use types::{Type, EffectRow, StructField, EnumVariant,
    INT, STR, BOOL, EMPTY_ROW, types_equal}
use env::{TypeEnv, TypeScheme, SchemeBound, StructDef, EnumDef,
    ImplEntry, ImplMethodSchemeCore, ImplAssocPredicate,
    ExplicitDerivedProviderPlan, NominalDerivedProviderPlan,
    TypedImplPredicate, MethodOrigin,
    add_impl, has_impl, find_impl, install_method_core,
    instantiate_impl_runtime_requirements,
    make_impl_method_scheme_core, make_typed_impl_predicate,
    direct_impl_predicate_provenance, freeze_impl_predicate_set,
    impl_predicate_subject_type_var, impl_predicate_trait_name,
    impl_predicate_subject_param_index, frozen_impl_predicates,
    impl_assoc_predicate_name, impl_assoc_predicate_type,
    apply_subst_map,
    ImplOwnerState, delegate_plan_not_applicable}
use ast::{Span, DeriveAttribute, span_zero}
use diagnostics::{CollectingSink, Severity, DiagnosticContext, make_diag}
use codes::{E0503}
use hir::{DerivedImpl, DerivedField, DerivedVariant, FieldAction, DictRef,
    TraitBound, TypeKind, trait_dict_name, trait_bound_param_name, compare_by_first}
use ir_identity::{ImplProviderRef, registered_trait_ref_symbol}

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

const BUILTIN_TYPES: Set<Str> = set_from(["Option", "Cell", "List", "Map", "Set", "Range"])

// ================================================================
// Public entry point
// ================================================================

pub fn run_derive_pass(
    mut env: TypeEnv, sink: CollectingSink
) -> List<DerivedImpl> {
    let mut derived_impls: List<DerivedImpl> = []
    let all_types = collect_user_types(env)
    derive_trait(env, sink, all_types, "Eq", derived_impls)
    // B-107 coherence: only the compiler's structural Eq path may opt a type
    // into structural Hash.  At this point derived_impls contains only this
    // pass's Eq impls, so manual Eq impls already present in trait_reg cannot
    // be mistaken for auto Eq.
    let auto_eq_types = collect_derived_type_names(derived_impls, "Eq")
    derive_hash_trait(env, sink, all_types, auto_eq_types, derived_impls)
    derive_trait(env, sink, all_types, "Clone", derived_impls)
    derive_trait(env, sink, all_types, "Ord", derived_impls)
    derive_trait(env, sink, all_types, "Debug", derived_impls)
    derive_json_trait(env, sink, all_types, derived_impls)
    derived_impls
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
                    let result = try_derive(env, ut, trait_name, known)
                    match result {
                        some(di) => {
                            known.insert(ut.name)
                            let owner = register_derived_impl(
                                env, sink, di, trait_name, span_zero(),
                                implicit_derive_provider(ut))
                            derived_impls.push(derived_impl_with_bounds(
                                di, derived_runtime_bounds_from_owner(owner)))
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
                        let result = try_derive(env, ut, "Hash", known)
                        match result {
                            some(di) => {
                                known.insert(ut.name)
                                let owner = register_derived_impl(
                                    env, sink, di, "Hash", span_zero(),
                                    implicit_derive_provider(ut))
                                derived_impls.push(derived_impl_with_bounds(
                                    di, derived_runtime_bounds_from_owner(owner)))
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
            let signature = json_derived_signature(ut, plan)
            match signature {
                some(di) => {
                    let attr_span = match derive_attribute(ut, "Json") {
                        some(attr) => attr.span,
                        none => span_zero()
                    }
                    let _ = register_derived_impl(
                        env, sink, di, "Json", attr_span,
                        explicit_derive_request(
                            ut, "Json").unwrap().provider_ref)
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
            match try_derive(env, ut, "Json", known) {
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
                    let registered_owner = match find_impl(
                        env.trait_reg, ut.name, "Json") {
                        some(found) => found,
                        none => panic("Json derive lost its registered owner")
                    }
                    // Field actions are name-addressed, while the method ABI is
                    // positional. Normalize the emitted ABI back to the exact
                    // first-discovery order already stored in ImplEntry.
                    derived_impls.push(derived_impl_with_bounds(
                        di, derived_runtime_bounds_from_owner(
                            registered_owner)))
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

fn json_derived_signature(
    ut: UserType, impl_bounds: List<DerivedPredicatePlan>
) -> DerivedImpl? {
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
    let mut bounds: List<TraitBound> = []
    for impl_bound in impl_bounds {
        match type_params.get(impl_bound.type_param_index) {
            some(type_param) => bounds.push(TraitBound {
                type_param: type_param,
                trait_name: impl_bound.trait_name
            }),
            none => return none
        }
    }
    some(DerivedImpl {
        type_name: ut.name,
        trait_name: "Json",
        type_params: type_params,
        bounds: bounds,
        type_kind: ut.type_kind,
        struct_fields: none,
        enum_variants: none
    })
}

fn derived_impl_dict_bounds(di: DerivedImpl) -> List<DerivedPredicatePlan>? {
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

fn derived_impl_with_bounds(
    di: DerivedImpl, bounds: List<TraitBound>
) -> DerivedImpl {
    DerivedImpl {
        type_name: di.type_name,
        trait_name: di.trait_name,
        type_params: di.type_params,
        bounds: bounds,
        type_kind: di.type_kind,
        struct_fields: di.struct_fields,
        enum_variants: di.enum_variants
    }
}

fn derived_runtime_bounds_from_owner(owner: ImplEntry) -> List<TraitBound> {
    let mut bounds: List<TraitBound> = []
    for predicate in frozen_impl_predicates(owner.predicates) {
        let param_name = owner.type_params.get(
            impl_predicate_subject_param_index(predicate)).unwrap_or("")
        if param_name == "" {
            panic("derived impl owner lost runtime predicate parameter")
        }
        bounds.push(TraitBound {
            type_param: param_name,
            trait_name: impl_predicate_trait_name(predicate)
        })
    }
    bounds
}

// ================================================================
// Try to derive a trait for a single type
// ================================================================

fn try_derive(env: TypeEnv, ut: UserType, trait_name: Str, known: Set<Str>) -> DerivedImpl? {
    let mut bounds: List<TraitBound> = []

    match ut.type_kind {
        TypeKind::StructKind => match ut.struct_def {
            some(def) => {
                let field_entries = def.fields.map(fn(f) { FieldEntry { name: f.name, ty: f.ty } })
                let fields = try_derive_fields(env, field_entries, def.type_param_vars, def.type_params, trait_name, known, ut.name, bounds)
                match fields {
                    some(fs) => some(DerivedImpl {
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
                for v in def.variants {
                    if ok {
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
                            field_entries.push(FieldEntry { name: fname, ty: type_at(v.fields, i) })
                        }
                        let fields = try_derive_fields(env, field_entries, def.type_param_vars, def.type_params, trait_name, known, ut.name, bounds)
                        match fields {
                            some(fs) => {
                                let mut final_fields = fs
                                if has_named_fields == false {
                                    let mut updated: List<DerivedField> = []
                                    for j in 0..fs.len() {
                                        let f = df_at(fs, j)
                                        updated.push(DerivedField { name: f.name, positional_index: some(j), action: f.action })
                                    }
                                    final_fields = updated
                                }
                                variants.push(DerivedVariant {
                                    name: v.name,
                                    discriminator: discriminator,
                                    fields: final_fields,
                                    has_named_fields: has_named_fields
                                })
                            },
                            none => { ok = false },
                        }
                    }
                    discriminator = discriminator + 1
                }
                if ok {
                    some(DerivedImpl {
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
    ty: Type
}

fn try_derive_fields(
    env: TypeEnv,
    fields: List<FieldEntry>,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    trait_name: Str,
    known: Set<Str>,
    self_type_name: Str, mut bounds: List<TraitBound>
) -> List<DerivedField>? {
    let mut result: List<DerivedField> = []
    for field in fields {
        let action = resolve_field_action(env, field.ty, type_param_vars, type_param_names, trait_name, known, self_type_name, bounds)
        match action {
            some(a) => result.push(DerivedField { name: field.name, positional_index: none, action: a }),
            none => { return none },
        }
    }
    some(result)
}

// ================================================================
// Resolve field action
// ================================================================

fn resolve_field_action(
    env: TypeEnv,
    field_type: Type,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    trait_name: Str,
    known: Set<Str>,
    self_type_name: Str, mut bounds: List<TraitBound>
) -> FieldAction? {
    // Hash deliberately goes through trait evidence even for primitives.  This
    // keeps derived code aligned with user-visible `hash()` dispatch and makes
    // the supported primitive set explicit instead of inheriting Eq/Ord's
    // Float/Unit identity shortcuts.
    if trait_name == "Hash" {
        return resolve_hash_field_action(
            env, field_type, type_param_vars, type_param_names,
            known, self_type_name, bounds)
    }
    if trait_name == "Json" {
        return resolve_json_field_action(
            env, field_type, type_param_vars, type_param_names, bounds)
    }
    match field_type {
        Type::IntType => some(FieldAction::Identity),
        Type::FloatType => some(FieldAction::FloatIdentity),
        Type::StrType => some(FieldAction::Identity),
        Type::BoolType => some(FieldAction::BoolIdentity),
        Type::UnitType => some(FieldAction::Identity),
        Type::TypeVar { id, .. } => {
            let param_idx = index_of_int(type_param_vars, id)
            if param_idx < 0 { return none }
            let param_name = str_at(type_param_names, param_idx)
            if has_bound(bounds, param_name, trait_name) == false {
                bounds.push(TraitBound { type_param: param_name, trait_name: trait_name })
            }
            some(FieldAction::Call {
                base_dict: DictRef::Simple(
                    trait_bound_param_name(param_name, trait_name)),
                extra_dicts: []
            })
        },
        Type::StructType { name, type_params, .. } => {
            if name == self_type_name {
                let extra = resolve_extra_dicts(type_params, type_param_vars, type_param_names, trait_name, known, self_type_name, bounds)
                match extra {
                    some(e) => some(FieldAction::Call {
                        base_dict: DictRef::Static(
                            trait_dict_name(name, trait_name)),
                        extra_dicts: e
                    }),
                    none => none,
                }
            } else {
                if known.contains(name) {
                    let extra = resolve_extra_dicts(type_params, type_param_vars, type_param_names, trait_name, known, self_type_name, bounds)
                    match extra {
                        some(e) => some(FieldAction::Call {
                            base_dict: DictRef::Static(
                                trait_dict_name(name, trait_name)),
                            extra_dicts: e
                        }),
                        none => none,
                    }
                } else {
                    none
                }
            }
        },
        Type::EnumType { name, type_params, .. } => {
            if name == self_type_name {
                let extra = resolve_extra_dicts(type_params, type_param_vars, type_param_names, trait_name, known, self_type_name, bounds)
                match extra {
                    some(e) => some(FieldAction::Call {
                        base_dict: DictRef::Static(
                            trait_dict_name(name, trait_name)),
                        extra_dicts: e
                    }),
                    none => none,
                }
            } else {
                if known.contains(name) {
                    let extra = resolve_extra_dicts(type_params, type_param_vars, type_param_names, trait_name, known, self_type_name, bounds)
                    match extra {
                        some(e) => some(FieldAction::Call {
                            base_dict: DictRef::Static(
                                trait_dict_name(name, trait_name)),
                            extra_dicts: e
                        }),
                        none => none,
                    }
                } else {
                    none
                }
            }
        },
        Type::TupleType { elements } => {
            let mut elem_actions: List<FieldAction> = []
            let mut ok = true
            for elem_ty in elements {
                if ok {
                    let elem_action = resolve_field_action(env, elem_ty, type_param_vars, type_param_names, trait_name, known, self_type_name, bounds)
                    match elem_action {
                        some(a) => elem_actions.push(a),
                        none => { ok = false },
                    }
                }
            }
            if ok {
                some(FieldAction::Tuple { element_actions: elem_actions })
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
        Type::AnyType => some(FieldAction::Identity),
        Type::NeverType => some(FieldAction::Identity),
        _ => none,
    }
}

fn resolve_json_field_action(
    env: TypeEnv,
    field_type: Type,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    mut bounds: List<TraitBound>
) -> FieldAction? {
    match resolve_json_dict_ref(
        env, field_type, type_param_vars, type_param_names, "Json", bounds
    ) {
        some(DictRef::Simple(dict_name)) => some(FieldAction::Call {
            base_dict: DictRef::Simple(dict_name),
            extra_dicts: []
        }),
        some(DictRef::Static(dict_name)) => some(FieldAction::Call {
            base_dict: DictRef::Static(dict_name),
            extra_dicts: []
        }),
        some(DictRef::Wrapped { dict, inner_dicts, .. }) => some(FieldAction::Call {
            base_dict: DictRef::Static(dict),
            extra_dicts: inner_dicts
        }),
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
    trait_name: Str, mut bounds: List<TraitBound>
) -> DictRef? {
    match t {
        Type::TypeVar { id, .. } => {
            let param_idx = index_of_int(owner_type_param_vars, id)
            if param_idx < 0 { return none }
            let param_name = str_at(owner_type_param_names, param_idx)
            if !has_bound(bounds, param_name, trait_name) {
                bounds.push(TraitBound {
                    type_param: param_name,
                    trait_name: trait_name
                })
            }
            some(DictRef::Simple(trait_bound_param_name(param_name, trait_name)))
        },
        Type::StructType { name, type_params, .. } => {
            resolve_json_nominal_dict_ref(
                env, name, type_params, owner_type_param_vars,
                owner_type_param_names, trait_name, bounds)
        },
        Type::EnumType { name, type_params, .. } => {
            resolve_json_nominal_dict_ref(
                env, name, type_params, owner_type_param_vars,
                owner_type_param_names, trait_name, bounds)
        },
        Type::IntType => resolve_json_builtin_dict_ref(env, "Int", trait_name),
        Type::FloatType => resolve_json_builtin_dict_ref(env, "Float", trait_name),
        Type::StrType => resolve_json_builtin_dict_ref(env, "Str", trait_name),
        Type::BoolType => resolve_json_builtin_dict_ref(env, "Bool", trait_name),
        Type::UnitType => resolve_json_builtin_dict_ref(env, "Unit", trait_name),
        _ => none
    }
}

fn resolve_json_builtin_dict_ref(
    env: TypeEnv, type_name: Str, trait_name: Str
) -> DictRef? {
    if has_impl(env.trait_reg, type_name, trait_name) {
        some(DictRef::Static(trait_dict_name(type_name, trait_name)))
    } else {
        none
    }
}

fn resolve_json_nominal_dict_ref(
    env: TypeEnv, name: Str, type_args: List<Type>,
    owner_type_param_vars: List<Int>, owner_type_param_names: List<Str>,
    trait_name: Str, mut bounds: List<TraitBound>
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
    let dict_name = trait_dict_name(name, trait_name)
    if requirements.len() == 0 {
        return some(DictRef::Static(dict_name))
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
            requirement.canonical_trait_name, bounds
        ) {
            some(dict_ref) => inner_dicts.push(dict_ref),
            none => return none
        }
    }
    some(DictRef::Wrapped {
        dict: dict_name,
        trait_name: trait_name,
        inner_dicts: inner_dicts
    })
}

fn resolve_hash_field_action(
    env: TypeEnv,
    field_type: Type,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    known: Set<Str>,
    self_type_name: Str,
    mut bounds: List<TraitBound>
) -> FieldAction? {
    match field_type {
        Type::IntType => some(FieldAction::Call {
            base_dict: DictRef::Static(trait_dict_name("Int", "Hash")),
            extra_dicts: []
        }),
        Type::StrType => some(FieldAction::Call {
            base_dict: DictRef::Static(trait_dict_name("Str", "Hash")),
            extra_dicts: []
        }),
        Type::BoolType => some(FieldAction::Call {
            base_dict: DictRef::Static(trait_dict_name("Bool", "Hash")),
            extra_dicts: []
        }),
        Type::TypeVar { id, .. } => {
            let param_idx = index_of_int(type_param_vars, id)
            if param_idx < 0 { return none }
            let param_name = str_at(type_param_names, param_idx)
            if has_bound(bounds, param_name, "Hash") == false {
                bounds.push(TraitBound { type_param: param_name, trait_name: "Hash" })
            }
            some(FieldAction::Call {
                base_dict: DictRef::Simple(
                    trait_bound_param_name(param_name, "Hash")),
                extra_dicts: []
            })
        },
        Type::StructType { name, type_params, .. } => {
            if name != self_type_name && known.contains(name) == false {
                return none
            }
            let extra = resolve_extra_dicts(
                type_params, type_param_vars, type_param_names,
                "Hash", known, self_type_name, bounds)
            match extra {
                some(e) => some(FieldAction::Call {
                    base_dict: DictRef::Static(
                        trait_dict_name(name, "Hash")),
                    extra_dicts: e
                }),
                none => none,
            }
        },
        Type::EnumType { name, type_params, .. } => {
            if name != self_type_name && known.contains(name) == false {
                return none
            }
            let extra = resolve_extra_dicts(
                type_params, type_param_vars, type_param_names,
                "Hash", known, self_type_name, bounds)
            match extra {
                some(e) => some(FieldAction::Call {
                    base_dict: DictRef::Static(
                        trait_dict_name(name, "Hash")),
                    extra_dicts: e
                }),
                none => none,
            }
        },
        Type::TupleType { elements } => {
            let mut elem_actions: List<FieldAction> = []
            for elem_ty in elements {
                let elem_action = resolve_hash_field_action(
                    env, elem_ty, type_param_vars, type_param_names,
                    known, self_type_name, bounds)
                match elem_action {
                    some(a) => elem_actions.push(a),
                    none => { return none },
                }
            }
            some(FieldAction::Tuple { element_actions: elem_actions })
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
    type_args: List<Type>,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    trait_name: Str,
    known: Set<Str>,
    self_type_name: Str, mut bounds: List<TraitBound>
) -> List<DictRef>? {
    let mut dicts: List<DictRef> = []
    for arg in type_args {
        let dict = resolve_type_arg_dict(arg, type_param_vars, type_param_names, trait_name, known, self_type_name, bounds)
        match dict {
            some(d) => dicts.push(d),
            none => { return none },
        }
    }
    some(dicts)
}

fn resolve_type_arg_dict(
    arg: Type,
    type_param_vars: List<Int>,
    type_param_names: List<Str>,
    trait_name: Str,
    known: Set<Str>,
    self_type_name: Str, mut bounds: List<TraitBound>
) -> DictRef? {
    match arg {
        Type::IntType => some(DictRef::Static(trait_dict_name("Int", trait_name))),
        Type::FloatType => {
            if trait_name == "Hash" {
                none
            } else {
                some(DictRef::Static(trait_dict_name("Float", trait_name)))
            }
        },
        Type::StrType => some(DictRef::Static(trait_dict_name("Str", trait_name))),
        Type::BoolType => some(DictRef::Static(trait_dict_name("Bool", trait_name))),
        Type::UnitType => {
            if trait_name == "Hash" || trait_name == "Json" {
                none
            } else {
                some(DictRef::Static(trait_dict_name("Unit", trait_name)))
            }
        },
        Type::TypeVar { id, .. } => {
            let param_idx = index_of_int(type_param_vars, id)
            if param_idx < 0 { return none }
            let param_name = str_at(type_param_names, param_idx)
            if has_bound(bounds, param_name, trait_name) == false {
                bounds.push(TraitBound { type_param: param_name, trait_name: trait_name })
            }
            some(DictRef::Simple(trait_bound_param_name(param_name, trait_name)))
        },
        Type::StructType { name, type_params, .. } => {
            if name != self_type_name && known.contains(name) == false {
                return none
            }
            let dict_name = trait_dict_name(name, trait_name)
            if type_params.len() == 0 {
                return some(DictRef::Static(dict_name))
            }
            let inner = resolve_extra_dicts(
                type_params, type_param_vars, type_param_names,
                trait_name, known, self_type_name, bounds)
            match inner {
                some(inner_dicts) => some(DictRef::Wrapped {
                    dict: dict_name,
                    trait_name: trait_name,
                    inner_dicts: inner_dicts
                }),
                none => none,
            }
        },
        Type::EnumType { name, type_params, .. } => {
            if name != self_type_name && known.contains(name) == false {
                return none
            }
            let dict_name = trait_dict_name(name, trait_name)
            if type_params.len() == 0 {
                return some(DictRef::Static(dict_name))
            }
            let inner = resolve_extra_dicts(
                type_params, type_param_vars, type_param_names,
                trait_name, known, self_type_name, bounds)
            match inner {
                some(inner_dicts) => some(DictRef::Wrapped {
                    dict: dict_name,
                    trait_name: trait_name,
                    inner_dicts: inner_dicts
                }),
                none => none,
            }
        },
        _ => none,
    }
}

// ================================================================
// Register derived impl
// ================================================================

fn register_derived_impl(
    mut env: TypeEnv, sink: CollectingSink,
    di: DerivedImpl, trait_name: Str, span: Span,
    provider_ref: ImplProviderRef
) -> ImplEntry {
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

    let origin = "<derive>:${di.type_name}:${trait_name}"
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
            scheme.ty, scheme.type_vars, scheme.def_id))
    }

    let trait_ref = match env.trait_reg.traits.get(trait_name) {
        some(def) => registered_trait_ref_symbol(def.owner_ref),
        none => panic("derive impl provider: trait is not registered")
    }
    let owner = ImplEntry {
        trait_name: some(trait_name),
        target_type_name: di.type_name,
        type_params: di.type_params,
        type_param_vars: type_var_ids,
        predicates: frozen_predicates,
        method_names: method_names,
        assoc_types: map_new(),
        method_schemes: exact,
        provider_ref: some(provider_ref),
        trait_ref: some(trait_ref),
        delegate_plan: delegate_plan_not_applicable(),
        origin: origin,
        span: span,
        owner_state: ImplOwnerState::FinalOwner
    }
    add_impl(env.trait_reg, owner)

    let mut sorted_methods = exact.entries()
    sorted_methods.sort_by(compare_by_first)
    for entry in sorted_methods {
        let (method_name, core) = entry
        let _ = install_method_core(
            env.trait_reg, sink, di.type_name, method_name, core,
            MethodOrigin {
                origin: origin,
                trait_name: some(trait_name),
                provider_ref: provider_ref,
                trait_ref: some(trait_ref),
                span: span
            })
    }
    owner
}

fn get_method_names(trait_name: Str) -> List<Str> {
    match trait_name {
        "Eq" => { let mut r = ["eq"]; r.push("ne"); r },
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
            methods.insert("eq", TypeScheme { ty: eq_fn, type_vars: type_var_ids, bounds: bounds, def_id: none })
            let ne_fn = Type::FnType { params: [self_type, self_type], return_type: BOOL, effects: EMPTY_ROW }
            methods.insert("ne", TypeScheme { ty: ne_fn, type_vars: type_var_ids, bounds: bounds, def_id: none })
        },
        "Clone" => {
            let clone_fn = Type::FnType { params: [self_type], return_type: self_type, effects: EMPTY_ROW }
            methods.insert("clone", TypeScheme { ty: clone_fn, type_vars: type_var_ids, bounds: bounds, def_id: none })
        },
        "Ord" => {
            let cmp_fn = Type::FnType { params: [self_type, self_type], return_type: INT, effects: EMPTY_ROW }
            methods.insert("cmp", TypeScheme { ty: cmp_fn, type_vars: type_var_ids, bounds: bounds, def_id: none })
        },
        "Debug" => {
            let debug_fn = Type::FnType { params: [self_type], return_type: STR, effects: EMPTY_ROW }
            methods.insert("debug", TypeScheme { ty: debug_fn, type_vars: type_var_ids, bounds: bounds, def_id: none })
        },
        "Hash" => {
            let hash_fn = Type::FnType { params: [self_type], return_type: INT, effects: EMPTY_ROW }
            methods.insert("hash", TypeScheme { ty: hash_fn, type_vars: type_var_ids, bounds: bounds, def_id: none })
        },
        "Json" => {
            let json_fn = Type::FnType { params: [self_type], return_type: STR, effects: EMPTY_ROW }
            methods.insert("to_json", TypeScheme { ty: json_fn, type_vars: type_var_ids, bounds: bounds, def_id: none })
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

fn has_bound(bounds: List<TraitBound>, type_param: Str, trait_name: Str) -> Bool {
    for b in bounds {
        if b.type_param == type_param {
            if b.trait_name == trait_name {
                return true
            }
        }
    }
    false
}

