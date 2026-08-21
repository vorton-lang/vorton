// builtins.ring — Combined translation of builtins-core.ts + builtins-hof.ts
// Registers built-in effects, types, traits, and HOF intrinsics into TypeEnv.

use types::{Type, Effect, EffectRow, StructField, EnumVariant,
    CALLABLE_UNKNOWN,
    INT, FLOAT, STR, BOOL, UNIT, NEVER, EMPTY_ROW,
    BUILTIN_LIST, BUILTIN_MAP, BUILTIN_SET, BUILTIN_OPTION, BUILTIN_CELL,
    make_option_type, make_map_type}
use env::{TypeEnv, TypeScheme, SchemeBound, StructDef, EnumDef,
    EffectDef, EffectOpDef, BuiltInKind, TraitDef, TraitMethodDef,
    ImplEntry, ImplDictBound, MethodOrigin, mono, add_impl,
    install_method_scheme, specialize_trait_method_scheme}
use ast::{span_zero}
use hir::{variant_ctor_name, compare_by_first}
use diagnostics::{CollectingSink}

// ============================================================
// Struct for open_row return value
// ============================================================

struct OpenRow {
    eff: EffectRow,
    tail_id: Int
}

// ============================================================
// Shared built-in method installation
// ============================================================

fn install_builtin_method_map(
    mut env: TypeEnv, sink: CollectingSink,
    target_type_name: Str, origin: Str,
    trait_name: Str?, methods: Map<Str, TypeScheme>
) {
    let span = span_zero()
    let mut entries = methods.entries()
    entries.sort_by(compare_by_first)
    for entry in entries {
        let (method_name, scheme) = entry
        let exact_scheme = match scheme.def_id {
            some(_) => scheme,
            none => TypeScheme {
                ..scheme, def_id: some(env.fresh_def_id())
            }
        }
        let _ = install_method_scheme(
            env.trait_reg, sink,
            target_type_name, method_name, exact_scheme,
            MethodOrigin {
                origin: origin,
                trait_name: trait_name,
                span: span
            })
    }
}

fn builtin_impl_self_type(
    target_type_name: Str, type_args: List<Type>
) -> Type {
    match target_type_name {
        "Int" => INT,
        "Float" => FLOAT,
        "Str" => STR,
        "Bool" => BOOL,
        BUILTIN_OPTION => Type::EnumType {
            name: BUILTIN_OPTION, type_params: type_args
        },
        _ => Type::StructType {
            name: target_type_name, type_params: type_args
        }
    }
}

fn add_builtin_impl(
    mut env: TypeEnv, sink: CollectingSink,
    trait_name: Str, target_type_name: Str,
    type_params: List<Str>, type_var_ids: List<Int>,
    dict_bounds: List<ImplDictBound>,
    method_names: List<Str>
) {
    let origin = "<builtin>:${target_type_name}:${trait_name}"
    let span = span_zero()
    let mut type_args: List<Type> = []
    for type_var_id in type_var_ids {
        type_args.push(Type::TypeVar { id: type_var_id, name: none })
    }
    let self_type = builtin_impl_self_type(target_type_name, type_args)
    let mut scheme_bounds: List<SchemeBound> = []
    for dict_bound in dict_bounds {
        match type_var_ids.get(dict_bound.type_param_index) {
            some(type_var_id) => scheme_bounds.push(SchemeBound {
                type_var: type_var_id,
                trait_name: dict_bound.trait_name,
                assoc_constraints: []
            }),
            none => {}
        }
    }
    let mut exact: Map<Str, TypeScheme> = map_new()
    match env.trait_reg.traits.get(trait_name) {
        some(trait_def) => {
            for method_name in method_names {
                match trait_def.methods.find(fn(method) {
                    method.name == method_name
                }) {
                    some(method) => {
                        let specialized = specialize_trait_method_scheme(
                            trait_def, method, self_type, [],
                            type_var_ids, map_new(), scheme_bounds)
                        exact.insert(method_name, TypeScheme {
                            ..specialized,
                            def_id: some(env.fresh_def_id())
                        })
                    },
                    none => {}
                }
            }
        },
        none => {}
    }
    add_impl(env.trait_reg, ImplEntry {
        trait_name: trait_name,
        target_type_name: target_type_name,
        type_params: type_params,
        dict_bounds: dict_bounds,
        method_names: method_names,
        assoc_types: map_new(),
        method_schemes: map_clone(exact),
        origin: origin,
        span: span
    })
    install_builtin_method_map(
        env, sink, target_type_name, origin,
        some(trait_name), exact)
}

// ============================================================
// Helper: create an open effect row (for HOF effect polymorphism)
// ============================================================

fn open_row(mut env: TypeEnv) -> OpenRow {
    let tail_id = env.fresh_var_id()
    OpenRow {
        eff: EffectRow { effects: [], tail: some(tail_id) },
        tail_id: tail_id
    }
}

// ============================================================
// Helper: make a List<T> struct type from a type variable
// ============================================================

fn make_list_struct(t: Type) -> Type {
    Type::StructType { name: BUILTIN_LIST, type_params: [t] }
}

// ============================================================
// Helper: make a Set<T> struct type from a type variable
// ============================================================

fn make_set_struct(t: Type) -> Type {
    Type::StructType { name: BUILTIN_SET, type_params: [t] }
}

// ============================================================
// Main entry point: register all builtins
// ============================================================

pub fn register_builtins(mut env: TypeEnv, sink: CollectingSink) {
    register_effects(env)
    register_cell(env, sink)
    register_option(env, sink)
    register_eq_trait(env, sink)
    register_option_eq(env, sink)
    register_clone_trait(env, sink)
    register_option_clone(env, sink)
    register_drop_trait(env)
    register_ord_trait(env, sink)
    register_debug_trait(env, sink)
    register_option_debug(env, sink)
    register_hash_trait(env, sink)
    register_mut_methods(env)
    register_ptr_builtins(env, sink)
}

// ============================================================
// Register built-in mut methods (mutating method names per type)
// ============================================================

fn register_mut_methods(mut env: TypeEnv) {
    let mut list_mut: Set<Str> = set_new()
    for m in ["push", "pop", "set", "extend", "reverse", "sort", "shift", "clear", "sort_by"] {
        list_mut.insert(m)
    }
    env.trait_reg.mut_methods.insert("List", list_mut)

    let mut map_mut: Set<Str> = set_new()
    for m in ["insert", "remove", "clear"] {
        map_mut.insert(m)
    }
    env.trait_reg.mut_methods.insert("Map", map_mut)

    let mut set_mut: Set<Str> = set_new()
    for m in ["insert", "remove", "clear"] {
        set_mut.insert(m)
    }
    env.trait_reg.mut_methods.insert("Set", set_mut)
}

// Main entry point: register all HOF intrinsics
pub fn register_hof_intrinsics(mut env: TypeEnv, sink: CollectingSink) {
    register_list_hof(env, sink)
    register_map_hof(env, sink)
    register_set_hof(env, sink)
    register_option_hof(env, sink)
}

// ============================================================
// register_effects: "io" and "fail" built-in effects
// ============================================================

fn register_effects(mut env: TypeEnv) {
    // io effect
    env.types.effects.insert("io", EffectDef {
        name: "io",
        type_params: [],
        type_param_vars: [],
        ops: [
            EffectOpDef { name: "read", def_id: env.fresh_def_id(),
                params: [STR], return_type: STR, has_default: false },
            EffectOpDef { name: "write", def_id: env.fresh_def_id(),
                params: [STR, STR], return_type: UNIT, has_default: false }
        ],
        built_in_kind: some(BuiltInKind::BkIo),
        all_have_defaults: false
    })

    // fail effect
    let fail_t_id = env.fresh_var_id()
    let fail_t = Type::TypeVar { id: fail_t_id, name: none }
    env.types.effects.insert("fail", EffectDef {
        name: "fail",
        type_params: ["E"],
        type_param_vars: [fail_t_id],
        ops: [
            EffectOpDef { name: "raise", def_id: env.fresh_def_id(),
                params: [fail_t], return_type: NEVER, has_default: false }
        ],
        built_in_kind: some(BuiltInKind::BkFail),
        all_have_defaults: false
    })
}

// ============================================================
// register_cell: Cell<T> struct + get/set/update methods
// ============================================================

fn register_cell(mut env: TypeEnv, sink: CollectingSink) {
    // Register Cell struct definition
    let cell_t_id = env.fresh_var_id()
    let cell_t = Type::TypeVar { id: cell_t_id, name: none }
    env.types.structs.insert(BUILTIN_CELL, StructDef {
        name: BUILTIN_CELL,
        type_params: ["T"],
        type_param_vars: [cell_t_id],
        fields: [StructField { name: "value", ty: cell_t, is_pub: true }],
        derive_attrs: [],
        is_extern: false
    })

    // Register Cell constructor function
    let ctor_t_id = env.fresh_var_id()
    let ctor_t = Type::TypeVar { id: ctor_t_id, name: none }
    let ctor_ret = Type::StructType {
        name: BUILTIN_CELL,
        type_params: [ctor_t]
    }
    env.bind(BUILTIN_CELL, TypeScheme {
        ty: Type::FnType { params: [ctor_t], return_type: ctor_ret, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [ctor_t_id],
        bounds: [],
        def_id: none
    })

    // Methods: get, set, update
    let m_t_id = env.fresh_var_id()
    let m_t = Type::TypeVar { id: m_t_id, name: none }
    let mut_row = EffectRow { effects: [Effect::MutEffect { state_type: m_t }], tail: none }
    let self_type = Type::StructType {
        name: BUILTIN_CELL,
        type_params: [m_t]
    }

    let mut methods: Map<Str, TypeScheme> = map_new()

    // get: (Cell<T>) -> T / mut
    methods.insert("get", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: m_t, effects: mut_row, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [m_t_id],
        bounds: [],
        def_id: none
    })

    // set: (Cell<T>, T) -> () / mut
    methods.insert("set", TypeScheme {
        ty: Type::FnType { params: [self_type, m_t], return_type: UNIT, effects: mut_row, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [m_t_id],
        bounds: [],
        def_id: none
    })

    // update: (Cell<T>, (T) -> T) -> () / mut
    let update_cb = Type::FnType { params: [m_t], return_type: m_t, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("update", TypeScheme {
        ty: Type::FnType { params: [self_type, update_cb], return_type: UNIT, effects: mut_row, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [m_t_id],
        bounds: [],
        def_id: none
    })

    install_builtin_method_map(
        env, sink, BUILTIN_CELL, "<builtin-inherent>:Cell:core",
        none, methods)
}

// ============================================================
// register_option: Option<T> enum + some/none constructors + methods
// ============================================================

fn register_option(mut env: TypeEnv, sink: CollectingSink) {
    // Register Option enum definition
    let option_t_id = env.fresh_var_id()
    let option_t = Type::TypeVar { id: option_t_id, name: none }
    let mut option_vi: Map<Str, Int> = map_new()
    option_vi.insert("some", 0)
    option_vi.insert("none", 1)
    env.types.enums.insert(BUILTIN_OPTION, EnumDef {
        name: BUILTIN_OPTION,
        type_params: ["T"],
        type_param_vars: [option_t_id],
        variants: [
            EnumVariant { name: "some", fields: [option_t], field_names: none },
            EnumVariant { name: "none", fields: [], field_names: none }
        ],
        derive_attrs: [],
        variant_index: option_vi
    })

    env.types.variant_to_enum.insert("some", BUILTIN_OPTION)
    env.types.variant_to_enum.insert("none", BUILTIN_OPTION)

    // some constructor: (T) -> Option<T>
    let some_t_id = env.fresh_var_id()
    let some_t = Type::TypeVar { id: some_t_id, name: none }
    env.bind("some", TypeScheme {
        ty: Type::FnType { params: [some_t], return_type: make_option_type(some_t), effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [some_t_id],
        bounds: [],
        def_id: none
    })
    // `some` is a normal payload constructor. Preserve exact constructor
    // identity through its DefId so call lowering and sink classification do
    // not depend on a same-spelled local/global.
    match env.lookup("some") {
        some(scheme) => match scheme.def_id {
            some(def_id) => {
                env.types.variant_ctor_origins.insert(def_id,
                    variant_ctor_name(BUILTIN_OPTION, "some"))
            },
            none => {}
        },
        none => {}
    }

    // none: Option<T> (not a function, just a polymorphic value)
    let none_t_id = env.fresh_var_id()
    let none_t = Type::TypeVar { id: none_t_id, name: none }
    env.bind("none", TypeScheme {
        ty: make_option_type(none_t),
        type_vars: [none_t_id],
        bounds: [],
        def_id: none
    })
    // `none` still needs its exact canonical identity so both backends select
    // the runtime singleton symbol. Ownership freshness is classified
    // separately: is_nullary_variant_ctor_ident excludes this one borrowed
    // built-in constructor result.
    match env.lookup("none") {
        some(scheme) => match scheme.def_id {
            some(def_id) => {
                env.types.variant_ctor_origins.insert(def_id,
                    variant_ctor_name(BUILTIN_OPTION, "none"))
            },
            none => {}
        },
        none => {}
    }

    // Option methods: is_some, is_none, unwrap_or
    let mut methods: Map<Str, TypeScheme> = map_new()

    let t_id = env.fresh_var_id()
    let t = Type::TypeVar { id: t_id, name: none }
    let self_type = make_option_type(t)

    methods.insert("is_some", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: BOOL, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    methods.insert("is_none", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: BOOL, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    methods.insert("unwrap_or", TypeScheme {
        ty: Type::FnType { params: [self_type, t], return_type: t, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    methods.insert("unwrap", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: t, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    let e_id = env.fresh_var_id()
    let e = Type::TypeVar { id: e_id, name: none }
    let self_type2 = make_option_type(Type::TypeVar { id: t_id, name: none })
    let fail_eff = Effect::FailEffect { error_type: e }
    methods.insert("to_fail", TypeScheme {
        ty: Type::FnType { params: [self_type2, e], return_type: Type::TypeVar { id: t_id, name: none }, effects: EffectRow { effects: [fail_eff], tail: none }, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, e_id],
        bounds: [],
        def_id: none
    })
    install_builtin_method_map(
        env, sink, BUILTIN_OPTION, "<builtin-inherent>:Option:core",
        none, methods)
}

// ============================================================
// register_eq_trait: Eq trait + primitive impls
// ============================================================

fn register_eq_trait(mut env: TypeEnv, sink: CollectingSink) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let eq_fn = Type::FnType { params: [self_var, self_var], return_type: BOOL, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN }
    let ne_fn = Type::FnType { params: [self_var, self_var], return_type: BOOL, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN }

    env.trait_reg.traits.insert("Eq", TraitDef {
        name: "Eq",
        type_params: [],
        type_param_vars: [self_var_id],
        methods: [
            TraitMethodDef { name: "eq", def_id: env.fresh_def_id(),
                ty: eq_fn, has_default: false, param_mutabilities: [false, false], method_type_params: [] },
            TraitMethodDef { name: "ne", def_id: env.fresh_def_id(),
                ty: ne_fn, has_default: true, param_mutabilities: [false, false], method_type_params: [] }
        ],
        supertraits: [],
        assoc_types: []
    })

    // Register Eq impls for primitive types
    for prim in ["Int", "Float", "Str", "Bool"] {
        add_builtin_impl(env, sink, "Eq", prim, [], [], [], ["eq", "ne"])
    }
}

// ============================================================
// register_option_eq: Option<T: Eq> Eq impl
// ============================================================

fn register_option_eq(mut env: TypeEnv, sink: CollectingSink) {
    let t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Eq", BUILTIN_OPTION, ["T"], [t_id],
        [ImplDictBound { type_param_index: 0, trait_name: "Eq" }],
        ["eq", "ne"])
}

// ============================================================
// register_clone_trait: Clone trait + primitive + collection impls
// ============================================================

fn register_clone_trait(mut env: TypeEnv, sink: CollectingSink) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let clone_fn = Type::FnType { params: [self_var], return_type: self_var, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN }

    env.trait_reg.traits.insert("Clone", TraitDef {
        name: "Clone",
        type_params: [],
        type_param_vars: [self_var_id],
        methods: [
            TraitMethodDef { name: "clone", def_id: env.fresh_def_id(),
                ty: clone_fn, has_default: false, param_mutabilities: [false], method_type_params: [] }
        ],
        supertraits: [],
        assoc_types: []
    })

    // Primitive impls
    for prim in ["Int", "Float", "Str", "Bool"] {
        add_builtin_impl(env, sink, "Clone", prim, [], [], [], ["clone"])
    }

    // Collection impls
    let list_t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Clone", BUILTIN_LIST,
        ["T"], [list_t_id], [], ["clone"])
    let map_k_id = env.fresh_var_id()
    let map_v_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Clone", BUILTIN_MAP,
        ["K", "V"], [map_k_id, map_v_id], [], ["clone"])
    let set_t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Clone", BUILTIN_SET,
        ["T"], [set_t_id], [], ["clone"])
}

// ============================================================
// register_drop_trait: Drop trait (B-002p1)
// ============================================================

fn register_drop_trait(mut env: TypeEnv) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    // drop(self) -> Unit, with {io} effect (allows flush/log/close)
    let io_row = EffectRow { effects: [Effect::IoEffect], tail: none }
    let drop_fn = Type::FnType { params: [self_var], return_type: UNIT, effects: io_row, ownership_term: CALLABLE_UNKNOWN }

    env.trait_reg.traits.insert("Drop", TraitDef {
        name: "Drop",
        type_params: [],
        type_param_vars: [self_var_id],
        methods: [
            TraitMethodDef { name: "drop", def_id: env.fresh_def_id(),
                ty: drop_fn, has_default: false, param_mutabilities: [false], method_type_params: [] }
        ],
        supertraits: [],
        assoc_types: []
    })
}

// ============================================================
// register_option_clone: Option<T: Clone> Clone impl
// ============================================================

fn register_option_clone(mut env: TypeEnv, sink: CollectingSink) {
    let t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Clone", BUILTIN_OPTION, ["T"], [t_id],
        [ImplDictBound { type_param_index: 0, trait_name: "Clone" }],
        ["clone"])
}

// ============================================================
// register_ord_trait: Ord trait + primitive impls
// ============================================================

fn register_ord_trait(mut env: TypeEnv, sink: CollectingSink) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let cmp_fn = Type::FnType { params: [self_var, self_var], return_type: INT, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN }

    env.trait_reg.traits.insert("Ord", TraitDef {
        name: "Ord",
        type_params: [],
        type_param_vars: [self_var_id],
        methods: [
            TraitMethodDef { name: "cmp", def_id: env.fresh_def_id(),
                ty: cmp_fn, has_default: false, param_mutabilities: [false, false], method_type_params: [] }
        ],
        supertraits: [],
        assoc_types: []
    })

    for prim in ["Int", "Float", "Str", "Bool"] {
        add_builtin_impl(env, sink, "Ord", prim, [], [], [], ["cmp"])
    }
}

// ============================================================
// register_debug_trait: Debug trait + primitive + collection impls
// ============================================================

fn register_debug_trait(mut env: TypeEnv, sink: CollectingSink) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let debug_fn = Type::FnType { params: [self_var], return_type: STR, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN }

    env.trait_reg.traits.insert("Debug", TraitDef {
        name: "Debug",
        type_params: [],
        type_param_vars: [self_var_id],
        methods: [
            TraitMethodDef { name: "debug", def_id: env.fresh_def_id(),
                ty: debug_fn, has_default: false, param_mutabilities: [false], method_type_params: [] }
        ],
        supertraits: [],
        assoc_types: []
    })

    // Primitive impls
    for prim in ["Int", "Float", "Str", "Bool"] {
        add_builtin_impl(env, sink, "Debug", prim, [], [], [], ["debug"])
    }

    // List<T: Debug> Debug impl
    let list_t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Debug", BUILTIN_LIST,
        ["T"], [list_t_id],
        [ImplDictBound { type_param_index: 0, trait_name: "Debug" }],
        ["debug"])

    // Map<K, V> Debug impl (no bounds required in TS source)
    let map_k_id = env.fresh_var_id()
    let map_v_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Debug", BUILTIN_MAP,
        ["K", "V"], [map_k_id, map_v_id], [], ["debug"])

    // Set<T> Debug impl (no bounds required in TS source)
    let set_t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Debug", BUILTIN_SET,
        ["T"], [set_t_id], [], ["debug"])
}

// ============================================================
// register_option_debug: Option<T: Debug> Debug impl
// ============================================================

fn register_option_debug(mut env: TypeEnv, sink: CollectingSink) {
    let t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Debug", BUILTIN_OPTION, ["T"], [t_id],
        [ImplDictBound { type_param_index: 0, trait_name: "Debug" }],
        ["debug"])
}

// ============================================================
// register_hash_trait: Hash trait + primitive impls
// ============================================================

fn register_hash_trait(mut env: TypeEnv, sink: CollectingSink) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let hash_fn = Type::FnType { params: [self_var], return_type: INT, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN }

    env.trait_reg.traits.insert("Hash", TraitDef {
        name: "Hash",
        type_params: [],
        type_param_vars: [self_var_id],
        methods: [
            TraitMethodDef { name: "hash", def_id: env.fresh_def_id(),
                ty: hash_fn, has_default: false, param_mutabilities: [false], method_type_params: [] }
        ],
        supertraits: [],
        assoc_types: []
    })

    for prim in ["Int", "Str", "Bool"] {
        add_builtin_impl(env, sink, "Hash", prim, [], [], [], ["hash"])
    }
}

// ============================================================
// HOF: register_list_hof
// ============================================================

fn register_list_hof(mut env: TypeEnv, sink: CollectingSink) {
    let mut methods: Map<Str, TypeScheme> = map_new()

    // map: (List<T>, (T) -> U / e) -> List<U> / e
    let mut t_id = env.fresh_var_id()
    let mut t = Type::TypeVar { id: t_id, name: none }
    let mut u_id = env.fresh_var_id()
    let mut u = Type::TypeVar { id: u_id, name: none }
    let mut orow = open_row(env)
    let mut cb = Type::FnType { params: [t], return_type: u, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("map", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_list_struct(u), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // filter: (List<T>, (T) -> Bool / e) -> List<T> / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("filter", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_list_struct(t), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // flat_map: (List<T>, (T) -> List<U> / e) -> List<U> / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    u_id = env.fresh_var_id()
    u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: make_list_struct(u), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("flat_map", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_list_struct(u), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // fold: (List<T>, U, (U, T) -> U / e) -> U / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    u_id = env.fresh_var_id()
    u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [u, t], return_type: u, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("fold", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), u, cb], return_type: u, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // any: (List<T>, (T) -> Bool / e) -> Bool / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("any", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // all: (List<T>, (T) -> Bool / e) -> Bool / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("all", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // find: (List<T>, (T) -> Bool / e) -> Option<T> / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("find", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_option_type(t), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // find_index: (List<T>, (T) -> Bool / e) -> Option<Int> / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("find_index", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_option_type(INT), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // sort_by: (List<T>, (T, T) -> Int / e) -> () / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t, t], return_type: INT, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("sort_by", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: UNIT, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })
    install_builtin_method_map(
        env, sink, BUILTIN_LIST, "<std-predecl>:List:unbounded",
        none, methods)
}

// ============================================================
// HOF: register_map_hof
// ============================================================

fn register_map_hof(mut env: TypeEnv, sink: CollectingSink) {
    let mut methods: Map<Str, TypeScheme> = map_new()

    // map_values: (Map<K,V>, (V) -> U / e) -> Map<K,U> / e
    let mut k_id = env.fresh_var_id()
    let mut k = Type::TypeVar { id: k_id, name: none }
    let mut v_id = env.fresh_var_id()
    let mut v = Type::TypeVar { id: v_id, name: none }
    let mut u_id = env.fresh_var_id()
    let mut u = Type::TypeVar { id: u_id, name: none }
    let mut orow = open_row(env)
    let mut cb = Type::FnType { params: [v], return_type: u, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("map_values", TypeScheme {
        ty: Type::FnType { params: [make_map_type(k, v), cb], return_type: make_map_type(k, u), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [k_id, v_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // filter: (Map<K,V>, (K, V) -> Bool / e) -> Map<K,V> / e
    k_id = env.fresh_var_id()
    k = Type::TypeVar { id: k_id, name: none }
    v_id = env.fresh_var_id()
    v = Type::TypeVar { id: v_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [k, v], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("filter", TypeScheme {
        ty: Type::FnType { params: [make_map_type(k, v), cb], return_type: make_map_type(k, v), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [k_id, v_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // fold: (Map<K,V>, U, (U, K, V) -> U / e) -> U / e
    k_id = env.fresh_var_id()
    k = Type::TypeVar { id: k_id, name: none }
    v_id = env.fresh_var_id()
    v = Type::TypeVar { id: v_id, name: none }
    u_id = env.fresh_var_id()
    u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [u, k, v], return_type: u, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("fold", TypeScheme {
        ty: Type::FnType { params: [make_map_type(k, v), u, cb], return_type: u, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [k_id, v_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // any: (Map<K,V>, (K, V) -> Bool / e) -> Bool / e
    k_id = env.fresh_var_id()
    k = Type::TypeVar { id: k_id, name: none }
    v_id = env.fresh_var_id()
    v = Type::TypeVar { id: v_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [k, v], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("any", TypeScheme {
        ty: Type::FnType { params: [make_map_type(k, v), cb], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [k_id, v_id, orow.tail_id],
        bounds: [],
        def_id: none
    })
    let mut unbounded_methods: Map<Str, TypeScheme> = map_new()
    let mut bounded_methods: Map<Str, TypeScheme> = map_new()
    for entry in methods.entries() {
        let (method_name, scheme) = entry
        if method_name == "filter" || method_name == "map_values" {
            bounded_methods.insert(method_name, scheme)
        } else {
            unbounded_methods.insert(method_name, scheme)
        }
    }
    install_builtin_method_map(
        env, sink, BUILTIN_MAP, "<std-predecl>:Map:unbounded",
        none, unbounded_methods)
    install_builtin_method_map(
        env, sink, BUILTIN_MAP, "<std-predecl>:Map:bounded",
        none, bounded_methods)
}

// ============================================================
// HOF: register_set_hof
// ============================================================

fn register_set_hof(mut env: TypeEnv, sink: CollectingSink) {
    let mut methods: Map<Str, TypeScheme> = map_new()

    // filter: (Set<T>, (T) -> Bool / e) -> Set<T> / e
    let mut t_id = env.fresh_var_id()
    let mut t = Type::TypeVar { id: t_id, name: none }
    let mut orow = open_row(env)
    let mut cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("filter", TypeScheme {
        ty: Type::FnType { params: [make_set_struct(t), cb], return_type: make_set_struct(t), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, orow.tail_id],
        bounds: [
            SchemeBound { type_var: t_id, trait_name: "Hash", assoc_constraints: [] },
            SchemeBound { type_var: t_id, trait_name: "Eq", assoc_constraints: [] }
        ],
        def_id: none
    })

    // fold: (Set<T>, U, (U, T) -> U / e) -> U / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    let u_id = env.fresh_var_id()
    let u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [u, t], return_type: u, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("fold", TypeScheme {
        ty: Type::FnType { params: [make_set_struct(t), u, cb], return_type: u, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // any: (Set<T>, (T) -> Bool / e) -> Bool / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("any", TypeScheme {
        ty: Type::FnType { params: [make_set_struct(t), cb], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // all: (Set<T>, (T) -> Bool / e) -> Bool / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("all", TypeScheme {
        ty: Type::FnType { params: [make_set_struct(t), cb], return_type: BOOL, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })
    let mut unbounded_methods: Map<Str, TypeScheme> = map_new()
    let mut bounded_methods: Map<Str, TypeScheme> = map_new()
    for entry in methods.entries() {
        let (method_name, scheme) = entry
        if method_name == "filter" {
            bounded_methods.insert(method_name, scheme)
        } else {
            unbounded_methods.insert(method_name, scheme)
        }
    }
    install_builtin_method_map(
        env, sink, BUILTIN_SET, "<std-predecl>:Set:unbounded",
        none, unbounded_methods)
    install_builtin_method_map(
        env, sink, BUILTIN_SET, "<std-predecl>:Set:bounded",
        none, bounded_methods)
}

// ============================================================
// HOF: register_option_hof
// ============================================================

fn register_option_hof(mut env: TypeEnv, sink: CollectingSink) {
    let mut methods: Map<Str, TypeScheme> = map_new()

    // map: (Option<T>, (T) -> U / e) -> Option<U> / e
    let mut t_id = env.fresh_var_id()
    let mut t = Type::TypeVar { id: t_id, name: none }
    let mut u_id = env.fresh_var_id()
    let mut u = Type::TypeVar { id: u_id, name: none }
    let mut orow = open_row(env)
    let mut cb = Type::FnType { params: [t], return_type: u, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("map", TypeScheme {
        ty: Type::FnType { params: [make_option_type(t), cb], return_type: make_option_type(u), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // and_then: (Option<T>, (T) -> Option<U> / e) -> Option<U> / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    u_id = env.fresh_var_id()
    u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: make_option_type(u), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("and_then", TypeScheme {
        ty: Type::FnType { params: [make_option_type(t), cb], return_type: make_option_type(u), effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // unwrap_or_else: (Option<T>, () -> T / e) -> T / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [], return_type: t, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN }
    methods.insert("unwrap_or_else", TypeScheme {
        ty: Type::FnType { params: [make_option_type(t), cb], return_type: t, effects: orow.eff, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })
    install_builtin_method_map(
        env, sink, BUILTIN_OPTION, "<builtin-inherent>:Option:hof",
        none, methods)
}

// ============================================================
// B-125: register Ptr<T> builtin functions and methods
// ============================================================

fn register_ptr_builtins(mut env: TypeEnv, sink: CollectingSink) {
    let unsafe_row = EffectRow { effects: [Effect::UnsafeEffect], tail: none }

    // ---- Top-level builtin functions ----

    // alloc(count: Int) -> Ptr<T> / unsafe
    let alloc_t_id = env.fresh_var_id()
    let alloc_t = Type::TypeVar { id: alloc_t_id, name: none }
    let alloc_ptr = Type::PtrType { pointee: alloc_t }
    env.bind("alloc", TypeScheme {
        ty: Type::FnType { params: [INT], return_type: alloc_ptr, effects: unsafe_row, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [alloc_t_id],
        bounds: [],
        def_id: none
    })

    // dealloc(p: Ptr<T>, count: Int) -> () / unsafe
    let dealloc_t_id = env.fresh_var_id()
    let dealloc_t = Type::TypeVar { id: dealloc_t_id, name: none }
    let dealloc_ptr = Type::PtrType { pointee: dealloc_t }
    env.bind("dealloc", TypeScheme {
        ty: Type::FnType { params: [dealloc_ptr, INT], return_type: UNIT, effects: unsafe_row, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [dealloc_t_id],
        bounds: [],
        def_id: none
    })

    // ptr_copy(src: Ptr<T>, dst: Ptr<T>, count: Int) -> () / unsafe
    let copy_t_id = env.fresh_var_id()
    let copy_t = Type::TypeVar { id: copy_t_id, name: none }
    let copy_ptr = Type::PtrType { pointee: copy_t }
    env.bind("ptr_copy", TypeScheme {
        ty: Type::FnType { params: [copy_ptr, copy_ptr, INT], return_type: UNIT, effects: unsafe_row, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [copy_t_id],
        bounds: [],
        def_id: none
    })

    // ptr_from_addr(a: Int) -> Ptr<T> (safe)
    let from_t_id = env.fresh_var_id()
    let from_t = Type::TypeVar { id: from_t_id, name: none }
    let from_ptr = Type::PtrType { pointee: from_t }
    env.bind("ptr_from_addr", TypeScheme {
        ty: Type::FnType { params: [INT], return_type: from_ptr, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [from_t_id],
        bounds: [],
        def_id: none
    })

    // ---- Ptr<T> methods ----

    let mut methods: Map<Str, TypeScheme> = map_new()

    // read: (Ptr<T>) -> T / unsafe
    let read_t_id = env.fresh_var_id()
    let read_t = Type::TypeVar { id: read_t_id, name: none }
    let read_ptr = Type::PtrType { pointee: read_t }
    methods.insert("read", TypeScheme {
        ty: Type::FnType { params: [read_ptr], return_type: read_t, effects: unsafe_row, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [read_t_id],
        bounds: [],
        def_id: none
    })

    // take: (Ptr<T>) -> T / unsafe
    let take_t_id = env.fresh_var_id()
    let take_t = Type::TypeVar { id: take_t_id, name: none }
    let take_ptr = Type::PtrType { pointee: take_t }
    methods.insert("take", TypeScheme {
        ty: Type::FnType { params: [take_ptr], return_type: take_t, effects: unsafe_row, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [take_t_id],
        bounds: [],
        def_id: none
    })

    // write: (Ptr<T>, T) -> () / unsafe
    let write_t_id = env.fresh_var_id()
    let write_t = Type::TypeVar { id: write_t_id, name: none }
    let write_ptr = Type::PtrType { pointee: write_t }
    methods.insert("write", TypeScheme {
        ty: Type::FnType { params: [write_ptr, write_t], return_type: UNIT, effects: unsafe_row, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [write_t_id],
        bounds: [],
        def_id: none
    })

    // offset: (Ptr<T>, Int) -> Ptr<T> / unsafe
    let off_t_id = env.fresh_var_id()
    let off_t = Type::TypeVar { id: off_t_id, name: none }
    let off_ptr = Type::PtrType { pointee: off_t }
    methods.insert("offset", TypeScheme {
        ty: Type::FnType { params: [off_ptr, INT], return_type: off_ptr, effects: unsafe_row, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [off_t_id],
        bounds: [],
        def_id: none
    })

    // cast: (Ptr<T>) -> Ptr<U> (safe)
    let cast_t_id = env.fresh_var_id()
    let cast_t = Type::TypeVar { id: cast_t_id, name: none }
    let cast_u_id = env.fresh_var_id()
    let cast_u = Type::TypeVar { id: cast_u_id, name: none }
    let cast_ptr_t = Type::PtrType { pointee: cast_t }
    let cast_ptr_u = Type::PtrType { pointee: cast_u }
    methods.insert("cast", TypeScheme {
        ty: Type::FnType { params: [cast_ptr_t], return_type: cast_ptr_u, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [cast_t_id, cast_u_id],
        bounds: [],
        def_id: none
    })

    // addr: (Ptr<T>) -> Int (safe)
    let addr_t_id = env.fresh_var_id()
    let addr_t = Type::TypeVar { id: addr_t_id, name: none }
    let addr_ptr = Type::PtrType { pointee: addr_t }
    methods.insert("addr", TypeScheme {
        ty: Type::FnType { params: [addr_ptr], return_type: INT, effects: EMPTY_ROW, ownership_term: CALLABLE_UNKNOWN },
        type_vars: [addr_t_id],
        bounds: [],
        def_id: none
    })
    install_builtin_method_map(
        env, sink, "Ptr", "<builtin-inherent>:Ptr:core",
        none, methods)
}
