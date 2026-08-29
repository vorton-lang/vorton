// builtins.ring — Combined translation of builtins-core.ts + builtins-hof.ts
// Registers built-in effects, types, traits, and HOF intrinsics into TypeEnv.

use types::{Type, Effect, EffectRow, StructField, EnumVariant,
    INT, FLOAT, STR, BOOL, UNIT, NEVER, EMPTY_ROW,
    BUILTIN_RANGE, BUILTIN_LIST, BUILTIN_MAP, BUILTIN_SET, BUILTIN_OPTION,
    BUILTIN_CELL,
    make_option_type, make_map_type}
use env::{TypeEnv, TypeScheme, SchemeBound, StructDef, EnumDef,
    EffectDef, EffectOpDef, BuiltInKind, TraitDef, TraitMethodDef,
    AssocTypeDef,
    RegisteredTraitMethodContract, RegisteredTraitAssocContract,
    make_registered_trait_method_contract,
    make_registered_trait_assoc_contract,
    make_registered_trait_contract,
    register_callable_effect_header,
    ImplEntry, ImplMethodSchemeCore, TypedImplPredicate,
    FrozenImplPredicateSet,
    mono, add_impl, install_method_core,
    make_impl_method_scheme_core, make_typed_impl_predicate,
    impl_method_core_as_scheme, impl_method_core_type,
    impl_method_core_type_vars, impl_method_core_def_id,
    apply_subst_map,
    ordered_effect_tail_vars, build_definition_effect_header_schema,
    direct_impl_predicate_provenance, freeze_impl_predicate_set,
    frozen_impl_predicates, impl_predicate_subject_type_var,
    impl_predicate_trait_name,
    find_impl_by_provider, impl_target_symbol,
    specialize_trait_method_scheme, delegate_plan_not_applicable}
use ast::{TypeParam, span_zero}
use effect_contract::{empty_typed_effect_header_schema}
use hir::{HDecl, HStructField, HTypeParam,
    compare_by_first}
use diagnostics::{CollectingSink}
use ir_inventory::{ExecutableRef, CallableResourceContractFact,
    CallableResourceRoleFact,
    make_named_executable_ref,
    executable_ref_is_named, executable_ref_named_symbol,
    make_callable_resource_contract_fact,
    callable_resource_contract_parameter_roles,
    callable_resource_role_read, callable_resource_role_mutate,
    callable_resource_role_consume}
use ir_identity::{SymbolRef, TraitMethodRef,
    ImplProviderRef, ImplOwnerRef, ImplMethodRef,
    IntrinsicRef, BuiltinMethodSite, BuiltinValueSite,
    make_symbol_ref, make_nominal_field_ref, make_trait_method_ref,
    trait_method_ref_member,
    make_variant_field_ref,
    make_registered_nominal_ref, make_registered_trait_ref,
    builtin_option_some_variant_ref, builtin_option_none_variant_ref,
    make_module_body_ref, path_owner_for_module_body, make_path_ref,
    path_role_synthetic, make_impl_provider_ref,
    make_impl_owner_ref, make_impl_method_ref,
    impl_owner_ref_target,
    impl_provider_ref_site, path_ref_normalized_child_path,
    symbol_ref_stable_key,
    impl_provider_kind_builtin, registered_trait_ref_symbol,
    builtin_method_site_from_tag, builtin_method_site_tag,
    make_builtin_method_intrinsic_ref, intrinsic_ref_same,
    intrinsic_ref_site,
    impl_method_ref_member, make_symbol_origin_ref,
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
    BUILTIN_METHOD_INT_EQ, BUILTIN_METHOD_INT_NE,
    BUILTIN_METHOD_FLOAT_EQ, BUILTIN_METHOD_FLOAT_NE,
    BUILTIN_METHOD_STR_EQ, BUILTIN_METHOD_STR_NE,
    BUILTIN_METHOD_BOOL_EQ, BUILTIN_METHOD_BOOL_NE,
    BUILTIN_METHOD_INT_CLONE, BUILTIN_METHOD_FLOAT_CLONE,
    BUILTIN_METHOD_STR_CLONE, BUILTIN_METHOD_BOOL_CLONE,
    BUILTIN_METHOD_INT_CMP, BUILTIN_METHOD_FLOAT_CMP,
    BUILTIN_METHOD_STR_CMP, BUILTIN_METHOD_BOOL_CMP,
    BUILTIN_METHOD_INT_DEBUG, BUILTIN_METHOD_FLOAT_DEBUG,
    BUILTIN_METHOD_STR_DEBUG, BUILTIN_METHOD_BOOL_DEBUG,
    BUILTIN_METHOD_INT_HASH, BUILTIN_METHOD_STR_HASH,
    BUILTIN_METHOD_BOOL_HASH,
    builtin_value_site_from_tag, builtin_value_site_tag,
    builtin_value_symbol,
    BUILTIN_VALUE_CELL_CONSTRUCTOR, BUILTIN_VALUE_ALLOC,
    BUILTIN_VALUE_DEALLOC, BUILTIN_VALUE_PTR_COPY,
    BUILTIN_VALUE_PTR_FROM_ADDR, BUILTIN_VALUE_HASH_COMBINE,
    BUILTIN_VALUE_STR_IDENTITY, BUILTIN_VALUE_BOOL_TO_STR,
    BUILTIN_VALUE_LIST_INDEX, BUILTIN_VALUE_STR_INDEX,
    BUILTIN_VALUE_SITE_COUNT,
    namespace_value, namespace_nominal, namespace_trait, namespace_member}

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

struct BuiltinImplMethodSpec {
    name: Str,
    intrinsic_tag: Int?,
    resource_contract: CallableResourceContractFact?
}

fn builtin_impl_method(name: Str) -> BuiltinImplMethodSpec {
    BuiltinImplMethodSpec {
        name: name, intrinsic_tag: none, resource_contract: none
    }
}

fn builtin_intrinsic_method(
    name: Str, intrinsic_tag: Int,
    resource_contract: CallableResourceContractFact
) -> BuiltinImplMethodSpec {
    BuiltinImplMethodSpec {
        name: name, intrinsic_tag: some(intrinsic_tag),
        resource_contract: some(resource_contract)
    }
}

fn builtin_resource_contract(
    parameter_roles: List<CallableResourceRoleFact>,
    result_role: CallableResourceRoleFact,
    result_alias_ordinals: List<Int>
) -> CallableResourceContractFact {
    make_callable_resource_contract_fact(
        parameter_roles, result_role, result_alias_ordinals)
}

fn builtin_trait_symbol(name: Str) -> SymbolRef {
    make_symbol_ref(
        "$builtin", namespace_trait(), name, "builtin:trait:${name}")
}

fn install_builtin_trait_contract(
    mut env: TypeEnv, name: Str, owner_symbol: SymbolRef,
    type_params: List<Str>, type_param_vars: List<Int>,
    self_type_var_id: Int,
    methods: List<TraitMethodDef>, supertraits: List<Str>,
    assoc_types: List<AssocTypeDef>
) {
    let owner_ref = make_registered_trait_ref(owner_symbol, name)
    let mut method_contracts: List<RegisteredTraitMethodContract> = []
    for method in methods {
        match method.ty {
            Type::FnType { effects, .. } => register_callable_effect_header(
                env, make_named_executable_ref(
                    trait_method_ref_member(method.method_ref)), effects),
            _ => panic("builtin trait method: signature is not callable")
        }
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
        self_type_var_id: self_type_var_id,
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

fn install_intrinsic_contract(
    mut intrinsics: Map<Str, IntrinsicRef>,
    mut resources: Map<Str, CallableResourceContractFact>,
    name: Str, tag: Int, resource: CallableResourceContractFact
) {
    install_intrinsic(intrinsics, name, tag)
    if resources.contains_key(name) {
        panic("builtin method intrinsic: duplicate resource relation")
    }
    resources.insert(name, resource)
}

pub struct CheckerBuiltinValue {
    name: Str,
    symbol: SymbolRef
}

fn registered_builtin_value_name(site: BuiltinValueSite) -> Str {
    let tag = builtin_value_site_tag(site)
    if tag == BUILTIN_VALUE_CELL_CONSTRUCTOR { return "Cell" }
    if tag == BUILTIN_VALUE_ALLOC { return "alloc" }
    if tag == BUILTIN_VALUE_DEALLOC { return "dealloc" }
    if tag == BUILTIN_VALUE_PTR_COPY { return "ptr_copy" }
    if tag == BUILTIN_VALUE_PTR_FROM_ADDR { return "ptr_from_addr" }
    panic("builtin value contract: site has no registered TypeScheme")
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
    let target_key = symbol_ref_stable_key(target_ref)
    let trait_key = match trait_ref {
        some(value) => symbol_ref_stable_key(value),
        none => "inherent"
    }
    let mut refs: Map<Str, ImplMethodRef> = map_new()
    let mut entries = cores.entries()
    entries.sort_by(compare_by_first)
    let mut callable_slot = 0
    for entry in entries {
        let (method_name, _) = entry
        let member = make_symbol_ref(
            "$builtin", namespace_member(),
            "builtin-impl-member:${provider_path}:${target_key}:${trait_key}:${callable_slot}",
            "provider:${provider_path}|target:${target_key}|trait:${trait_key}|method:${callable_slot}")
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
    method_resources: Map<Str, CallableResourceContractFact>,
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
            scheme.ty, scheme.type_vars, scheme.effect_schema,
            scheme.def_id))
    }
    let mut method_names = cores.keys()
    method_names.sort()
    let provider_ref = builtin_impl_provider(provider_site)
    let trait_ref = builtin_impl_trait_ref(env, trait_name)
    let identity = builtin_impl_identity(
        env, target_type_name, provider_ref, trait_ref, cores)
    let owner_ref = identity.0
    let method_refs = identity.1
    let mut finalized_cores: Map<Str, ImplMethodSchemeCore> = map_new()
    let mut final_entries = cores.entries()
    final_entries.sort_by(compare_by_first)
    for entry in final_entries {
        let (method_name, core) = entry
        let method_type = impl_method_core_type(core)
        let mut quantified: List<Int> = []
        for tail in ordered_effect_tail_vars(method_type) {
            if impl_method_core_type_vars(core).contains(tail) &&
               !owner_type_vars.contains(tail) {
                quantified.push(tail)
            }
        }
        let owner_symbol = impl_method_ref_member(
            method_refs.get(method_name).unwrap())
        let schema = build_definition_effect_header_schema(
            make_symbol_origin_ref(owner_symbol), [method_type],
            quantified)
        finalized_cores.insert(method_name, make_impl_method_scheme_core(
            method_type, impl_method_core_type_vars(core), schema,
            impl_method_core_def_id(core)))
    }
    cores = finalized_cores
    let owner = ImplEntry {
        trait_name: trait_name,
        target_type_name: target_type_name,
        type_params: type_params,
        type_param_vars: owner_type_vars,
        predicates: predicates,
        method_names: method_names,
        assoc_types: map_new(),
        assoc_type_effect_schemas: map_new(),
        method_schemes: map_clone(cores),
        method_refs: method_refs,
        method_intrinsics: map_clone(method_intrinsics),
        method_resource_contracts: method_resources,
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
    if target_type_name == BUILTIN_OPTION {
        return Type::EnumType {
            name: BUILTIN_OPTION, type_params: type_args
        }
    }
    match target_type_name {
        "Int" => INT,
        "Float" => FLOAT,
        "Str" => STR,
        "Bool" => BOOL,
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
    method_specs: List<BuiltinImplMethodSpec>
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
    let mut method_names: List<Str> = []
    for method_spec in method_specs {
        method_names.push(method_spec.name)
    }
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
    let mut method_intrinsics: Map<Str, IntrinsicRef> = map_new()
    let mut method_resources: Map<Str, CallableResourceContractFact> = map_new()
    for method_spec in method_specs {
        match method_spec.intrinsic_tag {
            some(tag) => {
                let resource = match method_spec.resource_contract {
                    some(value) => value,
                    none => panic(
                        "builtin impl owner: intrinsic resource contract is absent")
                }
                install_intrinsic(method_intrinsics, method_spec.name, tag)
                method_resources.insert(method_spec.name, resource)
            },
            none => {}
        }
    }
    add_impl(env.trait_reg, ImplEntry {
        trait_name: some(trait_name),
        target_type_name: target_type_name,
        type_params: type_params,
        type_param_vars: type_var_ids,
        predicates: predicates,
        method_names: method_names,
        assoc_types: map_new(),
        assoc_type_effect_schemas: map_new(),
        method_schemes: map_clone(exact),
        method_refs: method_refs,
        method_intrinsics: method_intrinsics,
        method_resource_contracts: method_resources,
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
    register_range(env)
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
    let mut str_resources: Map<Str, CallableResourceContractFact> = map_new()
    install_intrinsic_contract(str_intrinsics, str_resources, "len",
        BUILTIN_METHOD_STR_LEN, builtin_resource_contract(
            [callable_resource_role_read()], callable_resource_role_read(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "contains",
        BUILTIN_METHOD_STR_CONTAINS, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_read(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "starts_with",
        BUILTIN_METHOD_STR_STARTS_WITH, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_read(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "ends_with",
        BUILTIN_METHOD_STR_ENDS_WITH, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_read(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "slice",
        BUILTIN_METHOD_STR_SLICE, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read(),
             callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "trim",
        BUILTIN_METHOD_STR_TRIM, builtin_resource_contract(
            [callable_resource_role_read()], callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "to_upper",
        BUILTIN_METHOD_STR_TO_UPPER, builtin_resource_contract(
            [callable_resource_role_read()], callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "to_lower",
        BUILTIN_METHOD_STR_TO_LOWER, builtin_resource_contract(
            [callable_resource_role_read()], callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "replace",
        BUILTIN_METHOD_STR_REPLACE, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read(),
             callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "split",
        BUILTIN_METHOD_STR_SPLIT, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "char_at",
        BUILTIN_METHOD_STR_CHAR_AT, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "index_of",
        BUILTIN_METHOD_STR_INDEX_OF, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "pad_start",
        BUILTIN_METHOD_STR_PAD_START, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read(),
             callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "pad_end",
        BUILTIN_METHOD_STR_PAD_END, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read(),
             callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "repeat",
        BUILTIN_METHOD_STR_REPEAT, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "char_code_at",
        BUILTIN_METHOD_STR_CHAR_CODE_AT, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "trim_start",
        BUILTIN_METHOD_STR_TRIM_START, builtin_resource_contract(
            [callable_resource_role_read()], callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "trim_end",
        BUILTIN_METHOD_STR_TRIM_END, builtin_resource_contract(
            [callable_resource_role_read()], callable_resource_role_consume(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "is_empty",
        BUILTIN_METHOD_STR_IS_EMPTY, builtin_resource_contract(
            [callable_resource_role_read()], callable_resource_role_read(), []))
    install_intrinsic_contract(str_intrinsics, str_resources, "last_index_of",
        BUILTIN_METHOD_STR_LAST_INDEX_OF, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_builtin_method_owner(
        env, sink, "Str",
        none, [], [], [],
        str_methods, str_intrinsics, str_resources,
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_STR_CORE))

    let mut int_methods: Map<Str, TypeScheme> = map_new()
    int_methods.insert("to_str", mono(Type::FnType {
        params: [INT], return_type: STR, effects: EMPTY_ROW }))
    let mut int_intrinsics: Map<Str, IntrinsicRef> = map_new()
    let mut int_resources: Map<Str, CallableResourceContractFact> = map_new()
    install_intrinsic_contract(int_intrinsics, int_resources, "to_str",
        BUILTIN_METHOD_INT_TO_STR, builtin_resource_contract(
            [callable_resource_role_read()], callable_resource_role_consume(), []))
    install_builtin_method_owner(
        env, sink, "Int",
        none, [], [], [],
        int_methods, int_intrinsics, int_resources,
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_INT_CORE))

    let mut float_methods: Map<Str, TypeScheme> = map_new()
    float_methods.insert("to_str", mono(Type::FnType {
        params: [FLOAT], return_type: STR, effects: EMPTY_ROW }))
    let mut float_intrinsics: Map<Str, IntrinsicRef> = map_new()
    let mut float_resources: Map<Str, CallableResourceContractFact> = map_new()
    install_intrinsic_contract(float_intrinsics, float_resources, "to_str",
        BUILTIN_METHOD_FLOAT_TO_STR, builtin_resource_contract(
            [callable_resource_role_read()], callable_resource_role_consume(), []))
    install_builtin_method_owner(
        env, sink, "Float",
        none, [], [], [],
        float_methods, float_intrinsics, float_resources,
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_FLOAT_CORE))
}

// Range is a fixed 0.1 value shape, not a generic enum.  The surface `a..b`
// syntax and Range for-in plan both consume these exact nominal fields before
// Core; no backend stage reconstructs the shape from the leaf name.
fn register_range(mut env: TypeEnv) {
    let type_var_id = env.fresh_var_id()
    let element_type = Type::TypeVar { id: type_var_id, name: some("T") }
    let owner = make_symbol_ref(
        "$builtin", namespace_nominal(), BUILTIN_RANGE, "builtin:Range")
    let start_member = make_symbol_ref(
        "$builtin", namespace_member(), "Range::start",
        "builtin:Range|field:0|kind:struct-field")
    let end_member = make_symbol_ref(
        "$builtin", namespace_member(), "Range::end",
        "builtin:Range|field:1|kind:struct-field")
    let inclusive_member = make_symbol_ref(
        "$builtin", namespace_member(), "Range::inclusive",
        "builtin:Range|field:2|kind:struct-field")
    env.types.structs.insert(BUILTIN_RANGE, StructDef {
        name: BUILTIN_RANGE,
        owner_ref: make_registered_nominal_ref(owner, BUILTIN_RANGE),
        type_params: ["T"], type_param_vars: [type_var_id],
        fields: [
            StructField { name: "start", ty: element_type, is_pub: false,
                field_ref: make_nominal_field_ref(
                    owner, start_member, 0, "start"),
                field_index: 0, span: span_zero() },
            StructField { name: "end", ty: element_type, is_pub: false,
                field_ref: make_nominal_field_ref(
                    owner, end_member, 1, "end"),
                field_index: 1, span: span_zero() },
            StructField { name: "inclusive", ty: BOOL, is_pub: false,
                field_ref: make_nominal_field_ref(
                    owner, inclusive_member, 2, "inclusive"),
                field_index: 2, span: span_zero() }
        ],
        field_effect_schemas: [
            empty_typed_effect_header_schema(),
            empty_typed_effect_header_schema(),
            empty_typed_effect_header_schema()
        ],
        derive_attrs: [], derived_provider_plan: none,
        resource_storage_parameter_ordinals: [],
        is_extern: false
    })
}

pub fn builtin_range_hdecl(env: TypeEnv) -> HDecl {
    let def = env.types.structs.get(BUILTIN_RANGE).unwrap_or_else(fn() {
        panic("builtin Range HIR: StructDef is absent")
    })
    if def.type_param_vars.len() != 1 {
        panic("builtin Range HIR: formal census differs")
    }
    HDecl::Struct {
        name: def.name, owner_ref: def.owner_ref,
        type_params: [HTypeParam {
            source: TypeParam { name: "T", bounds: [], span: span_zero() },
            type_var_id: def.type_param_vars.get(0).unwrap(),
            bound_refs: []
        }],
        fields: def.fields.map(fn(field) { HStructField {
            name: field.name, ty: field.ty, is_pub: field.is_pub,
            field_ref: field.field_ref, field_index: field.field_index,
            span: field.span
        } }),
        is_pub: false, span: span_zero()
    }
}

// Normal compilation publishes no std HOF method core before source
// registration. Option HOFs are true builtins and remain final here.
pub fn register_hof_intrinsics(mut env: TypeEnv, sink: CollectingSink) {
    register_option_hof(env, sink)
}

fn append_builtin_type_var(mut values: List<Int>, value: Int) {
    if !values.contains(value) { values.push(value) }
}

fn collect_builtin_effect_formals(
    eff: Effect, mut value_vars: List<Int>, mut row_tails: List<Int>
) {
    match eff {
        Effect::FailEffect { error_type } =>
            collect_builtin_type_formals(error_type, value_vars, row_tails),
        Effect::MutEffect { state_type } =>
            collect_builtin_type_formals(state_type, value_vars, row_tails),
        Effect::CustomEffect { type_args, .. } => {
            for value in type_args {
                collect_builtin_type_formals(value, value_vars, row_tails)
            }
        },
        Effect::SystemEffect { .. } | Effect::UnsafeEffect => {}
    }
}

fn collect_builtin_effect_row_formals(
    row: EffectRow, mut value_vars: List<Int>, mut row_tails: List<Int>
) {
    match row.tail {
        some(value) => append_builtin_type_var(row_tails, value),
        none => {}
    }
    for eff in row.effects {
        collect_builtin_effect_formals(eff, value_vars, row_tails)
    }
}

fn collect_builtin_type_formals(
    ty: Type, mut value_vars: List<Int>, mut row_tails: List<Int>
) {
    match ty {
        Type::TypeVar { id, .. } => append_builtin_type_var(value_vars, id),
        Type::FnType { params, return_type, effects } => {
            for parameter in params {
                collect_builtin_type_formals(parameter, value_vars, row_tails)
            }
            collect_builtin_type_formals(return_type, value_vars, row_tails)
            collect_builtin_effect_row_formals(effects, value_vars, row_tails)
        },
        Type::StructType { type_params, .. } |
        Type::EnumType { type_params, .. } => {
            for parameter in type_params {
                collect_builtin_type_formals(parameter, value_vars, row_tails)
            }
        },
        Type::GenericType { base, args } => {
            collect_builtin_type_formals(base, value_vars, row_tails)
            for argument in args {
                collect_builtin_type_formals(argument, value_vars, row_tails)
            }
        },
        Type::RecordType { fields, tail, .. } => {
            for field in fields {
                collect_builtin_type_formals(field.ty, value_vars, row_tails)
            }
            match tail {
                some(value) => append_builtin_type_var(row_tails, value),
                none => {}
            }
        },
        Type::EffectRowType { effects, tail } => {
            for eff in effects {
                collect_builtin_effect_formals(eff, value_vars, row_tails)
            }
            match tail {
                some(value) => append_builtin_type_var(row_tails, value),
                none => {}
            }
        },
        Type::TupleType { elements } => {
            for element in elements {
                collect_builtin_type_formals(element, value_vars, row_tails)
            }
        },
        Type::PtrType { pointee } =>
            collect_builtin_type_formals(pointee, value_vars, row_tails),
        _ => {}
    }
}

struct RegisteredIntrinsicSource {
    owner: ImplEntry,
    scheme: TypeScheme
}

fn registered_intrinsic_source(
    env: TypeEnv, intrinsic: IntrinsicRef
) -> RegisteredIntrinsicSource {
    let mut found: RegisteredIntrinsicSource? = none
    for map_entry in env.trait_reg.trait_impls.entries() {
        let (_, owners) = map_entry
        for owner in owners {
            for method_entry in owner.method_intrinsics.entries() {
                let (method_name, candidate) = method_entry
                if intrinsic_ref_same(candidate, intrinsic) {
                    let core = match owner.method_schemes.get(method_name) {
                        some(value) => value,
                        none => panic(
                            "builtin method contract: exact scheme is missing")
                    }
                    if found.is_some() {
                        panic("builtin method contract: scheme is not unique")
                    }
                    found = some(RegisteredIntrinsicSource {
                        owner: owner,
                        scheme: impl_method_core_as_scheme(core)
                    })
                }
            }
        }
    }
    match found {
        some(value) => value,
        none => panic("builtin method contract: scheme was not registered")
    }
}

fn registered_intrinsic_resource_contract(
    env: TypeEnv, intrinsic: IntrinsicRef
) -> CallableResourceContractFact {
    let mut found: CallableResourceContractFact? = none
    for map_entry in env.trait_reg.trait_impls.entries() {
        let (_, owners) = map_entry
        for owner in owners {
            for method_entry in owner.method_intrinsics.entries() {
                let (method_name, candidate) = method_entry
                if intrinsic_ref_same(candidate, intrinsic) {
                    let contract = match
                            owner.method_resource_contracts.get(method_name) {
                        some(value) => value,
                        none => panic(
                            "builtin method contract: exact resource fact is missing")
                    }
                    if found.is_some() {
                        panic(
                            "builtin method contract: resource fact is not unique")
                    }
                    found = some(contract)
                }
            }
        }
    }
    match found {
        some(value) => value,
        none => panic(
            "builtin method contract: resource fact was not registered")
    }
}

pub struct BuiltinMethodContractFact {
    intrinsic: IntrinsicRef,
    target_owner: SymbolRef,
    target_owner_type_vars: List<Int>,
    method_type_vars: List<Int>,
    scheme: TypeScheme,
    resource: CallableResourceContractFact
}

fn builtin_method_value_type_vars(
    owner: ImplEntry, scheme: TypeScheme
) -> List<Int> {
    if scheme.bounds.len() != 0 {
        panic("builtin method contract: value formal has a scheme bound")
    }
    let mut value_vars: List<Int> = []
    let mut row_tails: List<Int> = []
    collect_builtin_type_formals(scheme.ty, value_vars, row_tails)
    let mut ordered_values: List<Int> = []
    let mut index = 0
    while index < scheme.type_vars.len() {
        let value = scheme.type_vars.get(index).unwrap()
        let mut prior = 0
        while prior < index {
            if scheme.type_vars.get(prior).unwrap() == value {
                panic("builtin method contract: scheme formal repeats")
            }
            prior = prior + 1
        }
        let is_value = value_vars.contains(value)
        let is_tail = row_tails.contains(value)
        if is_value == is_tail {
            panic("builtin method contract: scheme formal domain differs")
        }
        if is_value { ordered_values.push(value) }
        index = index + 1
    }
    for value in value_vars {
        if !scheme.type_vars.contains(value) {
            panic("builtin method contract: value formal is omitted")
        }
    }
    for tail in row_tails {
        if !scheme.type_vars.contains(tail) {
            panic("builtin method contract: effect tail is omitted")
        }
    }
    if owner.type_param_vars.len() > ordered_values.len() {
        panic("builtin method contract: owner formal prefix is short")
    }
    for owner_index in 0..owner.type_param_vars.len() {
        if owner.type_param_vars.get(owner_index).unwrap() !=
           ordered_values.get(owner_index).unwrap() {
            panic("builtin method contract: owner formal prefix differs")
        }
    }
    ordered_values
}

fn make_builtin_method_contract_fact(
    intrinsic: IntrinsicRef, owner: ImplEntry, scheme: TypeScheme,
    resource: CallableResourceContractFact
) -> BuiltinMethodContractFact {
    let arity = match scheme.ty {
        Type::FnType { params, .. } => params.len(),
        _ => panic("builtin method contract: scheme is not callable")
    }
    if callable_resource_contract_parameter_roles(resource).len() != arity {
        panic("builtin method contract: exact resource arity differs")
    }
    let owner_ref = match owner.owner_ref {
        some(value) => value,
        none => panic("builtin method contract: target owner is absent")
    }
    let value_vars = builtin_method_value_type_vars(owner, scheme)
    let mut method_type_vars: List<Int> = []
    for index in owner.type_param_vars.len()..value_vars.len() {
        method_type_vars.push(value_vars.get(index).unwrap())
    }
    BuiltinMethodContractFact {
        intrinsic: intrinsic,
        target_owner: impl_owner_ref_target(owner_ref),
        target_owner_type_vars: owner.type_param_vars.map(fn(value) { value }),
        method_type_vars: method_type_vars,
        scheme: scheme, resource: resource
    }
}

pub fn builtin_method_contract_intrinsic(
    value: BuiltinMethodContractFact
) -> IntrinsicRef { value.intrinsic }

pub fn builtin_method_contract_scheme(
    value: BuiltinMethodContractFact
) -> TypeScheme { value.scheme }
pub fn builtin_method_contract_target_owner(
    value: BuiltinMethodContractFact
) -> SymbolRef { value.target_owner }
pub fn builtin_method_contract_target_type_vars(
    value: BuiltinMethodContractFact
) -> List<Int> { value.target_owner_type_vars.map(fn(item) { item }) }
pub fn builtin_method_contract_method_type_vars(
    value: BuiltinMethodContractFact
) -> List<Int> { value.method_type_vars.map(fn(item) { item }) }
pub fn builtin_method_contract_resource(
    value: BuiltinMethodContractFact
) -> CallableResourceContractFact { value.resource }

// Sole typed builtin-method payload consumed by the real module-order-0 Core
// assembler.  It carries no shadow Core/Flow graph and owns no second type
// interner, executable inventory, manifest, or semantic fallback.
pub fn builtin_method_contract_facts(
    env: TypeEnv
) -> List<BuiltinMethodContractFact> {
    let mut result: List<BuiltinMethodContractFact> = []
    for tag in 0..BUILTIN_METHOD_SITE_COUNT {
        let intrinsic = builtin_method_intrinsic(
            builtin_method_site_from_tag(tag))
        let source = registered_intrinsic_source(env, intrinsic)
        result.push(make_builtin_method_contract_fact(
            intrinsic, source.owner, source.scheme,
            registered_intrinsic_resource_contract(env, intrinsic)))
    }
    if result.len() != BUILTIN_METHOD_SITE_COUNT {
        panic("builtin method contract: exact site census drifted")
    }
    result
}

// Physical lowering is a closed 0.1 relation, not a backend name lookup.
// `data` is present exactly when the selected lowering invokes one fixed C
// runtime leaf.  The remaining tags describe the two inline lowerings whose
// behavior cannot be represented by a runtime symbol alone.
pub const BUILTIN_VALUE_PHYSICAL_DIRECT_RUNTIME: Int = 0
pub const BUILTIN_VALUE_PHYSICAL_PTR_FROM_ADDR: Int = 1
pub const BUILTIN_VALUE_PHYSICAL_HASH_COMBINE: Int = 2
pub const BUILTIN_VALUE_PHYSICAL_STR_IDENTITY: Int = 3
pub const BUILTIN_VALUE_PHYSICAL_BOOL_TO_STR: Int = 4
pub const BUILTIN_VALUE_PHYSICAL_INDEX: Int = 5
const BUILTIN_VALUE_PHYSICAL_COUNT: Int = 6

pub struct BuiltinValuePhysicalLoweringFact {
    tag: Int,
    data: Str?
}

fn make_builtin_value_physical_lowering_fact(
    tag: Int, data: Str?
) -> BuiltinValuePhysicalLoweringFact {
    if tag < 0 || tag >= BUILTIN_VALUE_PHYSICAL_COUNT {
        panic("builtin value contract: physical lowering tag is invalid")
    }
    let requires_data =
        tag == BUILTIN_VALUE_PHYSICAL_DIRECT_RUNTIME ||
        tag == BUILTIN_VALUE_PHYSICAL_HASH_COMBINE ||
        tag == BUILTIN_VALUE_PHYSICAL_BOOL_TO_STR ||
        tag == BUILTIN_VALUE_PHYSICAL_INDEX
    match data {
        some(value) => if !requires_data || value == "" {
            panic("builtin value contract: physical lowering data differs")
        },
        none => if requires_data {
            panic("builtin value contract: physical lowering data is absent")
        }
    }
    BuiltinValuePhysicalLoweringFact { tag: tag, data: data }
}

pub fn builtin_value_physical_lowering_tag(
    value: BuiltinValuePhysicalLoweringFact
) -> Int {
    make_builtin_value_physical_lowering_fact(
        value.tag, value.data).tag
}

pub fn builtin_value_physical_lowering_data(
    value: BuiltinValuePhysicalLoweringFact
) -> Str? {
    make_builtin_value_physical_lowering_fact(
        value.tag, value.data).data
}

fn builtin_value_physical_lowering(
    site: BuiltinValueSite
) -> BuiltinValuePhysicalLoweringFact {
    let tag = builtin_value_site_tag(site)
    if tag == BUILTIN_VALUE_CELL_CONSTRUCTOR {
        return make_builtin_value_physical_lowering_fact(
            BUILTIN_VALUE_PHYSICAL_DIRECT_RUNTIME, some("ring_Cell_new"))
    }
    if tag == BUILTIN_VALUE_ALLOC {
        return make_builtin_value_physical_lowering_fact(
            BUILTIN_VALUE_PHYSICAL_DIRECT_RUNTIME, some("ring_raw_alloc"))
    }
    if tag == BUILTIN_VALUE_DEALLOC {
        return make_builtin_value_physical_lowering_fact(
            BUILTIN_VALUE_PHYSICAL_DIRECT_RUNTIME, some("ring_raw_dealloc"))
    }
    if tag == BUILTIN_VALUE_PTR_COPY {
        return make_builtin_value_physical_lowering_fact(
            BUILTIN_VALUE_PHYSICAL_DIRECT_RUNTIME, some("ring_ptr_copy"))
    }
    if tag == BUILTIN_VALUE_PTR_FROM_ADDR {
        return make_builtin_value_physical_lowering_fact(
            BUILTIN_VALUE_PHYSICAL_PTR_FROM_ADDR, none)
    }
    if tag == BUILTIN_VALUE_HASH_COMBINE {
        return make_builtin_value_physical_lowering_fact(
            BUILTIN_VALUE_PHYSICAL_HASH_COMBINE,
            some("ring_hash_combine"))
    }
    if tag == BUILTIN_VALUE_STR_IDENTITY {
        return make_builtin_value_physical_lowering_fact(
            BUILTIN_VALUE_PHYSICAL_STR_IDENTITY, none)
    }
    if tag == BUILTIN_VALUE_BOOL_TO_STR {
        return make_builtin_value_physical_lowering_fact(
            BUILTIN_VALUE_PHYSICAL_BOOL_TO_STR,
            some("ring_bool_to_str"))
    }
    if tag == BUILTIN_VALUE_LIST_INDEX {
        return make_builtin_value_physical_lowering_fact(
            BUILTIN_VALUE_PHYSICAL_INDEX, some("ring_list_get"))
    }
    if tag == BUILTIN_VALUE_STR_INDEX {
        return make_builtin_value_physical_lowering_fact(
            BUILTIN_VALUE_PHYSICAL_INDEX, some("ring_str_get"))
    }
    panic("builtin value contract: physical lowering census is incomplete")
}

// Manifest schemes use one stable normalized formal per generic site.  Raw
// ids are disjoint across the ten-site manifest but never enter inference:
// public Cell/Ptr bindings fresh-localize them through the existing env API.
fn deterministic_builtin_value_scheme(
    site: BuiltinValueSite
) -> TypeScheme {
    let tag = builtin_value_site_tag(site)
    let type_var_id = 0 - 1 - tag
    let type_var = Type::TypeVar { id: type_var_id, name: none }
    let unsafe_row = EffectRow {
        effects: [Effect::UnsafeEffect], tail: none
    }
    if tag == BUILTIN_VALUE_CELL_CONSTRUCTOR {
        return TypeScheme {
            ty: Type::FnType {
                params: [type_var],
                return_type: Type::StructType {
                    name: BUILTIN_CELL, type_params: [type_var]
                },
                effects: EMPTY_ROW
            },
            type_vars: [type_var_id], bounds: [],
            effect_schema: empty_typed_effect_header_schema(), def_id: none
        }
    }
    if tag == BUILTIN_VALUE_ALLOC {
        return TypeScheme {
            ty: Type::FnType {
                params: [INT],
                return_type: Type::PtrType { pointee: type_var },
                effects: unsafe_row
            },
            type_vars: [type_var_id], bounds: [],
            effect_schema: empty_typed_effect_header_schema(), def_id: none
        }
    }
    if tag == BUILTIN_VALUE_DEALLOC {
        return TypeScheme {
            ty: Type::FnType {
                params: [Type::PtrType { pointee: type_var }, INT],
                return_type: UNIT, effects: unsafe_row
            },
            type_vars: [type_var_id], bounds: [],
            effect_schema: empty_typed_effect_header_schema(), def_id: none
        }
    }
    if tag == BUILTIN_VALUE_PTR_COPY {
        let pointer = Type::PtrType { pointee: type_var }
        return TypeScheme {
            ty: Type::FnType {
                params: [pointer, pointer, INT],
                return_type: UNIT, effects: unsafe_row
            },
            type_vars: [type_var_id], bounds: [],
            effect_schema: empty_typed_effect_header_schema(), def_id: none
        }
    }
    if tag == BUILTIN_VALUE_PTR_FROM_ADDR {
        return TypeScheme {
            ty: Type::FnType {
                params: [INT],
                return_type: Type::PtrType { pointee: type_var },
                effects: EMPTY_ROW
            },
            type_vars: [type_var_id], bounds: [],
            effect_schema: empty_typed_effect_header_schema(), def_id: none
        }
    }
    if tag == BUILTIN_VALUE_HASH_COMBINE {
        return mono(Type::FnType {
            params: [INT, INT], return_type: INT, effects: EMPTY_ROW
        })
    }
    if tag == BUILTIN_VALUE_STR_IDENTITY {
        return mono(Type::FnType {
            params: [STR], return_type: STR, effects: EMPTY_ROW
        })
    }
    if tag == BUILTIN_VALUE_BOOL_TO_STR {
        return mono(Type::FnType {
            params: [BOOL], return_type: STR, effects: EMPTY_ROW
        })
    }
    if tag == BUILTIN_VALUE_LIST_INDEX {
        return TypeScheme {
            ty: Type::FnType {
                params: [make_list_struct(type_var), INT],
                return_type: type_var, effects: EMPTY_ROW
            },
            type_vars: [type_var_id],
            bounds: [], effect_schema: empty_typed_effect_header_schema(),
            def_id: none
        }
    }
    if tag == BUILTIN_VALUE_STR_INDEX {
        return mono(Type::FnType {
            params: [STR, INT], return_type: STR, effects: EMPTY_ROW
        })
    }
    panic("builtin value contract: scheme census is incomplete")
}

fn builtin_value_scheme_for_site(site: BuiltinValueSite) -> TypeScheme {
    let tag = builtin_value_site_tag(site)
    let scheme = deterministic_builtin_value_scheme(site)
    let mut value_vars: List<Int> = []
    let mut row_tails: List<Int> = []
    collect_builtin_type_formals(scheme.ty, value_vars, row_tails)
    let should_be_generic =
        tag == BUILTIN_VALUE_CELL_CONSTRUCTOR ||
        tag == BUILTIN_VALUE_ALLOC ||
        tag == BUILTIN_VALUE_DEALLOC ||
        tag == BUILTIN_VALUE_PTR_COPY ||
        tag == BUILTIN_VALUE_PTR_FROM_ADDR ||
        tag == BUILTIN_VALUE_LIST_INDEX
    if scheme.bounds.len() != 0 || scheme.def_id.is_some() ||
       row_tails.len() != 0 ||
       value_vars.len() != scheme.type_vars.len() ||
       (scheme.type_vars.len() == 1) != should_be_generic {
        panic("builtin value contract: normalized scheme is invalid")
    }
    let mut index = 0
    while index < scheme.type_vars.len() {
        let value = scheme.type_vars.get(index).unwrap()
        if value >= 0 || value_vars.get(index).unwrap() != value {
            panic("builtin value contract: normalized formal differs")
        }
        index = index + 1
    }
    scheme
}

fn bind_registered_builtin_value(
    mut env: TypeEnv, name: Str, site: BuiltinValueSite
) {
    if registered_builtin_value_name(site) != name {
        panic("builtin value contract: public binding relation differs")
    }
    let normalized = builtin_value_scheme_for_site(site)
    let mut substitution: Map<Int, Type> = map_new()
    let mut type_vars: List<Int> = []
    for source in normalized.type_vars {
        let target = env.fresh_var_id()
        substitution.insert(source, Type::TypeVar {
            id: target, name: none
        })
        type_vars.push(target)
    }
    env.bind(name, TypeScheme {
        ty: apply_subst_map(substitution, normalized.ty),
        type_vars: type_vars, bounds: [],
        effect_schema: normalized.effect_schema, def_id: none
    })
}

fn builtin_value_resource_contract(
    site: BuiltinValueSite
) -> CallableResourceContractFact {
    let tag = builtin_value_site_tag(site)
    if tag == BUILTIN_VALUE_CELL_CONSTRUCTOR {
        return builtin_resource_contract(
            [callable_resource_role_read()],
            callable_resource_role_consume(), [])
    }
    if tag == BUILTIN_VALUE_ALLOC {
        return builtin_resource_contract(
            [callable_resource_role_read()],
            callable_resource_role_read(), [])
    }
    if tag == BUILTIN_VALUE_DEALLOC {
        return builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_read(), [])
    }
    if tag == BUILTIN_VALUE_PTR_COPY {
        return builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read(),
             callable_resource_role_read()],
            callable_resource_role_read(), [])
    }
    if tag == BUILTIN_VALUE_PTR_FROM_ADDR {
        return builtin_resource_contract(
            [callable_resource_role_read()],
            callable_resource_role_read(), [])
    }
    if tag == BUILTIN_VALUE_HASH_COMBINE {
        return builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_read(), [])
    }
    if tag == BUILTIN_VALUE_STR_IDENTITY {
        return builtin_resource_contract(
            [callable_resource_role_read()],
            callable_resource_role_read(), [0])
    }
    if tag == BUILTIN_VALUE_BOOL_TO_STR {
        return builtin_resource_contract(
            [callable_resource_role_read()],
            callable_resource_role_consume(), [])
    }
    if tag == BUILTIN_VALUE_LIST_INDEX {
        return builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_read(), [0])
    }
    if tag == BUILTIN_VALUE_STR_INDEX {
        return builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), [])
    }
    panic("builtin value contract: resource census is incomplete")
}

pub struct BuiltinValueContractFact {
    site: BuiltinValueSite,
    executable: ExecutableRef,
    symbol: SymbolRef,
    scheme: TypeScheme,
    resource: CallableResourceContractFact,
    physical: BuiltinValuePhysicalLoweringFact
}

fn make_builtin_value_contract_fact(
    site: BuiltinValueSite
) -> BuiltinValueContractFact {
    let symbol = builtin_value_symbol(site)
    let executable = make_named_executable_ref(symbol)
    let scheme = builtin_value_scheme_for_site(site)
    let resource = builtin_value_resource_contract(site)
    let arity = match scheme.ty {
        Type::FnType { params, .. } => params.len(),
        _ => panic("builtin value contract: scheme is not callable")
    }
    if scheme.bounds.len() != 0 ||
       callable_resource_contract_parameter_roles(resource).len() != arity ||
       !executable_ref_is_named(executable) ||
       !symbol_ref_same(executable_ref_named_symbol(executable), symbol) {
        panic("builtin value contract: typed relation is incomplete")
    }
    BuiltinValueContractFact {
        site: site, executable: executable, symbol: symbol,
        scheme: scheme, resource: resource,
        physical: builtin_value_physical_lowering(site)
    }
}

pub fn builtin_value_contract_site(
    value: BuiltinValueContractFact
) -> BuiltinValueSite { value.site }

pub fn builtin_value_contract_executable(
    value: BuiltinValueContractFact
) -> ExecutableRef { value.executable }

pub fn builtin_value_contract_symbol(
    value: BuiltinValueContractFact
) -> SymbolRef { value.symbol }

pub fn builtin_value_contract_scheme(
    value: BuiltinValueContractFact
) -> TypeScheme { value.scheme }

pub fn builtin_value_contract_resource(
    value: BuiltinValueContractFact
) -> CallableResourceContractFact { value.resource }

pub fn builtin_value_contract_physical(
    value: BuiltinValueContractFact
) -> BuiltinValuePhysicalLoweringFact { value.physical }

// Sole typed manifest for ordinary compiler-owned direct-call leaves.  Every
// valid BuiltinValueSite produces exactly one relation, and exact executable
// identity is independently unique across the closed ten-site domain.
pub fn builtin_value_contract_facts(
) -> List<BuiltinValueContractFact> {
    let mut result: List<BuiltinValueContractFact> = []
    for tag in 0..BUILTIN_VALUE_SITE_COUNT {
        let fact = make_builtin_value_contract_fact(
            builtin_value_site_from_tag(tag))
        if builtin_value_site_tag(fact.site) != tag {
            panic("builtin value contract: site order drifted")
        }
        for existing in result {
            if builtin_value_site_tag(existing.site) == tag ||
               symbol_ref_same(existing.symbol, fact.symbol) {
                panic("builtin value contract: exact relation is not unique")
            }
        }
        result.push(fact)
    }
    if result.len() != BUILTIN_VALUE_SITE_COUNT {
        panic("builtin value contract: exact site census drifted")
    }
    result
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
// register_effects: dedicated abortive failure effect. System capabilities
// are exact row atoms on host extern declarations, not handled EffectDefs.
// ============================================================

fn register_effects(mut env: TypeEnv) {
    // fail effect
    let fail_t_id = env.fresh_var_id()
    let fail_t = Type::TypeVar { id: fail_t_id, name: none }
    env.types.effects.insert("fail", EffectDef {
        name: "fail",
        owner_ref: none, handled_ref: none,
        type_params: ["E"],
        type_param_vars: [fail_t_id],
        ops: [
            EffectOpDef { name: "raise", operation_ref: none,
                params: [fail_t], return_type: NEVER,
                effect_schema: empty_typed_effect_header_schema() }
        ],
        built_in_kind: some(BuiltInKind::BkFail)
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
        field_effect_schemas: [empty_typed_effect_header_schema()],
        derive_attrs: [],
        derived_provider_plan: none,
        resource_storage_parameter_ordinals: [],
        is_extern: false
    })

    // Register Cell constructor function
    bind_registered_builtin_value(
        env, BUILTIN_CELL, builtin_value_site_from_tag(
            BUILTIN_VALUE_CELL_CONSTRUCTOR))

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
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    // set: (Cell<T>, T) -> () / mut
    methods.insert("set", TypeScheme {
        ty: Type::FnType { params: [self_type, m_t], return_type: UNIT, effects: mut_row },
        type_vars: [m_t_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    // update: (Cell<T>, (T) -> T) -> () / mut
    let update_cb = Type::FnType { params: [m_t], return_type: m_t, effects: EMPTY_ROW }
    methods.insert("update", TypeScheme {
        ty: Type::FnType { params: [self_type, update_cb], return_type: UNIT, effects: mut_row },
        type_vars: [m_t_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    let mut intrinsics: Map<Str, IntrinsicRef> = map_new()
    let mut resources: Map<Str, CallableResourceContractFact> = map_new()
    install_intrinsic_contract(intrinsics, resources, "get",
        BUILTIN_METHOD_CELL_GET, builtin_resource_contract(
            [callable_resource_role_read()],
            callable_resource_role_consume(), [0]))
    install_intrinsic_contract(intrinsics, resources, "set",
        BUILTIN_METHOD_CELL_SET, builtin_resource_contract(
            [callable_resource_role_mutate(),
             callable_resource_role_consume()],
            callable_resource_role_read(), []))
    install_intrinsic_contract(intrinsics, resources, "update",
        BUILTIN_METHOD_CELL_UPDATE, builtin_resource_contract(
            [callable_resource_role_mutate(), callable_resource_role_read()],
            callable_resource_role_read(), []))
    install_builtin_method_owner(
        env, sink, BUILTIN_CELL,
        none, ["T"], [m_t_id], [], methods, intrinsics, resources,
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
    let some_ref = builtin_option_some_variant_ref()
    let none_ref = builtin_option_none_variant_ref()
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
        variant_field_effect_schemas:
            [[empty_typed_effect_header_schema()], []],
        derive_attrs: [],
        derived_provider_plan: none,
        variant_index: option_vi
    })

    env.types.variant_to_enum.insert("some", BUILTIN_OPTION)
    env.types.variant_to_enum.insert("none", BUILTIN_OPTION)

    // Direct constructor syntax infers payloads from the exact EnumDef.  The
    // lexical binding only exposes the polymorphic enum result to the checker;
    // it is not a callable scheme or a backend constructor symbol.
    let some_t_id = env.fresh_var_id()
    let some_t = Type::TypeVar { id: some_t_id, name: none }
    env.bind("some", TypeScheme {
        ty: make_option_type(some_t),
        type_vars: [some_t_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    // none is the same checker-only enum-result binding; its exact VariantRef
    // selects the borrowed singleton at the physical C boundary.
    let none_t_id = env.fresh_var_id()
    let none_t = Type::TypeVar { id: none_t_id, name: none }
    env.bind("none", TypeScheme {
        ty: make_option_type(none_t),
        type_vars: [none_t_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    // Option methods: is_some, is_none, unwrap_or
    let mut methods: Map<Str, TypeScheme> = map_new()

    let t_id = env.fresh_var_id()
    let t = Type::TypeVar { id: t_id, name: none }
    let self_type = make_option_type(t)

    methods.insert("is_some", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: BOOL, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    methods.insert("is_none", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: BOOL, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    methods.insert("unwrap_or", TypeScheme {
        ty: Type::FnType { params: [self_type, t], return_type: t, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    methods.insert("unwrap", TypeScheme {
        ty: Type::FnType { params: [self_type], return_type: t, effects: EMPTY_ROW },
        type_vars: [t_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })
    let mut intrinsics: Map<Str, IntrinsicRef> = map_new()
    let mut resources: Map<Str, CallableResourceContractFact> = map_new()
    install_intrinsic_contract(intrinsics, resources, "unwrap_or",
        BUILTIN_METHOD_OPTION_UNWRAP_OR, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), [0, 1]))
    install_intrinsic_contract(intrinsics, resources, "unwrap",
        BUILTIN_METHOD_OPTION_UNWRAP, builtin_resource_contract(
            [callable_resource_role_read()],
            callable_resource_role_consume(), [0]))
    install_intrinsic_contract(intrinsics, resources, "is_some",
        BUILTIN_METHOD_OPTION_IS_SOME, builtin_resource_contract(
            [callable_resource_role_read()], callable_resource_role_read(), []))
    install_intrinsic_contract(intrinsics, resources, "is_none",
        BUILTIN_METHOD_OPTION_IS_NONE, builtin_resource_contract(
            [callable_resource_role_read()], callable_resource_role_read(), []))
    install_intrinsic_contract(intrinsics, resources, "to_fail",
        BUILTIN_METHOD_OPTION_TO_FAIL, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), [0]))
    install_builtin_method_owner(
        env, sink, BUILTIN_OPTION,
        none, ["T"], [t_id], [], methods, intrinsics, resources,
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
        env, "Eq", owner_ref, [], [self_var_id], self_var_id, [
            TraitMethodDef { name: "eq", method_ref: builtin_trait_method(owner_ref, 0, 0, "eq"), ty: eq_fn, effect_schema: empty_typed_effect_header_schema(), has_default: false, param_mutabilities: [false, false], method_type_params: [] },
            TraitMethodDef { name: "ne", method_ref: builtin_trait_method(owner_ref, 1, 1, "ne"), ty: ne_fn, effect_schema: empty_typed_effect_header_schema(), has_default: true, param_mutabilities: [false, false], method_type_params: [] }
        ], [], [])

    // Register Eq impls with the exact intrinsic contract at the producer.
    add_builtin_impl(env, sink, "Eq", "Int", [], [], [], [
        builtin_intrinsic_method("eq", BUILTIN_METHOD_INT_EQ,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), [])),
        builtin_intrinsic_method("ne", BUILTIN_METHOD_INT_NE,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), []))])
    add_builtin_impl(env, sink, "Eq", "Float", [], [], [], [
        builtin_intrinsic_method("eq", BUILTIN_METHOD_FLOAT_EQ,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), [])),
        builtin_intrinsic_method("ne", BUILTIN_METHOD_FLOAT_NE,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), []))])
    add_builtin_impl(env, sink, "Eq", "Str", [], [], [], [
        builtin_intrinsic_method("eq", BUILTIN_METHOD_STR_EQ,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), [])),
        builtin_intrinsic_method("ne", BUILTIN_METHOD_STR_NE,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), []))])
    add_builtin_impl(env, sink, "Eq", "Bool", [], [], [], [
        builtin_intrinsic_method("eq", BUILTIN_METHOD_BOOL_EQ,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), [])),
        builtin_intrinsic_method("ne", BUILTIN_METHOD_BOOL_NE,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), []))])
}

// ============================================================
// register_option_eq: Option<T: Eq> Eq impl
// ============================================================

fn register_option_eq(mut env: TypeEnv, sink: CollectingSink) {
    let t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Eq", BUILTIN_OPTION, ["T"], [t_id],
        [BuiltinPredicateSpec { subject_param_index: 0, trait_name: "Eq" }],
        [builtin_impl_method("eq"), builtin_impl_method("ne")])
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
        env, "Clone", owner_ref, [], [self_var_id], self_var_id, [
            TraitMethodDef { name: "clone", method_ref: builtin_trait_method(owner_ref, 0, 0, "clone"), ty: clone_fn, effect_schema: empty_typed_effect_header_schema(), has_default: false, param_mutabilities: [false], method_type_params: [] }
        ], [], [])

    // Primitive impls carry their exact physical intrinsic contract here.
    add_builtin_impl(env, sink, "Clone", "Int", [], [], [], [
        builtin_intrinsic_method("clone", BUILTIN_METHOD_INT_CLONE,
            builtin_resource_contract([callable_resource_role_read()],
                callable_resource_role_consume(), [0]))])
    add_builtin_impl(env, sink, "Clone", "Float", [], [], [], [
        builtin_intrinsic_method("clone", BUILTIN_METHOD_FLOAT_CLONE,
            builtin_resource_contract([callable_resource_role_read()],
                callable_resource_role_consume(), [0]))])
    add_builtin_impl(env, sink, "Clone", "Str", [], [], [], [
        builtin_intrinsic_method("clone", BUILTIN_METHOD_STR_CLONE,
            builtin_resource_contract([callable_resource_role_read()],
                callable_resource_role_consume(), [0]))])
    add_builtin_impl(env, sink, "Clone", "Bool", [], [], [], [
        builtin_intrinsic_method("clone", BUILTIN_METHOD_BOOL_CLONE,
            builtin_resource_contract([callable_resource_role_read()],
                callable_resource_role_consume(), [0]))])

    // List/Map/Set Clone impls are ordinary std bodies. Their element/key/value
    // Clone evidence must remain visible to Core and ResourcePlanner.
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
        env, "Drop", owner_ref, [], [self_var_id], self_var_id, [
            TraitMethodDef { name: "drop", method_ref: builtin_trait_method(owner_ref, 0, 0, "drop"), ty: drop_fn, effect_schema: empty_typed_effect_header_schema(), has_default: false, param_mutabilities: [false], method_type_params: [] }
        ], [], [])
}

// ============================================================
// register_option_clone: Option<T: Clone> Clone impl
// ============================================================

fn register_option_clone(mut env: TypeEnv, sink: CollectingSink) {
    let t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Clone", BUILTIN_OPTION, ["T"], [t_id],
        [BuiltinPredicateSpec { subject_param_index: 0, trait_name: "Clone" }],
        [builtin_impl_method("clone")])
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
        env, "Ord", owner_ref, [], [self_var_id], self_var_id, [
            TraitMethodDef { name: "cmp", method_ref: builtin_trait_method(owner_ref, 0, 0, "cmp"), ty: cmp_fn, effect_schema: empty_typed_effect_header_schema(), has_default: false, param_mutabilities: [false, false], method_type_params: [] }
        ], [], [])

    add_builtin_impl(env, sink, "Ord", "Int", [], [], [], [
        builtin_intrinsic_method("cmp", BUILTIN_METHOD_INT_CMP,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), []))])
    add_builtin_impl(env, sink, "Ord", "Float", [], [], [], [
        builtin_intrinsic_method("cmp", BUILTIN_METHOD_FLOAT_CMP,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), []))])
    add_builtin_impl(env, sink, "Ord", "Str", [], [], [], [
        builtin_intrinsic_method("cmp", BUILTIN_METHOD_STR_CMP,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), []))])
    add_builtin_impl(env, sink, "Ord", "Bool", [], [], [], [
        builtin_intrinsic_method("cmp", BUILTIN_METHOD_BOOL_CMP,
            builtin_resource_contract(
                [callable_resource_role_read(), callable_resource_role_read()],
                callable_resource_role_read(), []))])
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
        env, "Debug", owner_ref, [], [self_var_id], self_var_id, [
            TraitMethodDef { name: "debug", method_ref: builtin_trait_method(owner_ref, 0, 0, "debug"), ty: debug_fn, effect_schema: empty_typed_effect_header_schema(), has_default: false, param_mutabilities: [false], method_type_params: [] }
        ], [], [])

    // Primitive impls
    add_builtin_impl(env, sink, "Debug", "Int", [], [], [], [
        builtin_intrinsic_method("debug", BUILTIN_METHOD_INT_DEBUG,
            builtin_resource_contract([callable_resource_role_read()],
                callable_resource_role_consume(), []))])
    add_builtin_impl(env, sink, "Debug", "Float", [], [], [], [
        builtin_intrinsic_method("debug", BUILTIN_METHOD_FLOAT_DEBUG,
            builtin_resource_contract([callable_resource_role_read()],
                callable_resource_role_consume(), []))])
    add_builtin_impl(env, sink, "Debug", "Str", [], [], [], [
        builtin_intrinsic_method("debug", BUILTIN_METHOD_STR_DEBUG,
            builtin_resource_contract([callable_resource_role_read()],
                callable_resource_role_consume(), []))])
    add_builtin_impl(env, sink, "Debug", "Bool", [], [], [], [
        builtin_intrinsic_method("debug", BUILTIN_METHOD_BOOL_DEBUG,
            builtin_resource_contract([callable_resource_role_read()],
                callable_resource_role_consume(), []))])

    // List<T: Debug> Debug impl
    let list_t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Debug", BUILTIN_LIST,
        ["T"], [list_t_id],
        [BuiltinPredicateSpec { subject_param_index: 0, trait_name: "Debug" }],
        [builtin_impl_method("debug")])

    // Map<K, V> Debug impl (no bounds required in TS source)
    let map_k_id = env.fresh_var_id()
    let map_v_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Debug", BUILTIN_MAP,
        ["K", "V"], [map_k_id, map_v_id], [],
        [builtin_impl_method("debug")])

    // Set<T> Debug impl (no bounds required in TS source)
    let set_t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Debug", BUILTIN_SET,
        ["T"], [set_t_id], [], [builtin_impl_method("debug")])
}

// ============================================================
// register_option_debug: Option<T: Debug> Debug impl
// ============================================================

fn register_option_debug(mut env: TypeEnv, sink: CollectingSink) {
    let t_id = env.fresh_var_id()
    add_builtin_impl(env, sink, "Debug", BUILTIN_OPTION, ["T"], [t_id],
        [BuiltinPredicateSpec { subject_param_index: 0, trait_name: "Debug" }],
        [builtin_impl_method("debug")])
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
        env, "Hash", owner_ref, [], [self_var_id], self_var_id, [
            TraitMethodDef { name: "hash", method_ref: builtin_trait_method(owner_ref, 0, 0, "hash"), ty: hash_fn, effect_schema: empty_typed_effect_header_schema(), has_default: false, param_mutabilities: [false], method_type_params: [] }
        ], [], [])

    add_builtin_impl(env, sink, "Hash", "Int", [], [], [], [
        builtin_intrinsic_method("hash", BUILTIN_METHOD_INT_HASH,
            builtin_resource_contract([callable_resource_role_read()],
                callable_resource_role_read(), []))])
    add_builtin_impl(env, sink, "Hash", "Str", [], [], [], [
        builtin_intrinsic_method("hash", BUILTIN_METHOD_STR_HASH,
            builtin_resource_contract([callable_resource_role_read()],
                callable_resource_role_read(), []))])
    add_builtin_impl(env, sink, "Hash", "Bool", [], [], [], [
        builtin_intrinsic_method("hash", BUILTIN_METHOD_BOOL_HASH,
            builtin_resource_contract([callable_resource_role_read()],
                callable_resource_role_read(), []))])
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
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    // filter: (List<T>, (T) -> Bool / e) -> List<T> / e
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("filter", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_list_struct(t), effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    // any: (List<T>, (T) -> Bool / e) -> Bool / e
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("any", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: BOOL, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    // all: (List<T>, (T) -> Bool / e) -> Bool / e
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("all", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: BOOL, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    // find: (List<T>, (T) -> Bool / e) -> Option<T> / e
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("find", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_option_type(t), effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    // find_index: (List<T>, (T) -> Bool / e) -> Option<Int> / e
    orow = open_row(env)
    cb = Type::FnType { params: [t], return_type: BOOL, effects: orow.eff }
    methods.insert("find_index", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: make_option_type(INT), effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    // sort_by: (List<T>, (T, T) -> Int / e) -> () / e
    orow = open_row(env)
    cb = Type::FnType { params: [t, t], return_type: INT, effects: orow.eff }
    methods.insert("sort_by", TypeScheme {
        ty: Type::FnType { params: [make_list_struct(t), cb], return_type: UNIT, effects: orow.eff },
        type_vars: [t_id, orow.tail_id],
        bounds: [],
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })
    install_builtin_method_owner(
        env, sink, BUILTIN_LIST,
        none, ["T"], [t_id], [],
        methods, map_new(), map_new(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    install_builtin_method_owner(
        env, sink, BUILTIN_MAP,
        none, ["K", "V"], [unbounded_k_id, unbounded_v_id], [],
        unbounded_methods, map_new(), map_new(),
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
        ], bounded_methods, map_new(), map_new(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })

    install_builtin_method_owner(
        env, sink, BUILTIN_SET,
        none, ["T"], [unbounded_t_id], [],
        unbounded_methods, map_new(), map_new(),
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
        ], bounded_methods, map_new(), map_new(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })
    let mut intrinsics: Map<Str, IntrinsicRef> = map_new()
    let mut resources: Map<Str, CallableResourceContractFact> = map_new()
    install_intrinsic_contract(intrinsics, resources, "map",
        BUILTIN_METHOD_OPTION_MAP, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_intrinsic_contract(intrinsics, resources, "and_then",
        BUILTIN_METHOD_OPTION_AND_THEN, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), []))
    install_intrinsic_contract(intrinsics, resources, "unwrap_or_else",
        BUILTIN_METHOD_OPTION_UNWRAP_OR_ELSE, builtin_resource_contract(
            [callable_resource_role_read(), callable_resource_role_read()],
            callable_resource_role_consume(), [0]))
    install_builtin_method_owner(
        env, sink, BUILTIN_OPTION,
        none, [], [], [], methods, intrinsics, resources,
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_OPTION_HOF))
}

// ============================================================
// B-125: register Ptr<T> builtin functions and methods
// ============================================================

fn register_ptr_builtins(mut env: TypeEnv, sink: CollectingSink) {
    let unsafe_row = EffectRow { effects: [Effect::UnsafeEffect], tail: none }

    // ---- Top-level builtin functions ----

    // alloc(count: Int) -> Ptr<T> / unsafe
    bind_registered_builtin_value(
        env, "alloc", builtin_value_site_from_tag(BUILTIN_VALUE_ALLOC))

    // dealloc(p: Ptr<T>, count: Int) -> () / unsafe
    bind_registered_builtin_value(
        env, "dealloc", builtin_value_site_from_tag(
            BUILTIN_VALUE_DEALLOC))

    // ptr_copy(src: Ptr<T>, dst: Ptr<T>, count: Int) -> () / unsafe
    bind_registered_builtin_value(
        env, "ptr_copy", builtin_value_site_from_tag(
            BUILTIN_VALUE_PTR_COPY))

    // ptr_from_addr(a: Int) -> Ptr<T> (safe)
    bind_registered_builtin_value(
        env, "ptr_from_addr", builtin_value_site_from_tag(
            BUILTIN_VALUE_PTR_FROM_ADDR))

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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
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
        effect_schema: empty_typed_effect_header_schema(),
        def_id: none
    })
    install_builtin_method_owner(
        env, sink, "Ptr",
        none, [], [], [], methods, map_new(), map_new(),
        builtin_impl_provider_site_from_tag(BUILTIN_PROVIDER_PTR_CORE))
}
