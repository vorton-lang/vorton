use types::{Type, Effect, EffectRow, StructField, EnumVariant, RecordField, INT,
    effects_match_kind, nominal_display_name, types_equal}
use union_find::{UnionFind, uf_find, uf_lookup}
use ast::{Span, EffectExpr, TypeParam, DeriveAttribute}
use diagnostics::{CollectingSink, DiagnosticSink, DiagnosticContext, Severity,
    make_diag}
use codes::{E0504}
use ir_identity::{SymbolRef, TraitMethodRef, ImplProviderRef, IntrinsicRef,
    ImplOwnerRef, ImplMethodRef,
    HandledEffectRef,
    RegisteredNominalRef, RegisteredTraitRef, symbol_ref_same,
    VariantRef, VariantFieldRef,
    registered_nominal_ref_symbol, registered_trait_ref_symbol,
    make_symbol_ref, namespace_nominal,
    symbol_ref_canonical_payload, symbol_ref_origin_module_key,
    make_impl_owner_ref, impl_owner_ref_target, impl_owner_ref_provider,
    impl_owner_ref_trait, impl_owner_ref_same,
    impl_method_ref_owner, impl_method_ref_name, impl_method_ref_same,
    trait_method_ref_trait, trait_method_ref_source_member_index,
    trait_method_ref_callable_slot_index, trait_method_ref_same,
    handled_effect_ref_same,
    symbol_ref_namespace_kind, namespace_kind_same,
    namespace_member, namespace_trait,
    impl_provider_ref_same, intrinsic_ref_same,
    impl_provider_ref_kind, impl_provider_kind_same,
    impl_provider_kind_source, impl_provider_kind_delegate}
use ir_inventory::{EffectOperationRef, CallableResourceContractFact,
    callable_resource_contract_parameter_roles,
    callable_resource_contract_same}
use extern_manifest::{CompilerExternManifest, CompilerExternManifestEntry,
    new_compiler_extern_manifest, register_compiler_extern_source,
    close_compiler_extern_manifest, compiler_extern_manifest_entry,
    registered_compiler_extern_manifest_entry,
    compiler_extern_manifest_entry_compiler_symbol,
    compiler_extern_should_publish_hdecl}

// ============================================================
// Type Scheme (for let-polymorphism)
// ============================================================

pub struct AssocConstraintEntry {
    pub name: Str,   // "Item"
    pub ty: Type     // the constrained concrete type
}

pub struct SchemeBound {
    pub type_var: Int,
    pub trait_name: Str,
    pub assoc_constraints: List<AssocConstraintEntry>
}

pub struct TypeScheme {
    pub ty: Type,
    pub type_vars: List<Int>,
    pub bounds: List<SchemeBound>,
    pub def_id: Int?
}

// Follow a scheme's lexical DefId to its final declaration identity. Alias
// consumers in checker/export must share this rule: an intermediate re-export
// key is a lookup location, never callable provenance.
pub fn exact_scheme_value_origin(
    exact_origins: Map<Int, Str>, scheme: TypeScheme, fallback: Str
) -> Str {
    match scheme.def_id {
        some(def_id) => match exact_origins.get(def_id) {
            some(origin) => origin,
            none => fallback
        },
        none => fallback
    }
}

// ============================================================
// Struct / Enum / Effect definitions stored in environment
// ============================================================

pub struct ExplicitDerivedProviderPlan {
    pub attribute: DeriveAttribute,
    pub provider_ref: ImplProviderRef
}

pub struct NominalDerivedProviderPlan {
    pub implicit_provider_ref: ImplProviderRef,
    pub explicit_providers: List<ExplicitDerivedProviderPlan>
}

pub struct StructDef {
    pub name: Str,
    pub owner_ref: RegisteredNominalRef,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub fields: List<StructField>,
    pub derive_attrs: List<DeriveAttribute>,
    pub derived_provider_plan: NominalDerivedProviderPlan?,
    // Ordinals of generic arguments held in hidden owned storage. Visible
    // fields remain the ordinary structural resource authority.
    pub resource_storage_parameter_ordinals: List<Int>,
    // True for opaque extern (FFI) types registered as zero-field structs.
    // Carries cross-module via TypeDef::StructDef_ so both the declaring and
    // consuming modules can exclude it from trait derivation (B-074).
    pub is_extern: Bool
}

pub struct EnumDef {
    pub name: Str,
    pub owner_ref: RegisteredNominalRef,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub variants: List<EnumVariant>,
    pub variant_refs: List<VariantRef>,
    pub variant_field_refs: List<List<VariantFieldRef>>,
    pub derive_attrs: List<DeriveAttribute>,
    pub derived_provider_plan: NominalDerivedProviderPlan?,
    pub variant_index: Map<Str, Int>
}

pub fn lookup_variant(def: EnumDef, name: Str) -> EnumVariant? {
    match def.variant_index.get(name) {
        some(idx) => def.variants.get(idx),
        none => none
    }
}

pub struct EffectOpDef {
    pub name: Str,
    pub operation_ref: EffectOperationRef?,
    pub params: List<Type>,
    pub return_type: Type
}

pub enum BuiltInKind { BkFail }

pub struct EffectDef {
    pub name: Str,
    pub owner_ref: SymbolRef?,
    pub handled_ref: HandledEffectRef?,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub ops: List<EffectOpDef>,
    pub built_in_kind: BuiltInKind?
}

// ============================================================
// Trait definitions
// ============================================================

pub struct TraitMethodDef {
    pub name: Str,
    pub method_ref: TraitMethodRef,
    pub ty: Type,
    pub has_default: Bool,
    pub param_mutabilities: List<Bool>,
    pub method_type_params: List<TypeParam>
}

pub struct AssocTypeDef {
    pub name: Str,
    pub member_ref: SymbolRef,
    pub bounds: List<Str>,        // trait name bounds
    pub default_type: Type?,      // trait-level default value
    pub var_id: Int               // type variable ID used in trait method signatures
}

pub struct TraitDef {
    pub name: Str,
    pub owner_ref: RegisteredTraitRef,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub self_type_var_id: Int,
    pub methods: List<TraitMethodDef>,
    pub supertraits: List<Str>,
    pub assoc_types: List<AssocTypeDef>,
    pub contract: RegisteredTraitContract
}

// One fully typed associated constraint on an impl-owner predicate.  The
// representation is private so callers cannot splice a constraint into a
// frozen owner after registration.
pub struct ImplAssocPredicate {
    name: Str,
    ty: Type
}

pub struct RegisteredTraitMethodContract {
    method_ref: TraitMethodRef,
    signature: Type,
    has_default: Bool,
    param_mutabilities: List<Bool>
}

pub fn make_registered_trait_method_contract(
    method_ref: TraitMethodRef, signature: Type,
    has_default: Bool, param_mutabilities: List<Bool>
) -> RegisteredTraitMethodContract {
    match signature {
        Type::FnType { params, .. } => if
                params.len() != param_mutabilities.len() {
            panic("trait contract: method mutability arity differs")
        },
        _ => panic("trait contract: method signature is not callable")
    }
    RegisteredTraitMethodContract {
        method_ref: method_ref, signature: signature,
        has_default: has_default,
        param_mutabilities: param_mutabilities.map(fn(value) { value })
    }
}
pub fn registered_trait_method_ref(
    value: RegisteredTraitMethodContract
) -> TraitMethodRef { value.method_ref }
pub fn registered_trait_method_signature(
    value: RegisteredTraitMethodContract
) -> Type { value.signature }
pub fn registered_trait_method_has_default(
    value: RegisteredTraitMethodContract
) -> Bool { value.has_default }
pub fn registered_trait_method_mutabilities(
    value: RegisteredTraitMethodContract
) -> List<Bool> { value.param_mutabilities.map(fn(item) { item }) }

pub struct RegisteredTraitAssocContract {
    member: SymbolRef,
    value_type: Type,
    default_type: Type?,
    bound_traits: List<SymbolRef>
}
pub fn make_registered_trait_assoc_contract(
    member: SymbolRef, value_type: Type, default_type: Type?,
    bound_traits: List<SymbolRef>
) -> RegisteredTraitAssocContract {
    if !namespace_kind_same(
            symbol_ref_namespace_kind(member), namespace_member()) {
        panic("trait contract: associated item is not a member")
    }
    for bound in bound_traits {
        if !namespace_kind_same(
                symbol_ref_namespace_kind(bound), namespace_trait()) {
            panic("trait contract: associated bound is not a trait")
        }
    }
    RegisteredTraitAssocContract {
        member: member, value_type: value_type,
        default_type: default_type,
        bound_traits: bound_traits.map(fn(item) { item })
    }
}
pub fn registered_trait_assoc_member(
    value: RegisteredTraitAssocContract
) -> SymbolRef { value.member }
pub fn registered_trait_assoc_type(
    value: RegisteredTraitAssocContract
) -> Type { value.value_type }
pub fn registered_trait_assoc_default(
    value: RegisteredTraitAssocContract
) -> Type? { value.default_type }
pub fn registered_trait_assoc_bounds(
    value: RegisteredTraitAssocContract
) -> List<SymbolRef> { value.bound_traits.map(fn(item) { item }) }

pub struct RegisteredTraitContract {
    owner: RegisteredTraitRef,
    methods: List<RegisteredTraitMethodContract>,
    assoc_items: List<RegisteredTraitAssocContract>,
    handled_effect_obligations: List<HandledEffectRef>,
    dict_obligations: List<SymbolRef>
}

pub fn make_registered_trait_contract(
    owner: RegisteredTraitRef,
    methods: List<RegisteredTraitMethodContract>,
    assoc_items: List<RegisteredTraitAssocContract>,
    handled_effect_obligations: List<HandledEffectRef>,
    dict_obligations: List<SymbolRef>
) -> RegisteredTraitContract {
    let owner_symbol = registered_trait_ref_symbol(owner)
    let mut previous_source_index = -1
    for method_index in 0..methods.len() {
        let method = methods.get(method_index).unwrap()
        let method_ref = method.method_ref
        let source_index = trait_method_ref_source_member_index(method_ref)
        if !symbol_ref_same(trait_method_ref_trait(method_ref), owner_symbol) ||
           trait_method_ref_callable_slot_index(method_ref) != method_index ||
           source_index <= previous_source_index {
            panic("trait contract: method order/owner drifted")
        }
        previous_source_index = source_index
    }
    for assoc_index in 0..assoc_items.len() {
        let assoc = assoc_items.get(assoc_index).unwrap()
        if symbol_ref_origin_module_key(assoc.member) !=
           symbol_ref_origin_module_key(owner_symbol) {
            panic("trait contract: associated member crosses owner module")
        }
        for right_index in assoc_index + 1..assoc_items.len() {
            if symbol_ref_same(
                    assoc.member,
                    assoc_items.get(right_index).unwrap().member) {
                panic("trait contract: associated member repeats")
            }
        }
    }
    for effect_index in 0..handled_effect_obligations.len() {
        for right_index in effect_index + 1..handled_effect_obligations.len() {
            if handled_effect_ref_same(
                    handled_effect_obligations.get(effect_index).unwrap(),
                    handled_effect_obligations.get(right_index).unwrap()) {
                panic("trait contract: handled effect obligation repeats")
            }
        }
    }
    for dict_index in 0..dict_obligations.len() {
        let obligation = dict_obligations.get(dict_index).unwrap()
        if !namespace_kind_same(
                symbol_ref_namespace_kind(obligation), namespace_trait()) {
            panic("trait contract: dictionary obligation is not a trait")
        }
        for right_index in dict_index + 1..dict_obligations.len() {
            if symbol_ref_same(
                    obligation,
                    dict_obligations.get(right_index).unwrap()) {
                panic("trait contract: dictionary obligation repeats")
            }
        }
    }
    RegisteredTraitContract {
        owner: owner,
        methods: methods.map(fn(item) { item }),
        assoc_items: assoc_items.map(fn(item) { item }),
        handled_effect_obligations:
            handled_effect_obligations.map(fn(item) { item }),
        dict_obligations: dict_obligations.map(fn(item) { item })
    }
}

pub fn registered_trait_contract_owner(
    value: RegisteredTraitContract
) -> RegisteredTraitRef { value.owner }
pub fn registered_trait_contract_methods(
    value: RegisteredTraitContract
) -> List<RegisteredTraitMethodContract> {
    value.methods.map(fn(item) { item })
}
pub fn registered_trait_contract_assoc_items(
    value: RegisteredTraitContract
) -> List<RegisteredTraitAssocContract> {
    value.assoc_items.map(fn(item) { item })
}
pub fn registered_trait_contract_handled_effects(
    value: RegisteredTraitContract
) -> List<HandledEffectRef> {
    value.handled_effect_obligations.map(fn(item) { item })
}
pub fn registered_trait_contract_dict_obligations(
    value: RegisteredTraitContract
) -> List<SymbolRef> { value.dict_obligations.map(fn(item) { item }) }

pub fn make_impl_assoc_predicate(name: Str, ty: Type) -> ImplAssocPredicate {
    if name == "" {
        panic("impl predicate: associated type name is empty")
    }
    ImplAssocPredicate { name: name, ty: ty }
}

pub fn impl_assoc_predicate_name(value: ImplAssocPredicate) -> Str {
    value.name
}

pub fn impl_assoc_predicate_type(value: ImplAssocPredicate) -> Type {
    value.ty
}

enum ImplPredicateProvenanceValue {
    DirectPredicate,
    ExpandedPredicate(List<Str>)
}

pub struct ImplPredicateProvenance {
    value: ImplPredicateProvenanceValue
}

pub fn direct_impl_predicate_provenance() -> ImplPredicateProvenance {
    ImplPredicateProvenance {
        value: ImplPredicateProvenanceValue::DirectPredicate
    }
}

pub fn expanded_impl_predicate_provenance(
    path: List<Str>
) -> ImplPredicateProvenance {
    if path.len() < 2 {
        panic("impl predicate: expanded path is incomplete")
    }
    let mut copied: List<Str> = []
    for component in path {
        if component == "" {
            panic("impl predicate: expanded path has empty component")
        }
        copied.push(component)
    }
    ImplPredicateProvenance {
        value: ImplPredicateProvenanceValue::ExpandedPredicate(copied)
    }
}

pub fn impl_predicate_provenance_is_direct(
    value: ImplPredicateProvenance
) -> Bool {
    match value.value {
        ImplPredicateProvenanceValue::DirectPredicate => true,
        ImplPredicateProvenanceValue::ExpandedPredicate(_) => false
    }
}

pub fn impl_predicate_provenance_path(
    value: ImplPredicateProvenance
) -> List<Str> {
    match value.value {
        ImplPredicateProvenanceValue::DirectPredicate => [],
        ImplPredicateProvenanceValue::ExpandedPredicate(path) => {
            let mut copied: List<Str> = []
            for component in path { copied.push(component) }
            copied
        }
    }
}

pub struct TypedImplPredicate {
    subject_param_index: Int,
    subject_type_var: Int,
    canonical_trait_name: Str,
    assoc_constraints: List<ImplAssocPredicate>,
    provenance: ImplPredicateProvenance
}

pub fn make_typed_impl_predicate(
    subject_param_index: Int, subject_type_var: Int,
    canonical_trait_name: Str,
    assoc_constraints: List<ImplAssocPredicate>,
    provenance: ImplPredicateProvenance
) -> TypedImplPredicate {
    if subject_param_index < 0 || subject_type_var < 0 ||
       canonical_trait_name == "" {
        panic("impl predicate: incomplete typed predicate")
    }
    let mut copied: List<ImplAssocPredicate> = []
    let mut seen: Set<Str> = set_new()
    for constraint in assoc_constraints {
        let name = impl_assoc_predicate_name(constraint)
        if seen.contains(name) {
            panic("impl predicate: duplicate associated constraint")
        }
        seen.insert(name)
        copied.push(constraint)
    }
    if !impl_predicate_provenance_is_direct(provenance) && copied.len() > 0 {
        panic("impl predicate: expanded predicate has associated constraints")
    }
    TypedImplPredicate {
        subject_param_index: subject_param_index,
        subject_type_var: subject_type_var,
        canonical_trait_name: canonical_trait_name,
        assoc_constraints: copied,
        provenance: provenance
    }
}

pub fn impl_predicate_subject_param_index(value: TypedImplPredicate) -> Int {
    value.subject_param_index
}

pub fn impl_predicate_subject_type_var(value: TypedImplPredicate) -> Int {
    value.subject_type_var
}

pub fn impl_predicate_trait_name(value: TypedImplPredicate) -> Str {
    value.canonical_trait_name
}

pub fn impl_predicate_assoc_constraints(
    value: TypedImplPredicate
) -> List<ImplAssocPredicate> {
    let mut copied: List<ImplAssocPredicate> = []
    for constraint in value.assoc_constraints { copied.push(constraint) }
    copied
}

pub fn impl_predicate_provenance(
    value: TypedImplPredicate
) -> ImplPredicateProvenance {
    value.provenance
}

fn impl_predicate_same(
    left: TypedImplPredicate, right: TypedImplPredicate
) -> Bool {
    if left.subject_param_index != right.subject_param_index ||
       left.subject_type_var != right.subject_type_var ||
       left.canonical_trait_name != right.canonical_trait_name ||
       left.assoc_constraints.len() != right.assoc_constraints.len() ||
       impl_predicate_provenance_is_direct(left.provenance) !=
           impl_predicate_provenance_is_direct(right.provenance) {
        return false
    }
    let left_path = impl_predicate_provenance_path(left.provenance)
    let right_path = impl_predicate_provenance_path(right.provenance)
    if left_path.len() != right_path.len() { return false }
    for index in 0..left_path.len() {
        if left_path.get(index).unwrap_or("") !=
           right_path.get(index).unwrap_or("") { return false }
    }
    for index in 0..left.assoc_constraints.len() {
        match (left.assoc_constraints.get(index),
               right.assoc_constraints.get(index)) {
            (some(a), some(b)) => {
                if a.name != b.name || !types_equal(a.ty, b.ty) {
                    return false
                }
            },
            _ => return false
        }
    }
    true
}

pub struct FrozenImplPredicateSet {
    predicates: List<TypedImplPredicate>
}

pub fn freeze_impl_predicate_set(
    owner_type_vars: List<Int>, predicates: List<TypedImplPredicate>
) -> FrozenImplPredicateSet {
    let mut copied: List<TypedImplPredicate> = []
    let mut seen: Set<Str> = set_new()
    for predicate in predicates {
        let index = predicate.subject_param_index
        if index < 0 || index >= owner_type_vars.len() ||
           owner_type_vars.get(index).unwrap_or(-1) !=
               predicate.subject_type_var {
            panic("impl predicate: subject does not match owner type variables")
        }
        let key = "${index.to_str()}|${predicate.canonical_trait_name}"
        if seen.contains(key) {
            panic("impl predicate: duplicate owner predicate")
        }
        seen.insert(key)
        if !impl_predicate_provenance_is_direct(predicate.provenance) {
            let path = impl_predicate_provenance_path(predicate.provenance)
            if path.get(path.len() - 1).unwrap_or("") !=
               predicate.canonical_trait_name {
                panic("impl predicate: expanded path has wrong target")
            }
            let direct_name = path.get(0).unwrap_or("")
            let direct_exists = predicates.any(fn(candidate) {
                candidate.subject_param_index == index &&
                    candidate.canonical_trait_name == direct_name &&
                    impl_predicate_provenance_is_direct(candidate.provenance)
            })
            if !direct_exists {
                panic("impl predicate: expanded path has no direct root")
            }
        }
        copied.push(predicate)
    }
    FrozenImplPredicateSet { predicates: copied }
}

pub fn empty_frozen_impl_predicate_set() -> FrozenImplPredicateSet {
    freeze_impl_predicate_set([], [])
}

pub fn frozen_impl_predicates(
    value: FrozenImplPredicateSet
) -> List<TypedImplPredicate> {
    let mut copied: List<TypedImplPredicate> = []
    for predicate in value.predicates { copied.push(predicate) }
    copied
}

pub fn frozen_impl_predicate_set_same(
    left: FrozenImplPredicateSet, right: FrozenImplPredicateSet
) -> Bool {
    if left.predicates.len() != right.predicates.len() { return false }
    for index in 0..left.predicates.len() {
        match (left.predicates.get(index), right.predicates.get(index)) {
            (some(a), some(b)) => if !impl_predicate_same(a, b) {
                return false
            },
            _ => return false
        }
    }
    true
}

// Method schemes intentionally cannot carry impl-owner predicates.  Every
// consumer resolves those predicates through the owning ImplEntry.
pub struct ImplMethodSchemeCore {
    ty: Type,
    type_vars: List<Int>,
    def_id: Int?
}

pub fn make_impl_method_scheme_core(
    ty: Type, type_vars: List<Int>, def_id: Int?
) -> ImplMethodSchemeCore {
    ImplMethodSchemeCore {
        ty: ty, type_vars: list_clone(type_vars), def_id: def_id
    }
}

pub fn impl_method_core_from_scheme(scheme: TypeScheme) -> ImplMethodSchemeCore {
    if scheme.bounds.len() != 0 {
        panic("impl method core: method-owned bounds are unsupported")
    }
    make_impl_method_scheme_core(scheme.ty, scheme.type_vars, scheme.def_id)
}

pub fn impl_method_core_type(value: ImplMethodSchemeCore) -> Type {
    value.ty
}

pub fn impl_method_core_type_vars(value: ImplMethodSchemeCore) -> List<Int> {
    list_clone(value.type_vars)
}

pub fn impl_method_core_def_id(value: ImplMethodSchemeCore) -> Int? {
    value.def_id
}

pub fn impl_method_core_as_scheme(value: ImplMethodSchemeCore) -> TypeScheme {
    TypeScheme {
        ty: value.ty, type_vars: list_clone(value.type_vars),
        bounds: [], def_id: value.def_id
    }
}

fn impl_method_core_same(
    left: ImplMethodSchemeCore, right: ImplMethodSchemeCore
) -> Bool {
    if !types_equal(left.ty, right.ty) || left.type_vars.len() != right.type_vars.len() ||
       left.def_id != right.def_id { return false }
    for index in 0..left.type_vars.len() {
        if left.type_vars.get(index).unwrap_or(-1) !=
           right.type_vars.get(index).unwrap_or(-1) { return false }
    }
    true
}

// One runtime dictionary predicate instantiated from the unique frozen impl
// owner.  This is a one-way consumer value, never a stored predicate authority.
pub struct ImplRuntimeRequirement {
    pub subject_type: Type,
    pub canonical_trait_name: Str,
    pub assoc_constraints: List<ImplAssocPredicate>
}

pub struct DelegateChildProviderPlan {
    source_member_index: Int,
    provider_ref: ImplProviderRef,
    produced_owner_count: Int,
    had_semantic_error: Bool
}

pub fn make_delegate_child_provider_plan(
    source_member_index: Int, provider_ref: ImplProviderRef,
    produced_owner_count: Int, had_semantic_error: Bool
) -> DelegateChildProviderPlan {
    if source_member_index < 0 || produced_owner_count < 0 ||
       (produced_owner_count == 0 && !had_semantic_error) ||
       !impl_provider_kind_same(
            impl_provider_ref_kind(provider_ref),
            impl_provider_kind_delegate()) {
        panic("impl owner: invalid delegate child provider")
    }
    DelegateChildProviderPlan {
        source_member_index: source_member_index,
        provider_ref: provider_ref,
        produced_owner_count: produced_owner_count,
        had_semantic_error: had_semantic_error
    }
}

pub fn delegate_child_provider_source_member_index(
    value: DelegateChildProviderPlan
) -> Int {
    value.source_member_index
}

pub fn delegate_child_provider_ref(
    value: DelegateChildProviderPlan
) -> ImplProviderRef {
    value.provider_ref
}

pub fn delegate_child_provider_produced_owner_count(
    value: DelegateChildProviderPlan
) -> Int {
    value.produced_owner_count
}

pub fn delegate_child_provider_had_semantic_error(
    value: DelegateChildProviderPlan
) -> Bool {
    value.had_semantic_error
}

enum DelegatePlanStateValue {
    DelegateNotApplicable,
    DelegatePending,
    DelegateFinal(List<DelegateChildProviderPlan>)
}

pub struct DelegatePlanState {
    value: DelegatePlanStateValue
}

pub fn delegate_plan_not_applicable() -> DelegatePlanState {
    DelegatePlanState { value: DelegatePlanStateValue::DelegateNotApplicable }
}

pub fn delegate_plan_pending() -> DelegatePlanState {
    DelegatePlanState { value: DelegatePlanStateValue::DelegatePending }
}

fn copy_delegate_child_provider_plans(
    values: List<DelegateChildProviderPlan>
) -> List<DelegateChildProviderPlan> {
    let mut copied: List<DelegateChildProviderPlan> = []
    for value in values { copied.push(value) }
    copied
}

pub fn delegate_plan_final(
    children: List<DelegateChildProviderPlan>
) -> DelegatePlanState {
    DelegatePlanState { value: DelegatePlanStateValue::DelegateFinal(
        copy_delegate_child_provider_plans(children)) }
}

pub fn delegate_plan_is_pending(value: DelegatePlanState) -> Bool {
    match value.value {
        DelegatePlanStateValue::DelegatePending => true,
        _ => false
    }
}

pub fn delegate_plan_children(
    value: DelegatePlanState
) -> List<DelegateChildProviderPlan> {
    match value.value {
        DelegatePlanStateValue::DelegateFinal(children) =>
            copy_delegate_child_provider_plans(children),
        DelegatePlanStateValue::DelegateNotApplicable => [],
        DelegatePlanStateValue::DelegatePending =>
            panic("impl owner: pending delegate plan was observed")
    }
}

pub struct ImplEntry {
    pub trait_name: Str?,
    pub target_type_name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub predicates: FrozenImplPredicateSet,
    pub method_names: List<Str>,
    pub assoc_types: Map<Str, Type>,
    // Trait/inherent method cores live only on their owning entry. The flat
    // ordinary-call view carries only exact ImplMethodRef identity.
    pub method_schemes: Map<Str, ImplMethodSchemeCore>,
    // Registration-issued executable members. Every owner carries one exact
    // ImplMethodRef for every method core.
    pub method_refs: Map<Str, ImplMethodRef>,
    // Exact builtin method semantic identity.  The owning method scheme is
    // the sole signature payload; this map may only relate that core to one
    // fixed IntrinsicRef.
    pub method_intrinsics: Map<Str, IntrinsicRef>,
    // Ownership-neutral resource ABI fixed by the exact method producer.
    // Bodyless builtin methods must carry one entry; downstream stages copy it.
    pub method_resource_contracts: Map<Str, CallableResourceContractFact>,
    pub provider_ref: ImplProviderRef?,
    pub trait_ref: SymbolRef?,
    pub owner_ref: ImplOwnerRef?,
    pub delegate_plan: DelegatePlanState,
    pub span: Span
}

// ============================================================
// Type alias + function bounds
// ============================================================

pub struct TypeAliasDef {
    pub name: Str,
    pub owner_ref: SymbolRef,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub schema_vars: List<Int>,
    pub ty: Type
}

pub struct EffectAliasDef {
    pub name: Str,
    pub type_params: List<Str>,
    pub type_param_vars: List<Int>,
    pub effects: List<EffectExpr>,
    pub span: Span
}

pub struct FnBound {
    pub type_param: Str,
    pub trait_name: Str
}

// ============================================================
// Scope
// ============================================================

pub struct Scope {
    pub variables: Map<Str, TypeScheme>
}

// ============================================================
// TypeEnv sub-structs
// ============================================================

pub struct TypeRegistry {
    pub structs: Map<Str, StructDef>,
    // Stable raw-ABI extern definitions. Ordinary nominal aliases may replace
    // the same leaf in `structs`, but must never erase the extern declaration.
    pub extern_structs: Map<Str, StructDef>,
    pub enums: Map<Str, EnumDef>,
    pub effects: Map<Str, EffectDef>,
    pub variant_to_enum: Map<Str, Str>,
    // Exact constructor provenance keyed by the lexical binding DefId. This is
    // a codegen identity table for every variant constructor; ownership
    // freshness is classified separately in shared HIR helpers.
    pub variant_ctor_origins: Map<Int, Str>,
    pub type_aliases: Map<Str, TypeAliasDef>,
    pub effect_aliases: Map<Str, EffectAliasDef>
}

pub struct TraitRegistry {
    pub traits: Map<Str, TraitDef>,
    pub trait_impls: Map<Str, List<ImplEntry>>,
    pub method_index: Map<Str, Map<Str, ImplMethodRef>>,
    pub mut_methods: Map<Str, Set<Str>>
}

pub struct ScopeManager {
    pub scopes: List<Scope>,
    pub fn_bounds: Map<Str, List<FnBound>>,
    pub var_bounds: Map<Int, Set<Str>>,
    pub def_spans: Map<Int, Span>,
    pub mutable_vars: Set<Int>,
    pub let_defs: Set<Int>,
    pub mut_param_defs: Set<Int>
}

pub struct IdGen {
    pub next_type_var_id: Int,
    pub next_def_id: Int
}

// ============================================================
// TypeEnv
// ============================================================

pub struct TypeEnv {
    pub types: TypeRegistry,
    pub trait_reg: TraitRegistry,
    pub scope: ScopeManager,
    pub ids: IdGen,
    compiler_externs: CompilerExternManifest
}

// ============================================================
// Constructor + helpers
// ============================================================

pub fn mono(ty: Type) -> TypeScheme {
    TypeScheme { ty: ty, type_vars: [], bounds: [], def_id: none }
}

pub fn new_type_env() -> TypeEnv {
    let initial_scope = Scope { variables: map_new() }
    TypeEnv {
        types: TypeRegistry {
            structs: map_new(),
            extern_structs: map_new(),
            enums: map_new(),
            effects: map_new(),
            variant_to_enum: map_new(),
            variant_ctor_origins: map_new(),
            type_aliases: map_new(),
            effect_aliases: map_new()
        },
        trait_reg: TraitRegistry {
            traits: map_new(),
            trait_impls: map_new(),
            method_index: map_new(),
            mut_methods: map_new()
        },
        scope: ScopeManager {
            scopes: [initial_scope],
            fn_bounds: map_new(),
            var_bounds: map_new(),
            def_spans: map_new(),
            mutable_vars: set_new(),
            let_defs: set_new(),
            mut_param_defs: set_new()
        },
        ids: IdGen {
            next_type_var_id: 0,
            next_def_id: 0
        },
        compiler_externs: new_compiler_extern_manifest()
    }
}

pub fn commit_struct_resource_storage_parameter_ordinals(
    mut env: TypeEnv, owner: RegisteredNominalRef, ordinals: List<Int>
) {
    let owner_symbol = registered_nominal_ref_symbol(owner)
    let mut keys: List<Str> = []
    for entry in env.types.structs.entries() {
        if symbol_ref_same(
                registered_nominal_ref_symbol(entry.1.owner_ref),
                owner_symbol) {
            keys.push(entry.0)
        }
    }
    if keys.len() == 0 {
        panic("struct storage contract: exact owner is absent")
    }
    for key in keys {
        let def = env.types.structs.get(key).unwrap()
        let mut index = 0
        while index < ordinals.len() {
            let ordinal = ordinals.get(index).unwrap()
            if ordinal < 0 || ordinal >= def.type_param_vars.len() ||
               (index > 0 && ordinals.get(index - 1).unwrap() >= ordinal) {
                panic("struct storage contract: ordinals are not canonical")
            }
            index = index + 1
        }
        if def.resource_storage_parameter_ordinals.len() != 0 &&
           !int_list_same(def.resource_storage_parameter_ordinals, ordinals) {
            panic("struct storage contract: exact owner changed")
        }
        env.types.structs.insert(key, StructDef {
            name: def.name, owner_ref: def.owner_ref,
            type_params: def.type_params,
            type_param_vars: def.type_param_vars,
            fields: def.fields, derive_attrs: def.derive_attrs,
            derived_provider_plan: def.derived_provider_plan,
            resource_storage_parameter_ordinals: ordinals,
            is_extern: def.is_extern
        })
    }
}

// Prelude registration is the only producer allowed to relate a
// resolver-issued source SymbolRef to a fixed compiler-owned extern. The
// manifest itself owns the physical source census and exact resource facts;
// TypeEnv only transports that opaque relation into declaration inference.
pub fn register_compiler_owned_extern_source(
    mut env: TypeEnv, source: SymbolRef, scheme: TypeScheme,
    source_generic_arity: Int
) -> Bool {
    if scheme.bounds.len() != 0 {
        panic("compiler extern manifest: source bridge has trait bounds")
    }
    let mut normalization: Map<Int, Type> = map_new()
    let mut index = 0
    for type_var in scheme.type_vars {
        normalization.insert(type_var, Type::TypeVar {
            id: -1 - index, name: none
        })
        index = index + 1
    }
    register_compiler_extern_source(
        env.compiler_externs, source,
        apply_subst_map(normalization, scheme.ty),
        source_generic_arity)
}

pub fn close_compiler_owned_extern_sources(mut env: TypeEnv) {
    close_compiler_extern_manifest(env.compiler_externs)
}

pub fn compiler_owned_extern_manifest_entry(
    env: TypeEnv, source: SymbolRef
) -> CompilerExternManifestEntry? {
    compiler_extern_manifest_entry(env.compiler_externs, source)
}

pub fn compiler_owned_extern_symbol(
    env: TypeEnv, source: SymbolRef
) -> SymbolRef? {
    registered_compiler_extern_manifest_entry(
        env.compiler_externs, source).map(fn(entry) {
            compiler_extern_manifest_entry_compiler_symbol(entry)
        })
}

pub fn compiler_owned_extern_should_publish_hdecl(
    env: TypeEnv, source: SymbolRef
) -> Bool? {
    compiler_extern_should_publish_hdecl(
        env.compiler_externs, source)
}

fn builtin_impl_target_symbol(type_name: Str) -> SymbolRef? {
    let site = match type_name {
        "Int" => some("builtin:type:0"),
        "Float" => some("builtin:type:1"),
        "Str" => some("builtin:type:2"),
        "Bool" => some("builtin:type:3"),
        "Unit" => some("builtin:type:4"),
        "Never" => some("builtin:type:5"),
        "Ptr" => some("builtin:type:6"),
        "List" => some("builtin:type:7"),
        "Map" => some("builtin:type:8"),
        "Set" => some("builtin:type:9"),
        "Cell" => some("builtin:type:10"),
        "Option" => some("builtin:type:11"),
        _ => none
    }
    match site {
        some(path) => some(make_symbol_ref(
            "$builtin", namespace_nominal(), type_name, path)),
        none => none
    }
}

// One typed target lookup shared by registration, export and Core assembly.
// No caller may mint a target identity from the spelling that failed here.
pub fn impl_target_symbol(env: TypeEnv, type_name: Str) -> SymbolRef? {
    match env.types.structs.get(type_name) {
        some(def) => some(registered_nominal_ref_symbol(def.owner_ref)),
        none => match env.types.enums.get(type_name) {
            some(def) => some(registered_nominal_ref_symbol(def.owner_ref)),
            none => builtin_impl_target_symbol(type_name)
        }
    }
}

// ============================================================
// TypeEnv methods
// ============================================================

impl TypeEnv {
    pub fn current_var_id(self) -> Int { self.ids.next_type_var_id }

    pub fn fresh_var(mut self) -> Type {
        let id = self.ids.next_type_var_id
        self.ids.next_type_var_id = id + 1
        Type::TypeVar { id: id, name: none }
    }

    pub fn fresh_var_id(mut self) -> Int {
        let id = self.ids.next_type_var_id
        self.ids.next_type_var_id = id + 1
        id
    }

    pub fn fresh_def_id(mut self) -> Int {
        let id = self.ids.next_def_id
        self.ids.next_def_id = id + 1
        id
    }

    pub fn push_scope(mut self) {
        self.scope.scopes.push(Scope { variables: map_new() })
    }

    pub fn pop_scope(mut self) {
        if self.scope.scopes.len() <= 1 {
            panic("unreachable: cannot pop global scope")
        }
        self.scope.scopes.pop()
    }

    pub fn bind(mut self, name: Str, scheme: TypeScheme) {
        let s = match scheme.def_id {
            some(_) => scheme,
            none => TypeScheme { ..scheme, def_id: some(self.fresh_def_id()) }
        }
        let idx = self.scope.scopes.len() - 1
        match self.scope.scopes.get(idx) {
            some(scope) => scope.variables.insert(name, s),
            none => panic("unreachable: no current scope")
        }
    }

    pub fn bind_mono(mut self, name: Str, ty: Type) {
        self.bind(name, mono(ty))
    }

    pub fn record_def_span(mut self, def_id: Int, span: Span) {
        self.scope.def_spans.insert(def_id, span)
    }

    pub fn rebind(mut self, name: Str, scheme: TypeScheme) {
        let mut i = self.scope.scopes.len() - 1
        while i >= 0 {
            match self.scope.scopes.get(i) {
                some(scope) => {
                    if scope.variables.contains_key(name) {
                        scope.variables.insert(name, scheme)
                        return
                    }
                },
                none => {}
            }
            i = i - 1
        }
        panic("unreachable: rebind failed — variable '${name}' not found in any scope")
    }

    pub fn lookup(self, name: Str) -> TypeScheme? {
        let mut i = self.scope.scopes.len() - 1
        while i >= 0 {
            let found = match self.scope.scopes.get(i) {
                some(scope) => scope.variables.get(name),
                none => none
            }
            if found.is_some() { return found }
            i = i - 1
        }
        none
    }

    pub fn instantiate(mut self, scheme: TypeScheme) -> Type {
        if scheme.type_vars.len() == 0 { return scheme.ty }
        let mut mapping: Map<Int, Type> = map_new()
        for tv in scheme.type_vars {
            mapping.insert(tv, self.fresh_var())
        }
        for bound in scheme.bounds {
            match mapping.get(bound.type_var) {
                some(fresh) => match fresh {
                    Type::TypeVar { id, .. } => {
                        let mut existing: Set<Str> = match self.scope.var_bounds.get(id) {
                            some(s) => s,
                            none => set_new()
                        }
                        existing.insert(bound.trait_name)
                        self.scope.var_bounds.insert(id, existing)
                    },
                    _ => {}
                },
                none => {}
            }
        }
        apply_subst_map(mapping, scheme.ty)
    }

    pub fn instantiate_impl_method_core(
        mut self, owner: ImplEntry, core: ImplMethodSchemeCore
    ) -> Type {
        let mut mapping: Map<Int, Type> = map_new()
        for type_var in impl_method_core_type_vars(core) {
            mapping.insert(type_var, self.fresh_var())
        }
        for predicate in frozen_impl_predicates(owner.predicates) {
            match mapping.get(impl_predicate_subject_type_var(predicate)) {
                some(Type::TypeVar { id, .. }) => {
                    let mut existing = match self.scope.var_bounds.get(id) {
                        some(bounds) => bounds,
                        none => set_new()
                    }
                    existing.insert(impl_predicate_trait_name(predicate))
                    self.scope.var_bounds.insert(id, existing)
                },
                _ => panic(
                    "impl method instantiation: predicate subject is not quantified")
            }
        }
        apply_subst_map(mapping, impl_method_core_type(core))
    }
}

// ============================================================
// trait_impls helpers (Map<Str, List<ImplEntry>> keyed by target_type_name)
// ============================================================

fn method_owner_display(trait_name: Str?) -> Str {
    match trait_name {
        some(name) => "trait '${nominal_display_name(name)}'",
        none => "an inherent impl"
    }
}

fn optional_string_same(left: Str?, right: Str?) -> Bool {
    match (left, right) {
        (some(a), some(b)) => a == b,
        (none, none) => true,
        _ => false
    }
}

pub fn optional_symbol_ref_same(left: SymbolRef?, right: SymbolRef?) -> Bool {
    match (left, right) {
        (some(a), some(b)) => symbol_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
}

fn optional_impl_provider_ref_same(
    left: ImplProviderRef?, right: ImplProviderRef?
) -> Bool {
    match (left, right) {
        (some(a), some(b)) => impl_provider_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
}

fn optional_impl_owner_ref_same(
    left: ImplOwnerRef?, right: ImplOwnerRef?
) -> Bool {
    match (left, right) {
        (some(a), some(b)) => impl_owner_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
}

fn int_list_same(left: List<Int>, right: List<Int>) -> Bool {
    if left.len() != right.len() { return false }
    for index in 0..left.len() {
        if left.get(index).unwrap_or(-1) != right.get(index).unwrap_or(-1) {
            return false
        }
    }
    true
}

fn string_list_same(left: List<Str>, right: List<Str>) -> Bool {
    if left.len() != right.len() { return false }
    for index in 0..left.len() {
        if left.get(index).unwrap_or("") != right.get(index).unwrap_or("") {
            return false
        }
    }
    true
}

fn assoc_type_map_same(left: Map<Str, Type>, right: Map<Str, Type>) -> Bool {
    if left.len() != right.len() { return false }
    for entry in left.entries() {
        let (name, ty) = entry
        match right.get(name) {
            some(other) => if !types_equal(ty, other) { return false },
            none => return false
        }
    }
    true
}

fn method_core_map_same(
    left: Map<Str, ImplMethodSchemeCore>,
    right: Map<Str, ImplMethodSchemeCore>
) -> Bool {
    if left.len() != right.len() { return false }
    for entry in left.entries() {
        let (name, core) = entry
        match right.get(name) {
            some(other) => if !impl_method_core_same(core, other) {
                return false
            },
            none => return false
        }
    }
    true
}

fn method_ref_map_same(
    left: Map<Str, ImplMethodRef>, right: Map<Str, ImplMethodRef>
) -> Bool {
    if left.len() != right.len() { return false }
    for entry in left.entries() {
        let (name, method_ref) = entry
        match right.get(name) {
            some(other) => if !impl_method_ref_same(method_ref, other) {
                return false
            },
            none => return false
        }
    }
    true
}

fn method_intrinsic_map_same(
    left: Map<Str, IntrinsicRef>, right: Map<Str, IntrinsicRef>
) -> Bool {
    if left.len() != right.len() { return false }
    for entry in left.entries() {
        let (name, intrinsic) = entry
        match right.get(name) {
            some(other) => if !intrinsic_ref_same(intrinsic, other) {
                return false
            },
            none => return false
        }
    }
    true
}

fn method_resource_contract_map_same(
    left: Map<Str, CallableResourceContractFact>,
    right: Map<Str, CallableResourceContractFact>
) -> Bool {
    if left.len() != right.len() { return false }
    for entry in left.entries() {
        let (name, contract) = entry
        match right.get(name) {
            some(other) => if !callable_resource_contract_same(
                    contract, other) { return false },
            none => return false
        }
    }
    true
}

fn delegate_child_provider_plan_same(
    left: DelegateChildProviderPlan, right: DelegateChildProviderPlan
) -> Bool {
    left.source_member_index == right.source_member_index &&
        impl_provider_ref_same(left.provider_ref, right.provider_ref) &&
        left.produced_owner_count == right.produced_owner_count &&
        left.had_semantic_error == right.had_semantic_error
}

fn delegate_plan_state_same(
    left: DelegatePlanState, right: DelegatePlanState
) -> Bool {
    match (left.value, right.value) {
        (DelegatePlanStateValue::DelegateNotApplicable,
         DelegatePlanStateValue::DelegateNotApplicable) => true,
        (DelegatePlanStateValue::DelegatePending,
         DelegatePlanStateValue::DelegatePending) => true,
        (DelegatePlanStateValue::DelegateFinal(a),
         DelegatePlanStateValue::DelegateFinal(b)) => {
            if a.len() != b.len() { return false }
            for index in 0..a.len() {
                match (a.get(index), b.get(index)) {
                    (some(left_child), some(right_child)) =>
                        if !delegate_child_provider_plan_same(
                                left_child, right_child) { return false },
                    _ => return false
                }
            }
            true
        }
        _ => false
    }
}

fn impl_entry_owner_shape_same(left: ImplEntry, right: ImplEntry) -> Bool {
    left.target_type_name == right.target_type_name &&
        optional_string_same(left.trait_name, right.trait_name) &&
        optional_symbol_ref_same(left.trait_ref, right.trait_ref) &&
        optional_impl_owner_ref_same(left.owner_ref, right.owner_ref) &&
        string_list_same(left.type_params, right.type_params) &&
        int_list_same(left.type_param_vars, right.type_param_vars) &&
        frozen_impl_predicate_set_same(left.predicates, right.predicates) &&
        assoc_type_map_same(left.assoc_types, right.assoc_types)
}

// Complete equality for a registration-issued final owner. Export/re-export
// dedupe uses this shared invariant after exact owner-key match; the opaque
// identity alone may never stand in for structural equality.
pub fn impl_entry_final_same(left: ImplEntry, right: ImplEntry) -> Bool {
    optional_impl_provider_ref_same(
            left.provider_ref, right.provider_ref) &&
        impl_entry_owner_shape_same(left, right) &&
        string_list_same(left.method_names, right.method_names) &&
        method_core_map_same(left.method_schemes, right.method_schemes) &&
        method_ref_map_same(left.method_refs, right.method_refs) &&
        method_intrinsic_map_same(
            left.method_intrinsics, right.method_intrinsics) &&
        method_resource_contract_map_same(
            left.method_resource_contracts,
            right.method_resource_contracts) &&
        delegate_plan_state_same(left.delegate_plan, right.delegate_plan)
}

pub fn impl_entry_exact_key_same(left: ImplEntry, right: ImplEntry) -> Bool {
    match (left.owner_ref, right.owner_ref) {
        (some(a), some(b)) => impl_owner_ref_same(a, b),
        _ => false
    }
}

fn validate_impl_entry(reg: TraitRegistry, entry: ImplEntry) {
    if entry.target_type_name == "" ||
       entry.type_params.len() != entry.type_param_vars.len() {
        panic("impl owner: incomplete owner entry")
    }
    for intrinsic_entry in entry.method_intrinsics.entries() {
        let (method_name, _) = intrinsic_entry
        if !entry.method_schemes.contains_key(method_name) ||
           !entry.method_resource_contracts.contains_key(method_name) {
            panic("impl owner: intrinsic has no method/resource contract")
        }
    }
    for resource_entry in entry.method_resource_contracts.entries() {
        let (method_name, contract) = resource_entry
        let core = match entry.method_schemes.get(method_name) {
            some(value) => value,
            none => panic("impl owner: resource contract has no method core")
        }
        let arity = match impl_method_core_type(core) {
            Type::FnType { params, .. } => params.len(),
            _ => panic("impl owner: resource contract method is not callable")
        }
        if callable_resource_contract_parameter_roles(contract).len() != arity {
            panic("impl owner: resource contract arity differs")
        }
    }
    for method_entry in entry.method_refs.entries() {
        let (method_name, method_ref) = method_entry
        if !entry.method_schemes.contains_key(method_name) ||
           method_name != impl_method_ref_name(method_ref) {
            panic("impl owner: exact method relation lost its core/name")
        }
        match entry.owner_ref {
            some(owner) => if !impl_owner_ref_same(
                    impl_method_ref_owner(method_ref), owner) {
                panic("impl owner: exact method crosses owner")
            },
            none => panic("impl owner: method ref has no typed owner")
        }
    }
    let mut type_param_names: Set<Str> = set_new()
    for name in entry.type_params {
        if name == "" || type_param_names.contains(name) {
            panic("impl owner: invalid type-parameter inventory")
        }
        type_param_names.insert(name)
    }
    match (entry.trait_name, entry.trait_ref) {
        (some(name), some(trait_ref)) => match reg.traits.get(name) {
            some(def) => if !symbol_ref_same(
                    registered_trait_ref_symbol(def.owner_ref), trait_ref) {
                panic("impl owner: declared trait identity changed")
            },
            none => panic("impl owner: declared trait is not registered")
        },
        (none, none) => {},
        _ => panic("impl owner: trait name/ref presence mismatch")
    }
    for predicate in frozen_impl_predicates(entry.predicates) {
        let trait_name = impl_predicate_trait_name(predicate)
        let trait_def = match reg.traits.get(trait_name) {
            some(def) => def,
            none => panic("impl owner: predicate trait is not registered")
        }
        for constraint in impl_predicate_assoc_constraints(predicate) {
            let declared = trait_def.assoc_types.any(fn(assoc) {
                assoc.name == impl_assoc_predicate_name(constraint)
            })
            if !declared {
                panic("impl owner: predicate associated type is not declared")
            }
        }
        let path = impl_predicate_provenance_path(
            impl_predicate_provenance(predicate))
        if path.len() > 0 {
            for index in 0..path.len() - 1 {
                let child = path.get(index).unwrap_or("")
                let parent = path.get(index + 1).unwrap_or("")
                match reg.traits.get(child) {
                    some(def) => if !def.supertraits.contains(parent) {
                        panic("impl owner: expanded predicate path is not a supertrait edge")
                    },
                    none => panic("impl owner: expanded predicate path has unknown trait")
                }
            }
        }
    }
    for method_name in entry.method_names {
        if !entry.method_schemes.contains_key(method_name) {
            panic("impl owner: explicit method inventory lost its core")
        }
    }
    for map_entry in entry.method_schemes.entries() {
        let (_, core) = map_entry
        let core_vars = impl_method_core_type_vars(core)
        for predicate in frozen_impl_predicates(entry.predicates) {
            if !core_vars.contains(
                impl_predicate_subject_type_var(predicate)) {
                panic("impl owner: method core does not quantify predicate subject")
            }
        }
    }
    match (entry.provider_ref, entry.delegate_plan.value) {
        (none, DelegatePlanStateValue::DelegateNotApplicable) => {},
        (some(provider), DelegatePlanStateValue::DelegatePending) => {
            if !impl_provider_kind_same(
                    impl_provider_ref_kind(provider),
                    impl_provider_kind_source()) {
                panic("impl owner: pending delegate plan parent is not Source")
            }
        },
        (some(provider), DelegatePlanStateValue::DelegateFinal(children)) => {
            if !impl_provider_kind_same(
                    impl_provider_ref_kind(provider),
                    impl_provider_kind_source()) {
                panic("impl owner: final delegate plan parent is not Source")
            }
            let mut previous_delegate_index = -1
            let mut seen_delegate_providers: List<ImplProviderRef> = []
            for child in children {
                if child.source_member_index < 0 ||
                   child.produced_owner_count < 0 ||
                   (child.produced_owner_count == 0 &&
                    !child.had_semantic_error) ||
                   child.source_member_index <= previous_delegate_index ||
                   !impl_provider_kind_same(
                        impl_provider_ref_kind(child.provider_ref),
                        impl_provider_kind_delegate()) {
                    panic("impl owner: invalid ordered delegate child plan")
                }
                for seen_provider in seen_delegate_providers {
                    if impl_provider_ref_same(
                            seen_provider, child.provider_ref) {
                        panic("impl owner: duplicate delegate child provider")
                    }
                }
                seen_delegate_providers.push(child.provider_ref)
                previous_delegate_index = child.source_member_index
            }
        },
        (some(provider), DelegatePlanStateValue::DelegateNotApplicable) => {
            if impl_provider_kind_same(
                    impl_provider_ref_kind(provider),
                    impl_provider_kind_source()) {
                panic("impl owner: Source provider has no final delegate plan")
            }
        },
        _ => panic("impl owner: provider/delegate plan state mismatch")
    }
    match (entry.provider_ref, entry.owner_ref) {
        (some(provider), some(owner)) => {
            if !impl_provider_ref_same(
                    impl_owner_ref_provider(owner), provider) ||
               !optional_symbol_ref_same(
                    impl_owner_ref_trait(owner), entry.trait_ref) ||
               entry.method_refs.len() != entry.method_schemes.len() {
                panic("impl owner: typed owner/method closure drifted")
            }
        },
        _ => panic("impl owner: final owner lacks typed identity")
    }
}

// The sole writer for the ordinary method index. Method shape and predicates
// live only on the referenced owner entry.
pub fn install_method_core(
    mut reg: TraitRegistry, mut sink: CollectingSink,
    target_type: Str, method_name: Str,
    core: ImplMethodSchemeCore, incoming: ImplMethodRef,
    diagnostic_span: Span
) -> Bool {
    let incoming_owner = impl_method_ref_owner(incoming)
    let owner = match find_impl_by_provider(
        reg, target_type, impl_owner_ref_trait(incoming_owner),
        impl_owner_ref_provider(incoming_owner)
    ) {
        some(found) => found,
        none => panic("impl method index: owner entry is missing")
    }
    match owner.method_schemes.get(method_name) {
        some(stored) => if !impl_method_core_same(stored, core) {
            panic("impl method index: core differs from owner")
        },
        none => panic("impl method index: owner has no method core")
    }
    match (owner.method_refs.get(method_name), owner.owner_ref) {
        (some(stored_ref), some(owner_ref)) => if
                !impl_method_ref_same(stored_ref, incoming) ||
                !impl_owner_ref_same(
                    impl_method_ref_owner(stored_ref), owner_ref) {
            panic("impl method index: exact member differs from owner")
        },
        _ => panic("impl method index: owner has no exact method relation")
    }
    let mut method_index = match reg.method_index.get(target_type) {
        some(existing) => existing,
        none => {
            let created: Map<Str, ImplMethodRef> = map_new()
            reg.method_index.insert(target_type, created)
            created
        }
    }

    match method_index.get(method_name) {
        some(existing) => {
            if impl_method_ref_same(existing, incoming) {
                method_index.insert(method_name, incoming)
                true
            } else {
                let old_owner = match impl_owner_ref_trait(
                        impl_method_ref_owner(existing)) {
                    some(trait_ref) => "trait '${nominal_display_name(
                        symbol_ref_canonical_payload(trait_ref))}'",
                    none => "an inherent impl"
                }
                let new_owner = method_owner_display(owner.trait_name)
                sink.report(make_diag(
                    E0504, Severity::SevError,
                    "Ambiguous method '${method_name}' on '${nominal_display_name(target_type)}': provided by ${old_owner} and ${new_owner}",
                    diagnostic_span,
                    DiagnosticContext::TraitError {
                        detail: "same-target method origins must be unique"
                    }))
                false
            }
        },
        none => {
            method_index.insert(method_name, incoming)
            true
        }
    }
}

pub fn add_impl(mut reg: TraitRegistry, entry: ImplEntry) {
    validate_impl_entry(reg, entry)
    match reg.trait_impls.get(entry.target_type_name) {
        some(impls) => {
            let mut matched = false
            for existing in impls {
                if impl_entry_exact_key_same(existing, entry) {
                    matched = true
                    if !impl_entry_final_same(existing, entry) {
                        panic("impl owner: same-provider replay changed frozen entry")
                    }
                }
            }
            if !matched {
                impls.push(entry)
            }
        },
        none => {
            let mut list: List<ImplEntry> = []
            list.push(entry)
            reg.trait_impls.insert(entry.target_type_name, list)
        }
    }
}

pub fn has_impl(reg: TraitRegistry, type_name: Str, trait_name: Str) -> Bool {
    match reg.trait_impls.get(type_name) {
        some(impls) => impls.any(fn(i) {
            match i.trait_name {
                some(name) => name == trait_name,
                none => false
            }
        }),
        none => false
    }
}

pub fn find_impl(reg: TraitRegistry, type_name: Str, trait_name: Str) -> ImplEntry? {
    match reg.trait_impls.get(type_name) {
        some(impls) => impls.find(fn(i) {
            match i.trait_name {
                some(name) => name == trait_name,
                none => false
            }
        }),
        none => none
    }
}

pub fn find_impl_by_provider(
    reg: TraitRegistry, type_name: Str,
    trait_ref: SymbolRef?, provider_ref: ImplProviderRef
) -> ImplEntry? {
    let mut found: ImplEntry? = none
    match reg.trait_impls.get(type_name) {
        some(impls) => {
            for entry in impls {
                if optional_symbol_ref_same(entry.trait_ref, trait_ref) {
                    match entry.provider_ref {
                        some(candidate) => if impl_provider_ref_same(
                                candidate, provider_ref) {
                            if found.is_some() {
                                panic("impl owner: typed provider key is not unique")
                            }
                            found = some(entry)
                        },
                        none => {}
                    }
                }
            }
        },
        none => {}
    }
    found
}

pub fn find_impls_by_provider(
    reg: TraitRegistry, type_name: Str, provider_ref: ImplProviderRef
) -> List<ImplEntry> {
    let mut found: List<ImplEntry> = []
    match reg.trait_impls.get(type_name) {
        some(impls) => {
            for entry in impls {
                match entry.provider_ref {
                    some(candidate) => if impl_provider_ref_same(
                            candidate, provider_ref) {
                        found.push(entry)
                    },
                    none => {}
                }
            }
        },
        none => {}
    }
    found
}

pub fn find_delegate_child_provider_plan(
    owner: ImplEntry, source_member_index: Int
) -> DelegateChildProviderPlan? {
    let mut found: DelegateChildProviderPlan? = none
    for child in delegate_plan_children(owner.delegate_plan) {
        if child.source_member_index == source_member_index {
            if found.is_some() {
                panic("impl owner: duplicate delegate child source index")
            }
            found = some(child)
        }
    }
    found
}

pub fn finalize_delegate_provider_plan(
    mut reg: TraitRegistry, type_name: Str, trait_ref: SymbolRef?,
    parent_provider_ref: ImplProviderRef,
    children: List<DelegateChildProviderPlan>
) {
    let mut matches = 0
    match reg.trait_impls.get(type_name) {
        some(impls) => {
            for index in 0..impls.len() {
                match impls.get(index) {
                    some(entry) => {
                        let provider_matches = match entry.provider_ref {
                            some(provider) => impl_provider_ref_same(
                                provider, parent_provider_ref),
                            none => false
                        }
                        if provider_matches && optional_symbol_ref_same(
                                entry.trait_ref, trait_ref) {
                            matches = matches + 1
                            if !delegate_plan_is_pending(entry.delegate_plan) {
                                panic("impl owner: delegate plan finalization replay")
                            }
                            let mut updated = entry
                            updated.delegate_plan = delegate_plan_final(children)
                            validate_impl_entry(reg, updated)
                            impls.set(index, updated)
                        }
                    },
                    none => {}
                }
            }
        },
        none => {}
    }
    if matches != 1 {
        panic("impl owner: delegate plan parent is not unique")
    }
}

pub fn assert_no_pending_delegate_plans(reg: TraitRegistry) {
    for map_entry in reg.trait_impls.entries() {
        let (_, owners) = map_entry
        for owner in owners {
            if delegate_plan_is_pending(owner.delegate_plan) {
                panic("impl owner: pending delegate plan reached close")
            }
        }
    }
}

pub fn instantiate_impl_runtime_requirements(
    entry: ImplEntry, type_args: List<Type>
) -> List<ImplRuntimeRequirement>? {
    if entry.type_param_vars.len() != type_args.len() { return none }
    let mut mapping: Map<Int, Type> = map_new()
    for index in 0..entry.type_param_vars.len() {
        match (entry.type_param_vars.get(index), type_args.get(index)) {
            (some(source), some(target)) => mapping.insert(source, target),
            _ => return none
        }
    }
    let mut requirements: List<ImplRuntimeRequirement> = []
    for predicate in frozen_impl_predicates(entry.predicates) {
        let mut constraints: List<ImplAssocPredicate> = []
        for constraint in impl_predicate_assoc_constraints(predicate) {
            constraints.push(make_impl_assoc_predicate(
                impl_assoc_predicate_name(constraint),
                apply_subst_map(mapping, impl_assoc_predicate_type(constraint))))
        }
        match type_args.get(impl_predicate_subject_param_index(predicate)) {
            some(subject) => requirements.push(ImplRuntimeRequirement {
                subject_type: subject,
                canonical_trait_name: impl_predicate_trait_name(predicate),
                assoc_constraints: constraints
            }),
            none => return none
        }
    }
    some(requirements)
}

pub fn replace_impl_method_core(
    mut reg: TraitRegistry, type_name: Str, owner_ref: ImplOwnerRef,
    method_name: Str, core: ImplMethodSchemeCore
) {
    let mut matches = 0
    match reg.trait_impls.get(type_name) {
        some(impls) => {
            for entry in impls {
                match entry.owner_ref {
                    some(candidate) => if impl_owner_ref_same(
                            candidate, owner_ref) {
                        matches = matches + 1
                        if !entry.method_schemes.contains_key(method_name) {
                            panic("impl method core: replacement target is missing")
                        }
                        entry.method_schemes.insert(method_name, core)
                    },
                    none => {}
                }
            }
        },
        none => {}
    }
    if matches != 1 {
        panic("impl method core: replacement owner is not unique")
    }
}

// ============================================================
// Map-based substitution: apply a local Map<Int, Type> mapping to a type.
// Used for local type parameter instantiation maps (not the global substitution).
// ============================================================

fn chase_type_var_map(subst: Map<Int, Type>, id: Int, depth: Int) -> Type {
    if depth > 100 { return Type::TypeVar { id: id, name: none } }
    match subst.get(id) {
        some(resolved) => match resolved {
            Type::TypeVar { id: next_id, .. } => chase_type_var_map(subst, next_id, depth + 1),
            _ => apply_subst_map(subst, resolved)
        },
        none => Type::TypeVar { id: id, name: none }
    }
}

pub fn apply_subst_map(subst: Map<Int, Type>, t: Type) -> Type {
    match t {
        Type::IntType => Type::IntType,
        Type::FloatType => Type::FloatType,
        Type::StrType => Type::StrType,
        Type::BoolType => Type::BoolType,
        Type::UnitType => Type::UnitType,
        Type::NeverType => Type::NeverType,
        Type::AnyType => Type::AnyType,
        Type::TypeVar { id, .. } => chase_type_var_map(subst, id, 0),
        Type::FnType { params, return_type, effects } =>
            Type::FnType {
                params: params.map(fn(p) { apply_subst_map(subst, p) }),
                return_type: apply_subst_map(subst, return_type),
                effects: apply_subst_row_map(subst, effects)
            },
        Type::StructType { name, type_params } =>
            Type::StructType {
                name: name,
                type_params: type_params.map(fn(p) { apply_subst_map(subst, p) })
            },
        Type::EnumType { name, type_params } =>
            Type::EnumType {
                name: name,
                type_params: type_params.map(fn(p) { apply_subst_map(subst, p) })
            },
        Type::GenericType { base, args } =>
            Type::GenericType {
                base: apply_subst_map(subst, base),
                args: args.map(fn(a) { apply_subst_map(subst, a) })
            },
        Type::RecordType { fields, tail, tail_name } => {
            let mapped_fields = fields.map(fn(f) {
                RecordField { name: f.name, ty: apply_subst_map(subst, f.ty) }
            })
            match tail {
                some(t_id) => match subst.get(t_id) {
                    some(resolved) => {
                        let chased = apply_subst_map(subst, resolved)
                        match chased {
                            Type::TypeVar { id: new_id, name: new_name } =>
                                Type::RecordType { fields: mapped_fields, tail: some(new_id), tail_name: new_name },
                            Type::RecordType { fields: extra_fields, tail: extra_tail, tail_name: extra_tn } => {
                                let mut all_fields = list_clone(mapped_fields)
                                for ef in extra_fields {
                                    all_fields.push(RecordField { name: ef.name, ty: apply_subst_map(subst, ef.ty) })
                                }
                                Type::RecordType { fields: all_fields, tail: extra_tail, tail_name: extra_tn }
                            },
                            _ => Type::RecordType { fields: mapped_fields, tail: none, tail_name: none }
                        }
                    },
                    none => Type::RecordType { fields: mapped_fields, tail: some(t_id), tail_name: tail_name }
                },
                none => Type::RecordType { fields: mapped_fields, tail: none, tail_name: tail_name }
            }
        },
        Type::EffectRowType { effects, tail } => {
            let row = apply_subst_row_map(subst, EffectRow { effects: effects, tail: tail })
            Type::EffectRowType { effects: row.effects, tail: row.tail }
        },
        Type::TupleType { elements } =>
            Type::TupleType { elements: elements.map(fn(e) { apply_subst_map(subst, e) }) },
        Type::PtrType { pointee } =>
            Type::PtrType { pointee: apply_subst_map(subst, pointee) },
        Type::ErrorType => Type::ErrorType
    }
}

pub fn apply_subst_effect_map(subst: Map<Int, Type>, e: Effect) -> Effect {
    match e {
        Effect::FailEffect { error_type } =>
            Effect::FailEffect { error_type: apply_subst_map(subst, error_type) },
        Effect::MutEffect { state_type } =>
            Effect::MutEffect { state_type: apply_subst_map(subst, state_type) },
        Effect::CustomEffect { reference, name, type_args } =>
            Effect::CustomEffect { reference: reference, name: name,
                type_args: type_args.map(fn(a) { apply_subst_map(subst, a) }) },
        Effect::SystemEffect { .. } => e,
        Effect::UnsafeEffect => Effect::UnsafeEffect
    }
}

pub fn apply_subst_row_map(subst: Map<Int, Type>, row: EffectRow) -> EffectRow {
    let effects = row.effects.map(fn(e) { apply_subst_effect_map(subst, e) })
    match row.tail {
        some(t_id) => match subst.get(t_id) {
            some(resolved) => {
                let chased = apply_subst_map(subst, resolved)
                match chased {
                    Type::TypeVar { id: new_id, .. } =>
                        EffectRow { effects: effects, tail: some(new_id) },
                    Type::EffectRowType { effects: extra_effs, tail: extra_tail } => {
                        let mut merged = list_clone(effects)
                        for ee in extra_effs {
                            merged.push(apply_subst_effect_map(subst, ee))
                        }
                        EffectRow { effects: merged, tail: extra_tail }
                    },
                    _ => EffectRow { effects: effects, tail: none }
                }
            },
            none => EffectRow { effects: effects, tail: some(t_id) }
        },
        none => EffectRow { effects: effects, tail: none }
    }
}

// Type-alias schemas use definition-local negative variable IDs.  Unlike the
// ordinary local substitution above, instantiation is deliberately one pass:
// a live call-site TypeVar inserted for one schema key must not be chased as
// though it were another definition-local key.
fn apply_schema_effect_once(subst: Map<Int, Type>, eff: Effect) -> Effect {
    match eff {
        Effect::FailEffect { error_type } => Effect::FailEffect {
            error_type: apply_schema_subst_once(subst, error_type)
        },
        Effect::MutEffect { state_type } => Effect::MutEffect {
            state_type: apply_schema_subst_once(subst, state_type)
        },
        Effect::CustomEffect { reference, name, type_args } =>
            Effect::CustomEffect {
                reference: reference, name: name,
                type_args: type_args.map(fn(arg) {
                    apply_schema_subst_once(subst, arg)
                })
            },
        Effect::SystemEffect { .. } => eff,
        Effect::UnsafeEffect => Effect::UnsafeEffect
    }
}

fn apply_schema_row_once(
    subst: Map<Int, Type>, row: EffectRow
) -> EffectRow {
    let effects = row.effects.map(fn(eff) {
        apply_schema_effect_once(subst, eff)
    })
    match row.tail {
        some(id) => match subst.get(id) {
            some(Type::TypeVar { id: mapped, .. }) =>
                EffectRow { effects: effects, tail: some(mapped) },
            some(Type::EffectRowType {
                effects: extra_effects, tail: extra_tail
            }) => {
                let mut merged = list_clone(effects)
                for eff in extra_effects { merged.push(eff) }
                EffectRow { effects: merged, tail: extra_tail }
            },
            some(_) => EffectRow { effects: effects, tail: none },
            none => EffectRow { effects: effects, tail: some(id) }
        },
        none => EffectRow { effects: effects, tail: none }
    }
}

fn apply_schema_subst_once(
    subst: Map<Int, Type>, ty: Type
) -> Type {
    match ty {
        Type::IntType => Type::IntType,
        Type::FloatType => Type::FloatType,
        Type::StrType => Type::StrType,
        Type::BoolType => Type::BoolType,
        Type::UnitType => Type::UnitType,
        Type::NeverType => Type::NeverType,
        Type::AnyType => Type::AnyType,
        Type::TypeVar { id, name } => match subst.get(id) {
            some(mapped) => mapped,
            none => Type::TypeVar { id: id, name: name }
        },
        Type::FnType { params, return_type, effects } => Type::FnType {
            params: params.map(fn(param) {
                apply_schema_subst_once(subst, param)
            }),
            return_type: apply_schema_subst_once(subst, return_type),
            effects: apply_schema_row_once(subst, effects)
        },
        Type::StructType { name, type_params } => Type::StructType {
            name: name,
            type_params: type_params.map(fn(param) {
                apply_schema_subst_once(subst, param)
            })
        },
        Type::EnumType { name, type_params } => Type::EnumType {
            name: name,
            type_params: type_params.map(fn(param) {
                apply_schema_subst_once(subst, param)
            })
        },
        Type::GenericType { base, args } => Type::GenericType {
            base: apply_schema_subst_once(subst, base),
            args: args.map(fn(arg) {
                apply_schema_subst_once(subst, arg)
            })
        },
        Type::RecordType { fields, tail, tail_name } => {
            let mapped_fields = fields.map(fn(field) {
                RecordField {
                    name: field.name,
                    ty: apply_schema_subst_once(subst, field.ty)
                }
            })
            match tail {
                some(id) => match subst.get(id) {
                    some(Type::TypeVar { id: mapped, name }) =>
                        Type::RecordType {
                            fields: mapped_fields, tail: some(mapped),
                            tail_name: name
                        },
                    some(Type::RecordType {
                        fields: extra_fields, tail: extra_tail,
                        tail_name: extra_tail_name
                    }) => {
                        let mut merged = list_clone(mapped_fields)
                        for field in extra_fields { merged.push(field) }
                        Type::RecordType {
                            fields: merged, tail: extra_tail,
                            tail_name: extra_tail_name
                        }
                    },
                    some(_) => Type::RecordType {
                        fields: mapped_fields, tail: none, tail_name: none
                    },
                    none => Type::RecordType {
                        fields: mapped_fields, tail: some(id),
                        tail_name: tail_name
                    }
                },
                none => Type::RecordType {
                    fields: mapped_fields, tail: none, tail_name: tail_name
                }
            }
        },
        Type::EffectRowType { effects, tail } => {
            let row = apply_schema_row_once(
                subst, EffectRow { effects: effects, tail: tail })
            Type::EffectRowType { effects: row.effects, tail: row.tail }
        },
        Type::TupleType { elements } => Type::TupleType {
            elements: elements.map(fn(element) {
                apply_schema_subst_once(subst, element)
            })
        },
        Type::PtrType { pointee } => Type::PtrType {
            pointee: apply_schema_subst_once(subst, pointee)
        },
        Type::ErrorType => Type::ErrorType
    }
}

// ============================================================
// Shared structural TypeVar mapping
// ============================================================

fn collect_effect_var_mappings(
    source_row: EffectRow, target_row: EffectRow,
    source_vars: Set<Int>, mut result: Map<Int, Type>
) {
    match (source_row.tail, target_row.tail) {
        (some(source_id), some(target_id)) => {
            if source_vars.contains(source_id) {
                result.insert(source_id, Type::TypeVar {
                    id: target_id, name: none
                })
            }
        },
        _ => {}
    }

    for source_effect in source_row.effects {
        for target_effect in target_row.effects {
            if effects_match_kind(source_effect, target_effect) {
                match (source_effect, target_effect) {
                    (Effect::FailEffect { error_type: source_type },
                     Effect::FailEffect { error_type: target_type }) =>
                        collect_var_mappings(
                            source_type, target_type, source_vars, result),
                    (Effect::MutEffect { state_type: source_type },
                     Effect::MutEffect { state_type: target_type }) =>
                        collect_var_mappings(
                            source_type, target_type, source_vars, result),
                    (Effect::CustomEffect { type_args: source_args, .. },
                     Effect::CustomEffect { type_args: target_args, .. }) => {
                        let mut i = 0
                        while i < source_args.len() && i < target_args.len() {
                            match (source_args.get(i), target_args.get(i)) {
                                (some(source_arg), some(target_arg)) =>
                                    collect_var_mappings(
                                        source_arg, target_arg,
                                        source_vars, result),
                                _ => {}
                            }
                            i = i + 1
                        }
                    },
                    _ => {}
                }
            }
        }
    }
}

fn collect_var_mappings(
    source_type: Type, target_type: Type,
    source_vars: Set<Int>, mut result: Map<Int, Type>
) {
    match source_type {
        Type::TypeVar { id, .. } => {
            if source_vars.contains(id) {
                result.insert(id, target_type)
            }
        },
        Type::StructType { name: source_name, type_params: source_params } =>
            match target_type {
                Type::StructType {
                    name: target_name, type_params: target_params
                } => {
                    if source_name == target_name {
                        let mut i = 0
                        while i < source_params.len() && i < target_params.len() {
                            match (source_params.get(i), target_params.get(i)) {
                                (some(source_param), some(target_param)) =>
                                    collect_var_mappings(
                                        source_param, target_param,
                                        source_vars, result),
                                _ => {}
                            }
                            i = i + 1
                        }
                    }
                },
                _ => {}
            },
        Type::EnumType { name: source_name, type_params: source_params } =>
            match target_type {
                Type::EnumType {
                    name: target_name, type_params: target_params
                } => {
                    if source_name == target_name {
                        let mut i = 0
                        while i < source_params.len() && i < target_params.len() {
                            match (source_params.get(i), target_params.get(i)) {
                                (some(source_param), some(target_param)) =>
                                    collect_var_mappings(
                                        source_param, target_param,
                                        source_vars, result),
                                _ => {}
                            }
                            i = i + 1
                        }
                    }
                },
                _ => {}
            },
        Type::FnType {
            params: source_params, return_type: source_return,
            effects: source_effects
        } => match target_type {
            Type::FnType {
                params: target_params, return_type: target_return,
                effects: target_effects
            } => {
                let mut i = 0
                while i < source_params.len() && i < target_params.len() {
                    match (source_params.get(i), target_params.get(i)) {
                        (some(source_param), some(target_param)) =>
                            collect_var_mappings(
                                source_param, target_param,
                                source_vars, result),
                        _ => {}
                    }
                    i = i + 1
                }
                collect_var_mappings(
                    source_return, target_return, source_vars, result)
                collect_effect_var_mappings(
                    source_effects, target_effects, source_vars, result)
            },
            _ => {}
        },
        Type::TupleType { elements: source_elements } => match target_type {
            Type::TupleType { elements: target_elements } => {
                let mut i = 0
                while i < source_elements.len() && i < target_elements.len() {
                    match (source_elements.get(i), target_elements.get(i)) {
                        (some(source_element), some(target_element)) =>
                            collect_var_mappings(
                                source_element, target_element,
                                source_vars, result),
                        _ => {}
                    }
                    i = i + 1
                }
            },
            _ => {}
        },
        Type::GenericType { base: source_base, args: source_args } =>
            match target_type {
                Type::GenericType { base: target_base, args: target_args } => {
                    collect_var_mappings(
                        source_base, target_base, source_vars, result)
                    let mut i = 0
                    while i < source_args.len() && i < target_args.len() {
                        match (source_args.get(i), target_args.get(i)) {
                            (some(source_arg), some(target_arg)) =>
                                collect_var_mappings(
                                    source_arg, target_arg,
                                    source_vars, result),
                            _ => {}
                        }
                        i = i + 1
                    }
                },
                _ => {}
            },
        Type::RecordType { fields: source_fields, tail: source_tail, .. } =>
            match target_type {
                Type::RecordType { fields: target_fields, tail: target_tail, .. } => {
                    for source_field in source_fields {
                        match target_fields.find(fn(field) {
                            field.name == source_field.name
                        }) {
                            some(target_field) => collect_var_mappings(
                                source_field.ty, target_field.ty,
                                source_vars, result),
                            none => {}
                        }
                    }
                    match (source_tail, target_tail) {
                        (some(source_id), some(target_id)) => {
                            if source_vars.contains(source_id) {
                                result.insert(source_id, Type::TypeVar {
                                    id: target_id, name: none
                                })
                            }
                        },
                        _ => {}
                    }
                },
                _ => {}
            },
        Type::PtrType { pointee: source_pointee } => match target_type {
            Type::PtrType { pointee: target_pointee } =>
                collect_var_mappings(
                    source_pointee, target_pointee, source_vars, result),
            _ => {}
        },
        Type::EffectRowType {
            effects: source_effects, tail: source_tail
        } => match target_type {
            Type::EffectRowType {
                effects: target_effects, tail: target_tail
            } => collect_effect_var_mappings(
                EffectRow { effects: source_effects, tail: source_tail },
                EffectRow { effects: target_effects, tail: target_tail },
                source_vars, result),
            _ => {}
        },
        _ => {}
    }
}

pub fn build_type_var_map(
    source_type: Type, target_type: Type, source_var_ids: List<Int>
) -> Map<Int, Type> {
    let mut result: Map<Int, Type> = map_new()
    collect_var_mappings(
        source_type, target_type, set_from(source_var_ids), result)
    result
}

pub fn build_scheme_var_map(
    scheme: TypeScheme, instantiated_type: Type
) -> Map<Int, Type> {
    build_type_var_map(scheme.ty, instantiated_type, scheme.type_vars)
}

fn append_ordered_type_var(mut result: List<Int>, id: Int) {
    if !result.contains(id) { result.push(id) }
}

fn collect_ordered_effect_vars(
    eff: Effect, mut result: List<Int>
) {
    match eff {
        Effect::FailEffect { error_type } =>
            collect_ordered_type_var_ids(error_type, result),
        Effect::MutEffect { state_type } =>
            collect_ordered_type_var_ids(state_type, result),
        Effect::CustomEffect { type_args, .. } => {
            for arg in type_args {
                collect_ordered_type_var_ids(arg, result)
            }
        },
        Effect::SystemEffect { .. } | Effect::UnsafeEffect => {}
    }
}

fn collect_ordered_effect_row_vars(
    row: EffectRow, mut result: List<Int>
) {
    for eff in row.effects {
        collect_ordered_effect_vars(eff, result)
    }
    match row.tail {
        some(id) => append_ordered_type_var(result, id),
        none => {}
    }
}

fn collect_ordered_type_var_ids(
    ty: Type, mut result: List<Int>
) {
    match ty {
        Type::TypeVar { id, .. } => append_ordered_type_var(result, id),
        Type::FnType { params, return_type, effects } => {
            for param in params {
                collect_ordered_type_var_ids(param, result)
            }
            collect_ordered_type_var_ids(return_type, result)
            collect_ordered_effect_row_vars(effects, result)
        },
        Type::StructType { type_params, .. } |
        Type::EnumType { type_params, .. } => {
            for param in type_params {
                collect_ordered_type_var_ids(param, result)
            }
        },
        Type::GenericType { base, args } => {
            collect_ordered_type_var_ids(base, result)
            for arg in args { collect_ordered_type_var_ids(arg, result) }
        },
        Type::RecordType { fields, tail, .. } => {
            for field in fields {
                collect_ordered_type_var_ids(field.ty, result)
            }
            match tail {
                some(id) => append_ordered_type_var(result, id),
                none => {}
            }
        },
        Type::EffectRowType { effects, tail } =>
            collect_ordered_effect_row_vars(
                EffectRow { effects: effects, tail: tail }, result),
        Type::TupleType { elements } => {
            for element in elements {
                collect_ordered_type_var_ids(element, result)
            }
        },
        Type::PtrType { pointee } =>
            collect_ordered_type_var_ids(pointee, result),
        _ => {}
    }
}

fn collect_type_var_ids(ty: Type, mut result: Set<Int>) {
    let mut ordered: List<Int> = []
    collect_ordered_type_var_ids(ty, ordered)
    for id in ordered { result.insert(id) }
}

fn collect_effect_tail_ids_in_type(
    ty: Type, mut result: List<Int>
) {
    match ty {
        Type::FnType { params, return_type, effects } => {
            for param in params {
                collect_effect_tail_ids_in_type(param, result)
            }
            collect_effect_tail_ids_in_type(return_type, result)
            for atom in effects.effects {
                collect_effect_tail_ids_in_atom(atom, result)
            }
            match effects.tail {
                some(id) => append_ordered_type_var(result, id),
                none => {}
            }
        },
        Type::StructType { type_params, .. } |
        Type::EnumType { type_params, .. } => {
            for param in type_params {
                collect_effect_tail_ids_in_type(param, result)
            }
        },
        Type::GenericType { base, args } => {
            collect_effect_tail_ids_in_type(base, result)
            for arg in args { collect_effect_tail_ids_in_type(arg, result) }
        },
        Type::RecordType { fields, .. } => {
            for field in fields {
                collect_effect_tail_ids_in_type(field.ty, result)
            }
        },
        Type::EffectRowType { effects, tail } => {
            for atom in effects {
                collect_effect_tail_ids_in_atom(atom, result)
            }
            match tail {
                some(id) => append_ordered_type_var(result, id),
                none => {}
            }
        },
        Type::TupleType { elements } => {
            for element in elements {
                collect_effect_tail_ids_in_type(element, result)
            }
        },
        Type::PtrType { pointee } =>
            collect_effect_tail_ids_in_type(pointee, result),
        _ => {}
    }
}

fn collect_effect_tail_ids_in_atom(
    atom: Effect, mut result: List<Int>
) {
    match atom {
        Effect::FailEffect { error_type } =>
            collect_effect_tail_ids_in_type(error_type, result),
        Effect::MutEffect { state_type } =>
            collect_effect_tail_ids_in_type(state_type, result),
        Effect::CustomEffect { type_args, .. } => {
            for argument in type_args {
                collect_effect_tail_ids_in_type(argument, result)
            }
        },
        Effect::SystemEffect { .. } | Effect::UnsafeEffect => {}
    }
}

pub fn ordered_effect_tail_vars(value: Type) -> List<Int> {
    let result: List<Int> = []
    collect_effect_tail_ids_in_type(value, result)
    result
}

fn fresh_mapping_for_ids(
    mut env: TypeEnv, ids: List<Int>, mut mapping: Map<Int, Type>
) {
    for id in ids {
        if !mapping.contains_key(id) {
            mapping.insert(id, env.fresh_var())
        }
    }
}

pub fn freshen_effect_header_types(
    mut env: TypeEnv, values: List<Type>
) -> List<Type> {
    let mut tails: List<Int> = []
    for value in values {
        for tail in ordered_effect_tail_vars(value) {
            append_ordered_type_var(tails, tail)
        }
    }
    let mapping: Map<Int, Type> = map_new()
    fresh_mapping_for_ids(env, tails, mapping)
    values.map(fn(value) { apply_subst_map(mapping, value) })
}

pub fn freshen_effect_header(mut env: TypeEnv, value: Type) -> Type {
    freshen_effect_header_types(env, [value]).get(0).unwrap()
}

fn collect_value_type_vars_in_atom(
    atom: Effect, mut result: Set<Int>
) {
    match atom {
        Effect::FailEffect { error_type } =>
            collect_value_type_vars(error_type, result),
        Effect::MutEffect { state_type } =>
            collect_value_type_vars(state_type, result),
        Effect::CustomEffect { type_args, .. } => {
            for argument in type_args {
                collect_value_type_vars(argument, result)
            }
        },
        Effect::SystemEffect { .. } | Effect::UnsafeEffect => {}
    }
}

fn collect_value_type_vars(ty: Type, mut result: Set<Int>) {
    match ty {
        Type::TypeVar { id, .. } => { result.insert(id) },
        Type::FnType { params, return_type, effects } => {
            for param in params { collect_value_type_vars(param, result) }
            collect_value_type_vars(return_type, result)
            for atom in effects.effects {
                collect_value_type_vars_in_atom(atom, result)
            }
        },
        Type::StructType { type_params, .. } |
        Type::EnumType { type_params, .. } => {
            for param in type_params { collect_value_type_vars(param, result) }
        },
        Type::GenericType { base, args } => {
            collect_value_type_vars(base, result)
            for arg in args { collect_value_type_vars(arg, result) }
        },
        Type::RecordType { fields, .. } => {
            for field in fields { collect_value_type_vars(field.ty, result) }
        },
        Type::EffectRowType { effects, .. } => {
            for atom in effects {
                collect_value_type_vars_in_atom(atom, result)
            }
        },
        Type::TupleType { elements } => {
            for element in elements { collect_value_type_vars(element, result) }
        },
        Type::PtrType { pointee } => collect_value_type_vars(pointee, result),
        _ => {}
    }
}

// HIR Call.type_args transports only ordinary type generics.  Row-tail
// formals are carried by CoreEffectInstantiation; payload variables inside
// fail<T>/mut<T>/custom<T> remain ordinary type generics.
pub fn scheme_value_type_vars(value: TypeScheme) -> List<Int> {
    let used: Set<Int> = set_new()
    collect_value_type_vars(value.ty, used)
    let mut result: List<Int> = []
    for id in value.type_vars {
        if used.contains(id) { result.push(id) }
    }
    result
}

fn extend_mapping_for_type(
    mut env: TypeEnv, value: Type, mut mapping: Map<Int, Type>
) {
    let mut ids: List<Int> = []
    collect_ordered_type_var_ids(value, ids)
    fresh_mapping_for_ids(env, ids, mapping)
}

fn mapped_var_ids(mapping: Map<Int, Type>, ids: List<Int>) -> List<Int> {
    ids.map(fn(id) {
        match mapping.get(id) {
            some(Type::TypeVar { id: mapped, .. }) => mapped,
            _ => panic("import header localization: formal was not freshened")
        }
    })
}

pub fn localize_imported_struct_def(
    mut env: TypeEnv, value: StructDef
) -> StructDef {
    let base: Map<Int, Type> = map_new()
    fresh_mapping_for_ids(env, value.type_param_vars, base)
    let mut fields: List<StructField> = []
    for field in value.fields {
        let mapping = map_clone(base)
        extend_mapping_for_type(env, field.ty, mapping)
        fields.push(StructField {
            name: field.name, ty: apply_subst_map(mapping, field.ty),
            is_pub: field.is_pub, field_ref: field.field_ref,
            field_index: field.field_index, span: field.span
        })
    }
    StructDef {
        name: value.name, owner_ref: value.owner_ref,
        type_params: value.type_params,
        type_param_vars: mapped_var_ids(base, value.type_param_vars),
        fields: fields, derive_attrs: value.derive_attrs,
        derived_provider_plan: value.derived_provider_plan,
        resource_storage_parameter_ordinals:
            value.resource_storage_parameter_ordinals,
        is_extern: value.is_extern
    }
}

pub fn localize_imported_enum_def(
    mut env: TypeEnv, value: EnumDef
) -> EnumDef {
    let base: Map<Int, Type> = map_new()
    fresh_mapping_for_ids(env, value.type_param_vars, base)
    let mut variants: List<EnumVariant> = []
    for variant in value.variants {
        let mut fields: List<Type> = []
        for field in variant.fields {
            let mapping = map_clone(base)
            extend_mapping_for_type(env, field, mapping)
            fields.push(apply_subst_map(mapping, field))
        }
        variants.push(EnumVariant {
            name: variant.name, fields: fields,
            field_names: variant.field_names
        })
    }
    EnumDef {
        name: value.name, owner_ref: value.owner_ref,
        type_params: value.type_params,
        type_param_vars: mapped_var_ids(base, value.type_param_vars),
        variants: variants, variant_refs: value.variant_refs,
        variant_field_refs: value.variant_field_refs,
        derive_attrs: value.derive_attrs,
        derived_provider_plan: value.derived_provider_plan,
        variant_index: value.variant_index
    }
}

pub fn localize_imported_effect_def(
    mut env: TypeEnv, value: EffectDef
) -> EffectDef {
    let base: Map<Int, Type> = map_new()
    fresh_mapping_for_ids(env, value.type_param_vars, base)
    let mut ops: List<EffectOpDef> = []
    for op in value.ops {
        let mapping = map_clone(base)
        for param in op.params { extend_mapping_for_type(env, param, mapping) }
        extend_mapping_for_type(env, op.return_type, mapping)
        ops.push(EffectOpDef {
            name: op.name, operation_ref: op.operation_ref,
            params: op.params.map(fn(param) {
                apply_subst_map(mapping, param)
            }),
            return_type: apply_subst_map(mapping, op.return_type)
        })
    }
    EffectDef {
        name: value.name, owner_ref: value.owner_ref,
        handled_ref: value.handled_ref, type_params: value.type_params,
        type_param_vars: mapped_var_ids(base, value.type_param_vars),
        ops: ops, built_in_kind: value.built_in_kind
    }
}

pub fn localize_imported_trait_def(
    mut env: TypeEnv, value: TraitDef
) -> TraitDef {
    let base: Map<Int, Type> = map_new()
    fresh_mapping_for_ids(env, value.type_param_vars, base)
    fresh_mapping_for_ids(env, [value.self_type_var_id], base)
    for assoc in value.assoc_types {
        fresh_mapping_for_ids(env, [assoc.var_id], base)
    }

    let mut methods: List<TraitMethodDef> = []
    let mut method_contracts: List<RegisteredTraitMethodContract> = []
    for method in value.methods {
        let mapping = map_clone(base)
        extend_mapping_for_type(env, method.ty, mapping)
        let localized = apply_subst_map(mapping, method.ty)
        methods.push(TraitMethodDef {
            name: method.name, method_ref: method.method_ref,
            ty: localized, has_default: method.has_default,
            param_mutabilities: method.param_mutabilities,
            method_type_params: method.method_type_params
        })
        method_contracts.push(make_registered_trait_method_contract(
            method.method_ref, localized, method.has_default,
            method.param_mutabilities))
    }

    let mut assoc_types: List<AssocTypeDef> = []
    let mut assoc_contracts: List<RegisteredTraitAssocContract> = []
    let mut assoc_index = 0
    while assoc_index < value.assoc_types.len() {
        let assoc = value.assoc_types.get(assoc_index).unwrap()
        let contract = value.contract.assoc_items.get(assoc_index).unwrap()
        let mapping = map_clone(base)
        match assoc.default_type {
            some(default_type) => extend_mapping_for_type(
                env, default_type, mapping),
            none => {}
        }
        let localized_default = assoc.default_type.map(fn(default_type) {
            apply_subst_map(mapping, default_type)
        })
        let localized_id = mapped_var_ids(base, [assoc.var_id]).get(0).unwrap()
        let localized_value = apply_subst_map(mapping, contract.value_type)
        assoc_types.push(AssocTypeDef {
            name: assoc.name, member_ref: assoc.member_ref,
            bounds: assoc.bounds, default_type: localized_default,
            var_id: localized_id
        })
        assoc_contracts.push(make_registered_trait_assoc_contract(
            contract.member, localized_value, localized_default,
            contract.bound_traits))
        assoc_index = assoc_index + 1
    }

    let contract = make_registered_trait_contract(
        value.owner_ref, method_contracts, assoc_contracts,
        value.contract.handled_effect_obligations,
        value.contract.dict_obligations)
    TraitDef {
        name: value.name, owner_ref: value.owner_ref,
        type_params: value.type_params,
        type_param_vars: mapped_var_ids(base, value.type_param_vars),
        self_type_var_id:
            mapped_var_ids(base, [value.self_type_var_id]).get(0).unwrap(),
        methods: methods, supertraits: value.supertraits,
        assoc_types: assoc_types, contract: contract
    }
}

pub fn instantiate_trait_method_signature(
    mut env: TypeEnv, method: TraitMethodDef
) -> Type {
    let mut ids: List<Int> = []
    collect_ordered_type_var_ids(method.ty, ids)
    let mapping: Map<Int, Type> = map_new()
    fresh_mapping_for_ids(env, ids, mapping)
    apply_subst_map(mapping, method.ty)
}

pub fn make_type_alias_def(
    name: Str, owner_ref: SymbolRef,
    type_params: List<Str>, raw_type_param_vars: List<Int>, raw_ty: Type
) -> TypeAliasDef {
    if type_params.len() != raw_type_param_vars.len() {
        panic("type alias schema: explicit parameter census differs")
    }
    let mut raw_schema_vars = list_clone(raw_type_param_vars)
    let mut explicit_index = 0
    while explicit_index < raw_type_param_vars.len() {
        let raw_id = raw_type_param_vars.get(explicit_index).unwrap()
        let mut prior = 0
        while prior < explicit_index {
            if raw_type_param_vars.get(prior).unwrap() == raw_id {
                panic("type alias schema: explicit parameter repeats")
            }
            prior = prior + 1
        }
        explicit_index = explicit_index + 1
    }
    collect_ordered_type_var_ids(raw_ty, raw_schema_vars)

    let mut normalization: Map<Int, Type> = map_new()
    let mut schema_vars: List<Int> = []
    let mut index = 0
    while index < raw_schema_vars.len() {
        let canonical_id = -1 - index
        normalization.insert(
            raw_schema_vars.get(index).unwrap(),
            Type::TypeVar { id: canonical_id, name: none })
        schema_vars.push(canonical_id)
        index = index + 1
    }
    let mut type_param_vars: List<Int> = []
    for raw_id in raw_type_param_vars {
        match normalization.get(raw_id) {
            some(Type::TypeVar { id, .. }) => type_param_vars.push(id),
            _ => panic("type alias schema: explicit parameter was not normalized")
        }
    }
    TypeAliasDef {
        name: name, owner_ref: owner_ref,
        type_params: type_params, type_param_vars: type_param_vars,
        schema_vars: schema_vars,
        ty: apply_schema_subst_once(normalization, raw_ty)
    }
}

pub fn instantiate_type_alias_schema(
    mut env: TypeEnv, alias: TypeAliasDef, resolved_args: List<Type>
) -> Type {
    if alias.type_params.len() != alias.type_param_vars.len() ||
       alias.type_param_vars.len() > alias.schema_vars.len() {
        panic("type alias schema: explicit parameter census differs")
    }
    let mut mapping: Map<Int, Type> = map_new()
    let mut index = 0
    while index < alias.schema_vars.len() {
        let schema_id = alias.schema_vars.get(index).unwrap()
        if schema_id != -1 - index {
            panic("type alias schema: variable IDs are not canonical")
        }
        if index < alias.type_param_vars.len() &&
           alias.type_param_vars.get(index).unwrap() != schema_id {
            panic("type alias schema: explicit parameters are not a prefix")
        }
        let replacement = if index < alias.type_param_vars.len() &&
                                  index < resolved_args.len() {
            resolved_args.get(index).unwrap()
        } else {
            env.fresh_var()
        }
        mapping.insert(schema_id, replacement)
        index = index + 1
    }
    apply_schema_subst_once(mapping, alias.ty)
}

// Specialize a trait declaration method for one concrete/generic impl owner.
// Default methods and built-in impl entries share this exact construction.
pub fn specialize_trait_method_scheme(
    trait_def: TraitDef, method: TraitMethodDef,
    self_type: Type, trait_type_args: List<Type>,
    impl_type_vars: List<Int>, assoc_types: Map<Str, Type>
) -> ImplMethodSchemeCore {
    let mut mapping: Map<Int, Type> = map_new()
    match method.ty {
        Type::FnType { params, .. } => match params.first() {
            some(receiver) => {
                let mut receiver_vars: Set<Int> = set_new()
                collect_type_var_ids(receiver, receiver_vars)
                let receiver_map = build_type_var_map(
                    receiver, self_type, receiver_vars.to_list())
                let mut receiver_ids = receiver_map.keys()
                receiver_ids.sort()
                for id in receiver_ids {
                    match receiver_map.get(id) {
                        some(mapped) => mapping.insert(id, mapped),
                        none => {}
                    }
                }
            },
            none => {}
        },
        _ => {}
    }

    let mut trait_index = 0
    while trait_index < trait_def.type_params.len() &&
          trait_index < trait_def.type_param_vars.len() &&
          trait_index < trait_type_args.len() {
        match (trait_def.type_param_vars.get(trait_index),
               trait_type_args.get(trait_index)) {
            (some(source_id), some(target_type)) =>
                mapping.insert(source_id, target_type),
            _ => {}
        }
        trait_index = trait_index + 1
    }
    for assoc_def in trait_def.assoc_types {
        match assoc_types.get(assoc_def.name) {
            some(concrete) => mapping.insert(assoc_def.var_id, concrete),
            none => {}
        }
    }

    let specialized_type = apply_subst_map(mapping, method.ty)
    let mut quantified = list_clone(impl_type_vars)
    let mut remaining: Set<Int> = set_new()
    collect_type_var_ids(specialized_type, remaining)
    let mut remaining_ids = remaining.to_list()
    remaining_ids.sort()
    for id in remaining_ids {
        if !quantified.contains(id) { quantified.push(id) }
    }
    make_impl_method_scheme_core(specialized_type, quantified, none)
}

// ============================================================
// Union-Find substitution: apply UnionFind-based substitution to a type.
// This is the primary apply_subst used by the type inference engine.
// Uses uf_find for O(alpha(n)) path-compressed type variable resolution.
// ============================================================

pub fn apply_subst(subst: UnionFind, t: Type) -> Type {
    match t {
        Type::IntType => Type::IntType,
        Type::FloatType => Type::FloatType,
        Type::StrType => Type::StrType,
        Type::BoolType => Type::BoolType,
        Type::UnitType => Type::UnitType,
        Type::NeverType => Type::NeverType,
        Type::AnyType => Type::AnyType,
        Type::TypeVar { id, name } => match uf_lookup(subst, id) {
            some(resolved) => apply_subst(subst, resolved),
            none => {
                // Always construct a new TypeVar to avoid returning borrowed `t`.
                // Perceus treats Call results as owned and inserts scope-end Drop;
                // returning the borrowed parameter `t` would cause UAF on the
                // original holder (UF table / effect list).
                let root = uf_find(subst, id)
                Type::TypeVar { id: root, name: name }
            }
        },
        Type::FnType { params, return_type, effects } =>
            Type::FnType {
                params: params.map(fn(p) { apply_subst(subst, p) }),
                return_type: apply_subst(subst, return_type),
                effects: apply_subst_row(subst, effects)
            },
        Type::StructType { name, type_params } =>
            Type::StructType {
                name: name,
                type_params: type_params.map(fn(p) { apply_subst(subst, p) })
            },
        Type::EnumType { name, type_params } =>
            Type::EnumType {
                name: name,
                type_params: type_params.map(fn(p) { apply_subst(subst, p) })
            },
        Type::GenericType { base, args } =>
            Type::GenericType {
                base: apply_subst(subst, base),
                args: args.map(fn(a) { apply_subst(subst, a) })
            },
        Type::RecordType { fields, tail, tail_name } => {
            let mapped_fields = fields.map(fn(f) {
                RecordField { name: f.name, ty: apply_subst(subst, f.ty) }
            })
            match tail {
                some(t_id) => {
                    let root_id = uf_find(subst, t_id)
                    match uf_lookup(subst, root_id) {
                        some(resolved) => {
                            let chased = apply_subst(subst, resolved)
                            match chased {
                                Type::TypeVar { id: new_id, name: new_name } =>
                                    Type::RecordType { fields: mapped_fields, tail: some(new_id), tail_name: new_name },
                                Type::RecordType { fields: extra_fields, tail: extra_tail, tail_name: extra_tn } => {
                                    let mut all_fields = list_clone(mapped_fields)
                                    for ef in extra_fields {
                                        all_fields.push(RecordField { name: ef.name, ty: apply_subst(subst, ef.ty) })
                                    }
                                    Type::RecordType { fields: all_fields, tail: extra_tail, tail_name: extra_tn }
                                },
                                _ => Type::RecordType { fields: mapped_fields, tail: none, tail_name: none }
                            }
                        },
                        none => {
                            let actual_id = if root_id == t_id { t_id } else { root_id }
                            Type::RecordType { fields: mapped_fields, tail: some(actual_id), tail_name: tail_name }
                        }
                    }
                },
                none => Type::RecordType { fields: mapped_fields, tail: none, tail_name: tail_name }
            }
        },
        Type::EffectRowType { effects, tail } => {
            let row = apply_subst_row(subst, EffectRow { effects: effects, tail: tail })
            Type::EffectRowType { effects: row.effects, tail: row.tail }
        },
        Type::TupleType { elements } =>
            Type::TupleType { elements: elements.map(fn(e) { apply_subst(subst, e) }) },
        Type::PtrType { pointee } =>
            Type::PtrType { pointee: apply_subst(subst, pointee) },
        Type::ErrorType => Type::ErrorType
    }
}

fn apply_subst_effect(subst: UnionFind, e: Effect) -> Effect {
    match e {
        Effect::FailEffect { error_type } =>
            Effect::FailEffect { error_type: apply_subst(subst, error_type) },
        Effect::MutEffect { state_type } =>
            Effect::MutEffect { state_type: apply_subst(subst, state_type) },
        Effect::CustomEffect { reference, name, type_args } =>
            Effect::CustomEffect { reference: reference, name: name,
                type_args: type_args.map(fn(a) { apply_subst(subst, a) }) },
        Effect::SystemEffect { .. } => e,
        Effect::UnsafeEffect => Effect::UnsafeEffect
    }
}

pub fn apply_subst_row(subst: UnionFind, row: EffectRow) -> EffectRow {
    let effects = row.effects.map(fn(e) { apply_subst_effect(subst, e) })
    match row.tail {
        some(t_id) => {
            let root_id = uf_find(subst, t_id)
            match uf_lookup(subst, root_id) {
                some(resolved) => {
                    let chased = apply_subst(subst, resolved)
                    match chased {
                        Type::TypeVar { id: new_id, .. } =>
                            EffectRow { effects: effects, tail: some(new_id) },
                        Type::EffectRowType { effects: extra_effs, tail: extra_tail } => {
                            let mut merged = list_clone(effects)
                            for ee in extra_effs {
                                merged.push(apply_subst_effect(subst, ee))
                            }
                            EffectRow { effects: merged, tail: extra_tail }
                        },
                        _ => EffectRow { effects: effects, tail: none }
                    }
                },
                none => {
                    let actual_id = if root_id == t_id { t_id } else { root_id }
                    EffectRow { effects: effects, tail: some(actual_id) }
                }
            }
        },
        none => EffectRow { effects: effects, tail: none }
    }
}
