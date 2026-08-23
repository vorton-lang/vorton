// Exact 0.1 delegate TypedPlan.
//
// The resolver/checker supplies every typed identity and body-local slot.  This
// module only validates the closed full-trait forwarding relation.  It never
// resolves a name/span, discovers a provider, fills a missing method, permits a
// partial override, or retains a pending/fallback state.

use ir_identity::{
    SymbolRef, NominalFieldRef, TraitMethodRef,
    ImplProviderRef, ImplOwnerRef, ImplMethodRef,
    SlotRef, OriginRef,
    symbol_ref_same, symbol_ref_namespace_kind,
    namespace_kind_same, namespace_member, namespace_trait, namespace_effect,
    nominal_field_ref_owner,
    trait_method_ref_same, trait_method_ref_trait,
    trait_method_ref_source_member_index,
    trait_method_ref_callable_slot_index,
    impl_provider_ref_same, impl_provider_ref_kind,
    impl_provider_kind_same, impl_provider_kind_delegate,
    impl_owner_ref_same, impl_owner_ref_target,
    impl_owner_ref_provider, impl_owner_ref_trait,
    impl_method_ref_same, impl_method_ref_owner,
    impl_method_ref_member, impl_method_ref_source_member_index,
    impl_method_ref_callable_slot_index,
    slot_ref_same,
    origin_ref_is_symbol, origin_ref_symbol
}
use ir_inventory::{
    ExecutableRef, BinderManifest,
    executable_ref_same, executable_ref_is_named,
    executable_ref_named_symbol,
    binder_manifest_owner, binder_manifest_entries,
    binder_entry_slot
}
use hir::{
    MethodCallRef,
    method_call_ref_is_intrinsic, method_call_ref_is_concrete,
    method_call_ref_is_bound, method_call_ref_impl,
    method_call_ref_bound
}
use core_expr::{
    CoreTypeRef, CoreEffectSet, CoreCalleeRef, CoreEvidenceRef, CoreSlot,
    core_type_ref_same, core_type_ref_index,
    core_effect_set_atoms, make_core_effect_set,
    core_evidence_is_local, core_evidence_local, core_evidence_callable,
    core_slot_reference, core_slot_type
}

// ============================================================
// Exact associated/evidence facts
// ============================================================

pub struct DelegateAssocBinding {
    member: SymbolRef,
    ty: CoreTypeRef
}

pub fn make_delegate_assoc_binding(
    member: SymbolRef, ty: CoreTypeRef
) -> DelegateAssocBinding {
    if !namespace_kind_same(
            symbol_ref_namespace_kind(member), namespace_member()) {
        panic("delegate plan: associated binding is not a member symbol")
    }
    DelegateAssocBinding { member: member, ty: ty }
}
pub fn delegate_assoc_binding_member(value: DelegateAssocBinding) -> SymbolRef {
    value.member
}
pub fn delegate_assoc_binding_type(value: DelegateAssocBinding) -> CoreTypeRef {
    value.ty
}
fn copy_assoc_bindings(
    values: List<DelegateAssocBinding>
) -> List<DelegateAssocBinding> {
    let mut result: List<DelegateAssocBinding> = []
    for value in values { result.push(value) }
    result
}

pub struct DelegateEvidenceBinding {
    requirement: SymbolRef,
    evidence: CoreEvidenceRef
}

pub fn make_delegate_evidence_binding(
    requirement: SymbolRef, evidence: CoreEvidenceRef
) -> DelegateEvidenceBinding {
    DelegateEvidenceBinding {
        requirement: requirement, evidence: evidence
    }
}
pub fn delegate_evidence_requirement(
    value: DelegateEvidenceBinding
) -> SymbolRef { value.requirement }
pub fn delegate_evidence_value(
    value: DelegateEvidenceBinding
) -> CoreEvidenceRef { value.evidence }
fn copy_evidence_bindings(
    values: List<DelegateEvidenceBinding>
) -> List<DelegateEvidenceBinding> {
    let mut result: List<DelegateEvidenceBinding> = []
    for value in values { result.push(value) }
    result
}
fn copy_evidence(values: List<CoreEvidenceRef>) -> List<CoreEvidenceRef> {
    let mut result: List<CoreEvidenceRef> = []
    for value in values { result.push(value) }
    result
}
fn core_evidence_same(left: CoreEvidenceRef, right: CoreEvidenceRef) -> Bool {
    if core_evidence_is_local(left) != core_evidence_is_local(right) {
        return false
    }
    if core_evidence_is_local(left) {
        slot_ref_same(core_evidence_local(left), core_evidence_local(right))
    } else {
        executable_ref_same(
            core_evidence_callable(left), core_evidence_callable(right))
    }
}

// ============================================================
// One exact forwarded method and its ordinary-Core body inputs
// ============================================================

pub struct DelegateMethodBodyPlan {
    type_count: Int,
    manifest: BinderManifest,
    slots: List<CoreSlot>,
    parameter_slots: List<SlotRef>,
    outer_type: CoreTypeRef,
    field_type: CoreTypeRef,
    result_type: CoreTypeRef,
    wrapper_receiver_slot: SlotRef,
    field_receiver_slot: SlotRef,
    forwarded_argument_slots: List<SlotRef>,
    result_slot: SlotRef,
    effects: CoreEffectSet,
    evidence: List<CoreEvidenceRef>,
    body_origin: OriginRef
}

fn copy_core_slots(values: List<CoreSlot>) -> List<CoreSlot> {
    let mut result: List<CoreSlot> = []
    for value in values { result.push(value) }
    result
}
fn copy_slot_refs(values: List<SlotRef>) -> List<SlotRef> {
    let mut result: List<SlotRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_delegate_method_body_plan(
    type_count: Int, manifest: BinderManifest, slots: List<CoreSlot>,
    parameter_slots: List<SlotRef>, outer_type: CoreTypeRef,
    field_type: CoreTypeRef, result_type: CoreTypeRef,
    wrapper_receiver_slot: SlotRef, field_receiver_slot: SlotRef,
    forwarded_argument_slots: List<SlotRef>, result_slot: SlotRef,
    effects: CoreEffectSet, evidence: List<CoreEvidenceRef>,
    body_origin: OriginRef
) -> DelegateMethodBodyPlan {
    if type_count <= 0 || slot_ref_same(
            wrapper_receiver_slot, field_receiver_slot) ||
       slot_ref_same(field_receiver_slot, result_slot) {
        panic("delegate plan: invalid method body slot relation")
    }
    DelegateMethodBodyPlan {
        type_count: type_count, manifest: manifest,
        slots: copy_core_slots(slots),
        parameter_slots: copy_slot_refs(parameter_slots),
        outer_type: outer_type, field_type: field_type,
        result_type: result_type,
        wrapper_receiver_slot: wrapper_receiver_slot,
        field_receiver_slot: field_receiver_slot,
        forwarded_argument_slots: copy_slot_refs(forwarded_argument_slots),
        result_slot: result_slot,
        effects: make_core_effect_set(core_effect_set_atoms(effects)),
        evidence: copy_evidence(evidence), body_origin: body_origin
    }
}

pub struct DelegateMethodPlan {
    required_method: TraitMethodRef,
    generated_method: ImplMethodRef,
    generated_executable: ExecutableRef,
    generated_origin: OriginRef,
    child_call: MethodCallRef,
    child_callee: CoreCalleeRef,
    forwarded_parameter_types: List<CoreTypeRef>,
    result_type: CoreTypeRef,
    body: DelegateMethodBodyPlan
}

pub fn make_delegate_method_plan(
    required_method: TraitMethodRef, generated_method: ImplMethodRef,
    generated_executable: ExecutableRef, generated_origin: OriginRef,
    child_call: MethodCallRef, child_callee: CoreCalleeRef,
    forwarded_parameter_types: List<CoreTypeRef>,
    result_type: CoreTypeRef,
    body: DelegateMethodBodyPlan
) -> DelegateMethodPlan {
    DelegateMethodPlan {
        required_method: required_method,
        generated_method: generated_method,
        generated_executable: generated_executable,
        generated_origin: generated_origin,
        child_call: child_call, child_callee: child_callee,
        forwarded_parameter_types:
            forwarded_parameter_types.map(fn(value) { value }),
        result_type: result_type,
        body: body
    }
}
fn copy_method_plans(values: List<DelegateMethodPlan>) -> List<DelegateMethodPlan> {
    let mut result: List<DelegateMethodPlan> = []
    for value in values { result.push(value) }
    result
}

pub fn delegate_method_required(value: DelegateMethodPlan) -> TraitMethodRef {
    value.required_method
}
pub fn delegate_method_generated(value: DelegateMethodPlan) -> ImplMethodRef {
    value.generated_method
}
pub fn delegate_method_executable(value: DelegateMethodPlan) -> ExecutableRef {
    value.generated_executable
}
pub fn delegate_method_origin(value: DelegateMethodPlan) -> OriginRef {
    value.generated_origin
}
pub fn delegate_method_child_call(value: DelegateMethodPlan) -> MethodCallRef {
    value.child_call
}
pub fn delegate_method_child_callee(value: DelegateMethodPlan) -> CoreCalleeRef {
    value.child_callee
}
pub fn delegate_method_forwarded_parameter_types(
    value: DelegateMethodPlan
) -> List<CoreTypeRef> {
    value.forwarded_parameter_types.map(fn(item) { item })
}
pub fn delegate_method_result_type(value: DelegateMethodPlan) -> CoreTypeRef {
    value.result_type
}
pub fn delegate_method_body(value: DelegateMethodPlan) -> DelegateMethodBodyPlan {
    value.body
}

pub fn delegate_body_type_count(value: DelegateMethodBodyPlan) -> Int {
    value.type_count
}
pub fn delegate_body_manifest(value: DelegateMethodBodyPlan) -> BinderManifest {
    value.manifest
}
pub fn delegate_body_slots(value: DelegateMethodBodyPlan) -> List<CoreSlot> {
    copy_core_slots(value.slots)
}
pub fn delegate_body_parameter_slots(
    value: DelegateMethodBodyPlan
) -> List<SlotRef> { copy_slot_refs(value.parameter_slots) }
pub fn delegate_body_outer_type(value: DelegateMethodBodyPlan) -> CoreTypeRef {
    value.outer_type
}
pub fn delegate_body_field_type(value: DelegateMethodBodyPlan) -> CoreTypeRef {
    value.field_type
}
pub fn delegate_body_result_type(value: DelegateMethodBodyPlan) -> CoreTypeRef {
    value.result_type
}
pub fn delegate_body_wrapper_receiver(
    value: DelegateMethodBodyPlan
) -> SlotRef { value.wrapper_receiver_slot }
pub fn delegate_body_field_receiver(value: DelegateMethodBodyPlan) -> SlotRef {
    value.field_receiver_slot
}
pub fn delegate_body_forwarded_arguments(
    value: DelegateMethodBodyPlan
) -> List<SlotRef> { copy_slot_refs(value.forwarded_argument_slots) }
pub fn delegate_body_result_slot(value: DelegateMethodBodyPlan) -> SlotRef {
    value.result_slot
}
pub fn delegate_body_effects(value: DelegateMethodBodyPlan) -> CoreEffectSet {
    make_core_effect_set(core_effect_set_atoms(value.effects))
}
pub fn delegate_body_evidence(
    value: DelegateMethodBodyPlan
) -> List<CoreEvidenceRef> { copy_evidence(value.evidence) }
pub fn delegate_body_origin(value: DelegateMethodBodyPlan) -> OriginRef {
    value.body_origin
}

// ============================================================
// Input, explicit invalid outcome, and validated TypedPlan
// ============================================================

pub struct DelegatePlanInput {
    outer_owner: ImplOwnerRef,
    outer_provider: ImplProviderRef,
    child_provider: ImplProviderRef,
    source_member_index: Int,
    field: NominalFieldRef,
    outer_type: CoreTypeRef,
    field_type: CoreTypeRef,
    trait_ref: SymbolRef,
    required_methods: List<TraitMethodRef>,
    method_plans: List<DelegateMethodPlan>,
    required_assoc_members: List<SymbolRef>,
    assoc_bindings: List<DelegateAssocBinding>,
    required_effect_evidence: List<SymbolRef>,
    effect_evidence: List<DelegateEvidenceBinding>,
    required_dict_evidence: List<SymbolRef>,
    dict_evidence: List<DelegateEvidenceBinding>,
    manual_conflict: Bool
}

pub fn make_delegate_plan_input(
    outer_owner: ImplOwnerRef, outer_provider: ImplProviderRef,
    child_provider: ImplProviderRef, source_member_index: Int,
    field: NominalFieldRef, outer_type: CoreTypeRef,
    field_type: CoreTypeRef, trait_ref: SymbolRef,
    required_methods: List<TraitMethodRef>,
    method_plans: List<DelegateMethodPlan>,
    required_assoc_members: List<SymbolRef>,
    assoc_bindings: List<DelegateAssocBinding>,
    required_effect_evidence: List<SymbolRef>,
    effect_evidence: List<DelegateEvidenceBinding>,
    required_dict_evidence: List<SymbolRef>,
    dict_evidence: List<DelegateEvidenceBinding>,
    manual_conflict: Bool
) -> DelegatePlanInput {
    DelegatePlanInput {
        outer_owner: outer_owner, outer_provider: outer_provider,
        child_provider: child_provider,
        source_member_index: source_member_index,
        field: field, outer_type: outer_type, field_type: field_type,
        trait_ref: trait_ref,
        required_methods: required_methods.map(fn(value) { value }),
        method_plans: copy_method_plans(method_plans),
        required_assoc_members: required_assoc_members.map(fn(value) { value }),
        assoc_bindings: copy_assoc_bindings(assoc_bindings),
        required_effect_evidence:
            required_effect_evidence.map(fn(value) { value }),
        effect_evidence: copy_evidence_bindings(effect_evidence),
        required_dict_evidence:
            required_dict_evidence.map(fn(value) { value }),
        dict_evidence: copy_evidence_bindings(dict_evidence),
        manual_conflict: manual_conflict
    }
}

const DELEGATE_INVALID_MANUAL_CONFLICT: Int = 0
const DELEGATE_INVALID_OWNER: Int = 1
const DELEGATE_INVALID_FIELD: Int = 2
const DELEGATE_INVALID_METHOD_ORDER: Int = 3
const DELEGATE_INVALID_MISSING_METHOD: Int = 4
const DELEGATE_INVALID_DUPLICATE_METHOD: Int = 5
const DELEGATE_INVALID_EXTRA_METHOD: Int = 6
const DELEGATE_INVALID_CHILD_CALL: Int = 7
const DELEGATE_INVALID_GENERATED_IDENTITY: Int = 8
const DELEGATE_INVALID_ASSOC_BINDING: Int = 9
const DELEGATE_INVALID_EVIDENCE: Int = 10
const DELEGATE_INVALID_BODY: Int = 11

pub struct DelegateInvalidPlan {
    reason: Int,
    source_member_index: Int
}

pub fn delegate_invalid_reason(value: DelegateInvalidPlan) -> Int {
    value.reason
}
pub fn delegate_invalid_source_member_index(value: DelegateInvalidPlan) -> Int {
    value.source_member_index
}
pub fn delegate_invalid_manual_conflict_reason() -> Int {
    DELEGATE_INVALID_MANUAL_CONFLICT
}
pub fn delegate_invalid_owner_reason() -> Int { DELEGATE_INVALID_OWNER }
pub fn delegate_invalid_field_reason() -> Int { DELEGATE_INVALID_FIELD }
pub fn delegate_invalid_method_order_reason() -> Int {
    DELEGATE_INVALID_METHOD_ORDER
}
pub fn delegate_invalid_missing_method_reason() -> Int {
    DELEGATE_INVALID_MISSING_METHOD
}
pub fn delegate_invalid_duplicate_method_reason() -> Int {
    DELEGATE_INVALID_DUPLICATE_METHOD
}
pub fn delegate_invalid_extra_method_reason() -> Int {
    DELEGATE_INVALID_EXTRA_METHOD
}
pub fn delegate_invalid_child_call_reason() -> Int {
    DELEGATE_INVALID_CHILD_CALL
}
pub fn delegate_invalid_generated_identity_reason() -> Int {
    DELEGATE_INVALID_GENERATED_IDENTITY
}
pub fn delegate_invalid_assoc_binding_reason() -> Int {
    DELEGATE_INVALID_ASSOC_BINDING
}
pub fn delegate_invalid_evidence_reason() -> Int {
    DELEGATE_INVALID_EVIDENCE
}
pub fn delegate_invalid_body_reason() -> Int { DELEGATE_INVALID_BODY }

pub struct DelegateTypedPlan {
    outer_owner: ImplOwnerRef,
    child_provider: ImplProviderRef,
    source_member_index: Int,
    field: NominalFieldRef,
    outer_type: CoreTypeRef,
    field_type: CoreTypeRef,
    trait_ref: SymbolRef,
    methods: List<DelegateMethodPlan>,
    assoc_bindings: List<DelegateAssocBinding>,
    effect_evidence: List<DelegateEvidenceBinding>,
    dict_evidence: List<DelegateEvidenceBinding>
}

enum DelegatePlanOutcomeValue {
    ValidDelegatePlanValue(DelegateTypedPlan),
    InvalidDelegatePlanValue(DelegateInvalidPlan)
}
pub struct DelegatePlanOutcome { value: DelegatePlanOutcomeValue }

fn invalid_outcome(input: DelegatePlanInput, reason: Int) -> DelegatePlanOutcome {
    DelegatePlanOutcome { value: DelegatePlanOutcomeValue::InvalidDelegatePlanValue(
        DelegateInvalidPlan {
            reason: reason, source_member_index: input.source_member_index
        }) }
}
pub fn delegate_plan_outcome_is_valid(value: DelegatePlanOutcome) -> Bool {
    match value.value {
        DelegatePlanOutcomeValue::ValidDelegatePlanValue(_) => true,
        DelegatePlanOutcomeValue::InvalidDelegatePlanValue(_) => false
    }
}
pub fn delegate_plan_outcome_plan(value: DelegatePlanOutcome) -> DelegateTypedPlan {
    match value.value {
        DelegatePlanOutcomeValue::ValidDelegatePlanValue(plan) => plan,
        _ => panic("delegate plan: invalid outcome has no TypedPlan")
    }
}
pub fn delegate_plan_outcome_invalid(
    value: DelegatePlanOutcome
) -> DelegateInvalidPlan {
    match value.value {
        DelegatePlanOutcomeValue::InvalidDelegatePlanValue(invalid) => invalid,
        _ => panic("delegate plan: valid outcome has no invalid reason")
    }
}

fn body_slot_index(value: DelegateMethodBodyPlan, target: SlotRef) -> Int? {
    let mut index = 0
    for slot in value.slots {
        if slot_ref_same(core_slot_reference(slot), target) {
            return some(index)
        }
        index = index + 1
    }
    none
}
fn body_slot_type(value: DelegateMethodBodyPlan, target: SlotRef) -> CoreTypeRef? {
    match body_slot_index(value, target) {
        some(index) => some(core_slot_type(value.slots.get(index).unwrap())),
        none => none
    }
}
fn method_body_is_closed(
    value: DelegateMethodBodyPlan,
    generated_executable: ExecutableRef,
    expected_outer_type: CoreTypeRef,
    expected_field_type: CoreTypeRef,
    expected_forwarded_types: List<CoreTypeRef>,
    expected_result_type: CoreTypeRef
) -> Bool {
    if value.type_count <= 0 ||
       !executable_ref_same(
            binder_manifest_owner(value.manifest), generated_executable) ||
       value.slots.len() != binder_manifest_entries(value.manifest).len() ||
       !core_type_ref_same(value.outer_type, expected_outer_type) ||
       !core_type_ref_same(value.field_type, expected_field_type) ||
       !core_type_ref_same(value.result_type, expected_result_type) ||
       value.parameter_slots.len() !=
            value.forwarded_argument_slots.len() + 1 ||
       value.forwarded_argument_slots.len() != expected_forwarded_types.len() ||
       !slot_ref_same(
            value.parameter_slots.get(0).unwrap_or(value.result_slot),
            value.wrapper_receiver_slot) {
        return false
    }
    let mut slot_index = 0
    while slot_index < value.slots.len() {
        let slot = value.slots.get(slot_index).unwrap()
        let binder = binder_manifest_entries(value.manifest).get(
            slot_index).unwrap()
        if !slot_ref_same(
                core_slot_reference(slot), binder_entry_slot(binder)) ||
           core_type_ref_index(core_slot_type(slot)) < 0 ||
           core_type_ref_index(core_slot_type(slot)) >= value.type_count {
            return false
        }
        let mut right_index = slot_index + 1
        while right_index < value.slots.len() {
            if slot_ref_same(
                    core_slot_reference(slot),
                    core_slot_reference(value.slots.get(right_index).unwrap())) {
                return false
            }
            right_index = right_index + 1
        }
        slot_index = slot_index + 1
    }
    match body_slot_type(value, value.wrapper_receiver_slot) {
        some(ty) => if !core_type_ref_same(ty, value.outer_type) { return false },
        none => return false
    }
    match body_slot_type(value, value.field_receiver_slot) {
        some(ty) => if !core_type_ref_same(ty, value.field_type) { return false },
        none => return false
    }
    match body_slot_type(value, value.result_slot) {
        some(ty) => if !core_type_ref_same(ty, value.result_type) { return false },
        none => return false
    }
    let mut argument_index = 0
    while argument_index < value.forwarded_argument_slots.len() {
        let argument = value.forwarded_argument_slots.get(argument_index).unwrap()
        if body_slot_index(value, argument).is_none() ||
           !slot_ref_same(
                value.parameter_slots.get(argument_index + 1).unwrap(),
                argument) {
            return false
        }
        match body_slot_type(value, argument) {
            some(ty) => if !core_type_ref_same(
                    ty, expected_forwarded_types.get(
                        argument_index).unwrap()) {
                return false
            },
            none => return false
        }
        argument_index = argument_index + 1
    }
    for evidence in value.evidence {
        if core_evidence_is_local(evidence) &&
           body_slot_index(value, core_evidence_local(evidence)).is_none() {
            return false
        }
    }
    true
}

fn method_identity_is_exact(
    input: DelegatePlanInput, value: DelegateMethodPlan
) -> Bool {
    if !impl_owner_ref_same(
            impl_method_ref_owner(value.generated_method), input.outer_owner) ||
       !executable_ref_is_named(value.generated_executable) ||
       !symbol_ref_same(
            executable_ref_named_symbol(value.generated_executable),
            impl_method_ref_member(value.generated_method)) ||
       !origin_ref_is_symbol(value.generated_origin) ||
       !symbol_ref_same(
            origin_ref_symbol(value.generated_origin),
            impl_method_ref_member(value.generated_method)) ||
       !executable_ref_same(
            binder_manifest_owner(value.body.manifest),
            value.generated_executable) {
        return false
    }
    impl_method_ref_callable_slot_index(value.generated_method) ==
        trait_method_ref_callable_slot_index(value.required_method)
}

fn child_call_is_exact(
    input: DelegatePlanInput, value: DelegateMethodPlan
) -> Bool {
    if method_call_ref_is_intrinsic(value.child_call) {
        return false
    }
    if method_call_ref_is_concrete(value.child_call) {
        let child_method = method_call_ref_impl(value.child_call)
        let child_owner = impl_method_ref_owner(child_method)
        if !impl_provider_ref_same(
                impl_owner_ref_provider(child_owner), input.child_provider) {
            return false
        }
        return match impl_owner_ref_trait(child_owner) {
            some(trait_symbol) => symbol_ref_same(
                trait_symbol, input.trait_ref),
            none => false
        }
    }
    method_call_ref_is_bound(value.child_call) &&
        trait_method_ref_same(
            method_call_ref_bound(value.child_call), value.required_method)
}

fn required_methods_are_ordered(input: DelegatePlanInput) -> Bool {
    let mut index = 0
    while index < input.required_methods.len() {
        let current = input.required_methods.get(index).unwrap()
        if !symbol_ref_same(
                trait_method_ref_trait(current), input.trait_ref) {
            return false
        }
        if index > 0 {
            let previous = input.required_methods.get(index - 1).unwrap()
            if trait_method_ref_source_member_index(current) <=
                    trait_method_ref_source_member_index(previous) ||
               trait_method_ref_callable_slot_index(current) <=
                    trait_method_ref_callable_slot_index(previous) {
                return false
            }
        }
        index = index + 1
    }
    true
}

fn binding_requirements_match_assoc(input: DelegatePlanInput) -> Bool {
    if input.required_assoc_members.len() != input.assoc_bindings.len() {
        return false
    }
    let mut index = 0
    while index < input.assoc_bindings.len() {
        let binding = input.assoc_bindings.get(index).unwrap()
        if !symbol_ref_same(
                input.required_assoc_members.get(index).unwrap(),
                binding.member) {
            return false
        }
        let mut right_index = index + 1
        while right_index < input.assoc_bindings.len() {
            if symbol_ref_same(
                    binding.member,
                    input.assoc_bindings.get(right_index).unwrap().member) {
                return false
            }
            right_index = right_index + 1
        }
        index = index + 1
    }
    true
}

fn evidence_requirements_match(
    required: List<SymbolRef>, bindings: List<DelegateEvidenceBinding>
) -> Bool {
    if required.len() != bindings.len() { return false }
    let mut index = 0
    while index < bindings.len() {
        let binding = bindings.get(index).unwrap()
        if !symbol_ref_same(required.get(index).unwrap(), binding.requirement) {
            return false
        }
        let mut right_index = index + 1
        while right_index < bindings.len() {
            let right = bindings.get(right_index).unwrap()
            if symbol_ref_same(binding.requirement, right.requirement) ||
               core_evidence_same(binding.evidence, right.evidence) {
                return false
            }
            right_index = right_index + 1
        }
        index = index + 1
    }
    true
}

fn evidence_requirement_namespaces_are_exact(input: DelegatePlanInput) -> Bool {
    for requirement in input.required_effect_evidence {
        if !namespace_kind_same(
                symbol_ref_namespace_kind(requirement), namespace_effect()) {
            return false
        }
    }
    for requirement in input.required_dict_evidence {
        if !namespace_kind_same(
                symbol_ref_namespace_kind(requirement), namespace_trait()) {
            return false
        }
    }
    for member in input.required_assoc_members {
        if !namespace_kind_same(
                symbol_ref_namespace_kind(member), namespace_member()) {
            return false
        }
    }
    true
}

fn method_contains_plan_evidence(
    method: DelegateMethodPlan, input: DelegatePlanInput
) -> Bool {
    for binding in input.effect_evidence {
        let mut found = false
        for evidence in method.body.evidence {
            if core_evidence_same(binding.evidence, evidence) { found = true }
        }
        if !found { return false }
    }
    for binding in input.dict_evidence {
        let mut found = false
        for evidence in method.body.evidence {
            if core_evidence_same(binding.evidence, evidence) { found = true }
        }
        if !found { return false }
    }
    true
}

pub fn validate_delegate_plan(input: DelegatePlanInput) -> DelegatePlanOutcome {
    if input.manual_conflict {
        return invalid_outcome(input, DELEGATE_INVALID_MANUAL_CONFLICT)
    }
    let owner_trait = impl_owner_ref_trait(input.outer_owner)
    if input.source_member_index < 0 ||
       !impl_provider_ref_same(
            impl_owner_ref_provider(input.outer_owner), input.outer_provider) ||
       !impl_provider_kind_same(
            impl_provider_ref_kind(input.child_provider),
            impl_provider_kind_delegate()) ||
       match owner_trait {
            some(trait_symbol) => !symbol_ref_same(
                trait_symbol, input.trait_ref),
            none => true
       } {
        return invalid_outcome(input, DELEGATE_INVALID_OWNER)
    }
    if !symbol_ref_same(
            impl_owner_ref_target(input.outer_owner),
            nominal_field_ref_owner(input.field)) {
        return invalid_outcome(input, DELEGATE_INVALID_FIELD)
    }
    if !required_methods_are_ordered(input) {
        return invalid_outcome(input, DELEGATE_INVALID_METHOD_ORDER)
    }
    if input.method_plans.len() < input.required_methods.len() {
        return invalid_outcome(input, DELEGATE_INVALID_MISSING_METHOD)
    }
    if input.method_plans.len() > input.required_methods.len() {
        return invalid_outcome(input, DELEGATE_INVALID_EXTRA_METHOD)
    }
    let mut index = 0
    while index < input.method_plans.len() {
        let method = input.method_plans.get(index).unwrap()
        let required = input.required_methods.get(index).unwrap()
        let mut duplicate_index = index + 1
        while duplicate_index < input.method_plans.len() {
            if trait_method_ref_same(
                    method.required_method,
                    input.method_plans.get(duplicate_index).unwrap()
                        .required_method) {
                return invalid_outcome(
                    input, DELEGATE_INVALID_DUPLICATE_METHOD)
            }
            duplicate_index = duplicate_index + 1
        }
        if !trait_method_ref_same(method.required_method, required) {
            return invalid_outcome(input, DELEGATE_INVALID_MISSING_METHOD)
        }
        if !method_identity_is_exact(input, method) {
            return invalid_outcome(
                input, DELEGATE_INVALID_GENERATED_IDENTITY)
        }
        if !child_call_is_exact(input, method) {
            return invalid_outcome(input, DELEGATE_INVALID_CHILD_CALL)
        }
        if !core_type_ref_same(method.body.field_type, input.field_type) ||
           !core_type_ref_same(method.body.outer_type, input.outer_type) ||
           !method_contains_plan_evidence(method, input) ||
           !method_body_is_closed(
                method.body, method.generated_executable,
                input.outer_type, input.field_type,
                method.forwarded_parameter_types,
                method.result_type) {
            return invalid_outcome(input, DELEGATE_INVALID_BODY)
        }
        index = index + 1
    }
    if !evidence_requirement_namespaces_are_exact(input) ||
       !binding_requirements_match_assoc(input) {
        return invalid_outcome(input, DELEGATE_INVALID_ASSOC_BINDING)
    }
    if !evidence_requirements_match(
            input.required_effect_evidence, input.effect_evidence) ||
       !evidence_requirements_match(
            input.required_dict_evidence, input.dict_evidence) {
        return invalid_outcome(input, DELEGATE_INVALID_EVIDENCE)
    }
    let plan = DelegateTypedPlan {
        outer_owner: input.outer_owner,
        child_provider: input.child_provider,
        source_member_index: input.source_member_index,
        field: input.field, outer_type: input.outer_type,
        field_type: input.field_type, trait_ref: input.trait_ref,
        methods: copy_method_plans(input.method_plans),
        assoc_bindings: copy_assoc_bindings(input.assoc_bindings),
        effect_evidence: copy_evidence_bindings(input.effect_evidence),
        dict_evidence: copy_evidence_bindings(input.dict_evidence)
    }
    DelegatePlanOutcome {
        value: DelegatePlanOutcomeValue::ValidDelegatePlanValue(plan)
    }
}

pub fn delegate_typed_plan_outer_owner(value: DelegateTypedPlan) -> ImplOwnerRef {
    value.outer_owner
}
pub fn delegate_typed_plan_child_provider(
    value: DelegateTypedPlan
) -> ImplProviderRef { value.child_provider }
pub fn delegate_typed_plan_source_member_index(
    value: DelegateTypedPlan
) -> Int { value.source_member_index }
pub fn delegate_typed_plan_field(value: DelegateTypedPlan) -> NominalFieldRef {
    value.field
}
pub fn delegate_typed_plan_outer_type(value: DelegateTypedPlan) -> CoreTypeRef {
    value.outer_type
}
pub fn delegate_typed_plan_field_type(value: DelegateTypedPlan) -> CoreTypeRef {
    value.field_type
}
pub fn delegate_typed_plan_trait(value: DelegateTypedPlan) -> SymbolRef {
    value.trait_ref
}
pub fn delegate_typed_plan_methods(
    value: DelegateTypedPlan
) -> List<DelegateMethodPlan> { copy_method_plans(value.methods) }
pub fn delegate_typed_plan_assoc_bindings(
    value: DelegateTypedPlan
) -> List<DelegateAssocBinding> { copy_assoc_bindings(value.assoc_bindings) }
pub fn delegate_typed_plan_effect_evidence(
    value: DelegateTypedPlan
) -> List<DelegateEvidenceBinding> {
    copy_evidence_bindings(value.effect_evidence)
}
pub fn delegate_typed_plan_dict_evidence(
    value: DelegateTypedPlan
) -> List<DelegateEvidenceBinding> {
    copy_evidence_bindings(value.dict_evidence)
}
