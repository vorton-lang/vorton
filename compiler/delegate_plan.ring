// Exact 0.1 delegate TypedPlan.
//
// The resolver/checker supplies every typed identity and source binder.  This
// module only validates the closed full-trait forwarding relation.  It never
// resolves a name/span, discovers a provider, fills a missing method, permits a
// partial override, or retains a pending/fallback state.

use ir_identity::{
    CoreTypeRef, core_type_ref_same, core_type_ref_index,
    SymbolRef, NominalFieldRef, TraitMethodRef, HandledEffectRef,
    ImplProviderRef, ImplOwnerRef, ImplMethodRef,
    SlotRef, OriginRef,
    symbol_ref_same, symbol_ref_namespace_kind,
    namespace_kind_same, namespace_member, namespace_trait,
    registered_trait_ref_symbol,
    handled_effect_ref_same,
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
    ExecutableRef, ExactMethodRef,
    exact_method_ref_is_intrinsic, exact_method_ref_is_impl,
    exact_method_ref_is_trait, exact_method_ref_impl,
    exact_method_ref_trait,
    executable_ref_is_named, executable_ref_named_symbol,
    dict_ref_same
}
use env::{
    RegisteredTraitContract,
    registered_trait_contract_owner,
    registered_trait_contract_methods,
    registered_trait_contract_assoc_items,
    registered_trait_contract_dict_obligations,
    registered_trait_method_ref,
    registered_trait_assoc_member
}
use effect_contract::{
    CoreEffectSet, core_effect_set_atoms, make_core_effect_set,
    core_effect_atom_kind_tag, core_effect_atom_handled_ref
}
use core_type_source::{
    CoreTypeGraph, core_type_graph_count, core_type_graph_node,
    core_type_graph_nodes, make_core_type_graph, copy_core_type_graph,
    flow_type_node_nominal
}
use core_expr::{
    CoreCalleeRef, CoreEvidenceRef, CoreBinder,
    CoreHandledEvidenceBinding, CoreHandledEvidenceUse,
    core_evidence_dict,
    core_handled_evidence_requirement, core_handled_evidence_slot,
    core_handled_evidence_type,
    core_handled_use_requirement, core_handled_use_slot,
    core_handled_use_type,
    core_binder_reference, core_binder_type
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
fn copy_handled_bindings(
    values: List<CoreHandledEvidenceBinding>
) -> List<CoreHandledEvidenceBinding> {
    let mut result: List<CoreHandledEvidenceBinding> = []
    for value in values { result.push(value) }
    result
}
fn copy_handled_uses(
    values: List<CoreHandledEvidenceUse>
) -> List<CoreHandledEvidenceUse> {
    let mut result: List<CoreHandledEvidenceUse> = []
    for value in values { result.push(value) }
    result
}
fn core_evidence_same(left: CoreEvidenceRef, right: CoreEvidenceRef) -> Bool {
    dict_ref_same(core_evidence_dict(left), core_evidence_dict(right))
}

// ============================================================
// One exact forwarded method and its ordinary-Core body inputs
// ============================================================

pub struct DelegateMethodBodyPlan {
    binders: List<CoreBinder>,
    parameter_slots: List<SlotRef>,
    outer_type: CoreTypeRef,
    field_type: CoreTypeRef,
    result_type: CoreTypeRef,
    wrapper_receiver_slot: SlotRef,
    forwarded_argument_slots: List<SlotRef>,
    effects: CoreEffectSet,
    evidence: List<CoreEvidenceRef>,
    handled_bindings: List<CoreHandledEvidenceBinding>,
    handled_uses: List<CoreHandledEvidenceUse>,
    body_origin: OriginRef
}

fn copy_core_binders(values: List<CoreBinder>) -> List<CoreBinder> {
    let mut result: List<CoreBinder> = []
    for value in values { result.push(value) }
    result
}
fn copy_slot_refs(values: List<SlotRef>) -> List<SlotRef> {
    let mut result: List<SlotRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_delegate_method_body_plan(
    binders: List<CoreBinder>,
    parameter_slots: List<SlotRef>, outer_type: CoreTypeRef,
    field_type: CoreTypeRef, result_type: CoreTypeRef,
    wrapper_receiver_slot: SlotRef,
    forwarded_argument_slots: List<SlotRef>,
    effects: CoreEffectSet, evidence: List<CoreEvidenceRef>,
    handled_bindings: List<CoreHandledEvidenceBinding>,
    handled_uses: List<CoreHandledEvidenceUse>,
    body_origin: OriginRef
) -> DelegateMethodBodyPlan {
    DelegateMethodBodyPlan {
        binders: copy_core_binders(binders),
        parameter_slots: copy_slot_refs(parameter_slots),
        outer_type: outer_type, field_type: field_type,
        result_type: result_type,
        wrapper_receiver_slot: wrapper_receiver_slot,
        forwarded_argument_slots: copy_slot_refs(forwarded_argument_slots),
        effects: make_core_effect_set(core_effect_set_atoms(effects)),
        evidence: copy_evidence(evidence),
        handled_bindings: copy_handled_bindings(handled_bindings),
        handled_uses: copy_handled_uses(handled_uses),
        body_origin: body_origin
    }
}

pub struct DelegateMethodPlan {
    required_method: TraitMethodRef,
    generated_method: ImplMethodRef,
    generated_executable: ExecutableRef,
    generated_origin: OriginRef,
    child_call: ExactMethodRef,
    child_callee: CoreCalleeRef,
    forwarded_parameter_types: List<CoreTypeRef>,
    result_type: CoreTypeRef,
    body: DelegateMethodBodyPlan
}

pub fn make_delegate_method_plan(
    required_method: TraitMethodRef, generated_method: ImplMethodRef,
    generated_executable: ExecutableRef, generated_origin: OriginRef,
    child_call: ExactMethodRef, child_callee: CoreCalleeRef,
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

pub fn delegate_method_generated(value: DelegateMethodPlan) -> ImplMethodRef {
    value.generated_method
}
pub fn delegate_method_executable(value: DelegateMethodPlan) -> ExecutableRef {
    value.generated_executable
}
pub fn delegate_method_origin(value: DelegateMethodPlan) -> OriginRef {
    value.generated_origin
}
pub fn delegate_method_child_call(value: DelegateMethodPlan) -> ExactMethodRef {
    value.child_call
}
pub fn delegate_method_child_callee(value: DelegateMethodPlan) -> CoreCalleeRef {
    value.child_callee
}
pub fn delegate_method_body(value: DelegateMethodPlan) -> DelegateMethodBodyPlan {
    value.body
}

pub fn delegate_body_binders(value: DelegateMethodBodyPlan) -> List<CoreBinder> {
    copy_core_binders(value.binders)
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
pub fn delegate_body_forwarded_arguments(
    value: DelegateMethodBodyPlan
) -> List<SlotRef> { copy_slot_refs(value.forwarded_argument_slots) }
pub fn delegate_body_effects(value: DelegateMethodBodyPlan) -> CoreEffectSet {
    make_core_effect_set(core_effect_set_atoms(value.effects))
}
pub fn delegate_body_evidence(
    value: DelegateMethodBodyPlan
) -> List<CoreEvidenceRef> { copy_evidence(value.evidence) }
pub fn delegate_body_handled_uses(
    value: DelegateMethodBodyPlan
) -> List<CoreHandledEvidenceUse> {
    copy_handled_uses(value.handled_uses)
}
pub fn delegate_body_origin(value: DelegateMethodBodyPlan) -> OriginRef {
    value.body_origin
}

// ============================================================
// Input and fail-loud validated TypedPlan
// ============================================================

pub struct DelegatePlanInput {
    outer_owner: ImplOwnerRef,
    outer_provider: ImplProviderRef,
    child_provider: ImplProviderRef,
    field_impl_owner: ImplOwnerRef,
    field_impl_provider: ImplProviderRef,
    field_target: SymbolRef,
    source_member_index: Int,
    type_graph: CoreTypeGraph,
    field: NominalFieldRef,
    outer_type: CoreTypeRef,
    field_type: CoreTypeRef,
    trait_contract: RegisteredTraitContract,
    method_plans: List<DelegateMethodPlan>,
    assoc_bindings: List<DelegateAssocBinding>,
    dict_evidence: List<DelegateEvidenceBinding>
}

pub fn make_delegate_plan_input(
    outer_owner: ImplOwnerRef, outer_provider: ImplProviderRef,
    child_provider: ImplProviderRef, source_member_index: Int,
    field_impl_owner: ImplOwnerRef,
    field_impl_provider: ImplProviderRef, field_target: SymbolRef,
    type_graph: CoreTypeGraph,
    field: NominalFieldRef, outer_type: CoreTypeRef,
    field_type: CoreTypeRef, trait_contract: RegisteredTraitContract,
    method_plans: List<DelegateMethodPlan>,
    assoc_bindings: List<DelegateAssocBinding>,
    dict_evidence: List<DelegateEvidenceBinding>
) -> DelegatePlanInput {
    DelegatePlanInput {
        outer_owner: outer_owner, outer_provider: outer_provider,
        child_provider: child_provider,
        field_impl_owner: field_impl_owner,
        field_impl_provider: field_impl_provider,
        field_target: field_target,
        source_member_index: source_member_index,
        type_graph: copy_core_type_graph(type_graph),
        field: field, outer_type: outer_type, field_type: field_type,
        trait_contract: trait_contract,
        method_plans: copy_method_plans(method_plans),
        assoc_bindings: copy_assoc_bindings(assoc_bindings),
        dict_evidence: copy_evidence_bindings(dict_evidence)
    }
}

pub struct DelegateTypedPlan {
    outer_owner: ImplOwnerRef,
    field: NominalFieldRef,
    methods: List<DelegateMethodPlan>,
    assoc_bindings: List<DelegateAssocBinding>
}

fn body_binder_index(value: DelegateMethodBodyPlan, target: SlotRef) -> Int? {
    let mut index = 0
    for binder in value.binders {
        if slot_ref_same(core_binder_reference(binder), target) {
            return some(index)
        }
        index = index + 1
    }
    none
}
fn body_binder_type(value: DelegateMethodBodyPlan, target: SlotRef) -> CoreTypeRef? {
    match body_binder_index(value, target) {
        some(index) => some(core_binder_type(value.binders.get(index).unwrap())),
        none => none
    }
}
fn method_body_is_closed(
    value: DelegateMethodBodyPlan,
    expected_type_count: Int,
    expected_outer_type: CoreTypeRef,
    expected_field_type: CoreTypeRef,
    expected_forwarded_types: List<CoreTypeRef>,
    expected_result_type: CoreTypeRef
) -> Bool {
    if !core_type_ref_same(value.outer_type, expected_outer_type) ||
       !core_type_ref_same(value.field_type, expected_field_type) ||
       !core_type_ref_same(value.result_type, expected_result_type) ||
       value.parameter_slots.len() !=
            value.forwarded_argument_slots.len() + 1 ||
       value.forwarded_argument_slots.len() != expected_forwarded_types.len() ||
       !slot_ref_same(
            value.parameter_slots.get(0).unwrap_or(value.wrapper_receiver_slot),
            value.wrapper_receiver_slot) {
        return false
    }
    let mut binder_index = 0
    while binder_index < value.binders.len() {
        let binder = value.binders.get(binder_index).unwrap()
        if core_type_ref_index(core_binder_type(binder)) < 0 ||
           core_type_ref_index(core_binder_type(binder)) >= expected_type_count {
            return false
        }
        let mut right_index = binder_index + 1
        while right_index < value.binders.len() {
            if slot_ref_same(
                    core_binder_reference(binder),
                    core_binder_reference(
                        value.binders.get(right_index).unwrap())) {
                return false
            }
            right_index = right_index + 1
        }
        binder_index = binder_index + 1
    }
    match body_binder_type(value, value.wrapper_receiver_slot) {
        some(ty) => if !core_type_ref_same(ty, value.outer_type) { return false },
        none => return false
    }
    let mut argument_index = 0
    while argument_index < value.forwarded_argument_slots.len() {
        let argument = value.forwarded_argument_slots.get(argument_index).unwrap()
        if body_binder_index(value, argument).is_none() ||
           !slot_ref_same(
                value.parameter_slots.get(argument_index + 1).unwrap(),
                argument) {
            return false
        }
        match body_binder_type(value, argument) {
            some(ty) => if !core_type_ref_same(
                    ty, expected_forwarded_types.get(
                        argument_index).unwrap()) {
                return false
            },
            none => return false
        }
        argument_index = argument_index + 1
    }
    for binding in value.handled_bindings {
        match body_binder_type(value, core_handled_evidence_slot(binding)) {
            some(ty) => if !core_type_ref_same(
                    ty, core_handled_evidence_type(binding)) {
                return false
            },
            none => return false
        }
    }
    for use_ in value.handled_uses {
        if body_binder_index(value, core_handled_use_slot(use_)).is_none() {
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
            impl_method_ref_member(value.generated_method)) {
        return false
    }
    impl_method_ref_callable_slot_index(value.generated_method) ==
        trait_method_ref_callable_slot_index(value.required_method)
}

fn child_call_is_exact(
    input: DelegatePlanInput, value: DelegateMethodPlan
) -> Bool {
    let trait_symbol = registered_trait_ref_symbol(
        registered_trait_contract_owner(input.trait_contract))
    if exact_method_ref_is_intrinsic(value.child_call) {
        return false
    }
    if exact_method_ref_is_impl(value.child_call) {
        let child_method = exact_method_ref_impl(value.child_call)
        let child_owner = impl_method_ref_owner(child_method)
        if !impl_owner_ref_same(child_owner, input.field_impl_owner) ||
           !impl_provider_ref_same(
                impl_owner_ref_provider(child_owner),
                input.field_impl_provider) {
            return false
        }
        return match impl_owner_ref_trait(child_owner) {
            some(selected_trait) => symbol_ref_same(
                selected_trait, trait_symbol),
            none => false
        }
    }
    exact_method_ref_is_trait(value.child_call) &&
        trait_method_ref_same(
            exact_method_ref_trait(value.child_call), value.required_method)
}

fn contract_method_refs(input: DelegatePlanInput) -> List<TraitMethodRef> {
    registered_trait_contract_methods(input.trait_contract).map(fn(method) {
        registered_trait_method_ref(method)
    })
}

fn binding_requirements_match_assoc(input: DelegatePlanInput) -> Bool {
    let required = registered_trait_contract_assoc_items(
        input.trait_contract)
    if required.len() != input.assoc_bindings.len() {
        return false
    }
    let mut index = 0
    while index < input.assoc_bindings.len() {
        let binding = input.assoc_bindings.get(index).unwrap()
        if !symbol_ref_same(
                registered_trait_assoc_member(required.get(index).unwrap()),
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

fn handled_evidence_requirements_match(body: DelegateMethodBodyPlan) -> Bool {
    let mut required: List<HandledEffectRef> = []
    for atom in core_effect_set_atoms(body.effects) {
        if core_effect_atom_kind_tag(atom) == 3 {
            required.push(core_effect_atom_handled_ref(atom))
        }
    }
    if required.len() != body.handled_bindings.len() ||
       required.len() != body.handled_uses.len() {
        return false
    }
    let mut index = 0
    while index < required.len() {
        let binding = body.handled_bindings.get(index).unwrap()
        let use_ = body.handled_uses.get(index).unwrap()
        if !handled_effect_ref_same(
                required.get(index).unwrap(),
                core_handled_evidence_requirement(binding)) ||
           !handled_effect_ref_same(
                required.get(index).unwrap(),
                core_handled_use_requirement(use_)) ||
           !core_type_ref_same(
                core_handled_evidence_type(binding),
                core_handled_use_type(use_)) ||
           !slot_ref_same(
                core_handled_evidence_slot(binding),
                core_handled_use_slot(use_)) {
            return false
        }
        let mut right_index = index + 1
        while right_index < body.handled_bindings.len() {
            let right = body.handled_bindings.get(right_index).unwrap()
            if handled_effect_ref_same(
                    core_handled_evidence_requirement(binding),
                    core_handled_evidence_requirement(right)) ||
               slot_ref_same(
                    core_handled_evidence_slot(binding),
                    core_handled_evidence_slot(right)) {
                return false
            }
            right_index = right_index + 1
        }
        index = index + 1
    }
    true
}

fn method_contains_plan_evidence(
    method: DelegateMethodPlan, input: DelegatePlanInput
) -> Bool {
    for binding in input.dict_evidence {
        let mut found = false
        for evidence in method.body.evidence {
            if core_evidence_same(binding.evidence, evidence) { found = true }
        }
        if !found { return false }
    }
    true
}

pub fn validate_delegate_plan(input: DelegatePlanInput) -> DelegateTypedPlan {
    let owner_trait = impl_owner_ref_trait(input.outer_owner)
    let contract_trait = registered_trait_ref_symbol(
        registered_trait_contract_owner(input.trait_contract))
    if input.source_member_index < 0 ||
       !impl_provider_ref_same(
            impl_owner_ref_provider(input.outer_owner), input.outer_provider) ||
       !impl_provider_kind_same(
            impl_provider_ref_kind(input.child_provider),
            impl_provider_kind_delegate()) ||
       match owner_trait {
            some(trait_symbol) => !symbol_ref_same(
                trait_symbol, contract_trait),
            none => true
       } {
        panic("delegate plan: owner relation differs")
    }
    if !symbol_ref_same(
            impl_owner_ref_target(input.outer_owner),
            nominal_field_ref_owner(input.field)) {
        panic("delegate plan: field owner differs")
    }
    if core_type_graph_count(input.type_graph) <= 0 ||
       !symbol_ref_same(
            flow_type_node_nominal(core_type_graph_node(
                input.type_graph, input.outer_type)),
            impl_owner_ref_target(input.outer_owner)) ||
       !symbol_ref_same(
            flow_type_node_nominal(core_type_graph_node(
                input.type_graph, input.field_type)),
            input.field_target) {
        panic("delegate plan: field type relation differs")
    }
    let field_trait = impl_owner_ref_trait(input.field_impl_owner)
    if !symbol_ref_same(
            impl_owner_ref_target(input.field_impl_owner),
            input.field_target) ||
       !impl_provider_ref_same(
            impl_owner_ref_provider(input.field_impl_owner),
            input.field_impl_provider) ||
       match field_trait {
            some(trait_symbol) => !symbol_ref_same(
                trait_symbol, contract_trait),
            none => true
       } {
        panic("delegate plan: child owner relation differs")
    }
    let required_methods = contract_method_refs(input)
    if input.method_plans.len() < required_methods.len() {
        panic("delegate plan: required method is missing")
    }
    if input.method_plans.len() > required_methods.len() {
        panic("delegate plan: extra method is present")
    }
    let mut index = 0
    while index < input.method_plans.len() {
        let method = input.method_plans.get(index).unwrap()
        let required = required_methods.get(index).unwrap()
        let mut duplicate_index = index + 1
        while duplicate_index < input.method_plans.len() {
            if trait_method_ref_same(
                    method.required_method,
                    input.method_plans.get(duplicate_index).unwrap()
                        .required_method) {
                panic("delegate plan: required method is duplicated")
            }
            duplicate_index = duplicate_index + 1
        }
        if !trait_method_ref_same(method.required_method, required) {
            panic("delegate plan: required method order differs")
        }
        if !method_identity_is_exact(input, method) {
            panic("delegate plan: generated method identity differs")
        }
        if !child_call_is_exact(input, method) {
            panic("delegate plan: child call identity differs")
        }
        if !core_type_ref_same(method.body.field_type, input.field_type) ||
           !core_type_ref_same(method.body.outer_type, input.outer_type) ||
           !handled_evidence_requirements_match(method.body) ||
           !method_contains_plan_evidence(method, input) ||
           !method_body_is_closed(
                method.body, core_type_graph_count(input.type_graph),
                input.outer_type, input.field_type,
                method.forwarded_parameter_types,
                method.result_type) {
            panic("delegate plan: method body relation differs")
        }
        index = index + 1
    }
    if !binding_requirements_match_assoc(input) {
        panic("delegate plan: associated binding relation differs")
    }
    if !evidence_requirements_match(
            registered_trait_contract_dict_obligations(input.trait_contract),
            input.dict_evidence) {
        panic("delegate plan: dictionary evidence relation differs")
    }
    DelegateTypedPlan {
        outer_owner: input.outer_owner,
        field: input.field,
        methods: copy_method_plans(input.method_plans),
        assoc_bindings: copy_assoc_bindings(input.assoc_bindings)
    }
}

pub fn delegate_typed_plan_outer_owner(value: DelegateTypedPlan) -> ImplOwnerRef {
    value.outer_owner
}
pub fn delegate_typed_plan_field(value: DelegateTypedPlan) -> NominalFieldRef {
    value.field
}
pub fn delegate_typed_plan_methods(
    value: DelegateTypedPlan
) -> List<DelegateMethodPlan> { copy_method_plans(value.methods) }
pub fn delegate_typed_plan_assoc_bindings(
    value: DelegateTypedPlan
) -> List<DelegateAssocBinding> { copy_assoc_bindings(value.assoc_bindings) }
