use types::{Type, EffectRow, StructField, EnumVariant,
    INT, STR, BOOL, EMPTY_ROW, BUILTIN_OPTION, types_equal,
    type_to_builtin_name}
use env::{TypeEnv, TypeScheme, SchemeBound, StructDef, EnumDef,
    ImplEntry, ImplMethodSchemeCore, ImplAssocPredicate,
    ExplicitDerivedProviderPlan, NominalDerivedProviderPlan,
    TypedImplPredicate,
    add_impl, has_impl, find_impl, find_impl_by_provider, install_method_core,
    instantiate_impl_runtime_requirements,
    make_impl_method_scheme_core, make_typed_impl_predicate,
    impl_method_core_type,
    direct_impl_predicate_provenance, freeze_impl_predicate_set,
    impl_predicate_subject_type_var, impl_predicate_trait_name,
    impl_predicate_subject_param_index, frozen_impl_predicates,
    impl_assoc_predicate_name, impl_assoc_predicate_type,
    apply_subst_map,
    impl_target_symbol}
use builtins::{builtin_option_derived_owners}
use effect_contract::{
    empty_typed_effect_header_schema, empty_typed_effect_ctx_layout,
    make_typed_callable_effect_ctx, make_empty_effect_ctx_source
}
use ast::{Span, DeriveAttribute, TypeParam, TypeBound, span_zero}
use diagnostics::{CollectingSink, Severity, DiagnosticContext, make_diag}
use codes::{E0503}
use hir::{DerivedImpl, DerivedMethod, DerivedSemanticKind, DerivedDirectCall,
    DerivedField, DerivedFieldRef,
    DerivedVariant, DerivedTextPiece, DerivedTextSequence,
    DerivedTextVariant, DerivedTextPlan,
    FieldAction, DictRef, HExactCallPlan,
    MethodCallRef, HProjectionRef, make_intrinsic_method_call_ref,
    make_concrete_method_call_ref, make_bound_method_call_ref,
    method_call_ref_is_intrinsic, method_call_ref_is_concrete,
    method_call_ref_intrinsic, method_call_ref_impl,
    method_call_ref_bound, method_call_ref_bound_evidence,
    method_call_ref_signature, method_call_ref_receiver_mutable,
    method_call_ref_callee_identity, make_h_exact_call_plan,
    h_tuple_projection, derived_semantic_kind_tag,
    TraitBound, HTypeParam, TypeKind, trait_dict_name,
    trait_bound_param_name, compare_by_first}
use hir_exact::{
    make_simple_dict_ref, make_static_dict_ref, make_wrapped_dict_ref,
    dict_ref_exact, dict_ref_is_simple_physical,
    dict_ref_is_static_physical, dict_ref_simple_name,
    dict_ref_static_name, dict_ref_wrapped_name,
    dict_ref_wrapped_physical_inner
}
use ir_identity::{SymbolRef, ImplProviderRef, ImplOwnerRef, ImplMethodRef,
    RegisteredNominalRef,
    make_impl_owner_ref, make_impl_method_ref, make_named_callee_ref,
    make_symbol_ref, namespace_member,
    make_path_ref, path_owner_for_symbol, path_role_declaration,
    path_role_parameter,
    make_source_slot_ref, slot_domain_lexical,
    path_ref_same, slot_ref_same,
    impl_provider_ref_site, path_ref_owner,
    path_owner_ref_module_body, module_body_ref_origin_module_key,
    path_ref_normalized_child_path,
    symbol_ref_same, impl_provider_ref_same, impl_owner_ref_same,
    impl_method_ref_same, registered_nominal_ref_same,
    impl_provider_ref_kind, impl_provider_kind_same,
    impl_provider_kind_builtin, impl_provider_kind_derived,
    registered_trait_ref_symbol, registered_nominal_ref_symbol,
    impl_owner_ref_target, impl_method_ref_owner, impl_method_ref_member,
    impl_method_ref_name,
    symbol_ref_origin_module_key, symbol_ref_stable_key}
use ir_identity::{builtin_value_site_from_tag, builtin_value_symbol,
    BUILTIN_VALUE_HASH_COMBINE}
use ir_inventory::{ExecutableRef, BinderEntry,
    make_parameter_dict_ref, make_exact_static_dict_ref,
    make_exact_wrapped_dict_ref, dict_ref_wrapped_base,
    make_named_executable_ref, executable_ref_is_named,
    executable_ref_named_symbol, executable_ref_same,
    make_source_binder_entry,
    binder_entry_slot, binder_entry_owner, binder_entry_kind,
    binder_entry_site, binder_kind_tag, binder_kind_let,
    binder_kind_match_pattern,
    binder_kind_source_param,
    make_effect_ctx_parameter_ref}
use infer_ctx::{InferCtx, value_symbol_ref}
use infer_helpers::{exact_nominal_method_call}

fn str_at(list: List<Str>, i: Int) -> Str {
    match list.get(i) { some(v) => v, none => panic("unreachable: str_at out of bounds") }
}

fn int_at(list: List<Int>, i: Int) -> Int {
    match list.get(i) { some(v) => v, none => panic("unreachable: int_at out of bounds") }
}

fn type_at(list: List<Type>, i: Int) -> Type {
    match list.get(i) { some(v) => v, none => panic("unreachable: type_at out of bounds") }
}

fn df_at(list: List<DerivedField>, i: Int) -> DerivedField {
    match list.get(i) { some(v) => v, none => panic("unreachable: df_at out of bounds") }
}

// Derive's fixed point is transient. The only stored authority is the
// FrozenImplPredicateSet installed on the completed ImplEntry.
struct DerivedPredicatePlan {
    type_param_index: Int,
    trait_name: Str
}

// Eligibility/fixed-point planning precedes registry installation, so it
// cannot claim a final ImplOwnerRef or executable inventory.  This private
// draft never crosses into HProgram; finalize_derived_impl atomically turns a
// registered owner plus this field plan into the mandatory exact HIR fact.
struct DerivedImplDraft {
    provider_ref: ImplProviderRef,
    trait_ref: SymbolRef,
    type_name: Str,
    trait_name: Str,
    type_params: List<Str>,
    bounds: List<TraitBound>,
    type_kind: TypeKind,
    struct_fields: List<DerivedField>?,
    enum_variants: List<DerivedVariant>?
}

struct DerivedCallAuthority {
    self_type_name: Str,
    self_method: ImplMethodRef?
}

fn derived_runtime_owner(value: DerivedCallAuthority) -> ExecutableRef {
    match value.self_method {
        some(method) => make_named_executable_ref(impl_method_ref_member(method)),
        none => panic("derived dictionary evidence lacks method owner")
    }
}

fn derived_bound_dict_ref(
    authority: DerivedCallAuthority, bounds: List<TraitBound>,
    type_var_id: Int, trait_name: Str
) -> DictRef {
    let bound = bounds.find(fn(value) {
        value.type_var_id == type_var_id && value.trait_name == trait_name
    }).unwrap_or_else(fn() {
        panic("derived dictionary evidence bound is absent")
    })
    make_simple_dict_ref(
        trait_bound_param_name(bound.type_param, bound.trait_name),
        make_parameter_dict_ref(
            derived_runtime_owner(authority), bound.dict_ordinal))
}

fn derived_impl_owner(
    env: TypeEnv, type_name: Str, trait_name: Str,
    authority: DerivedCallAuthority
) -> ImplOwnerRef {
    match find_impl(env.trait_reg, type_name, trait_name) {
        some(entry) => match entry.owner_ref {
            some(owner) => owner,
            none => panic("derived dictionary impl owner is absent")
        },
        none => if type_name == authority.self_type_name {
            match authority.self_method {
                some(method) => impl_method_ref_owner(method),
                none => panic("derived self dictionary owner is absent")
            }
        } else {
            panic("derived dictionary impl is absent")
        }
    }
}

fn derived_static_dict_ref(
    env: TypeEnv, type_name: Str, trait_name: Str,
    authority: DerivedCallAuthority
) -> DictRef {
    make_static_dict_ref(
        trait_dict_name(type_name, trait_name),
        make_exact_static_dict_ref(derived_impl_owner(
            env, type_name, trait_name, authority)))
}

fn derived_wrapped_dict_ref(
    env: TypeEnv, type_name: Str, trait_name: Str,
    inner: List<DictRef>, authority: DerivedCallAuthority
) -> DictRef {
    let owner = derived_impl_owner(env, type_name, trait_name, authority)
    make_wrapped_dict_ref(
        trait_dict_name(type_name, trait_name),
        registered_derive_trait_ref(env, trait_name), inner,
        make_exact_wrapped_dict_ref(owner, inner.map(fn(value) {
            dict_ref_exact(value)
        })))
}

const BUILTIN_TYPES: Set<Str> = set_from(["Option", "Cell", "List", "Map", "Set", "Range"])

// ================================================================
// Public entry point
// ================================================================

pub fn run_derive_pass(
    mut ctx: InferCtx
) -> List<DerivedImpl> {
    let mut derived_impls: List<DerivedImpl> = []
    let all_types = collect_user_types(ctx.env)
    derive_trait(ctx.env, ctx.sink, all_types, "Eq", derived_impls)
    // B-107 coherence: only the compiler's structural Eq path may opt a type
    // into structural Hash.  At this point derived_impls contains only this
    // pass's Eq impls, so manual Eq impls already present in trait_reg cannot
    // be mistaken for auto Eq.
    let auto_eq_types = collect_derived_type_names(derived_impls, "Eq")
    derive_hash_trait(
        ctx.env, ctx.sink, all_types, auto_eq_types, derived_impls)
    derive_trait(ctx.env, ctx.sink, all_types, "Clone", derived_impls)
    derive_trait(ctx.env, ctx.sink, all_types, "Ord", derived_impls)
    derive_trait(ctx.env, ctx.sink, all_types, "Debug", derived_impls)
    derive_json_trait(ctx.env, ctx.sink, all_types, derived_impls)
    let mut exact: List<DerivedImpl> = []
    if ctx.core_module_order == 0 {
        for builtin in builtin_option_derived_impls(ctx.env) {
            exact.push(builtin)
        }
    }
    for derived in derived_impls { exact.push(derived) }
    close_derived_text_plans(ctx, exact)
}

fn option_derived_some_variant(
    env: TypeEnv, bound: TraitBound, authority: DerivedCallAuthority
) -> DerivedVariant {
    let option_def = env.types.enums.get(BUILTIN_OPTION).unwrap_or_else(fn() {
        panic("builtin Option derived descriptor lost enum owner")
    })
    let variant_index = option_def.variant_index.get("some").unwrap_or_else(fn() {
        panic("builtin Option derived descriptor lost some variant")
    })
    let variant = option_def.variants.get(variant_index).unwrap()
    let variant_ref = option_def.variant_refs.get(variant_index).unwrap()
    let field_refs = option_def.variant_field_refs.get(variant_index).unwrap()
    let field_type = variant.fields.get(0).unwrap()
    let field_ref = field_refs.get(0).unwrap()
    let evidence = derived_bound_dict_ref(
        authority, [bound], bound.type_var_id, bound.trait_name)
    let action = derived_call_action(
        env, field_type, bound.trait_name, evidence, [],
        authority).unwrap_or_else(fn() {
        panic("builtin Option derived descriptor lost field method")
    })
    DerivedVariant {
        name: "some",
        variant_ref: variant_ref,
        discriminator: 0,
        fields: [DerivedField {
            name: "_0",
            positional_index: some(0),
            field_ref: DerivedFieldRef::VariantDerivedField(field_ref),
            ty: field_type, action: action, ord_result_binders: []
        }],
        has_named_fields: false
    }
}

fn option_derived_none_variant(env: TypeEnv) -> DerivedVariant {
    let option_def = env.types.enums.get(BUILTIN_OPTION).unwrap_or_else(fn() {
        panic("builtin Option derived descriptor lost enum owner")
    })
    let variant_index = option_def.variant_index.get("none").unwrap_or_else(fn() {
        panic("builtin Option derived descriptor lost none variant")
    })
    DerivedVariant {
        name: "none",
        variant_ref: option_def.variant_refs.get(variant_index).unwrap(),
        discriminator: 1,
        fields: [], has_named_fields: false
    }
}

fn builtin_option_derived_impl(env: TypeEnv, owner: ImplEntry) -> DerivedImpl {
    let provider_ref = match owner.provider_ref {
        some(provider) => provider,
        none => panic("builtin Option derived descriptor lost provider")
    }
    let trait_ref = match owner.trait_ref {
        some(value) => value,
        none => panic("builtin Option derived descriptor lost trait")
    }
    let trait_name = match owner.trait_name {
        some(name) => name,
        none => panic("builtin Option derived descriptor lost trait name")
    }
    if owner.target_type_name != BUILTIN_OPTION ||
       !impl_provider_kind_same(
            impl_provider_ref_kind(provider_ref),
            impl_provider_kind_builtin()) ||
       !string_lists_same(owner.type_params, ["T"]) {
        panic("builtin Option derived descriptor owner drifted")
    }
    let bounds = derived_runtime_bounds_from_owner(env, owner)
    if bounds.len() != 1 {
        panic("builtin Option derived descriptor lost exact predicate")
    }
    let bound = bounds.get(0).unwrap()
    if bound.type_param != "T" || bound.trait_name != trait_name {
        panic("builtin Option derived descriptor predicate drifted")
    }
    let primary_name = derived_primary_method_name(trait_name)
    let authority = DerivedCallAuthority {
        self_type_name: BUILTIN_OPTION,
        self_method: owner.method_refs.get(primary_name)
    }
    if authority.self_method.is_none() {
        panic("builtin Option derived descriptor lost primary method")
    }
    let variants = match trait_name {
        "Eq" => some([
            option_derived_some_variant(env, bound, authority),
            option_derived_none_variant(env)
        ]),
        "Debug" => some([
            option_derived_some_variant(env, bound, authority),
            option_derived_none_variant(env)
        ]),
        "Clone" => some([
            option_derived_some_variant(env, bound, authority),
            option_derived_none_variant(env)
        ]),
        _ => panic("builtin Option derived descriptor census drifted")
    }
    finalize_derived_impl(env, DerivedImplDraft {
        provider_ref: provider_ref,
        trait_ref: trait_ref,
        type_name: owner.target_type_name,
        trait_name: trait_name,
        type_params: owner.type_params,
        bounds: bounds,
        type_kind: TypeKind::EnumKind,
        struct_fields: none,
        enum_variants: variants
    }, owner)
}

pub fn builtin_option_derived_impls(env: TypeEnv) -> List<DerivedImpl> {
    let mut result: List<DerivedImpl> = []
    for owner in builtin_option_derived_owners(env) {
        result.push(builtin_option_derived_impl(env, owner))
    }
    if result.len() != 3 ||
       result.get(0).unwrap().trait_name != "Eq" ||
       result.get(1).unwrap().trait_name != "Debug" ||
       result.get(2).unwrap().trait_name != "Clone" {
        panic("builtin Option derived descriptor order drifted")
    }
    result
}

fn derived_impl_key_same(left: DerivedImpl, right: DerivedImpl) -> Bool {
    impl_owner_ref_same(left.owner_ref, right.owner_ref) &&
        left.type_name == right.type_name &&
        impl_provider_ref_same(left.provider_ref, right.provider_ref) &&
        symbol_ref_same(left.trait_ref, right.trait_ref)
}

fn derived_impl_matches_owner(
    env: TypeEnv, di: DerivedImpl, owner: ImplEntry
) -> Bool {
    let owner_identity_matches = match owner.owner_ref {
        some(exact) => impl_owner_ref_same(exact, di.owner_ref),
        none => false
    }
    let provider_matches = match owner.provider_ref {
        some(provider) => impl_provider_ref_same(
            provider, di.provider_ref),
        none => false
    }
    let trait_matches = match owner.trait_ref {
        some(trait_ref) => symbol_ref_same(trait_ref, di.trait_ref),
        none => false
    }
    let trait_name_matches = match owner.trait_name {
        some(name) => name == di.trait_name,
        none => false
    }
    if !owner_identity_matches || !provider_matches || !trait_matches ||
       !trait_name_matches {
        return false
    }
    if owner.target_type_name != di.type_name ||
       derived_semantic_kind_tag(di.semantic_kind) !=
            derived_semantic_kind_tag(
                derived_impl_semantic_kind(di.trait_name)) ||
       !symbol_ref_same(
            impl_owner_ref_target(di.owner_ref),
            registered_nominal_ref_symbol(di.target_owner)) ||
       !types_equal(di.target_type,
            derived_target_type(owner, di.type_kind)) ||
       !derived_h_type_params_same(
            derived_h_type_params(env, owner), di.type_params) ||
       !trait_bounds_same(
            derived_runtime_bounds_from_owner(env, owner), di.bounds) {
        return false
    }
    let method_names = get_method_names(di.trait_name)
    if di.methods.len() != method_names.len() { return false }
    for index in 0..method_names.len() {
        let method_name = method_names.get(index).unwrap()
        let actual = di.methods.get(index).unwrap()
        let expected_ref = match owner.method_refs.get(method_name) {
            some(value) => value,
            none => return false
        }
        let expected_core = match owner.method_schemes.get(method_name) {
            some(value) => value,
            none => return false
        }
        if !impl_method_ref_same(actual.method_ref, expected_ref) ||
           derived_semantic_kind_tag(actual.semantic_kind) !=
                derived_semantic_kind_tag(
                    derived_impl_semantic_kind(di.trait_name)) ||
           !types_equal(actual.signature, impl_method_core_type(expected_core)) ||
           !executable_ref_is_named(actual.executable_ref) ||
           !symbol_ref_same(
                executable_ref_named_symbol(actual.executable_ref),
                impl_method_ref_member(expected_ref)) {
            return false
        }
    }
    true
}

// This is the first real consumer of the derived carrier identity.  It checks
// the final registry owner rather than trusting a backend spelling or a derive
// plan that happened to mint the same display name.
pub fn validate_derived_impls(
    env: TypeEnv, derived_impls: List<DerivedImpl>
) {
    let builtin_owners = builtin_option_derived_owners(env)
    let mut seen: List<DerivedImpl> = []
    for di in derived_impls {
        for existing in seen {
            if derived_impl_key_same(existing, di) {
                panic("derived impl descriptor duplicated exact owner")
            }
        }
        let owner = match find_impl_by_provider(
            env.trait_reg, di.type_name,
            some(di.trait_ref), di.provider_ref
        ) {
            some(found) => found,
            none => panic("derived impl descriptor owner is missing")
        }
        if !derived_impl_matches_owner(env, di, owner) {
            panic("derived impl descriptor changed final owner")
        }
        let kind = impl_provider_ref_kind(di.provider_ref)
        if impl_provider_kind_same(kind, impl_provider_kind_builtin()) {
            let mut matches = 0
            for expected in builtin_owners {
                if derived_impl_matches_owner(env, di, expected) {
                    matches = matches + 1
                }
            }
            if matches != 1 {
                panic("derived impl descriptor has unknown builtin owner")
            }
        } else if !impl_provider_kind_same(
                kind, impl_provider_kind_derived()) {
            panic("derived impl descriptor has invalid provider kind")
        }
        seen.push(di)
    }
}

fn collect_derived_type_names(derived_impls: List<DerivedImpl>, trait_name: Str) -> Set<Str> {
    let mut names: Set<Str> = set_new()
    for di in derived_impls {
        if di.trait_name == trait_name {
            names.insert(di.type_name)
        }
    }
    names
}

// ================================================================
// Collect user-defined types
// ================================================================

struct UserType {
    name: Str,
    type_kind: TypeKind,
    struct_def: StructDef?,
    enum_def: EnumDef?,
    derive_attrs: List<DeriveAttribute>,
    provider_plan: NominalDerivedProviderPlan
}

fn collect_user_types(env: TypeEnv) -> List<UserType> {
    let builtins = BUILTIN_TYPES
    let mut result: List<UserType> = []
    let mut sorted_structs = env.types.structs.entries()
    sorted_structs.sort_by(compare_by_first)
    for entry in sorted_structs {
        let (name, def) = entry
        // Skip mod aliases (e.g. "Point" aliasing "geo::Point") to avoid duplicate derives
        if name != def.name { continue }
        // Skip opaque extern types (B-074): registered as zero-field structs for
        // type-checking, but they have no observable runtime structure to derive.
        if def.is_extern { continue }
        if builtins.contains(name) == false {
            result.push(UserType {
                name: name, type_kind: TypeKind::StructKind,
                struct_def: some(def), enum_def: none,
                derive_attrs: def.derive_attrs,
                provider_plan: def.derived_provider_plan.unwrap()
            })
        }
    }
    let mut sorted_enums = env.types.enums.entries()
    sorted_enums.sort_by(compare_by_first)
    for entry in sorted_enums {
        let (name, def) = entry
        // Skip mod aliases to avoid duplicate derives
        if name != def.name { continue }
        if builtins.contains(name) == false {
            result.push(UserType {
                name: name, type_kind: TypeKind::EnumKind,
                struct_def: none, enum_def: some(def),
                derive_attrs: def.derive_attrs,
                provider_plan: def.derived_provider_plan.unwrap()
            })
        }
    }
    result
}

// ================================================================
// Fixpoint derivation for a single trait
// ================================================================

fn derive_trait(
    mut env: TypeEnv, sink: CollectingSink,
    all_types: List<UserType>, trait_name: Str,
    mut derived_impls: List<DerivedImpl>
) {
    let mut known = set_new()
    let mut sorted_impls = env.trait_reg.trait_impls.entries()
    sorted_impls.sort_by(compare_by_first)
    for entry in sorted_impls {
        let (tname, impls) = entry
        for imp in impls {
            match imp.trait_name {
                some(name) => if name == trait_name {
                    known.insert(imp.target_type_name)
                },
                none => {}
            }
        }
    }
    known.insert("Int")
    known.insert("Float")
    known.insert("Str")
    known.insert("Bool")

    let mut changed = true
    while changed {
        changed = false
        for ut in all_types {
            if known.contains(ut.name) { } else {
                // B-002p1: Drop types cannot auto-derive Clone (mutual exclusion)
                if trait_name == "Clone" && has_impl(env.trait_reg, ut.name, "Drop") { } else {
                if has_manual_impl(env, ut.name, trait_name) { } else {
                    let result = try_derive(
                        env, ut, trait_name, known,
                        implicit_derive_provider(ut))
                    match result {
                        some(di) => {
                            known.insert(ut.name)
                            let owner = register_derived_impl(
                                env, sink, di, span_zero())
                            derived_impls.push(
                                finalize_derived_impl(env, di, owner))
                            changed = true
                        },
                        none => {},
                    }
                }
                }
            }
        }
    }
}

// Hash uses the same try_derive decomposition as structural Eq, but eligibility
// is restricted to the exact set of Eq impls generated by this derive pass.
// A pre-existing manual Eq therefore never silently acquires structural Hash.
fn derive_hash_trait(
    mut env: TypeEnv,
    sink: CollectingSink,
    all_types: List<UserType>,
    auto_eq_types: Set<Str>,
    mut derived_impls: List<DerivedImpl>
) {
    let mut known: Set<Str> = set_new()
    let mut sorted_impls = env.trait_reg.trait_impls.entries()
    sorted_impls.sort_by(compare_by_first)
    for entry in sorted_impls {
        let (_tname, impls) = entry
        for imp in impls {
            match imp.trait_name {
                some(name) => if name == "Hash" {
                    known.insert(imp.target_type_name)
                },
                none => {}
            }
        }
    }
    // Hash has exactly these primitive impls.  In particular Float and Unit
    // must not enter the Hash fixpoint.
    known.insert("Int")
    known.insert("Str")
    known.insert("Bool")

    let mut changed = true
    while changed {
        changed = false
        for ut in all_types {
            if auto_eq_types.contains(ut.name) {
                if known.contains(ut.name) { } else {
                    if has_manual_impl(env, ut.name, "Hash") { } else {
                        let result = try_derive(
                            env, ut, "Hash", known,
                            implicit_derive_provider(ut))
                        match result {
                            some(di) => {
                                known.insert(ut.name)
                                let owner = register_derived_impl(
                                    env, sink, di, span_zero())
                                derived_impls.push(
                                    finalize_derived_impl(env, di, owner))
                                changed = true
                            },
                            none => {},
                        }
                    }
                }
            }
        }
    }
}

fn has_manual_impl(env: TypeEnv, type_name: Str, trait_name: Str) -> Bool {
    has_impl(env.trait_reg, type_name, trait_name)
}

fn requests_derive(ut: UserType, trait_name: Str) -> Bool {
    explicit_derive_request(ut, trait_name).is_some()
}

fn derive_attribute(ut: UserType, trait_name: Str) -> DeriveAttribute? {
    match explicit_derive_request(ut, trait_name) {
        some(request) => some(request.attribute),
        none => none
    }
}

fn implicit_derive_provider(ut: UserType) -> ImplProviderRef {
    ut.provider_plan.implicit_provider_ref
}

fn explicit_derive_request(
    ut: UserType, trait_name: Str
) -> ExplicitDerivedProviderPlan? {
    if ut.provider_plan.explicit_providers.len() != ut.derive_attrs.len() {
        panic("derive provider plan: explicit attribute arity changed")
    }
    for index in 0..ut.provider_plan.explicit_providers.len() {
        match (ut.provider_plan.explicit_providers.get(index),
               ut.derive_attrs.get(index)) {
            (some(request), some(attribute)) => {
                if request.attribute.trait_name != attribute.trait_name ||
                   request.attribute.span.file != attribute.span.file ||
                   request.attribute.span.start.offset !=
                        attribute.span.start.offset ||
                   request.attribute.span.end.offset != attribute.span.end.offset {
                    panic("derive provider plan: explicit attribute changed")
                }
                if attribute.trait_name == trait_name {
                    return some(request)
                }
            },
            _ => panic("derive provider plan: explicit attribute is missing")
        }
    }
    none
}

// Json is deliberately opt-in. Unlike the historical auto-derived traits,
// only an explicit @derive(Json) declaration enters this fixpoint.
fn derive_json_trait(
    mut env: TypeEnv, mut sink: CollectingSink,
    all_types: List<UserType>, mut derived_impls: List<DerivedImpl>
) {
    for ut in all_types {
        for request in ut.provider_plan.explicit_providers {
            let attr = request.attribute
            if attr.trait_name != "Json" {
                let requested = attr.trait_name
                let detail = "unsupported explicit derive trait '${requested}'"
                sink.report(make_diag(E0503, Severity::SevError,
                    "@derive currently supports Json; '${requested}' is not an explicit derive target",
                    attr.span, DiagnosticContext::TraitError { detail: detail }))
            }
        }
    }

    // Json is a two-phase derive.  First solve every explicit candidate's
    // ordered runtime predicates as a least fixed point.  Candidate references
    // consult the current plan, so mutually-recursive SCCs grow together rather
    // than waiting for one member to become "known" first.  Manual impls are
    // always read through their authoritative frozen ImplEntry predicates.
    let mut candidates: List<UserType> = []
    let mut candidate_names: Set<Str> = set_new()
    let mut plans: Map<Str, List<DerivedPredicatePlan>> = map_new()
    for ut in all_types {
        if requests_derive(ut, "Json") && !has_manual_impl(env, ut.name, "Json") {
            candidates.push(ut)
            candidate_names.insert(ut.name)
            let empty: List<DerivedPredicatePlan> = []
            plans.insert(ut.name, empty)
        }
    }

    let mut invalid: Set<Str> = set_new()
    // Every successful changed round either invalidates a candidate or appends
    // at least one previously unseen (type-param, trait) pair. This finite cap
    // is an internal guard against accidental non-monotonic SCC regressions.
    let trait_count = env.trait_reg.traits.len()
    let mut max_rounds = 2 + candidates.len()
    for ut in candidates {
        max_rounds = max_rounds + user_type_param_count(ut) * (trait_count + 1)
    }
    let mut rounds = 0
    let mut changed = true
    while changed {
        rounds = rounds + 1
        if rounds > max_rounds {
            panic("Json derive evidence fixed point did not terminate")
        }
        changed = false
        for ut in candidates {
            if !invalid.contains(ut.name) {
                match plan_json_bounds_for_user_type(
                    env, ut, candidate_names, invalid, plans
                ) {
                    none => {
                        invalid.insert(ut.name)
                        changed = true
                    },
                    some(next) => {
                        // Monotonic union preserves the first-discovery order.
                        // Never replace a plan: SCC peers may expose the same
                        // finite predicate set in a different traversal order.
                        let mut merged: List<DerivedPredicatePlan> = []
                        match plans.get(ut.name) {
                            some(previous) => {
                                for bound in previous { merged.push(bound) }
                            },
                            none => {}
                        }
                        let before = merged.len()
                        for bound in next {
                            push_impl_dict_bound(
                                merged, bound.type_param_index, bound.trait_name)
                        }
                        if merged.len() != before {
                            plans.insert(ut.name, merged)
                            changed = true
                        }
                    }
                }
            }
        }
    }

    // Register the complete valid set before producing any body actions.  A
    // recursive member can therefore resolve every peer via find_impl exactly
    // like ordinary inference does; no provisional/builtin dictionary exists.
    for ut in candidates {
        if !invalid.contains(ut.name) {
            let plan = match plans.get(ut.name) {
                some(bounds) => bounds,
                none => []
            }
            let provider_ref = explicit_derive_request(
                ut, "Json").unwrap().provider_ref
            let signature = json_derived_signature(
                env, ut, plan, provider_ref)
            match signature {
                some(di) => {
                    let attr_span = match derive_attribute(ut, "Json") {
                        some(attr) => attr.span,
                        none => span_zero()
                    }
                    let _ = register_derived_impl(
                        env, sink, di, attr_span)
                },
                none => { invalid.insert(ut.name) }
            }
        }
    }

    let mut known: Set<Str> = set_new()
    let mut sorted_impls = env.trait_reg.trait_impls.entries()
    sorted_impls.sort_by(compare_by_first)
    for entry in sorted_impls {
        let (_target, impls) = entry
        for imp in impls {
            match imp.trait_name {
                some(name) => if name == "Json" {
                    known.insert(imp.target_type_name)
                },
                none => {}
            }
        }
    }

    for ut in candidates {
        if !invalid.contains(ut.name) {
            let provider_ref = explicit_derive_request(
                ut, "Json").unwrap().provider_ref
            match try_derive(
                env, ut, "Json", known, provider_ref) {
                some(di) => {
                    let planned = match plans.get(ut.name) {
                        some(found) => found,
                        none => []
                    }
                    let actual = match derived_impl_dict_bounds(di) {
                        some(found) => found,
                        none => panic("Json derive produced an invalid type-parameter bound")
                    }
                    if !same_impl_dict_bound_set(planned, actual) {
                        panic("Json derive evidence set changed after ImplEntry registration")
                    }
                    let registered_owner = match find_impl_by_provider(
                        env.trait_reg, ut.name,
                        some(di.trait_ref), di.provider_ref) {
                        some(found) => found,
                        none => panic("Json derive lost its registered owner")
                    }
                    // Field actions are name-addressed, while the method ABI is
                    // positional. Normalize the emitted ABI back to the exact
                    // first-discovery order already stored in ImplEntry.
                    derived_impls.push(finalize_derived_impl(
                        env, di, registered_owner))
                },
                none => { invalid.insert(ut.name) }
            }
        }
    }

    for ut in candidates {
        if invalid.contains(ut.name) {
            let display = ut.name
            let attr_span = match derive_attribute(ut, "Json") {
                some(attr) => attr.span,
                none => span_zero()
            }
            sink.report(make_diag(E0503, Severity::SevError,
                "Cannot derive Json for '${display}': every field must provide Json evidence",
                attr_span, DiagnosticContext::TraitError {
                    detail: "Json derive field evidence is missing"
                }))
        }
    }
}

fn user_type_param_count(ut: UserType) -> Int {
    match ut.type_kind {
        TypeKind::StructKind => match ut.struct_def {
            some(def) => def.type_params.len(),
            none => 0
        },
        TypeKind::EnumKind => match ut.enum_def {
            some(def) => def.type_params.len(),
            none => 0
        }
    }
}

fn same_impl_dict_bound_set(
    left: List<DerivedPredicatePlan>, right: List<DerivedPredicatePlan>
) -> Bool {
    if left.len() != right.len() { return false }
    for expected in left {
        let found = right.any(fn(actual) {
            actual.type_param_index == expected.type_param_index &&
                actual.trait_name == expected.trait_name
        })
        if !found { return false }
    }
    true
}

fn push_impl_dict_bound(
    mut bounds: List<DerivedPredicatePlan>, type_param_index: Int, trait_name: Str
) {
    let duplicate = bounds.any(fn(bound) {
        bound.type_param_index == type_param_index && bound.trait_name == trait_name
    })
    if !duplicate {
        bounds.push(DerivedPredicatePlan {
            type_param_index: type_param_index,
            trait_name: trait_name
        })
    }
}

fn derive_requirement_assoc_satisfied(
    env: TypeEnv, subject: Type, trait_name: Str,
    constraints: List<ImplAssocPredicate>
) -> Bool {
    if constraints.len() == 0 { return true }
    let mut target_name: Str? = none
    let mut type_args: List<Type> = []
    match subject {
        Type::StructType { name, type_params } => {
            target_name = some(name)
            type_args = type_params
        },
        Type::EnumType { name, type_params } => {
            target_name = some(name)
            type_args = type_params
        },
        _ => return false
    }
    let entry = match target_name {
        some(name) => match find_impl(env.trait_reg, name, trait_name) {
            some(found) => found,
            none => return false
        },
        none => return false
    }
    if entry.type_param_vars.len() != type_args.len() { return false }
    let mut mapping: Map<Int, Type> = map_new()
    for index in 0..entry.type_param_vars.len() {
        match (entry.type_param_vars.get(index), type_args.get(index)) {
            (some(source), some(actual)) => mapping.insert(source, actual),
            _ => return false
        }
    }
    for constraint in constraints {
        match entry.assoc_types.get(impl_assoc_predicate_name(constraint)) {
            some(actual) => if !types_equal(
                impl_assoc_predicate_type(constraint),
                apply_subst_map(mapping, actual)) { return false },
            none => return false
        }
    }
    true
}

fn plan_json_bounds_for_user_type(
    env: TypeEnv, ut: UserType,
    candidate_names: Set<Str>, invalid: Set<Str>,
    plans: Map<Str, List<DerivedPredicatePlan>>
) -> List<DerivedPredicatePlan>? {
    let mut bounds: List<DerivedPredicatePlan> = []
    match ut.type_kind {
        TypeKind::StructKind => match ut.struct_def {
            some(def) => {
                for field in def.fields {
                    if !plan_json_evidence_for_type(
                        env, field.ty, def.type_param_vars, "Json",
                        candidate_names, invalid, plans, bounds
                    ) { return none }
                }
            },
            none => return none
        },
        TypeKind::EnumKind => match ut.enum_def {
            some(def) => {
                for variant in def.variants {
                    for field_ty in variant.fields {
                        if !plan_json_evidence_for_type(
                            env, field_ty, def.type_param_vars, "Json",
                            candidate_names, invalid, plans, bounds
                        ) { return none }
                    }
                }
            },
            none => return none
        }
    }
    some(bounds)
}

fn plan_json_evidence_for_type(
    env: TypeEnv, t: Type, owner_type_param_vars: List<Int>, trait_name: Str,
    candidate_names: Set<Str>, invalid: Set<Str>,
    plans: Map<Str, List<DerivedPredicatePlan>>, mut bounds: List<DerivedPredicatePlan>
) -> Bool {
    match t {
        Type::TypeVar { id, .. } => {
            let param_idx = index_of_int(owner_type_param_vars, id)
            if param_idx < 0 { return false }
            push_impl_dict_bound(bounds, param_idx, trait_name)
            true
        },
        Type::StructType { name, type_params, .. } =>
            plan_json_nominal_evidence(
                env, name, type_params, owner_type_param_vars, trait_name,
                candidate_names, invalid, plans, bounds),
        Type::EnumType { name, type_params, .. } =>
            plan_json_nominal_evidence(
                env, name, type_params, owner_type_param_vars, trait_name,
                candidate_names, invalid, plans, bounds),
        Type::IntType => has_impl(env.trait_reg, "Int", trait_name),
        Type::FloatType => has_impl(env.trait_reg, "Float", trait_name),
        Type::StrType => has_impl(env.trait_reg, "Str", trait_name),
        Type::BoolType => has_impl(env.trait_reg, "Bool", trait_name),
        Type::UnitType => has_impl(env.trait_reg, "Unit", trait_name),
        _ => false
    }
}

fn plan_json_nominal_evidence(
    env: TypeEnv, name: Str, type_args: List<Type>,
    owner_type_param_vars: List<Int>, trait_name: Str,
    candidate_names: Set<Str>, invalid: Set<Str>,
    plans: Map<Str, List<DerivedPredicatePlan>>, mut bounds: List<DerivedPredicatePlan>
) -> Bool {
    if trait_name == "Json" && candidate_names.contains(name) {
        if invalid.contains(name) { return false }
        let candidate_bounds = match plans.get(name) {
            some(found) => found,
            none => return false
        }
        for candidate_bound in candidate_bounds {
            match type_args.get(candidate_bound.type_param_index) {
                some(type_arg) => {
                    if !plan_json_evidence_for_type(
                        env, type_arg, owner_type_param_vars,
                        candidate_bound.trait_name,
                        candidate_names, invalid, plans, bounds
                    ) { return false }
                },
                none => return false
            }
        }
        return true
    }

    match find_impl(env.trait_reg, name, trait_name) {
        none => false,
        some(impl_entry) => match instantiate_impl_runtime_requirements(
            impl_entry, type_args
        ) {
            none => false,
            some(requirements) => {
                for requirement in requirements {
                    if !derive_requirement_assoc_satisfied(
                        env, requirement.subject_type,
                        requirement.canonical_trait_name,
                        requirement.assoc_constraints) {
                        return false
                    }
                    if !plan_json_evidence_for_type(
                        env, requirement.subject_type, owner_type_param_vars,
                        requirement.canonical_trait_name,
                        candidate_names, invalid, plans, bounds
                    ) { return false }
                }
                true
            }
        }
    }
}

fn registered_derive_trait_ref(
    env: TypeEnv, trait_name: Str
) -> SymbolRef {
    match env.trait_reg.traits.get(trait_name) {
        some(def) => registered_trait_ref_symbol(def.owner_ref),
        none => panic("derive impl provider: trait is not registered")
    }
}

fn json_derived_signature(
    env: TypeEnv, ut: UserType,
    impl_bounds: List<DerivedPredicatePlan>,
    provider_ref: ImplProviderRef
) -> DerivedImplDraft? {
    let type_params = match ut.type_kind {
        TypeKind::StructKind => match ut.struct_def {
            some(def) => def.type_params,
            none => return none
        },
        TypeKind::EnumKind => match ut.enum_def {
            some(def) => def.type_params,
            none => return none
        }
    }
    let type_param_vars = match ut.type_kind {
        TypeKind::StructKind => match ut.struct_def {
            some(def) => def.type_param_vars,
            none => return none
        },
        TypeKind::EnumKind => match ut.enum_def {
            some(def) => def.type_param_vars,
            none => return none
        }
    }
    let mut bounds: List<TraitBound> = []
    for impl_bound in impl_bounds {
        match type_params.get(impl_bound.type_param_index) {
            some(type_param) => bounds.push(TraitBound {
                type_param: type_param,
                type_var_id: type_param_vars.get(
                    impl_bound.type_param_index).unwrap_or_else(fn() {
                        panic("Json derive bound variable is absent")
                    }),
                trait_name: impl_bound.trait_name,
                trait_ref: registered_derive_trait_ref(
                    env, impl_bound.trait_name),
                dict_ordinal: bounds.len()
            }),
            none => return none
        }
    }
    some(DerivedImplDraft {
        provider_ref: provider_ref,
        trait_ref: registered_derive_trait_ref(env, "Json"),
        type_name: ut.name,
        trait_name: "Json",
        type_params: type_params,
        bounds: bounds,
        type_kind: ut.type_kind,
        struct_fields: none,
        enum_variants: none
    })
}

fn derived_impl_dict_bounds(di: DerivedImplDraft) -> List<DerivedPredicatePlan>? {
    let mut result: List<DerivedPredicatePlan> = []
    for bound in di.bounds {
        let param_idx = index_of_str(di.type_params, bound.type_param)
        if param_idx < 0 { return none }
        result.push(DerivedPredicatePlan {
            type_param_index: param_idx,
            trait_name: bound.trait_name
        })
    }
    some(result)
}

fn string_lists_same(left: List<Str>, right: List<Str>) -> Bool {
    if left.len() != right.len() { return false }
    for index in 0..left.len() {
        if left.get(index).unwrap_or("") !=
           right.get(index).unwrap_or("") {
            return false
        }
    }
    true
}

fn derived_h_type_params(
    env: TypeEnv, owner: ImplEntry
) -> List<HTypeParam> {
    if owner.type_params.len() != owner.type_param_vars.len() {
        panic("derived impl type parameters: owner arity differs")
    }
    let predicates = frozen_impl_predicates(owner.predicates)
    let mut result: List<HTypeParam> = []
    for index in 0..owner.type_params.len() {
        let name = owner.type_params.get(index).unwrap()
        let type_var_id = owner.type_param_vars.get(index).unwrap()
        let mut source_bounds: List<TypeBound> = []
        let mut bound_refs: List<SymbolRef> = []
        for predicate in predicates {
            if impl_predicate_subject_param_index(predicate) == index {
                if impl_predicate_subject_type_var(predicate) != type_var_id {
                    panic("derived impl type parameter: predicate variable differs")
                }
                let trait_name = impl_predicate_trait_name(predicate)
                source_bounds.push(TypeBound {
                    trait_name: trait_name, type_args: [],
                    assoc_constraints: [], span: span_zero()
                })
                bound_refs.push(registered_derive_trait_ref(env, trait_name))
            }
        }
        result.push(HTypeParam {
            source: TypeParam {
                name: name, bounds: source_bounds, span: span_zero()
            },
            type_var_id: type_var_id,
            bound_refs: bound_refs
        })
    }
    result
}

fn derived_h_type_params_same(
    left: List<HTypeParam>, right: List<HTypeParam>
) -> Bool {
    if left.len() != right.len() { return false }
    for index in 0..left.len() {
        let expected = left.get(index).unwrap()
        let actual = right.get(index).unwrap()
        if expected.source.name != actual.source.name ||
           expected.type_var_id != actual.type_var_id ||
           expected.source.bounds.len() != actual.source.bounds.len() ||
           expected.bound_refs.len() != actual.bound_refs.len() {
            return false
        }
        for bound_index in 0..expected.bound_refs.len() {
            if expected.source.bounds.get(bound_index).unwrap().trait_name !=
                   actual.source.bounds.get(bound_index).unwrap().trait_name ||
               !symbol_ref_same(
                    expected.bound_refs.get(bound_index).unwrap(),
                    actual.bound_refs.get(bound_index).unwrap()) {
                return false
            }
        }
    }
    true
}

fn trait_bounds_same(
    left: List<TraitBound>, right: List<TraitBound>
) -> Bool {
    if left.len() != right.len() { return false }
    for index in 0..left.len() {
        match (left.get(index), right.get(index)) {
            (some(a), some(b)) => if a.type_param != b.type_param ||
                                      a.type_var_id != b.type_var_id ||
                                      a.trait_name != b.trait_name ||
                                      !symbol_ref_same(
                                        a.trait_ref, b.trait_ref) {
                return false
            },
            _ => return false
        }
    }
    true
}

fn derived_target_owner(
    env: TypeEnv, kind: TypeKind, type_name: Str
) -> RegisteredNominalRef {
    match kind {
        TypeKind::StructKind => match env.types.structs.get(type_name) {
            some(def) => def.owner_ref,
            none => panic("derived impl descriptor lost struct owner")
        },
        TypeKind::EnumKind => match env.types.enums.get(type_name) {
            some(def) => def.owner_ref,
            none => panic("derived impl descriptor lost enum owner")
        }
    }
}

fn derived_target_type(owner: ImplEntry, kind: TypeKind) -> Type {
    let mut type_args: List<Type> = []
    for type_var in owner.type_param_vars {
        type_args.push(Type::TypeVar { id: type_var, name: none })
    }
    match kind {
        TypeKind::StructKind => Type::StructType {
            name: owner.target_type_name, type_params: type_args },
        TypeKind::EnumKind => Type::EnumType {
            name: owner.target_type_name, type_params: type_args }
    }
}

fn exact_derived_methods(
    mut env: TypeEnv, owner: ImplEntry, trait_name: Str
) -> List<DerivedMethod> {
    let mut result: List<DerivedMethod> = []
    for method_name in get_method_names(trait_name) {
        let method_ref = owner.method_refs.get(method_name).unwrap_or_else(fn() {
            panic("derived impl descriptor lost exact method")
        })
        let core = owner.method_schemes.get(method_name).unwrap_or_else(fn() {
            panic("derived impl descriptor lost method signature")
        })
        let executable = make_named_executable_ref(
            impl_method_ref_member(method_ref))
        let signature = impl_method_core_type(core)
        let parameter_types = match signature {
            Type::FnType { params, .. } => params,
            _ => panic("derived impl descriptor method is not callable")
        }
        let symbol = executable_ref_named_symbol(executable)
        let mut binders: List<BinderEntry> = []
        for index in 0..parameter_types.len() {
            let def_id = env.fresh_def_id()
            binders.push(make_source_binder_entry(
                make_source_slot_ref(
                    symbol_ref_origin_module_key(symbol),
                    slot_domain_lexical(), def_id),
                executable, binder_kind_source_param(),
                make_path_ref(
                    path_owner_for_symbol(symbol),
                    ["derived-parameter:${index.to_str()}"],
                    path_role_parameter())))
        }
        result.push(DerivedMethod {
            semantic_kind: derived_impl_semantic_kind(trait_name),
            method_ref: method_ref,
            executable_ref: executable,
            signature: signature,
            binders: binders,
            effect_ctx: make_typed_callable_effect_ctx(
                make_effect_ctx_parameter_ref(executable),
                empty_typed_effect_ctx_layout())
        })
    }
    result
}

fn derived_ord_executable(methods: List<DerivedMethod>) -> ExecutableRef? {
    let mut found: ExecutableRef? = none
    for method in methods {
        if derived_semantic_kind_tag(method.semantic_kind) == 3 {
            if found.is_some() {
                panic("derived Ord descriptor repeats executable")
            }
            found = some(method.executable_ref)
        }
    }
    found
}

fn derived_hash_mix_call() -> DerivedDirectCall {
    let signature = Type::FnType {
        params: [INT, INT], return_type: INT, effects: EMPTY_ROW }
    let symbol = builtin_value_symbol(builtin_value_site_from_tag(
        BUILTIN_VALUE_HASH_COMBINE))
    DerivedDirectCall {
        plan: make_h_exact_call_plan(
            make_named_callee_ref(symbol), signature, none, [],
            make_empty_effect_ctx_source())
    }
}

fn derived_type_mapping(
    env: TypeEnv, kind: TypeKind, type_name: Str,
    owner_type_vars: List<Int>
) -> Map<Int, Type> {
    let source_vars = match kind {
        TypeKind::StructKind => match env.types.structs.get(type_name) {
            some(def) => def.type_param_vars,
            none => panic("derived impl descriptor lost struct type variables")
        },
        TypeKind::EnumKind => match env.types.enums.get(type_name) {
            some(def) => def.type_param_vars,
            none => panic("derived impl descriptor lost enum type variables")
        }
    }
    if source_vars.len() != owner_type_vars.len() {
        panic("derived impl descriptor type-variable arity differs")
    }
    let mut mapping: Map<Int, Type> = map_new()
    for index in 0..source_vars.len() {
        mapping.insert(source_vars.get(index).unwrap(),
            Type::TypeVar {
                id: owner_type_vars.get(index).unwrap(), name: none })
    }
    mapping
}

fn remap_derived_method_call(
    value: MethodCallRef, mapping: Map<Int, Type>
) -> MethodCallRef {
    let signature = apply_subst_map(
        mapping, method_call_ref_signature(value))
    if method_call_ref_is_intrinsic(value) {
        make_intrinsic_method_call_ref(
            method_call_ref_intrinsic(value), signature)
    } else if method_call_ref_is_concrete(value) {
        make_concrete_method_call_ref(
            method_call_ref_impl(value), signature,
            method_call_ref_receiver_mutable(value))
    } else {
        make_bound_method_call_ref(
            method_call_ref_bound(value),
            method_call_ref_bound_evidence(value), signature,
            method_call_ref_receiver_mutable(value))
    }
}

fn remap_derived_action(
    value: FieldAction, mapping: Map<Int, Type>
) -> FieldAction {
    match value {
        FieldAction::Call { method_ref, base_dict, extra_dicts } =>
            FieldAction::Call {
                method_ref: remap_derived_method_call(method_ref, mapping),
                base_dict: base_dict, extra_dicts: extra_dicts },
        FieldAction::Tuple {
            element_types, element_projections, element_actions
        } => {
            let mut result: List<FieldAction> = []
            for action in element_actions {
                result.push(remap_derived_action(action, mapping))
            }
            FieldAction::Tuple {
                element_types: element_types.map(fn(ty) {
                    apply_subst_map(mapping, ty) }),
                element_projections: element_projections,
                element_actions: result }
        },
        _ => value
    }
}

fn derived_action_call_leaf_count(value: FieldAction) -> Int {
    match value {
        FieldAction::Call { .. } => 1,
        FieldAction::Tuple { element_actions, .. } => {
            let mut result = 0
            for action in element_actions {
                result = result + derived_action_call_leaf_count(action)
            }
            result
        },
        _ => 0
    }
}

fn append_derived_ord_result_binders(
    mut env: TypeEnv, value: FieldAction, executable: ExecutableRef,
    mut ordinal: List<Int>, mut result: List<BinderEntry>
) {
    match value {
        FieldAction::Call { .. } => {
            let index = match ordinal.get(0) {
                some(value) => value,
                none => panic("derived Ord binder ordinal is absent")
            }
            let def_id = env.fresh_def_id()
            let symbol = executable_ref_named_symbol(executable)
            result.push(make_source_binder_entry(
                make_source_slot_ref(
                    symbol_ref_origin_module_key(symbol),
                    slot_domain_lexical(), def_id),
                executable, binder_kind_match_pattern(),
                make_path_ref(
                    path_owner_for_symbol(symbol),
                    ["derived-ord-result:${index.to_str()}"],
                    path_role_declaration())))
            ordinal.set(0, index + 1)
        },
        FieldAction::Tuple { element_actions, .. } => {
            for action in element_actions {
                append_derived_ord_result_binders(
                    env, action, executable, ordinal, result)
            }
        },
        _ => {}
    }
}

fn finalize_derived_field(
    mut env: TypeEnv, field: DerivedField,
    ord_executable: ExecutableRef?, mut ordinal: List<Int>,
    type_mapping: Map<Int, Type>
) -> DerivedField {
    let action = remap_derived_action(field.action, type_mapping)
    let mut binders: List<BinderEntry> = []
    match ord_executable {
        some(executable) => append_derived_ord_result_binders(
            env, action, executable, ordinal, binders),
        none => {}
    }
    let expected = match ord_executable {
        some(_) => derived_action_call_leaf_count(action),
        none => 0
    }
    if binders.len() != expected {
        panic("derived Ord binder/Call-leaf census differs")
    }
    DerivedField {
        name: field.name, positional_index: field.positional_index,
        field_ref: field.field_ref,
        ty: apply_subst_map(type_mapping, field.ty),
        action: action,
        ord_result_binders: binders
    }
}

fn validate_derived_ord_field_binders(
    field: DerivedField, ord_executable: ExecutableRef?,
    mut seen: List<BinderEntry>
) {
    let expected = match ord_executable {
        some(_) => derived_action_call_leaf_count(field.action),
        none => 0
    }
    if field.ord_result_binders.len() != expected {
        panic("derived Ord binder/Call-leaf census changed")
    }
    for entry in field.ord_result_binders {
        let executable = match ord_executable {
            some(value) => value,
            none => panic("non-Ord derived field carries result binder")
        }
        if !executable_ref_same(binder_entry_owner(entry), executable) ||
           binder_kind_tag(binder_entry_kind(entry)) !=
                binder_kind_tag(binder_kind_match_pattern()) {
            panic("derived Ord result binder owner/kind differs")
        }
        let _ = make_source_binder_entry(
            binder_entry_slot(entry), executable, binder_entry_kind(entry),
            binder_entry_site(entry))
        for existing in seen {
            if slot_ref_same(
                    binder_entry_slot(existing), binder_entry_slot(entry)) ||
               path_ref_same(
                    binder_entry_site(existing), binder_entry_site(entry)) {
                panic("derived Ord result binder identity is duplicated")
            }
        }
        seen.push(entry)
    }
}

fn finalize_derived_impl(
    mut env: TypeEnv, di: DerivedImplDraft, owner: ImplEntry
) -> DerivedImpl {
    let owner_provider = match owner.provider_ref {
        some(provider) => provider,
        none => panic("derived impl descriptor owner lost provider")
    }
    let owner_trait = match owner.trait_ref {
        some(trait_ref) => trait_ref,
        none => panic("derived impl descriptor owner lost trait")
    }
    let owner_trait_name = match owner.trait_name {
        some(name) => name,
        none => panic("derived impl descriptor owner lost trait name")
    }
    if owner.target_type_name != di.type_name ||
       owner_trait_name != di.trait_name ||
       !impl_provider_ref_same(owner_provider, di.provider_ref) ||
       !symbol_ref_same(owner_trait, di.trait_ref) ||
       !string_lists_same(owner.type_params, di.type_params) {
        panic("derived impl descriptor changed exact owner")
    }
    let bounds = derived_runtime_bounds_from_owner(env, owner)
    let exact_owner = match owner.owner_ref {
        some(value) => value,
        none => panic("derived impl descriptor owner lacks typed identity")
    }
    let methods = exact_derived_methods(env, owner, di.trait_name)
    let type_mapping = derived_type_mapping(
        env, di.type_kind, di.type_name, owner.type_param_vars)
    let ord_executable = if di.trait_name == "Ord" {
        match derived_ord_executable(methods) {
            some(value) => some(value),
            none => panic("derived Ord descriptor lost cmp executable")
        }
    } else { none }
    let mut ordinal: List<Int> = [0]
    let final_struct_fields = match di.struct_fields {
        some(fields) => {
            let mut result: List<DerivedField> = []
            for field in fields {
                result.push(finalize_derived_field(
                    env, field, ord_executable, ordinal, type_mapping))
            }
            some(result)
        },
        none => none
    }
    let final_variants = match di.enum_variants {
        some(variants) => {
            let mut result: List<DerivedVariant> = []
            for variant in variants {
                let mut fields: List<DerivedField> = []
                for field in variant.fields {
                    fields.push(finalize_derived_field(
                        env, field, ord_executable, ordinal, type_mapping))
                }
                result.push(DerivedVariant {
                    name: variant.name, variant_ref: variant.variant_ref,
                    discriminator: variant.discriminator, fields: fields,
                    has_named_fields: variant.has_named_fields })
            }
            some(result)
        },
        none => none
    }
    let mut ord_binders: List<BinderEntry> = []
    match final_struct_fields {
        some(fields) => {
            for field in fields {
                validate_derived_ord_field_binders(
                    field, ord_executable, ord_binders)
            }
        },
        none => {}
    }
    match final_variants {
        some(variants) => {
            for variant in variants {
                for field in variant.fields {
                    validate_derived_ord_field_binders(
                        field, ord_executable, ord_binders)
                }
            }
        },
        none => {}
    }
    let produced_ord_binders = match ordinal.get(0) {
        some(value) => value,
        none => panic("derived Ord binder ordinal is absent")
    }
    if produced_ord_binders != ord_binders.len() {
        panic("derived Ord binder production is not exhaustive")
    }
    DerivedImpl {
        semantic_kind: derived_impl_semantic_kind(di.trait_name),
        owner_ref: exact_owner,
        provider_ref: owner_provider,
        trait_ref: owner_trait,
        target_owner: derived_target_owner(env, di.type_kind, di.type_name),
        target_type: derived_target_type(owner, di.type_kind),
        methods: methods,
        hash_mix: if di.trait_name == "Hash" {
            some(derived_hash_mix_call())
        } else { none },
        text_plan: none,
        type_name: di.type_name,
        trait_name: di.trait_name,
        type_params: derived_h_type_params(env, owner),
        bounds: bounds,
        type_kind: di.type_kind,
        struct_fields: final_struct_fields,
        enum_variants: final_variants
    }
}

fn derived_runtime_bounds_from_owner(
    env: TypeEnv, owner: ImplEntry
) -> List<TraitBound> {
    let mut bounds: List<TraitBound> = []
    for predicate in frozen_impl_predicates(owner.predicates) {
        let param_name = owner.type_params.get(
            impl_predicate_subject_param_index(predicate)).unwrap_or("")
        if param_name == "" {
            panic("derived impl owner lost runtime predicate parameter")
        }
        bounds.push(TraitBound {
            type_param: param_name,
            type_var_id: impl_predicate_subject_type_var(predicate),
            trait_name: impl_predicate_trait_name(predicate),
            trait_ref: registered_derive_trait_ref(
                env, impl_predicate_trait_name(predicate)),
            dict_ordinal: bounds.len()
        })
    }
    bounds
}

fn push_derived_literal(mut pieces: List<DerivedTextPiece>, value: Str) {
    if value != "" {
        pieces.push(DerivedTextPiece::DerivedLiteralText(value))
    }
}

fn push_derived_rendered_field(
    mut pieces: List<DerivedTextPiece>, field: DerivedField
) {
    match field.action {
        FieldAction::FnLiteral => pieces.push(
            DerivedTextPiece::DerivedFieldLiteralText {
                field: field.field_ref, value: "<fn>"
            }),
        _ => pieces.push(
            DerivedTextPiece::DerivedFieldText(field.field_ref))
    }
}

fn derived_struct_text_sequence(
    di: DerivedImpl, fields: List<DerivedField>
) -> DerivedTextSequence {
    let mut pieces: List<DerivedTextPiece> = []
    if di.trait_name == "Debug" {
        if fields.len() == 0 {
            push_derived_literal(pieces, di.type_name)
        } else {
            push_derived_literal(pieces, "${di.type_name} { ")
            let mut index = 0
            for field in fields {
                if index > 0 { push_derived_literal(pieces, ", ") }
                push_derived_literal(pieces, "${field.name}: ")
                push_derived_rendered_field(pieces, field)
                index = index + 1
            }
            push_derived_literal(pieces, " }")
        }
    } else if di.trait_name == "Json" {
        push_derived_literal(pieces, "{")
        let mut index = 0
        for field in fields {
            let prefix = if index == 0 { "" } else { "," }
            push_derived_literal(pieces, "${prefix}\"${field.name}\":")
            push_derived_rendered_field(pieces, field)
            index = index + 1
        }
        push_derived_literal(pieces, "}")
    } else {
        panic("derived text sequence: unsupported trait")
    }
    DerivedTextSequence { pieces: pieces }
}

fn derived_variant_text_sequence(
    di: DerivedImpl, variant: DerivedVariant
) -> DerivedTextSequence {
    let mut pieces: List<DerivedTextPiece> = []
    if di.trait_name == "Debug" {
        if variant.fields.len() == 0 {
            push_derived_literal(pieces, variant.name)
        } else {
            let open = if variant.has_named_fields { " { " } else { "(" }
            push_derived_literal(pieces, "${variant.name}${open}")
            let mut index = 0
            for field in variant.fields {
                if index > 0 { push_derived_literal(pieces, ", ") }
                if variant.has_named_fields {
                    push_derived_literal(pieces, "${field.name}: ")
                }
                push_derived_rendered_field(pieces, field)
                index = index + 1
            }
            push_derived_literal(
                pieces, if variant.has_named_fields { " }" } else { ")" })
        }
    } else if di.trait_name == "Json" {
        push_derived_literal(
            pieces, "{\"_tag\":\"${variant.name}\"")
        for field in variant.fields {
            push_derived_literal(pieces, ",\"${field.name}\":")
            push_derived_rendered_field(pieces, field)
        }
        push_derived_literal(pieces, "}")
    } else {
        panic("derived text variant: unsupported trait")
    }
    DerivedTextSequence { pieces: pieces }
}

fn derived_text_method(di: DerivedImpl) -> DerivedMethod {
    let expected = derived_primary_method_name(di.trait_name)
    for method in di.methods {
        if impl_method_ref_name(method.method_ref) == expected {
            return method
        }
    }
    panic("derived text plan: exact method is absent")
}

fn derived_text_binder(
    mut env: TypeEnv, executable: ExecutableRef
) -> BinderEntry {
    let def_id = env.fresh_def_id()
    let symbol = executable_ref_named_symbol(executable)
    make_source_binder_entry(
        make_source_slot_ref(
            symbol_ref_origin_module_key(symbol),
            slot_domain_lexical(), def_id),
        executable, binder_kind_let(),
        make_path_ref(path_owner_for_symbol(symbol),
            ["derived-text-builder"], path_role_declaration()))
}

fn exact_derived_text_plan(mut ctx: InferCtx, di: DerivedImpl) -> DerivedTextPlan {
    let method = derived_text_method(di)
    let builder_scheme = ctx.env.lookup("string_builder").unwrap_or_else(fn() {
        panic("derived text plan: string builder function is absent")
    })
    let builder_def_id = match builder_scheme.def_id {
        some(value) => value,
        none => panic("derived text plan: string builder DefId is absent")
    }
    let builder = make_h_exact_call_plan(
        make_named_callee_ref(value_symbol_ref(ctx, builder_def_id)),
        builder_scheme.ty, none, [], make_empty_effect_ctx_source())
    let append_method = exact_nominal_method_call(
        ctx, "StringBuilder", "add")
    let finish_method = exact_nominal_method_call(
        ctx, "StringBuilder", "to_str")
    let append = make_h_exact_call_plan(
        method_call_ref_callee_identity(append_method),
        method_call_ref_signature(append_method), some(append_method), [],
        make_empty_effect_ctx_source())
    let finish = make_h_exact_call_plan(
        method_call_ref_callee_identity(finish_method),
        method_call_ref_signature(finish_method), some(finish_method), [],
        make_empty_effect_ctx_source())
    let struct_sequence = match di.struct_fields {
        some(fields) => some(derived_struct_text_sequence(di, fields)),
        none => none
    }
    let variants = match di.enum_variants {
        some(values) => {
            let mut result: List<DerivedTextVariant> = []
            for variant in values {
                result.push(DerivedTextVariant {
                    variant_ref: variant.variant_ref,
                    sequence: derived_variant_text_sequence(di, variant) })
            }
            some(result)
        },
        none => none
    }
    if struct_sequence.is_some() == variants.is_some() {
        panic("derived text plan: shape presence is ambiguous")
    }
    DerivedTextPlan {
        builder_binder: derived_text_binder(ctx.env, method.executable_ref),
        builder: builder,
        append: append, finish: finish,
        struct_sequence: struct_sequence, variants: variants
    }
}

fn with_derived_text_plan(
    di: DerivedImpl, plan: DerivedTextPlan?
) -> DerivedImpl {
    DerivedImpl {
        semantic_kind: di.semantic_kind,
        owner_ref: di.owner_ref, provider_ref: di.provider_ref,
        trait_ref: di.trait_ref, target_owner: di.target_owner,
        target_type: di.target_type, methods: di.methods,
        hash_mix: di.hash_mix,
        text_plan: plan,
        type_name: di.type_name, trait_name: di.trait_name,
        type_params: di.type_params, bounds: di.bounds,
        type_kind: di.type_kind, struct_fields: di.struct_fields,
        enum_variants: di.enum_variants
    }
}

fn close_derived_text_plans(
    mut ctx: InferCtx, values: List<DerivedImpl>
) -> List<DerivedImpl> {
    let mut result: List<DerivedImpl> = []
    for value in values {
        if value.trait_name == "Debug" || value.trait_name == "Json" {
            result.push(with_derived_text_plan(
                value, some(exact_derived_text_plan(ctx, value))))
        } else {
            result.push(with_derived_text_plan(value, none))
        }
    }
    result
}

// ================================================================
// Try to derive a trait for a single type
// ================================================================

fn try_derive(
    env: TypeEnv, ut: UserType, trait_name: Str, known: Set<Str>,
    provider_ref: ImplProviderRef
) -> DerivedImplDraft? {
    let mut bounds: List<TraitBound> = []
    let trait_ref = registered_derive_trait_ref(env, trait_name)
    let planned_refs = derived_impl_method_refs_from_names(
        env, ut.name, provider_ref, trait_ref,
        get_method_names(trait_name))
    let authority = DerivedCallAuthority {
        self_type_name: ut.name,
        self_method: planned_refs.1.get(
            derived_primary_method_name(trait_name))
    }

    match ut.type_kind {
        TypeKind::StructKind => match ut.struct_def {
            some(def) => {
                let field_entries = def.fields.map(fn(f) { FieldEntry {
                    name: f.name,
                    field_ref: DerivedFieldRef::NominalDerivedField(
                        f.field_ref),
                    ty: f.ty } })
                let fields = try_derive_fields(
                    env, field_entries, def.type_param_vars, def.type_params,
                    trait_name, known, ut.name, authority, bounds)
                match fields {
                    some(fs) => some(DerivedImplDraft {
                        provider_ref: provider_ref,
                        trait_ref: trait_ref,
                        type_name: ut.name,
                        trait_name: trait_name,
                        type_params: def.type_params,
                        bounds: bounds,
                        type_kind: TypeKind::StructKind,
                        struct_fields: some(fs),
                        enum_variants: none
                    }),
                    none => none,
                }
            },
            none => none,
        },
        TypeKind::EnumKind => match ut.enum_def {
            some(def) => {
                let mut variants: List<DerivedVariant> = []
                let mut ok = true
                let mut discriminator = 0
                let mut variant_index = 0
                for v in def.variants {
                    if ok {
                        let variant_ref = match def.variant_refs.get(
                                variant_index) {
                            some(value) => value,
                            none => panic(
                                "derive plan: enum variant identity is absent")
                        }
                        let exact_field_refs = match def.variant_field_refs.get(
                                variant_index) {
                            some(value) => value,
                            none => panic(
                                "derive plan: enum field identity inventory is absent")
                        }
                        if exact_field_refs.len() != v.fields.len() {
                            panic("derive plan: enum field identity arity differs")
                        }
                        let has_named_fields = match v.field_names {
                            some(fns) => fns.len() > 0,
                            none => false,
                        }
                        let mut field_entries: List<FieldEntry> = []
                        for i in 0..v.fields.len() {
                            let fname = if has_named_fields {
                                match v.field_names {
                                    some(fns) => str_at(fns, i),
                                    none => "_${i}",
                                }
                            } else {
                                "_${i}"
                            }
                            field_entries.push(FieldEntry {
                                name: fname,
                                field_ref:
                                    DerivedFieldRef::VariantDerivedField(
                                        exact_field_refs.get(i).unwrap()),
                                ty: type_at(v.fields, i) })
                        }
                        let fields = try_derive_fields(
                            env, field_entries, def.type_param_vars,
                            def.type_params, trait_name, known, ut.name,
                            authority, bounds)
                        match fields {
                            some(fs) => {
                                let mut final_fields = fs
                                if has_named_fields == false {
                                    let mut updated: List<DerivedField> = []
                                    for j in 0..fs.len() {
                                        let f = df_at(fs, j)
                                        updated.push(DerivedField {
                                            name: f.name,
                                            positional_index: some(j),
                                            field_ref: f.field_ref, ty: f.ty,
                                            action: f.action,
                                            ord_result_binders:
                                                f.ord_result_binders })
                                    }
                                    final_fields = updated
                                }
                                variants.push(DerivedVariant {
                                    name: v.name,
                                    variant_ref: variant_ref,
                                    discriminator: discriminator,
                                    fields: final_fields,
                                    has_named_fields: has_named_fields
                                })
                            },
                            none => { ok = false },
                        }
                    }
                    discriminator = discriminator + 1
                    variant_index = variant_index + 1
                }
                if ok {
                    some(DerivedImplDraft {
                        provider_ref: provider_ref,
                        trait_ref: trait_ref,
                        type_name: ut.name,
                        trait_name: trait_name,
                        type_params: def.type_params,
                        bounds: bounds,
                        type_kind: TypeKind::EnumKind,
                        struct_fields: none,
                        enum_variants: some(variants)
                    })
                } else {
                    none
                }
            },
            none => none,
        },
    }
}

// ================================================================
// Try to derive fields
// ================================================================

struct FieldEntry {
    name: Str,
    field_ref: DerivedFieldRef,
    ty: Type
}

fn try_derive_fields(
    env: TypeEnv,
    fields: List<FieldEntry>,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    trait_name: Str,
    known: Set<Str>,
    self_type_name: Str, authority: DerivedCallAuthority,
    mut bounds: List<TraitBound>
) -> List<DerivedField>? {
    let mut result: List<DerivedField> = []
    for field in fields {
        let action = resolve_field_action(
            env, field.ty, type_param_vars, type_param_names, trait_name,
            known, self_type_name, authority, bounds)
        match action {
            some(a) => result.push(DerivedField {
                name: field.name, positional_index: none,
                field_ref: field.field_ref, ty: field.ty,
                action: a, ord_result_binders: [] }),
            none => { return none },
        }
    }
    some(result)
}

// ================================================================
// Resolve field action
// ================================================================

fn derived_primary_method_name(trait_name: Str) -> Str {
    match trait_name {
        "Eq" => "eq",
        "Hash" => "hash",
        "Clone" => "clone",
        "Ord" => "cmp",
        "Debug" => "debug",
        "Json" => "to_json",
        _ => panic("derive field plan: unsupported trait")
    }
}

fn derived_impl_semantic_kind(trait_name: Str) -> DerivedSemanticKind {
    match trait_name {
        "Eq" => DerivedSemanticKind::DerivedEqPrimary,
        "Hash" => DerivedSemanticKind::DerivedHash,
        "Clone" => DerivedSemanticKind::DerivedClone,
        "Ord" => DerivedSemanticKind::DerivedOrd,
        "Debug" => DerivedSemanticKind::DerivedDebug,
        "Json" => DerivedSemanticKind::DerivedJson,
        _ => panic("derive semantic kind: unsupported trait")
    }
}

fn derived_actual_type_args(value: Type) -> List<Type> {
    match value {
        Type::StructType { type_params, .. } => type_params,
        Type::EnumType { type_params, .. } => type_params,
        _ => []
    }
}

fn exact_derived_field_method(
    env: TypeEnv, field_type: Type, trait_name: Str,
    evidence: DictRef, authority: DerivedCallAuthority
) -> MethodCallRef? {
    let method_name = derived_primary_method_name(trait_name)
    match field_type {
        Type::TypeVar { .. } => {
            let trait_def = match env.trait_reg.traits.get(trait_name) {
                some(value) => value,
                none => return none
            }
            let method = match trait_def.methods.find(fn(item) {
                item.name == method_name
            }) {
                some(value) => value,
                none => return none
            }
            let mut mapping: Map<Int, Type> = map_new()
            match trait_def.type_param_vars.first() {
                some(self_var) => mapping.insert(self_var, field_type),
                none => return none
            }
            some(make_bound_method_call_ref(
                method.method_ref, evidence,
                apply_subst_map(mapping, method.ty), false))
        },
        _ => {
            let target_name = match type_to_builtin_name(field_type) {
                some(value) => value,
                none => match field_type {
                    Type::StructType { name, .. } => name,
                    Type::EnumType { name, .. } => name,
                    _ => return none
                }
            }
            let owner = find_impl(env.trait_reg, target_name, trait_name)
            match owner {
                none => {
                    if target_name != authority.self_type_name {
                        return none
                    }
                    let method = match authority.self_method {
                        some(value) => value,
                        none => return none
                    }
                    let trait_def = match env.trait_reg.traits.get(trait_name) {
                        some(value) => value,
                        none => return none
                    }
                    let trait_method = match trait_def.methods.find(fn(item) {
                        item.name == method_name
                    }) {
                        some(value) => value,
                        none => return none
                    }
                    let mut self_mapping: Map<Int, Type> = map_new()
                    match trait_def.type_param_vars.first() {
                        some(self_var) => self_mapping.insert(
                            self_var, field_type),
                        none => return none
                    }
                    return some(make_concrete_method_call_ref(
                        method,
                        apply_subst_map(self_mapping, trait_method.ty),
                        false))
                },
                some(_) => {}
            }
            let owner = owner.unwrap()
            let core = match owner.method_schemes.get(method_name) {
                some(value) => value,
                none => return none
            }
            let mut mapping: Map<Int, Type> = map_new()
            let actual_args = derived_actual_type_args(field_type)
            if actual_args.len() != owner.type_param_vars.len() {
                return none
            }
            for index in 0..actual_args.len() {
                mapping.insert(
                    owner.type_param_vars.get(index).unwrap(),
                    actual_args.get(index).unwrap())
            }
            let signature = apply_subst_map(
                mapping, impl_method_core_type(core))
            match owner.method_intrinsics.get(method_name) {
                some(intrinsic) => some(make_intrinsic_method_call_ref(
                    intrinsic, signature)),
                none => match owner.method_refs.get(method_name) {
                    some(method) => some(make_concrete_method_call_ref(
                        method, signature, false)),
                    none => none
                }
            }
        }
    }
}

fn derived_call_action(
    env: TypeEnv, field_type: Type, trait_name: Str,
    base_dict: DictRef, extra_dicts: List<DictRef>,
    authority: DerivedCallAuthority
) -> FieldAction? {
    match exact_derived_field_method(
            env, field_type, trait_name, base_dict, authority) {
        some(method_ref) => some(FieldAction::Call {
            method_ref: method_ref, base_dict: base_dict,
            extra_dicts: extra_dicts }),
        none => none
    }
}

fn resolve_field_action(
    env: TypeEnv,
    field_type: Type,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    trait_name: Str,
    known: Set<Str>,
    self_type_name: Str, authority: DerivedCallAuthority,
    mut bounds: List<TraitBound>
) -> FieldAction? {
    // Hash deliberately goes through trait evidence even for primitives.  This
    // keeps derived code aligned with user-visible `hash()` dispatch and makes
    // the supported primitive set explicit instead of inheriting Eq/Ord's
    // Float/Unit identity shortcuts.
    if trait_name == "Hash" {
        return resolve_hash_field_action(
            env, field_type, type_param_vars, type_param_names,
            known, self_type_name, authority, bounds)
    }
    if trait_name == "Json" {
        return resolve_json_field_action(
            env, field_type, type_param_vars, type_param_names,
            authority, bounds)
    }
    match field_type {
        Type::IntType => derived_call_action(
            env, field_type, trait_name,
            derived_static_dict_ref(env, "Int", trait_name, authority), [],
            authority),
        Type::FloatType => derived_call_action(
            env, field_type, trait_name,
            derived_static_dict_ref(env, "Float", trait_name, authority), [],
            authority),
        Type::StrType => derived_call_action(
            env, field_type, trait_name,
            derived_static_dict_ref(env, "Str", trait_name, authority), [],
            authority),
        Type::BoolType => derived_call_action(
            env, field_type, trait_name,
            derived_static_dict_ref(env, "Bool", trait_name, authority), [],
            authority),
        Type::UnitType => derived_call_action(
            env, field_type, trait_name,
            derived_static_dict_ref(env, "Unit", trait_name, authority), [],
            authority),
        Type::TypeVar { id, .. } => {
            let param_idx = index_of_int(type_param_vars, id)
            if param_idx < 0 { return none }
            let param_name = str_at(type_param_names, param_idx)
            if has_bound(bounds, id,
                    registered_derive_trait_ref(env, trait_name)) == false {
                bounds.push(TraitBound {
                    type_param: param_name, type_var_id: id,
                    trait_name: trait_name,
                    trait_ref: registered_derive_trait_ref(
                        env, trait_name),
                    dict_ordinal: bounds.len() })
            }
            let evidence = derived_bound_dict_ref(
                authority, bounds, id, trait_name)
            derived_call_action(
                env, field_type, trait_name, evidence, [], authority)
        },
        Type::StructType { name, type_params, .. } => {
            if name == self_type_name {
                let extra = resolve_extra_dicts(env, type_params, type_param_vars,
                    type_param_names, trait_name, known, self_type_name,
                    authority, bounds)
                match extra {
                    some(e) => derived_call_action(
                        env, field_type, trait_name,
                        derived_static_dict_ref(
                            env, name, trait_name, authority), e,
                        authority),
                    none => none,
                }
            } else {
                if known.contains(name) {
                    let extra = resolve_extra_dicts(env, type_params,
                        type_param_vars, type_param_names, trait_name,
                        known, self_type_name, authority, bounds)
                    match extra {
                        some(e) => derived_call_action(
                            env, field_type, trait_name,
                            derived_static_dict_ref(
                                env, name, trait_name, authority), e,
                            authority),
                        none => none,
                    }
                } else {
                    none
                }
            }
        },
        Type::EnumType { name, type_params, .. } => {
            if name == self_type_name {
                let extra = resolve_extra_dicts(env, type_params, type_param_vars,
                    type_param_names, trait_name, known, self_type_name,
                    authority, bounds)
                match extra {
                    some(e) => derived_call_action(
                        env, field_type, trait_name,
                        derived_static_dict_ref(
                            env, name, trait_name, authority), e,
                        authority),
                    none => none,
                }
            } else {
                if known.contains(name) {
                    let extra = resolve_extra_dicts(env, type_params,
                        type_param_vars, type_param_names, trait_name,
                        known, self_type_name, authority, bounds)
                    match extra {
                        some(e) => derived_call_action(
                            env, field_type, trait_name,
                            derived_static_dict_ref(
                                env, name, trait_name, authority), e,
                            authority),
                        none => none,
                    }
                } else {
                    none
                }
            }
        },
        Type::TupleType { elements } => {
            let mut elem_actions: List<FieldAction> = []
            let mut elem_types: List<Type> = []
            let mut elem_projections: List<HProjectionRef> = []
            let mut ok = true
            let mut element_index = 0
            for elem_ty in elements {
                if ok {
                    let elem_action = resolve_field_action(
                        env, elem_ty, type_param_vars, type_param_names,
                        trait_name, known, self_type_name, authority, bounds)
                    match elem_action {
                        some(a) => {
                            elem_actions.push(a)
                            elem_types.push(elem_ty)
                            elem_projections.push(
                                h_tuple_projection(element_index))
                        },
                        none => { ok = false },
                    }
                }
                element_index = element_index + 1
            }
            if ok {
                some(FieldAction::Tuple {
                    element_types: elem_types,
                    element_projections: elem_projections,
                    element_actions: elem_actions })
            } else {
                none
            }
        },
        Type::FnType { .. } => {
            if trait_name == "Debug" {
                some(FieldAction::FnLiteral)
            } else {
                none
            }
        },
        Type::ErrorType => some(FieldAction::Identity),
        Type::AnyType | Type::NeverType => none,
        _ => none,
    }
}

fn resolve_json_field_action(
    env: TypeEnv,
    field_type: Type,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    authority: DerivedCallAuthority,
    mut bounds: List<TraitBound>
) -> FieldAction? {
    match resolve_json_dict_ref(
        env, field_type, type_param_vars, type_param_names,
        "Json", authority, bounds
    ) {
        some(value) => if dict_ref_is_simple_physical(value) ||
                dict_ref_is_static_physical(value) {
            derived_call_action(env, field_type, "Json", value, [], authority)
        } else {
            derived_call_action(
                env, field_type, "Json",
                make_static_dict_ref(
                    dict_ref_wrapped_name(value),
                    make_exact_static_dict_ref(
                        dict_ref_wrapped_base(dict_ref_exact(value)))),
                dict_ref_wrapped_physical_inner(value), authority)
        },
        none => none
    }
}

// Derive-side counterpart of infer_ctx.resolve_dict_evidence_for_type.  The
// only local policy is how a surrounding derived impl turns a free type var
// into one of its own bounds; nominal requirements are instantiated by the
// shared env helper from the exact frozen ImplEntry predicate sequence.
fn resolve_json_dict_ref(
    env: TypeEnv, t: Type,
    owner_type_param_vars: List<Int>, owner_type_param_names: List<Str>,
    trait_name: Str, authority: DerivedCallAuthority,
    mut bounds: List<TraitBound>
) -> DictRef? {
    match t {
        Type::TypeVar { id, .. } => {
            let param_idx = index_of_int(owner_type_param_vars, id)
            if param_idx < 0 { return none }
            let param_name = str_at(owner_type_param_names, param_idx)
            if !has_bound(bounds, id,
                    registered_derive_trait_ref(env, trait_name)) {
                bounds.push(TraitBound {
                    type_param: param_name,
                    type_var_id: id,
                    trait_name: trait_name,
                    trait_ref: registered_derive_trait_ref(
                        env, trait_name),
                    dict_ordinal: bounds.len()
                })
            }
            some(derived_bound_dict_ref(
                authority, bounds, id, trait_name))
        },
        Type::StructType { name, type_params, .. } => {
            resolve_json_nominal_dict_ref(
                env, name, type_params, owner_type_param_vars,
                owner_type_param_names, trait_name, authority, bounds)
        },
        Type::EnumType { name, type_params, .. } => {
            resolve_json_nominal_dict_ref(
                env, name, type_params, owner_type_param_vars,
                owner_type_param_names, trait_name, authority, bounds)
        },
        Type::IntType => resolve_json_builtin_dict_ref(
            env, "Int", trait_name, authority),
        Type::FloatType => resolve_json_builtin_dict_ref(
            env, "Float", trait_name, authority),
        Type::StrType => resolve_json_builtin_dict_ref(
            env, "Str", trait_name, authority),
        Type::BoolType => resolve_json_builtin_dict_ref(
            env, "Bool", trait_name, authority),
        Type::UnitType => resolve_json_builtin_dict_ref(
            env, "Unit", trait_name, authority),
        _ => none
    }
}

fn resolve_json_builtin_dict_ref(
    env: TypeEnv, type_name: Str, trait_name: Str,
    authority: DerivedCallAuthority
) -> DictRef? {
    if has_impl(env.trait_reg, type_name, trait_name) {
        some(derived_static_dict_ref(
            env, type_name, trait_name, authority))
    } else {
        none
    }
}

fn resolve_json_nominal_dict_ref(
    env: TypeEnv, name: Str, type_args: List<Type>,
    owner_type_param_vars: List<Int>, owner_type_param_names: List<Str>,
    trait_name: Str, authority: DerivedCallAuthority,
    mut bounds: List<TraitBound>
) -> DictRef? {
    let impl_entry = match find_impl(env.trait_reg, name, trait_name) {
        some(found) => found,
        none => return none
    }
    let requirements = match instantiate_impl_runtime_requirements(
        impl_entry, type_args
    ) {
        some(found) => found,
        none => return none
    }
    if requirements.len() == 0 {
        return some(derived_static_dict_ref(
            env, name, trait_name, authority))
    }
    let mut inner_dicts: List<DictRef> = []
    for requirement in requirements {
        if !derive_requirement_assoc_satisfied(
            env, requirement.subject_type,
            requirement.canonical_trait_name,
            requirement.assoc_constraints) {
            return none
        }
        match resolve_json_dict_ref(
            env, requirement.subject_type, owner_type_param_vars,
            owner_type_param_names,
            requirement.canonical_trait_name, authority, bounds
        ) {
            some(dict_ref) => inner_dicts.push(dict_ref),
            none => return none
        }
    }
    some(derived_wrapped_dict_ref(
        env, name, trait_name, inner_dicts, authority))
}

fn resolve_hash_field_action(
    env: TypeEnv,
    field_type: Type,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    known: Set<Str>,
    self_type_name: Str,
    authority: DerivedCallAuthority,
    mut bounds: List<TraitBound>
) -> FieldAction? {
    match field_type {
        Type::IntType => derived_call_action(
            env, field_type, "Hash",
            derived_static_dict_ref(env, "Int", "Hash", authority),
            [], authority),
        Type::StrType => derived_call_action(
            env, field_type, "Hash",
            derived_static_dict_ref(env, "Str", "Hash", authority),
            [], authority),
        Type::BoolType => derived_call_action(
            env, field_type, "Hash",
            derived_static_dict_ref(env, "Bool", "Hash", authority),
            [], authority),
        Type::TypeVar { id, .. } => {
            let param_idx = index_of_int(type_param_vars, id)
            if param_idx < 0 { return none }
            let param_name = str_at(type_param_names, param_idx)
            if has_bound(bounds, id,
                    registered_derive_trait_ref(env, "Hash")) == false {
                bounds.push(TraitBound {
                    type_param: param_name, type_var_id: id,
                    trait_name: "Hash",
                    trait_ref: registered_derive_trait_ref(env, "Hash"),
                    dict_ordinal: bounds.len() })
            }
            let evidence = derived_bound_dict_ref(
                authority, bounds, id, "Hash")
            derived_call_action(
                env, field_type, "Hash", evidence, [], authority)
        },
        Type::StructType { name, type_params, .. } => {
            if name != self_type_name && known.contains(name) == false {
                return none
            }
            let extra = resolve_extra_dicts(env,
                type_params, type_param_vars, type_param_names,
                "Hash", known, self_type_name, authority, bounds)
            match extra {
                some(e) => derived_call_action(
                    env, field_type, "Hash",
                    derived_static_dict_ref(env, name, "Hash", authority), e,
                    authority),
                none => none,
            }
        },
        Type::EnumType { name, type_params, .. } => {
            if name != self_type_name && known.contains(name) == false {
                return none
            }
            let extra = resolve_extra_dicts(env,
                type_params, type_param_vars, type_param_names,
                "Hash", known, self_type_name, authority, bounds)
            match extra {
                some(e) => derived_call_action(
                    env, field_type, "Hash",
                    derived_static_dict_ref(env, name, "Hash", authority), e,
                    authority),
                none => none,
            }
        },
        Type::TupleType { elements } => {
            let mut elem_actions: List<FieldAction> = []
            let mut elem_types: List<Type> = []
            let mut elem_projections: List<HProjectionRef> = []
            let mut element_index = 0
            for elem_ty in elements {
                let elem_action = resolve_hash_field_action(
                    env, elem_ty, type_param_vars, type_param_names,
                    known, self_type_name, authority, bounds)
                match elem_action {
                    some(a) => {
                        elem_actions.push(a)
                        elem_types.push(elem_ty)
                        elem_projections.push(
                            h_tuple_projection(element_index))
                    },
                    none => { return none },
                }
                element_index = element_index + 1
            }
            some(FieldAction::Tuple {
                element_types: elem_types,
                element_projections: elem_projections,
                element_actions: elem_actions })
        },
        // Hash has no primitive evidence for Float/Unit, and address identity
        // is never a legal structural hash fallback.
        _ => none,
    }
}

// ================================================================
// Resolve extra dicts
// ================================================================

fn resolve_extra_dicts(
    env: TypeEnv,
    type_args: List<Type>,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    trait_name: Str,
    known: Set<Str>,
    self_type_name: Str, authority: DerivedCallAuthority,
    mut bounds: List<TraitBound>
) -> List<DictRef>? {
    let mut dicts: List<DictRef> = []
    for arg in type_args {
        let dict = resolve_type_arg_dict(
            env, arg, type_param_vars, type_param_names,
            trait_name, known, self_type_name, authority, bounds)
        match dict {
            some(d) => dicts.push(d),
            none => { return none },
        }
    }
    some(dicts)
}

fn resolve_type_arg_dict(
    env: TypeEnv,
    arg: Type,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    trait_name: Str,
    known: Set<Str>,
    self_type_name: Str, authority: DerivedCallAuthority,
    mut bounds: List<TraitBound>
) -> DictRef? {
    match arg {
        Type::IntType => some(derived_static_dict_ref(
            env, "Int", trait_name, authority)),
        Type::FloatType => {
            if trait_name == "Hash" {
                none
            } else {
                some(derived_static_dict_ref(
                    env, "Float", trait_name, authority))
            }
        },
        Type::StrType => some(derived_static_dict_ref(
            env, "Str", trait_name, authority)),
        Type::BoolType => some(derived_static_dict_ref(
            env, "Bool", trait_name, authority)),
        Type::UnitType => {
            if trait_name == "Hash" || trait_name == "Json" {
                none
            } else {
                some(derived_static_dict_ref(
                    env, "Unit", trait_name, authority))
            }
        },
        Type::TypeVar { id, .. } => {
            let param_idx = index_of_int(type_param_vars, id)
            if param_idx < 0 { return none }
            let param_name = str_at(type_param_names, param_idx)
            if has_bound(bounds, id,
                    registered_derive_trait_ref(env, trait_name)) == false {
                bounds.push(TraitBound {
                    type_param: param_name, type_var_id: id,
                    trait_name: trait_name,
                    trait_ref: registered_derive_trait_ref(
                        env, trait_name),
                    dict_ordinal: bounds.len() })
            }
            some(derived_bound_dict_ref(
                authority, bounds, id, trait_name))
        },
        Type::StructType { name, type_params, .. } => {
            if name != self_type_name && known.contains(name) == false {
                return none
            }
            if type_params.len() == 0 {
                return some(derived_static_dict_ref(
                    env, name, trait_name, authority))
            }
            let inner = resolve_extra_dicts(env,
                type_params, type_param_vars, type_param_names,
                trait_name, known, self_type_name, authority, bounds)
            match inner {
                some(inner_dicts) => some(derived_wrapped_dict_ref(
                    env, name, trait_name, inner_dicts, authority)),
                none => none,
            }
        },
        Type::EnumType { name, type_params, .. } => {
            if name != self_type_name && known.contains(name) == false {
                return none
            }
            if type_params.len() == 0 {
                return some(derived_static_dict_ref(
                    env, name, trait_name, authority))
            }
            let inner = resolve_extra_dicts(env,
                type_params, type_param_vars, type_param_names,
                trait_name, known, self_type_name, authority, bounds)
            match inner {
                some(inner_dicts) => some(derived_wrapped_dict_ref(
                    env, name, trait_name, inner_dicts, authority)),
                none => none,
            }
        },
        _ => none,
    }
}

// ================================================================
// Register derived impl
// ================================================================

fn derived_impl_method_refs_from_names(
    env: TypeEnv, type_name: Str, provider_ref: ImplProviderRef,
    trait_ref: SymbolRef, method_names: List<Str>
) -> (ImplOwnerRef, Map<Str, ImplMethodRef>) {
    let target_ref = match impl_target_symbol(env, type_name) {
        some(symbol) => symbol,
        none => panic("derive impl owner: exact target symbol is missing")
    }
    let owner_ref = make_impl_owner_ref(
        target_ref, provider_ref, some(trait_ref))
    let provider_path = path_ref_normalized_child_path(
        impl_provider_ref_site(provider_ref)).join("/")
    let trait_key = symbol_ref_stable_key(trait_ref)
    let module_key = module_body_ref_origin_module_key(
        path_owner_ref_module_body(path_ref_owner(
            impl_provider_ref_site(provider_ref))))
    let mut refs: Map<Str, ImplMethodRef> = map_new()
    let mut sorted_names = method_names
    sorted_names.sort()
    let mut callable_slot = 0
    for method_name in sorted_names {
        let member = make_symbol_ref(
            module_key, namespace_member(),
            "derived-impl-member:${provider_path}:${trait_key}:${callable_slot}",
            "provider:${provider_path}|trait:${trait_key}|method:${callable_slot}")
        refs.insert(method_name, make_impl_method_ref(
            owner_ref, member, callable_slot, callable_slot, method_name))
        callable_slot = callable_slot + 1
    }
    (owner_ref, refs)
}

fn derived_impl_method_refs(
    env: TypeEnv, type_name: Str, provider_ref: ImplProviderRef,
    trait_ref: SymbolRef, exact: Map<Str, ImplMethodSchemeCore>
) -> (ImplOwnerRef, Map<Str, ImplMethodRef>) {
    let mut names: List<Str> = []
    for entry in exact.entries() { names.push(entry.0) }
    derived_impl_method_refs_from_names(
        env, type_name, provider_ref, trait_ref, names)
}

fn register_derived_impl(
    mut env: TypeEnv, sink: CollectingSink,
    di: DerivedImplDraft, span: Span
) -> ImplEntry {
    let trait_name = di.trait_name
    let provider_ref = di.provider_ref
    let mut methods: Map<Str, TypeScheme> = map_new()

    let mut type_var_ids: List<Int> = []
    let mut self_type_params: List<Type> = []
    for i in 0..di.type_params.len() {
        let var_id = env.fresh_var_id()
        type_var_ids.push(var_id)
        self_type_params.push(Type::TypeVar { id: var_id, name: none })
    }

    let self_type = build_self_type(env, di.type_name, di.type_kind, self_type_params)

    let mut scheme_bounds: List<SchemeBound> = []
    let mut predicates: List<TypedImplPredicate> = []
    for b in di.bounds {
        let param_idx = index_of_str(di.type_params, b.type_param)
        if param_idx >= 0 {
            let subject_var = int_at(type_var_ids, param_idx)
            scheme_bounds.push(SchemeBound {
                type_var: subject_var,
                trait_name: b.trait_name,
                assoc_constraints: []
            })
            predicates.push(make_typed_impl_predicate(
                param_idx, subject_var, b.trait_name, [],
                direct_impl_predicate_provenance()))
        }
    }
    let frozen_predicates = freeze_impl_predicate_set(
        type_var_ids, predicates)

    let method_names = get_method_names(trait_name)
    register_trait_methods(methods, trait_name, self_type, type_var_ids, scheme_bounds)

    let mut exact: Map<Str, ImplMethodSchemeCore> = map_new()
    for entry in methods.entries() {
        let (method_name, scheme) = entry
        for bound in scheme.bounds {
            let found = predicates.any(fn(predicate) {
                impl_predicate_subject_type_var(predicate) == bound.type_var &&
                    impl_predicate_trait_name(predicate) == bound.trait_name
            })
            if !found || bound.assoc_constraints.len() != 0 {
                panic("derive impl owner: method scheme has non-owner bounds")
            }
        }
        exact.insert(method_name, make_impl_method_scheme_core(
            scheme.ty, scheme.type_vars, scheme.effect_schema,
            scheme.def_id))
    }

    let trait_ref = registered_derive_trait_ref(env, trait_name)
    if !symbol_ref_same(trait_ref, di.trait_ref) {
        panic("derive impl descriptor changed registered trait")
    }
    let identity = derived_impl_method_refs(
        env, di.type_name, provider_ref, trait_ref, exact)
    let owner_ref = identity.0
    let method_refs = identity.1
    let owner = ImplEntry {
        trait_name: some(trait_name),
        target_type_name: di.type_name,
        type_params: di.type_params,
        type_param_vars: type_var_ids,
        predicates: frozen_predicates,
        method_names: method_names,
        assoc_types: map_new(),
        assoc_type_effect_schemas: map_new(),
        method_schemes: exact,
        method_refs: method_refs,
        method_intrinsics: map_new(),
        method_resource_contracts: map_new(),
        provider_ref: some(provider_ref),
        trait_ref: some(trait_ref),
        owner_ref: some(owner_ref),
        span: span
    }
    add_impl(env.trait_reg, owner)

    let mut sorted_methods = exact.entries()
    sorted_methods.sort_by(compare_by_first)
    for entry in sorted_methods {
        let (method_name, core) = entry
        let _ = install_method_core(
            env.trait_reg, sink, di.type_name, method_name, core,
            method_refs.get(method_name).unwrap(), span)
    }
    owner
}

fn get_method_names(trait_name: Str) -> List<Str> {
    match trait_name {
        "Eq" => ["eq"],
        "Clone" => ["clone"],
        "Debug" => ["debug"],
        "Ord" => ["cmp"],
        "Hash" => ["hash"],
        "Json" => ["to_json"],
        _ => [],
    }
}

fn build_self_type(env: TypeEnv, type_name: Str, type_kind: TypeKind, type_params: List<Type>) -> Type {
    match type_kind {
        TypeKind::StructKind => Type::StructType { name: type_name, type_params: type_params },
        TypeKind::EnumKind => Type::EnumType { name: type_name, type_params: type_params },
    }
}

fn register_trait_methods(
    mut methods: Map<Str, TypeScheme>,
    trait_name: Str,
    self_type: Type,
    type_var_ids: List<Int>,
    bounds: List<SchemeBound>
) {
    match trait_name {
        "Eq" => {
            let eq_fn = Type::FnType { params: [self_type, self_type], return_type: BOOL, effects: EMPTY_ROW }
            methods.insert("eq", TypeScheme { ty: eq_fn, type_vars: type_var_ids, bounds: bounds, effect_schema: empty_typed_effect_header_schema(), def_id: none })
        },
        "Clone" => {
            let clone_fn = Type::FnType { params: [self_type], return_type: self_type, effects: EMPTY_ROW }
            methods.insert("clone", TypeScheme { ty: clone_fn, type_vars: type_var_ids, bounds: bounds, effect_schema: empty_typed_effect_header_schema(), def_id: none })
        },
        "Ord" => {
            let cmp_fn = Type::FnType { params: [self_type, self_type], return_type: INT, effects: EMPTY_ROW }
            methods.insert("cmp", TypeScheme { ty: cmp_fn, type_vars: type_var_ids, bounds: bounds, effect_schema: empty_typed_effect_header_schema(), def_id: none })
        },
        "Debug" => {
            let debug_fn = Type::FnType { params: [self_type], return_type: STR, effects: EMPTY_ROW }
            methods.insert("debug", TypeScheme { ty: debug_fn, type_vars: type_var_ids, bounds: bounds, effect_schema: empty_typed_effect_header_schema(), def_id: none })
        },
        "Hash" => {
            let hash_fn = Type::FnType { params: [self_type], return_type: INT, effects: EMPTY_ROW }
            methods.insert("hash", TypeScheme { ty: hash_fn, type_vars: type_var_ids, bounds: bounds, effect_schema: empty_typed_effect_header_schema(), def_id: none })
        },
        "Json" => {
            let json_fn = Type::FnType { params: [self_type], return_type: STR, effects: EMPTY_ROW }
            methods.insert("to_json", TypeScheme { ty: json_fn, type_vars: type_var_ids, bounds: bounds, effect_schema: empty_typed_effect_header_schema(), def_id: none })
        },
        _ => {},
    }
}

// ================================================================
// Helpers
// ================================================================

fn index_of_int(list: List<Int>, target: Int) -> Int {
    for i in 0..list.len() {
        if int_at(list, i) == target { return i }
    }
    0 - 1
}

fn index_of_str(list: List<Str>, target: Str) -> Int {
    for i in 0..list.len() {
        if str_at(list, i) == target { return i }
    }
    0 - 1
}

fn has_bound(
    bounds: List<TraitBound>, type_var_id: Int, trait_ref: SymbolRef
) -> Bool {
    for b in bounds {
        if b.type_var_id == type_var_id &&
           symbol_ref_same(b.trait_ref, trait_ref) {
            return true
        }
    }
    false
}

