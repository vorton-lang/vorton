//! C11 code generation for checked programs.
//!
//! Expressions are flattened into temporaries so evaluation order is explicit.
//! An owned value that must be released, a counted `Str`, a list, or an
//! aggregate holding either, belongs to exactly one place:
//!
//! - locals and temporaries own their value; a scope releases what it owns
//!   when it ends, and `break`, `continue` and `return` release the scopes
//!   they leave;
//! - copying a counted value retains it; an entity is never copied: moving
//!   it leaves the source zeroed, and releasing a zeroed value does nothing;
//! - a parameter of a counted value type is borrowed from the caller, while
//!   a parameter of an entity type is owned by the callee.

use std::fmt::Write as _;

use crate::ast::{AssignmentOperator, BinaryOperator, UnaryOperator};
use crate::checker::{
    Arm, Block, BorrowTarget, Builtin, Expr, ExprKind, ForSource, Function, Intrinsic, Pattern,
    Place, Program, Projection, Receiver, Statement, Type, TypeKind, Types,
};

const RUNTIME: &str = include_str!("../../../runtime/vorton_runtime.c");

/// Generates one self-contained C11 translation unit for `program`.
pub(crate) fn emit(program: &Program) -> String {
    let mut literals = Literals::default();
    let mut bodies = String::new();
    for (index, function) in program.functions.iter().enumerate() {
        bodies.push_str(&FunctionEmitter::emit(
            program,
            index,
            function,
            &mut literals,
        ));
    }

    let mut output = String::from(RUNTIME);
    output.push('\n');
    output.push_str(&type_definitions(&program.types));
    output.push_str(&literals.declarations);
    for (index, function) in program.functions.iter().enumerate() {
        writeln!(output, "{};", prototype(&program.types, index, function)).unwrap();
    }
    output.push('\n');
    output.push_str(&bodies);
    writeln!(
        output,
        "int main(void) {{\n    {}();\n    vt_finish();\n    return 0;\n}}",
        function_name(program.main, &program.functions[program.main])
    )
    .unwrap();
    output
}

/// C definitions for every tuple, struct, enum and list type, then the
/// prototypes and bodies of their helpers: release, retain, equality,
/// clone, and the list operations.
fn type_definitions(types: &Types) -> String {
    let mut definitions = String::new();
    let mut done = vec![false; types.len()];
    for ty in types.all() {
        define(types, ty, &mut done, &mut definitions);
    }
    let mut prototypes = String::new();
    let mut bodies = String::new();
    for ty in types.all() {
        if is_aggregate(types, ty) {
            helpers(types, ty, &mut prototypes, &mut bodies);
        }
    }
    definitions + &prototypes + &bodies
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
        TypeKind::Map(..) => output.push_str("    vt_map m;\n"),
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
            if stored == 0 {
                output.push_str("    char vt_empty;\n");
            }
        }
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

fn helpers(types: &Types, ty: Type, prototypes: &mut String, bodies: &mut String) {
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
        let body = per_field(
            &|field, code| {
                types
                    .needs_release(field)
                    .then(|| count_line(field, "release", code))
            },
            "v",
        );
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
    let clone_body = if types.is_entity(ty) {
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
    if has_equality(types, ty) {
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

/// A C expression that hashes the map key `code` of type `ty`.
fn hash_code(types: &Types, ty: Type, code: &str) -> String {
    match types.kind(ty) {
        TypeKind::Int => format!("vt_hash_int({code})"),
        TypeKind::Bool => format!("vt_hash_int((int64_t){code})"),
        TypeKind::Str => format!("vt_hash_str({code})"),
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
    if has_equality(types, ty) {
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
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } | TypeKind::List(_) | TypeKind::Map(..) => {
            format!("vt_clone_T{}({code})", ty.index())
        }
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

fn is_aggregate(types: &Types, ty: Type) -> bool {
    matches!(
        types.kind(ty),
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } | TypeKind::List(_) | TypeKind::Map(..)
    )
}

fn has_equality(types: &Types, ty: Type) -> bool {
    match types.kind(ty) {
        TypeKind::Int | TypeKind::Float | TypeKind::Bool | TypeKind::Str | TypeKind::Unit => true,
        TypeKind::Never | TypeKind::Map(..) => false,
        TypeKind::List(element) => has_equality(types, *element),
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } => types
            .components(ty)
            .into_iter()
            .all(|component| has_equality(types, component)),
    }
}

/// A C expression that compares two values of type `ty`.
fn equal_code(types: &Types, ty: Type, a: &str, b: &str) -> String {
    match types.kind(ty) {
        TypeKind::Unit | TypeKind::Never => "true".to_owned(),
        TypeKind::Str => format!("vt_str_eq({a}, {b})"),
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } | TypeKind::List(_) => {
            format!("vt_eq_T{}({a}, {b})", ty.index())
        }
        TypeKind::Map(..) => unreachable!("maps have no =="),
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

fn function_name(index: usize, function: &Function) -> String {
    format!("vt_f{index}_{}", function.name)
}

fn prototype(types: &Types, index: usize, function: &Function) -> String {
    let parameters = function
        .parameters
        .iter()
        .filter(|&&local| types.has_storage(function.locals[local].ty))
        .map(|&local| {
            let local_info = &function.locals[local];
            format!(
                "{} {}",
                storage_type(types, local_info),
                local_name(local, &local_info.name)
            )
        })
        .collect::<Vec<_>>();
    let parameters = if parameters.is_empty() {
        "void".to_owned()
    } else {
        parameters.join(", ")
    };
    let result = if function.result_borrow.is_some() {
        format!("{} *", c_type(types, function.result))
    } else {
        c_type(types, function.result)
    };
    format!(
        "static {result} {}({parameters})",
        function_name(index, function)
    )
}

/// The C type that stores a local: a pointer for a borrowed local.
fn storage_type(types: &Types, local: &crate::checker::Local) -> String {
    if local.borrow.is_some() {
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
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } | TypeKind::List(_) | TypeKind::Map(..) => {
            format!("vt_T{}", ty.index())
        }
    }
}

/// An initializer for a variable of type `ty`.
fn zero(types: &Types, ty: Type) -> &'static str {
    match types.kind(ty) {
        TypeKind::Int => "0",
        TypeKind::Float => "0.0",
        TypeKind::Bool => "false",
        TypeKind::Str => "NULL",
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } | TypeKind::List(_) | TypeKind::Map(..) => {
            "{0}"
        }
        TypeKind::Unit | TypeKind::Never => unreachable!("unit values have no storage"),
    }
}

/// An expression for the zero value of `ty`, assignable to an existing place.
fn zero_value(types: &Types, ty: Type) -> String {
    if is_aggregate(types, ty) {
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

/// The C lvalue of an evaluated place, its type, and the temporaries that
/// hold its list indices and map keys, with their types.
type PlaceCode = (String, Type, Vec<(String, Type)>);

/// A lowered operand. `owned` operands that need releasing belong to the
/// consumer, which must store or release them.
#[derive(Clone)]
enum Value {
    Unit,
    Never,
    Code { code: String, owned: bool },
}

impl Value {
    fn code(&self) -> &str {
        match self {
            Self::Code { code, .. } => code,
            Self::Unit | Self::Never => unreachable!("only typed values have C code"),
        }
    }
}

struct FunctionEmitter<'a> {
    program: &'a Program,
    types: &'a Types,
    function: &'a Function,
    literals: &'a mut Literals,
    declarations: String,
    body: String,
    indent: usize,
    temporaries: usize,
    labels: usize,
    /// Values that the current code owns and must release, per open scope,
    /// as C lvalues with their types.
    scopes: Vec<Vec<(String, Type)>>,
    /// The scope depth at the start of each enclosing loop body.
    loops: Vec<usize>,
}

impl FunctionEmitter<'_> {
    fn emit(
        program: &Program,
        index: usize,
        function: &Function,
        literals: &mut Literals,
    ) -> String {
        let types = &program.types;
        let mut emitter = FunctionEmitter {
            program,
            types,
            function,
            literals,
            declarations: String::new(),
            body: String::new(),
            indent: 1,
            temporaries: 0,
            labels: 0,
            scopes: vec![Vec::new()],
            loops: Vec::new(),
        };
        for (local, info) in function.locals.iter().enumerate() {
            if !function.parameters.contains(&local) && types.has_storage(info.ty) {
                let initial = if info.borrow.is_some() {
                    "NULL"
                } else {
                    zero(types, info.ty)
                };
                writeln!(
                    emitter.declarations,
                    "    {} {} = {initial};",
                    storage_type(types, info),
                    local_name(local, &info.name),
                )
                .unwrap();
            }
        }
        // The callee owns its entity parameters.
        for &local in &function.parameters {
            let ty = function.locals[local].ty;
            if types.is_entity(ty) && function.locals[local].borrow.is_none() {
                emitter.own(emitter.local_code(local), ty);
            }
        }
        let value = emitter.block(&function.body);
        match value {
            Value::Never => {}
            Value::Unit => {
                emitter.release_scopes_from(0);
                emitter.line("return;");
            }
            value @ Value::Code { .. } => emitter.return_value(value),
        }
        format!(
            "{} {{\n{}{}}}\n\n",
            prototype(types, index, function),
            emitter.declarations,
            emitter.body
        )
    }

    /// Returns `value` after releasing every scope. A borrowed result is a
    /// pointer that owns nothing.
    fn return_value(&mut self, value: Value) {
        let value = if self.function.result_borrow.is_some() {
            value
        } else {
            self.owned(value, self.function.result)
        };
        self.release_scopes_from(0);
        self.line(&format!("return {};", value.code()));
    }

    fn line(&mut self, text: &str) {
        for _ in 0..self.indent {
            self.body.push_str("    ");
        }
        self.body.push_str(text);
        self.body.push('\n');
    }

    fn temporary(&mut self, ty: Type) -> String {
        let name = format!("t{}", self.temporaries);
        self.temporaries += 1;
        writeln!(
            self.declarations,
            "    {} {name} = {};",
            c_type(self.types, ty),
            zero(self.types, ty)
        )
        .unwrap();
        name
    }

    fn counter(&mut self) -> String {
        let name = format!("t{}", self.temporaries);
        self.temporaries += 1;
        writeln!(self.declarations, "    int64_t {name} = 0;").unwrap();
        name
    }

    fn releases(&self, ty: Type) -> bool {
        self.types.needs_release(ty)
    }

    /// The C lvalue of a local; a borrowed local is dereferenced.
    fn local_code(&self, local: usize) -> String {
        let info = &self.function.locals[local];
        let name = local_name(local, &info.name);
        if info.borrow.is_some() {
            format!("(*{name})")
        } else {
            name
        }
    }

    /// Records that the innermost scope owns `code` of type `ty`.
    fn own(&mut self, code: String, ty: Type) {
        if self.releases(ty) {
            self.scopes
                .last_mut()
                .expect("a scope is open")
                .push((code, ty));
        }
    }

    /// Makes `value` an owned operand, retaining a borrowed counted value.
    fn owned(&mut self, value: Value, ty: Type) -> Value {
        match value {
            Value::Code { code, owned: false } if self.releases(ty) => {
                debug_assert!(
                    !self.types.is_entity(ty),
                    "the checker moves entities into owning positions"
                );
                let temporary = self.temporary(ty);
                self.line(&format!("{temporary} = {code};"));
                self.line(&count_line(ty, "retain", &temporary));
                Value::Code {
                    code: temporary,
                    owned: true,
                }
            }
            value => value,
        }
    }

    /// Copies a value that reads a place into a temporary, so that operands
    /// evaluated after it cannot change what it read. A counted copy is
    /// retained and owned.
    fn settle(&mut self, value: Value, ty: Type) -> Value {
        match value {
            Value::Code { code, owned: false } if !self.types.is_entity(ty) => {
                if self.releases(ty) {
                    self.owned(Value::Code { code, owned: false }, ty)
                } else {
                    self.store(ty, code, false)
                }
            }
            value => value,
        }
    }

    /// Evaluates `operands` from left to right, settling each one that more
    /// operands follow. Returns `None` if one diverges.
    fn operands<'e>(&mut self, operands: impl IntoIterator<Item = &'e Expr>) -> Option<Vec<Value>> {
        let operands = operands.into_iter().collect::<Vec<_>>();
        let mut values = Vec::new();
        for (position, operand) in operands.iter().enumerate() {
            let value = self.expr(operand);
            if matches!(value, Value::Never) {
                return None;
            }
            values.push(if position + 1 < operands.len() {
                self.settle(value, operand.ty)
            } else {
                value
            });
        }
        Some(values)
    }

    /// Releases `value` after a borrowing use if it owns what it holds.
    fn release(&mut self, value: &Value, ty: Type) {
        if let Value::Code { code, owned: true } = value
            && self.releases(ty)
        {
            self.line(&count_line(ty, "release", code));
        }
    }

    /// Keeps an owned value alive until the innermost scope ends, so a part
    /// of it can be read without copying, and returns it as a borrowed value.
    fn defer(&mut self, value: Value, ty: Type) -> Value {
        match value {
            Value::Code { code, owned: true } if self.releases(ty) => {
                let temporary = self.store(ty, code, false);
                self.own(temporary.code().to_owned(), ty);
                temporary
            }
            value => value,
        }
    }

    fn release_scopes_from(&mut self, depth: usize) {
        let owned = self.scopes[depth..]
            .iter()
            .flatten()
            .rev()
            .cloned()
            .collect::<Vec<_>>();
        for (code, ty) in owned {
            self.line(&count_line(ty, "release", &code));
        }
    }

    fn close_scope(&mut self) {
        let depth = self.scopes.len() - 1;
        self.release_scopes_from(depth);
        self.scopes.pop();
    }

    fn block(&mut self, block: &Block) -> Value {
        self.scopes.push(Vec::new());
        for statement in &block.statements {
            if self.statement(statement) {
                self.scopes.pop();
                return Value::Never;
            }
        }
        let value = match &block.tail {
            Some(tail) => {
                let value = self.expr(tail);
                if block.ty == Type::UNIT {
                    self.release(&value, tail.ty);
                    Value::Unit
                } else if matches!(value, Value::Never) || block.ty == Type::NEVER {
                    Value::Never
                } else if matches!(tail.kind, ExprKind::Borrow(_)) {
                    // A returned borrow is a pointer that owns nothing.
                    value
                } else {
                    self.owned(value, block.ty)
                }
            }
            None if block.ty == Type::NEVER => Value::Never,
            None => Value::Unit,
        };
        if matches!(value, Value::Never) {
            self.scopes.pop();
        } else {
            self.close_scope();
        }
        value
    }

    /// Evaluates the indices and keys of `place` and returns its C lvalue,
    /// its type, and the temporaries that hold its list indices and map
    /// keys, in order, with their types. Returns `None` if one diverges.
    fn place(&mut self, place: &Place) -> Option<PlaceCode> {
        self.place_prefix(place, place.projections.len())
    }

    /// Like [`Self::place`], for the place reached by the first `count`
    /// projections of `place`.
    fn place_prefix(&mut self, place: &Place, count: usize) -> Option<PlaceCode> {
        if let Some(call) = &place.call {
            let Value::Code { code, .. } = self.expr(call) else {
                return None;
            };
            let name = local_name(place.local, &self.function.locals[place.local].name);
            self.line(&format!("{name} = &{code};"));
        }
        let mut code = self.local_code(place.local);
        let mut ty = self.function.locals[place.local].ty;
        let mut indices = Vec::new();
        for projection in &place.projections[..count] {
            match projection {
                Projection::Field(index) => {
                    code = field_code(self.types, ty, 0, *index, &code);
                    ty = self.types.components(ty)[*index];
                }
                Projection::Index(index) => {
                    let value = self.expr(index);
                    if matches!(value, Value::Never) {
                        return None;
                    }
                    match *self.types.kind(ty) {
                        TypeKind::List(element) => {
                            let index = self.store(Type::INT, value.code().to_owned(), false);
                            self.line(&format!("vt_check_index({}, {code}.len);", index.code()));
                            code = format!("{code}.items[{}]", index.code());
                            indices.push((index.code().to_owned(), Type::INT));
                            ty = element;
                        }
                        TypeKind::Map(key, element) => {
                            let key_code = self.key_operand(value, key);
                            code = self.map_at(&code, ty, element, &key_code);
                            indices.push((key_code, key));
                            ty = element;
                        }
                        _ => unreachable!("the checker indexes only lists and maps"),
                    }
                }
            }
        }
        Some((code, ty, indices))
    }

    /// Moves an owned key or value into a temporary of the map's entry
    /// storage, whose address the map functions take.
    fn entry_operand(&mut self, value: Value, ty: Type) -> String {
        let temporary = self.entry_temporary(ty);
        if let Value::Code { .. } = value {
            let value = self.owned(value, ty);
            self.line(&format!("{temporary} = {};", value.code()));
        }
        temporary
    }

    /// A temporary of the storage type of map keys or values of type `ty`.
    fn entry_temporary(&mut self, ty: Type) -> String {
        let name = format!("t{}", self.temporaries);
        self.temporaries += 1;
        let initial = if self.types.has_storage(ty) {
            zero(self.types, ty)
        } else {
            "0"
        };
        writeln!(
            self.declarations,
            "    {} {name} = {initial};",
            item_type(self.types, ty)
        )
        .unwrap();
        name
    }

    /// Keeps a map key in a temporary whose address can be taken, alive
    /// until the innermost scope ends.
    fn key_operand(&mut self, value: Value, key: Type) -> String {
        let value = self.defer(value, key);
        self.store(key, value.code().to_owned(), false)
            .code()
            .to_owned()
    }

    /// The C lvalue of the value of the key in `key_code` in the map `map`
    /// of type `ty`; the program panics if the key is absent.
    fn map_at(&mut self, map: &str, ty: Type, element: Type, key_code: &str) -> String {
        format!(
            "(*({} *)vt_map_at(&{map}.m, vt_maptype_T{}(), &{key_code}))",
            item_type(self.types, element),
            ty.index()
        )
    }

    /// Emits `statement` and returns whether control cannot continue after it.
    fn statement(&mut self, statement: &Statement) -> bool {
        match statement {
            Statement::Let { local, value } if self.function.locals[*local].borrow.is_some() => {
                let ExprKind::Borrow(target) = &value.kind else {
                    unreachable!("a borrowed binding is initialized by a borrow")
                };
                let BorrowTarget::Place(place) = target.as_ref() else {
                    unreachable!("the checker binds borrows of places only")
                };
                let Some((code, ty, _)) = self.place(place) else {
                    return true;
                };
                if self.types.has_storage(ty) {
                    let name = local_name(*local, &self.function.locals[*local].name);
                    self.line(&format!("{name} = &{code};"));
                }
                false
            }
            Statement::Let { local, value } => {
                let ty = self.function.locals[*local].ty;
                let value = self.expr(value);
                if matches!(value, Value::Never) {
                    return true;
                }
                if matches!(value, Value::Unit) {
                    return false;
                }
                let value = self.owned(value, ty);
                let name = self.local_code(*local);
                self.line(&format!("{name} = {};", value.code()));
                self.own(name, ty);
                false
            }
            Statement::LetPattern { pattern, value } => {
                let Some(code) = self.subject(value) else {
                    return true;
                };
                self.bind(pattern, &code, value.ty);
                self.close_scope();
                self.register_bindings(pattern);
                false
            }
            Statement::Assign {
                place,
                operator,
                value,
            } => self.assign(place, *operator, value),
            Statement::Expr(expression) => {
                let value = self.expr(expression);
                self.release(&value, expression.ty);
                matches!(value, Value::Never)
            }
            Statement::Return(value) => {
                let value = match value {
                    Some(value) => self.expr(value),
                    None => Value::Unit,
                };
                match value {
                    Value::Never => {}
                    Value::Unit => {
                        self.release_scopes_from(0);
                        self.line("return;");
                    }
                    value => self.return_value(value),
                }
                true
            }
            Statement::Break | Statement::Continue => {
                let depth = *self
                    .loops
                    .last()
                    .expect("the checker allows these only in loops");
                self.release_scopes_from(depth);
                self.line(if matches!(statement, Statement::Break) {
                    "break;"
                } else {
                    "continue;"
                });
                true
            }
            Statement::While { condition, body } => {
                self.line("for (;;) {");
                self.indent += 1;
                let condition = self.expr(condition);
                if !matches!(condition, Value::Never) {
                    self.line(&format!("if (!{}) break;", condition.code()));
                    self.loop_body(body, None, false);
                }
                self.indent -= 1;
                self.line("}");
                false
            }
            Statement::Loop(body) => {
                self.line("for (;;) {");
                self.indent += 1;
                self.loop_body(body, None, false);
                self.indent -= 1;
                self.line("}");
                body.ty == Type::NEVER && !loop_breaks(body)
            }
            Statement::For {
                binding,
                source,
                body,
            } => {
                self.for_loop(binding, source, body);
                false
            }
        }
    }

    fn assign(&mut self, place: &Place, operator: AssignmentOperator, value: &Expr) -> bool {
        if operator == AssignmentOperator::Assign
            && let Some(Projection::Index(key)) = place.projections.last()
        {
            // `map[key] = value` inserts the key or replaces its value.
            let count = place.projections.len() - 1;
            let Some((map, map_ty, _)) = self.place_prefix(place, count) else {
                return true;
            };
            if let TypeKind::Map(key_ty, value_ty) = *self.types.kind(map_ty) {
                let key = self.expr(key);
                if matches!(key, Value::Never) {
                    return true;
                }
                let key = self.entry_operand(key, key_ty);
                let value = self.expr(value);
                if matches!(value, Value::Never) {
                    return true;
                }
                let value = self.entry_operand(value, value_ty);
                let old = self.entry_temporary(value_ty);
                let release = [(key.as_str(), key_ty), (old.as_str(), value_ty)]
                    .iter()
                    .filter(|(_, ty)| self.releases(*ty))
                    .map(|(code, ty)| count_line(*ty, "release", code))
                    .collect::<Vec<_>>()
                    .join(" ");
                self.line(&format!(
                    "if (vt_map_insert(&{map}.m, vt_maptype_T{}(), &{key}, &{value}, &{old})) {{ {release} }}",
                    map_ty.index()
                ));
                return false;
            }
        }
        let Some((name, ty, _)) = self.place(place) else {
            return true;
        };
        let value = self.expr(value);
        if matches!(value, Value::Never) {
            return true;
        }
        if matches!(value, Value::Unit) {
            return false;
        }
        let code = value.code().to_owned();
        match (operator, ty) {
            (AssignmentOperator::Assign, ty) if self.releases(ty) => {
                let value = self.owned(value, ty);
                self.line(&count_line(ty, "release", &name));
                self.line(&format!("{name} = {};", value.code()));
            }
            (AssignmentOperator::Assign, _) => self.line(&format!("{name} = {code};")),
            (operator, Type::INT) => {
                let function = match operator {
                    AssignmentOperator::AddAssign => "vt_int_add",
                    AssignmentOperator::SubtractAssign => "vt_int_sub",
                    AssignmentOperator::MultiplyAssign => "vt_int_mul",
                    AssignmentOperator::DivideAssign => "vt_int_div",
                    AssignmentOperator::RemainderAssign => "vt_int_rem",
                    AssignmentOperator::Assign => unreachable!(),
                };
                self.line(&format!("{name} = {function}({name}, {code});"));
            }
            (operator, _) => {
                let expression = match operator {
                    AssignmentOperator::AddAssign => format!("{name} + {code}"),
                    AssignmentOperator::SubtractAssign => format!("{name} - {code}"),
                    AssignmentOperator::MultiplyAssign => format!("{name} * {code}"),
                    AssignmentOperator::DivideAssign => format!("{name} / {code}"),
                    AssignmentOperator::RemainderAssign => format!("fmod({name}, {code})"),
                    AssignmentOperator::Assign => unreachable!(),
                };
                self.line(&format!("{name} = {expression};"));
            }
        }
        false
    }

    /// Emits a loop body. `binding` assigns the loop variable at the start of
    /// each iteration; the variable is owned by the iteration, and so is the
    /// element itself when `owned`, after the binding took its parts.
    fn loop_body(&mut self, body: &Block, binding: Option<(&Pattern, String, Type)>, owned: bool) {
        self.loops.push(self.scopes.len());
        self.scopes.push(Vec::new());
        if let Some((pattern, code, ty)) = binding {
            if owned {
                self.own(code.clone(), ty);
            }
            self.bind(pattern, &Some(code), ty);
            self.register_bindings(pattern);
        }
        if !matches!(self.block(body), Value::Never) {
            self.close_scope();
        } else {
            self.scopes.pop();
        }
        self.loops.pop();
    }

    fn for_loop(&mut self, binding: &Pattern, source: &ForSource, body: &Block) {
        match source {
            ForSource::Range {
                start,
                end,
                inclusive,
            } => {
                let start = self.expr(start);
                if matches!(start, Value::Never) {
                    return;
                }
                let current = self.store(Type::INT, start.code().to_owned(), false);
                let end = self.expr(end);
                if matches!(end, Value::Never) {
                    return;
                }
                let end = self.store(Type::INT, end.code().to_owned(), false);
                let (current, end) = (current.code().to_owned(), end.code().to_owned());
                if *inclusive {
                    let going = self.counter();
                    self.line(&format!(
                        "for ({going} = {current} <= {end}; {going}; {going} = {current} != {end} && ({current} += 1, 1)) {{"
                    ));
                } else {
                    self.line(&format!("for (; {current} < {end}; {current} += 1) {{"));
                }
                self.indent += 1;
                self.loop_body(body, Some((binding, current, Type::INT)), false);
                self.indent -= 1;
                self.line("}");
            }
            ForSource::Taken { container, element } => {
                let ty = container.ty;
                let value = self.expr(container);
                if matches!(value, Value::Never) {
                    return;
                }
                // The loop owns the container. Binding an entity element
                // takes it and zeroes its slot, so the container later
                // releases only what the iterations did not take.
                self.scopes.push(Vec::new());
                let container = self.store(ty, value.code().to_owned(), true);
                let container = container.code().to_owned();
                self.own(container.clone(), ty);
                let index = self.counter();
                match *self.types.kind(ty) {
                    TypeKind::List(_) => {
                        self.line(&format!(
                            "for ({index} = 0; {index} < {container}.len; {index} += 1) {{"
                        ));
                        self.indent += 1;
                        self.loop_body(
                            body,
                            Some((binding, format!("{container}.items[{index}]"), *element)),
                            false,
                        );
                    }
                    TypeKind::Map(key, value) => {
                        // Each entry moves into a `(key, value)` tuple that
                        // the iteration owns.
                        let entry_ty = *element;
                        let entry = self.temporary(entry_ty);
                        self.line(&format!(
                            "for ({index} = 0; {index} < {container}.m.used; {index} += 1) {{"
                        ));
                        self.indent += 1;
                        self.line(&format!("if (!{container}.m.live[{index}]) continue;"));
                        let source = format!("&{container}");
                        for (position, (part_ty, part)) in [
                            (key, map_key(self.types, key, &source, &index)),
                            (value, map_value(self.types, value, &source, &index)),
                        ]
                        .into_iter()
                        .enumerate()
                        {
                            if self.types.has_storage(part_ty) {
                                let field = field_code(self.types, entry_ty, 0, position, &entry);
                                self.line(&format!("{field} = {part};"));
                                if self.releases(part_ty) {
                                    self.line(&format!(
                                        "{part} = {};",
                                        zero_value(self.types, part_ty)
                                    ));
                                }
                            }
                        }
                        self.loop_body(body, Some((binding, entry, entry_ty)), true);
                    }
                    _ => unreachable!("the checker iterates lists and maps"),
                }
                self.indent -= 1;
                self.line("}");
                self.close_scope();
            }
            ForSource::Borrowed(place) => {
                let Some((container, ty, _)) = self.place(place) else {
                    return;
                };
                let index = self.counter();
                match *self.types.kind(ty) {
                    TypeKind::List(element) => {
                        self.line(&format!(
                            "for ({index} = 0; {index} < {container}.len; {index} += 1) {{"
                        ));
                        self.indent += 1;
                        self.loop_body(
                            body,
                            Some((binding, format!("{container}.items[{index}]"), element)),
                            false,
                        );
                    }
                    // A borrowed map yields its values.
                    TypeKind::Map(_, value) => {
                        self.line(&format!(
                            "for ({index} = 0; {index} < {container}.m.used; {index} += 1) {{"
                        ));
                        self.indent += 1;
                        self.line(&format!("if (!{container}.m.live[{index}]) continue;"));
                        let part = map_value(self.types, value, &format!("&{container}"), &index);
                        self.loop_body(body, Some((binding, part, value)), false);
                    }
                    _ => unreachable!("the checker iterates lists and maps"),
                }
                self.indent -= 1;
                self.line("}");
            }
        }
    }

    fn expr(&mut self, expression: &Expr) -> Value {
        match &expression.kind {
            ExprKind::Int(value) => Value::Code {
                code: int_literal(*value),
                owned: false,
            },
            ExprKind::Float(value) => Value::Code {
                code: format!("{value:e}"),
                owned: false,
            },
            ExprKind::Bool(value) => Value::Code {
                code: if *value { "true" } else { "false" }.to_owned(),
                owned: false,
            },
            ExprKind::Str(value) => Value::Code {
                code: self.literals.add(value),
                owned: false,
            },
            ExprKind::Unit => Value::Unit,
            ExprKind::Local(local) => {
                if self.types.has_storage(self.function.locals[*local].ty) {
                    Value::Code {
                        code: self.local_code(*local),
                        owned: false,
                    }
                } else {
                    Value::Unit
                }
            }
            ExprKind::Move(place) => {
                let Some((code, ty, _)) = self.place(place) else {
                    return Value::Never;
                };
                let value = self.store(ty, code.clone(), true);
                self.line(&format!("{code} = {};", zero_value(self.types, ty)));
                value
            }
            ExprKind::Call {
                function,
                arguments,
                checks,
                borrow,
            } => self.call(
                *function,
                arguments,
                checks,
                expression.ty,
                borrow.is_some(),
            ),
            // Other borrows are lowered where they appear.
            ExprKind::Borrow(target) => match target.as_ref() {
                BorrowTarget::Place(place) => match self.place(place) {
                    Some((code, _, _)) => Value::Code {
                        code: format!("(&{code})"),
                        owned: false,
                    },
                    None => Value::Never,
                },
                BorrowTarget::Value(_) => unreachable!("only places are returned borrowed"),
            },
            ExprKind::Intrinsic {
                intrinsic,
                arguments,
            } => self.intrinsic(*intrinsic, arguments),
            ExprKind::Unary { operator, operand } => {
                let operand = self.expr(operand);
                if matches!(operand, Value::Never) {
                    return Value::Never;
                }
                let code = match (operator, expression.ty) {
                    (UnaryOperator::Negate, Type::INT) => format!("vt_int_neg({})", operand.code()),
                    (UnaryOperator::Negate, _) => format!("(-{})", operand.code()),
                    (UnaryOperator::Not, _) => format!("(!{})", operand.code()),
                };
                self.store(expression.ty, code, false)
            }
            ExprKind::Binary {
                operator,
                left,
                right,
            } => self.binary(*operator, left, right, expression.ty),
            ExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => self.if_expr(
                condition,
                then_branch,
                else_branch.as_deref(),
                expression.ty,
            ),
            ExprKind::Block(block) => self.block(block),
            ExprKind::Interpolate(parts) => self.interpolate(parts),
            ExprKind::Tuple(elements) => {
                let fields = elements.iter().enumerate().collect::<Vec<_>>();
                self.aggregate(expression.ty, 0, None, &fields)
            }
            ExprKind::Construct {
                variant,
                base,
                fields,
            } => {
                let fields = fields
                    .iter()
                    .map(|(index, value)| (*index, value))
                    .collect::<Vec<_>>();
                self.aggregate(expression.ty, *variant, base.as_deref(), &fields)
            }
            ExprKind::Field { base, index } => self.field(base, *index, expression.ty),
            ExprKind::Match { scrutinee, arms } => self.match_expr(scrutinee, arms, expression.ty),
            ExprKind::List(elements) => self.list(expression.ty, elements),
            ExprKind::EmptyMap => Value::Code {
                code: self.temporary(expression.ty),
                owned: true,
            },
            ExprKind::Index { base, index } => self.index(base, index, expression.ty),
            ExprKind::Builtin {
                builtin,
                receiver,
                arguments,
            } => self.builtin(*builtin, receiver, arguments, expression.ty),
        }
    }

    /// Builds a tuple, struct or enum value from `base` and the given fields,
    /// evaluated in that order.
    fn aggregate(
        &mut self,
        ty: Type,
        variant: usize,
        base: Option<&Expr>,
        fields: &[(usize, &Expr)],
    ) -> Value {
        let base = match base {
            Some(base) => {
                let value = self.expr(base);
                if matches!(value, Value::Never) {
                    return Value::Never;
                }
                Some(self.owned(value, ty))
            }
            None => None,
        };
        let Some(values) = self.operands(fields.iter().map(|(_, field)| *field)) else {
            return Value::Never;
        };
        let values = fields
            .iter()
            .zip(values)
            .map(|((index, field), value)| (*index, field.ty, value))
            .collect::<Vec<_>>();
        let result = self.temporary(ty);
        if let Some(base) = &base {
            self.line(&format!("{result} = {};", base.code()));
        }
        if self.types.is_enum(ty) {
            self.line(&format!("{result}.tag = {variant};"));
        }
        for (index, field_ty, value) in values {
            if matches!(value, Value::Unit) {
                continue;
            }
            let value = self.owned(value, field_ty);
            let target = field_code(self.types, ty, variant, index, &result);
            if base.is_some() && self.releases(field_ty) {
                self.line(&count_line(field_ty, "release", &target));
            }
            self.line(&format!("{target} = {};", value.code()));
        }
        Value::Code {
            code: result,
            owned: true,
        }
    }

    /// Reads a part of `base`: borrowed from a place, or copied out of an
    /// owned value that is then released. An entity part of an owned value
    /// is borrowed and the value lives until the scope ends.
    fn part(&mut self, base: Value, base_ty: Type, part: String, ty: Type) -> Value {
        let Value::Code { code, owned } = base else {
            return base;
        };
        if !self.types.has_storage(ty) {
            self.release(&Value::Code { code, owned }, base_ty);
            return Value::Unit;
        }
        if !owned || !self.releases(base_ty) {
            return Value::Code {
                code: part,
                owned: false,
            };
        }
        if self.types.is_entity(ty) {
            self.defer(Value::Code { code, owned }, base_ty);
            return Value::Code {
                code: part,
                owned: false,
            };
        }
        let result = if self.releases(ty) {
            self.owned(
                Value::Code {
                    code: part,
                    owned: false,
                },
                ty,
            )
        } else {
            self.store(ty, part, false)
        };
        self.release(&Value::Code { code, owned }, base_ty);
        result
    }

    fn field(&mut self, base: &Expr, index: usize, ty: Type) -> Value {
        let value = self.expr(base);
        let Value::Code { code, owned } = value else {
            return value;
        };
        let part = field_code(self.types, base.ty, 0, index, &code);
        self.part(Value::Code { code, owned }, base.ty, part, ty)
    }

    fn index(&mut self, base: &Expr, index: &Expr, ty: Type) -> Value {
        let value = self.expr(base);
        if matches!(value, Value::Never) {
            return Value::Never;
        }
        let position = self.expr(index);
        if matches!(position, Value::Never) {
            self.release(&value, base.ty);
            return Value::Never;
        }
        let container = value.code().to_owned();
        let part = match *self.types.kind(base.ty) {
            TypeKind::Map(key, _) => {
                let key = self.key_operand(position, key);
                let part = self.map_at(&container, base.ty, ty, &key);
                if !self.types.has_storage(ty) {
                    // The lookup still panics for an absent key.
                    self.line(&format!("(void){part};"));
                }
                part
            }
            _ => {
                let position = self.store(Type::INT, position.code().to_owned(), false);
                self.line(&format!(
                    "vt_check_index({}, {container}.len);",
                    position.code()
                ));
                format!("{container}.items[{}]", position.code())
            }
        };
        self.part(value, base.ty, part, ty)
    }

    fn list(&mut self, ty: Type, elements: &[Expr]) -> Value {
        let Some(values) = self.operands(elements) else {
            return Value::Never;
        };
        let result = self.temporary(ty);
        for (value, element_ty) in values.into_iter().zip(elements.iter().map(|e| e.ty)) {
            let argument = match value {
                Value::Unit => String::new(),
                value => {
                    let value = self.owned(value, element_ty);
                    format!(", {}", value.code())
                }
            };
            self.line(&format!("vt_push_T{}(&{result}{argument});", ty.index()));
        }
        Value::Code {
            code: result,
            owned: true,
        }
    }

    fn builtin(
        &mut self,
        builtin: Builtin,
        receiver: &Receiver,
        arguments: &[Expr],
        ty: Type,
    ) -> Value {
        let (code, receiver_ty, receiver_value) = match receiver {
            Receiver::Place(place) => {
                let Some((code, receiver_ty, _)) = self.place(place) else {
                    return Value::Never;
                };
                (code, receiver_ty, None)
            }
            Receiver::Value(value) => {
                let receiver_ty = value.ty;
                let evaluated = self.expr(value);
                if matches!(evaluated, Value::Never) {
                    return Value::Never;
                }
                (evaluated.code().to_owned(), receiver_ty, Some(evaluated))
            }
        };
        let Some(values) = self.operands(arguments) else {
            return Value::Never;
        };
        let values = values
            .into_iter()
            .zip(arguments.iter().map(|argument| argument.ty))
            .collect::<Vec<_>>();
        let n = receiver_ty.index();
        let element = match self.types.kind(receiver_ty) {
            TypeKind::List(element) => Some(*element),
            _ => None,
        };
        let owned_argument = |emitter: &mut Self, position: usize| -> String {
            let (value, value_ty) = values[position].clone();
            match value {
                Value::Unit => String::new(),
                value => format!(", {}", emitter.owned(value, value_ty).code()),
            }
        };
        let result = match builtin {
            _ if builtin != Builtin::Clone
                && matches!(self.types.kind(receiver_ty), TypeKind::Map(..)) =>
            {
                self.map_builtin(builtin, &code, receiver_ty, &values, ty)
            }
            Builtin::Push => {
                let argument = owned_argument(self, 0);
                self.line(&format!("vt_push_T{n}(&{code}{argument});"));
                Value::Unit
            }
            Builtin::Insert => {
                let argument = owned_argument(self, 1);
                self.line(&format!(
                    "vt_insert_T{n}(&{code}, {}{argument});",
                    values[0].0.code()
                ));
                Value::Unit
            }
            Builtin::Clear => {
                self.line(&format!("vt_clear_T{n}(&{code});"));
                Value::Unit
            }
            Builtin::Len => self.store(Type::INT, format!("{code}.len"), false),
            Builtin::IsEmpty => self.store(Type::BOOL, format!("({code}.len == 0)"), false),
            Builtin::Remove => {
                let element = element.expect("remove is a list method");
                if self.types.has_storage(element) {
                    self.store(
                        ty,
                        format!("vt_remove_T{n}(&{code}, {})", values[0].0.code()),
                        true,
                    )
                } else {
                    self.line(&format!(
                        "vt_check_index({0}, {code}.len); {code}.len -= 1;",
                        values[0].0.code()
                    ));
                    Value::Unit
                }
            }
            Builtin::Pop => {
                let element = element.expect("pop is a list method");
                let (some, none) = option_variants(self.types, ty);
                let result = self.temporary(ty);
                self.line(&format!("if ({code}.len == 0) {{"));
                self.line(&format!("    {result}.tag = {none};"));
                self.line("} else {");
                self.line(&format!("    {code}.len -= 1;"));
                self.line(&format!("    {result}.tag = {some};"));
                if self.types.has_storage(element) {
                    self.line(&format!(
                        "    {} = {code}.items[{code}.len];",
                        field_code(self.types, ty, some, 0, &result)
                    ));
                }
                self.line("}");
                Value::Code {
                    code: result,
                    owned: true,
                }
            }
            Builtin::Contains => self.store(
                Type::BOOL,
                format!("vt_contains_T{n}({code}, {})", values[0].0.code()),
                false,
            ),
            Builtin::Clone => {
                if self.types.has_storage(receiver_ty) {
                    self.store(ty, clone_code(self.types, receiver_ty, &code), true)
                } else {
                    Value::Unit
                }
            }
            Builtin::Get | Builtin::ContainsKey | Builtin::Keys => {
                unreachable!("only maps have these methods")
            }
        };
        for (value, value_ty) in &values {
            if !matches!(builtin, Builtin::Push | Builtin::Insert) {
                self.release(value, *value_ty);
            }
        }
        if let Some(receiver_value) = receiver_value {
            self.release(&receiver_value, receiver_ty);
        }
        result
    }

    /// A built-in method other than `clone` of the map `code` of type
    /// `map_ty`, with argument `values`, returning a `ty`. `insert` moves
    /// its key and value into the map; the other methods only read the key.
    fn map_builtin(
        &mut self,
        builtin: Builtin,
        code: &str,
        map_ty: Type,
        values: &[(Value, Type)],
        ty: Type,
    ) -> Value {
        let TypeKind::Map(key_ty, value_ty) = *self.types.kind(map_ty) else {
            unreachable!("only maps get here")
        };
        let n = map_ty.index();
        let map_type = format!("vt_maptype_T{n}()");
        let read_key = |emitter: &mut Self| {
            let key = emitter.entry_temporary(key_ty);
            emitter.line(&format!("{key} = {};", values[0].0.code()));
            key
        };
        // Starts a `Option` result: `Some` with `field` when `test` holds,
        // and `None` otherwise.
        let option = |emitter: &mut Self, test: &str, then: &[String], field: String| {
            let (some, none) = option_variants(emitter.types, ty);
            let result = emitter.temporary(ty);
            emitter.line(&format!("if ({test}) {{"));
            for line in then {
                emitter.line(&format!("    {line}"));
            }
            emitter.line(&format!("    {result}.tag = {some};"));
            if emitter.types.has_storage(value_ty) {
                emitter.line(&format!(
                    "    {} = {field};",
                    field_code(emitter.types, ty, some, 0, &result)
                ));
            }
            emitter.line(&format!("}} else {{ {result}.tag = {none}; }}"));
            Value::Code {
                code: result,
                owned: true,
            }
        };
        match builtin {
            Builtin::Len => self.store(Type::INT, format!("{code}.m.len"), false),
            Builtin::IsEmpty => self.store(Type::BOOL, format!("({code}.m.len == 0)"), false),
            Builtin::Clear => {
                self.line(&format!("vt_clear_T{n}(&{code});"));
                Value::Unit
            }
            Builtin::ContainsKey => {
                let key = read_key(self);
                self.store(
                    Type::BOOL,
                    format!("(vt_map_find(&{code}.m, {map_type}, &{key}) >= 0)"),
                    false,
                )
            }
            Builtin::Get => {
                let key = read_key(self);
                let entry = self.counter();
                self.line(&format!(
                    "{entry} = vt_map_find(&{code}.m, {map_type}, &{key});"
                ));
                let value = map_value(self.types, value_ty, &format!("&{code}"), &entry);
                let field = clone_code(self.types, value_ty, &value);
                option(self, &format!("{entry} >= 0"), &[], field)
            }
            Builtin::Insert => {
                let key = self.entry_operand(values[0].0.clone(), key_ty);
                let value = self.entry_operand(values[1].0.clone(), value_ty);
                let old = self.entry_temporary(value_ty);
                // A present key keeps its stored copy.
                let release_key = if self.releases(key_ty) {
                    vec![count_line(key_ty, "release", &key)]
                } else {
                    Vec::new()
                };
                let test =
                    format!("vt_map_insert(&{code}.m, {map_type}, &{key}, &{value}, &{old})");
                option(self, &test, &release_key, old)
            }
            Builtin::Remove => {
                let key = read_key(self);
                let old_key = self.entry_temporary(key_ty);
                let old = self.entry_temporary(value_ty);
                let release_key = if self.releases(key_ty) {
                    vec![count_line(key_ty, "release", &old_key)]
                } else {
                    Vec::new()
                };
                let test =
                    format!("vt_map_remove(&{code}.m, {map_type}, &{key}, &{old_key}, &{old})");
                option(self, &test, &release_key, old)
            }
            Builtin::Keys => {
                let result = self.temporary(ty);
                let entry = self.counter();
                let key = map_key(self.types, key_ty, &format!("&{code}"), &entry);
                self.line(&format!(
                    "for ({entry} = 0; {entry} < {code}.m.used; {entry} += 1) {{"
                ));
                self.line(&format!(
                    "    if ({code}.m.live[{entry}]) vt_push_T{}(&{result}, {});",
                    ty.index(),
                    clone_code(self.types, key_ty, &key)
                ));
                self.line("}");
                Value::Code {
                    code: result,
                    owned: true,
                }
            }
            _ => unreachable!("not a map method"),
        }
    }

    /// Evaluates the subject of a `match` or destructuring, which the tests
    /// and bindings read, and opens a scope that [`Self::close_scope`]
    /// closes. A borrowed place is matched where it is; any other subject is
    /// kept in a temporary, owned by the new scope if the subject is owned.
    /// Returns `None` if the subject diverges, and its C code if it has
    /// storage.
    fn subject(&mut self, subject: &Expr) -> Option<Option<String>> {
        let value = match &subject.kind {
            ExprKind::Borrow(target) => match target.as_ref() {
                BorrowTarget::Place(place) => {
                    let (code, _, _) = self.place(place)?;
                    self.scopes.push(Vec::new());
                    return Some(self.types.has_storage(subject.ty).then_some(code));
                }
                BorrowTarget::Value(value) => self.expr(value),
            },
            _ => self.expr(subject),
        };
        match value {
            Value::Never => None,
            Value::Unit => {
                self.scopes.push(Vec::new());
                Some(None)
            }
            Value::Code { code, owned } => {
                self.scopes.push(Vec::new());
                let temporary = self.store(subject.ty, code, owned);
                if owned {
                    self.own(temporary.code().to_owned(), subject.ty);
                }
                Some(Some(temporary.code().to_owned()))
            }
        }
    }

    fn match_expr(&mut self, scrutinee: &Expr, arms: &[Arm], ty: Type) -> Value {
        let subject_ty = scrutinee.ty;
        let Some(code) = self.subject(scrutinee) else {
            return Value::Never;
        };
        let result = self.types.has_storage(ty).then(|| self.temporary(ty));
        let end = format!("vt_m{}", self.labels);
        self.labels += 1;
        for arm in arms {
            let test = code.as_deref().map_or_else(
                || "true".to_owned(),
                |code| self.test(&arm.pattern, code, subject_ty),
            );
            self.line(&format!("if ({test}) {{"));
            self.indent += 1;
            self.scopes.push(Vec::new());
            self.bind(&arm.pattern, &code, subject_ty);
            self.register_bindings(&arm.pattern);
            let guard = match &arm.guard {
                Some(guard) => {
                    let value = self.expr(guard);
                    if matches!(value, Value::Never) {
                        None
                    } else {
                        self.line(&format!("if ({}) {{", value.code()));
                        self.indent += 1;
                        Some(())
                    }
                }
                None => None,
            };
            let value = self.expr(&arm.body);
            if !matches!(value, Value::Never) {
                self.assign_branch(result.as_deref(), value, arm.body.ty);
                let depth = self.scopes.len() - 1;
                self.release_scopes_from(depth);
                self.line(&format!("goto {end};"));
            }
            if guard.is_some() {
                self.indent -= 1;
                self.line("}");
                let depth = self.scopes.len() - 1;
                self.release_scopes_from(depth);
            }
            self.scopes.pop();
            self.indent -= 1;
            self.line("}");
        }
        self.line("vt_unreachable();");
        self.line(&format!("{end}:;"));
        self.close_scope();
        match result {
            Some(code) => Value::Code { code, owned: true },
            None if ty == Type::NEVER => Value::Never,
            None => Value::Unit,
        }
    }

    /// A side-effect-free C condition that holds when `pattern` matches `code`.
    fn test(&mut self, pattern: &Pattern, code: &str, ty: Type) -> String {
        match pattern {
            Pattern::Wildcard | Pattern::Binding(_) => "true".to_owned(),
            Pattern::Int(value) => format!("({code} == {})", int_literal(*value)),
            Pattern::Float(value) => format!("({code} == {value:e})"),
            Pattern::Bool(value) => format!("({code} == {value})"),
            Pattern::Str(value) => format!("vt_str_eq({code}, {})", self.literals.add(value)),
            Pattern::Tuple(elements) => {
                let element_types = self.types.components(ty);
                let tests = elements
                    .iter()
                    .zip(element_types)
                    .enumerate()
                    .map(|(index, (element, element_ty))| {
                        let field = field_code(self.types, ty, 0, index, code);
                        self.test(element, &field, element_ty)
                    })
                    .collect::<Vec<_>>();
                conjunction(&tests)
            }
            Pattern::Variant { variant, fields } => {
                let mut tests = vec![format!("({code}.tag == {variant})")];
                for (index, field) in fields {
                    let field_ty = self.types.variants(ty)[*variant].fields[*index].ty;
                    let field_code = field_code(self.types, ty, *variant, *index, code);
                    tests.push(self.test(field, &field_code, field_ty));
                }
                conjunction(&tests)
            }
            Pattern::Or(alternatives) => {
                let tests = alternatives
                    .iter()
                    .map(|alternative| self.test(alternative, code, ty))
                    .collect::<Vec<_>>();
                format!("({})", tests.join(" || "))
            }
        }
    }

    /// Gives the pattern's binding locals the matched parts of `code`: an
    /// entity part is taken and zeroed in the subject, a counted value is
    /// retained, anything else is copied.
    fn bind(&mut self, pattern: &Pattern, code: &Option<String>, ty: Type) {
        let Some(code) = code else {
            return;
        };
        match pattern {
            Pattern::Binding(local) => {
                if self.function.locals[*local].borrow.is_some() {
                    if !self.types.has_storage(ty) {
                        return;
                    }
                    let name = local_name(*local, &self.function.locals[*local].name);
                    self.line(&format!("{name} = &{code};"));
                } else if self.types.has_storage(ty) {
                    let name = self.local_code(*local);
                    self.line(&format!("{name} = {code};"));
                    if self.types.is_entity(ty) {
                        self.line(&format!("{code} = {};", zero_value(self.types, ty)));
                    } else if self.releases(ty) {
                        self.line(&count_line(ty, "retain", &name));
                    }
                }
            }
            Pattern::Tuple(elements) => {
                let element_types = self.types.components(ty);
                for (index, (element, element_ty)) in elements.iter().zip(element_types).enumerate()
                {
                    let field = field_code(self.types, ty, 0, index, code);
                    self.bind(element, &Some(field), element_ty);
                }
            }
            Pattern::Variant { variant, fields } => {
                for (index, field) in fields {
                    let field_ty = self.types.variants(ty)[*variant].fields[*index].ty;
                    let field_code = field_code(self.types, ty, *variant, *index, code);
                    self.bind(field, &Some(field_code), field_ty);
                }
            }
            Pattern::Or(alternatives) => {
                if pattern.bindings().is_empty() {
                    return;
                }
                let mut keyword = "if";
                for alternative in alternatives {
                    let test = self.test(alternative, code, ty);
                    self.line(&format!("{keyword} ({test}) {{"));
                    self.indent += 1;
                    self.bind(alternative, &Some(code.clone()), ty);
                    self.indent -= 1;
                    self.line("}");
                    keyword = "else if";
                }
            }
            Pattern::Wildcard
            | Pattern::Int(_)
            | Pattern::Float(_)
            | Pattern::Bool(_)
            | Pattern::Str(_) => {}
        }
    }

    /// Makes the innermost scope own the binding locals of `pattern`.
    fn register_bindings(&mut self, pattern: &Pattern) {
        for local in pattern.bindings() {
            if self.function.locals[local].borrow.is_some() {
                continue;
            }
            let ty = self.function.locals[local].ty;
            let code = self.local_code(local);
            self.own(code, ty);
        }
    }

    /// Stores `code` in a new temporary so later side effects cannot reorder it.
    fn store(&mut self, ty: Type, code: String, owned: bool) -> Value {
        let temporary = self.temporary(ty);
        self.line(&format!("{temporary} = {code};"));
        Value::Code {
            code: temporary,
            owned,
        }
    }

    fn call(
        &mut self,
        function: usize,
        arguments: &[Expr],
        checks: &[crate::checker::DisjointCheck],
        ty: Type,
        borrowed: bool,
    ) -> Value {
        // The C operands, the values to release after the call, and the
        // index temporaries of each borrowed place.
        let mut operands = Vec::new();
        let mut releases = Vec::new();
        let mut indices = Vec::new();
        for (position, argument) in arguments.iter().enumerate() {
            let ty = argument.ty;
            let mut place_indices = Vec::new();
            let operand = match &argument.kind {
                ExprKind::Borrow(target) => match target.as_ref() {
                    BorrowTarget::Place(place) => {
                        let Some((code, _, evaluated)) = self.place(place) else {
                            return Value::Never;
                        };
                        place_indices = evaluated;
                        self.types.has_storage(ty).then(|| format!("&{code}"))
                    }
                    BorrowTarget::Value(value) => match self.expr(value) {
                        Value::Never => return Value::Never,
                        Value::Unit => None,
                        // A part of a temporary that the scope keeps alive.
                        Value::Code { code, owned: false } if self.types.is_entity(ty) => {
                            Some(format!("&{code}"))
                        }
                        value => {
                            let value = self.owned(value, ty);
                            let temporary = self.store(ty, value.code().to_owned(), true);
                            let operand = format!("&{}", temporary.code());
                            releases.push((temporary, ty));
                            Some(operand)
                        }
                    },
                },
                _ => match self.expr(argument) {
                    Value::Never => return Value::Never,
                    Value::Unit => None,
                    value => {
                        let value = if position + 1 < arguments.len() {
                            self.settle(value, ty)
                        } else {
                            value
                        };
                        let operand = value.code().to_owned();
                        // The callee owns entity arguments and borrows the others.
                        if !self.types.is_entity(ty) {
                            releases.push((value, ty));
                        }
                        Some(operand)
                    }
                },
            };
            operands.extend(operand);
            indices.push(place_indices);
        }
        for check in checks {
            let same = indices[check.first]
                .iter()
                .zip(&indices[check.second])
                .map(|((first, ty), (second, _))| equal_code(self.types, *ty, first, second))
                .collect::<Vec<_>>();
            self.line(&format!(
                "if ({}) vt_panic(\"the same element is borrowed twice\");",
                same.join(" && ")
            ));
        }
        let name = function_name(function, &self.program.functions[function]);
        let code = format!("{name}({})", operands.join(", "));
        let result = if borrowed {
            // The result points at a place that the call borrowed.
            let pointer = format!("t{}", self.temporaries);
            self.temporaries += 1;
            writeln!(
                self.declarations,
                "    {} *{pointer} = NULL;",
                c_type(self.types, ty)
            )
            .unwrap();
            self.line(&format!("{pointer} = {code};"));
            Value::Code {
                code: format!("(*{pointer})"),
                owned: false,
            }
        } else if self.types.has_storage(ty) {
            self.store(ty, code, true)
        } else {
            self.line(&format!("{code};"));
            if ty == Type::NEVER {
                Value::Never
            } else {
                Value::Unit
            }
        };
        for (value, value_ty) in &releases {
            self.release(value, *value_ty);
        }
        result
    }

    fn intrinsic(&mut self, intrinsic: Intrinsic, arguments: &[Expr]) -> Value {
        let Some(values) = self.operands(arguments) else {
            return Value::Never;
        };
        match intrinsic {
            Intrinsic::Print => {
                let text = self.stringify(&values[0], arguments[0].ty);
                self.line(&format!("vt_print({});", text.code()));
                self.release(&text, Type::STR);
                self.release(&values[0], arguments[0].ty);
                Value::Unit
            }
            Intrinsic::Assert => {
                self.line(&format!(
                    "if (!{}) vt_panic_assert({});",
                    values[0].code(),
                    values[1].code()
                ));
                self.release(&values[1], Type::STR);
                Value::Unit
            }
            Intrinsic::Panic => {
                self.line(&format!("vt_panic_str({});", values[0].code()));
                Value::Never
            }
        }
    }

    /// Converts a printable value to a `Str` operand without consuming it.
    fn stringify(&mut self, value: &Value, ty: Type) -> Value {
        match ty {
            Type::STR => Value::Code {
                code: value.code().to_owned(),
                owned: false,
            },
            Type::INT => self.store(Type::STR, format!("vt_int_to_str({})", value.code()), true),
            Type::FLOAT => self.store(
                Type::STR,
                format!("vt_float_to_str({})", value.code()),
                true,
            ),
            Type::BOOL => Value::Code {
                code: format!("vt_bool_to_str({})", value.code()),
                owned: false,
            },
            _ => unreachable!("the checker admits only printable values"),
        }
    }

    fn interpolate(&mut self, parts: &[Expr]) -> Value {
        let Some(values) = self.operands(parts) else {
            return Value::Never;
        };
        let values = values
            .into_iter()
            .zip(parts.iter().map(|part| part.ty))
            .collect::<Vec<_>>();
        let mut texts = Vec::new();
        for (value, ty) in &values {
            texts.push(self.stringify(value, *ty));
        }
        let list = texts.iter().map(Value::code).collect::<Vec<_>>().join(", ");
        let result = self.store(
            Type::STR,
            format!(
                "vt_str_join({}, (vt_str *[]){{{list}}})",
                texts.len().max(1)
            ),
            true,
        );
        for text in &texts {
            self.release(text, Type::STR);
        }
        for (value, ty) in &values {
            self.release(value, *ty);
        }
        result
    }

    fn binary(&mut self, operator: BinaryOperator, left: &Expr, right: &Expr, ty: Type) -> Value {
        use BinaryOperator as Op;
        if matches!(operator, Op::LogicAnd | Op::LogicOr) {
            let left = self.expr(left);
            if matches!(left, Value::Never) {
                return Value::Never;
            }
            let result = self.store(Type::BOOL, left.code().to_owned(), false);
            let test = if operator == Op::LogicAnd {
                result.code().to_owned()
            } else {
                format!("!{}", result.code())
            };
            self.line(&format!("if ({test}) {{"));
            self.indent += 1;
            let right = self.expr(right);
            if !matches!(right, Value::Never) {
                self.line(&format!("{} = {};", result.code(), right.code()));
            }
            self.indent -= 1;
            self.line("}");
            return result;
        }
        let operand_ty = left.ty;
        let left = self.expr(left);
        if matches!(left, Value::Never) {
            return Value::Never;
        }
        let left = self.settle(left, operand_ty);
        let right = self.expr(right);
        if matches!(right, Value::Never) {
            self.release(&left, operand_ty);
            return Value::Never;
        }
        if !self.types.has_storage(operand_ty) {
            let code = if operator == Op::Equal {
                "true"
            } else {
                "false"
            };
            return self.store(ty, code.to_owned(), false);
        }
        let (a, b) = (left.code(), right.code());
        let code = match (operator, operand_ty) {
            (Op::Add, Type::INT) => format!("vt_int_add({a}, {b})"),
            (Op::Subtract, Type::INT) => format!("vt_int_sub({a}, {b})"),
            (Op::Multiply, Type::INT) => format!("vt_int_mul({a}, {b})"),
            (Op::Divide, Type::INT) => format!("vt_int_div({a}, {b})"),
            (Op::Remainder, Type::INT) => format!("vt_int_rem({a}, {b})"),
            (Op::Add, _) => format!("({a} + {b})"),
            (Op::Subtract, _) => format!("({a} - {b})"),
            (Op::Multiply, _) => format!("({a} * {b})"),
            (Op::Divide, _) => format!("({a} / {b})"),
            (Op::Remainder, _) => format!("fmod({a}, {b})"),
            (Op::Equal, _) => equal_code(self.types, operand_ty, a, b),
            (Op::NotEqual, _) => format!("(!{})", equal_code(self.types, operand_ty, a, b)),
            (Op::Less, Type::STR) => format!("(vt_str_compare({a}, {b}) < 0)"),
            (Op::Greater, Type::STR) => format!("(vt_str_compare({a}, {b}) > 0)"),
            (Op::LessEqual, Type::STR) => format!("(vt_str_compare({a}, {b}) <= 0)"),
            (Op::GreaterEqual, Type::STR) => format!("(vt_str_compare({a}, {b}) >= 0)"),
            (Op::Less, _) => format!("({a} < {b})"),
            (Op::Greater, _) => format!("({a} > {b})"),
            (Op::LessEqual, _) => format!("({a} <= {b})"),
            (Op::GreaterEqual, _) => format!("({a} >= {b})"),
            (Op::LogicAnd | Op::LogicOr | Op::RangeExclusive | Op::RangeInclusive, _) => {
                unreachable!("handled above or rejected by the checker")
            }
        };
        let result = self.store(ty, code, false);
        self.release(&left, operand_ty);
        self.release(&right, operand_ty);
        result
    }

    fn if_expr(
        &mut self,
        condition: &Expr,
        then_branch: &Block,
        else_branch: Option<&Expr>,
        ty: Type,
    ) -> Value {
        let condition = self.expr(condition);
        if matches!(condition, Value::Never) {
            return Value::Never;
        }
        let result = self.types.has_storage(ty).then(|| self.temporary(ty));
        self.line(&format!("if ({}) {{", condition.code()));
        self.indent += 1;
        let value = self.block(then_branch);
        self.assign_branch(result.as_deref(), value, then_branch.ty);
        self.indent -= 1;
        if let Some(else_branch) = else_branch {
            self.line("} else {");
            self.indent += 1;
            let value = self.expr(else_branch);
            self.assign_branch(result.as_deref(), value, else_branch.ty);
            self.indent -= 1;
        }
        self.line("}");
        match result {
            Some(code) => Value::Code { code, owned: true },
            None if ty == Type::NEVER => Value::Never,
            None => Value::Unit,
        }
    }

    fn assign_branch(&mut self, result: Option<&str>, value: Value, ty: Type) {
        match (result, value) {
            (Some(result), value @ Value::Code { .. }) => {
                let value = self.owned(value, ty);
                self.line(&format!("{result} = {};", value.code()));
            }
            (None, value @ Value::Code { .. }) => self.release(&value, ty),
            (_, Value::Unit | Value::Never) => {}
        }
    }
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

fn conjunction(tests: &[String]) -> String {
    let tests = tests
        .iter()
        .filter(|test| test.as_str() != "true")
        .cloned()
        .collect::<Vec<_>>();
    if tests.is_empty() {
        "true".to_owned()
    } else {
        format!("({})", tests.join(" && "))
    }
}

/// Whether some path through `body` reaches a `break` of this loop.
fn loop_breaks(body: &Block) -> bool {
    fn block_breaks(block: &Block) -> bool {
        block.statements.iter().any(statement_breaks)
            || block.tail.as_deref().is_some_and(expr_breaks)
    }
    fn statement_breaks(statement: &Statement) -> bool {
        match statement {
            Statement::Break => true,
            Statement::Let { value, .. }
            | Statement::LetPattern { value, .. }
            | Statement::Assign { value, .. } => expr_breaks(value),
            Statement::Expr(value) => expr_breaks(value),
            Statement::Return(value) => value.as_ref().is_some_and(expr_breaks),
            Statement::Continue
            | Statement::While { .. }
            | Statement::Loop(_)
            | Statement::For { .. } => false,
        }
    }
    fn expr_breaks(expression: &Expr) -> bool {
        match &expression.kind {
            ExprKind::Block(block) => block_breaks(block),
            ExprKind::If {
                then_branch,
                else_branch,
                ..
            } => block_breaks(then_branch) || else_branch.as_deref().is_some_and(expr_breaks),
            ExprKind::Match { arms, .. } => arms.iter().any(|arm| expr_breaks(&arm.body)),
            _ => false,
        }
    }
    block_breaks(body)
}

fn int_literal(value: i64) -> String {
    if value == i64::MIN {
        "INT64_MIN".to_owned()
    } else {
        format!("INT64_C({value})")
    }
}
