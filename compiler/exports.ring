use types::{Type, Effect}
use ast::{Program, Decl, UseDecl, UseImport, NamedImport}
use hir::{HProgram, HDecl, ValueBindingKind, ModuleImplFact, compare_by_first}
use diagnostics::{CollectingSink, DiagnosticContext, Severity, make_diag}
use codes::{E0703}
use env::{TypeEnv, TypeScheme, StructDef, EnumDef, EffectDef, TraitDef, ImplEntry,
    TypeAliasDef, EffectAliasDef,
    PhysicalNominalFact, make_physical_struct_fact,
    make_physical_enum_fact, physical_nominal_owner,
    physical_nominal_name, physical_nominal_is_struct,
    physical_nominal_drop_method, physical_nominal_dependency_owners,
    physical_nominal_owner_for_type, localize_physical_nominal_fact,
    find_impl_by_provider,
    impl_entry_exact_key_same, impl_entry_final_same,
    optional_symbol_ref_same}
use ir_identity::{SymbolRef, ImplMethodRef, RegisteredNominalRef,
    impl_provider_ref_same, impl_owner_ref_same,
    impl_owner_ref_target,
    impl_method_ref_owner, impl_method_ref_name, impl_method_ref_same,
    variant_ref_owner, variant_ref_member,
    registered_nominal_ref_same, registered_nominal_ref_symbol,
    registered_nominal_ref_display_name,
    registered_trait_ref_symbol,
    symbol_ref_same, symbol_ref_canonical_payload}
use infer_register::{prefix_decl_name, module_prefix_decl_name}
use effect_contract::{empty_typed_effect_header_schema}

// ============================================================
// ModuleExports — the public interface of a compiled module
// ============================================================

pub struct ModuleExports {
    pub module_key: Str,
    pub module_prefix: Str,
    pub values: Map<Str, TypeScheme>,
    pub value_symbols: Map<Str, SymbolRef>,
    // Exact registration kind for public value bindings. Absence is a local
    // borrow; constructor identity travels in value_symbols.
    pub value_binding_kinds: Map<Str, ValueBindingKind>,
    pub types: Map<Str, TypeDef>,
    pub type_aliases: Map<Str, TypeAliasDef>,
    pub effects: Map<Str, EffectDef>,
    pub effect_aliases: Map<Str, EffectAliasDef>,
    pub traits: Map<Str, TraitDef>,
    pub trait_impls: List<ImplEntry>,
    pub method_index: Map<Str, Map<Str, ImplMethodRef>>,
    pub inherent_methods: Map<Str, List<Str>>,
    pub struct_field_orders: Map<Str, List<Str>>,
    pub extern_values: Set<Str>,
    pub mut_methods: Map<Str, Set<Str>>,
    pub fn_mut_params: Map<Str, List<Bool>>,
    physical_nominals: List<PhysicalNominalFact>
}

pub enum TypeDef {
    StructDef_(StructDef),
    EnumDef_(EnumDef)
}

fn export_display_name(identity: Str) -> Str {
    let parts = identity.split("$$_")
    if parts.len() > 1 { parts.get(1).unwrap_or(identity) } else { identity }
}

// ============================================================
// extract_decl_export — recursive helper for extract_exports
// Handles a single declaration, inserting its public exports
// into the collector maps. For ModBlock decls, recurses to
// support arbitrary nesting depth.
// ============================================================

fn append_identity(prefix: Str, name: Str) -> Str {
    if prefix.ends_with("$$_") { "${prefix}${name}" } else { "${prefix}::${name}" }
}

fn identity_leaf(identity: Str) -> Str {
    let inline_parts = identity.split("::")
    let inline_leaf = inline_parts.get(inline_parts.len() - 1).unwrap_or(identity)
    let file_parts = inline_leaf.split("$$_")
    file_parts.get(file_parts.len() - 1).unwrap_or(inline_leaf)
}

// Raw extern identities deliberately omit the file/inline owner. A fallback
// from an exact canonical source is therefore valid only when the current
// file's AST proves that the complete `$$_mod::...::item` path ends at an
// ExternType declaration. Matching the leaf alone would let a prelude extern
// or an unrelated sibling satisfy a private inline re-export.
fn decl_path_is_extern_type(
    decls: List<Decl>, path: List<Str>, path_index: Int
) -> Bool {
    if path_index < 0 || path_index >= path.len() { return false }
    let expected = path.get(path_index).unwrap_or("")
    let is_leaf = path_index == path.len() - 1
    for decl in decls {
        if is_leaf {
            match decl {
                Decl::ExternType { name, .. } => {
                    if name == expected { return true }
                },
                _ => {}
            }
        } else {
            match decl {
                Decl::ModBlock { name, decls: nested, .. } => {
                    if name == expected &&
                       decl_path_is_extern_type(
                           nested, path, path_index + 1) {
                        return true
                    }
                },
                _ => {}
            }
        }
    }
    false
}

fn program_declares_exact_extern_source(
    program: Program, source: Str
) -> Bool {
    let identity_parts = source.split("$$_")
    if identity_parts.len() != 2 { return false }
    let relative = identity_parts.get(1).unwrap_or("")
    if relative == "" { return false }
    let path = relative.split("::")
    if path.len() == 0 { return false }
    decl_path_is_extern_type(program.decls, path, 0)
}

fn declared_value_kind(kinds: Map<Int, ValueBindingKind>, scheme: TypeScheme) -> ValueBindingKind? {
    match scheme.def_id {
        some(def_id) => kinds.get(def_id),
        none => none
    }
}

fn exact_scheme_value_symbol(
    symbols: Map<Int, SymbolRef>, scheme: TypeScheme
) -> SymbolRef {
    let def_id = match scheme.def_id {
        some(value) => value,
        none => panic("module export: value scheme lacks exact DefId")
    }
    match symbols.get(def_id) {
        some(value) => value,
        none => panic("module export: value DefId lacks exact SymbolRef")
    }
}

// Reconstruct an enum constructor from its canonical definition. Looking up the
// variant leaf in the value environment is unsound: a later module-local value
// with the same spelling may shadow that leaf while the public enum must still
// export its own constructor. Consumers allocate a fresh local DefId, so export
// schemes deliberately carry none here.
fn variant_ctor_scheme(def: EnumDef) -> TypeScheme {
    let enum_params = def.type_param_vars.map(fn(id) {
        Type::TypeVar { id: id, name: none }
    })
    let enum_type = Type::EnumType { name: def.name, type_params: enum_params }
    TypeScheme {
        ty: enum_type,
        type_vars: list_clone(def.type_param_vars),
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    }
}

pub fn module_export_physical_nominals(
    value: ModuleExports
) -> List<PhysicalNominalFact> {
    value.physical_nominals.map(fn(item) { item })
}

fn physical_drop_method(
    env: TypeEnv, nominal_owner: RegisteredNominalRef
) -> ImplMethodRef? {
    let drop_trait = match env.trait_reg.traits.get("Drop") {
        some(def) => registered_trait_ref_symbol(def.owner_ref),
        none => panic("physical nominal export: Drop trait owner is absent")
    }
    let target = registered_nominal_ref_symbol(nominal_owner)
    let mut found: ImplMethodRef? = none
    for bucket in env.trait_reg.trait_impls.entries() {
        for impl_ in bucket.1 {
            match (impl_.owner_ref, impl_.trait_ref) {
                (some(owner), some(trait_ref)) => if
                        symbol_ref_same(impl_owner_ref_target(owner), target) &&
                        symbol_ref_same(trait_ref, drop_trait) {
                    let method = impl_.method_refs.get("drop").unwrap_or_else(fn() {
                        panic("physical nominal export: Drop owner lacks method")
                    })
                    match found {
                        some(existing) => if !impl_method_ref_same(
                                existing, method) {
                            panic("physical nominal export: Drop owner repeats")
                        },
                        none => { found = some(method) }
                    }
                },
                _ => {}
            }
        }
    }
    found
}

fn physical_dependency_owners_same(
    left: List<RegisteredNominalRef>,
    right: List<RegisteredNominalRef>
) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        if !registered_nominal_ref_same(
                left.get(index).unwrap(), right.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}

fn append_physical_nominal(
    mut values: List<PhysicalNominalFact>, candidate: PhysicalNominalFact
) {
    for index in 0..values.len() {
        let existing = values.get(index).unwrap()
        if registered_nominal_ref_same(
                physical_nominal_owner(existing),
                physical_nominal_owner(candidate)) {
            if physical_nominal_name(existing) !=
                    physical_nominal_name(candidate) ||
               physical_nominal_is_struct(existing) !=
                    physical_nominal_is_struct(candidate) ||
               !physical_dependency_owners_same(
                    physical_nominal_dependency_owners(existing),
                    physical_nominal_dependency_owners(candidate)) {
                panic("physical nominal export: exact owner layout differs")
            }
            match (physical_nominal_drop_method(existing),
                   physical_nominal_drop_method(candidate)) {
                (some(left), some(right)) => if
                        !impl_method_ref_same(left, right) {
                    panic("physical nominal export: Drop method differs")
                },
                (none, some(_)) => { values.set(index, candidate) },
                _ => {}
            }
            return
        }
    }
    values.push(candidate)
}

fn append_dependency_physical_nominals(
    dependencies: List<ModuleExports>,
    mut values: List<PhysicalNominalFact>
) {
    for dependency in dependencies {
        for fact in module_export_physical_nominals(dependency) {
            append_physical_nominal(values, fact)
        }
    }
}

fn has_physical_nominal_owner(
    values: List<PhysicalNominalFact>, owner: RegisteredNominalRef
) -> Bool {
    values.any(fn(value) {
        registered_nominal_ref_same(physical_nominal_owner(value), owner)
    })
}

fn collect_physical_effect_dependencies(
    env: TypeEnv, effects: List<Effect>,
    mut owners: List<RegisteredNominalRef>
) {
    for atom in effects {
        match atom {
            Effect::FailEffect { error_type } =>
                collect_physical_type_dependencies(env, error_type, owners),
            Effect::MutEffect { state_type } =>
                collect_physical_type_dependencies(env, state_type, owners),
            Effect::CustomEffect { type_args, .. } => {
                for argument in type_args {
                    collect_physical_type_dependencies(env, argument, owners)
                }
            },
            _ => {}
        }
    }
}

fn collect_physical_type_dependencies(
    env: TypeEnv, ty: Type, mut owners: List<RegisteredNominalRef>
) {
    match ty {
        Type::FnType { params, return_type, effects } => {
            for parameter in params {
                collect_physical_type_dependencies(env, parameter, owners)
            }
            collect_physical_type_dependencies(env, return_type, owners)
            collect_physical_effect_dependencies(env, effects.effects, owners)
        },
        Type::StructType { name, type_params } => {
            let exact_type = Type::StructType {
                name: name, type_params: type_params
            }
            owners.push(physical_nominal_owner_for_type(
                env, exact_type).unwrap_or_else(fn() {
                    panic("physical nominal export: struct dependency owner is absent")
                }))
            for parameter in type_params {
                collect_physical_type_dependencies(env, parameter, owners)
            }
        },
        Type::EnumType { name, type_params } => {
            let exact_type = Type::EnumType {
                name: name, type_params: type_params
            }
            owners.push(physical_nominal_owner_for_type(
                env, exact_type).unwrap_or_else(fn() {
                    panic("physical nominal export: enum dependency owner is absent")
                }))
            for parameter in type_params {
                collect_physical_type_dependencies(env, parameter, owners)
            }
        },
        Type::GenericType { base, args } => {
            collect_physical_type_dependencies(env, base, owners)
            for argument in args {
                collect_physical_type_dependencies(env, argument, owners)
            }
        },
        Type::RecordType { fields, .. } => {
            for field in fields {
                collect_physical_type_dependencies(env, field.ty, owners)
            }
        },
        Type::EffectRowType { effects, .. } =>
            collect_physical_effect_dependencies(env, effects, owners),
        Type::TupleType { elements } => {
            for element in elements {
                collect_physical_type_dependencies(env, element, owners)
            }
        },
        Type::PtrType { pointee } =>
            collect_physical_type_dependencies(env, pointee, owners),
        _ => {}
    }
}

fn struct_physical_dependency_owners(
    env: TypeEnv, def: StructDef
) -> List<RegisteredNominalRef> {
    let result: List<RegisteredNominalRef> = []
    for field in def.fields {
        collect_physical_type_dependencies(env, field.ty, result)
    }
    result
}

fn enum_physical_dependency_owners(
    env: TypeEnv, def: EnumDef
) -> List<RegisteredNominalRef> {
    let result: List<RegisteredNominalRef> = []
    for variant in def.variants {
        for field in variant.fields {
            collect_physical_type_dependencies(env, field, result)
        }
    }
    result
}

fn append_environment_physical_nominals(
    env: TypeEnv, mut values: List<PhysicalNominalFact>
) {
    let mut structs = env.types.structs.entries()
    structs.sort_by(compare_by_first)
    for entry in structs {
        if !has_physical_nominal_owner(values, entry.1.owner_ref) {
            append_physical_nominal(values, make_physical_struct_fact(
                entry.1, physical_drop_method(env, entry.1.owner_ref),
                struct_physical_dependency_owners(env, entry.1)))
        }
    }
    let mut externs = env.types.extern_structs.entries()
    externs.sort_by(compare_by_first)
    for entry in externs {
        if !has_physical_nominal_owner(values, entry.1.owner_ref) {
            append_physical_nominal(values, make_physical_struct_fact(
                entry.1, physical_drop_method(env, entry.1.owner_ref),
                struct_physical_dependency_owners(env, entry.1)))
        }
    }
    let mut enums = env.types.enums.entries()
    enums.sort_by(compare_by_first)
    for entry in enums {
        if !has_physical_nominal_owner(values, entry.1.owner_ref) {
            append_physical_nominal(values, make_physical_enum_fact(
                entry.1, physical_drop_method(env, entry.1.owner_ref),
                enum_physical_dependency_owners(env, entry.1)))
        }
    }
}

pub fn physical_nominal_inputs_for_core(
    mut env: TypeEnv, dependencies: List<ModuleExports>
) -> List<PhysicalNominalFact> {
    let raw_dependencies: List<PhysicalNominalFact> = []
    append_dependency_physical_nominals(dependencies, raw_dependencies)
    let result: List<PhysicalNominalFact> = []
    for fact in raw_dependencies {
        append_physical_nominal(
            result, localize_physical_nominal_fact(env, fact))
    }
    append_environment_physical_nominals(env, result)
    result
}

fn physical_fact_for_owner(
    values: List<PhysicalNominalFact>, owner: RegisteredNominalRef
) -> PhysicalNominalFact {
    let mut found: PhysicalNominalFact? = none
    for value in values {
        if registered_nominal_ref_same(
                physical_nominal_owner(value), owner) {
            if physical_nominal_name(value) != symbol_ref_canonical_payload(
                    registered_nominal_ref_symbol(owner)) {
                panic("physical nominal export: exact dependency payload differs")
            }
            found = some(value)
        }
    }
    match found {
        some(value) => value,
        none => panic(
            "physical nominal export: exact dependency is absent")
    }
}

fn exported_physical_nominal_closure(
    env: TypeEnv, types: Map<Str, TypeDef>,
    dependencies: List<ModuleExports>
) -> List<PhysicalNominalFact> {
    let pool: List<PhysicalNominalFact> = []
    append_dependency_physical_nominals(dependencies, pool)
    append_environment_physical_nominals(env, pool)
    let pending: List<PhysicalNominalFact> = []
    let mut roots = types.entries()
    roots.sort_by(compare_by_first)
    for entry in roots {
        let owner = match entry.1 {
            TypeDef::StructDef_(def) => def.owner_ref,
            TypeDef::EnumDef_(def) => def.owner_ref
        }
        pending.push(physical_fact_for_owner(pool, owner))
    }
    let result: List<PhysicalNominalFact> = []
    let mut cursor = 0
    while cursor < pending.len() {
        let fact = pending.get(cursor).unwrap()
        cursor = cursor + 1
        let already = result.any(fn(existing) {
            registered_nominal_ref_same(
                physical_nominal_owner(existing),
                physical_nominal_owner(fact))
        })
        if already { continue }
        append_physical_nominal(result, fact)
        for owner in physical_nominal_dependency_owners(fact) {
            pending.push(physical_fact_for_owner(pool, owner))
        }
    }
    result
}

// Resolve a relative pub-use inside an inline module to the same canonical
// identity scheme used by registration (file-prefix$$_inline::item).
fn inline_use_source_prefix(mod_identity: Str, use_decl: UseDecl) -> Str? {
    let path = use_decl.path.segments
    if path.len() == 0 { return none }
    let first = path.get(0).unwrap_or("")
    if first != "self" && first != "super" { return none }

    let identity_parts = mod_identity.split("$$_")
    if identity_parts.len() < 2 { return none }
    let root = "${identity_parts.get(0).unwrap_or("")}$$_"
    let mut inline_parts = identity_parts.get(1).unwrap_or("").split("::")

    let mut index = 1
    if first == "super" {
        if inline_parts.len() == 0 { return none }
        inline_parts.pop()
        while index < path.len() && path.get(index).unwrap_or("") == "super" {
            if inline_parts.len() == 0 { return none }
            inline_parts.pop()
            index = index + 1
        }
    }

    let remaining_end = match use_decl.imports {
        UseImport::NamedItems { .. } => path.len(),
        UseImport::Module => path.len() - 1
    }
    while index < remaining_end {
        inline_parts.push(path.get(index).unwrap_or(""))
        index = index + 1
    }
    if inline_parts.len() == 0 { some(root) } else { some("${root}${inline_parts.join("::")}") }
}

fn copy_inline_export(
    source: Str, local: Str, env: TypeEnv, fn_mut_params_map: Map<Str, List<Bool>>, program: Program,
    mut values: Map<Str, TypeScheme>, mut value_symbols: Map<Str, SymbolRef>,
    exact_value_symbols: Map<Int, SymbolRef>,
    exact_value_binding_kinds: Map<Int, ValueBindingKind>,
    mut value_binding_kinds: Map<Str, ValueBindingKind>,
    mut types: Map<Str, TypeDef>, mut type_aliases: Map<Str, TypeAliasDef>, mut effects: Map<Str, EffectDef>,
    mut effect_aliases: Map<Str, EffectAliasDef>, mut traits: Map<Str, TraitDef>,
    mut inherent_methods: Map<Str, List<Str>>, mut struct_field_orders: Map<Str, List<Str>>,
    mut extern_values: Set<Str>, mut mut_methods: Map<Str, Set<Str>>,
    mut fn_mut_params: Map<Str, List<Bool>>
) {
    match env.lookup(source) {
        some(scheme) => {
            let exact_symbol = exact_scheme_value_symbol(
                exact_value_symbols, scheme)
            let exact_origin = symbol_ref_canonical_payload(exact_symbol)
            values.insert(local, scheme)
            value_symbols.insert(local, exact_symbol)
            match declared_value_kind(exact_value_binding_kinds, scheme) {
                some(kind) => {
                    value_binding_kinds.insert(local, kind)
                    match kind {
                        ValueBindingKind::ExternCallable => {
                            extern_values.insert(local)
                        },
                        _ => {}
                    }
                },
                none => {}
            }
            match fn_mut_params_map.get(source) {
                some(flags) => { fn_mut_params.insert(local, flags) },
                none => match fn_mut_params_map.get(exact_origin) {
                    some(flags) => { fn_mut_params.insert(local, flags) },
                    none => {}
                }
            }
        },
        none => {
            // Every file/inline extern now has a canonical declaration
            // identity in the environment. A leaf fallback here would allow
            // an unrelated same-spelled extern to leak across module scopes.
        }
    }
    match env.types.structs.get(source) {
        some(def) => {
            types.insert(local, TypeDef::StructDef_(def))
            let mut fields: List<Str> = []
            for field in def.fields { fields.push(field.name) }
            struct_field_orders.insert(local, fields)
            match env.trait_reg.mut_methods.get(def.name) {
                some(methods) => { mut_methods.insert(def.name, methods) }, none => {}
            }
        },
        none => {
            // Extern types retain a raw ABI identity. Permit that lookup only
            // after the complete canonical source path is proven against this
            // file's recursive AST; never infer ownership from a unique leaf.
            if program_declares_exact_extern_source(program, source) {
                let abi_name = identity_leaf(source)
                match env.types.extern_structs.get(abi_name) {
                    some(def) => {
                        if def.is_extern { types.insert(local, TypeDef::StructDef_(def)) }
                    },
                    none => {}
                }
            }
        }
    }
    match env.types.enums.get(source) {
        some(def) => {
            types.insert(local, TypeDef::EnumDef_(def))
            // A facade enum must carry its constructors even when the source
            // inline module itself is private. Reconstruct the registration
            // scheme from the canonical EnumDef instead of consulting the
            // unqualified variant binding, which may belong to a same-spelled
            // variant from another enum. The fully-qualified facade binding
            // gives inference an exact lookup; the legacy leaf binding keeps
            // named enum imports compatible when it is not already occupied.
            let mut variant_index = 0
            for variant in def.variants {
                let variant_ref = match def.variant_refs.get(variant_index) {
                    some(value) => value,
                    none => panic("module export: enum VariantRef is missing")
                }
                variant_index = variant_index + 1
                let ctor_scheme = variant_ctor_scheme(def)
                let facade_ctor = "${local}::${variant.name}"
                values.insert(facade_ctor, ctor_scheme)
                value_symbols.insert(facade_ctor,
                    variant_ref_member(variant_ref))
                if !values.contains_key(variant.name) {
                    values.insert(variant.name, ctor_scheme)
                    value_symbols.insert(variant.name,
                        variant_ref_member(variant_ref))
                }
            }
            match env.trait_reg.mut_methods.get(def.name) {
                some(methods) => { mut_methods.insert(def.name, methods) }, none => {}
            }
        },
        none => {}
    }
    match env.types.type_aliases.get(source) {
        some(def) => { type_aliases.insert(local, def) }, none => {}
    }
    match env.types.effects.get(source) {
        some(def) => { effects.insert(local, def) }, none => {}
    }
    match env.types.effect_aliases.get(source) {
        some(def) => { effect_aliases.insert(local, def) }, none => {}
    }
    match env.trait_reg.traits.get(source) {
        some(def) => { traits.insert(local, def) }, none => {}
    }
}

fn extract_decl_export(
    decl: Decl,
    env: TypeEnv,
    fn_mut_params_map: Map<Str, List<Bool>>,
    program: Program,
    mut values: Map<Str, TypeScheme>,
    mut value_symbols: Map<Str, SymbolRef>,
    exact_value_symbols: Map<Int, SymbolRef>,
    exact_value_binding_kinds: Map<Int, ValueBindingKind>,
    mut value_binding_kinds: Map<Str, ValueBindingKind>,
    mut types: Map<Str, TypeDef>,
    mut type_aliases: Map<Str, TypeAliasDef>,
    mut effects: Map<Str, EffectDef>,
    mut effect_aliases: Map<Str, EffectAliasDef>,
    mut traits: Map<Str, TraitDef>,
    mut inherent_methods: Map<Str, List<Str>>,
    mut struct_field_orders: Map<Str, List<Str>>,
    mut extern_values: Set<Str>,
    mut mut_methods: Map<Str, Set<Str>>,
    mut fn_mut_params: Map<Str, List<Bool>>,
    is_top_level: Bool
) {
    match decl {
        Decl::Fn { name, is_pub, .. } => {
            if is_pub {
                let display = export_display_name(name)
                match env.lookup(name) {
                    some(scheme) => {
                        values.insert(display, scheme)
                        value_symbols.insert(display, exact_scheme_value_symbol(
                            exact_value_symbols, scheme))
                        value_binding_kinds.insert(display, ValueBindingKind::DirectCallable)
                    },
                    none => {},
                }
                match fn_mut_params_map.get(name) {
                    some(flags) => { fn_mut_params.insert(display, flags) },
                    none => {},
                }
            }
        },
        Decl::Struct { name, is_pub, .. } => {
            if is_pub {
                let display = export_display_name(name)
                match env.types.structs.get(name) {
                    some(sdef) => {
                        types.insert(display, TypeDef::StructDef_(sdef))
                        let mut field_names: List<Str> = []
                        for f in sdef.fields { field_names.push(f.name) }
                        struct_field_orders.insert(display, field_names)
                    },
                    none => {},
                }
            }
        },
        Decl::Enum { name, is_pub, .. } => {
            if is_pub {
                let display = export_display_name(name)
                match env.types.enums.get(name) {
                    some(edef) => {
                        types.insert(display, TypeDef::EnumDef_(edef))
                        // The module's final leaf scope may contain an unrelated
                        // same-spelled private fn/const. Export the enum's exact
                        // constructor scheme and identity from EnumDef instead.
                        let mut variant_index = 0
                        for v in edef.variants {
                            let variant_ref = match edef.variant_refs.get(
                                variant_index) {
                                some(value) => value,
                                none => panic(
                                    "module export: enum VariantRef is missing")
                            }
                            variant_index = variant_index + 1
                            let ctor_scheme = variant_ctor_scheme(edef)
                            values.insert(v.name, ctor_scheme)
                            value_symbols.insert(v.name,
                                variant_ref_member(variant_ref))
                        }
                    },
                    none => {},
                }
            }
        },
        Decl::Effect { name, is_pub, .. } => {
            if is_pub {
                let display = export_display_name(name)
                match env.types.effects.get(name) {
                    some(effdef) => { effects.insert(display, effdef) },
                    none => {},
                }
            }
        },
        Decl::EffectAlias { name, is_pub, .. } => {
            if is_pub {
                let display = export_display_name(name)
                match env.types.effect_aliases.get(name) {
                    some(adef) => { effect_aliases.insert(display, adef) },
                    none => {},
                }
            }
        },
        Decl::Trait { name, is_pub, .. } => {
            if is_pub {
                let display = export_display_name(name)
                match env.trait_reg.traits.get(name) {
                    some(tdef) => { traits.insert(display, tdef) },
                    none => {},
                }
            }
        },
        // Decl::Impl is intentionally absent here: impl exports are driven by
        // the checker's persisted ModuleImplFact list (export_impl_facts),
        // whose targets were resolved while the namespace frames were live.
        Decl::ExternFn { name, is_pub, .. } => {
            if is_pub {
                let display = export_display_name(name)
                extern_values.insert(display)
                match env.lookup(name) {
                    some(scheme) => {
                        values.insert(display, scheme)
                        value_symbols.insert(display, exact_scheme_value_symbol(
                            exact_value_symbols, scheme))
                        value_binding_kinds.insert(display, ValueBindingKind::ExternCallable)
                    },
                    none => {},
                }
            }
        },
        Decl::ExternType { name, is_pub, .. } => {
            if is_pub {
                let display = export_display_name(name)
                let abi_name = identity_leaf(name)
                match env.types.extern_structs.get(abi_name) {
                    some(sdef) => {
                        if sdef.is_extern {
                            types.insert(display, TypeDef::StructDef_(sdef))
                        }
                    },
                    none => {},
                }
            }
        },
        Decl::TypeAlias { name, is_pub, .. } => {
            if is_pub {
                let display = export_display_name(name)
                match env.types.type_aliases.get(name) {
                    some(adef) => { type_aliases.insert(display, adef) },
                    none => {},
                }
            }
        },
        Decl::Const { name, is_pub, .. } => {
            if is_pub {
                let display = export_display_name(name)
                match env.lookup(name) {
                    some(scheme) => {
                        values.insert(display, scheme)
                        value_symbols.insert(display, exact_scheme_value_symbol(
                            exact_value_symbols, scheme))
                        value_binding_kinds.insert(display, ValueBindingKind::ConstGetter)
                    },
                    none => {},
                }
            }
        },
        Decl::ModBlock { name: mod_name, uses: mod_uses, decls: mod_decls, is_pub: mpub, .. } => {
            if mpub {
                for subdecl in mod_decls {
                    let prefixed = prefix_decl_name(mod_name, subdecl)
                    extract_decl_export(prefixed, env, fn_mut_params_map, program,
                        values, value_symbols, exact_value_symbols,
                        exact_value_binding_kinds, value_binding_kinds,
                        types, type_aliases, effects, effect_aliases, traits,
                        inherent_methods, struct_field_orders,
                        extern_values, mut_methods, fn_mut_params, false)
                }
                let facade = export_display_name(mod_name)
                for use_decl in mod_uses {
                    if !use_decl.is_pub { continue }
                    match inline_use_source_prefix(mod_name, use_decl) {
                        some(source_prefix) => match use_decl.imports {
                            UseImport::NamedItems { names } => {
                                for item in names {
                                    let local_name = match item.alias { some(a) => a, none => item.name }
                                    copy_inline_export(append_identity(source_prefix, item.name), "${facade}::${local_name}",
                                        env, fn_mut_params_map, program, values, value_symbols,
                                        exact_value_symbols, exact_value_binding_kinds,
                                        value_binding_kinds,
                                        types, type_aliases, effects, effect_aliases, traits,
                                        inherent_methods, struct_field_orders, extern_values, mut_methods, fn_mut_params)
                                }
                            },
                            UseImport::Module => {
                                let path = use_decl.path.segments
                                let item_name = path.get(path.len() - 1).unwrap_or("")
                                let local_name = match use_decl.alias { some(a) => a, none => item_name }
                                copy_inline_export(append_identity(source_prefix, item_name), "${facade}::${local_name}",
                                    env, fn_mut_params_map, program, values, value_symbols,
                                    exact_value_symbols, exact_value_binding_kinds,
                                    value_binding_kinds,
                                    types, type_aliases, effects, effect_aliases, traits,
                                    inherent_methods, struct_field_orders, extern_values, mut_methods, fn_mut_params)
                            }
                        },
                        none => {}
                    }
                }
            }
        },
        _ => {},
    }
}

// ============================================================
// extract_exports
// ============================================================

fn copy_exported_name(
    source: ModuleExports, source_name: Str, local_name: Str,
    mut values: Map<Str, TypeScheme>, mut value_symbols: Map<Str, SymbolRef>,
    mut value_binding_kinds: Map<Str, ValueBindingKind>,
    mut types: Map<Str, TypeDef>, mut type_aliases: Map<Str, TypeAliasDef>, mut effects: Map<Str, EffectDef>,
    mut effect_aliases: Map<Str, EffectAliasDef>, mut traits: Map<Str, TraitDef>,
    mut struct_field_orders: Map<Str, List<Str>>, mut extern_values: Set<Str>,
    mut fn_mut_params: Map<Str, List<Bool>>,
    mut inherent_methods: Map<Str, List<Str>>, mut mut_methods: Map<Str, Set<Str>>
) {
    match source.values.get(source_name) {
        some(scheme) => {
            values.insert(local_name, scheme)
            let symbol = match source.value_symbols.get(source_name) {
                some(value) => value,
                none => panic("module re-export: value lacks exact SymbolRef")
            }
            value_symbols.insert(local_name, symbol)
            match source.value_binding_kinds.get(source_name) {
                some(kind) => { value_binding_kinds.insert(local_name, kind) },
                none => {}
            }
        },
        none => {}
    }
    match source.types.get(source_name) {
        some(def) => {
            types.insert(local_name, def)
            let canonical_type = match def {
                TypeDef::StructDef_(sdef) => sdef.name,
                TypeDef::EnumDef_(edef) => edef.name
            }
            match source.inherent_methods.get(canonical_type) {
                some(methods) => { inherent_methods.insert(canonical_type, list_clone(methods)) }, none => {}
            }
            match source.mut_methods.get(canonical_type) {
                some(methods) => { mut_methods.insert(canonical_type, methods) }, none => {}
            }
        },
        none => {}
    }
    match source.type_aliases.get(source_name) {
        some(def) => { type_aliases.insert(local_name, def) }, none => {}
    }
    match source.effects.get(source_name) {
        some(def) => { effects.insert(local_name, def) }, none => {}
    }
    match source.effect_aliases.get(source_name) {
        some(def) => { effect_aliases.insert(local_name, def) }, none => {}
    }
    match source.traits.get(source_name) {
        some(def) => { traits.insert(local_name, def) }, none => {}
    }
    match source.struct_field_orders.get(source_name) {
        some(fields) => { struct_field_orders.insert(local_name, fields) }, none => {}
    }
    if source.extern_values.contains(source_name) { extern_values.insert(local_name) }
    match source.fn_mut_params.get(source_name) {
        some(flags) => { fn_mut_params.insert(local_name, flags) }, none => {}
    }
}

fn exact_constructor_owner_for_symbol(
    env: TypeEnv, symbol: SymbolRef
) -> RegisteredNominalRef? {
    let mut found: RegisteredNominalRef? = none
    for entry in env.types.enums.entries() {
        let def = entry.1
        for variant in def.variant_refs {
            if symbol_ref_same(variant_ref_member(variant), symbol) {
                let owner = variant_ref_owner(variant)
                match found {
                    some(existing) => if !registered_nominal_ref_same(
                            existing, owner) {
                        panic("module export: constructor member names multiple enum owners")
                    },
                    none => { found = some(owner) }
                }
            }
        }
    }
    found
}

fn public_types_contain_enum_owner(
    values: Map<Str, TypeDef>, owner: RegisteredNominalRef
) -> Bool {
    for entry in values.entries() {
        match entry.1 {
            TypeDef::EnumDef_(def) => if registered_nominal_ref_same(
                    def.owner_ref, owner) {
                return true
            },
            TypeDef::StructDef_(_) => {}
        }
    }
    false
}

fn validate_constructor_export_closure(
    env: TypeEnv, value_symbols: Map<Str, SymbolRef>,
    types: Map<Str, TypeDef>, mut sink: CollectingSink, program: Program
) -> Bool {
    let mut entries = value_symbols.entries()
    entries.sort_by(compare_by_first)
    let mut valid = true
    for entry in entries {
        let export_name = entry.0
        match exact_constructor_owner_for_symbol(env, entry.1) {
            some(owner) => if !public_types_contain_enum_owner(types, owner) {
                let owner_name = export_display_name(
                    registered_nominal_ref_display_name(owner))
                sink.report(make_diag(
                    E0703, Severity::SevError,
                    "Public constructor export '${export_name}' requires its owner enum '${owner_name}' to be publicly re-exported; re-export the enum in this facade",
                    program.span,
                    DiagnosticContext::OtherContext { detail: some(
                        "re-export the constructor owner enum in this facade")
                    }))
                valid = false
            },
            none => {}
        }
    }
    valid
}

// Export the methods of every user-declared impl block. The canonical target
// in each ModuleImplFact was resolved by the checker while the module's
// namespace frames were live (check_impl_decl -> resolve_nominal_identity),
// so this consumes the registration result directly instead of replaying
// lexical resolution against the rolled-back environment.
fn append_exact_impl_owner(owner: ImplEntry, mut owners: List<ImplEntry>) {
    for existing in owners {
        if impl_entry_exact_key_same(existing, owner) {
            if !impl_entry_final_same(existing, owner) {
                panic("impl export closure: same-provider owner structure drifted")
            }
            return
        }
    }
    owners.push(owner)
}

fn method_ref_matches_owner(method_ref: ImplMethodRef, owner: ImplEntry) -> Bool {
    match owner.owner_ref {
        some(owner_ref) => if !impl_owner_ref_same(
                impl_method_ref_owner(method_ref), owner_ref) {
            return false
        },
        none => return false
    }
    match owner.method_refs.get(impl_method_ref_name(method_ref)) {
        some(expected) => impl_method_ref_same(expected, method_ref),
        none => false
    }
}

fn append_owner_method_indexes(
    owner: ImplEntry,
    registry_index: Map<Str, Map<Str, ImplMethodRef>>,
    allowed_method_names: List<Str>,
    mut method_index: Map<Str, Map<Str, ImplMethodRef>>
) {
    match registry_index.get(owner.target_type_name) {
        some(index) => {
            let mut sorted_cores = owner.method_schemes.entries()
            sorted_cores.sort_by(compare_by_first)
            for core_entry in sorted_cores {
                let (method_name, _) = core_entry
                if !allowed_method_names.contains(method_name) { continue }
                let method_ref = match index.get(method_name) {
                    some(found) => found,
                    none => panic(
                        "impl export closure: owner core index is missing")
                }
                if !method_ref_matches_owner(method_ref, owner) {
                    panic("impl export closure: owner core index changed identity")
                }
                insert_exact_method_ref(
                    owner.target_type_name, method_name, method_ref,
                    method_index)
            }
        },
        none => if owner.method_schemes.len() > 0 {
            panic("impl export closure: owner core index map is missing")
        }
    }
}

fn exported_owner_method_names(
    owner: ImplEntry, inherent_methods: Map<Str, List<Str>>
) -> List<Str> {
    match owner.trait_ref {
        some(_) => {
            let mut names = owner.method_schemes.keys()
            names.sort()
            names
        },
        none => match inherent_methods.get(owner.target_type_name) {
            some(names) => list_clone(names),
            none => []
        }
    }
}

fn insert_exact_method_ref(
    target: Str, method_name: Str, method_ref: ImplMethodRef,
    mut method_index: Map<Str, Map<Str, ImplMethodRef>>
) {
    let mut target_index = match method_index.get(target) {
        some(existing) => existing,
        none => {
            let created: Map<Str, ImplMethodRef> = map_new()
            method_index.insert(target, created)
            created
        }
    }
    match target_index.get(method_name) {
        some(existing) => if !impl_method_ref_same(existing, method_ref) {
            panic("impl export closure: distinct identities share one method index")
        },
        none => target_index.insert(method_name, method_ref)
    }
}

fn export_impl_facts(
    impl_facts: List<ModuleImplFact>,
    env: TypeEnv,
    program: Program,
    mut fact_owners: List<ImplEntry>,
    mut inherent_methods: Map<Str, List<Str>>,
    mut mut_methods: Map<Str, Set<Str>>
) {
    let mut seen_fact_owners: List<ImplEntry> = []
    for fact in impl_facts {
        let owner = match find_impl_by_provider(
            env.trait_reg, fact.target,
            fact.trait_ref, fact.provider_ref
        ) {
            some(found) => found,
            none => panic("impl export closure: exact fact owner is missing")
        }
        if !optional_symbol_ref_same(owner.trait_ref, fact.trait_ref) ||
           match owner.owner_ref {
               some(registered) => !impl_owner_ref_same(
                   registered, fact.owner_ref),
               none => true
           } {
            panic("impl export closure: fact owner relation changed")
        }
        for seen in seen_fact_owners {
            if impl_entry_exact_key_same(seen, owner) {
                panic("impl export closure: user impl fact was exported twice")
            }
        }
        seen_fact_owners.push(owner)
        for method_name in fact.method_names {
            if !owner.method_schemes.contains_key(method_name) {
                panic("impl export closure: fact method has no owner core")
            }
            match env.trait_reg.method_index.get(fact.target) {
                some(index) => match index.get(method_name) {
                    some(method_ref) => if !method_ref_matches_owner(
                            method_ref, owner) {
                        panic("impl export closure: fact method changed owner")
                    },
                    none => panic("impl export closure: fact method index is missing")
                },
                none => panic("impl export closure: fact method index map is missing")
            }
        }
        if fact.trait_ref.is_some() &&
           fact.public_inherent_method_names.len() != 0 {
            panic("impl export closure: trait impl carried member visibility")
        }
        for public_name in fact.public_inherent_method_names {
            if !fact.method_names.contains(public_name) {
                panic("impl export closure: public inherent method is not owned")
            }
        }
        append_exact_impl_owner(owner, fact_owners)
        match env.trait_reg.mut_methods.get(fact.target) {
            some(ms) => { mut_methods.insert(fact.target, ms) },
            none => {}
        }
        // Inherent-method name lists — only for top-level impls of pub types
        // (mod-block nested impls never did the pub-type scan; preserved).
        if fact.is_top_level && fact.trait_ref.is_none() {
            let mut is_pub_type = false
            for d in program.decls {
                match d {
                    Decl::Struct { name, is_pub, .. } => {
                        if name == export_display_name(fact.target) && is_pub { is_pub_type = true }
                    },
                    Decl::Enum { name, is_pub, .. } => {
                        if name == export_display_name(fact.target) && is_pub { is_pub_type = true }
                    },
                    _ => {}
                }
            }
            if is_pub_type {
                let mut method_names: List<Str> = []
                for m in fact.public_inherent_method_names {
                    method_names.push(m)
                }
                match inherent_methods.get(fact.target) {
                    some(existing) => existing.extend(method_names),
                    none => { inherent_methods.insert(fact.target, method_names) }
                }
            }
        }
    }
}

fn validate_impl_export_closure(
    owners: List<ImplEntry>,
    method_index: Map<Str, Map<Str, ImplMethodRef>>,
    inherent_methods: Map<Str, List<Str>>
) {
    for map_entry in method_index.entries() {
        let (target, index) = map_entry
        for method_entry in index.entries() {
            let (method_name, method_ref) = method_entry
            let mut matches = 0
            for owner in owners {
                if owner.target_type_name == target &&
                   method_ref_matches_owner(method_ref, owner) {
                    matches = matches + 1
                    if !owner.method_schemes.contains_key(method_name) {
                        panic("impl export closure: exported index has no owner core")
                    }
                }
            }
            if matches != 1 {
                panic("impl export closure: exported index owner is not unique")
            }
        }
    }
    for owner in owners {
        let allowed = exported_owner_method_names(owner, inherent_methods)
        for core_entry in owner.method_schemes.entries() {
            let (method_name, _) = core_entry
            if !allowed.contains(method_name) { continue }
            let method_ref = match method_index.get(owner.target_type_name) {
                some(index) => match index.get(method_name) {
                    some(found) => found,
                    none => panic(
                        "impl export closure: owner core has no exported index")
                },
                none => panic(
                    "impl export closure: owner core has no exported index map")
            }
            if !method_ref_matches_owner(method_ref, owner) {
                panic("impl export closure: owner core index is not exact")
            }
        }
    }
}

pub fn extract_exports(
    module_key: Str,
    module_prefix: Str,
    program: Program,
    hprogram: HProgram,
    env: TypeEnv,
    fn_mut_params_map: Map<Str, List<Bool>>,
    exact_value_symbols: Map<Int, SymbolRef>,
    exact_value_binding_kinds: Map<Int, ValueBindingKind>,
    impl_facts: List<ModuleImplFact>,
    available_modules: List<ModuleExports>,
    sink: CollectingSink
) -> ModuleExports? {
    let mut values: Map<Str, TypeScheme> = map_new()
    let mut value_symbols: Map<Str, SymbolRef> = map_new()
    let mut value_binding_kinds: Map<Str, ValueBindingKind> = map_new()
    let mut types: Map<Str, TypeDef> = map_new()
    let mut type_aliases: Map<Str, TypeAliasDef> = map_new()
    let mut effects: Map<Str, EffectDef> = map_new()
    let mut effect_aliases: Map<Str, EffectAliasDef> = map_new()
    let mut traits: Map<Str, TraitDef> = map_new()
    let mut inherent_methods: Map<Str, List<Str>> = map_new()
    let mut struct_field_orders: Map<Str, List<Str>> = map_new()
    let mut extern_values: Set<Str> = set_new()
    let mut mut_methods: Map<Str, Set<Str>> = map_new()
    let mut fn_mut_params: Map<Str, List<Bool>> = map_new()
    let mut fact_owners: List<ImplEntry> = []
    for decl in program.decls {
        let canonical_decl = module_prefix_decl_name(module_prefix, decl)
        extract_decl_export(canonical_decl, env, fn_mut_params_map, program,
            values, value_symbols, exact_value_symbols,
            exact_value_binding_kinds, value_binding_kinds,
            types, type_aliases, effects, effect_aliases, traits,
            inherent_methods, struct_field_orders,
            extern_values, mut_methods, fn_mut_params, true)
    }
    export_impl_facts(impl_facts, env, program,
        fact_owners, inherent_methods, mut_methods)

    // Handle pub use re-exports from the dependency export objects themselves.
    // Payloads and origins are forwarded verbatim; only the facade lookup key
    // changes.  This covers named, aliased, whole-module, and transitive uses.
    let mut module_map: Map<Str, ModuleExports> = map_new()
    for mod_ in available_modules { module_map.insert(mod_.module_key, mod_) }
    for use_decl in program.uses {
        if use_decl.is_pub {
            let mod_key = use_decl.path.segments.join("::")
            match module_map.get(mod_key) {
                some(source) => match use_decl.imports {
                    UseImport::NamedItems { names } => {
                        for item in names {
                            let local_name = match item.alias { some(a) => a, none => item.name }
                            copy_exported_name(source, item.name, local_name,
                                values, value_symbols, value_binding_kinds,
                                types, type_aliases, effects, effect_aliases, traits,
                                struct_field_orders, extern_values, fn_mut_params,
                                inherent_methods, mut_methods)
                            // Importing an enum also imports its constructors.
                            match source.types.get(item.name) {
                                some(TypeDef::EnumDef_(edef)) => {
                                    for v in edef.variants {
                                        copy_exported_name(source, v.name, v.name,
                                            values, value_symbols, value_binding_kinds,
                                            types, type_aliases, effects, effect_aliases, traits,
                                            struct_field_orders, extern_values, fn_mut_params,
                                            inherent_methods, mut_methods)
                                    }
                                },
                                _ => {}
                            }
                        }
                    },
                    UseImport::Module => {
                        let mut names: Set<Str> = set_new()
                        for entry in source.values.entries() { let (name, _) = entry; names.insert(name) }
                        for entry in source.types.entries() { let (name, _) = entry; names.insert(name) }
                        for entry in source.type_aliases.entries() { let (name, _) = entry; names.insert(name) }
                        for entry in source.effects.entries() { let (name, _) = entry; names.insert(name) }
                        for entry in source.effect_aliases.entries() { let (name, _) = entry; names.insert(name) }
                        for entry in source.traits.entries() { let (name, _) = entry; names.insert(name) }
                        let mut sorted_names = names.to_list()
                        sorted_names.sort()
                        for name in sorted_names {
                            copy_exported_name(source, name, name,
                                values, value_symbols, value_binding_kinds,
                                types, type_aliases, effects, effect_aliases, traits,
                                struct_field_orders, extern_values, fn_mut_params,
                                inherent_methods, mut_methods)
                        }
                    }
                },
                none => {}
            }
        }
    }

    if !validate_constructor_export_closure(
            env, value_symbols, types, sink, program) {
        return none
    }

    // Filter by canonical payload identity after re-exports have been applied.
    // A facade may rename Foo to Bar, but its ImplEntry must still travel with
    // StructDef.name/EnumDef.name rather than the display spelling.
    let mut exported_type_ids: Set<Str> = set_new()
    for entry in types.entries() {
        let (_, def) = entry
        match def {
            TypeDef::StructDef_(sdef) => exported_type_ids.insert(sdef.name),
            TypeDef::EnumDef_(edef) => exported_type_ids.insert(edef.name)
        }
    }
    let mut exported_trait_ids: Set<Str> = set_new()
    for entry in traits.entries() {
        let (_, def) = entry
        exported_trait_ids.insert(def.name)
    }
    let mut trait_impls: List<ImplEntry> = []
    for owner in fact_owners {
        let target_exported = exported_type_ids.contains(
            owner.target_type_name)
        let publish = match owner.trait_name {
            some(name) => target_exported &&
                exported_trait_ids.contains(name),
            none => target_exported
        }
        if publish { append_exact_impl_owner(owner, trait_impls) }
    }
    let mut sorted_trait_impls = env.trait_reg.trait_impls.entries()
    sorted_trait_impls.sort_by(compare_by_first)
    for map_entry in sorted_trait_impls {
        let (_, impl_list) = map_entry
        for impl_ in impl_list {
            let target_exported = exported_type_ids.contains(
                impl_.target_type_name)
            let publish = match impl_.trait_name {
                some(name) => target_exported &&
                    exported_trait_ids.contains(name),
                none => target_exported
            }
            if publish {
                append_exact_impl_owner(impl_, trait_impls)
            }
        }
    }
    // Index production is intentionally delayed until the exact final owner
    // union is closed. Name/type/fact helpers only collect owners and metadata.
    let mut method_index: Map<Str, Map<Str, ImplMethodRef>> = map_new()
    for owner in trait_impls {
        append_owner_method_indexes(
            owner, env.trait_reg.method_index,
            exported_owner_method_names(owner, inherent_methods),
            method_index)
    }
    validate_impl_export_closure(
        trait_impls, method_index, inherent_methods)

    let physical_nominals = exported_physical_nominal_closure(
        env, types, available_modules)

    some(ModuleExports {
        module_key: module_key,
        module_prefix: module_prefix,
        values: values,
        value_symbols: value_symbols,
        value_binding_kinds: value_binding_kinds,
        types: types,
        type_aliases: type_aliases,
        effects: effects,
        effect_aliases: effect_aliases,
        traits: traits,
        trait_impls: trait_impls,
        method_index: method_index,
        inherent_methods: inherent_methods,
        struct_field_orders: struct_field_orders,
        extern_values: extern_values,
        mut_methods: mut_methods,
        fn_mut_params: fn_mut_params,
        physical_nominals: physical_nominals
    })
}

