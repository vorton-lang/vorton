//! C11 code generation for checked programs.
//!
//! This module defines the C types of the program and their helpers:
//! release, retain, clone, comparison and hashing, and the operations of
//! lists and maps. [`body`] emits each function from its IR.
//!
//! An owned value that must be released, a counted `Str`, a container, or
//! an aggregate holding one, belongs to exactly one place. Copying a counted
//! value retains it; an entity is never copied: moving it leaves the source
//! zeroed, and releasing a zeroed value does nothing.

mod body;

use std::fmt::Write as _;

use crate::mir::{Instance, LocalDecl, Program};
use crate::types::{Glue, Operation};
use crate::types::{Type, TypeKind, Types};

const RUNTIME: &str = include_str!("../../../runtime/vorton_runtime.c");
const GENERIC: &str = "generic functions are instantiated before code generation";

/// Generates one self-contained C11 translation unit for `program`.
pub(crate) fn emit(program: &Program) -> String {
    let mut literals = Literals::default();
    let mut bodies = String::new();
    for index in 0..program.functions.len() {
        bodies.push_str(&body::function(program, index, &mut literals));
    }

    let mut output = String::from(RUNTIME);
    output.push('\n');
    let (definitions, helper_bodies) = type_definitions(program);
    output.push_str(&definitions);
    output.push_str(&literals.declarations);
    for (index, function) in program.functions.iter().enumerate() {
        writeln!(output, "{};", prototype(&program.types, index, function)).unwrap();
    }
    output.push('\n');
    // Helpers of types with hand-written comparisons call the functions.
    output.push_str(&helper_bodies);
    output.push_str(&bodies);
    writeln!(
        output,
        "int main(void) {{\n    vt_start();\n    {}();\n    vt_finish();\n    return 0;\n}}",
        function_name(program.main, &program.functions[program.main])
    )
    .unwrap();
    output
}

/// C definitions for every tuple, struct, enum and list type, then the
/// prototypes of their helpers: release, retain, equality, clone, and the
/// list operations; and separately the bodies of the helpers.
fn type_definitions(program: &Program) -> (String, String) {
    let types = &program.types;
    let mut definitions = String::new();
    let mut done = vec![false; types.len()];
    for ty in types.all() {
        define(types, ty, &mut done, &mut definitions);
    }
    let mut prototypes = String::new();
    let mut bodies = String::new();
    for ty in types.all() {
        if is_aggregate(types, ty) {
            helpers(program, ty, &mut prototypes, &mut bodies);
        }
    }
    (definitions + &prototypes, bodies)
}

fn define(types: &Types, ty: Type, done: &mut [bool], output: &mut String) {
    if done[ty.index()] || !is_aggregate(types, ty) {
        return;
    }
    done[ty.index()] = true;
    for component in types.components(ty) {
        define(types, component, done, output);
    }
    let name = c_type(types, ty);
    writeln!(output, "typedef struct {name} {{").unwrap();
    match types.kind(ty) {
        TypeKind::List(element) => {
            writeln!(
                output,
                "    int64_t len;\n    int64_t cap;\n    {} *items;",
                item_type(types, *element)
            )
            .unwrap();
        }
        TypeKind::Map(..) | TypeKind::Set(_) => output.push_str("    vt_map m;\n"),
        _ if types.is_enum(ty) => {
            output.push_str("    int32_t tag;\n");
            let mut union = String::new();
            for (variant, fields) in variant_fields(types, ty).iter().enumerate() {
                let members = fields
                    .iter()
                    .enumerate()
                    .filter(|(_, field)| types.has_storage(**field))
                    .map(|(index, field)| format!("{} f{index};", c_type(types, *field)))
                    .collect::<Vec<_>>();
                if !members.is_empty() {
                    writeln!(
                        union,
                        "        struct {{ {} }} v{variant};",
                        members.join(" ")
                    )
                    .unwrap();
                }
            }
            if !union.is_empty() {
                writeln!(output, "    union {{\n{union}    }} u;").unwrap();
            }
        }
        _ => {
            let mut stored = 0;
            for (index, component) in types.components(ty).iter().enumerate() {
                if types.has_storage(*component) {
                    writeln!(output, "    {} f{index};", c_type(types, *component)).unwrap();
                    stored += 1;
                }
            }
            if stored == 0 && !types.has_drop(ty) {
                output.push_str("    char vt_empty;\n");
            }
        }
    }
    // A value with a hand-written `Drop` is live until it is moved away.
    if types.has_drop(ty) {
        output.push_str("    bool vt_live;\n");
    }
    writeln!(output, "}} {name};").unwrap();
}

/// The C type of list items: a struct tag, so lists can hold types that are
/// defined after them.
fn item_type(types: &Types, element: Type) -> String {
    if !types.has_storage(element) {
        "char".to_owned()
    } else if is_aggregate(types, element) {
        format!("struct {}", c_type(types, element))
    } else {
        c_type(types, element)
    }
}

/// The helpers of a tuple, struct or enum type. Comparing and cloning call
/// the hand-written impl or work through the parts as [`Types::glue`] says.
fn helpers(program: &Program, ty: Type, prototypes: &mut String, bodies: &mut String) {
    let types = &program.types;
    let written = types.written.get(&ty);
    let name = c_type(types, ty);
    let n = ty.index();
    let mut function = |signature: String, body: String| {
        writeln!(prototypes, "static {signature};").unwrap();
        writeln!(bodies, "static {signature} {{\n{body}}}").unwrap();
    };
    if let TypeKind::List(element) = *types.kind(ty) {
        list_helpers(types, ty, element, &mut function);
        return;
    }
    if let TypeKind::Map(key, value) = *types.kind(ty) {
        map_helpers(types, ty, key, value, &mut function);
        return;
    }
    // A set is a map whose values are `Unit`.
    if let TypeKind::Set(element) = *types.kind(ty) {
        map_helpers(types, ty, element, Type::UNIT, &mut function);
        return;
    }
    let parts = variant_fields(types, ty);
    let per_field = |action: &dyn Fn(Type, &str) -> Option<String>, source: &str| {
        let mut body = String::new();
        for (variant, fields) in parts.iter().enumerate() {
            let lines = fields
                .iter()
                .enumerate()
                .filter_map(|(index, field)| {
                    action(*field, &field_code(types, ty, variant, index, source))
                })
                .collect::<Vec<_>>();
            if lines.is_empty() {
                continue;
            }
            if types.is_enum(ty) {
                writeln!(
                    body,
                    "    if ({source}.tag == {variant}) {{ {} }}",
                    lines.join(" ")
                )
                .unwrap();
            } else {
                for line in lines {
                    writeln!(body, "    {line}").unwrap();
                }
            }
        }
        body
    };
    if types.needs_release(ty) {
        let mut body = per_field(
            &|field, code| {
                types
                    .needs_release(field)
                    .then(|| count_line(field, "release", code))
            },
            "v",
        );
        // A hand-written `drop` runs first, on a value that has not been
        // moved away, and then the fields are released.
        if let Some(drop) = written.and_then(|written| written.drop) {
            let user = function_name(drop, &program.functions[drop]);
            body = format!("    if (!v.vt_live) return;\n    {user}(&v);\n{body}");
        }
        function(format!("void vt_release_T{n}({name} v)"), body);
        if !types.is_entity(ty) {
            let body = per_field(
                &|field, code| {
                    types
                        .needs_release(field)
                        .then(|| count_line(field, "retain", code))
                },
                "v",
            );
            function(format!("void vt_retain_T{n}({name} v)"), body);
        }
    }
    let clone_body = if let Glue::Written(clone) = types.glue(ty, Operation::Clone) {
        let user = function_name(clone, &program.functions[clone]);
        format!("    return {user}(&v);\n")
    } else if types.is_entity(ty) {
        let body = per_field(
            &|field, code| {
                types
                    .needs_release(field)
                    .then(|| format!("{code} = {};", clone_code(types, field, code)))
            },
            "r",
        );
        format!("    {name} r = v;\n{body}    return r;\n")
    } else if types.needs_release(ty) {
        format!("    vt_retain_T{n}(v);\n    return v;\n")
    } else {
        "    return v;\n".to_owned()
    };
    function(format!("{name} vt_clone_T{n}({name} v)"), clone_body);
    if let Glue::Written(eq) = types.glue(ty, Operation::Equal) {
        let user = function_name(eq, &program.functions[eq]);
        function(
            format!("bool vt_eq_T{n}({name} a, {name} b)"),
            format!("    return {user}(&a, &b);\n"),
        );
    } else if types.has_equality(ty) {
        let mut body = String::new();
        if types.is_enum(ty) {
            body.push_str("    if (a.tag != b.tag) return false;\n");
        }
        for (variant, fields) in parts.iter().enumerate() {
            let tests = fields
                .iter()
                .enumerate()
                .filter(|(_, field)| types.has_storage(**field))
                .map(|(index, field)| {
                    equal_code(
                        types,
                        *field,
                        &field_code(types, ty, variant, index, "a"),
                        &field_code(types, ty, variant, index, "b"),
                    )
                })
                .collect::<Vec<_>>();
            if tests.is_empty() {
                continue;
            }
            if types.is_enum(ty) {
                writeln!(
                    body,
                    "    if (a.tag == {variant}) return {};",
                    tests.join(" && ")
                )
                .unwrap();
            } else {
                writeln!(body, "    return {};", tests.join(" && ")).unwrap();
            }
        }
        body.push_str("    return true;\n");
        function(format!("bool vt_eq_T{n}({name} a, {name} b)"), body);
    }
    if let Glue::Written(partial_cmp) = types.glue(ty, Operation::Order) {
        // `Option<Ordering>` to -1, 0 or 1, and 2 for `None`; the variants
        // of `Ordering` are `Less`, `Equal` and `Greater`.
        let user = function_name(partial_cmp, &program.functions[partial_cmp]);
        let body = &program.functions[partial_cmp].body;
        let result = body.locals[body.result].ty;
        let (some, none) = option_variants(types, result);
        function(
            format!("int vt_cmp_T{n}({name} a, {name} b)"),
            format!(
                "    {} r = {user}(&a, &b);\n    if (r.tag == {none}) return 2;\n    return (int)r.u.v{some}.f0.tag - 1;\n",
                c_type(types, result)
            ),
        );
    } else if types.has_order(ty) {
        // Fields in declaration order; an enum compares variants first.
        let mut body = String::from("    int c = 0;\n");
        if types.is_enum(ty) {
            body.push_str("    if (a.tag != b.tag) return a.tag < b.tag ? -1 : 1;\n");
        }
        for (variant, fields) in parts.iter().enumerate() {
            let steps = fields
                .iter()
                .enumerate()
                .filter(|(_, field)| types.has_storage(**field))
                .map(|(index, field)| {
                    let compare = compare_code(
                        types,
                        *field,
                        &field_code(types, ty, variant, index, "a"),
                        &field_code(types, ty, variant, index, "b"),
                    );
                    format!("c = {compare}; if (c != 0) return c;")
                })
                .collect::<Vec<_>>();
            if steps.is_empty() {
                continue;
            }
            if types.is_enum(ty) {
                writeln!(
                    body,
                    "    if (a.tag == {variant}) {{ {} }}",
                    steps.join(" ")
                )
                .unwrap();
            } else {
                for step in steps {
                    writeln!(body, "    {step}").unwrap();
                }
            }
        }
        body.push_str("    return c;\n");
        function(format!("int vt_cmp_T{n}({name} a, {name} b)"), body);
    }
    if types.is_key(ty) {
        let tag = if types.is_enum(ty) {
            "    h = vt_hash_mix(h, (uint64_t)v.tag);\n"
        } else {
            ""
        };
        let fields = per_field(
            &|field, code| {
                types
                    .has_storage(field)
                    .then(|| format!("h = vt_hash_mix(h, {});", hash_code(types, field, code)))
            },
            "v",
        );
        function(
            format!("uint64_t vt_hash_T{n}({name} v)"),
            format!("    uint64_t h = 0;\n{tag}{fields}    return h;\n"),
        );
    }
}

/// A C expression that compares two values of type `ty` three ways: -1, 0
/// or 1, or 2 when they are unordered.
fn compare_code(types: &Types, ty: Type, a: &str, b: &str) -> String {
    match types.kind(ty) {
        TypeKind::Int => format!("vt_cmp_int({a}, {b})"),
        TypeKind::Bool => format!("vt_cmp_int((int64_t){a}, (int64_t){b})"),
        TypeKind::Float => format!("vt_cmp_float({a}, {b})"),
        TypeKind::Str => format!("vt_cmp_str({a}, {b})"),
        TypeKind::Unit => "0".to_owned(),
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } => {
            format!("vt_cmp_T{}({a}, {b})", ty.index())
        }
        _ => unreachable!("the checker orders only these types"),
    }
}

/// A C expression that hashes the map key `code` of type `ty`.
fn hash_code(types: &Types, ty: Type, code: &str) -> String {
    match types.kind(ty) {
        TypeKind::Int => format!("vt_hash_int({code})"),
        TypeKind::Bool => format!("vt_hash_int((int64_t){code})"),
        TypeKind::Str => format!("vt_hash_str({code})"),
        // `Unit` has one value.
        TypeKind::Unit => "0".to_owned(),
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } => format!("vt_hash_T{}({code})", ty.index()),
        _ => unreachable!("the checker admits only these key types"),
    }
}

/// The helpers of a map type: how its keys hash and compare, and release,
/// clone and clear.
fn map_helpers(
    types: &Types,
    ty: Type,
    key: Type,
    value: Type,
    function: &mut impl FnMut(String, String),
) {
    let name = c_type(types, ty);
    let n = ty.index();
    let (key_item, value_item) = (item_type(types, key), item_type(types, value));
    function(
        format!("uint64_t vt_maphash_T{n}(const void *key)"),
        format!(
            "    return {};\n",
            hash_code(types, key, &format!("*(const {key_item} *)key"))
        ),
    );
    function(
        format!("bool vt_mapeq_T{n}(const void *left, const void *right)"),
        format!(
            "    return {};\n",
            equal_code(
                types,
                key,
                &format!("*(const {key_item} *)left"),
                &format!("*(const {key_item} *)right")
            )
        ),
    );
    function(
        format!("const vt_map_type *vt_maptype_T{n}(void)"),
        format!(
            "    static const vt_map_type type = {{sizeof({key_item}), sizeof({value_item}), vt_maphash_T{n}, vt_mapeq_T{n}}};\n    return &type;\n"
        ),
    );
    let mut release_entry = String::new();
    if types.needs_release(key) {
        release_entry.push_str(&count_line(
            key,
            "release",
            &map_key(types, key, "map", "i"),
        ));
    }
    if types.needs_release(value) {
        release_entry.push_str(&count_line(
            value,
            "release",
            &map_value(types, value, "map", "i"),
        ));
    }
    let release_all = if release_entry.is_empty() {
        String::new()
    } else {
        format!(
            "    for (int64_t i = 0; i < map->m.used; i += 1) {{\n        if (map->m.live[i]) {{ {release_entry} }}\n    }}\n"
        )
    };
    function(
        format!("void vt_clear_T{n}({name} *map)"),
        format!("{release_all}    vt_map_reset(&map->m);\n"),
    );
    let map = if release_all.is_empty() {
        String::new()
    } else {
        format!("    {name} *map = &v;\n")
    };
    function(
        format!("void vt_release_T{n}({name} v)"),
        format!("{map}{release_all}    vt_map_free(&v.m);\n"),
    );
    function(
        format!("{name} vt_clone_T{n}({name} v)"),
        format!(
            "    {name} r = {{0}};\n    for (int64_t i = 0; i < v.m.used; i += 1) {{\n        if (!v.m.live[i]) continue;\n        {key_item} key = {};\n        {value_item} value = {};\n        {value_item} old;\n        vt_map_insert(&r.m, vt_maptype_T{n}(), &key, &value, &old);\n    }}\n    return r;\n",
            clone_code(types, key, &map_key(types, key, "&v", "i")),
            clone_code(types, value, &map_value(types, value, "&v", "i")),
        ),
    );
}

/// The C lvalue of the key of entry `entry` of the map `*map`.
fn map_key(types: &Types, key: Type, map: &str, entry: &str) -> String {
    format!("(({} *)({map})->m.keys)[{entry}]", item_type(types, key))
}

/// The C lvalue of the value of entry `entry` of the map `*map`.
fn map_value(types: &Types, value: Type, map: &str, entry: &str) -> String {
    format!(
        "(({} *)({map})->m.values)[{entry}]",
        item_type(types, value)
    )
}

fn list_helpers(types: &Types, ty: Type, element: Type, function: &mut impl FnMut(String, String)) {
    let name = c_type(types, ty);
    let n = ty.index();
    let stored = types.has_storage(element);
    let item = c_type(types, element);
    let size = if stored {
        format!("sizeof({item})")
    } else {
        "1".to_owned()
    };
    let release_each = if types.needs_release(element) {
        format!(
            "    for (int64_t i = 0; i < v.len; i += 1) {{ {} }}\n",
            count_line(element, "release", "v.items[i]")
        )
    } else {
        String::new()
    };
    function(
        format!("void vt_release_T{n}({name} v)"),
        format!("{release_each}    vt_items_free(v.items);\n"),
    );
    let grow = format!(
        "    if (list->len == list->cap) {{\n        list->cap = list->cap == 0 ? 4 : list->cap * 2;\n        list->items = vt_items_resize(list->items, list->cap, {size});\n    }}\n"
    );
    let value_parameter = if stored {
        format!(", {item} value")
    } else {
        String::new()
    };
    let store = if stored {
        "    list->items[list->len] = value;\n"
    } else {
        ""
    };
    function(
        format!("void vt_push_T{n}({name} *list{value_parameter})"),
        format!("{grow}{store}    list->len += 1;\n"),
    );
    let shift_up = if stored {
        format!(
            "    memmove(list->items + index + 1, list->items + index, (size_t)(list->len - index) * {size});\n    list->items[index] = value;\n"
        )
    } else {
        String::new()
    };
    function(
        format!("void vt_insert_T{n}({name} *list, int64_t index{value_parameter})"),
        format!(
            "    if (index < 0 || index > list->len) {{\n        vt_panic(\"index out of bounds\");\n    }}\n{grow}{shift_up}    list->len += 1;\n"
        ),
    );
    if stored {
        function(
            format!("{item} vt_remove_T{n}({name} *list, int64_t index)"),
            format!(
                "    vt_check_index(index, list->len);\n    {item} result = list->items[index];\n    memmove(list->items + index, list->items + index + 1, (size_t)(list->len - index - 1) * {size});\n    list->len -= 1;\n    return result;\n"
            ),
        );
    }
    let release_all = if types.needs_release(element) {
        format!(
            "    for (int64_t i = 0; i < list->len; i += 1) {{ {} }}\n",
            count_line(element, "release", "list->items[i]")
        )
    } else {
        String::new()
    };
    function(
        format!("void vt_clear_T{n}({name} *list)"),
        format!("{release_all}    list->len = 0;\n"),
    );
    let copy_items = if stored {
        format!(
            "    for (int64_t i = 0; i < v.len; i += 1) {{ r.items[i] = {}; }}\n",
            clone_code(types, element, "v.items[i]")
        )
    } else {
        String::new()
    };
    function(
        format!("{name} vt_clone_T{n}({name} v)"),
        format!(
            "    {name} r = {{0}};\n    if (v.len > 0) {{\n        r.cap = v.len;\n        r.items = vt_items_resize(NULL, r.cap, {size});\n    }}\n{copy_items}    r.len = v.len;\n    return r;\n"
        ),
    );
    if types.has_equality(ty) {
        let test = if stored {
            format!(
                "        if (!{}) return false;\n",
                equal_code(types, element, "a.items[i]", "b.items[i]")
            )
        } else {
            String::new()
        };
        function(
            format!("bool vt_eq_T{n}({name} a, {name} b)"),
            format!(
                "    if (a.len != b.len) return false;\n    for (int64_t i = 0; i < a.len; i += 1) {{\n{test}    }}\n    return true;\n"
            ),
        );
        if stored && !types.is_entity(element) {
            function(
                format!("bool vt_contains_T{n}({name} v, {item} value)"),
                format!(
                    "    for (int64_t i = 0; i < v.len; i += 1) {{\n        if ({}) return true;\n    }}\n    return false;\n",
                    equal_code(types, element, "v.items[i]", "value")
                ),
            );
        }
    }
}

/// A C expression that returns an owned copy of `code`.
fn clone_code(types: &Types, ty: Type, code: &str) -> String {
    match types.kind(ty) {
        TypeKind::Str => format!("(vt_str_retain({code}), {code})"),
        TypeKind::Tuple(_)
        | TypeKind::Nominal { .. }
        | TypeKind::List(_)
        | TypeKind::Map(..)
        | TypeKind::Set(_) => format!("vt_clone_T{}({code})", ty.index()),
        _ => code.to_owned(),
    }
}

/// The field types of each variant; a tuple or struct has one variant.
fn variant_fields(types: &Types, ty: Type) -> Vec<Vec<Type>> {
    match types.kind(ty) {
        TypeKind::Tuple(elements) => vec![elements.clone()],
        TypeKind::Nominal { .. } => types
            .variants(ty)
            .iter()
            .map(|variant| variant.fields.iter().map(|field| field.ty).collect())
            .collect(),
        _ => Vec::new(),
    }
}

/// The C lvalue of field `index` of `variant` inside `base` of type `ty`.
fn field_code(types: &Types, ty: Type, variant: usize, index: usize, base: &str) -> String {
    if types.is_enum(ty) {
        format!("{base}.u.v{variant}.f{index}")
    } else {
        format!("{base}.f{index}")
    }
}

/// Whether `ty` is defined as a C struct. A type that mentions a type
/// parameter is not; only its instances are.
fn is_aggregate(types: &Types, ty: Type) -> bool {
    matches!(
        types.kind(ty),
        TypeKind::Tuple(_)
            | TypeKind::Nominal { .. }
            | TypeKind::List(_)
            | TypeKind::Map(..)
            | TypeKind::Set(_)
    ) && !types.is_generic(ty)
}

/// A C expression that compares two values of type `ty`.
fn equal_code(types: &Types, ty: Type, a: &str, b: &str) -> String {
    match types.kind(ty) {
        TypeKind::Unit | TypeKind::Never => "true".to_owned(),
        TypeKind::Str => format!("vt_str_eq({a}, {b})"),
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } | TypeKind::List(_) => {
            format!("vt_eq_T{}({a}, {b})", ty.index())
        }
        TypeKind::Map(..) | TypeKind::Set(_) | TypeKind::Range => {
            unreachable!("maps, sets and ranges have no ==")
        }
        TypeKind::Param { .. } => unreachable!("{GENERIC}"),
        TypeKind::Int | TypeKind::Float | TypeKind::Bool => format!("({a} == {b})"),
    }
}

/// The statement that retains or releases the value `code`.
fn count_line(ty: Type, action: &str, code: &str) -> String {
    if ty == Type::STR {
        format!("vt_str_{action}({code});")
    } else {
        format!("vt_{action}_T{}({code});", ty.index())
    }
}

fn function_name(index: usize, function: &Instance) -> String {
    format!("vt_f{index}_{}", function.name)
}

fn prototype(types: &Types, index: usize, function: &Instance) -> String {
    let body = &function.body;
    let parameters = body
        .parameters
        .iter()
        .filter(|&&local| types.has_storage(body.locals[local].ty))
        .map(|&local| {
            let declaration = &body.locals[local];
            format!(
                "{} {}",
                storage_type(types, declaration),
                local_name(local, &declaration.name)
            )
        })
        .collect::<Vec<_>>();
    let parameters = if parameters.is_empty() {
        "void".to_owned()
    } else {
        parameters.join(", ")
    };
    // A borrowed result is a pointer to the place it names.
    let result = storage_type(types, &body.locals[body.result]);
    format!(
        "static {result} {}({parameters})",
        function_name(index, function)
    )
}

/// The C type that stores a local: a pointer for a reference local whose
/// target has storage.
fn storage_type(types: &Types, local: &LocalDecl) -> String {
    if local.reference.is_some() && types.has_storage(local.ty) {
        format!("{} *", c_type(types, local.ty))
    } else {
        c_type(types, local.ty)
    }
}
fn c_type(types: &Types, ty: Type) -> String {
    match types.kind(ty) {
        TypeKind::Int => "int64_t".to_owned(),
        TypeKind::Float => "double".to_owned(),
        TypeKind::Bool => "bool".to_owned(),
        TypeKind::Str => "vt_str *".to_owned(),
        TypeKind::Unit | TypeKind::Never => "void".to_owned(),
        TypeKind::Range => "vt_range".to_owned(),
        TypeKind::Tuple(_)
        | TypeKind::Nominal { .. }
        | TypeKind::List(_)
        | TypeKind::Map(..)
        | TypeKind::Set(_) => format!("vt_T{}", ty.index()),
        TypeKind::Param { .. } => unreachable!("{GENERIC}"),
    }
}

/// An initializer for a variable of type `ty`.
fn zero(types: &Types, ty: Type) -> &'static str {
    match types.kind(ty) {
        TypeKind::Int => "0",
        TypeKind::Float => "0.0",
        TypeKind::Bool => "false",
        TypeKind::Str => "NULL",
        TypeKind::Tuple(_)
        | TypeKind::Nominal { .. }
        | TypeKind::List(_)
        | TypeKind::Map(..)
        | TypeKind::Set(_)
        | TypeKind::Range => "{0}",
        TypeKind::Unit | TypeKind::Never => unreachable!("unit values have no storage"),
        TypeKind::Param { .. } => unreachable!("{GENERIC}"),
    }
}

/// An expression for the zero value of `ty`, assignable to an existing place.
fn zero_value(types: &Types, ty: Type) -> String {
    if is_aggregate(types, ty) || *types.kind(ty) == TypeKind::Range {
        format!("({}){{0}}", c_type(types, ty))
    } else {
        zero(types, ty).to_owned()
    }
}

fn local_name(local: usize, name: &str) -> String {
    format!("v{local}_{name}")
}

#[derive(Default)]
struct Literals {
    declarations: String,
    count: usize,
}

impl Literals {
    fn add(&mut self, value: &str) -> String {
        let name = format!("vt_lit{}", self.count);
        self.count += 1;
        writeln!(
            self.declarations,
            "static vt_str {name} = {{-1, {}, \"{}\"}};",
            value.len(),
            escape_c(value)
        )
        .unwrap();
        format!("(&{name})")
    }
}

fn escape_c(value: &str) -> String {
    let mut escaped = String::new();
    for byte in value.bytes() {
        match byte {
            b'\\' => escaped.push_str("\\\\"),
            b'"' => escaped.push_str("\\\""),
            b'?' => escaped.push_str("\\?"),
            b' '..=b'~' => escaped.push(char::from(byte)),
            _ => write!(escaped, "\\{byte:03o}").unwrap(),
        }
    }
    escaped
}

/// The `Some` and `None` variant indices of an `Option` type: `Some` is the
/// variant with one field.
fn option_variants(types: &Types, ty: Type) -> (usize, usize) {
    let variants = types.variants(ty);
    let some = variants
        .iter()
        .position(|variant| variant.fields.len() == 1)
        .expect("`Option` has `Some`");
    let none = variants
        .iter()
        .position(|variant| variant.fields.is_empty())
        .expect("`Option` has `None`");
    (some, none)
}

fn int_literal(value: i64) -> String {
    if value == i64::MIN {
        "INT64_MIN".to_owned()
    } else {
        format!("INT64_C({value})")
    }
}
