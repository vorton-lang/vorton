// builtins.ring — Combined translation of builtins-core.ts + builtins-hof.ts
// Registers built-in effects, types, traits, and HOF intrinsics into TypeEnv.

use types::{Type, Effect, EffectRow, StructField, EnumVariant,
    INT, FLOAT, STR, BOOL, UNIT, NEVER, EMPTY_ROW,
    BUILTIN_LIST, BUILTIN_MAP, BUILTIN_SET, BUILTIN_OPTION, BUILTIN_CELL,
    make_option_type, make_map_type}
use env::{TypeEnv, TypeScheme, SchemeBound, StructDef, EnumDef,
    EffectDef, EffectOpDef, BuiltInKind, TraitDef, TraitMethodDef,
    AssocTypeDef,
    RegisteredTraitMethodContract, RegisteredTraitAssocContract,
    make_registered_trait_method_contract,
    make_registered_trait_assoc_contract,
    make_registered_trait_contract,
    ImplEntry, ImplMethodSchemeCore, TypedImplPredicate,
    FrozenImplPredicateSet,
    mono, add_impl, install_method_core,
    make_impl_method_scheme_core, make_typed_impl_predicate,
    impl_method_core_as_scheme,
    direct_impl_predicate_provenance, freeze_impl_predicate_set,
    frozen_impl_predicates, impl_predicate_subject_type_var,
    impl_predicate_trait_name,
    find_impl_by_provider, impl_target_symbol,
    specialize_trait_method_scheme, delegate_plan_not_applicable}
use ast::{span_zero}
use hir::{variant_ctor_name, compare_by_first}
use diagnostics::{CollectingSink}
use ir_identity::{SymbolRef, TraitMethodRef,
    ImplProviderRef, ImplOwnerRef, ImplMethodRef,
    IntrinsicRef, BuiltinMethodSite, BuiltinValueSite,
    make_symbol_ref, make_nominal_field_ref, make_trait_method_ref,
    make_symbol_origin_ref,
    VariantRef, VariantFieldRef, make_variant_ref, make_variant_field_ref,
    make_registered_nominal_ref, make_registered_trait_ref,
    make_module_body_ref, path_owner_for_module_body, make_path_ref,
    path_role_synthetic, make_impl_provider_ref,
    make_impl_owner_ref, make_impl_method_ref,
    impl_provider_ref_site, path_ref_normalized_child_path,
    impl_provider_kind_builtin, registered_trait_ref_symbol,
    builtin_method_site_from_tag, builtin_method_site_tag,
    make_builtin_method_intrinsic_ref, intrinsic_ref_same,
    intrinsic_ref_symbol,
    BUILTIN_METHOD_SITE_COUNT,
    BUILTIN_METHOD_STR_LEN, BUILTIN_METHOD_STR_CONTAINS,
    BUILTIN_METHOD_STR_STARTS_WITH, BUILTIN_METHOD_STR_ENDS_WITH,
    BUILTIN_METHOD_STR_SLICE, BUILTIN_METHOD_STR_TRIM,
    BUILTIN_METHOD_STR_TO_UPPER, BUILTIN_METHOD_STR_TO_LOWER,
    BUILTIN_METHOD_STR_REPLACE, BUILTIN_METHOD_STR_SPLIT,
    BUILTIN_METHOD_STR_CHAR_AT, BUILTIN_METHOD_STR_INDEX_OF,
    BUILTIN_METHOD_STR_PAD_START, BUILTIN_METHOD_STR_PAD_END,
    BUILTIN_METHOD_STR_REPEAT, BUILTIN_METHOD_STR_CHAR_CODE_AT,
    BUILTIN_METHOD_STR_TRIM_START, BUILTIN_METHOD_STR_TRIM_END,
    BUILTIN_METHOD_STR_IS_EMPTY, BUILTIN_METHOD_STR_LAST_INDEX_OF,
    BUILTIN_METHOD_INT_TO_STR, BUILTIN_METHOD_FLOAT_TO_STR,
    BUILTIN_METHOD_OPTION_UNWRAP_OR, BUILTIN_METHOD_OPTION_UNWRAP,
    BUILTIN_METHOD_OPTION_IS_SOME, BUILTIN_METHOD_OPTION_IS_NONE,
    BUILTIN_METHOD_OPTION_MAP, BUILTIN_METHOD_OPTION_AND_THEN,
    BUILTIN_METHOD_OPTION_UNWRAP_OR_ELSE, BUILTIN_METHOD_OPTION_TO_FAIL,
    BUILTIN_METHOD_CELL_GET, BUILTIN_METHOD_CELL_SET,
    BUILTIN_METHOD_CELL_UPDATE,
    builtin_value_site_from_tag, builtin_value_symbol,
    BUILTIN_VALUE_CELL_CONSTRUCTOR, BUILTIN_VALUE_ALLOC,
    BUILTIN_VALUE_DEALLOC, BUILTIN_VALUE_PTR_COPY,
    BUILTIN_VALUE_PTR_FROM_ADDR,
    namespace_value, namespace_nominal, namespace_trait, namespace_member}
use ir_inventory::{ExecutableEntry, ExecutableInventory, BinderManifest,
    make_named_executable_ref, make_module_body_parent,
    make_executable_entry, make_contract_only,
    make_executable_inventory, make_binder_manifest,
    executable_kind_builtin_intrinsic,
    executable_inventory_count}
use core_hir::{make_core_program, core_program_body_count,
    core_program_inventory, core_program_manifests}
use core_expr::{CoreTypeRef, CoreTypeGraph, CoreCallableContract,
    make_core_type_ref, make_core_type_graph,
    core_type_ref_index, make_core_callable_contract}
use flow_ir::{FlowTypeNode, FlowTypeRef, FlowNominalFieldFact,
    FlowGenericParamFact, FlowResourceDependencyEdge,
    FlowSemanticRole,
    make_flow_type_ref, make_flow_int_type_node,
    make_flow_float_type_node, make_flow_str_type_node,
    make_flow_bool_type_node, make_flow_unit_type_node,
    make_flow_never_type_node, make_flow_struct_type_node,
    make_flow_enum_type_node, make_flow_callable_type_node,
    make_flow_parameter_type_node, make_flow_generic_param_fact,
    flow_type_seed_unique,
    make_flow_call_contract, flow_callable_mode_contract_only,
    flow_semantic_role_read, make_fresh_flow_value_origin}

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

struct BuiltinPredicateSpec {
    subject_param_index: Int,
    trait_name: Str
}

fn builtin_trait_symbol(name: Str) -> SymbolRef {
    make_symbol_ref(
        "$builtin", namespace_trait(), name, "builtin:trait:${name}")
}

fn install_builtin_trait_contract(
    mut env: TypeEnv, name: Str, owner_symbol: SymbolRef,
    type_params: List<Str>, type_param_vars: List<Int>,
    methods: List<TraitMethodDef>, supertraits: List<Str>,
    assoc_types: List<AssocTypeDef>
) {
    let owner_ref = make_registered_trait_ref(owner_symbol, name)
    let mut method_contracts: List<RegisteredTraitMethodContract> = []
    for method in methods {
        method_contracts.push(make_registered_trait_method_contract(
            method.method_ref, method.ty, method.has_default,
            method.param_mutabilities))
    }
    let mut assoc_contracts: List<RegisteredTraitAssocContract> = []
    for assoc in assoc_types {
        let mut bound_refs: List<SymbolRef> = []
        for bound_name in assoc.bounds {
            match env.trait_reg.traits.get(bound_name) {
                some(bound_trait) => bound_refs.push(
                    registered_trait_ref_symbol(bound_trait.owner_ref)),
                none => {}
            }
        }
        assoc_contracts.push(make_registered_trait_assoc_contract(
            assoc.member_ref,
            Type::TypeVar { id: assoc.var_id, name: some(assoc.name) },
            assoc.default_type, bound_refs))
    }
    let mut dict_obligations: List<SymbolRef> = []
    for supertrait in supertraits {
        match env.trait_reg.traits.get(supertrait) {
            some(def) => dict_obligations.push(
                registered_trait_ref_symbol(def.owner_ref)),
            none => {}
        }
    }
    let contract = make_registered_trait_contract(
        owner_ref, method_contracts, assoc_contracts,
        [], dict_obligations)
    env.trait_reg.traits.insert(name, TraitDef {
        name: name, owner_ref: owner_ref,
        type_params: type_params, type_param_vars: type_param_vars,
        methods: methods, supertraits: supertraits,
        assoc_types: assoc_types, contract: contract
    })
}

fn builtin_trait_method(
    owner: SymbolRef, source_member_index: Int,
    callable_slot_index: Int, name: Str
) -> TraitMethodRef {
    if source_member_index != callable_slot_index {
        panic("builtin trait method: source/slot ordering drifted")
    }
    make_trait_method_ref(
        owner, source_member_index, callable_slot_index, name)
}

const BUILTIN_PROVIDER_TRAIT_FACTORY: Int = 0
const BUILTIN_PROVIDER_CELL_CORE: Int = 1
const BUILTIN_PROVIDER_OPTION_CORE: Int = 2
const BUILTIN_PROVIDER_LIST_HOF_FALLBACK: Int = 3
const BUILTIN_PROVIDER_MAP_HOF_UNBOUNDED: Int = 4
const BUILTIN_PROVIDER_MAP_HOF_BOUNDED: Int = 5
const BUILTIN_PROVIDER_SET_HOF_UNBOUNDED: Int = 6
const BUILTIN_PROVIDER_SET_HOF_BOUNDED: Int = 7
const BUILTIN_PROVIDER_OPTION_HOF: Int = 8
const BUILTIN_PROVIDER_PTR_CORE: Int = 9
const BUILTIN_PROVIDER_STR_CORE: Int = 10
const BUILTIN_PROVIDER_INT_CORE: Int = 11
const BUILTIN_PROVIDER_FLOAT_CORE: Int = 12
const BUILTIN_PROVIDER_SITE_COUNT: Int = 13

const BUILTIN_PROVIDER_ORDINALS: List<Int> = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
]

struct BuiltinImplProviderSite {
    tag: Int
}

fn builtin_impl_provider_site_from_tag(tag: Int) -> BuiltinImplProviderSite {
    if tag < 0 || tag >= BUILTIN_PROVIDER_SITE_COUNT ||
       BUILTIN_PROVIDER_ORDINALS.len() != BUILTIN_PROVIDER_SITE_COUNT {
        panic("builtin impl provider: invalid fixed site")
    }
    let mut seen: Set<Int> = set_new()
    for expected in 0..BUILTIN_PROVIDER_SITE_COUNT {
        let ordinal = BUILTIN_PROVIDER_ORDINALS.get(expected).unwrap_or(-1)
        if ordinal != expected || seen.contains(ordinal) {
            panic("builtin impl provider: fixed ordinal table drifted")
        }
        seen.insert(ordinal)
    }
    BuiltinImplProviderSite { tag: tag }
}

fn builtin_impl_provider_site_ordinal(site: BuiltinImplProviderSite) -> Int {
    let checked = builtin_impl_provider_site_from_tag(site.tag)
    BUILTIN_PROVIDER_ORDINALS.get(checked.tag).unwrap_or(-1)
}

fn builtin_trait_factory_site() -> BuiltinImplProviderSite {
    builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_TRAIT_FACTORY)
}

fn builtin_impl_provider(site: BuiltinImplProviderSite) -> ImplProviderRef {
    let ordinal = builtin_impl_provider_site_ordinal(site)
    make_impl_provider_ref(
        make_path_ref(
            path_owner_for_module_body(make_module_body_ref(
                "$builtin", "builtin:impl-providers")),
            [ordinal.to_str()], path_role_synthetic()),
        impl_provider_kind_builtin())
}

fn builtin_method_intrinsic(site: BuiltinMethodSite) -> IntrinsicRef {
    let tag = builtin_method_site_tag(site)
    make_builtin_method_intrinsic_ref(site, make_symbol_ref(
        "$builtin", namespace_value(), "builtin-method:${tag.to_str()}",
        "builtin:method-site:${tag.to_str()}"))
}

fn install_intrinsic(
    mut intrinsics: Map<Str, IntrinsicRef>, name: Str, tag: Int
) {
    if intrinsics.contains_key(name) {
        panic("builtin method intrinsic: duplicate method relation")
    }
    intrinsics.insert(name, builtin_method_intrinsic(
        builtin_method_site_from_tag(tag)))
}

pub struct CheckerBuiltinValue {
    name: Str,
    symbol: SymbolRef
}

fn make_checker_builtin_value(
    name: Str, site: BuiltinValueSite
) -> CheckerBuiltinValue {
    CheckerBuiltinValue { name: name, symbol: builtin_value_symbol(site) }
}

pub fn checker_only_builtin_values() -> List<CheckerBuiltinValue> {
    [
        make_checker_builtin_value(
            "Cell", builtin_value_site_from_tag(
                BUILTIN_VALUE_CELL_CONSTRUCTOR)),
        make_checker_builtin_value(
            "alloc", builtin_value_site_from_tag(BUILTIN_VALUE_ALLOC)),
        make_checker_builtin_value(
            "dealloc", builtin_value_site_from_tag(BUILTIN_VALUE_DEALLOC)),
        make_checker_builtin_value(
            "ptr_copy", builtin_value_site_from_tag(BUILTIN_VALUE_PTR_COPY)),
        make_checker_builtin_value(
            "ptr_from_addr", builtin_value_site_from_tag(
                BUILTIN_VALUE_PTR_FROM_ADDR))
    ]
}

pub fn checker_builtin_value_name(value: CheckerBuiltinValue) -> Str {
    value.name
}

pub fn checker_builtin_value_symbol(value: CheckerBuiltinValue) -> SymbolRef {
    value.symbol
}

fn builtin_impl_identity(
    env: TypeEnv, target_type_name: Str, provider_ref: ImplProviderRef,
    trait_ref: SymbolRef?, cores: Map<Str, ImplMethodSchemeCore>
) -> (ImplOwnerRef, Map<Str, ImplMethodRef>) {
    let target_ref = match impl_target_symbol(env, target_type_name) {
        some(symbol) => symbol,
        none => panic("builtin impl owner: exact target symbol is missing")
    }
    let owner_ref = make_impl_owner_ref(
        target_ref, provider_ref, trait_ref)
    let provider_path = path_ref_normalized_child_path(
        impl_provider_ref_site(provider_ref)).join("/")
    let mut refs: Map<Str, ImplMethodRef> = map_new()
    let mut entries = cores.entries()
    entries.sort_by(compare_by_first)
    let mut callable_slot = 0
    for entry in entries {
        let (method_name, _) = entry
        let member = make_symbol_ref(
            "$builtin", namespace_member(),
            "builtin-impl-member:${provider_path}:${callable_slot}",
            "provider:${provider_path}|method:${callable_slot}")
        refs.insert(method_name, make_impl_method_ref(
            owner_ref, member, callable_slot, callable_slot, method_name))
        callable_slot = callable_slot + 1
    }
    (owner_ref, refs)
}

fn builtin_impl_trait_ref(env: TypeEnv, trait_name: Str?) -> SymbolRef? {
    match trait_name {
        some(name) => match env.trait_reg.traits.get(name) {
            some(def) => some(registered_trait_ref_symbol(def.owner_ref)),
            none => panic("builtin impl provider: trait is not registered")
        },
        none => none
    }
}

fn freeze_builtin_predicates(
    owner_type_vars: List<Int>, specs: List<BuiltinPredicateSpec>
) -> FrozenImplPredicateSet {
    let mut predicates: List<TypedImplPredicate> = []
    let mut seen: Set<Str> = set_new()
    for spec in specs {
        let subject_var = owner_type_vars.get(
            spec.subject_param_index).unwrap_or(-1)
        if subject_var < 0 {
            panic("builtin impl owner: predicate subject is missing")
        }
        let key = "${spec.subject_param_index.to_str()}|${spec.trait_name}"
        if seen.contains(key) {
            panic("builtin impl owner: duplicate predicate")
        }
        seen.insert(key)
        predicates.push(make_typed_impl_predicate(
            spec.subject_param_index, subject_var, spec.trait_name, [],
            direct_impl_predicate_provenance()))
    }
    freeze_impl_predicate_set(owner_type_vars, predicates)
}

fn scheme_bounds_match_owner(
    scheme: TypeScheme, predicates: FrozenImplPredicateSet
) -> Bool {
    for bound in scheme.bounds {
        if bound.assoc_constraints.len() != 0 { return false }
        let found = frozen_impl_predicates(predicates).any(fn(predicate) {
            impl_predicate_subject_type_var(predicate) == bound.type_var &&
                impl_predicate_trait_name(predicate) == bound.trait_name
        })
        if !found { return false }
    }
    true
}

fn install_builtin_method_owner(
    mut env: TypeEnv, sink: CollectingSink,
    target_type_name: Str,
    trait_name: Str?, type_params: List<Str>, owner_type_vars: List<Int>,
    predicate_specs: List<BuiltinPredicateSpec>,
    methods: Map<Str, TypeScheme>,
    method_intrinsics: Map<Str, IntrinsicRef>,
    provider_site: BuiltinImplProviderSite
) {
    let span = span_zero()
    if type_params.len() != owner_type_vars.len() {
        panic("builtin impl owner: type-parameter arity mismatch")
    }
    let predicates = freeze_builtin_predicates(
        owner_type_vars, predicate_specs)
    let mut cores: Map<Str, ImplMethodSchemeCore> = map_new()
    let mut entries = methods.entries()
    entries.sort_by(compare_by_first)
    for entry in entries {
        let (method_name, scheme) = entry
        if !scheme_bounds_match_owner(scheme, predicates) {
            panic("builtin impl owner: method scheme has non-owner bounds")
        }
        for owner_var in owner_type_vars {
            if !scheme.type_vars.contains(owner_var) {
                panic("builtin impl owner: method core lost owner type variable")
            }
        }
        cores.insert(method_name, make_impl_method_scheme_core(
            scheme.ty, scheme.type_vars, scheme.def_id))
    }
    let mut method_names = cores.keys()
    method_names.sort()
    let provider_ref = builtin_impl_provider(provider_site)
    let trait_ref = builtin_impl_trait_ref(env, trait_name)
    let identity = builtin_impl_identity(
        env, target_type_name, provider_ref, trait_ref, cores)
    let owner_ref = identity.0
    let method_refs = identity.1
    let owner = ImplEntry {
        trait_name: trait_name,
        target_type_name: target_type_name,
        type_params: type_params,
        type_param_vars: owner_type_vars,
        predicates: predicates,
        method_names: method_names,
        assoc_types: map_new(),
        method_schemes: map_clone(cores),
        method_refs: method_refs,
        method_intrinsics: map_clone(method_intrinsics),
        provider_ref: some(provider_ref),
        trait_ref: trait_ref,
        owner_ref: some(owner_ref),
        delegate_plan: delegate_plan_not_applicable(),
        span: span
    }
    add_impl(env.trait_reg, owner)
    let mut core_entries = cores.entries()
    core_entries.sort_by(compare_by_first)
    for entry in core_entries {
        let (method_name, core) = entry
        let _ = install_method_core(
            env.trait_reg, sink,
            target_type_name, method_name, core,
            method_refs.get(method_name).unwrap(), span)
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
    predicate_specs: List<BuiltinPredicateSpec>,
    method_names: List<Str>
) {
    let span = span_zero()
    let mut type_args: List<Type> = []
    for type_var_id in type_var_ids {
        type_args.push(Type::TypeVar { id: type_var_id, name: none })
    }
    let self_type = builtin_impl_self_type(target_type_name, type_args)
    let predicates = freeze_builtin_predicates(
        type_var_ids, predicate_specs)
    let provider_ref = builtin_impl_provider(builtin_trait_factory_site())
    let trait_ref = builtin_impl_trait_ref(
        env, some(trait_name)).unwrap()
    let mut exact: Map<Str, ImplMethodSchemeCore> = map_new()
    match env.trait_reg.traits.get(trait_name) {
        some(trait_def) => {
            for method_name in method_names {
                match trait_def.methods.find(fn(method) {
                    method.name == method_name
                }) {
                    some(method) => exact.insert(
                        method_name,
                        specialize_trait_method_scheme(
                            trait_def, method, self_type, [],
                            type_var_ids, map_new())),
                    none => {}
                }
            }
        },
        none => {}
    }
    let identity = builtin_impl_identity(
        env, target_type_name, provider_ref, some(trait_ref), exact)
    let owner_ref = identity.0
    let method_refs = identity.1
    add_impl(env.trait_reg, ImplEntry {
        trait_name: some(trait_name),
        target_type_name: target_type_name,
        type_params: type_params,
        type_param_vars: type_var_ids,
        predicates: predicates,
        method_names: method_names,
        assoc_types: map_new(),
        method_schemes: map_clone(exact),
        method_refs: method_refs,
        method_intrinsics: map_new(),
        provider_ref: some(provider_ref),
        trait_ref: some(trait_ref),
        owner_ref: some(owner_ref),
        delegate_plan: delegate_plan_not_applicable(),
        span: span
    })
    let mut entries = exact.entries()
    entries.sort_by(compare_by_first)
    for entry in entries {
        let (method_name, core) = entry
        let _ = install_method_core(
            env.trait_reg, sink, target_type_name, method_name, core,
            method_refs.get(method_name).unwrap(), span)
    }
}

// The builtin Option derived-body inventory is a front-end fact.  Consumers
// receive the exact final registry owners in the historical emission order;
// they never reconstruct a provider from target/trait/backend spellings.
const BUILTIN_OPTION_DERIVED_TRAITS: List<Str> = ["Eq", "Debug", "Clone"]

fn require_builtin_option_derived_owner(
    env: TypeEnv, trait_name: Str
) -> ImplEntry {
    let provider_ref = builtin_impl_provider(builtin_trait_factory_site())
    let trait_ref = builtin_impl_trait_ref(
        env, some(trait_name)).unwrap()
    let owner = match find_impl_by_provider(
        env.trait_reg, BUILTIN_OPTION, some(trait_ref), provider_ref
    ) {
        some(found) => found,
        none => panic("builtin Option derived owner is missing")
    }
    if owner.target_type_name != BUILTIN_OPTION {
        panic("builtin Option derived owner is not final")
    }
    match owner.trait_name {
        some(found) => if found != trait_name {
            panic("builtin Option derived owner changed trait")
        },
        none => panic("builtin Option derived owner lost trait")
    }
    owner
}

pub fn builtin_option_derived_owners(env: TypeEnv) -> List<ImplEntry> {
    if BUILTIN_OPTION_DERIVED_TRAITS.len() != 3 ||
       BUILTIN_OPTION_DERIVED_TRAITS.get(0).unwrap_or("") != "Eq" ||
       BUILTIN_OPTION_DERIVED_TRAITS.get(1).unwrap_or("") != "Debug" ||
       BUILTIN_OPTION_DERIVED_TRAITS.get(2).unwrap_or("") != "Clone" {
        panic("builtin Option derived owner census drifted")
    }
    let mut owners: List<ImplEntry> = []
    for trait_name in BUILTIN_OPTION_DERIVED_TRAITS {
        owners.push(require_builtin_option_derived_owner(env, trait_name))
    }

    // Ord has no Option registry owner.  The historical C-only descriptor was
    // unreachable backend behavior, not an implicit language implementation.
    let provider_ref = builtin_impl_provider(builtin_trait_factory_site())
    let ord_ref = builtin_impl_trait_ref(env, some("Ord")).unwrap()
    if find_impl_by_provider(
            env.trait_reg, BUILTIN_OPTION, some(ord_ref), provider_ref
        ).is_some() {
        panic("builtin Option derived owner census gained Ord")
    }
    owners
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
    register_scalar_method_intrinsics(env, sink)
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

fn register_scalar_method_intrinsics(
    mut env: TypeEnv, sink: CollectingSink
) {
    let mut str_methods: Map<Str, TypeScheme> = map_new()
    str_methods.insert("len", mono(Type::FnType {
        params: [STR], return_type: INT, effects: EMPTY_ROW }))
    for name in ["contains", "starts_with", "ends_with"] {
        str_methods.insert(name, mono(Type::FnType {
            params: [STR, STR], return_type: BOOL, effects: EMPTY_ROW }))
    }
    str_methods.insert("slice", mono(Type::FnType {
        params: [STR, INT, INT], return_type: STR, effects: EMPTY_ROW }))
    for name in ["trim", "to_upper", "to_lower", "trim_start", "trim_end"] {
        str_methods.insert(name, mono(Type::FnType {
            params: [STR], return_type: STR, effects: EMPTY_ROW }))
    }
    str_methods.insert("replace", mono(Type::FnType {
        params: [STR, STR, STR], return_type: STR, effects: EMPTY_ROW }))
    str_methods.insert("split", mono(Type::FnType {
        params: [STR, STR], return_type: make_list_struct(STR),
        effects: EMPTY_ROW }))
    str_methods.insert("char_at", mono(Type::FnType {
        params: [STR, INT], return_type: make_option_type(STR),
        effects: EMPTY_ROW }))
    str_methods.insert("index_of", mono(Type::FnType {
        params: [STR, STR], return_type: make_option_type(INT),
        effects: EMPTY_ROW }))
    for name in ["pad_start", "pad_end"] {
        str_methods.insert(name, mono(Type::FnType {
            params: [STR, INT, STR], return_type: STR,
            effects: EMPTY_ROW }))
    }
    str_methods.insert("repeat", mono(Type::FnType {
        params: [STR, INT], return_type: STR, effects: EMPTY_ROW }))
    str_methods.insert("char_code_at", mono(Type::FnType {
        params: [STR, INT], return_type: make_option_type(INT),
        effects: EMPTY_ROW }))
    str_methods.insert("is_empty", mono(Type::FnType {
        params: [STR], return_type: BOOL, effects: EMPTY_ROW }))
    str_methods.insert("last_index_of", mono(Type::FnType {
        params: [STR, STR], return_type: make_option_type(INT),
        effects: EMPTY_ROW }))

    let mut str_intrinsics: Map<Str, IntrinsicRef> = map_new()
    install_intrinsic(str_intrinsics, "len", BUILTIN_METHOD_STR_LEN)
    install_intrinsic(str_intrinsics, "contains", BUILTIN_METHOD_STR_CONTAINS)
    install_intrinsic(
        str_intrinsics, "starts_with", BUILTIN_METHOD_STR_STARTS_WITH)
    install_intrinsic(str_intrinsics, "ends_with", BUILTIN_METHOD_STR_ENDS_WITH)
    install_intrinsic(str_intrinsics, "slice", BUILTIN_METHOD_STR_SLICE)
    install_intrinsic(str_intrinsics, "trim", BUILTIN_METHOD_STR_TRIM)
    install_intrinsic(str_intrinsics, "to_upper", BUILTIN_METHOD_STR_TO_UPPER)
    install_intrinsic(str_intrinsics, "to_lower", BUILTIN_METHOD_STR_TO_LOWER)
    install_intrinsic(str_intrinsics, "replace", BUILTIN_METHOD_STR_REPLACE)
    install_intrinsic(str_intrinsics, "split", BUILTIN_METHOD_STR_SPLIT)
    install_intrinsic(str_intrinsics, "char_at", BUILTIN_METHOD_STR_CHAR_AT)
    install_intrinsic(str_intrinsics, "index_of", BUILTIN_METHOD_STR_INDEX_OF)
    install_intrinsic(str_intrinsics, "pad_start", BUILTIN_METHOD_STR_PAD_START)
    install_intrinsic(str_intrinsics, "pad_end", BUILTIN_METHOD_STR_PAD_END)
    install_intrinsic(str_intrinsics, "repeat", BUILTIN_METHOD_STR_REPEAT)
    install_intrinsic(
        str_intrinsics, "char_code_at", BUILTIN_METHOD_STR_CHAR_CODE_AT)
    install_intrinsic(
        str_intrinsics, "trim_start", BUILTIN_METHOD_STR_TRIM_START)
    install_intrinsic(str_intrinsics, "trim_end", BUILTIN_METHOD_STR_TRIM_END)
    install_intrinsic(str_intrinsics, "is_empty", BUILTIN_METHOD_STR_IS_EMPTY)
    install_intrinsic(
        str_intrinsics, "last_index_of", BUILTIN_METHOD_STR_LAST_INDEX_OF)
    install_builtin_method_owner(
        env, sink, "Str",
        none, [], [], [],
        str_methods, str_intrinsics,
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_STR_CORE))

    let mut int_methods: Map<Str, TypeScheme> = map_new()
    int_methods.insert("to_str", mono(Type::FnType {
        params: [INT], return_type: STR, effects: EMPTY_ROW }))
    let mut int_intrinsics: Map<Str, IntrinsicRef> = map_new()
    install_intrinsic(int_intrinsics, "to_str", BUILTIN_METHOD_INT_TO_STR)
    install_builtin_method_owner(
        env, sink, "Int",
        none, [], [], [],
        int_methods, int_intrinsics,
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_INT_CORE))

    let mut float_methods: Map<Str, TypeScheme> = map_new()
    float_methods.insert("to_str", mono(Type::FnType {
        params: [FLOAT], return_type: STR, effects: EMPTY_ROW }))
    let mut float_intrinsics: Map<Str, IntrinsicRef> = map_new()
    install_intrinsic(
        float_intrinsics, "to_str", BUILTIN_METHOD_FLOAT_TO_STR)
    install_builtin_method_owner(
        env, sink, "Float",
        none, [], [], [],
        float_methods, float_intrinsics,
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_FLOAT_CORE))
}

// Normal compilation publishes no std HOF method core before source
// registration. Option HOFs are true builtins and remain final here.
pub fn register_hof_intrinsics(mut env: TypeEnv, sink: CollectingSink) {
    register_option_hof(env, sink)
}

fn registered_intrinsic_count(env: TypeEnv, intrinsic: IntrinsicRef) -> Int {
    let mut count = 0
    for map_entry in env.trait_reg.trait_impls.entries() {
        let (_, owners) = map_entry
        for owner in owners {
            for method_entry in owner.method_intrinsics.entries() {
                let (_, candidate) = method_entry
                if intrinsic_ref_same(candidate, intrinsic) {
                    count = count + 1
                }
            }
        }
    }
    count
}

fn registered_intrinsic_scheme(
    env: TypeEnv, intrinsic: IntrinsicRef
) -> TypeScheme {
    let mut found: TypeScheme? = none
    for map_entry in env.trait_reg.trait_impls.entries() {
        let (_, owners) = map_entry
        for owner in owners {
            for method_entry in owner.method_intrinsics.entries() {
                let (method_name, candidate) = method_entry
                if intrinsic_ref_same(candidate, intrinsic) {
                    let core = match owner.method_schemes.get(method_name) {
                        some(value) => value,
                        none => panic(
                            "builtin method Core shadow: exact core is missing")
                    }
                    if found.is_some() {
                        panic("builtin method Core shadow: core is not unique")
                    }
                    found = some(impl_method_core_as_scheme(core))
                }
            }
        }
    }
    match found {
        some(value) => value,
        none => panic("builtin method Core shadow: core was not registered")
    }
}

fn append_builtin_core_type(
    env: TypeEnv, owner: SymbolRef, scheme_vars: List<Int>,
    ty: Type, mut nodes: List<FlowTypeNode>
) -> CoreTypeRef {
    match ty {
        Type::IntType => {
            let reference = make_flow_type_ref(nodes.len())
            nodes.push(make_flow_int_type_node(reference))
            make_core_type_ref(nodes.len() - 1)
        },
        Type::FloatType => {
            let reference = make_flow_type_ref(nodes.len())
            nodes.push(make_flow_float_type_node(reference))
            make_core_type_ref(nodes.len() - 1)
        },
        Type::StrType => {
            let reference = make_flow_type_ref(nodes.len())
            nodes.push(make_flow_str_type_node(reference))
            make_core_type_ref(nodes.len() - 1)
        },
        Type::BoolType => {
            let reference = make_flow_type_ref(nodes.len())
            nodes.push(make_flow_bool_type_node(reference))
            make_core_type_ref(nodes.len() - 1)
        },
        Type::UnitType => {
            let reference = make_flow_type_ref(nodes.len())
            nodes.push(make_flow_unit_type_node(reference))
            make_core_type_ref(nodes.len() - 1)
        },
        Type::NeverType => {
            let reference = make_flow_type_ref(nodes.len())
            nodes.push(make_flow_never_type_node(reference))
            make_core_type_ref(nodes.len() - 1)
        },
        Type::TypeVar { id, .. } => {
            let parameter_index = scheme_vars.index_of(id).unwrap_or(-1)
            if parameter_index < 0 || scheme_vars.len() == 0 {
                panic("builtin method Core shadow: unbound type variable")
            }
            let parameter = make_flow_generic_param_fact(
                owner, parameter_index, scheme_vars.len(), [])
            let reference = make_flow_type_ref(nodes.len())
            nodes.push(make_flow_parameter_type_node(reference, parameter))
            make_core_type_ref(nodes.len() - 1)
        },
        Type::StructType { name, type_params } => {
            let mut arguments: List<FlowTypeRef> = []
            for argument in type_params {
                let core_ref = append_builtin_core_type(
                    env, owner, scheme_vars, argument, nodes)
                arguments.push(make_flow_type_ref(
                    core_type_ref_index(core_ref)))
            }
            let nominal = match impl_target_symbol(env, name) {
                some(symbol) => symbol,
                none => panic(
                    "builtin method Core shadow: struct owner is missing")
            }
            let reference = make_flow_type_ref(nodes.len())
            let fields: List<FlowNominalFieldFact> = []
            let parameters: List<FlowGenericParamFact> = []
            let edges: List<FlowResourceDependencyEdge> = []
            nodes.push(make_flow_struct_type_node(
                reference, nominal, arguments, fields,
                flow_type_seed_unique(), none, parameters, edges))
            make_core_type_ref(nodes.len() - 1)
        },
        Type::EnumType { name, type_params } => {
            let mut arguments: List<FlowTypeRef> = []
            for argument in type_params {
                let core_ref = append_builtin_core_type(
                    env, owner, scheme_vars, argument, nodes)
                arguments.push(make_flow_type_ref(
                    core_type_ref_index(core_ref)))
            }
            let nominal = match impl_target_symbol(env, name) {
                some(symbol) => symbol,
                none => panic(
                    "builtin method Core shadow: enum owner is missing")
            }
            let reference = make_flow_type_ref(nodes.len())
            let fields: List<FlowNominalFieldFact> = []
            let parameters: List<FlowGenericParamFact> = []
            let edges: List<FlowResourceDependencyEdge> = []
            nodes.push(make_flow_enum_type_node(
                reference, nominal, arguments, fields,
                flow_type_seed_unique(), none, parameters, edges))
            make_core_type_ref(nodes.len() - 1)
        },
        Type::FnType { params, return_type, .. } => {
            let mut parameters: List<FlowTypeRef> = []
            for param in params {
                let core_ref = append_builtin_core_type(
                    env, owner, scheme_vars, param, nodes)
                parameters.push(make_flow_type_ref(
                    core_type_ref_index(core_ref)))
            }
            let result_ref = append_builtin_core_type(
                env, owner, scheme_vars, return_type, nodes)
            let reference = make_flow_type_ref(nodes.len())
            nodes.push(make_flow_callable_type_node(
                reference, parameters,
                make_flow_type_ref(core_type_ref_index(result_ref))))
            make_core_type_ref(nodes.len() - 1)
        },
        _ => panic("builtin method Core shadow: unsupported exact type")
    }
}

// Live C0/B-201 producer+consumer.  It closes the exact ContractOnly builtin
// method inventory on every checker construction and then discards the shadow;
// ordinary compilation still consumes the same registry owner payload.
pub fn validate_builtin_method_core_shadow(env: TypeEnv) {
    let module_body = make_module_body_ref(
        "$builtin", "builtin:method-sites")
    let mut entries: List<ExecutableEntry> = []
    let mut manifests: List<BinderManifest> = []
    let mut type_nodes: List<FlowTypeNode> = []
    let mut callables: List<CoreCallableContract> = []
    for tag in 0..BUILTIN_METHOD_SITE_COUNT {
        let intrinsic = builtin_method_intrinsic(
            builtin_method_site_from_tag(tag))
        if registered_intrinsic_count(env, intrinsic) != 1 {
            panic("builtin method Core shadow: registry relation is not unique")
        }
        let executable = make_named_executable_ref(
            intrinsic_ref_symbol(intrinsic))
        entries.push(make_executable_entry(
            executable, make_module_body_parent(module_body),
            executable_kind_builtin_intrinsic(), make_contract_only()))
        manifests.push(make_binder_manifest(executable, []))
        let scheme = registered_intrinsic_scheme(env, intrinsic)
        match scheme.ty {
            Type::FnType { params, return_type, .. } => {
                let mut parameter_types: List<CoreTypeRef> = []
                let mut flow_parameter_types: List<FlowTypeRef> = []
                let mut parameter_roles: List<FlowSemanticRole> = []
                for param in params {
                    let param_ref = append_builtin_core_type(
                        env, intrinsic_ref_symbol(intrinsic),
                        scheme.type_vars, param, type_nodes)
                    parameter_types.push(param_ref)
                    flow_parameter_types.push(make_flow_type_ref(
                        core_type_ref_index(param_ref)))
                    parameter_roles.push(flow_semantic_role_read())
                }
                let result_type = append_builtin_core_type(
                    env, intrinsic_ref_symbol(intrinsic),
                    scheme.type_vars, return_type, type_nodes)
                let semantic_contract = make_flow_call_contract(
                    flow_parameter_types, parameter_roles,
                    make_flow_type_ref(core_type_ref_index(result_type)),
                    flow_semantic_role_read(),
                    make_fresh_flow_value_origin())
                callables.push(make_core_callable_contract(
                    executable,
                    make_symbol_origin_ref(intrinsic_ref_symbol(intrinsic)),
                    parameter_types, [], result_type,
                    flow_callable_mode_contract_only(),
                    semantic_contract, []))
            },
            _ => panic("builtin method Core shadow: core is not callable")
        }
    }
    let program = make_core_program(
        make_core_type_graph(type_nodes), callables, [], [],
        make_executable_inventory(entries), manifests)
    if core_program_body_count(program) != 0 ||
       executable_inventory_count(core_program_inventory(program)) !=
            BUILTIN_METHOD_SITE_COUNT ||
       core_program_manifests(program).len() != BUILTIN_METHOD_SITE_COUNT {
        panic("builtin method Core shadow: closed census drifted")
    }
}

// Only checker.load_prelude's no-std branch may consume this fallback.
pub fn finalize_std_hof_fallbacks(
    mut env: TypeEnv, sink: CollectingSink
) {
    register_list_hof(env, sink)
    register_map_hof(env, sink)
    register_set_hof(env, sink)
}

// ============================================================
// register_effects: "io" and "fail" built-in effects
// ============================================================

fn register_effects(mut env: TypeEnv) {
    // io effect
    env.types.effects.insert("io", EffectDef {
        name: "io",
        owner_ref: none, handled_ref: none,
        type_params: [],
        type_param_vars: [],
        ops: [
            EffectOpDef { name: "read", operation_ref: none, params: [STR], return_type: STR, has_default: false },
            EffectOpDef { name: "write", operation_ref: none, params: [STR, STR], return_type: UNIT, has_default: false }
        ],
        built_in_kind: some(BuiltInKind::BkIo),
        all_have_defaults: false
    })

    // fail effect
    let fail_t_id = env.fresh_var_id()
    let fail_t = Type::TypeVar { id: fail_t_id, name: none }
    env.types.effects.insert("fail", EffectDef {
        name: "fail",
        owner_ref: none, handled_ref: none,
        type_params: ["E"],
        type_param_vars: [fail_t_id],
        ops: [
            EffectOpDef { name: "raise", operation_ref: none, params: [fail_t], return_type: NEVER, has_default: false }
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
    let cell_owner = make_symbol_ref(
        "$builtin", namespace_nominal(), BUILTIN_CELL, "builtin:Cell")
    let cell_member = make_symbol_ref(
        "$builtin", namespace_member(), "${BUILTIN_CELL}::value",
        "builtin:Cell|field:0|kind:struct-field")
    env.types.structs.insert(BUILTIN_CELL, StructDef {
        name: BUILTIN_CELL,
        owner_ref: make_registered_nominal_ref(cell_owner, BUILTIN_CELL),
        type_params: ["T"],
        type_param_vars: [cell_t_id],
        fields: [StructField {
            name: "value", ty: cell_t, is_pub: true,
            field_ref: make_nominal_field_ref(
                cell_owner, cell_member, 0, "value"),
            field_index: 0,
            span: span_zero()
        }],
        derive_attrs: [],
        derived_provider_plan: none,
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
        ty: Type::FnType { params: [ctor_t], return_type: ctor_ret, effects: EMPTY_ROW },
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
        ty: Type::FnType { params: [self_type], return_type: m_t, effects: mut_row },
        type_vars: [m_t_id],
        bounds: [],
        def_id: none
    })

    // set: (Cell<T>, T) -> () / mut
    methods.insert("set", TypeScheme {
        ty: Type::FnType { params: [self_type, m_t], return_type: UNIT, effects: mut_row },
        type_vars: [m_t_id],
        bounds: [],
        def_id: none
    })

    // update: (Cell<T>, (T) -> T) -> () / mut
    let update_cb = Type::FnType { params: [m_t], return_type: m_t, effects: EMPTY_ROW }
    methods.insert("update", TypeScheme {
        ty: Type::FnType { params: [self_type, update_cb], return_type: UNIT, effects: mut_row },
        type_vars: [m_t_id],
        bounds: [],
        def_id: none
    })

    let mut intrinsics: Map<Str, IntrinsicRef> = map_new()
    install_intrinsic(intrinsics, "get", BUILTIN_METHOD_CELL_GET)
    install_intrinsic(intrinsics, "set", BUILTIN_METHOD_CELL_SET)
    install_intrinsic(intrinsics, "update", BUILTIN_METHOD_CELL_UPDATE)
    install_builtin_method_owner(
        env, sink, BUILTIN_CELL,
        none, [], [], [], methods, intrinsics,
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_CELL_CORE))
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
    let option_owner = make_symbol_ref(
        "$builtin", namespace_nominal(), BUILTIN_OPTION, "builtin:Option")
    let option_registered = make_registered_nominal_ref(
        option_owner, BUILTIN_OPTION)
    let some_member = make_symbol_ref(
        "$builtin", namespace_member(), "Option|variant:0",
        "builtin:Option|variant:0")
    let none_member = make_symbol_ref(
        "$builtin", namespace_member(), "Option|variant:1",
        "builtin:Option|variant:1")
    let some_ref = make_variant_ref(option_registered, some_member, 0)
    let none_ref = make_variant_ref(option_registered, none_member, 1)
    let some_field_member = make_symbol_ref(
        "$builtin", namespace_member(), "Option|variant:0|field:0",
        "builtin:Option|variant:0|field:0")
    env.types.enums.insert(BUILTIN_OPTION, EnumDef {
        name: BUILTIN_OPTION,
        owner_ref: option_registered,
        type_params: ["T"],
        type_param_vars: [option_t_id],
        variants: [
            EnumVariant { name: "some", fields: [option_t], field_names: none },
            EnumVariant { name: "none", fields: [], field_names: none }
        ],
        variant_refs: [some_ref, none_ref],
        variant_field_refs: [[make_variant_field_ref(
            some_ref, some_field_member, 0)], []],
        derive_attrs: [],
        derived_provider_plan: none,
        variant_index: option_vi
    })

    env.types.variant_to_enum.insert("some", BUILTIN_OPTION)
    env.types.variant_to_enum.insert("none", BUILTIN_OPTION)

    // some constructor: (T) -> Option<T>
    let some_t_id = env.fresh_var_id()
    let some_t = Type::TypeVar { id: some_t_id, name: none }
    env.bind("some", TypeScheme {
        ty: Type::FnType { params: [some_t], return_type: make_option_type(some_t), effects: EMPTY_ROW },
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
        ty: Type::FnType { params: [self_type], return_type: BOOL, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    methods.insert("is_none", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: BOOL, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    methods.insert("unwrap_or", TypeScheme {
        ty: Type::FnType { params: [self_type, t], return_type: t, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    methods.insert("unwrap", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: t, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        def_id: none
    })

    let e_id = env.fresh_var_id()
    let e = Type::TypeVar { id: e_id, name: none }
    let self_type2 = make_option_type(Type::TypeVar { id: t_id, name: none })
    let fail_eff = Effect::FailEffect { error_type: e }
    methods.insert("to_fail", TypeScheme {
        ty: Type::FnType { params: [self_type2, e], return_type: Type::TypeVar { id: t_id, name: none }, effects: EffectRow { effects: [fail_eff], tail: none } },
        type_vars: [t_id, e_id],
        bounds: [],
        def_id: none
    })
    let mut intrinsics: Map<Str, IntrinsicRef> = map_new()
    install_intrinsic(intrinsics, "unwrap_or", BUILTIN_METHOD_OPTION_UNWRAP_OR)
    install_intrinsic(intrinsics, "unwrap", BUILTIN_METHOD_OPTION_UNWRAP)
    install_intrinsic(intrinsics, "is_some", BUILTIN_METHOD_OPTION_IS_SOME)
    install_intrinsic(intrinsics, "is_none", BUILTIN_METHOD_OPTION_IS_NONE)
    install_intrinsic(intrinsics, "to_fail", BUILTIN_METHOD_OPTION_TO_FAIL)
    install_builtin_method_owner(
        env, sink, BUILTIN_OPTION,
        none, [], [], [], methods, intrinsics,
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_OPTION_CORE))
}

// ============================================================
// register_eq_trait: Eq trait + primitive impls
// ============================================================

fn register_eq_trait(mut env: TypeEnv, sink: CollectingSink) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let eq_fn = Type::FnType { params: [self_var, self_var], return_type: BOOL, effects: EMPTY_ROW }
    let ne_fn = Type::FnType { params: [self_var, self_var], return_type: BOOL, effects: EMPTY_ROW }

    let owner_ref = builtin_trait_symbol("Eq")
    install_builtin_trait_contract(
        env, "Eq", owner_ref, [], [self_var_id], [
            TraitMethodDef { name: "eq", method_ref: builtin_trait_method(owner_ref, 0, 0, "eq"), ty: eq_fn, has_default: false, param_mutabilities: [false, false], method_type_params: [] },
            TraitMethodDef { name: "ne", method_ref: builtin_trait_method(owner_ref, 1, 1, "ne"), ty: ne_fn, has_default: true, param_mutabilities: [false, false], method_type_params: [] }
        ], [], [])

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
        [BuiltinPredicateSpec { subject_param_index: 0, trait_name: "Eq" }],
        ["eq", "ne"])
}

// ============================================================
// register_clone_trait: Clone trait + primitive + collection impls
// ============================================================

fn register_clone_trait(mut env: TypeEnv, sink: CollectingSink) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let clone_fn = Type::FnType { params: [self_var], return_type: self_var, effects: EMPTY_ROW }

    let owner_ref = builtin_trait_symbol("Clone")
    install_builtin_trait_contract(
        env, "Clone", owner_ref, [], [self_var_id], [
            TraitMethodDef { name: "clone", method_ref: builtin_trait_method(owner_ref, 0, 0, "clone"), ty: clone_fn, has_default: false, param_mutabilities: [false], method_type_params: [] }
        ], [], [])

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

    // Ring 0.1 Drop is effect-free on every path.
    let drop_fn = Type::FnType { params: [self_var], return_type: UNIT, effects: EMPTY_ROW }

    let owner_ref = builtin_trait_symbol("Drop")
    install_builtin_trait_contract(
        env, "Drop", owner_ref, [], [self_var_id], [
            TraitMethodDef { name: "drop", method_ref: builtin_trait_method(owner_ref, 0, 0, "drop"), ty: drop_fn, has_default: false, param_mutabilities: [false], method_type_params: [] }
        ], [], [])
}

// ============================================================
// register_option_clone: Option<T: Clone> Clone impl
// ============================================================

fn register_option_clone(mut env: TypeEnv, sink: CollectingSink) {
    let t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Clone", BUILTIN_OPTION, ["T"], [t_id],
        [BuiltinPredicateSpec { subject_param_index: 0, trait_name: "Clone" }],
        ["clone"])
}

// ============================================================
// register_ord_trait: Ord trait + primitive impls
// ============================================================

fn register_ord_trait(mut env: TypeEnv, sink: CollectingSink) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let cmp_fn = Type::FnType { params: [self_var, self_var], return_type: INT, effects: EMPTY_ROW }

    let owner_ref = builtin_trait_symbol("Ord")
    install_builtin_trait_contract(
        env, "Ord", owner_ref, [], [self_var_id], [
            TraitMethodDef { name: "cmp", method_ref: builtin_trait_method(owner_ref, 0, 0, "cmp"), ty: cmp_fn, has_default: false, param_mutabilities: [false, false], method_type_params: [] }
        ], [], [])

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

    let debug_fn = Type::FnType { params: [self_var], return_type: STR, effects: EMPTY_ROW }

    let owner_ref = builtin_trait_symbol("Debug")
    install_builtin_trait_contract(
        env, "Debug", owner_ref, [], [self_var_id], [
            TraitMethodDef { name: "debug", method_ref: builtin_trait_method(owner_ref, 0, 0, "debug"), ty: debug_fn, has_default: false, param_mutabilities: [false], method_type_params: [] }
        ], [], [])

    // Primitive impls
    for prim in ["Int", "Float", "Str", "Bool"] {
        add_builtin_impl(env, sink, "Debug", prim, [], [], [], ["debug"])
    }

    // List<T: Debug> Debug impl
    let list_t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Debug", BUILTIN_LIST,
        ["T"], [list_t_id],
        [BuiltinPredicateSpec { subject_param_index: 0, trait_name: "Debug" }],
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
        [BuiltinPredicateSpec { subject_param_index: 0, trait_name: "Debug" }],
        ["debug"])
}

// ============================================================
// register_hash_trait: Hash trait + primitive impls
// ============================================================

fn register_hash_trait(mut env: TypeEnv, sink: CollectingSink) {
    let self_var_id = env.fresh_var_id()
    let self_var = Type::TypeVar { id: self_var_id, name: none }

    let hash_fn = Type::FnType { params: [self_var], return_type: INT, effects: EMPTY_ROW }

    let owner_ref = builtin_trait_symbol("Hash")
    install_builtin_trait_contract(
        env, "Hash", owner_ref, [], [self_var_id], [
            TraitMethodDef { name: "hash", method_ref: builtin_trait_method(owner_ref, 0, 0, "hash"), ty: hash_fn, has_default: false, param_mutabilities: [false], method_type_params: [] }
        ], [], [])

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
    let t_id = env.fresh_var_id()
    let t = Type::TypeVar { id: t_id, name: none }
    let mut u_id = env.fresh_var_id()
    let mut u = Type::TypeVar { id: u_id, name: none }
    let mut orow = open_row(env)
    let mut cb = Type::FnType { params: [t], return_type: u, effects: orow.eff }
    methods.insert("map", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_list_struct(u), effects: orow.eff },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // filter: (List<T>, (T) -> Bool / e) -> List<T> / e
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("filter", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_list_struct(t), effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // flat_map: (List<T>, (T) -> List<U> / e) -> List<U> / e
    u_id = env.fresh_var_id()
    u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: make_list_struct(u), effects: orow.eff }
    methods.insert("flat_map", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_list_struct(u), effects: orow.eff },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // fold: (List<T>, U, (U, T) -> U / e) -> U / e
    u_id = env.fresh_var_id()
    u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [u, t], return_type: u, effects: orow.eff }
    methods.insert("fold", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), u, cb], return_type: u, effects: orow.eff },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // any: (List<T>, (T) -> Bool / e) -> Bool / e
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("any", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: BOOL, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // all: (List<T>, (T) -> Bool / e) -> Bool / e
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("all", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: BOOL, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // find: (List<T>, (T) -> Bool / e) -> Option<T> / e
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("find", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_option_type(t), effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // find_index: (List<T>, (T) -> Bool / e) -> Option<Int> / e
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("find_index", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_option_type(INT), effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // sort_by: (List<T>, (T, T) -> Int / e) -> () / e
    orow = open_row(env)
    cb = Type::FnType { params: [t, t], return_type: INT, effects: orow.eff }
    methods.insert("sort_by", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: UNIT, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })
    install_builtin_method_owner(
        env, sink, BUILTIN_LIST,
        none, ["T"], [t_id], [],
        methods, map_new(),
        builtin_impl_provider_site_from_tag(
            BUILTIN_PROVIDER_LIST_HOF_FALLBACK))
}

// ============================================================
// HOF: register_map_hof
// ============================================================

fn register_map_hof(mut env: TypeEnv, sink: CollectingSink) {
    let mut bounded_methods: Map<Str, TypeScheme> = map_new()
    let mut unbounded_methods: Map<Str, TypeScheme> = map_new()

    let bounded_k_id = env.fresh_var_id()
    let bounded_k = Type::TypeVar { id: bounded_k_id, name: none }
    let bounded_v_id = env.fresh_var_id()
    let bounded_v = Type::TypeVar { id: bounded_v_id, name: none }

    // map_values: (Map<K,V>, (V) -> U / e) -> Map<K,U> / e
    let mut u_id = env.fresh_var_id()
    let mut u = Type::TypeVar { id: u_id, name: none }
    let mut orow = open_row(env)
    let mut cb = Type::FnType {
        params: [bounded_v], return_type: u, effects: orow.eff
    }
    bounded_methods.insert("map_values", TypeScheme {
        ty: Type::FnType {
            params: [make_map_type(bounded_k, bounded_v), cb],
            return_type: make_map_type(bounded_k, u), effects: orow.eff
        },
        type_vars: [bounded_k_id, bounded_v_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // filter: (Map<K,V>, (K, V) -> Bool / e) -> Map<K,V> / e
    orow = open_row(env)
    cb = Type::FnType {
        params: [bounded_k, bounded_v], return_type: BOOL, effects: orow.eff
    }
    bounded_methods.insert("filter", TypeScheme {
        ty: Type::FnType {
            params: [make_map_type(bounded_k, bounded_v), cb],
            return_type: make_map_type(bounded_k, bounded_v),
            effects: orow.eff
        },
        type_vars: [bounded_k_id, bounded_v_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    let unbounded_k_id = env.fresh_var_id()
    let unbounded_k = Type::TypeVar { id: unbounded_k_id, name: none }
    let unbounded_v_id = env.fresh_var_id()
    let unbounded_v = Type::TypeVar { id: unbounded_v_id, name: none }

    // fold: (Map<K,V>, U, (U, K, V) -> U / e) -> U / e
    u_id = env.fresh_var_id()
    u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType {
        params: [u, unbounded_k, unbounded_v],
        return_type: u, effects: orow.eff
    }
    unbounded_methods.insert("fold", TypeScheme {
        ty: Type::FnType {
            params: [make_map_type(unbounded_k, unbounded_v), u, cb],
            return_type: u, effects: orow.eff
        },
        type_vars: [unbounded_k_id, unbounded_v_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // any: (Map<K,V>, (K, V) -> Bool / e) -> Bool / e
    orow = open_row(env)
    cb = Type::FnType {
        params: [unbounded_k, unbounded_v],
        return_type: BOOL, effects: orow.eff
    }
    unbounded_methods.insert("any", TypeScheme {
        ty: Type::FnType {
            params: [make_map_type(unbounded_k, unbounded_v), cb],
            return_type: BOOL, effects: orow.eff
        },
        type_vars: [unbounded_k_id, unbounded_v_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    install_builtin_method_owner(
        env, sink, BUILTIN_MAP,
        none, ["K", "V"], [unbounded_k_id, unbounded_v_id], [],
        unbounded_methods, map_new(),
        builtin_impl_provider_site_from_tag(
            BUILTIN_PROVIDER_MAP_HOF_UNBOUNDED))
    install_builtin_method_owner(
        env, sink, BUILTIN_MAP,
        none, ["K", "V"], [bounded_k_id, bounded_v_id], [
            BuiltinPredicateSpec {
                subject_param_index: 0, trait_name: "Hash"
            },
            BuiltinPredicateSpec {
                subject_param_index: 0, trait_name: "Eq"
            }
        ], bounded_methods, map_new(),
        builtin_impl_provider_site_from_tag(
            BUILTIN_PROVIDER_MAP_HOF_BOUNDED))
}

// ============================================================
// HOF: register_set_hof
// ============================================================

fn register_set_hof(mut env: TypeEnv, sink: CollectingSink) {
    let mut bounded_methods: Map<Str, TypeScheme> = map_new()
    let mut unbounded_methods: Map<Str, TypeScheme> = map_new()

    // filter: (Set<T>, (T) -> Bool / e) -> Set<T> / e
    let bounded_t_id = env.fresh_var_id()
    let bounded_t = Type::TypeVar { id: bounded_t_id, name: none }
    let mut orow = open_row(env)
    let mut cb = Type::FnType {
        params: [bounded_t], return_type: BOOL, effects: orow.eff
    }
    bounded_methods.insert("filter", TypeScheme {
        ty: Type::FnType {
            params: [make_set_struct(bounded_t), cb],
            return_type: make_set_struct(bounded_t), effects: orow.eff
        },
        type_vars: [bounded_t_id, orow.tail_id],
        bounds: [
            SchemeBound {
                type_var: bounded_t_id,
                trait_name: "Hash", assoc_constraints: []
            },
            SchemeBound {
                type_var: bounded_t_id,
                trait_name: "Eq", assoc_constraints: []
            }
        ],
        def_id: none
    })

    let unbounded_t_id = env.fresh_var_id()
    let unbounded_t = Type::TypeVar { id: unbounded_t_id, name: none }

    // fold: (Set<T>, U, (U, T) -> U / e) -> U / e
    let u_id = env.fresh_var_id()
    let u = Type::TypeVar { id: u_id, name: none }
    orow = open_row(env)
    cb = Type::FnType {
        params: [u, unbounded_t], return_type: u, effects: orow.eff
    }
    unbounded_methods.insert("fold", TypeScheme {
        ty: Type::FnType {
            params: [make_set_struct(unbounded_t), u, cb],
            return_type: u, effects: orow.eff
        },
        type_vars: [unbounded_t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // any: (Set<T>, (T) -> Bool / e) -> Bool / e
    orow = open_row(env)
    cb = Type::FnType {
        params: [unbounded_t], return_type: BOOL, effects: orow.eff
    }
    unbounded_methods.insert("any", TypeScheme {
        ty: Type::FnType {
            params: [make_set_struct(unbounded_t), cb],
            return_type: BOOL, effects: orow.eff
        },
        type_vars: [unbounded_t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // all: (Set<T>, (T) -> Bool / e) -> Bool / e
    orow = open_row(env)
    cb = Type::FnType {
        params: [unbounded_t], return_type: BOOL, effects: orow.eff
    }
    unbounded_methods.insert("all", TypeScheme {
        ty: Type::FnType {
            params: [make_set_struct(unbounded_t), cb],
            return_type: BOOL, effects: orow.eff
        },
        type_vars: [unbounded_t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    install_builtin_method_owner(
        env, sink, BUILTIN_SET,
        none, ["T"], [unbounded_t_id], [],
        unbounded_methods, map_new(),
        builtin_impl_provider_site_from_tag(
            BUILTIN_PROVIDER_SET_HOF_UNBOUNDED))
    install_builtin_method_owner(
        env, sink, BUILTIN_SET,
        none, ["T"], [bounded_t_id], [
            BuiltinPredicateSpec {
                subject_param_index: 0, trait_name: "Hash"
            },
            BuiltinPredicateSpec {
                subject_param_index: 0, trait_name: "Eq"
            }
        ], bounded_methods, map_new(),
        builtin_impl_provider_site_from_tag(
            BUILTIN_PROVIDER_SET_HOF_BOUNDED))
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
    let mut cb = Type::FnType { params: [t], return_type: u, effects: orow.eff }
    methods.insert("map", TypeScheme {
        ty: Type::FnType { params: [make_option_type(t), cb], return_type: make_option_type(u), effects: orow.eff },
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
    cb = Type::FnType { params: [t], return_type: make_option_type(u), effects: orow.eff }
    methods.insert("and_then", TypeScheme {
        ty: Type::FnType { params: [make_option_type(t), cb], return_type: make_option_type(u), effects: orow.eff },
        type_vars: [t_id, u_id, orow.tail_id],
        bounds: [],
        def_id: none
    })

    // unwrap_or_else: (Option<T>, () -> T / e) -> T / e
    t_id = env.fresh_var_id()
    t = Type::TypeVar { id: t_id, name: none }
    orow = open_row(env)
    cb = Type::FnType { params: [], return_type: t, effects: orow.eff }
    methods.insert("unwrap_or_else", TypeScheme {
        ty: Type::FnType { params: [make_option_type(t), cb], return_type: t, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        def_id: none
    })
    let mut intrinsics: Map<Str, IntrinsicRef> = map_new()
    install_intrinsic(intrinsics, "map", BUILTIN_METHOD_OPTION_MAP)
    install_intrinsic(intrinsics, "and_then", BUILTIN_METHOD_OPTION_AND_THEN)
    install_intrinsic(
        intrinsics, "unwrap_or_else", BUILTIN_METHOD_OPTION_UNWRAP_OR_ELSE)
    install_builtin_method_owner(
        env, sink, BUILTIN_OPTION,
        none, [], [], [], methods, intrinsics,
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_OPTION_HOF))
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
        ty: Type::FnType { params: [INT], return_type: alloc_ptr, effects: unsafe_row },
        type_vars: [alloc_t_id],
        bounds: [],
        def_id: none
    })

    // dealloc(p: Ptr<T>, count: Int) -> () / unsafe
    let dealloc_t_id = env.fresh_var_id()
    let dealloc_t = Type::TypeVar { id: dealloc_t_id, name: none }
    let dealloc_ptr = Type::PtrType { pointee: dealloc_t }
    env.bind("dealloc", TypeScheme {
        ty: Type::FnType { params: [dealloc_ptr, INT], return_type: UNIT, effects: unsafe_row },
        type_vars: [dealloc_t_id],
        bounds: [],
        def_id: none
    })

    // ptr_copy(src: Ptr<T>, dst: Ptr<T>, count: Int) -> () / unsafe
    let copy_t_id = env.fresh_var_id()
    let copy_t = Type::TypeVar { id: copy_t_id, name: none }
    let copy_ptr = Type::PtrType { pointee: copy_t }
    env.bind("ptr_copy", TypeScheme {
        ty: Type::FnType { params: [copy_ptr, copy_ptr, INT], return_type: UNIT, effects: unsafe_row },
        type_vars: [copy_t_id],
        bounds: [],
        def_id: none
    })

    // ptr_from_addr(a: Int) -> Ptr<T> (safe)
    let from_t_id = env.fresh_var_id()
    let from_t = Type::TypeVar { id: from_t_id, name: none }
    let from_ptr = Type::PtrType { pointee: from_t }
    env.bind("ptr_from_addr", TypeScheme {
        ty: Type::FnType { params: [INT], return_type: from_ptr, effects: EMPTY_ROW },
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
        ty: Type::FnType { params: [read_ptr], return_type: read_t, effects: unsafe_row },
        type_vars: [read_t_id],
        bounds: [],
        def_id: none
    })

    // take: (Ptr<T>) -> T / unsafe
    let take_t_id = env.fresh_var_id()
    let take_t = Type::TypeVar { id: take_t_id, name: none }
    let take_ptr = Type::PtrType { pointee: take_t }
    methods.insert("take", TypeScheme {
        ty: Type::FnType { params: [take_ptr], return_type: take_t, effects: unsafe_row },
        type_vars: [take_t_id],
        bounds: [],
        def_id: none
    })

    // write: (Ptr<T>, T) -> () / unsafe
    let write_t_id = env.fresh_var_id()
    let write_t = Type::TypeVar { id: write_t_id, name: none }
    let write_ptr = Type::PtrType { pointee: write_t }
    methods.insert("write", TypeScheme {
        ty: Type::FnType { params: [write_ptr, write_t], return_type: UNIT, effects: unsafe_row },
        type_vars: [write_t_id],
        bounds: [],
        def_id: none
    })

    // offset: (Ptr<T>, Int) -> Ptr<T> / unsafe
    let off_t_id = env.fresh_var_id()
    let off_t = Type::TypeVar { id: off_t_id, name: none }
    let off_ptr = Type::PtrType { pointee: off_t }
    methods.insert("offset", TypeScheme {
        ty: Type::FnType { params: [off_ptr, INT], return_type: off_ptr, effects: unsafe_row },
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
        ty: Type::FnType { params: [cast_ptr_t], return_type: cast_ptr_u, effects: EMPTY_ROW },
        type_vars: [cast_t_id, cast_u_id],
        bounds: [],
        def_id: none
    })

    // addr: (Ptr<T>) -> Int (safe)
    let addr_t_id = env.fresh_var_id()
    let addr_t = Type::TypeVar { id: addr_t_id, name: none }
    let addr_ptr = Type::PtrType { pointee: addr_t }
    methods.insert("addr", TypeScheme {
        ty: Type::FnType { params: [addr_ptr], return_type: INT, effects: EMPTY_ROW },
        type_vars: [addr_t_id],
        bounds: [],
        def_id: none
    })
    install_builtin_method_owner(
        env, sink, "Ptr",
        none, [], [], [], methods, map_new(),
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_PTR_CORE))
}
