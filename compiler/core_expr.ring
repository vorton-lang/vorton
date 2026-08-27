// CoreHIR structured semantic language for Ring 0.1.
//
// CoreHIR is the last language-semantic representation.  Every callee,
// method, evidence edge, nominal/member projection, generated executable and
// body-local slot is supplied as an exact typed reference by the upstream
// elaborator.  The representation has no source names/spans and deliberately
// has no Clone/Take/Drop/Cleanup, layout, ABI, or backend variant.

use ir_identity::{
    CoreTypeRef, CoreTypeFactRef,
    make_core_type_ref, make_module_core_type_ref,
    core_type_ref_index, core_type_ref_module_key, core_type_ref_same,
    core_type_fact_module_key, core_type_fact_ordinal,
    core_type_fact_same, core_type_fact_local_ref,
    SymbolRef, RegisteredNominalRef, NominalFieldRef,
    VariantRef, VariantFieldRef,
    HandledEffectRef, SystemEffectRef,
    ImplOwnerRef, ImplMethodRef,
    PathRef, PathOwnerRef, SlotRef, CalleeRef,
    OriginRef,
    symbol_ref_same, symbol_ref_origin_module_key,
    symbol_ref_namespace_kind,
    namespace_kind_same, namespace_effect, namespace_member,
    registered_nominal_ref_symbol, registered_nominal_ref_same,
    nominal_field_ref_same, nominal_field_ref_owner, nominal_field_ref_index,
    variant_ref_owner, variant_ref_same,
    variant_field_ref_variant, variant_field_ref_same,
    handled_effect_ref_same, system_effect_ref_same,
    impl_owner_ref_same, impl_owner_ref_target, impl_owner_ref_trait,
    impl_method_ref_owner,
    impl_method_ref_callable_slot_index, impl_method_ref_member,
    impl_method_ref_same,
    trait_method_ref_trait, trait_method_ref_member,
    intrinsic_ref_symbol,
    path_ref_same, path_ref_owner,
    path_owner_ref_is_symbol, path_owner_ref_symbol,
    path_owner_ref_module_body,
    module_body_ref_origin_module_key,
    slot_ref_same, slot_ref_is_source,
    slot_ref_source_origin_module_key, slot_ref_source_domain,
    slot_domain_dictionary, slot_domain_same,
    make_named_callee_ref, make_local_callee_ref, make_dynamic_callee_ref,
    callee_ref_same, origin_ref_same,
    origin_ref_is_symbol, origin_ref_symbol, origin_ref_path
}
use ir_inventory::{
    ExecutableRef, BinderKind, BinderEntry, HandledEvidenceRef,
    HandledEvidenceCapture,
    make_named_executable_ref,
    EffectOperationRef, SystemHostCallableRef, ExactMethodRef, ExactDictRef,
    ExecutableContractMode, executable_contract_mode_same,
    executable_contract_mode_concrete_body,
    executable_ref_same, executable_ref_is_named,
    executable_ref_named_symbol, executable_ref_origin_module_key,
    make_source_binder_entry, make_synthetic_binder_entry,
    binder_kind_tag, binder_kind_handled_evidence_local,
    binder_entry_slot, binder_entry_owner, binder_entry_kind, binder_entry_site,
    handled_evidence_requirement, handled_evidence_binding,
    handled_evidence_slot, handled_evidence_contract_owner,
    handled_evidence_ordinal, handled_evidence_ref_same,
    handled_evidence_capture_requirement,
    handled_evidence_capture_source, handled_evidence_capture_target,
    effect_operation_ref_effect, effect_operation_ref_callable,
    effect_operation_ref_same, effect_operation_ref_source_index,
    system_host_callable_effect, system_host_callable_executable,
    exact_method_ref_is_intrinsic, exact_method_ref_is_impl,
    exact_method_ref_is_trait, exact_method_ref_intrinsic,
    exact_method_ref_impl, exact_method_ref_trait,
    dict_ref_is_local, dict_ref_is_static, dict_ref_local, dict_ref_static,
    dict_ref_wrapped_base, dict_ref_wrapped_inner, dict_ref_same,
    binder_kind_dictionary_evidence_local,
    binder_kind_dictionary_evidence_param, binder_kind_lambda_capture
}
use effect_contract::{
    EffectParamRef, effect_param_owner, effect_param_ordinal,
    effect_param_ref_same,
    CoreEffectAtom, CoreEffectSet, CoreEffectContract,
    CoreEffectSubstitution, CoreEffectInstantiation,
    make_core_fail_effect, make_core_mut_effect, make_core_unsafe_effect,
    make_core_handled_effect, make_core_system_effect,
    core_effect_atom_kind_tag, core_effect_atom_type,
    core_effect_atom_handled_ref, core_effect_atom_type_arguments,
    core_effect_atom_system_ref,
    make_core_effect_set, core_effect_set_atoms, core_effect_set_same,
    core_effect_set_contains_atom,
    make_core_effect_contract, make_closed_core_effect_contract,
    core_effect_contract_exact, core_effect_contract_parameter,
    core_effect_contract_same, copy_core_effect_contract,
    make_core_effect_substitution, core_effect_substitution_parameter,
    core_effect_substitution_replacement,
    make_core_effect_instantiation, make_explicit_core_effect_instantiation,
    core_effect_instantiation_source,
    core_effect_instantiation_substitutions,
    core_effect_instantiation_result,
    core_effect_contract_handled_requirements
}
use core_type_source::{
    CoreTypeFactAllocator,
    new_core_type_fact_allocator, reserve_core_type_fact_ref,
}
use resource_model::{
    FlowCallContract, flow_call_contract_module_key,
    flow_call_contract_parameter_types, flow_call_contract_parameter_roles,
    flow_call_contract_result_type, flow_call_contract_result_role,
    flow_call_contract_result_origin, flow_semantic_role_tag,
    value_origin_same,
    FlowStorageContract, flow_storage_contract_tag
}
use core_type_source::{
    CoreTypeGraph, core_type_graph_count, core_type_graph_nodes,
    core_type_graph_node, core_type_graph_ref_from_flow,
    FlowTypeNode, FlowFieldIdentity, FlowNominalFieldFact,
    flow_type_node_kind, flow_type_node_children,
    flow_type_node_nominal, flow_type_node_nominal_fields,
    flow_type_node_parameter_count,
    flow_type_node_callable_effects,
    flow_type_node_generic_param,
    flow_type_kind_tag, flow_type_kind_int, flow_type_kind_float,
    flow_type_kind_str, flow_type_kind_bool, flow_type_kind_unit,
    flow_type_kind_never, flow_type_kind_struct, flow_type_kind_enum,
    flow_type_kind_tuple, flow_type_kind_record, flow_type_kind_callable,
    flow_type_kind_parameter,
    flow_nominal_field_identity, flow_nominal_field_type,
    flow_nominal_field_record_name,
    flow_field_identity_is_nominal, flow_field_identity_nominal,
    flow_field_identity_is_variant, flow_field_identity_variant,
    flow_field_identity_path,
    flow_type_actual_satisfies_formal,
    FlowTypeSubstitution, make_flow_type_substitution,
    flow_type_substitution_parameter,
    flow_type_substitution_replacement,
    copy_flow_type_substitutions,
    flow_generic_param_owner, flow_generic_param_index,
    flow_generic_param_arity, flow_generic_param_bounds,
    flow_generic_param_fact_same, flow_generic_param_identity_same,
    flow_type_actual_satisfies_substituted_formal,
    FlowEffectParamSubstitution, make_flow_effect_param_substitution,
    flow_type_actual_matches_formal_exact,
    remap_flow_call_contract
}

// ============================================================
// Exact typed/effect references
// ============================================================

pub struct CoreHandledEvidenceBinding {
    reference: HandledEvidenceRef,
    aggregate_type: CoreTypeRef
}

pub fn make_core_handled_evidence_binding(
    reference: HandledEvidenceRef, aggregate_type: CoreTypeRef
) -> CoreHandledEvidenceBinding {
    if core_type_ref_index(aggregate_type) < 0 ||
       !slot_ref_same(
            handled_evidence_slot(reference),
            binder_entry_slot(handled_evidence_binding(reference))) {
        panic("CoreHIR: invalid typed handled-evidence binding")
    }
    CoreHandledEvidenceBinding {
        reference: reference, aggregate_type: aggregate_type
    }
}
pub fn core_handled_evidence_reference(
    value: CoreHandledEvidenceBinding
) -> HandledEvidenceRef { value.reference }
pub fn core_handled_evidence_requirement(
    value: CoreHandledEvidenceBinding
) -> HandledEffectRef { handled_evidence_requirement(value.reference) }
pub fn core_handled_evidence_slot(
    value: CoreHandledEvidenceBinding
) -> SlotRef { handled_evidence_slot(value.reference) }
pub fn core_handled_evidence_owner(
    value: CoreHandledEvidenceBinding
) -> ExecutableRef { handled_evidence_contract_owner(value.reference) }
pub fn core_handled_evidence_ordinal(
    value: CoreHandledEvidenceBinding
) -> Int { handled_evidence_ordinal(value.reference) }
pub fn core_handled_evidence_type(
    value: CoreHandledEvidenceBinding
) -> CoreTypeRef { value.aggregate_type }
fn copy_handled_evidence_bindings(
    values: List<CoreHandledEvidenceBinding>
) -> List<CoreHandledEvidenceBinding> {
    let mut result: List<CoreHandledEvidenceBinding> = []
    for value in values {
        result.push(make_core_handled_evidence_binding(
            value.reference, value.aggregate_type))
    }
    result
}

pub struct CoreHandledEvidenceUse {
    reference: HandledEvidenceRef,
    aggregate_type: CoreTypeRef
}
pub fn make_core_handled_evidence_use(
    reference: HandledEvidenceRef, aggregate_type: CoreTypeRef
) -> CoreHandledEvidenceUse {
    if core_type_ref_index(aggregate_type) < 0 {
        panic("CoreHIR: invalid typed handled-evidence use")
    }
    CoreHandledEvidenceUse {
        reference: reference, aggregate_type: aggregate_type
    }
}
pub fn core_handled_use_reference(
    value: CoreHandledEvidenceUse
) -> HandledEvidenceRef { value.reference }
pub fn core_handled_use_requirement(
    value: CoreHandledEvidenceUse
) -> HandledEffectRef { handled_evidence_requirement(value.reference) }
pub fn core_handled_use_slot(value: CoreHandledEvidenceUse) -> SlotRef {
    handled_evidence_slot(value.reference)
}
pub fn core_handled_use_owner(value: CoreHandledEvidenceUse) -> ExecutableRef {
    handled_evidence_contract_owner(value.reference)
}
pub fn core_handled_use_ordinal(value: CoreHandledEvidenceUse) -> Int {
    handled_evidence_ordinal(value.reference)
}
pub fn core_handled_use_type(value: CoreHandledEvidenceUse) -> CoreTypeRef {
    value.aggregate_type
}
fn copy_handled_evidence_uses(
    values: List<CoreHandledEvidenceUse>
) -> List<CoreHandledEvidenceUse> {
    let mut result: List<CoreHandledEvidenceUse> = []
    for value in values {
        result.push(make_core_handled_evidence_use(
            value.reference, value.aggregate_type))
    }
    result
}

pub struct CoreHandledEvidenceCapture {
    reference: HandledEvidenceCapture,
    aggregate_type: CoreTypeRef
}
pub fn make_core_handled_evidence_capture(
    reference: HandledEvidenceCapture, aggregate_type: CoreTypeRef
) -> CoreHandledEvidenceCapture {
    if core_type_ref_index(aggregate_type) < 0 {
        panic("CoreHIR: invalid typed handled-evidence capture")
    }
    CoreHandledEvidenceCapture {
        reference: reference, aggregate_type: aggregate_type
    }
}
pub fn core_handled_capture_requirement(
    value: CoreHandledEvidenceCapture
) -> HandledEffectRef {
    handled_evidence_capture_requirement(value.reference)
}
pub fn core_handled_capture_source(
    value: CoreHandledEvidenceCapture
) -> HandledEvidenceRef {
    handled_evidence_capture_source(value.reference)
}
pub fn core_handled_capture_target(
    value: CoreHandledEvidenceCapture
) -> HandledEvidenceRef {
    handled_evidence_capture_target(value.reference)
}
pub fn core_handled_capture_type(
    value: CoreHandledEvidenceCapture
) -> CoreTypeRef { value.aggregate_type }
fn copy_handled_evidence_captures(
    values: List<CoreHandledEvidenceCapture>
) -> List<CoreHandledEvidenceCapture> {
    let mut result: List<CoreHandledEvidenceCapture> = []
    for value in values {
        result.push(make_core_handled_evidence_capture(
            value.reference, value.aggregate_type))
    }
    result
}

pub struct CoreCallableContract {
    reference: ExecutableRef,
    origin: OriginRef,
    header_type: CoreTypeRef,
    type_formals: List<CoreTypeRef>,
    effect_formals: List<EffectParamRef>,
    parameter_slots: List<SlotRef>,
    mode: ExecutableContractMode,
    semantic_contract: FlowCallContract,
    effects: CoreEffectContract,
    handled_evidence: List<CoreHandledEvidenceBinding>
}

fn copy_core_type_refs(values: List<CoreTypeRef>) -> List<CoreTypeRef> {
    let mut result: List<CoreTypeRef> = []
    for value in values { result.push(value) }
    result
}
fn copy_effect_param_refs(
    values: List<EffectParamRef>
) -> List<EffectParamRef> {
    values.map(fn(value) { value })
}
pub fn make_core_callable_contract(
    reference: ExecutableRef, origin: OriginRef,
    header_type: CoreTypeRef, type_formals: List<CoreTypeRef>,
    effect_formals: List<EffectParamRef>,
    parameter_slots: List<SlotRef>, mode: ExecutableContractMode,
    semantic_contract: FlowCallContract,
    effects: CoreEffectContract,
    handled_evidence: List<CoreHandledEvidenceBinding>
) -> CoreCallableContract {
    if core_type_ref_index(header_type) < 0 {
        panic("CoreHIR: callable header type is invalid")
    }
    let mut type_formal_index = 0
    while type_formal_index < type_formals.len() {
        let formal = type_formals.get(type_formal_index).unwrap()
        if core_type_ref_index(formal) < 0 {
            panic("CoreHIR: callable type formal is invalid")
        }
        let mut right = type_formal_index + 1
        while right < type_formals.len() {
            if core_type_ref_same(formal, type_formals.get(right).unwrap()) {
                panic("CoreHIR: callable repeats a type formal")
            }
            right = right + 1
        }
        type_formal_index = type_formal_index + 1
    }
    let mut effect_formal_index = 0
    while effect_formal_index < effect_formals.len() {
        let formal = effect_formals.get(effect_formal_index).unwrap()
        if !origin_ref_same(effect_param_owner(formal), origin) ||
           effect_param_ordinal(formal) != effect_formal_index {
            panic("CoreHIR: callable effect formal owner/order differs")
        }
        let mut right = effect_formal_index + 1
        while right < effect_formals.len() {
            if effect_param_ref_same(
                    formal, effect_formals.get(right).unwrap()) {
                panic("CoreHIR: callable repeats an effect formal")
            }
            right = right + 1
        }
        effect_formal_index = effect_formal_index + 1
    }
    let flow_parameters = flow_call_contract_parameter_types(semantic_contract)
    let concrete = executable_contract_mode_same(
        mode, executable_contract_mode_concrete_body())
    if (concrete && parameter_slots.len() != flow_parameters.len()) ||
       (!concrete && parameter_slots.len() != 0) {
        panic("CoreHIR: callable parameter-slot relation differs")
    }
    let mut left_index = 0
    while left_index < handled_evidence.len() {
        let left = handled_evidence.get(left_index).unwrap()
        if core_handled_evidence_ordinal(left) != left_index ||
           !executable_ref_same(
                core_handled_evidence_owner(left), reference) ||
           !executable_ref_same(
                binder_entry_owner(handled_evidence_binding(left.reference)),
                reference) {
            panic("CoreHIR: callable handled-evidence owner/order differs")
        }
        let mut right_index = left_index + 1
        while right_index < handled_evidence.len() {
            let right = handled_evidence.get(right_index).unwrap()
            if handled_effect_ref_same(
                    core_handled_evidence_requirement(left),
                    core_handled_evidence_requirement(right)) ||
               slot_ref_same(
                    core_handled_evidence_slot(left),
                    core_handled_evidence_slot(right)) ||
               handled_evidence_ref_same(left.reference, right.reference) {
                panic("CoreHIR: callable repeats handled evidence")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    CoreCallableContract {
        reference: reference, origin: origin,
        header_type: header_type,
        type_formals: copy_core_type_refs(type_formals),
        effect_formals: copy_effect_param_refs(effect_formals),
        parameter_slots: copy_slot_refs(parameter_slots),
        mode: mode,
        semantic_contract: semantic_contract,
        effects: copy_core_effect_contract(effects),
        handled_evidence: copy_handled_evidence_bindings(handled_evidence)
    }
}
pub fn core_callable_reference(value: CoreCallableContract) -> ExecutableRef {
    value.reference
}
pub fn core_callable_origin(value: CoreCallableContract) -> OriginRef {
    value.origin
}
pub fn core_callable_header_type(
    value: CoreCallableContract
) -> CoreTypeRef { value.header_type }
pub fn core_callable_type_formals(
    value: CoreCallableContract
) -> List<CoreTypeRef> { copy_core_type_refs(value.type_formals) }
pub fn core_callable_effect_formals(
    value: CoreCallableContract
) -> List<EffectParamRef> { copy_effect_param_refs(value.effect_formals) }
pub fn core_callable_parameter_types(
    value: CoreCallableContract
) -> List<CoreTypeRef> {
    flow_call_contract_parameter_types(value.semantic_contract).map(fn(ty) {
        match flow_call_contract_module_key(value.semantic_contract) {
            some(module_key) => make_module_core_type_ref(
                module_key, core_type_ref_index(ty)),
            none => ty
        }
    })
}
pub fn core_callable_parameter_slots(
    value: CoreCallableContract
) -> List<SlotRef> { copy_slot_refs(value.parameter_slots) }
pub fn core_callable_result_type(value: CoreCallableContract) -> CoreTypeRef {
    let ty = flow_call_contract_result_type(value.semantic_contract)
    match flow_call_contract_module_key(value.semantic_contract) {
        some(module_key) => make_module_core_type_ref(
            module_key, core_type_ref_index(ty)),
        none => ty
    }
}
pub fn core_callable_mode(value: CoreCallableContract) -> ExecutableContractMode {
    value.mode
}
pub fn core_callable_semantic_contract(
    value: CoreCallableContract
) -> FlowCallContract { value.semantic_contract }
pub fn core_callable_effect_contract(
    value: CoreCallableContract
) -> CoreEffectContract { copy_core_effect_contract(value.effects) }
pub fn core_callable_handled_evidence(
    value: CoreCallableContract
) -> List<CoreHandledEvidenceBinding> {
    copy_handled_evidence_bindings(value.handled_evidence)
}

pub struct CoreExecutableRedirect {
    source: ExecutableRef,
    target: ExecutableRef,
    type_formals: List<(CoreTypeRef, CoreTypeRef)>,
    effect_formals: List<(EffectParamRef, EffectParamRef)>
}
fn make_core_executable_redirect(
    source: ExecutableRef, target: ExecutableRef,
    type_formals: List<(CoreTypeRef, CoreTypeRef)>,
    effect_formals: List<(EffectParamRef, EffectParamRef)>
) -> CoreExecutableRedirect {
    if !executable_ref_is_named(source) ||
       !executable_ref_is_named(target) ||
       executable_ref_same(source, target) {
        panic("CoreHIR: executable redirect is invalid")
    }
    let mut type_index = 0
    while type_index < type_formals.len() {
        let left = type_formals.get(type_index).unwrap()
        if core_type_ref_index(left.0) < 0 ||
           core_type_ref_index(left.1) < 0 {
            panic("CoreHIR: executable redirect has an invalid type formal")
        }
        let mut right_index = type_index + 1
        while right_index < type_formals.len() {
            let right = type_formals.get(right_index).unwrap()
            if core_type_ref_same(left.0, right.0) ||
               core_type_ref_same(left.1, right.1) {
                panic("CoreHIR: executable redirect type mapping is not bijective")
            }
            right_index = right_index + 1
        }
        type_index = type_index + 1
    }
    let mut effect_index = 0
    while effect_index < effect_formals.len() {
        let left = effect_formals.get(effect_index).unwrap()
        let mut right_index = effect_index + 1
        while right_index < effect_formals.len() {
            let right = effect_formals.get(right_index).unwrap()
            if effect_param_ref_same(left.0, right.0) ||
               effect_param_ref_same(left.1, right.1) {
                panic("CoreHIR: executable redirect effect mapping is not bijective")
            }
            right_index = right_index + 1
        }
        effect_index = effect_index + 1
    }
    CoreExecutableRedirect {
        source: source, target: target,
        type_formals: type_formals.map(fn(pair) { (pair.0, pair.1) }),
        effect_formals: effect_formals.map(fn(pair) { (pair.0, pair.1) })
    }
}
pub fn core_executable_redirect_source(
    value: CoreExecutableRedirect
) -> ExecutableRef { value.source }
pub fn core_executable_redirect_target(
    value: CoreExecutableRedirect
) -> ExecutableRef { value.target }
pub fn copy_core_executable_redirects(
    values: List<CoreExecutableRedirect>
) -> List<CoreExecutableRedirect> {
    values.map(fn(value) {
        make_core_executable_redirect(
            value.source, value.target,
            value.type_formals, value.effect_formals)
    })
}

fn callable_redirect_semantic_shell_same(
    source: CoreCallableContract, target: CoreCallableContract
) -> Bool {
    let source_roles = flow_call_contract_parameter_roles(
        source.semantic_contract)
    let target_roles = flow_call_contract_parameter_roles(
        target.semantic_contract)
    if source_roles.len() != target_roles.len() ||
       flow_semantic_role_tag(flow_call_contract_result_role(
            source.semantic_contract)) !=
       flow_semantic_role_tag(flow_call_contract_result_role(
            target.semantic_contract)) ||
       !value_origin_same(
            flow_call_contract_result_origin(source.semantic_contract),
            flow_call_contract_result_origin(target.semantic_contract)) {
        return false
    }
    let mut index = 0
    while index < source_roles.len() {
        if flow_semantic_role_tag(source_roles.get(index).unwrap()) !=
           flow_semantic_role_tag(target_roles.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}

pub fn core_callable_redirect(
    source: CoreCallableContract, target: CoreCallableContract,
    graph: CoreTypeGraph
) -> CoreExecutableRedirect? {
    if source.type_formals.len() != target.type_formals.len() ||
       source.effect_formals.len() != target.effect_formals.len() ||
       source.handled_evidence.len() != target.handled_evidence.len() ||
       !callable_redirect_semantic_shell_same(source, target) ||
       !executable_ref_is_named(source.reference) ||
       !executable_ref_is_named(target.reference) {
        return none
    }
    let source_owner = executable_ref_named_symbol(source.reference)
    let target_owner = executable_ref_named_symbol(target.reference)
    let mut type_pairs: List<(CoreTypeRef, CoreTypeRef)> = []
    let mut type_substitutions: List<FlowTypeSubstitution> = []
    let mut type_index = 0
    while type_index < source.type_formals.len() {
        let source_formal = source.type_formals.get(type_index).unwrap()
        let target_formal = target.type_formals.get(type_index).unwrap()
        let source_node = core_type_graph_node(graph, source_formal)
        let target_node = core_type_graph_node(graph, target_formal)
        if flow_type_kind_tag(flow_type_node_kind(source_node)) !=
                flow_type_kind_tag(flow_type_kind_parameter()) ||
           flow_type_kind_tag(flow_type_node_kind(target_node)) !=
                flow_type_kind_tag(flow_type_kind_parameter()) {
            return none
        }
        let source_fact = flow_type_node_generic_param(source_node)
        let target_fact = flow_type_node_generic_param(target_node)
        if !symbol_ref_same(flow_generic_param_owner(source_fact), source_owner) ||
           !symbol_ref_same(flow_generic_param_owner(target_fact), target_owner) ||
           flow_generic_param_index(source_fact) != type_index ||
           flow_generic_param_index(target_fact) != type_index ||
           flow_generic_param_arity(source_fact) != source.type_formals.len() ||
           flow_generic_param_arity(target_fact) != target.type_formals.len() ||
           flow_generic_param_bounds(source_fact).len() != 0 ||
           flow_generic_param_bounds(target_fact).len() != 0 {
            return none
        }
        type_pairs.push((source_formal, target_formal))
        type_substitutions.push(make_flow_type_substitution(
            target_fact, source_formal))
        type_index = type_index + 1
    }
    let mut effect_pairs: List<(EffectParamRef, EffectParamRef)> = []
    let mut effect_substitutions: List<FlowEffectParamSubstitution> = []
    let mut effect_index = 0
    while effect_index < source.effect_formals.len() {
        let source_formal = source.effect_formals.get(effect_index).unwrap()
        let target_formal = target.effect_formals.get(effect_index).unwrap()
        if !origin_ref_same(effect_param_owner(source_formal), source.origin) ||
           !origin_ref_same(effect_param_owner(target_formal), target.origin) ||
           effect_param_ordinal(source_formal) != effect_index ||
           effect_param_ordinal(target_formal) != effect_index {
            return none
        }
        effect_pairs.push((source_formal, target_formal))
        effect_substitutions.push(make_flow_effect_param_substitution(
            target_formal, source_formal))
        effect_index = effect_index + 1
    }
    if !flow_type_actual_matches_formal_exact(
            core_type_graph_nodes(graph), source.header_type,
            target.header_type, type_substitutions,
            effect_substitutions) {
        return none
    }
    let mut handled_index = 0
    while handled_index < source.handled_evidence.len() {
        let left = source.handled_evidence.get(handled_index).unwrap()
        let right = target.handled_evidence.get(handled_index).unwrap()
        if !handled_effect_ref_same(
                core_handled_evidence_requirement(left),
                core_handled_evidence_requirement(right)) ||
           !core_type_ref_same(
                core_handled_evidence_type(left),
                core_handled_evidence_type(right)) {
            return none
        }
        handled_index = handled_index + 1
    }
    some(make_core_executable_redirect(
        source.reference, target.reference, type_pairs, effect_pairs))
}

fn copy_core_callable_contracts(
    values: List<CoreCallableContract>
) -> List<CoreCallableContract> {
    let mut result: List<CoreCallableContract> = []
    for value in values {
        result.push(make_core_callable_contract(
            value.reference, value.origin,
            value.header_type, value.type_formals, value.effect_formals,
            value.parameter_slots, value.mode,
            value.semantic_contract, value.effects, value.handled_evidence))
    }
    result
}
pub fn copy_core_callables(
    values: List<CoreCallableContract>
) -> List<CoreCallableContract> { copy_core_callable_contracts(values) }

// ============================================================
// Exact callable/evidence/member identities
// ============================================================
fn core_executable_redirect_for(
    value: ExecutableRef, redirects: List<CoreExecutableRedirect>
) -> CoreExecutableRedirect? {
    let mut found: CoreExecutableRedirect? = none
    for redirect in redirects {
        if executable_ref_same(redirect.source, value) {
            if found.is_some() {
                panic("CoreHIR: executable redirect source repeats")
            }
            found = some(redirect)
        }
    }
    found
}
fn redirected_core_executable(
    value: ExecutableRef, redirects: List<CoreExecutableRedirect>
) -> ExecutableRef {
    match core_executable_redirect_for(value, redirects) {
        some(redirect) => redirect.target,
        none => value
    }
}

const CORE_CALLEE_DIRECT: Int = 0
const CORE_CALLEE_LOCAL: Int = 1
const CORE_CALLEE_DYNAMIC: Int = 2

pub struct CoreCalleeRef {
    callee: CalleeRef,
    kind: Int,
    direct: ExecutableRef?,
    local: SlotRef?,
    dynamic: PathRef?,
    contract: FlowCallContract,
    type_substitutions: List<FlowTypeSubstitution>,
    effects: CoreEffectInstantiation
}

pub fn make_core_direct_callee(
    value: ExecutableRef, contract: FlowCallContract,
    type_substitutions: List<FlowTypeSubstitution>,
    effects: CoreEffectInstantiation
) -> CoreCalleeRef {
    if !executable_ref_is_named(value) {
        panic("CoreHIR: direct callee is not a named executable")
    }
    let callee = make_named_callee_ref(executable_ref_named_symbol(value))
    CoreCalleeRef {
        callee: callee, kind: CORE_CALLEE_DIRECT,
        direct: some(value), local: none, dynamic: none,
        contract: contract,
        type_substitutions: copy_flow_type_substitutions(type_substitutions),
        effects: effects
    }
}
pub fn make_core_local_callee(
    value: SlotRef, contract: FlowCallContract,
    effects: CoreEffectInstantiation
) -> CoreCalleeRef {
    CoreCalleeRef {
        callee: make_local_callee_ref(value), kind: CORE_CALLEE_LOCAL,
        direct: none, local: some(value), dynamic: none,
        contract: contract, type_substitutions: [], effects: effects
    }
}
pub fn make_core_dynamic_callee(
    value: PathRef, contract: FlowCallContract,
    effects: CoreEffectInstantiation
) -> CoreCalleeRef {
    CoreCalleeRef {
        callee: make_dynamic_callee_ref(value), kind: CORE_CALLEE_DYNAMIC,
        direct: none, local: none, dynamic: some(value),
        contract: contract, type_substitutions: [], effects: effects
    }
}
pub fn core_callee_ref(value: CoreCalleeRef) -> CalleeRef { value.callee }
pub fn core_callee_kind_tag(value: CoreCalleeRef) -> Int { value.kind }
pub fn core_callee_direct(value: CoreCalleeRef) -> ExecutableRef {
    match value.direct {
        some(executable) => executable,
        none => panic("CoreHIR: non-direct callee has no ExecutableRef")
    }
}
pub fn core_callee_local(value: CoreCalleeRef) -> SlotRef {
    match value.local {
        some(slot) => slot,
        none => panic("CoreHIR: non-local callee has no SlotRef")
    }
}
pub fn core_callee_dynamic(value: CoreCalleeRef) -> PathRef {
    match value.dynamic {
        some(path) => path,
        none => panic("CoreHIR: non-dynamic callee has no PathRef")
    }
}
pub fn core_callee_contract(value: CoreCalleeRef) -> FlowCallContract {
    value.contract
}
pub fn core_callee_type_substitutions(
    value: CoreCalleeRef
) -> List<FlowTypeSubstitution> {
    copy_flow_type_substitutions(value.type_substitutions)
}
pub fn core_callee_effect_instantiation(
    value: CoreCalleeRef
) -> CoreEffectInstantiation {
    make_core_effect_instantiation(
        core_effect_instantiation_source(value.effects),
        core_effect_instantiation_substitutions(value.effects),
        core_effect_instantiation_result(value.effects))
}

enum CoreEvidenceRefValue {
    DictEvidenceValue(ExactDictRef)
}

pub struct CoreEvidenceRef { value: CoreEvidenceRefValue }

pub fn make_core_dict_evidence(value: ExactDictRef) -> CoreEvidenceRef {
    CoreEvidenceRef { value: CoreEvidenceRefValue::DictEvidenceValue(value) }
}
pub fn core_evidence_dict(value: CoreEvidenceRef) -> ExactDictRef {
    match value.value {
        CoreEvidenceRefValue::DictEvidenceValue(dict) => dict,
        _ => panic("CoreHIR: non-dictionary evidence has no DictRef")
    }
}
fn copy_evidence(values: List<CoreEvidenceRef>) -> List<CoreEvidenceRef> {
    let mut result: List<CoreEvidenceRef> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreAssocBinding {
    member: SymbolRef,
    ty: CoreTypeRef
}
pub fn make_core_assoc_binding(
    member: SymbolRef, ty: CoreTypeRef
) -> CoreAssocBinding {
    if !namespace_kind_same(
            symbol_ref_namespace_kind(member), namespace_member()) {
        panic("CoreHIR: associated binding is not an exact member")
    }
    CoreAssocBinding { member: member, ty: ty }
}
pub fn core_assoc_binding_member(value: CoreAssocBinding) -> SymbolRef {
    value.member
}
pub fn core_assoc_binding_type(value: CoreAssocBinding) -> CoreTypeRef {
    value.ty
}
fn copy_core_assoc_bindings(values: List<CoreAssocBinding>) -> List<CoreAssocBinding> {
    let mut result: List<CoreAssocBinding> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreImplMetadata {
    owner: ImplOwnerRef,
    methods: List<ImplMethodRef>,
    assoc_bindings: List<CoreAssocBinding>
}

pub fn make_core_impl_metadata(
    owner: ImplOwnerRef, methods: List<ImplMethodRef>,
    assoc_bindings: List<CoreAssocBinding>
) -> CoreImplMetadata {
    let mut method_index = 0
    while method_index < methods.len() {
        let method = methods.get(method_index).unwrap()
        if !impl_owner_ref_same(impl_method_ref_owner(method), owner) ||
           (method_index > 0 &&
            impl_method_ref_callable_slot_index(method) <=
                impl_method_ref_callable_slot_index(
                    methods.get(method_index - 1).unwrap())) {
            panic("CoreHIR: impl method owner/order differs")
        }
        method_index = method_index + 1
    }
    let mut assoc_index = 0
    while assoc_index < assoc_bindings.len() {
        let mut right_index = assoc_index + 1
        while right_index < assoc_bindings.len() {
            if symbol_ref_same(
                    assoc_bindings.get(assoc_index).unwrap().member,
                    assoc_bindings.get(right_index).unwrap().member) {
                panic("CoreHIR: impl repeats an associated binding")
            }
            right_index = right_index + 1
        }
        assoc_index = assoc_index + 1
    }
    CoreImplMetadata {
        owner: owner, methods: methods.map(fn(value) { value }),
        assoc_bindings: copy_core_assoc_bindings(assoc_bindings)
    }
}
pub fn core_impl_owner(value: CoreImplMetadata) -> ImplOwnerRef { value.owner }
pub fn core_impl_methods(value: CoreImplMetadata) -> List<ImplMethodRef> {
    value.methods.map(fn(method) { method })
}
pub fn core_impl_assoc_bindings(value: CoreImplMetadata) -> List<CoreAssocBinding> {
    copy_core_assoc_bindings(value.assoc_bindings)
}
pub fn copy_core_impl_metadata(values: List<CoreImplMetadata>) -> List<CoreImplMetadata> {
    let mut result: List<CoreImplMetadata> = []
    for value in values {
        result.push(make_core_impl_metadata(
            value.owner, value.methods, value.assoc_bindings))
    }
    result
}

enum CoreFieldRefValue {
    NominalFieldValue(NominalFieldRef),
    VariantFieldValue(VariantFieldRef),
    TupleFieldValue(Int),
    RecordFieldValue { path: PathRef, name: Str }
}

pub struct CoreFieldRef { value: CoreFieldRefValue }

pub fn make_core_nominal_field(value: NominalFieldRef) -> CoreFieldRef {
    CoreFieldRef { value: CoreFieldRefValue::NominalFieldValue(value) }
}
pub fn make_core_variant_field(value: VariantFieldRef) -> CoreFieldRef {
    CoreFieldRef { value: CoreFieldRefValue::VariantFieldValue(value) }
}
pub fn make_core_tuple_field(index: Int) -> CoreFieldRef {
    if index < 0 { panic("CoreHIR: negative tuple field index") }
    CoreFieldRef { value: CoreFieldRefValue::TupleFieldValue(index) }
}
pub fn make_core_record_field(value: PathRef, name: Str) -> CoreFieldRef {
    if name == "" { panic("CoreHIR: record field name is empty") }
    CoreFieldRef {
        value: CoreFieldRefValue::RecordFieldValue {
            path: value, name: name
        }
    }
}
pub fn core_field_ref_kind_tag(value: CoreFieldRef) -> Int {
    match value.value {
        CoreFieldRefValue::NominalFieldValue(_) => 0,
        CoreFieldRefValue::TupleFieldValue(_) => 1,
        CoreFieldRefValue::RecordFieldValue { .. } => 2,
        CoreFieldRefValue::VariantFieldValue(_) => 3
    }
}
pub fn core_field_ref_variant(value: CoreFieldRef) -> VariantFieldRef {
    match value.value {
        CoreFieldRefValue::VariantFieldValue(field) => field,
        _ => panic("CoreHIR: non-variant field has no VariantFieldRef")
    }
}
pub fn core_field_ref_nominal(value: CoreFieldRef) -> NominalFieldRef {
    match value.value {
        CoreFieldRefValue::NominalFieldValue(field) => field,
        _ => panic("CoreHIR: non-nominal field has no NominalFieldRef")
    }
}
pub fn core_field_ref_tuple_index(value: CoreFieldRef) -> Int {
    match value.value {
        CoreFieldRefValue::TupleFieldValue(index) => index,
        _ => panic("CoreHIR: non-tuple field has no index")
    }
}
pub fn core_field_ref_record_path(value: CoreFieldRef) -> PathRef {
    match value.value {
        CoreFieldRefValue::RecordFieldValue { path, .. } => path,
        _ => panic("CoreHIR: non-record field has no path")
    }
}
pub fn core_field_ref_record_name(value: CoreFieldRef) -> Str {
    match value.value {
        CoreFieldRefValue::RecordFieldValue { name, .. } => name,
        _ => panic("CoreHIR: non-record field has no structural name")
    }
}

pub fn core_field_ref_same(left: CoreFieldRef, right: CoreFieldRef) -> Bool {
    match (left.value, right.value) {
        (CoreFieldRefValue::NominalFieldValue(a),
         CoreFieldRefValue::NominalFieldValue(b)) => nominal_field_ref_same(a, b),
        (CoreFieldRefValue::VariantFieldValue(a),
         CoreFieldRefValue::VariantFieldValue(b)) => variant_field_ref_same(a, b),
        (CoreFieldRefValue::TupleFieldValue(a),
         CoreFieldRefValue::TupleFieldValue(b)) => a == b,
        (CoreFieldRefValue::RecordFieldValue { path: a, name: an },
         CoreFieldRefValue::RecordFieldValue { path: b, name: bn }) =>
            path_ref_same(a, b) && an == bn,
        _ => false
    }
}

enum CorePlaceRefValue {
    CoreSlotPlaceValue(SlotRef),
    CoreProjectPlaceValue {
        base: CoreExpr,
        field: CoreFieldRef,
        value_type: CoreTypeRef
    }
}
pub struct CorePlaceRef { value: CorePlaceRefValue }
pub fn make_core_slot_place(slot: SlotRef) -> CorePlaceRef {
    CorePlaceRef { value: CorePlaceRefValue::CoreSlotPlaceValue(slot) }
}
pub fn make_core_project_place(
    base: CoreExpr, field: CoreFieldRef, value_type: CoreTypeRef
) -> CorePlaceRef {
    CorePlaceRef { value: CorePlaceRefValue::CoreProjectPlaceValue {
        base: base, field: field,
        value_type: value_type
    } }
}
pub fn core_place_is_slot(value: CorePlaceRef) -> Bool {
    match value.value {
        CorePlaceRefValue::CoreSlotPlaceValue(_) => true,
        CorePlaceRefValue::CoreProjectPlaceValue { .. } => false
    }
}
pub fn core_place_slot(value: CorePlaceRef) -> SlotRef {
    match value.value {
        CorePlaceRefValue::CoreSlotPlaceValue(slot) => slot,
        _ => panic("CoreHIR: projected place has no direct slot")
    }
}
pub fn core_place_base(value: CorePlaceRef) -> CoreExpr {
    match value.value {
        CorePlaceRefValue::CoreProjectPlaceValue { base, .. } => base,
        _ => panic("CoreHIR: slot place has no projection base")
    }
}
pub fn core_place_field(value: CorePlaceRef) -> CoreFieldRef {
    match value.value {
        CorePlaceRefValue::CoreProjectPlaceValue { field, .. } => field,
        _ => panic("CoreHIR: slot place has no projection field")
    }
}
pub fn core_place_value_type(value: CorePlaceRef) -> CoreTypeRef {
    match value.value {
        CorePlaceRefValue::CoreProjectPlaceValue { value_type, .. } => value_type,
        _ => panic("CoreHIR: slot place type comes from body slot table")
    }
}

enum CoreConstructorRefValue {
    StructConstructorValue {
        owner: RegisteredNominalRef,
        fields: List<NominalFieldRef>
    },
    VariantConstructorValue(VariantRef),
    TupleConstructorValue(Int)
}

pub struct CoreConstructorRef {
    value: CoreConstructorRefValue,
    executable: ExecutableRef?
}

fn copy_nominal_field_refs(
    values: List<NominalFieldRef>
) -> List<NominalFieldRef> {
    let mut result: List<NominalFieldRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_core_struct_constructor(
    owner: RegisteredNominalRef, fields: List<NominalFieldRef>
) -> CoreConstructorRef {
    let owner_symbol = registered_nominal_ref_symbol(owner)
    let mut index = 0
    while index < fields.len() {
        let field = fields.get(index).unwrap()
        if !symbol_ref_same(nominal_field_ref_owner(field), owner_symbol) ||
           nominal_field_ref_index(field) != index {
            panic("CoreHIR: struct constructor field owner/order differs")
        }
        index = index + 1
    }
    CoreConstructorRef {
        value: CoreConstructorRefValue::StructConstructorValue {
            owner: owner, fields: copy_nominal_field_refs(fields)
        },
        executable: none
    }
}
pub fn make_core_variant_constructor(
    variant: VariantRef, executable: ExecutableRef
) -> CoreConstructorRef {
    CoreConstructorRef {
        value: CoreConstructorRefValue::VariantConstructorValue(variant),
        executable: some(executable)
    }
}
pub fn make_core_tuple_constructor(arity: Int) -> CoreConstructorRef {
    if arity < 0 { panic("CoreHIR: negative tuple constructor arity") }
    CoreConstructorRef {
        value: CoreConstructorRefValue::TupleConstructorValue(arity),
        executable: none
    }
}
pub fn core_constructor_kind_tag(value: CoreConstructorRef) -> Int {
    match value.value {
        CoreConstructorRefValue::StructConstructorValue { .. } => 0,
        CoreConstructorRefValue::VariantConstructorValue(_) => 1,
        CoreConstructorRefValue::TupleConstructorValue(_) => 2
    }
}
pub fn core_constructor_struct_owner(
    value: CoreConstructorRef
) -> RegisteredNominalRef {
    match value.value {
        CoreConstructorRefValue::StructConstructorValue { owner, .. } => owner,
        _ => panic("CoreHIR: constructor is not a struct")
    }
}
pub fn core_constructor_struct_fields(
    value: CoreConstructorRef
) -> List<NominalFieldRef> {
    match value.value {
        CoreConstructorRefValue::StructConstructorValue { fields, .. } =>
            copy_nominal_field_refs(fields),
        _ => panic("CoreHIR: constructor is not a struct")
    }
}
pub fn core_constructor_variant(value: CoreConstructorRef) -> VariantRef {
    match value.value {
        CoreConstructorRefValue::VariantConstructorValue(variant) => variant,
        _ => panic("CoreHIR: constructor is not a variant")
    }
}
pub fn core_constructor_arity(value: CoreConstructorRef) -> Int {
    match value.value {
        CoreConstructorRefValue::TupleConstructorValue(arity) => arity,
        _ => panic("CoreHIR: nominal constructor has no structural arity")
    }
}
pub fn core_constructor_executable(value: CoreConstructorRef) -> ExecutableRef? {
    value.executable
}

pub struct CoreFieldValue {
    field: CoreFieldRef,
    value: CoreExpr
}

pub fn make_core_field_value(
    field: CoreFieldRef, value: CoreExpr
) -> CoreFieldValue { CoreFieldValue { field: field, value: value } }
pub fn core_field_value_field(value: CoreFieldValue) -> CoreFieldRef { value.field }
pub fn core_field_value_expr(value: CoreFieldValue) -> CoreExpr { value.value }
fn copy_field_values(values: List<CoreFieldValue>) -> List<CoreFieldValue> {
    let mut result: List<CoreFieldValue> = []
    for value in values { result.push(value) }
    result
}

fn copy_core_field_refs(values: List<CoreFieldRef>) -> List<CoreFieldRef> {
    let mut result: List<CoreFieldRef> = []
    for value in values { result.push(value) }
    result
}

// ============================================================
// 0.1 literals, primitive operations, and patterns
// ============================================================

enum CoreLiteralValue {
    IntLiteralValue(Int),
    FloatLiteralValue(Float),
    StrLiteralValue(Str),
    BoolLiteralValue(Bool),
    UnitLiteralValue
}

pub struct CoreLiteral { value: CoreLiteralValue }

pub fn make_core_int_literal(value: Int) -> CoreLiteral {
    CoreLiteral { value: CoreLiteralValue::IntLiteralValue(value) }
}
pub fn make_core_float_literal(value: Float) -> CoreLiteral {
    CoreLiteral { value: CoreLiteralValue::FloatLiteralValue(value) }
}
pub fn make_core_str_literal(value: Str) -> CoreLiteral {
    CoreLiteral { value: CoreLiteralValue::StrLiteralValue(value) }
}
pub fn make_core_bool_literal(value: Bool) -> CoreLiteral {
    CoreLiteral { value: CoreLiteralValue::BoolLiteralValue(value) }
}
pub fn make_core_unit_literal() -> CoreLiteral {
    CoreLiteral { value: CoreLiteralValue::UnitLiteralValue }
}
pub fn core_literal_kind_tag(value: CoreLiteral) -> Int {
    match value.value {
        CoreLiteralValue::IntLiteralValue(_) => 0,
        CoreLiteralValue::FloatLiteralValue(_) => 1,
        CoreLiteralValue::StrLiteralValue(_) => 2,
        CoreLiteralValue::BoolLiteralValue(_) => 3,
        CoreLiteralValue::UnitLiteralValue => 4
    }
}
pub fn core_literal_int(value: CoreLiteral) -> Int {
    match value.value {
        CoreLiteralValue::IntLiteralValue(literal) => literal,
        _ => panic("CoreHIR: literal is not Int")
    }
}
pub fn core_literal_float(value: CoreLiteral) -> Float {
    match value.value {
        CoreLiteralValue::FloatLiteralValue(literal) => literal,
        _ => panic("CoreHIR: literal is not Float")
    }
}
pub fn core_literal_str(value: CoreLiteral) -> Str {
    match value.value {
        CoreLiteralValue::StrLiteralValue(literal) => literal,
        _ => panic("CoreHIR: literal is not Str")
    }
}
pub fn core_literal_bool(value: CoreLiteral) -> Bool {
    match value.value {
        CoreLiteralValue::BoolLiteralValue(literal) => literal,
        _ => panic("CoreHIR: literal is not Bool")
    }
}

const CORE_PRIMITIVE_ADD: Int = 0
const CORE_PRIMITIVE_SUB: Int = 1
const CORE_PRIMITIVE_MUL: Int = 2
const CORE_PRIMITIVE_DIV: Int = 3
const CORE_PRIMITIVE_MOD: Int = 4
const CORE_PRIMITIVE_NEGATE: Int = 5
const CORE_PRIMITIVE_NOT: Int = 6
const CORE_PRIMITIVE_LT: Int = 7
const CORE_PRIMITIVE_LE: Int = 8
const CORE_PRIMITIVE_GT: Int = 9
const CORE_PRIMITIVE_GE: Int = 10

pub struct CorePrimitiveOp { tag: Int }

pub fn make_core_primitive_op(tag: Int) -> CorePrimitiveOp {
    if tag < CORE_PRIMITIVE_ADD || tag > CORE_PRIMITIVE_GE {
        panic("CoreHIR: invalid 0.1 primitive operation")
    }
    CorePrimitiveOp { tag: tag }
}
pub fn core_primitive_op_tag(value: CorePrimitiveOp) -> Int {
    make_core_primitive_op(value.tag).tag
}

enum CorePatternValue {
    WildcardPatternValue,
    BindingPatternValue(SlotRef),
    LiteralPatternValue(CoreLiteral),
    TuplePatternValue(List<CorePattern>),
    StructPatternValue {
        owner: RegisteredNominalRef,
        fields: List<CorePatternField>
    },
    VariantPatternValue {
        variant: VariantRef,
        fields: List<CorePatternField>
    }
}

pub struct CorePattern {
    ty: CoreTypeRef,
    value: CorePatternValue
}

pub struct CorePatternField {
    field: CoreFieldRef,
    pattern: CorePattern
}

fn copy_patterns(values: List<CorePattern>) -> List<CorePattern> {
    let mut result: List<CorePattern> = []
    for value in values { result.push(value) }
    result
}
fn copy_pattern_fields(values: List<CorePatternField>) -> List<CorePatternField> {
    let mut result: List<CorePatternField> = []
    for value in values { result.push(value) }
    result
}

pub fn make_core_wildcard_pattern(ty: CoreTypeRef) -> CorePattern {
    CorePattern { ty: ty, value: CorePatternValue::WildcardPatternValue }
}
pub fn make_core_binding_pattern(
    ty: CoreTypeRef, slot: SlotRef
) -> CorePattern {
    CorePattern { ty: ty, value: CorePatternValue::BindingPatternValue(slot) }
}
pub fn make_core_literal_pattern(
    ty: CoreTypeRef, literal: CoreLiteral
) -> CorePattern {
    CorePattern { ty: ty, value: CorePatternValue::LiteralPatternValue(literal) }
}
pub fn make_core_tuple_pattern(
    ty: CoreTypeRef, elements: List<CorePattern>
) -> CorePattern {
    CorePattern { ty: ty, value: CorePatternValue::TuplePatternValue(
        copy_patterns(elements)) }
}
pub fn make_core_pattern_field(
    field: CoreFieldRef, pattern: CorePattern
) -> CorePatternField { CorePatternField { field: field, pattern: pattern } }
pub fn make_core_struct_pattern(
    ty: CoreTypeRef, owner: RegisteredNominalRef,
    fields: List<CorePatternField>
) -> CorePattern {
    CorePattern { ty: ty, value: CorePatternValue::StructPatternValue {
        owner: owner, fields: copy_pattern_fields(fields)
    } }
}
pub fn make_core_variant_pattern(
    ty: CoreTypeRef, variant: VariantRef,
    fields: List<CorePatternField>
) -> CorePattern {
    CorePattern { ty: ty, value: CorePatternValue::VariantPatternValue {
        variant: variant, fields: copy_pattern_fields(fields)
    } }
}
pub fn core_pattern_kind_tag(value: CorePattern) -> Int {
    match value.value {
        CorePatternValue::WildcardPatternValue => 0,
        CorePatternValue::BindingPatternValue(_) => 1,
        CorePatternValue::LiteralPatternValue(_) => 2,
        CorePatternValue::TuplePatternValue(_) => 3,
        CorePatternValue::StructPatternValue { .. } => 4,
        CorePatternValue::VariantPatternValue { .. } => 5
    }
}
pub fn core_pattern_type(value: CorePattern) -> CoreTypeRef { value.ty }
pub fn core_pattern_binding(value: CorePattern) -> SlotRef {
    match value.value {
        CorePatternValue::BindingPatternValue(slot) => slot,
        _ => panic("CoreHIR: pattern is not a binding")
    }
}
pub fn core_pattern_literal(value: CorePattern) -> CoreLiteral {
    match value.value {
        CorePatternValue::LiteralPatternValue(literal) => literal,
        _ => panic("CoreHIR: pattern is not a literal")
    }
}
pub fn core_pattern_elements(value: CorePattern) -> List<CorePattern> {
    match value.value {
        CorePatternValue::TuplePatternValue(elements) => copy_patterns(elements),
        _ => panic("CoreHIR: pattern is not a tuple")
    }
}
pub fn core_pattern_fields(value: CorePattern) -> List<CorePatternField> {
    match value.value {
        CorePatternValue::StructPatternValue { fields, .. } =>
            copy_pattern_fields(fields),
        CorePatternValue::VariantPatternValue { fields, .. } =>
            copy_pattern_fields(fields),
        _ => panic("CoreHIR: pattern has no fields")
    }
}
pub fn core_pattern_struct_owner(value: CorePattern) -> RegisteredNominalRef {
    match value.value {
        CorePatternValue::StructPatternValue { owner, .. } => owner,
        _ => panic("CoreHIR: pattern is not a struct")
    }
}
pub fn core_pattern_variant(value: CorePattern) -> VariantRef {
    match value.value {
        CorePatternValue::VariantPatternValue { variant, .. } => variant,
        _ => panic("CoreHIR: pattern is not a variant")
    }
}
pub fn core_pattern_field_ref(value: CorePatternField) -> CoreFieldRef {
    value.field
}
pub fn core_pattern_field_pattern(value: CorePatternField) -> CorePattern {
    value.pattern
}

// ============================================================
// Immutable structured Core expressions and statements
// ============================================================

pub struct CoreCapture {
    source: SlotRef,
    target: SlotRef
}
pub fn make_core_capture(source: SlotRef, target: SlotRef) -> CoreCapture {
    if slot_ref_same(source, target) {
        panic("CoreHIR: capture aliases its source")
    }
    CoreCapture { source: source, target: target }
}
pub fn core_capture_source(value: CoreCapture) -> SlotRef { value.source }
pub fn core_capture_target(value: CoreCapture) -> SlotRef { value.target }
fn copy_captures(values: List<CoreCapture>) -> List<CoreCapture> {
    let mut result: List<CoreCapture> = []
    for value in values { result.push(value) }
    result
}

enum CoreExprValue {
    LiteralExprValue(CoreLiteral),
    CallableValueExprValue {
        executable: ExecutableRef,
        evidence: List<CoreEvidenceRef>
    },
    ReadExprValue(SlotRef),
    PrimitiveExprValue { operation: CorePrimitiveOp, operands: List<CoreExpr> },
    CallExprValue {
        callee: CoreCalleeRef,
        arguments: List<CoreExpr>,
        evidence: List<CoreEvidenceRef>,
        handled_evidence: List<CoreHandledEvidenceUse>
    },
    MethodCallExprValue {
        callee: CoreCalleeRef,
        method: ExactMethodRef,
        receiver: CoreExpr,
        arguments: List<CoreExpr>,
        evidence: List<CoreEvidenceRef>,
        handled_evidence: List<CoreHandledEvidenceUse>
    },
    EffectCallExprValue {
        operation: EffectOperationRef,
        arguments: List<CoreExpr>,
        evidence: List<CoreEvidenceRef>,
        handled_evidence: List<CoreHandledEvidenceUse>
    },
    SystemCallExprValue {
        host: SystemHostCallableRef,
        arguments: List<CoreExpr>
    },
    FailRaiseExprValue { payload: CoreExpr },
    ProjectExprValue {
        base: CoreExpr,
        field: CoreFieldRef,
        partial: Bool
    },
    ConstructExprValue {
        constructor: CoreConstructorRef,
        fields: List<CoreFieldValue>
    },
    MoveUpdateExprValue {
        base: CoreExpr,
        constructor: CoreConstructorRef,
        schema: List<CoreFieldRef>,
        overrides: List<CoreFieldValue>
    },
    LambdaExprValue {
        executable: ExecutableRef,
        captures: List<CoreCapture>,
        handled_captures: List<CoreHandledEvidenceCapture>
    },
    BlockExprValue(CoreBlock),
    IfExprValue {
        condition: CoreExpr,
        then_block: CoreBlock,
        else_block: CoreBlock
    },
    MatchExprValue {
        scrutinee: CoreExpr,
        arms: List<CoreMatchArm>
    },
    TryCatchExprValue {
        body: CoreBlock,
        error_slot: SlotRef,
        arms: List<CoreMatchArm>
    },
    HandleExprValue {
        body: CoreBlock,
        installations: List<CoreHandlerInstallation>
    }
}

pub struct CoreExpr {
    ty: CoreTypeRef,
    effects: CoreEffectSet,
    origin: OriginRef,
    value: CoreExprValue
}

enum CoreStmtValue {
    Bind {
        target: SlotRef, value: CoreExpr, is_mutable: Bool,
        origin: OriginRef
    },
    Assign {
        target: CorePlaceRef, value: CoreExpr, origin: OriginRef
    },
    ExprStmt { value: CoreExpr, origin: OriginRef },
    While {
        condition: CoreExpr, body: CoreBlock, origin: OriginRef
    },
    Break { origin: OriginRef },
    Continue { origin: OriginRef },
    Return { value: CoreExpr?, origin: OriginRef }
}

pub struct CoreStmt { value: CoreStmtValue }

pub struct CoreBlock {
    statements: List<CoreStmt>,
    tail: CoreExpr?,
    origin: OriginRef
}

pub struct CoreMatchArm {
    pattern: CorePattern,
    guard: CoreExpr?,
    body: CoreBlock,
    origin: OriginRef
}

pub struct CoreHandlerOperation {
    operation: EffectOperationRef,
    executable: ExecutableRef,
    parameter_slots: List<SlotRef>,
    resume_slot: SlotRef?,
    captures: List<CoreCapture>,
    handled_captures: List<CoreHandledEvidenceCapture>,
    origin: OriginRef
}

pub struct CoreHandlerInstallation {
    evidence: CoreHandledEvidenceBinding,
    operations: List<CoreHandlerOperation>,
    origin: OriginRef
}

fn copy_slot_refs(values: List<SlotRef>) -> List<SlotRef> {
    let mut result: List<SlotRef> = []
    for value in values { result.push(value) }
    result
}
fn copy_statements(values: List<CoreStmt>) -> List<CoreStmt> {
    let mut result: List<CoreStmt> = []
    for value in values { result.push(value) }
    result
}
fn copy_match_arms(values: List<CoreMatchArm>) -> List<CoreMatchArm> {
    let mut result: List<CoreMatchArm> = []
    for value in values { result.push(value) }
    result
}
fn copy_handler_operations(
    values: List<CoreHandlerOperation>
) -> List<CoreHandlerOperation> {
    let mut result: List<CoreHandlerOperation> = []
    for value in values {
        result.push(CoreHandlerOperation {
            operation: value.operation, executable: value.executable,
            parameter_slots: copy_slot_refs(value.parameter_slots),
            resume_slot: value.resume_slot,
            captures: copy_captures(value.captures),
            handled_captures: copy_handled_evidence_captures(
                value.handled_captures),
            origin: value.origin
        })
    }
    result
}
fn copy_handler_installations(
    values: List<CoreHandlerInstallation>
) -> List<CoreHandlerInstallation> {
    let mut result: List<CoreHandlerInstallation> = []
    for value in values {
        result.push(CoreHandlerInstallation {
            evidence: make_core_handled_evidence_binding(
                value.evidence.reference, value.evidence.aggregate_type),
            operations: copy_handler_operations(value.operations),
            origin: value.origin
        })
    }
    result
}
fn make_core_expr(
    ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, value: CoreExprValue
) -> CoreExpr {
    CoreExpr {
        ty: ty,
        effects: make_core_effect_set(core_effect_set_atoms(effects)),
        origin: origin, value: value
    }
}

pub fn make_core_literal_expr(
    ty: CoreTypeRef, origin: OriginRef, literal: CoreLiteral
) -> CoreExpr {
    make_core_expr(ty, make_core_effect_set([]), origin,
        CoreExprValue::LiteralExprValue(literal))
}
pub fn make_core_read_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    source: SlotRef
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::ReadExprValue(source))
}
pub fn make_core_callable_value_expr(
    ty: CoreTypeRef, origin: OriginRef, executable: ExecutableRef,
    evidence: List<CoreEvidenceRef>
) -> CoreExpr {
    make_core_expr(ty, make_core_effect_set([]), origin,
        CoreExprValue::CallableValueExprValue {
            executable: executable, evidence: copy_evidence(evidence)
        })
}
fn copy_core_exprs(values: List<CoreExpr>) -> List<CoreExpr> {
    values.map(fn(value) { value })
}
pub fn make_core_primitive_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    operation: CorePrimitiveOp, operands: List<CoreExpr>
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::PrimitiveExprValue {
            operation: operation, operands: copy_core_exprs(operands)
        })
}
pub fn make_core_call_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    callee: CoreCalleeRef, arguments: List<CoreExpr>,
    evidence: List<CoreEvidenceRef>,
    handled_evidence: List<CoreHandledEvidenceUse>
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::CallExprValue {
            callee: callee, arguments: copy_core_exprs(arguments),
            evidence: copy_evidence(evidence),
            handled_evidence: copy_handled_evidence_uses(handled_evidence)
        })
}
pub fn make_core_method_call_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    callee: CoreCalleeRef, method: ExactMethodRef,
    receiver: CoreExpr, arguments: List<CoreExpr>,
    evidence: List<CoreEvidenceRef>,
    handled_evidence: List<CoreHandledEvidenceUse>
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::MethodCallExprValue {
            callee: callee, method: method, receiver: receiver,
            arguments: copy_core_exprs(arguments),
            evidence: copy_evidence(evidence),
            handled_evidence: copy_handled_evidence_uses(handled_evidence)
        })
}
pub fn make_core_effect_call_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    operation: EffectOperationRef, arguments: List<CoreExpr>,
    evidence: List<CoreEvidenceRef>,
    handled_evidence: List<CoreHandledEvidenceUse>
) -> CoreExpr {
    if handled_evidence.len() != 1 ||
       !handled_effect_ref_same(
            core_handled_use_requirement(
                handled_evidence.get(0).unwrap()),
            effect_operation_ref_effect(operation)) {
        panic("CoreHIR: custom effect call lacks one exact handled use")
    }
    make_core_expr(ty, effects, origin,
        CoreExprValue::EffectCallExprValue {
            operation: operation, arguments: copy_core_exprs(arguments),
            evidence: copy_evidence(evidence),
            handled_evidence: copy_handled_evidence_uses(handled_evidence)
        })
}
pub fn make_core_system_call_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    host: SystemHostCallableRef, arguments: List<CoreExpr>
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::SystemCallExprValue {
            host: host, arguments: copy_core_exprs(arguments)
        })
}
pub fn make_core_fail_raise_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    payload: CoreExpr
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::FailRaiseExprValue { payload: payload })
}
pub fn make_core_project_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    base: CoreExpr, field: CoreFieldRef, partial: Bool
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::ProjectExprValue {
            base: base, field: field, partial: partial
        })
}
pub fn make_core_construct_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    constructor: CoreConstructorRef,
    fields: List<CoreFieldValue>
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::ConstructExprValue {
            constructor: constructor, fields: copy_field_values(fields)
        })
}
pub fn make_core_move_update_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    base: CoreExpr, constructor: CoreConstructorRef,
    schema: List<CoreFieldRef>, overrides: List<CoreFieldValue>
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::MoveUpdateExprValue {
            base: base, constructor: constructor,
            schema: copy_core_field_refs(schema),
            overrides: copy_field_values(overrides)
        })
}
pub fn make_core_lambda_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    executable: ExecutableRef, captures: List<CoreCapture>,
    handled_captures: List<CoreHandledEvidenceCapture>
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::LambdaExprValue {
            executable: executable, captures: copy_captures(captures),
            handled_captures: copy_handled_evidence_captures(handled_captures)
        })
}

pub fn make_core_block(
    statements: List<CoreStmt>, tail: CoreExpr?, origin: OriginRef
) -> CoreBlock {
    CoreBlock {
        statements: copy_statements(statements), tail: tail, origin: origin
    }
}
pub fn make_core_match_arm(
    pattern: CorePattern, guard: CoreExpr?, body: CoreBlock,
    origin: OriginRef
) -> CoreMatchArm {
    CoreMatchArm {
        pattern: pattern, guard: guard, body: body, origin: origin
    }
}
pub fn make_core_handler_operation(
    operation: EffectOperationRef, executable: ExecutableRef,
    parameter_slots: List<SlotRef>,
    resume_slot: SlotRef?,
    captures: List<CoreCapture>,
    handled_captures: List<CoreHandledEvidenceCapture>,
    origin: OriginRef
) -> CoreHandlerOperation {
    CoreHandlerOperation {
        operation: operation, executable: executable,
        parameter_slots: copy_slot_refs(parameter_slots),
        resume_slot: resume_slot,
        captures: copy_captures(captures),
        handled_captures: copy_handled_evidence_captures(handled_captures),
        origin: origin
    }
}
pub fn make_core_handler_installation(
    evidence: CoreHandledEvidenceBinding,
    operations: List<CoreHandlerOperation>, origin: OriginRef
) -> CoreHandlerInstallation {
    if operations.len() == 0 {
        panic("CoreHIR: handled effect installation has no operations")
    }
    if binder_kind_tag(binder_entry_kind(
            handled_evidence_binding(evidence.reference))) !=
       binder_kind_tag(binder_kind_handled_evidence_local()) {
        panic("CoreHIR: handled installation evidence is not local")
    }
    let requirement = core_handled_evidence_requirement(evidence)
    let mut index = 0
    while index < operations.len() {
        let operation = operations.get(index).unwrap()
        if !handled_effect_ref_same(
                effect_operation_ref_effect(operation.operation), requirement) ||
           effect_operation_ref_source_index(operation.operation) != index {
            panic("CoreHIR: handler operation effect/order differs")
        }
        let mut right = index + 1
        while right < operations.len() {
            let other = operations.get(right).unwrap()
            if effect_operation_ref_same(
                    operation.operation, other.operation) ||
               executable_ref_same(operation.executable, other.executable) {
                panic("CoreHIR: handler operation/executable is duplicated")
            }
            right = right + 1
        }
        index = index + 1
    }
    CoreHandlerInstallation {
        evidence: evidence,
        operations: copy_handler_operations(operations), origin: origin
    }
}
pub fn make_core_block_expr(
    ty: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef,
    block: CoreBlock
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::BlockExprValue(block))
}
pub fn make_core_if_expr(
    ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, condition: CoreExpr,
    then_block: CoreBlock, else_block: CoreBlock
) -> CoreExpr {
    make_core_expr(ty, effects, origin,
        CoreExprValue::IfExprValue {
            condition: condition,
            then_block: then_block, else_block: else_block
        })
}
pub fn make_core_match_expr(
    ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, scrutinee: CoreExpr, arms: List<CoreMatchArm>
) -> CoreExpr {
    if arms.len() == 0 { panic("CoreHIR: match has no arms") }
    make_core_expr(ty, effects, origin,
        CoreExprValue::MatchExprValue {
            scrutinee: scrutinee, arms: copy_match_arms(arms)
        })
}
pub fn make_core_try_catch_expr(
    ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, body: CoreBlock, error_slot: SlotRef,
    arms: List<CoreMatchArm>
) -> CoreExpr {
    if arms.len() == 0 { panic("CoreHIR: catch has no arms") }
    make_core_expr(ty, effects, origin,
        CoreExprValue::TryCatchExprValue {
            body: body, error_slot: error_slot,
            arms: copy_match_arms(arms)
        })
}
pub fn make_core_handle_expr(
    ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, body: CoreBlock,
    installations: List<CoreHandlerInstallation>
) -> CoreExpr {
    if installations.len() == 0 {
        panic("CoreHIR: handle has no effect installations")
    }
    let mut index = 0
    while index < installations.len() {
        let current = installations.get(index).unwrap()
        if index > 0 && core_handled_evidence_ordinal(current.evidence) <=
                core_handled_evidence_ordinal(
                    installations.get(index - 1).unwrap().evidence) {
            panic("CoreHIR: handled installations are not in exact order")
        }
        let mut right = index + 1
        while right < installations.len() {
            if handled_effect_ref_same(
                    core_handled_evidence_requirement(current.evidence),
                    core_handled_evidence_requirement(
                        installations.get(right).unwrap().evidence)) {
                panic("CoreHIR: handled installations repeat an effect")
            }
            right = right + 1
        }
        index = index + 1
    }
    make_core_expr(ty, effects, origin,
        CoreExprValue::HandleExprValue {
            body: body,
            installations: copy_handler_installations(installations)
        })
}

pub fn make_core_bind_stmt(
    target: SlotRef, value: CoreExpr, is_mutable: Bool,
    origin: OriginRef
) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::Bind {
        target: target, value: value, is_mutable: is_mutable, origin: origin
    } }
}
pub fn make_core_assign_stmt(
    target: CorePlaceRef, value: CoreExpr, origin: OriginRef
) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::Assign {
        target: target, value: value, origin: origin
    } }
}
pub fn make_core_expr_stmt(value: CoreExpr, origin: OriginRef) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::ExprStmt {
        value: value, origin: origin
    } }
}
pub fn make_core_while_stmt(
    condition: CoreExpr, body: CoreBlock, origin: OriginRef
) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::While {
        condition: condition, body: body, origin: origin
    } }
}
pub fn make_core_break_stmt(origin: OriginRef) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::Break { origin: origin } }
}
pub fn make_core_continue_stmt(origin: OriginRef) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::Continue { origin: origin } }
}
pub fn make_core_return_stmt(value: CoreExpr?, origin: OriginRef) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::Return {
        value: value, origin: origin
    } }
}

pub fn core_stmt_kind_tag(value: CoreStmt) -> Int {
    match value.value {
        CoreStmtValue::Bind { .. } => 0,
        CoreStmtValue::Assign { .. } => 1,
        CoreStmtValue::ExprStmt { .. } => 2,
        CoreStmtValue::While { .. } => 3,
        CoreStmtValue::Break { .. } => 4,
        CoreStmtValue::Continue { .. } => 5,
        CoreStmtValue::Return { .. } => 6
    }
}
pub fn core_stmt_origin(value: CoreStmt) -> OriginRef {
    match value.value {
        CoreStmtValue::Bind { origin, .. } => origin,
        CoreStmtValue::Assign { origin, .. } => origin,
        CoreStmtValue::ExprStmt { origin, .. } => origin,
        CoreStmtValue::While { origin, .. } => origin,
        CoreStmtValue::Break { origin } => origin,
        CoreStmtValue::Continue { origin } => origin,
        CoreStmtValue::Return { origin, .. } => origin
    }
}
pub fn core_stmt_target(value: CoreStmt) -> CorePlaceRef {
    match value.value {
        CoreStmtValue::Bind { target, .. } => make_core_slot_place(target),
        CoreStmtValue::Assign { target, .. } => target,
        _ => panic("CoreHIR: statement has no place target")
    }
}
pub fn core_stmt_value(value: CoreStmt) -> CoreExpr {
    match value.value {
        CoreStmtValue::Bind { value: expr, .. } => expr,
        CoreStmtValue::Assign { value: expr, .. } => expr,
        CoreStmtValue::ExprStmt { value: expr, .. } => expr,
        _ => panic("CoreHIR: statement has no required expression")
    }
}
pub fn core_stmt_bind_is_mutable(value: CoreStmt) -> Bool {
    match value.value {
        CoreStmtValue::Bind { is_mutable, .. } => is_mutable,
        _ => panic("CoreHIR: statement is not a source binding")
    }
}
pub fn core_stmt_while_condition(value: CoreStmt) -> CoreExpr {
    match value.value {
        CoreStmtValue::While { condition, .. } => condition,
        _ => panic("CoreHIR: statement is not While")
    }
}
pub fn core_stmt_while_body(value: CoreStmt) -> CoreBlock {
    match value.value {
        CoreStmtValue::While { body, .. } => body,
        _ => panic("CoreHIR: statement is not While")
    }
}
pub fn core_stmt_return_value(value: CoreStmt) -> CoreExpr? {
    match value.value {
        CoreStmtValue::Return { value: returned, .. } => returned,
        _ => panic("CoreHIR: statement is not Return")
    }
}

pub fn core_expr_type(value: CoreExpr) -> CoreTypeRef { value.ty }
pub fn core_expr_effects(value: CoreExpr) -> CoreEffectSet {
    make_core_effect_set(core_effect_set_atoms(value.effects))
}
pub fn core_expr_origin(value: CoreExpr) -> OriginRef { value.origin }
pub fn core_expr_kind_tag(value: CoreExpr) -> Int {
    match value.value {
        CoreExprValue::LiteralExprValue(_) => 0,
        CoreExprValue::ReadExprValue(_) => 1,
        CoreExprValue::PrimitiveExprValue { .. } => 2,
        CoreExprValue::CallExprValue { .. } => 3,
        CoreExprValue::MethodCallExprValue { .. } => 4,
        CoreExprValue::EffectCallExprValue { .. } => 5,
        CoreExprValue::SystemCallExprValue { .. } => 6,
        CoreExprValue::ProjectExprValue { .. } => 9,
        CoreExprValue::ConstructExprValue { .. } => 10,
        CoreExprValue::LambdaExprValue { .. } => 11,
        CoreExprValue::BlockExprValue(_) => 12,
        CoreExprValue::IfExprValue { .. } => 13,
        CoreExprValue::MatchExprValue { .. } => 14,
        CoreExprValue::TryCatchExprValue { .. } => 15,
        CoreExprValue::HandleExprValue { .. } => 16,
        CoreExprValue::CallableValueExprValue { .. } => 17,
        CoreExprValue::FailRaiseExprValue { .. } => 18,
        CoreExprValue::MoveUpdateExprValue { .. } => 19
    }
}
pub fn core_expr_literal(value: CoreExpr) -> CoreLiteral {
    match value.value {
        CoreExprValue::LiteralExprValue(literal) => literal,
        _ => panic("CoreHIR: expression is not Literal")
    }
}
pub fn core_expr_read_source(value: CoreExpr) -> SlotRef {
    match value.value {
        CoreExprValue::ReadExprValue(source) => source,
        _ => panic("CoreHIR: expression is not Read")
    }
}
pub fn core_expr_callable_executable(value: CoreExpr) -> ExecutableRef {
    match value.value {
        CoreExprValue::CallableValueExprValue { executable, .. } => executable,
        _ => panic("CoreHIR: expression is not an exact callable value")
    }
}
pub fn core_expr_callable_evidence(value: CoreExpr) -> List<CoreEvidenceRef> {
    match value.value {
        CoreExprValue::CallableValueExprValue { evidence, .. } =>
            copy_evidence(evidence),
        _ => panic("CoreHIR: expression is not an exact callable value")
    }
}
pub fn core_expr_primitive_operation(value: CoreExpr) -> CorePrimitiveOp {
    match value.value {
        CoreExprValue::PrimitiveExprValue { operation, .. } => operation,
        _ => panic("CoreHIR: expression is not Primitive")
    }
}
pub fn core_expr_primitive_operands(value: CoreExpr) -> List<CoreExpr> {
    match value.value {
        CoreExprValue::PrimitiveExprValue { operands, .. } =>
            copy_core_exprs(operands),
        _ => panic("CoreHIR: expression is not Primitive")
    }
}
pub fn core_expr_call_callee(value: CoreExpr) -> CoreCalleeRef {
    match value.value {
        CoreExprValue::CallExprValue { callee, .. } => callee,
        CoreExprValue::MethodCallExprValue { callee, .. } => callee,
        _ => panic("CoreHIR: expression has no callee")
    }
}
pub fn core_expr_call_arguments(value: CoreExpr) -> List<CoreExpr> {
    match value.value {
        CoreExprValue::CallExprValue { arguments, .. } =>
            copy_core_exprs(arguments),
        CoreExprValue::MethodCallExprValue { arguments, .. } =>
            copy_core_exprs(arguments),
        CoreExprValue::EffectCallExprValue { arguments, .. } =>
            copy_core_exprs(arguments),
        CoreExprValue::SystemCallExprValue { arguments, .. } =>
            copy_core_exprs(arguments),
        _ => panic("CoreHIR: expression has no call arguments")
    }
}
pub fn core_expr_call_evidence(value: CoreExpr) -> List<CoreEvidenceRef> {
    match value.value {
        CoreExprValue::CallExprValue { evidence, .. } =>
            copy_evidence(evidence),
        CoreExprValue::MethodCallExprValue { evidence, .. } =>
            copy_evidence(evidence),
        CoreExprValue::EffectCallExprValue { evidence, .. } =>
            copy_evidence(evidence),
        _ => panic("CoreHIR: expression has no evidence list")
    }
}
pub fn core_expr_call_handled_evidence(
    value: CoreExpr
) -> List<CoreHandledEvidenceUse> {
    match value.value {
        CoreExprValue::CallExprValue { handled_evidence, .. } =>
            copy_handled_evidence_uses(handled_evidence),
        CoreExprValue::MethodCallExprValue { handled_evidence, .. } =>
            copy_handled_evidence_uses(handled_evidence),
        CoreExprValue::EffectCallExprValue { handled_evidence, .. } =>
            copy_handled_evidence_uses(handled_evidence),
        _ => panic("CoreHIR: expression has no handled-evidence list")
    }
}
pub fn core_expr_method_ref(value: CoreExpr) -> ExactMethodRef {
    match value.value {
        CoreExprValue::MethodCallExprValue { method, .. } => method,
        _ => panic("CoreHIR: expression is not MethodCall")
    }
}
pub fn core_expr_method_receiver(value: CoreExpr) -> CoreExpr {
    match value.value {
        CoreExprValue::MethodCallExprValue { receiver, .. } => receiver,
        _ => panic("CoreHIR: expression is not MethodCall")
    }
}
pub fn core_expr_effect_operation(value: CoreExpr) -> EffectOperationRef {
    match value.value {
        CoreExprValue::EffectCallExprValue { operation, .. } => operation,
        _ => panic("CoreHIR: expression is not EffectCall")
    }
}
pub fn core_expr_system_host(value: CoreExpr) -> SystemHostCallableRef {
    match value.value {
        CoreExprValue::SystemCallExprValue { host, .. } => host,
        _ => panic("CoreHIR: expression is not SystemCall")
    }
}
pub fn core_expr_fail_payload(value: CoreExpr) -> CoreExpr {
    match value.value {
        CoreExprValue::FailRaiseExprValue { payload } => payload,
        _ => panic("CoreHIR: expression is not FailRaise")
    }
}
pub fn core_expr_project_base(value: CoreExpr) -> CoreExpr {
    match value.value {
        CoreExprValue::ProjectExprValue { base, .. } => base,
        _ => panic("CoreHIR: expression is not Project")
    }
}
pub fn core_expr_project_field(value: CoreExpr) -> CoreFieldRef {
    match value.value {
        CoreExprValue::ProjectExprValue { field, .. } => field,
        _ => panic("CoreHIR: expression is not Project")
    }
}
pub fn core_expr_project_is_partial(value: CoreExpr) -> Bool {
    match value.value {
        CoreExprValue::ProjectExprValue { partial, .. } => partial,
        _ => panic("CoreHIR: expression is not Project")
    }
}
pub fn core_expr_constructor(value: CoreExpr) -> CoreConstructorRef {
    match value.value {
        CoreExprValue::ConstructExprValue { constructor, .. } => constructor,
        _ => panic("CoreHIR: expression is not Construct")
    }
}
pub fn core_expr_constructor_fields(value: CoreExpr) -> List<CoreFieldValue> {
    match value.value {
        CoreExprValue::ConstructExprValue { fields, .. } =>
            copy_field_values(fields),
        _ => panic("CoreHIR: expression is not Construct")
    }
}
pub fn core_expr_move_update_base(value: CoreExpr) -> CoreExpr {
    match value.value {
        CoreExprValue::MoveUpdateExprValue { base, .. } => base,
        _ => panic("CoreHIR: expression is not MoveUpdate")
    }
}
pub fn core_expr_move_update_constructor(value: CoreExpr) -> CoreConstructorRef {
    match value.value {
        CoreExprValue::MoveUpdateExprValue { constructor, .. } => constructor,
        _ => panic("CoreHIR: expression is not MoveUpdate")
    }
}
pub fn core_expr_move_update_schema(value: CoreExpr) -> List<CoreFieldRef> {
    match value.value {
        CoreExprValue::MoveUpdateExprValue { schema, .. } =>
            copy_core_field_refs(schema),
        _ => panic("CoreHIR: expression is not MoveUpdate")
    }
}
pub fn core_expr_move_update_overrides(value: CoreExpr) -> List<CoreFieldValue> {
    match value.value {
        CoreExprValue::MoveUpdateExprValue { overrides, .. } =>
            copy_field_values(overrides),
        _ => panic("CoreHIR: expression is not MoveUpdate")
    }
}
pub fn core_expr_lambda_executable(value: CoreExpr) -> ExecutableRef {
    match value.value {
        CoreExprValue::LambdaExprValue { executable, .. } => executable,
        _ => panic("CoreHIR: expression is not Lambda")
    }
}
pub fn core_expr_lambda_captures(value: CoreExpr) -> List<CoreCapture> {
    match value.value {
        CoreExprValue::LambdaExprValue { captures, .. } => copy_captures(captures),
        _ => panic("CoreHIR: expression is not Lambda")
    }
}
pub fn core_expr_lambda_handled_captures(
    value: CoreExpr
) -> List<CoreHandledEvidenceCapture> {
    match value.value {
        CoreExprValue::LambdaExprValue { handled_captures, .. } =>
            copy_handled_evidence_captures(handled_captures),
        _ => panic("CoreHIR: expression is not Lambda")
    }
}
pub fn core_expr_block(value: CoreExpr) -> CoreBlock {
    match value.value {
        CoreExprValue::BlockExprValue(block) => block,
        _ => panic("CoreHIR: expression is not Block")
    }
}
pub fn core_expr_condition(value: CoreExpr) -> CoreExpr {
    match value.value {
        CoreExprValue::IfExprValue { condition, .. } => condition,
        _ => panic("CoreHIR: expression is not If")
    }
}
pub fn core_expr_then_block(value: CoreExpr) -> CoreBlock {
    match value.value {
        CoreExprValue::IfExprValue { then_block, .. } => then_block,
        _ => panic("CoreHIR: expression is not If")
    }
}
pub fn core_expr_else_block(value: CoreExpr) -> CoreBlock {
    match value.value {
        CoreExprValue::IfExprValue { else_block, .. } => else_block,
        _ => panic("CoreHIR: expression is not If")
    }
}
pub fn core_expr_scrutinee(value: CoreExpr) -> CoreExpr {
    match value.value {
        CoreExprValue::MatchExprValue { scrutinee, .. } => scrutinee,
        _ => panic("CoreHIR: expression is not Match")
    }
}
pub fn core_expr_match_arms(value: CoreExpr) -> List<CoreMatchArm> {
    match value.value {
        CoreExprValue::MatchExprValue { arms, .. } => copy_match_arms(arms),
        CoreExprValue::TryCatchExprValue { arms, .. } => copy_match_arms(arms),
        _ => panic("CoreHIR: expression has no match arms")
    }
}
pub fn core_expr_try_body(value: CoreExpr) -> CoreBlock {
    match value.value {
        CoreExprValue::TryCatchExprValue { body, .. } => body,
        _ => panic("CoreHIR: expression is not TryCatch")
    }
}
pub fn core_expr_error_slot(value: CoreExpr) -> SlotRef {
    match value.value {
        CoreExprValue::TryCatchExprValue { error_slot, .. } => error_slot,
        _ => panic("CoreHIR: expression is not TryCatch")
    }
}
pub fn core_expr_handle_body(value: CoreExpr) -> CoreBlock {
    match value.value {
        CoreExprValue::HandleExprValue { body, .. } => body,
        _ => panic("CoreHIR: expression is not Handle")
    }
}
pub fn core_expr_handler_installations(
    value: CoreExpr
) -> List<CoreHandlerInstallation> {
    match value.value {
        CoreExprValue::HandleExprValue { installations, .. } =>
            copy_handler_installations(installations),
        _ => panic("CoreHIR: expression is not Handle")
    }
}
pub fn core_block_statements(value: CoreBlock) -> List<CoreStmt> {
    copy_statements(value.statements)
}
pub fn core_block_tail(value: CoreBlock) -> CoreExpr? { value.tail }
pub fn core_block_origin(value: CoreBlock) -> OriginRef { value.origin }
pub fn core_match_arm_pattern(value: CoreMatchArm) -> CorePattern { value.pattern }
pub fn core_match_arm_guard(value: CoreMatchArm) -> CoreExpr? { value.guard }
pub fn core_match_arm_body(value: CoreMatchArm) -> CoreBlock { value.body }
pub fn core_match_arm_origin(value: CoreMatchArm) -> OriginRef { value.origin }
pub fn core_handler_operation_ref(
    value: CoreHandlerOperation
) -> EffectOperationRef { value.operation }
pub fn core_handler_operation_executable(
    value: CoreHandlerOperation
) -> ExecutableRef {
    value.executable
}
pub fn core_handler_operation_parameter_slots(
    value: CoreHandlerOperation
) -> List<SlotRef> {
    copy_slot_refs(value.parameter_slots)
}
pub fn core_handler_operation_resume_slot(
    value: CoreHandlerOperation
) -> SlotRef? {
    value.resume_slot
}
pub fn core_handler_operation_captures(
    value: CoreHandlerOperation
) -> List<CoreCapture> { copy_captures(value.captures) }
pub fn core_handler_operation_handled_captures(
    value: CoreHandlerOperation
) -> List<CoreHandledEvidenceCapture> {
    copy_handled_evidence_captures(value.handled_captures)
}
pub fn core_handler_operation_origin(
    value: CoreHandlerOperation
) -> OriginRef { value.origin }
pub fn core_handler_installation_evidence(
    value: CoreHandlerInstallation
) -> CoreHandledEvidenceBinding { value.evidence }
pub fn core_handler_installation_operations(
    value: CoreHandlerInstallation
) -> List<CoreHandlerOperation> {
    copy_handler_operations(value.operations)
}
pub fn core_handler_installation_origin(
    value: CoreHandlerInstallation
) -> OriginRef { value.origin }

// ============================================================
// Closed structured body and recursive validator
// ============================================================

// Core carries only language-semantic binders. Administrative result/temp,
// scope and control slots are allocated once by CoreHIR -> FlowIR lowering.
pub struct CoreBinder {
    reference: SlotRef,
    ty: CoreTypeRef,
    kind: BinderKind,
    site: PathRef,
    storage_contract: FlowStorageContract,
    is_mutable: Bool
}

pub fn make_core_binder(
    reference: SlotRef, ty: CoreTypeRef, kind: BinderKind,
    site: PathRef, storage_contract: FlowStorageContract,
    is_mutable: Bool
) -> CoreBinder {
    if core_type_ref_index(ty) < 0 {
        panic("CoreHIR: binder has a negative type reference")
    }
    let _ = flow_storage_contract_tag(storage_contract)
    CoreBinder {
        reference: reference, ty: ty, kind: kind, site: site,
        storage_contract: storage_contract, is_mutable: is_mutable
    }
}
pub fn core_binder_reference(value: CoreBinder) -> SlotRef { value.reference }
pub fn core_binder_type(value: CoreBinder) -> CoreTypeRef { value.ty }
pub fn core_binder_kind(value: CoreBinder) -> BinderKind { value.kind }
pub fn core_binder_site(value: CoreBinder) -> PathRef { value.site }
pub fn core_binder_storage_contract(
    value: CoreBinder
) -> FlowStorageContract { value.storage_contract }
pub fn core_binder_is_mutable(value: CoreBinder) -> Bool { value.is_mutable }
fn copy_core_binders(values: List<CoreBinder>) -> List<CoreBinder> {
    let mut result: List<CoreBinder> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreBody {
    reference: ExecutableRef,
    origin: OriginRef,
    binders: List<CoreBinder>,
    parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef,
    body: CoreBlock
}

fn path_module_key(value: PathRef) -> Str {
    let owner = path_ref_owner(value)
    if path_owner_ref_is_symbol(owner) {
        symbol_ref_origin_module_key(path_owner_ref_symbol(owner))
    } else {
        module_body_ref_origin_module_key(path_owner_ref_module_body(owner))
    }
}
fn origin_module_key(value: OriginRef) -> Str {
    if origin_ref_is_symbol(value) {
        symbol_ref_origin_module_key(origin_ref_symbol(value))
    } else {
        path_module_key(origin_ref_path(value))
    }
}
fn validate_origin(value: OriginRef, owner: ExecutableRef) {
    if origin_module_key(value) != executable_ref_origin_module_key(owner) {
        panic("CoreHIR: origin crosses executable module")
    }
}
fn type_ref_valid(value: CoreTypeRef, type_count: Int) -> Bool {
    core_type_ref_index(value) >= 0 &&
        core_type_ref_index(value) < type_count
}
fn binder_index(values: List<CoreBinder>, target: SlotRef) -> Int? {
    let mut index = 0
    for value in values {
        if slot_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}
fn require_binder(values: List<CoreBinder>, target: SlotRef) {
    if binder_index(values, target).is_none() {
        panic("CoreHIR: expression references an undeclared slot")
    }
}
fn exact_binder(values: List<CoreBinder>, target: SlotRef) -> CoreBinder {
    match binder_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("CoreHIR: expression references an undeclared slot")
    }
}
fn validate_effect_set(value: CoreEffectSet, type_count: Int) {
    let atoms = core_effect_set_atoms(value)
    let _ = make_core_effect_set(atoms)
    for atom in atoms {
        let kind = core_effect_atom_kind_tag(atom)
        if kind == 0 || kind == 1 {
            if !type_ref_valid(core_effect_atom_type(atom), type_count) {
                panic("CoreHIR: effect atom has an unresolved type")
            }
        } else if kind == 3 {
            for ty in core_effect_atom_type_arguments(atom) {
                if !type_ref_valid(ty, type_count) {
                    panic("CoreHIR: handled effect argument is unresolved")
                }
            }
        }
    }
}
fn validate_open_effect_set(value: CoreEffectSet) {
    let atoms = core_effect_set_atoms(value)
    let _ = make_core_effect_set(atoms)
    for atom in atoms {
        let kind = core_effect_atom_kind_tag(atom)
        if kind == 0 || kind == 1 {
            if core_type_ref_index(core_effect_atom_type(atom)) < 0 {
                panic("CoreHIR: effect atom has an invalid type")
            }
        } else if kind == 3 {
            for ty in core_effect_atom_type_arguments(atom) {
                if core_type_ref_index(ty) < 0 {
                    panic("CoreHIR: handled effect argument is invalid")
                }
            }
        }
    }
}
fn validate_dictionary_binder(value: ExactDictRef, body: CoreBody) {
    if dict_ref_is_local(value) {
        let slot = dict_ref_local(value)
        let binder = exact_binder(body.binders, slot)
        let kind = binder_kind_tag(core_binder_kind(binder))
        if kind != binder_kind_tag(binder_kind_dictionary_evidence_local()) &&
           kind != binder_kind_tag(binder_kind_dictionary_evidence_param()) &&
           kind != binder_kind_tag(binder_kind_lambda_capture()) {
            panic("CoreHIR: dictionary evidence uses a non-dictionary binder")
        }
        if slot_ref_is_source(slot) &&
           (slot_ref_source_origin_module_key(slot) !=
                executable_ref_origin_module_key(body.reference) ||
            !slot_domain_same(
                slot_ref_source_domain(slot), slot_domain_dictionary())) {
            panic("CoreHIR: dictionary evidence source slot crosses its owner/domain")
        }
        return
    }
    let owner = if dict_ref_is_static(value) {
        dict_ref_static(value)
    } else {
        for inner in dict_ref_wrapped_inner(value) {
            validate_dictionary_binder(inner, body)
        }
        dict_ref_wrapped_base(value)
    }
    if impl_owner_ref_trait(owner).is_none() {
        panic("CoreHIR: dictionary evidence names a non-trait impl")
    }
}

fn validate_evidence(values: List<CoreEvidenceRef>, body: CoreBody) {
    let mut index = 0
    while index < values.len() {
        let dict = core_evidence_dict(values.get(index).unwrap())
        validate_dictionary_binder(dict, body)
        let mut right = index + 1
        while right < values.len() {
            if dict_ref_same(
                    dict, core_evidence_dict(values.get(right).unwrap())) {
                panic("CoreHIR: call repeats exact dictionary evidence")
            }
            right = right + 1
        }
        index = index + 1
    }
}

fn validate_handled_evidence_uses(
    values: List<CoreHandledEvidenceUse>, body: CoreBody
) {
    let mut index = 0
    while index < values.len() {
        let value = values.get(index).unwrap()
        require_binder(body.binders, core_handled_use_slot(value))
        let binder = body.binders.get(
            binder_index(body.binders, core_handled_use_slot(value)).unwrap()
        ).unwrap()
        if !core_type_ref_same(binder.ty, value.aggregate_type) ||
           !executable_ref_same(core_handled_use_owner(value), body.reference) {
            panic("CoreHIR: handled-evidence use binder/type/owner differs")
        }
        let mut right = index + 1
        while right < values.len() {
            let other = values.get(right).unwrap()
            if handled_effect_ref_same(
                    core_handled_use_requirement(value),
                    core_handled_use_requirement(other)) ||
               slot_ref_same(
                    core_handled_use_slot(value),
                    core_handled_use_slot(other)) {
                panic("CoreHIR: call repeats handled-evidence use")
            }
            right = right + 1
        }
        index = index + 1
    }
}

fn validate_handled_installation(
    value: CoreHandlerInstallation, body: CoreBody
) {
    let slot = core_handled_evidence_slot(value.evidence)
    require_binder(body.binders, slot)
    let binder = body.binders.get(binder_index(body.binders, slot).unwrap()).unwrap()
    if !core_type_ref_same(binder.ty, value.evidence.aggregate_type) ||
       !executable_ref_same(
            core_handled_evidence_owner(value.evidence), body.reference) {
        panic("CoreHIR: handled installation evidence differs from body")
    }
}

fn validate_handled_captures(
    values: List<CoreHandledEvidenceCapture>,
    body: CoreBody, target_owner: ExecutableRef
) {
    let mut index = 0
    while index < values.len() {
        let value = values.get(index).unwrap()
        let source = core_handled_capture_source(value)
        let target = core_handled_capture_target(value)
        let source_slot = handled_evidence_slot(source)
        require_binder(body.binders, source_slot)
        let binder = body.binders.get(
            binder_index(body.binders, source_slot).unwrap()).unwrap()
        if !core_type_ref_same(binder.ty, value.aggregate_type) ||
           !executable_ref_same(
                handled_evidence_contract_owner(source), body.reference) ||
           !executable_ref_same(
                handled_evidence_contract_owner(target), target_owner) {
            panic("CoreHIR: handled capture owner/type differs")
        }
        let mut right = index + 1
        while right < values.len() {
            let other = values.get(right).unwrap()
            if handled_effect_ref_same(
                    core_handled_capture_requirement(value),
                    core_handled_capture_requirement(other)) ||
               slot_ref_same(
                    handled_evidence_slot(target),
                    handled_evidence_slot(
                        core_handled_capture_target(other))) {
                panic("CoreHIR: handled capture is duplicated")
            }
            right = right + 1
        }
        index = index + 1
    }
}

fn validate_pattern(
    value: CorePattern, binders: List<CoreBinder>, seen: List<SlotRef>
) -> List<SlotRef> {
    let mut result = copy_slot_refs(seen)
    match value.value {
        CorePatternValue::WildcardPatternValue |
        CorePatternValue::LiteralPatternValue(_) => {},
        CorePatternValue::BindingPatternValue(slot) => {
            require_binder(binders, slot)
            for existing in result {
                if slot_ref_same(existing, slot) {
                    panic("CoreHIR: pattern binds a slot twice")
                }
            }
            result.push(slot)
        },
        CorePatternValue::TuplePatternValue(elements) => {
            for element in elements {
                result = validate_pattern(element, binders, result)
            }
        },
        CorePatternValue::StructPatternValue { owner, fields } => {
            let owner_symbol = registered_nominal_ref_symbol(owner)
            let mut field_index = 0
            while field_index < fields.len() {
                let field = fields.get(field_index).unwrap()
                match field.field.value {
                    CoreFieldRefValue::NominalFieldValue(reference) => {
                        if !symbol_ref_same(
                                nominal_field_ref_owner(reference), owner_symbol) {
                            panic("CoreHIR: struct pattern field crosses owner")
                        }
                    },
                    _ => panic("CoreHIR: struct pattern uses non-nominal field")
                }
                let mut right_index = field_index + 1
                while right_index < fields.len() {
                    if core_field_ref_same(
                            field.field,
                            fields.get(right_index).unwrap().field) {
                        panic("CoreHIR: pattern repeats a field")
                    }
                    right_index = right_index + 1
                }
                result = validate_pattern(field.pattern, binders, result)
                field_index = field_index + 1
            }
        },
        CorePatternValue::VariantPatternValue { variant, fields } => {
            let mut field_index = 0
            while field_index < fields.len() {
                let field = fields.get(field_index).unwrap()
                match field.field.value {
                    CoreFieldRefValue::VariantFieldValue(reference) => {
                        if !variant_ref_same(
                                variant_field_ref_variant(reference), variant) {
                            panic("CoreHIR: variant pattern field crosses owner")
                        }
                    },
                    _ => panic("CoreHIR: variant pattern lacks VariantFieldRef")
                }
                let mut right_index = field_index + 1
                while right_index < fields.len() {
                    if core_field_ref_same(
                            field.field,
                            fields.get(right_index).unwrap().field) {
                        panic("CoreHIR: variant pattern repeats a field")
                    }
                    right_index = right_index + 1
                }
                result = validate_pattern(field.pattern, binders, result)
                field_index = field_index + 1
            }
        }
    }
    result
}

fn validate_callee(value: CoreCalleeRef, body: CoreBody) {
    if value.kind == CORE_CALLEE_DIRECT {
        let executable = match value.direct {
            some(item) => item,
            none => panic("CoreHIR: direct callee lacks executable")
        }
        if !callee_ref_same(
                value.callee,
                make_named_callee_ref(executable_ref_named_symbol(executable))) {
            panic("CoreHIR: direct CalleeRef/executable differs")
        }
    } else if value.kind == CORE_CALLEE_LOCAL {
        let slot = match value.local {
            some(item) => item,
            none => panic("CoreHIR: local callee lacks slot")
        }
        require_binder(body.binders, slot)
        if !callee_ref_same(value.callee, make_local_callee_ref(slot)) {
            panic("CoreHIR: local CalleeRef/slot differs")
        }
    } else if value.kind == CORE_CALLEE_DYNAMIC {
        let path = match value.dynamic {
            some(item) => item,
            none => panic("CoreHIR: dynamic callee lacks path")
        }
        if path_module_key(path) != executable_ref_origin_module_key(
                body.reference) ||
           !callee_ref_same(value.callee, make_dynamic_callee_ref(path)) {
            panic("CoreHIR: dynamic CalleeRef/path differs")
        }
    } else {
        panic("CoreHIR: unknown callee form")
    }
}

fn validate_constructor_fields(
    constructor: CoreConstructorRef, fields: List<CoreFieldValue>,
    body: CoreBody, loop_depth: Int
) {
    let mut index = 0
    while index < fields.len() {
        let field = fields.get(index).unwrap()
        validate_expr_with_loop_depth(field.value, body, loop_depth)
        let mut right_index = index + 1
        while right_index < fields.len() {
            if core_field_ref_same(
                    field.field, fields.get(right_index).unwrap().field) {
                panic("CoreHIR: constructor repeats a field")
            }
            right_index = right_index + 1
        }
        index = index + 1
    }
    match constructor.value {
        CoreConstructorRefValue::StructConstructorValue {
            owner, fields: contract_fields
        } => {
            let symbol = registered_nominal_ref_symbol(owner)
            if fields.len() != contract_fields.len() {
                panic("CoreHIR: struct constructor contract arity differs")
            }
            let mut field_index = 0
            while field_index < fields.len() {
                let field = fields.get(field_index).unwrap()
                match field.field.value {
                    CoreFieldRefValue::NominalFieldValue(reference) => if
                        !symbol_ref_same(
                            nominal_field_ref_owner(reference), symbol) ||
                        !nominal_field_ref_same(
                            reference,
                            contract_fields.get(field_index).unwrap()) {
                        panic("CoreHIR: struct constructor field order/owner differs")
                    },
                    _ => panic("CoreHIR: struct constructor uses non-nominal field")
                }
                field_index = field_index + 1
            }
        },
        CoreConstructorRefValue::VariantConstructorValue(variant) => {
            for field in fields {
                match field.field.value {
                    CoreFieldRefValue::VariantFieldValue(reference) => if
                        !variant_ref_same(
                            variant_field_ref_variant(reference), variant) {
                        panic("CoreHIR: variant constructor field crosses owner")
                    },
                    _ => panic("CoreHIR: variant constructor lacks VariantFieldRef")
                }
            }
        },
        CoreConstructorRefValue::TupleConstructorValue(arity) => {
            if fields.len() != arity {
                panic("CoreHIR: structural constructor arity differs")
            }
        }
    }
}

fn validate_expr_with_loop_depth(
    value: CoreExpr, body: CoreBody, loop_depth: Int
) {
    if core_type_ref_index(value.ty) < 0 {
        panic("CoreHIR: expression has an invalid type")
    }
    validate_origin(value.origin, body.reference)
    validate_open_effect_set(value.effects)
    match value.value {
        CoreExprValue::LiteralExprValue(_) => {},
        CoreExprValue::CallableValueExprValue { evidence, .. } =>
            validate_evidence(evidence, body),
        CoreExprValue::ReadExprValue(source) =>
            require_binder(body.binders, source),
        CoreExprValue::PrimitiveExprValue { operation, operands } => {
            let _ = core_primitive_op_tag(operation)
            for operand in operands {
                validate_expr_with_loop_depth(operand, body, loop_depth)
            }
        },
        CoreExprValue::CallExprValue {
            callee, arguments, evidence, handled_evidence
        } => {
            validate_callee(callee, body)
            for argument in arguments {
                validate_expr_with_loop_depth(argument, body, loop_depth)
            }
            validate_evidence(evidence, body)
            validate_handled_evidence_uses(handled_evidence, body)
        },
        CoreExprValue::MethodCallExprValue {
            callee, receiver, arguments, evidence, handled_evidence, ..
        } => {
            validate_callee(callee, body)
            validate_expr_with_loop_depth(receiver, body, loop_depth)
            for argument in arguments {
                validate_expr_with_loop_depth(argument, body, loop_depth)
            }
            validate_evidence(evidence, body)
            validate_handled_evidence_uses(handled_evidence, body)
        },
        CoreExprValue::EffectCallExprValue {
            operation, arguments, evidence, handled_evidence
        } => {
            for argument in arguments {
                validate_expr_with_loop_depth(argument, body, loop_depth)
            }
            validate_evidence(evidence, body)
            validate_handled_evidence_uses(handled_evidence, body)
            if handled_evidence.len() != 1 ||
               !handled_effect_ref_same(
                    core_handled_use_requirement(
                        handled_evidence.get(0).unwrap()),
                    effect_operation_ref_effect(operation)) {
                panic("CoreHIR: effect call handled use differs")
            }
        },
        CoreExprValue::SystemCallExprValue { arguments, .. } => {
            for argument in arguments {
                validate_expr_with_loop_depth(argument, body, loop_depth)
            }
        },
        CoreExprValue::FailRaiseExprValue { payload } =>
            validate_expr_with_loop_depth(payload, body, loop_depth),
        CoreExprValue::ProjectExprValue { base, .. } =>
            validate_expr_with_loop_depth(base, body, loop_depth),
        CoreExprValue::ConstructExprValue { constructor, fields } =>
            validate_constructor_fields(constructor, fields, body, loop_depth),
        CoreExprValue::MoveUpdateExprValue {
            base, constructor, schema, overrides
        } => {
            validate_expr_with_loop_depth(base, body, loop_depth)
            for override_value in overrides {
                validate_expr_with_loop_depth(
                    override_value.value, body, loop_depth)
                if !schema.any(fn(field) {
                        core_field_ref_same(field, override_value.field)
                    }) {
                    panic("CoreHIR: move update override is outside schema")
                }
            }
            let mut index = 0
            while index < schema.len() {
                let mut right = index + 1
                while right < schema.len() {
                    if core_field_ref_same(
                            schema.get(index).unwrap(),
                            schema.get(right).unwrap()) {
                        panic("CoreHIR: move update schema repeats a field")
                    }
                    right = right + 1
                }
                index = index + 1
            }
            let mut override_index = 0
            while override_index < overrides.len() {
                let mut right = override_index + 1
                while right < overrides.len() {
                    if core_field_ref_same(
                            overrides.get(override_index).unwrap().field,
                            overrides.get(right).unwrap().field) {
                        panic("CoreHIR: move update repeats an override")
                    }
                    right = right + 1
                }
                override_index = override_index + 1
            }
            match constructor.value {
                CoreConstructorRefValue::StructConstructorValue { .. } |
                CoreConstructorRefValue::VariantConstructorValue(_) => {},
                _ => panic("CoreHIR: move update constructor is not nominal")
            }
        },
        CoreExprValue::LambdaExprValue {
            executable, captures, handled_captures
        } => {
            for capture in captures {
                require_binder(body.binders, capture.source)
            }
            validate_handled_captures(handled_captures, body, executable)
        },
        CoreExprValue::BlockExprValue(block) =>
            validate_block_with_loop_depth(block, body, loop_depth),
        CoreExprValue::IfExprValue {
            condition, then_block, else_block
        } => {
            validate_expr_with_loop_depth(condition, body, loop_depth)
            validate_block_with_loop_depth(then_block, body, loop_depth)
            validate_block_with_loop_depth(else_block, body, loop_depth)
        },
        CoreExprValue::MatchExprValue { scrutinee, arms } => {
            validate_expr_with_loop_depth(scrutinee, body, loop_depth)
            for arm in arms { validate_match_arm(arm, body, loop_depth) }
        },
        CoreExprValue::TryCatchExprValue {
            body: protected, error_slot, arms
        } => {
            require_binder(body.binders, error_slot)
            validate_block_with_loop_depth(protected, body, loop_depth)
            for arm in arms { validate_match_arm(arm, body, loop_depth) }
        },
        CoreExprValue::HandleExprValue {
            body: handled_body, installations
        } => {
            validate_block_with_loop_depth(handled_body, body, loop_depth)
            let mut index = 0
            while index < installations.len() {
                let installation = installations.get(index).unwrap()
                validate_origin(installation.origin, body.reference)
                validate_handled_installation(installation, body)
                for operation in installation.operations {
                    validate_origin(operation.origin, operation.executable)
                    for capture in operation.captures {
                        require_binder(body.binders, capture.source)
                    }
                    validate_handled_captures(
                        operation.handled_captures,
                        body, operation.executable)
                }
                let mut right_index = index + 1
                while right_index < installations.len() {
                    let right = installations.get(right_index).unwrap()
                    if handled_effect_ref_same(
                            core_handled_evidence_requirement(
                                installation.evidence),
                            core_handled_evidence_requirement(right.evidence)) {
                        panic("CoreHIR: handle repeats an exact effect")
                    }
                    right_index = right_index + 1
                }
                index = index + 1
            }
        }
    }
}

fn validate_expr(value: CoreExpr, body: CoreBody) {
    validate_expr_with_loop_depth(value, body, 0)
}

fn validate_match_arm(
    value: CoreMatchArm, body: CoreBody, loop_depth: Int
) {
    validate_origin(value.origin, body.reference)
    let _ = validate_pattern(value.pattern, body.binders, [])
    match value.guard {
        some(guard) => validate_expr_with_loop_depth(
            guard, body, loop_depth),
        none => {}
    }
    validate_block_with_loop_depth(value.body, body, loop_depth)
}

fn validate_statement(value: CoreStmt, body: CoreBody, loop_depth: Int) {
    match value.value {
        CoreStmtValue::Bind { target, value: expr, origin, .. } => {
            validate_origin(origin, body.reference)
            require_binder(body.binders, target)
            validate_expr_with_loop_depth(expr, body, loop_depth)
        },
        CoreStmtValue::Assign { target, value: expr, origin } => {
            validate_origin(origin, body.reference)
            if core_place_is_slot(target) {
                require_binder(body.binders, core_place_slot(target))
            } else {
                validate_expr_with_loop_depth(
                    core_place_base(target), body, loop_depth)
            }
            validate_expr_with_loop_depth(expr, body, loop_depth)
        },
        CoreStmtValue::ExprStmt { value: expr, origin } => {
            validate_origin(origin, body.reference)
            validate_expr_with_loop_depth(expr, body, loop_depth)
        },
        CoreStmtValue::While { condition, body: loop_body, origin } => {
            validate_origin(origin, body.reference)
            validate_expr_with_loop_depth(condition, body, loop_depth)
            validate_block_with_loop_depth(loop_body, body, loop_depth + 1)
        },
        CoreStmtValue::Break { origin } => {
            validate_origin(origin, body.reference)
            if loop_depth <= 0 {
                panic("CoreHIR: loop control appears outside a loop")
            }
        },
        CoreStmtValue::Continue { origin } => {
            validate_origin(origin, body.reference)
            if loop_depth <= 0 {
                panic("CoreHIR: loop control appears outside a loop")
            }
        },
        CoreStmtValue::Return { value: returned, origin } => {
            validate_origin(origin, body.reference)
            match returned {
                some(expr) => validate_expr_with_loop_depth(
                    expr, body, loop_depth),
                none => {}
            }
        }
    }
}

fn validate_block_with_loop_depth(
    value: CoreBlock, body: CoreBody, loop_depth: Int
) {
    validate_origin(value.origin, body.reference)
    for statement in value.statements {
        validate_statement(statement, body, loop_depth)
    }
    match value.tail {
        some(expr) => validate_expr_with_loop_depth(expr, body, loop_depth),
        none => {}
    }
}
fn validate_block(value: CoreBlock, body: CoreBody) {
    validate_block_with_loop_depth(value, body, 0)
}

pub fn validate_core_body(value: CoreBody) {
    validate_origin(value.origin, value.reference)
    let mut binder_index_value = 0
    while binder_index_value < value.binders.len() {
        let binder = value.binders.get(binder_index_value).unwrap()
        if core_type_ref_index(binder.ty) < 0 {
            panic("CoreHIR: binder has an invalid type")
        }
        let entry = if slot_ref_is_source(binder.reference) {
            make_source_binder_entry(
                binder.reference, value.reference, binder.kind, binder.site)
        } else {
            make_synthetic_binder_entry(
                binder.reference, value.reference, binder.kind, binder.site)
        }
        if !slot_ref_same(binder_entry_slot(entry), binder.reference) ||
           !path_ref_same(binder_entry_site(entry), binder.site) {
            panic("CoreHIR: binder identity changed during validation")
        }
        let mut right_index = binder_index_value + 1
        while right_index < value.binders.len() {
            if slot_ref_same(
                    binder.reference,
                    value.binders.get(right_index).unwrap().reference) {
                panic("CoreHIR: body repeats a semantic binder")
            }
            right_index = right_index + 1
        }
        binder_index_value = binder_index_value + 1
    }
    let mut parameter_index = 0
    while parameter_index < value.parameter_slots.len() {
        let parameter = value.parameter_slots.get(parameter_index).unwrap()
        require_binder(value.binders, parameter)
        let mut right_index = parameter_index + 1
        while right_index < value.parameter_slots.len() {
            if slot_ref_same(
                    parameter,
                    value.parameter_slots.get(right_index).unwrap()) {
                panic("CoreHIR: body repeats a parameter slot")
            }
            right_index = right_index + 1
        }
        parameter_index = parameter_index + 1
    }
    validate_block(value.body, value)
}

pub fn make_core_body(
    reference: ExecutableRef, origin: OriginRef,
    binders: List<CoreBinder>, parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef, body: CoreBlock
) -> CoreBody {
    if core_type_ref_index(result_type) < 0 {
        panic("CoreHIR: body has an invalid result type")
    }
    let result = CoreBody {
        reference: reference, origin: origin,
        binders: copy_core_binders(binders),
        parameter_slots: copy_slot_refs(parameter_slots),
        result_type: result_type, body: body
    }
    validate_core_body(result)
    result
}

pub fn core_body_reference(value: CoreBody) -> ExecutableRef { value.reference }
pub fn core_body_origin(value: CoreBody) -> OriginRef { value.origin }
pub fn core_body_binders(value: CoreBody) -> List<CoreBinder> {
    copy_core_binders(value.binders)
}
pub fn core_body_parameter_slots(value: CoreBody) -> List<SlotRef> {
    copy_slot_refs(value.parameter_slots)
}
pub fn core_body_result_type(value: CoreBody) -> CoreTypeRef { value.result_type }
pub fn core_body_block(value: CoreBody) -> CoreBlock { value.body }

fn collect_expr_effect_sets(
    value: CoreExpr, mut result: List<CoreEffectSet>
) {
    result.push(make_core_effect_set(core_effect_set_atoms(value.effects)))
    match value.value {
        CoreExprValue::PrimitiveExprValue { operands, .. } => {
            for operand in operands { collect_expr_effect_sets(operand, result) }
        },
        CoreExprValue::CallExprValue { arguments, .. } => {
            for argument in arguments { collect_expr_effect_sets(argument, result) }
        },
        CoreExprValue::EffectCallExprValue { arguments, .. } => {
            for argument in arguments { collect_expr_effect_sets(argument, result) }
        },
        CoreExprValue::SystemCallExprValue { arguments, .. } => {
            for argument in arguments { collect_expr_effect_sets(argument, result) }
        },
        CoreExprValue::MethodCallExprValue { receiver, arguments, .. } => {
            collect_expr_effect_sets(receiver, result)
            for argument in arguments { collect_expr_effect_sets(argument, result) }
        },
        CoreExprValue::FailRaiseExprValue { payload } =>
            collect_expr_effect_sets(payload, result),
        CoreExprValue::ProjectExprValue { base, .. } =>
            collect_expr_effect_sets(base, result),
        CoreExprValue::ConstructExprValue { fields, .. } => {
            for field in fields { collect_expr_effect_sets(field.value, result) }
        },
        CoreExprValue::MoveUpdateExprValue { base, overrides, .. } => {
            collect_expr_effect_sets(base, result)
            for field in overrides {
                collect_expr_effect_sets(field.value, result)
            }
        },
        CoreExprValue::BlockExprValue(block) =>
            collect_block_effect_sets(block, result),
        CoreExprValue::IfExprValue { condition, then_block, else_block } => {
            collect_expr_effect_sets(condition, result)
            collect_block_effect_sets(then_block, result)
            collect_block_effect_sets(else_block, result)
        },
        CoreExprValue::MatchExprValue { scrutinee, arms } => {
            collect_expr_effect_sets(scrutinee, result)
            for arm in arms {
                match arm.guard {
                    some(guard) => collect_expr_effect_sets(guard, result),
                    none => {}
                }
                collect_block_effect_sets(arm.body, result)
            }
        },
        CoreExprValue::TryCatchExprValue { body, arms, .. } => {
            collect_block_effect_sets(body, result)
            for arm in arms {
                match arm.guard {
                    some(guard) => collect_expr_effect_sets(guard, result),
                    none => {}
                }
                collect_block_effect_sets(arm.body, result)
            }
        },
        CoreExprValue::HandleExprValue { body, .. } =>
            collect_block_effect_sets(body, result),
        _ => {}
    }
}

fn collect_statement_effect_sets(
    value: CoreStmt, mut result: List<CoreEffectSet>
) {
    match value.value {
        CoreStmtValue::Bind { value: expr, .. } =>
            collect_expr_effect_sets(expr, result),
        CoreStmtValue::ExprStmt { value: expr, .. } =>
            collect_expr_effect_sets(expr, result),
        CoreStmtValue::Assign { target, value: expr, .. } => {
            if !core_place_is_slot(target) {
                collect_expr_effect_sets(core_place_base(target), result)
            }
            collect_expr_effect_sets(expr, result)
        },
        CoreStmtValue::While { condition, body, .. } => {
            collect_expr_effect_sets(condition, result)
            collect_block_effect_sets(body, result)
        },
        CoreStmtValue::Return { value: returned, .. } => match returned {
            some(expr) => collect_expr_effect_sets(expr, result),
            none => {}
        },
        _ => {}
    }
}

fn collect_block_effect_sets(
    value: CoreBlock, mut result: List<CoreEffectSet>
) {
    for statement in value.statements {
        collect_statement_effect_sets(statement, result)
    }
    match value.tail {
        some(expr) => collect_expr_effect_sets(expr, result),
        none => {}
    }
}

pub fn core_body_effect_sets(value: CoreBody) -> List<CoreEffectSet> {
    let mut result: List<CoreEffectSet> = []
    collect_block_effect_sets(value.body, result)
    result
}

fn collect_core_expr_origins(value: CoreExpr, mut result: List<OriginRef>) {
    result.push(value.origin)
    match value.value {
        CoreExprValue::PrimitiveExprValue { operands, .. } => {
            for operand in operands { collect_core_expr_origins(operand, result) }
        },
        CoreExprValue::CallExprValue { arguments, .. } |
        CoreExprValue::EffectCallExprValue { arguments, .. } |
        CoreExprValue::SystemCallExprValue { arguments, .. } => {
            for argument in arguments {
                collect_core_expr_origins(argument, result)
            }
        },
        CoreExprValue::MethodCallExprValue { receiver, arguments, .. } => {
            collect_core_expr_origins(receiver, result)
            for argument in arguments { collect_core_expr_origins(argument, result) }
        },
        CoreExprValue::FailRaiseExprValue { payload } =>
            collect_core_expr_origins(payload, result),
        CoreExprValue::ProjectExprValue { base, .. } =>
            collect_core_expr_origins(base, result),
        CoreExprValue::ConstructExprValue { fields, .. } => {
            for field in fields { collect_core_expr_origins(field.value, result) }
        },
        CoreExprValue::MoveUpdateExprValue { base, overrides, .. } => {
            collect_core_expr_origins(base, result)
            for field in overrides {
                collect_core_expr_origins(field.value, result)
            }
        },
        CoreExprValue::BlockExprValue(block) =>
            collect_core_block_origins(block, result),
        CoreExprValue::IfExprValue { condition, then_block, else_block } => {
            collect_core_expr_origins(condition, result)
            collect_core_block_origins(then_block, result)
            collect_core_block_origins(else_block, result)
        },
        CoreExprValue::MatchExprValue { scrutinee, arms } => {
            collect_core_expr_origins(scrutinee, result)
            for arm in arms {
                result.push(arm.origin)
                match arm.guard {
                    some(guard) => collect_core_expr_origins(guard, result),
                    none => {}
                }
                collect_core_block_origins(arm.body, result)
            }
        },
        CoreExprValue::TryCatchExprValue { body, arms, .. } => {
            collect_core_block_origins(body, result)
            for arm in arms {
                result.push(arm.origin)
                match arm.guard {
                    some(guard) => collect_core_expr_origins(guard, result),
                    none => {}
                }
                collect_core_block_origins(arm.body, result)
            }
        },
        CoreExprValue::HandleExprValue { body, installations } => {
            collect_core_block_origins(body, result)
            for installation in installations {
                for operation in installation.operations {
                    result.push(operation.origin)
                }
            }
        },
        _ => {}
    }
}

fn collect_core_stmt_origins(value: CoreStmt, mut result: List<OriginRef>) {
    result.push(core_stmt_origin(value))
    match value.value {
        CoreStmtValue::Bind { value: expr, .. } |
        CoreStmtValue::Expr { value: expr, .. } =>
            collect_core_expr_origins(expr, result),
        CoreStmtValue::Assign { target, value: expr, .. } => {
            match target.value {
                CorePlaceRefValue::CoreProjectPlaceValue { base, .. } =>
                    collect_core_expr_origins(base, result),
                _ => {}
            }
            collect_core_expr_origins(expr, result)
        },
        CoreStmtValue::While { condition, body, .. } => {
            collect_core_expr_origins(condition, result)
            collect_core_block_origins(body, result)
        },
        CoreStmtValue::Return { value: returned, .. } => match returned {
            some(expr) => collect_core_expr_origins(expr, result), none => {}
        },
        _ => {}
    }
}

fn collect_core_block_origins(value: CoreBlock, mut result: List<OriginRef>) {
    result.push(value.origin)
    for statement in value.statements { collect_core_stmt_origins(statement, result) }
    match value.tail {
        some(expr) => collect_core_expr_origins(expr, result), none => {}
    }
}

pub fn core_body_origins(value: CoreBody) -> List<OriginRef> {
    let mut result: List<OriginRef> = [value.origin]
    collect_core_block_origins(value.body, result)
    result
}

// Core assembly first closes each module against its own opaque type-fact
// ordinals, then the project interner assigns the only global CoreTypeRef
// domain.  These rebuilders are the single typed rewrite boundary; downstream
// Flow lowering never sees module-local ordinals.
struct CoreRewriteContext {
    mapping: List<Int>?,
    module_key: Str?,
    redirects: List<CoreExecutableRedirect>,
    redirect_graph: CoreTypeGraph?
}
fn core_type_rewrite_context(
    mapping: List<Int>, module_key: Str
) -> CoreRewriteContext {
    CoreRewriteContext {
        mapping: some(mapping), module_key: some(module_key), redirects: [],
        redirect_graph: none
    }
}
fn core_executable_rewrite_context(
    redirects: List<CoreExecutableRedirect>, graph: CoreTypeGraph
) -> CoreRewriteContext {
    CoreRewriteContext {
        mapping: none, module_key: none,
        redirects: copy_core_executable_redirects(redirects),
        redirect_graph: some(graph)
    }
}
fn remap_core_type_reference(
    value: CoreTypeRef, ctx: CoreRewriteContext
) -> CoreTypeRef {
    match (ctx.mapping, ctx.module_key) {
        (some(mapping), some(module_key)) => {
            if value.module_key != some(module_key) {
                panic("CoreHIR: type reference belongs to another module recorder")
            }
            match mapping.get(core_type_ref_index(value)) {
                some(index) => make_core_type_ref(index),
                none => panic("CoreHIR: module-local type reference is out of range")
            }
        },
        (none, none) => value,
        _ => panic("CoreHIR: type rewrite context is partial")
    }
}

fn remap_core_effect_atom(
    value: CoreEffectAtom, ctx: CoreRewriteContext
) -> CoreEffectAtom {
    let kind = core_effect_atom_kind_tag(value)
    if kind == 0 {
        make_core_fail_effect(remap_core_type_reference(
            core_effect_atom_type(value), ctx))
    } else if kind == 1 {
        make_core_mut_effect(remap_core_type_reference(
            core_effect_atom_type(value), ctx))
    } else if kind == 2 {
        make_core_unsafe_effect()
    } else if kind == 3 {
        make_core_handled_effect(
            core_effect_atom_handled_ref(value),
            core_effect_atom_type_arguments(value).map(fn(ty) {
                remap_core_type_reference(ty, ctx)
            }))
    } else if kind == 4 {
        make_core_system_effect(core_effect_atom_system_ref(value))
    } else {
        panic("CoreHIR: unknown effect atom")
    }
}

fn remap_core_effect_set(
    value: CoreEffectSet, ctx: CoreRewriteContext
) -> CoreEffectSet {
    make_core_effect_set(core_effect_set_atoms(value).map(fn(atom) {
        remap_core_effect_atom(atom, ctx)
    }))
}

fn remap_core_effect_contract(
    value: CoreEffectContract, ctx: CoreRewriteContext
) -> CoreEffectContract {
    make_core_effect_contract(
        remap_core_effect_set(core_effect_contract_exact(value), ctx),
        core_effect_contract_parameter(value))
}
pub fn remap_core_effect_contract_types(
    value: CoreEffectContract, mapping: List<Int>, module_key: Str
) -> CoreEffectContract {
    remap_core_effect_contract(
        value, core_type_rewrite_context(mapping, module_key))
}

fn redirected_core_type_reference(
    value: CoreTypeRef, redirect: CoreExecutableRedirect
) -> CoreTypeRef {
    let mut found: CoreTypeRef? = none
    for pair in redirect.type_formals {
        if core_type_ref_same(pair.0, value) {
            if found.is_some() {
                panic("CoreHIR: redirect type formal source repeats")
            }
            found = some(pair.1)
        }
    }
    match found { some(target) => target, none => value }
}

fn redirected_effect_parameter(
    value: EffectParamRef, redirect: CoreExecutableRedirect
) -> EffectParamRef {
    let mut found: EffectParamRef? = none
    for pair in redirect.effect_formals {
        if effect_param_ref_same(pair.0, value) {
            if found.is_some() {
                panic("CoreHIR: redirect effect formal source repeats")
            }
            found = some(pair.1)
        }
    }
    match found { some(target) => target, none => value }
}

fn redirected_core_effect_atom(
    value: CoreEffectAtom, redirect: CoreExecutableRedirect
) -> CoreEffectAtom {
    let kind = core_effect_atom_kind_tag(value)
    if kind == 0 {
        make_core_fail_effect(redirected_core_type_reference(
            core_effect_atom_type(value), redirect))
    } else if kind == 1 {
        make_core_mut_effect(redirected_core_type_reference(
            core_effect_atom_type(value), redirect))
    } else if kind == 2 {
        make_core_unsafe_effect()
    } else if kind == 3 {
        make_core_handled_effect(
            core_effect_atom_handled_ref(value),
            core_effect_atom_type_arguments(value).map(fn(ty) {
                redirected_core_type_reference(ty, redirect)
            }))
    } else if kind == 4 {
        make_core_system_effect(core_effect_atom_system_ref(value))
    } else {
        panic("CoreHIR: unknown redirected effect atom")
    }
}

fn redirected_core_effect_contract(
    value: CoreEffectContract, redirect: CoreExecutableRedirect
) -> CoreEffectContract {
    make_core_effect_contract(
        make_core_effect_set(core_effect_set_atoms(
            core_effect_contract_exact(value)).map(fn(atom) {
                redirected_core_effect_atom(atom, redirect)
            })),
        core_effect_contract_parameter(value).map(fn(parameter) {
            redirected_effect_parameter(parameter, redirect)
        }))
}

fn redirected_type_substitution_parameter(
    value: FlowTypeSubstitution, redirect: CoreExecutableRedirect,
    graph: CoreTypeGraph
) -> FlowTypeSubstitution {
    let source_parameter = flow_type_substitution_parameter(value)
    let mut found: FlowTypeSubstitution? = none
    for pair in redirect.type_formals {
        let source_node = core_type_graph_node(graph, pair.0)
        let target_node = core_type_graph_node(graph, pair.1)
        let source_fact = flow_type_node_generic_param(source_node)
        if flow_generic_param_identity_same(source_fact, source_parameter) {
            if found.is_some() {
                panic("CoreHIR: redirect type substitution maps twice")
            }
            found = some(make_flow_type_substitution(
                flow_type_node_generic_param(target_node),
                flow_type_substitution_replacement(value)))
        }
    }
    match found {
        some(result) => result,
        none => panic("CoreHIR: redirect type substitution lacks declared formal")
    }
}

fn remap_core_effect_instantiation(
    value: CoreEffectInstantiation, ctx: CoreRewriteContext,
    redirect: CoreExecutableRedirect?
) -> CoreEffectInstantiation {
    match (ctx.mapping, ctx.module_key, redirect) {
        (some(_), some(_), none) => make_core_effect_instantiation(
            remap_core_effect_contract(
                core_effect_instantiation_source(value), ctx),
            core_effect_instantiation_substitutions(value).map(fn(item) {
                make_core_effect_substitution(
                    core_effect_substitution_parameter(item),
                    remap_core_effect_contract(
                        core_effect_substitution_replacement(item), ctx))
            }),
            remap_core_effect_contract(
                core_effect_instantiation_result(value), ctx)),
        (none, none, some(exact)) => make_core_effect_instantiation(
            redirected_core_effect_contract(
                core_effect_instantiation_source(value), exact),
            core_effect_instantiation_substitutions(value).map(fn(item) {
                make_core_effect_substitution(
                    redirected_effect_parameter(
                        core_effect_substitution_parameter(item), exact),
                    core_effect_substitution_replacement(item))
            }),
            core_effect_instantiation_result(value)),
        (none, none, none) => make_core_effect_instantiation(
            core_effect_instantiation_source(value),
            core_effect_instantiation_substitutions(value),
            core_effect_instantiation_result(value)),
        _ => panic("CoreHIR: effect-instantiation rewrite context is partial")
    }
}

fn remap_handled_binding(
    value: CoreHandledEvidenceBinding, ctx: CoreRewriteContext
) -> CoreHandledEvidenceBinding {
    make_core_handled_evidence_binding(
        value.reference, remap_core_type_reference(value.aggregate_type, ctx))
}
fn remap_handled_use(
    value: CoreHandledEvidenceUse, ctx: CoreRewriteContext
) -> CoreHandledEvidenceUse {
    make_core_handled_evidence_use(
        value.reference, remap_core_type_reference(value.aggregate_type, ctx))
}
fn remap_handled_uses(
    values: List<CoreHandledEvidenceUse>, ctx: CoreRewriteContext
) -> List<CoreHandledEvidenceUse> {
    let mut result: List<CoreHandledEvidenceUse> = []
    for value in values {
        result.push(remap_handled_use(value, ctx))
    }
    result
}

fn remap_core_callee(
    value: CoreCalleeRef, ctx: CoreRewriteContext
) -> CoreCalleeRef {
    let contract = match (ctx.mapping, ctx.module_key) {
        (some(mapping), some(module_key)) =>
            remap_flow_call_contract(value.contract, mapping, module_key),
        (none, none) => value.contract,
        _ => panic("CoreHIR: callee rewrite context is partial")
    }
    if value.kind == CORE_CALLEE_DIRECT {
        let redirect = core_executable_redirect_for(
            value.direct.unwrap(), ctx.redirects)
        let effects = remap_core_effect_instantiation(
            value.effects, ctx, redirect)
        let substitutions = match redirect {
            some(exact) => {
                let graph = match ctx.redirect_graph {
                    some(value) => value,
                    none => panic("CoreHIR: redirect type graph is absent")
                }
                value.type_substitutions.map(fn(item) {
                    redirected_type_substitution_parameter(
                        item, exact, graph)
                })
            },
            none => value.type_substitutions.map(fn(item) {
                make_flow_type_substitution(
                    flow_type_substitution_parameter(item),
                    remap_core_type_reference(
                        flow_type_substitution_replacement(item), ctx))
            })
        }
        make_core_direct_callee(
            match redirect {
                some(exact) => exact.target,
                none => value.direct.unwrap()
            },
            contract, substitutions, effects)
    } else if value.kind == CORE_CALLEE_LOCAL {
        make_core_local_callee(
            value.local.unwrap(), contract,
            remap_core_effect_instantiation(value.effects, ctx, none))
    } else if value.kind == CORE_CALLEE_DYNAMIC {
        make_core_dynamic_callee(
            value.dynamic.unwrap(), contract,
            remap_core_effect_instantiation(value.effects, ctx, none))
    } else {
        panic("CoreHIR: unknown callee form during type remap")
    }
}

fn remap_core_place(
    value: CorePlaceRef, ctx: CoreRewriteContext
) -> CorePlaceRef {
    match value.value {
        CorePlaceRefValue::CoreSlotPlaceValue(slot) => make_core_slot_place(slot),
        CorePlaceRefValue::CoreProjectPlaceValue {
            base, field, value_type
        } => make_core_project_place(
            remap_core_expr_types(base, ctx), field,
            remap_core_type_reference(value_type, ctx))
    }
}

fn remap_core_pattern(
    value: CorePattern, ctx: CoreRewriteContext
) -> CorePattern {
    let ty = remap_core_type_reference(value.ty, ctx)
    match value.value {
        CorePatternValue::WildcardPatternValue => make_core_wildcard_pattern(ty),
        CorePatternValue::BindingPatternValue(slot) =>
            make_core_binding_pattern(ty, slot),
        CorePatternValue::LiteralPatternValue(literal) =>
            make_core_literal_pattern(ty, literal),
        CorePatternValue::TuplePatternValue(elements) =>
            make_core_tuple_pattern(ty, elements.map(fn(element) {
                remap_core_pattern(element, ctx)
            })),
        CorePatternValue::StructPatternValue { owner, fields } =>
            make_core_struct_pattern(ty, owner, fields.map(fn(field) {
                make_core_pattern_field(
                    field.field, remap_core_pattern(
                        field.pattern, ctx))
            })),
        CorePatternValue::VariantPatternValue { variant, fields } =>
            make_core_variant_pattern(ty, variant, fields.map(fn(field) {
                make_core_pattern_field(
                    field.field, remap_core_pattern(
                        field.pattern, ctx))
            }))
    }
}

fn remap_core_block_types(
    value: CoreBlock, ctx: CoreRewriteContext
) -> CoreBlock {
    make_core_block(
        value.statements.map(fn(statement) {
            remap_core_statement_types(statement, ctx)
        }),
        match value.tail {
            some(tail) => some(remap_core_expr_types(tail, ctx)),
            none => none
        },
        value.origin)
}

fn remap_core_match_arm_types(
    value: CoreMatchArm, ctx: CoreRewriteContext
) -> CoreMatchArm {
    make_core_match_arm(
        remap_core_pattern(value.pattern, ctx),
        match value.guard {
            some(guard) => some(remap_core_expr_types(guard, ctx)),
            none => none
        },
        remap_core_block_types(value.body, ctx), value.origin)
}

fn remap_core_expr_types(
    value: CoreExpr, ctx: CoreRewriteContext
) -> CoreExpr {
    let ty = remap_core_type_reference(value.ty, ctx)
    let effects = remap_core_effect_set(value.effects, ctx)
    let payload = match value.value {
        CoreExprValue::LiteralExprValue(literal) =>
            CoreExprValue::LiteralExprValue(literal),
        CoreExprValue::CallableValueExprValue { executable, evidence } =>
            CoreExprValue::CallableValueExprValue {
                executable: redirected_core_executable(
                    executable, ctx.redirects),
                evidence: copy_evidence(evidence)
            },
        CoreExprValue::ReadExprValue(source) =>
            CoreExprValue::ReadExprValue(source),
        CoreExprValue::PrimitiveExprValue { operation, operands } =>
            CoreExprValue::PrimitiveExprValue {
                operation: operation, operands: operands.map(fn(operand) {
                    remap_core_expr_types(operand, ctx)
                })
            },
        CoreExprValue::CallExprValue {
            callee, arguments, evidence, handled_evidence
        } =>
            CoreExprValue::CallExprValue {
                callee: remap_core_callee(callee, ctx),
                arguments: arguments.map(fn(argument) {
                    remap_core_expr_types(argument, ctx)
                }),
                evidence: copy_evidence(evidence),
                handled_evidence: remap_handled_uses(handled_evidence, ctx)
            },
        CoreExprValue::MethodCallExprValue {
            callee, method, receiver, arguments, evidence, handled_evidence
        } => CoreExprValue::MethodCallExprValue {
            callee: remap_core_callee(callee, ctx),
            method: method,
            receiver: remap_core_expr_types(receiver, ctx),
            arguments: arguments.map(fn(argument) {
                remap_core_expr_types(argument, ctx)
            }),
            evidence: copy_evidence(evidence),
            handled_evidence: remap_handled_uses(handled_evidence, ctx)
        },
        CoreExprValue::EffectCallExprValue {
            operation, arguments, evidence, handled_evidence
        } => CoreExprValue::EffectCallExprValue {
            operation: operation, arguments: arguments.map(fn(argument) {
                remap_core_expr_types(argument, ctx)
            }),
            evidence: copy_evidence(evidence),
            handled_evidence: remap_handled_uses(handled_evidence, ctx)
        },
        CoreExprValue::SystemCallExprValue { host, arguments } =>
            CoreExprValue::SystemCallExprValue {
                host: host, arguments: arguments.map(fn(argument) {
                    remap_core_expr_types(argument, ctx)
                })
            },
        CoreExprValue::FailRaiseExprValue { payload } =>
            CoreExprValue::FailRaiseExprValue {
                payload: remap_core_expr_types(payload, ctx)
            },
        CoreExprValue::ProjectExprValue { base, field, partial } =>
            CoreExprValue::ProjectExprValue {
                base: remap_core_expr_types(base, ctx),
                field: field, partial: partial
            },
        CoreExprValue::ConstructExprValue { constructor, fields } =>
            CoreExprValue::ConstructExprValue {
                constructor: constructor, fields: fields.map(fn(field) {
                    make_core_field_value(
                        field.field, remap_core_expr_types(
                            field.value, ctx))
                })
            },
        CoreExprValue::MoveUpdateExprValue {
            base, constructor, schema, overrides
        } => CoreExprValue::MoveUpdateExprValue {
            base: remap_core_expr_types(base, ctx),
            constructor: constructor,
            schema: copy_core_field_refs(schema),
            overrides: overrides.map(fn(field) {
                make_core_field_value(
                    field.field, remap_core_expr_types(
                        field.value, ctx))
            })
        },
        CoreExprValue::LambdaExprValue {
            executable, captures, handled_captures
        } =>
            CoreExprValue::LambdaExprValue {
            executable: executable,
            captures: copy_captures(captures),
            handled_captures: handled_captures.map(fn(capture) {
                make_core_handled_evidence_capture(
                    capture.reference,
                    remap_core_type_reference(capture.aggregate_type, ctx))
            })
        },
        CoreExprValue::BlockExprValue(block) =>
            CoreExprValue::BlockExprValue(
                remap_core_block_types(block, ctx)),
        CoreExprValue::IfExprValue {
            condition, then_block, else_block
        } => CoreExprValue::IfExprValue {
            condition: remap_core_expr_types(condition, ctx),
            then_block: remap_core_block_types(then_block, ctx),
            else_block: remap_core_block_types(else_block, ctx)
        },
        CoreExprValue::MatchExprValue { scrutinee, arms } =>
            CoreExprValue::MatchExprValue {
                scrutinee: remap_core_expr_types(scrutinee, ctx),
                arms: arms.map(fn(arm) {
                    remap_core_match_arm_types(arm, ctx)
                })
            },
        CoreExprValue::TryCatchExprValue { body, error_slot, arms } =>
            CoreExprValue::TryCatchExprValue {
                body: remap_core_block_types(body, ctx),
                error_slot: error_slot,
                arms: arms.map(fn(arm) {
                    remap_core_match_arm_types(arm, ctx)
                })
            },
        CoreExprValue::HandleExprValue { body, installations } =>
            CoreExprValue::HandleExprValue {
                body: remap_core_block_types(body, ctx),
                installations: installations.map(fn(installation) {
                    CoreHandlerInstallation {
                        evidence: remap_handled_binding(
                            installation.evidence, ctx),
                        operations: installation.operations.map(fn(operation) {
                            CoreHandlerOperation {
                                operation: operation.operation,
                                executable: operation.executable,
                                parameter_slots: copy_slot_refs(
                                    operation.parameter_slots),
                                resume_slot: operation.resume_slot,
                                captures: copy_captures(operation.captures),
                                handled_captures:
                                    operation.handled_captures.map(fn(capture) {
                                        make_core_handled_evidence_capture(
                                            capture.reference,
                                            remap_core_type_reference(
                                                capture.aggregate_type, ctx))
                                    }),
                                origin: operation.origin
                            }
                        }),
                        origin: installation.origin
                    }
                })
            }
    }
    make_core_expr(ty, effects, value.origin, payload)
}

fn remap_core_statement_types(
    value: CoreStmt, ctx: CoreRewriteContext
) -> CoreStmt {
    match value.value {
        CoreStmtValue::Bind {
            target, value: expr, is_mutable, origin
        } => make_core_bind_stmt(
            target, remap_core_expr_types(expr, ctx),
            is_mutable, origin),
        CoreStmtValue::Assign { target, value: expr, origin } =>
            make_core_assign_stmt(
                remap_core_place(target, ctx),
                remap_core_expr_types(expr, ctx), origin),
        CoreStmtValue::ExprStmt { value: expr, origin } =>
            make_core_expr_stmt(
                remap_core_expr_types(expr, ctx), origin),
        CoreStmtValue::While { condition, body, origin } =>
            make_core_while_stmt(
                remap_core_expr_types(condition, ctx),
                remap_core_block_types(body, ctx), origin),
        CoreStmtValue::Break { origin } => make_core_break_stmt(origin),
        CoreStmtValue::Continue { origin } => make_core_continue_stmt(origin),
        CoreStmtValue::Return { value: returned, origin } =>
            make_core_return_stmt(match returned {
                some(expr) => some(remap_core_expr_types(expr, ctx)),
                none => none
            }, origin)
    }
}

pub fn remap_core_callable_types(
    value: CoreCallableContract, mapping: List<Int>, module_key: Str
) -> CoreCallableContract {
    let ctx = core_type_rewrite_context(mapping, module_key)
    make_core_callable_contract(
        value.reference, value.origin,
        remap_core_type_reference(value.header_type, ctx),
        value.type_formals.map(fn(formal) {
            remap_core_type_reference(formal, ctx)
        }),
        value.effect_formals,
        value.parameter_slots,
        value.mode,
        remap_flow_call_contract(value.semantic_contract, mapping, module_key),
        remap_core_effect_contract(value.effects, ctx),
        value.handled_evidence.map(fn(binding) {
            remap_handled_binding(binding, ctx)
        }))
}

pub fn remap_core_impl_types(
    value: CoreImplMetadata, mapping: List<Int>, module_key: Str
) -> CoreImplMetadata {
    let ctx = core_type_rewrite_context(mapping, module_key)
    make_core_impl_metadata(
        value.owner, value.methods,
        value.assoc_bindings.map(fn(binding) {
            make_core_assoc_binding(
                binding.member,
                remap_core_type_reference(binding.ty, ctx))
        }))
}

pub fn remap_core_body_types(
    value: CoreBody, mapping: List<Int>, module_key: Str
) -> CoreBody {
    let ctx = core_type_rewrite_context(mapping, module_key)
    make_core_body(
        value.reference, value.origin,
        value.binders.map(fn(binder) {
            make_core_binder(
                binder.reference,
                remap_core_type_reference(binder.ty, ctx),
                binder.kind, binder.site, binder.storage_contract,
                binder.is_mutable)
        }),
        value.parameter_slots,
        remap_core_type_reference(value.result_type, ctx),
        remap_core_block_types(value.body, ctx))
}

pub fn redirect_core_body_executables(
    value: CoreBody, redirects: List<CoreExecutableRedirect>,
    graph: CoreTypeGraph
) -> CoreBody {
    let ctx = core_executable_rewrite_context(redirects, graph)
    make_core_body(
        value.reference, value.origin, value.binders, value.parameter_slots,
        value.result_type, remap_core_block_types(value.body, ctx))
}

fn identity_type_mapping(count: Int) -> List<Int> {
    let mut result: List<Int> = []
    let mut index = 0
    while index < count {
        result.push(index)
        index = index + 1
    }
    result
}

pub fn validate_core_callable_type_domain(
    value: CoreCallableContract, type_count: Int, module_key: Str
) {
    let _ = remap_core_callable_types(
        value, identity_type_mapping(type_count), module_key)
}
pub fn validate_core_impl_type_domain(
    value: CoreImplMetadata, type_count: Int, module_key: Str
) {
    let _ = remap_core_impl_types(
        value, identity_type_mapping(type_count), module_key)
}
pub fn validate_core_body_type_domain(
    value: CoreBody, type_count: Int, module_key: Str
) {
    let _ = remap_core_body_types(
        value, identity_type_mapping(type_count), module_key)
}

// ============================================================
// Collection-complete CoreProgram validation
// ============================================================

fn core_binder_type_for(value: CoreBody, slot: SlotRef) -> CoreTypeRef {
    match binder_index(value.binders, slot) {
        some(index) => value.binders.get(index).unwrap().ty,
        none => panic("CoreHIR: program validation found an absent binder")
    }
}

fn core_callable_for(
    values: List<CoreCallableContract>, reference: ExecutableRef
) -> CoreCallableContract {
    let mut found: CoreCallableContract? = none
    for value in values {
        if executable_ref_same(value.reference, reference) {
            if found.is_some() {
                panic("CoreHIR: duplicate callable contract")
            }
            found = some(value)
        }
    }
    match found {
        some(value) => value,
        none => panic("CoreHIR: exact callable contract is absent")
    }
}

pub fn validate_core_callable_contracts(
    graph: CoreTypeGraph, values: List<CoreCallableContract>
) {
    let mut left_index = 0
    while left_index < values.len() {
        let left = values.get(left_index).unwrap()
        validate_origin(left.origin, left.reference)
        let header = core_type_graph_node(graph, left.header_type)
        if flow_type_kind_tag(flow_type_node_kind(header)) !=
                flow_type_kind_tag(flow_type_kind_callable()) {
            panic("CoreHIR: callable header is not a function type")
        }
        let header_children = flow_type_node_children(header)
        let parameter_types = core_callable_parameter_types(left)
        if flow_type_node_parameter_count(header) != parameter_types.len() ||
           header_children.len() != parameter_types.len() + 1 {
            panic("CoreHIR: callable header arity differs")
        }
        let mut header_index = 0
        while header_index < parameter_types.len() {
            if !core_type_ref_same(
                    header_children.get(header_index).unwrap(),
                    parameter_types.get(header_index).unwrap()) {
                panic("CoreHIR: callable header parameter differs")
            }
            header_index = header_index + 1
        }
        if !core_type_ref_same(
                header_children.get(parameter_types.len()).unwrap(),
                core_callable_result_type(left)) ||
           !core_effect_contract_same(
                flow_type_node_callable_effects(header), left.effects) {
            panic("CoreHIR: callable header result/effects differ")
        }
        let owner = if left.type_formals.len() == 0 {
            none
        } else if executable_ref_is_named(left.reference) {
            some(executable_ref_named_symbol(left.reference))
        } else {
            panic("CoreHIR: anonymous callable declares type formals")
        }
        let mut formal_index = 0
        while formal_index < left.type_formals.len() {
            let node = core_type_graph_node(
                graph, left.type_formals.get(formal_index).unwrap())
            if flow_type_kind_tag(flow_type_node_kind(node)) !=
                    flow_type_kind_tag(flow_type_kind_parameter()) {
                panic("CoreHIR: callable type formal is not a parameter node")
            }
            let fact = flow_type_node_generic_param(node)
            if !symbol_ref_same(
                    flow_generic_param_owner(fact), owner.unwrap()) ||
               flow_generic_param_index(fact) != formal_index ||
               flow_generic_param_arity(fact) != left.type_formals.len() {
                panic("CoreHIR: callable type formal owner/order/arity differs")
            }
            let _ = flow_generic_param_bounds(fact)
            formal_index = formal_index + 1
        }
        let mut effect_formal_index = 0
        while effect_formal_index < left.effect_formals.len() {
            let formal = left.effect_formals.get(effect_formal_index).unwrap()
            if !origin_ref_same(effect_param_owner(formal), left.origin) ||
               effect_param_ordinal(formal) != effect_formal_index {
                panic("CoreHIR: callable effect formal owner/order differs")
            }
            effect_formal_index = effect_formal_index + 1
        }
        let _ = core_type_graph_node(graph, core_callable_result_type(left))
        validate_effect_set(
            core_effect_contract_exact(left.effects),
            core_type_graph_count(graph))
        for parameter in parameter_types {
            let _ = core_type_graph_node(graph, parameter)
        }
        for binding in left.handled_evidence {
            let _ = core_type_graph_node(graph, binding.aggregate_type)
        }
        let mut right_index = left_index + 1
        while right_index < values.len() {
            if executable_ref_same(
                    left.reference, values.get(right_index).unwrap().reference) {
                panic("CoreHIR: duplicate callable contract")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
}

fn type_kind(graph: CoreTypeGraph, ty: CoreTypeRef) -> Int {
    flow_type_kind_tag(flow_type_node_kind(core_type_graph_node(graph, ty)))
}
fn require_core_type_same(
    left: CoreTypeRef, right: CoreTypeRef, message: Str
) {
    if !core_type_ref_same(left, right) { panic(message) }
}
fn require_core_type_actual_satisfies_formal(
    actual: CoreTypeRef, formal: CoreTypeRef,
    graph: CoreTypeGraph, message: Str
) {
    let formal_ref = core_type_graph_ref_from_flow(graph, formal)
    if !flow_type_actual_satisfies_formal(
            core_type_graph_nodes(graph),
            core_type_graph_node(graph, actual),
            core_type_graph_node(graph, formal_ref)) {
        panic(message)
    }
}

fn validate_instantiated_handled_uses(
    uses: List<CoreHandledEvidenceUse>, effects: CoreEffectContract,
    body: CoreBody
) {
    let requirements = core_effect_contract_handled_requirements(effects)
    if uses.len() != requirements.len() {
        panic("CoreHIR: handled-evidence census differs from effect instantiation")
    }
    validate_handled_evidence_uses(uses, body)
    let mut index = 0
    while index < uses.len() {
        let actual = uses.get(index).unwrap()
        if !handled_effect_ref_same(
                core_handled_use_requirement(actual),
                requirements.get(index).unwrap()) {
            panic("CoreHIR: handled-evidence requirement order differs")
        }
        index = index + 1
    }
}

fn validate_call_effects(
    callee: CoreCalleeRef, expression_effects: CoreEffectSet
) {
    let instantiation = callee.effects
    let result_contract = core_effect_instantiation_result(instantiation)
    for atom in core_effect_set_atoms(
            core_effect_contract_exact(result_contract)) {
        if !core_effect_set_contains_atom(expression_effects, atom) {
            panic("CoreHIR: call expression drops an instantiated effect atom")
        }
    }
}

fn core_call_contract_actual_satisfies_formal(
    actual: FlowCallContract, formal: FlowCallContract,
    substitutions: List<FlowTypeSubstitution>, graph: CoreTypeGraph
) -> Bool {
    let module_same = match (
            flow_call_contract_module_key(actual),
            flow_call_contract_module_key(formal)) {
        (some(a), some(b)) => a == b,
        (none, none) => true,
        _ => false
    }
    let actual_types = flow_call_contract_parameter_types(actual)
    let formal_types = flow_call_contract_parameter_types(formal)
    let actual_roles = flow_call_contract_parameter_roles(actual)
    let formal_roles = flow_call_contract_parameter_roles(formal)
    if !module_same || actual_types.len() != formal_types.len() ||
       actual_roles.len() != formal_roles.len() ||
       !flow_type_actual_satisfies_substituted_formal(
            core_type_graph_nodes(graph),
            flow_call_contract_result_type(actual),
            flow_call_contract_result_type(formal), substitutions) ||
       flow_semantic_role_tag(flow_call_contract_result_role(actual)) !=
            flow_semantic_role_tag(flow_call_contract_result_role(formal)) ||
       !value_origin_same(
            flow_call_contract_result_origin(actual),
            flow_call_contract_result_origin(formal)) {
        return false
    }
    let mut index = 0
    while index < actual_types.len() {
        if flow_semantic_role_tag(actual_roles.get(index).unwrap()) !=
                flow_semantic_role_tag(formal_roles.get(index).unwrap()) ||
           !flow_type_actual_satisfies_substituted_formal(
                core_type_graph_nodes(graph),
                actual_types.get(index).unwrap(),
                formal_types.get(index).unwrap(), substitutions) {
            return false
        }
        index = index + 1
    }
    true
}

fn validate_call_signature(
    callee: CoreCalleeRef, arguments: List<CoreExpr>, result_type: CoreTypeRef,
    expression_effects: CoreEffectSet,
    evidence: List<CoreEvidenceRef>,
    handled_evidence: List<CoreHandledEvidenceUse>, body: CoreBody,
    graph: CoreTypeGraph, callables: List<CoreCallableContract>
) {
    validate_call_effects(callee, expression_effects)
    if callee.kind != CORE_CALLEE_DIRECT &&
       callee.type_substitutions.len() != 0 {
        panic("CoreHIR: non-direct call carries declaration type substitutions")
    }
    let flow_parameters = flow_call_contract_parameter_types(callee.contract)
    if arguments.len() != flow_parameters.len() {
        panic("CoreHIR: call argument arity differs from exact contract")
    }
    let mut index = 0
    while index < arguments.len() {
        if !flow_type_actual_satisfies_formal(
                core_type_graph_nodes(graph),
                core_type_graph_node(
                    graph, core_expr_type(arguments.get(index).unwrap())),
                core_type_graph_node(
                    graph, flow_parameters.get(index).unwrap())) {
            panic("CoreHIR: call argument type differs from exact contract")
        }
        index = index + 1
    }
    require_core_type_same(
        result_type,
        core_type_graph_ref_from_flow(
            graph, flow_call_contract_result_type(callee.contract)),
        "CoreHIR: call result type differs from exact contract")
    if callee.kind == CORE_CALLEE_DIRECT {
        let candidate = core_callable_for(callables, core_callee_direct(callee))
        validate_type_substitutions_for_callable(
            callee.type_substitutions, candidate, graph,
            "CoreHIR: direct type substitution identity/order differs")
        if !core_call_contract_actual_satisfies_formal(
                callee.contract, candidate.semantic_contract,
                callee.type_substitutions, graph) {
            panic("CoreHIR: direct call semantic contract differs")
        }
        if !core_effect_contract_same(
                candidate.effects,
                core_effect_instantiation_source(callee.effects)) {
            panic("CoreHIR: direct call effect source contract differs")
        }
        validate_evidence(evidence, body)
        validate_instantiated_handled_uses(
            handled_evidence,
            core_effect_instantiation_result(callee.effects), body)
    } else if callee.kind == CORE_CALLEE_LOCAL {
        let callable_ty = core_type_graph_node(
            graph, core_binder_type_for(body, core_callee_local(callee)))
        if flow_type_kind_tag(flow_type_node_kind(callable_ty)) !=
           flow_type_kind_tag(flow_type_kind_callable()) ||
           flow_type_node_parameter_count(callable_ty) != arguments.len() {
            panic("CoreHIR: local callee slot is not exact callable type")
        }
        validate_evidence(evidence, body)
        validate_instantiated_handled_uses(
            handled_evidence,
            core_effect_instantiation_result(callee.effects), body)
    } else if callee.kind == CORE_CALLEE_DYNAMIC {
        validate_evidence(evidence, body)
        validate_instantiated_handled_uses(
            handled_evidence,
            core_effect_instantiation_result(callee.effects), body)
    } else {
        panic("CoreHIR: unknown callee identity form")
    }
}

fn core_field_matches_flow(
    core: CoreFieldRef, flow: FlowFieldIdentity
) -> Bool {
    match core.value {
        CoreFieldRefValue::NominalFieldValue(field) =>
            flow_field_identity_is_nominal(flow) &&
                nominal_field_ref_same(
                    field, flow_field_identity_nominal(flow)),
        CoreFieldRefValue::VariantFieldValue(field) =>
            flow_field_identity_is_variant(flow) &&
                variant_field_ref_same(
                    field, flow_field_identity_variant(flow)),
        CoreFieldRefValue::RecordFieldValue { path, .. } =>
            !flow_field_identity_is_nominal(flow) &&
                !flow_field_identity_is_variant(flow) &&
                path_ref_same(path, flow_field_identity_path(flow)),
        CoreFieldRefValue::TupleFieldValue(_) => false
    }
}

fn core_field_matches_fact(
    core: CoreFieldRef, fact: FlowNominalFieldFact
) -> Bool {
    if !core_field_matches_flow(core, flow_nominal_field_identity(fact)) {
        return false
    }
    if core_field_ref_kind_tag(core) == 2 {
        return core_field_ref_record_name(core) ==
            flow_nominal_field_record_name(fact)
    }
    true
}

fn validate_core_literal_type(
    literal: CoreLiteral, ty: CoreTypeRef, graph: CoreTypeGraph
) {
    let expected = match core_literal_kind_tag(literal) {
        0 => flow_type_kind_tag(flow_type_kind_int()),
        1 => flow_type_kind_tag(flow_type_kind_float()),
        2 => flow_type_kind_tag(flow_type_kind_str()),
        3 => flow_type_kind_tag(flow_type_kind_bool()),
        _ => flow_type_kind_tag(flow_type_kind_unit())
    }
    if type_kind(graph, ty) != expected {
        panic("CoreHIR: literal type differs")
    }
}

fn validate_core_primitive_signature(
    operation: CorePrimitiveOp, operands: List<CoreExpr>,
    result_type: CoreTypeRef, body: CoreBody, graph: CoreTypeGraph
) {
    let tag = core_primitive_op_tag(operation)
    if tag == CORE_PRIMITIVE_NEGATE {
        if operands.len() != 1 {
            panic("CoreHIR: negate arity differs")
        }
        require_core_type_same(
            core_expr_type(operands.get(0).unwrap()), result_type,
            "CoreHIR: negate input/result type differs")
    } else if tag == CORE_PRIMITIVE_NOT {
        if operands.len() != 1 ||
           type_kind(graph, result_type) !=
                flow_type_kind_tag(flow_type_kind_bool()) ||
           type_kind(graph, core_expr_type(operands.get(0).unwrap())) !=
                flow_type_kind_tag(flow_type_kind_bool()) {
            panic("CoreHIR: not signature differs")
        }
    } else {
        if operands.len() != 2 {
            panic("CoreHIR: binary primitive arity differs")
        }
        let left = core_expr_type(operands.get(0).unwrap())
        let right = core_expr_type(operands.get(1).unwrap())
        require_core_type_same(
            left, right, "CoreHIR: binary operand types differ")
        if tag >= CORE_PRIMITIVE_LT && tag <= CORE_PRIMITIVE_GE {
            if type_kind(graph, result_type) !=
               flow_type_kind_tag(flow_type_kind_bool()) {
                panic("CoreHIR: comparison result is not Bool")
            }
        } else {
            require_core_type_same(
                left, result_type,
                "CoreHIR: arithmetic input/result type differs")
        }
    }
}

fn variant_flow_fields(
    node: FlowTypeNode, variant: VariantRef
) -> List<FlowNominalFieldFact> {
    let mut result: List<FlowNominalFieldFact> = []
    for field in flow_type_node_nominal_fields(node) {
        let identity = flow_nominal_field_identity(field)
        if flow_field_identity_is_variant(identity) &&
           variant_ref_same(
                variant_field_ref_variant(
                    flow_field_identity_variant(identity)), variant) {
            result.push(field)
        }
    }
    result
}

fn validate_field_sequence(
    fields: List<CoreFieldValue>, expected: List<FlowNominalFieldFact>,
    graph: CoreTypeGraph
) {
    if fields.len() != expected.len() {
        panic("CoreHIR: constructor field census differs from type graph")
    }
    let mut index = 0
    while index < fields.len() {
        let actual = fields.get(index).unwrap()
        let fact = expected.get(index).unwrap()
        if !core_field_matches_fact(actual.field, fact) {
            panic("CoreHIR: constructor field identity/type order differs")
        }
        require_core_type_actual_satisfies_formal(
            core_expr_type(actual.value), flow_nominal_field_type(fact), graph,
            "CoreHIR: constructor field identity/type order differs")
        index = index + 1
    }
}

fn validate_construct_with_graph(
    constructor: CoreConstructorRef, fields: List<CoreFieldValue>,
    result_type: CoreTypeRef, graph: CoreTypeGraph
) {
    let node = core_type_graph_node(graph, result_type)
    match constructor.value {
        CoreConstructorRefValue::StructConstructorValue {
            owner, fields: contract_fields
        } => {
            if type_kind(graph, result_type) !=
                    flow_type_kind_tag(flow_type_kind_struct()) ||
               !symbol_ref_same(
                    registered_nominal_ref_symbol(owner),
                    flow_type_node_nominal(node)) {
                panic("CoreHIR: struct constructor/result owner differs")
            }
            let mut expected: List<FlowNominalFieldFact> = []
            for fact in flow_type_node_nominal_fields(node) {
                if flow_field_identity_is_nominal(
                        flow_nominal_field_identity(fact)) {
                    expected.push(fact)
                }
            }
            if contract_fields.len() != expected.len() {
                panic("CoreHIR: struct constructor contract/type arity differs")
            }
            let mut contract_index = 0
            while contract_index < contract_fields.len() {
                let identity = flow_nominal_field_identity(
                    expected.get(contract_index).unwrap())
                if !flow_field_identity_is_nominal(identity) ||
                   !nominal_field_ref_same(
                        contract_fields.get(contract_index).unwrap(),
                        flow_field_identity_nominal(identity)) {
                    panic("CoreHIR: struct constructor contract/type order differs")
                }
                contract_index = contract_index + 1
            }
            validate_field_sequence(fields, expected, graph)
        },
        CoreConstructorRefValue::VariantConstructorValue(variant) => {
            if type_kind(graph, result_type) !=
                    flow_type_kind_tag(flow_type_kind_enum()) ||
               !symbol_ref_same(
                    registered_nominal_ref_symbol(variant_ref_owner(variant)),
                    flow_type_node_nominal(node)) {
                panic("CoreHIR: variant constructor/result owner differs")
            }
            validate_field_sequence(
                fields, variant_flow_fields(node, variant), graph)
        },
        CoreConstructorRefValue::TupleConstructorValue(arity) => {
            let children = flow_type_node_children(node)
            if type_kind(graph, result_type) !=
                    flow_type_kind_tag(flow_type_kind_tuple()) ||
               arity != children.len() || fields.len() != children.len() {
                panic("CoreHIR: tuple constructor/result arity differs")
            }
            let mut index = 0
            while index < fields.len() {
                let field = fields.get(index).unwrap()
                match field.field.value {
                    CoreFieldRefValue::TupleFieldValue(field_index) => if
                        field_index != index {
                        panic("CoreHIR: tuple constructor field order differs")
                    },
                    _ => panic("CoreHIR: tuple constructor field identity differs")
                }
                require_core_type_actual_satisfies_formal(
                    core_expr_type(field.value),
                    children.get(index).unwrap(), graph,
                    "CoreHIR: tuple constructor field type differs")
                index = index + 1
            }
        }
    }
}

fn validate_move_update_with_graph(
    constructor: CoreConstructorRef, schema: List<CoreFieldRef>,
    overrides: List<CoreFieldValue>, base_type: CoreTypeRef,
    result_type: CoreTypeRef, graph: CoreTypeGraph
) {
    require_core_type_same(
        base_type, result_type,
        "CoreHIR: move update base/result type differs")
    let node = core_type_graph_node(graph, result_type)
    let mut expected: List<FlowNominalFieldFact> = []
    match constructor.value {
        CoreConstructorRefValue::StructConstructorValue {
            owner, fields: contract_fields
        } => {
            if type_kind(graph, result_type) !=
                    flow_type_kind_tag(flow_type_kind_struct()) ||
               !symbol_ref_same(
                    registered_nominal_ref_symbol(owner),
                    flow_type_node_nominal(node)) {
                panic("CoreHIR: move update struct owner/type differs")
            }
            for fact in flow_type_node_nominal_fields(node) {
                if flow_field_identity_is_nominal(
                        flow_nominal_field_identity(fact)) {
                    expected.push(fact)
                }
            }
            if contract_fields.len() != expected.len() {
                panic("CoreHIR: move update struct contract arity differs")
            }
        },
        CoreConstructorRefValue::VariantConstructorValue(variant) => {
            if type_kind(graph, result_type) !=
                    flow_type_kind_tag(flow_type_kind_enum()) ||
               !symbol_ref_same(
                    registered_nominal_ref_symbol(variant_ref_owner(variant)),
                    flow_type_node_nominal(node)) {
                panic("CoreHIR: move update variant owner/type differs")
            }
            expected = variant_flow_fields(node, variant)
        },
        _ => panic("CoreHIR: move update constructor is not nominal")
    }
    if schema.len() != expected.len() {
        panic("CoreHIR: move update schema census differs")
    }
    let mut index = 0
    while index < schema.len() {
        if !core_field_matches_fact(
                schema.get(index).unwrap(), expected.get(index).unwrap()) {
            panic("CoreHIR: move update schema identity/order differs")
        }
        index = index + 1
    }
    for override_value in overrides {
        require_core_type_actual_satisfies_formal(
            core_expr_type(override_value.value),
            projection_result_type(override_value.field, result_type, graph),
            graph,
            "CoreHIR: move update override type differs")
    }
}

fn validate_pattern_with_graph(
    pattern: CorePattern, expected_type: CoreTypeRef,
    body: CoreBody, graph: CoreTypeGraph
) {
    require_core_type_same(
        pattern.ty, expected_type,
        "CoreHIR: pattern type differs from scrutinee")
    let node = core_type_graph_node(graph, pattern.ty)
    match pattern.value {
        CorePatternValue::WildcardPatternValue => {},
        CorePatternValue::BindingPatternValue(slot) => require_core_type_same(
            core_binder_type_for(body, slot), pattern.ty,
            "CoreHIR: pattern binding type differs"),
        CorePatternValue::LiteralPatternValue(literal) =>
            validate_core_literal_type(literal, pattern.ty, graph),
        CorePatternValue::TuplePatternValue(elements) => {
            let children = flow_type_node_children(node)
            if type_kind(graph, pattern.ty) !=
                    flow_type_kind_tag(flow_type_kind_tuple()) ||
               elements.len() != children.len() {
                panic("CoreHIR: tuple pattern type/arity differs")
            }
            let mut index = 0
            for element in elements {
                validate_pattern_with_graph(
                    element,
                    children.get(index).unwrap(),
                    body, graph)
                index = index + 1
            }
        },
        CorePatternValue::StructPatternValue { owner, fields } => {
            if type_kind(graph, pattern.ty) !=
                    flow_type_kind_tag(flow_type_kind_struct()) ||
               !symbol_ref_same(
                    registered_nominal_ref_symbol(owner),
                    flow_type_node_nominal(node)) {
                panic("CoreHIR: struct pattern owner/type differs")
            }
            let expected = flow_type_node_nominal_fields(node)
            if fields.len() != expected.len() {
                panic("CoreHIR: struct pattern is not field-complete")
            }
            let mut index = 0
            for field in fields {
                let fact = expected.get(index).unwrap()
                if !core_field_matches_fact(field.field, fact) {
                    panic("CoreHIR: struct pattern field order differs")
                }
                validate_pattern_with_graph(
                    field.pattern,
                    flow_nominal_field_type(fact),
                    body, graph)
                index = index + 1
            }
        },
        CorePatternValue::VariantPatternValue { variant, fields } => {
            if type_kind(graph, pattern.ty) !=
                    flow_type_kind_tag(flow_type_kind_enum()) ||
               !symbol_ref_same(
                    registered_nominal_ref_symbol(variant_ref_owner(variant)),
                    flow_type_node_nominal(node)) {
                panic("CoreHIR: variant pattern owner/type differs")
            }
            let expected = variant_flow_fields(node, variant)
            if fields.len() != expected.len() {
                panic("CoreHIR: variant pattern is not payload-complete")
            }
            let mut index = 0
            for field in fields {
                let fact = expected.get(index).unwrap()
                if !core_field_matches_fact(field.field, fact) {
                    panic("CoreHIR: variant pattern field order differs")
                }
                validate_pattern_with_graph(
                    field.pattern,
                    flow_nominal_field_type(fact),
                    body, graph)
                index = index + 1
            }
        }
    }
}

fn projection_result_type(
    field: CoreFieldRef, base_type: CoreTypeRef,
    graph: CoreTypeGraph
) -> CoreTypeRef {
    let node = core_type_graph_node(graph, base_type)
    match field.value {
        CoreFieldRefValue::TupleFieldValue(index) => {
            let children = flow_type_node_children(node)
            if type_kind(graph, base_type) !=
                    flow_type_kind_tag(flow_type_kind_tuple()) ||
               index < 0 || index >= children.len() {
                panic("CoreHIR: tuple projection index/type differs")
            }
            children.get(index).unwrap()
        },
        _ => {
            let mut found: CoreTypeRef? = none
            for fact in flow_type_node_nominal_fields(node) {
                if core_field_matches_fact(field, fact) {
                    if found.is_some() {
                        panic("CoreHIR: projection field fact is duplicated")
                    }
                    found = some(flow_nominal_field_type(fact))
                }
            }
            match found {
                some(value) => value,
                none => panic("CoreHIR: projection field is absent from type graph")
            }
        }
    }
}

fn core_place_type(
    place: CorePlaceRef, body: CoreBody, graph: CoreTypeGraph,
    callables: List<CoreCallableContract>
) -> CoreTypeRef {
    if core_place_is_slot(place) {
        return core_binder_type_for(body, core_place_slot(place))
    }
    let base_type = core_expr_type(core_place_base(place))
    let expected = projection_result_type(
        core_place_field(place), base_type, graph)
    let actual = core_place_value_type(place)
    require_core_type_actual_satisfies_formal(
        actual, expected, graph,
        "CoreHIR: project place value type differs")
    actual
}

fn block_tail_type(value: CoreBlock) -> CoreTypeRef? {
    match value.tail {
        some(expr) => some(expr.ty),
        none => none
    }
}

fn require_block_result_type(
    value: CoreBlock, expected: CoreTypeRef, graph: CoreTypeGraph
) {
    match block_tail_type(value) {
        some(actual) => require_core_type_same(
            actual, expected, "CoreHIR: block result type differs"),
        none => if type_kind(graph, expected) !=
                flow_type_kind_tag(flow_type_kind_unit()) &&
                type_kind(graph, expected) !=
                flow_type_kind_tag(flow_type_kind_never()) {
            panic("CoreHIR: value block has no typed tail")
        }
    }
}

fn callee_direct_matches_symbol(callee: CoreCalleeRef, symbol: SymbolRef) -> Bool {
    callee.kind == CORE_CALLEE_DIRECT &&
        executable_ref_is_named(core_callee_direct(callee)) &&
        symbol_ref_same(
            executable_ref_named_symbol(core_callee_direct(callee)), symbol)
}

fn require_registered_impl_owner(
    values: List<CoreImplMetadata>, owner: ImplOwnerRef
) {
    let mut matches = 0
    for value in values {
        if impl_owner_ref_same(core_impl_owner(value), owner) {
            matches = matches + 1
        }
    }
    if matches != 1 {
        panic("CoreHIR: dictionary/method impl owner is not uniquely registered")
    }
}

fn validate_dictionary_provider(
    value: ExactDictRef, body: CoreBody,
    impls: List<CoreImplMetadata>
) {
    validate_dictionary_binder(value, body)
    if dict_ref_is_local(value) { return }
    let owner = if dict_ref_is_static(value) {
        dict_ref_static(value)
    } else {
        for inner in dict_ref_wrapped_inner(value) {
            validate_dictionary_provider(inner, body, impls)
        }
        dict_ref_wrapped_base(value)
    }
    // The ImplOwnerRef constructor is the exact typed provider authority.
    // Builtin trait impls intentionally have no CoreImplMetadata body entry,
    // so registry membership is required only for an executable ImplMethodRef.
    let _ = impls
    let _ = owner
}

fn validate_evidence_with_program(
    values: List<CoreEvidenceRef>, body: CoreBody,
    impls: List<CoreImplMetadata>
) {
    validate_evidence(values, body)
    for value in values {
        validate_dictionary_provider(core_evidence_dict(value), body, impls)
    }
}

fn validate_method_call_identity(
    method: ExactMethodRef, callee: CoreCalleeRef,
    evidence: List<CoreEvidenceRef>, body: CoreBody,
    impls: List<CoreImplMetadata>
) {
    if exact_method_ref_is_intrinsic(method) {
        if !callee_direct_matches_symbol(
                callee, intrinsic_ref_symbol(
                    exact_method_ref_intrinsic(method))) {
            panic("CoreHIR: intrinsic method/callee differs")
        }
    } else if exact_method_ref_is_impl(method) {
        let reference = exact_method_ref_impl(method)
        if !callee_direct_matches_symbol(
                callee, impl_method_ref_member(reference)) {
            panic("CoreHIR: concrete method/callee differs")
        }
        require_registered_impl_owner(impls, impl_method_ref_owner(reference))
        let mut matches = 0
        for value in impls {
            if impl_owner_ref_same(
                    core_impl_owner(value), impl_method_ref_owner(reference)) {
                for candidate in core_impl_methods(value) {
                    if impl_method_ref_same(candidate, reference) {
                        matches = matches + 1
                    }
                }
            }
        }
        if matches != 1 {
            panic("CoreHIR: concrete method is absent from its exact impl")
        }
    } else if exact_method_ref_is_trait(method) {
        let reference = exact_method_ref_trait(method)
        if !callee_direct_matches_symbol(
                callee, trait_method_ref_member(reference)) {
            panic("CoreHIR: trait method/callee differs")
        }
        if evidence.len() != 1 {
            panic("CoreHIR: trait method lacks one exact dictionary")
        }
        let dict = core_evidence_dict(evidence.get(0).unwrap())
        validate_dictionary_provider(dict, body, impls)
        if !dict_ref_is_local(dict) {
            let owner = if dict_ref_is_static(dict) {
                dict_ref_static(dict)
            } else { dict_ref_wrapped_base(dict) }
            match impl_owner_ref_trait(owner) {
                some(trait_ref) => if !symbol_ref_same(
                        trait_ref, trait_method_ref_trait(reference)) {
                    panic("CoreHIR: trait method dictionary selects another trait")
                },
                none => panic("CoreHIR: trait method dictionary lacks a trait")
            }
        }
    } else {
        panic("CoreHIR: method identity is not closed")
    }
}

fn validate_handled_capture_targets(
    captures: List<CoreHandledEvidenceCapture>,
    contract: CoreCallableContract, graph: CoreTypeGraph
) {
    for capture in captures {
        let target = core_handled_capture_target(capture)
        let mut found = false
        for binding in contract.handled_evidence {
            if handled_evidence_ref_same(target, binding.reference) {
                if !core_type_ref_same(
                        capture.aggregate_type, binding.aggregate_type) {
                    panic("CoreHIR: handled capture target type differs")
                }
                found = true
            }
        }
        if !found {
            panic("CoreHIR: handled capture target is absent from callable")
        }
        let _ = core_type_graph_node(graph, capture.aggregate_type)
    }
}

fn validate_type_substitutions_for_callable(
    substitutions: List<FlowTypeSubstitution>,
    callable: CoreCallableContract, graph: CoreTypeGraph,
    message: Str
) {
    if callable.type_formals.len() == 0 {
        if substitutions.len() == 0 { return }
        if !executable_ref_is_named(callable.reference) { panic(message) }
        let owner = executable_ref_named_symbol(callable.reference)
        let mut ordinal = 0
        for substitution in substitutions {
            let parameter = flow_type_substitution_parameter(substitution)
            if !symbol_ref_same(flow_generic_param_owner(parameter), owner) ||
               flow_generic_param_index(parameter) != ordinal ||
               flow_generic_param_arity(parameter) != substitutions.len() {
                panic(message)
            }
            let _ = core_type_graph_node(
                graph, flow_type_substitution_replacement(substitution))
            ordinal = ordinal + 1
        }
        return
    }
    let mut prior_index = 0 - 1
    for substitution in substitutions {
        let parameter = flow_type_substitution_parameter(substitution)
        let mut found_index: Int? = none
        let mut index = 0
        while index < callable.type_formals.len() {
            let node = core_type_graph_node(
                graph, callable.type_formals.get(index).unwrap())
            let declared = flow_type_node_generic_param(node)
            if flow_generic_param_fact_same(parameter, declared) {
                if found_index.is_some() { panic(message) }
                found_index = some(index)
            }
            index = index + 1
        }
        let exact_index = match found_index {
            some(value) => value,
            none => panic(message)
        }
        if exact_index <= prior_index { panic(message) }
        let _ = core_type_graph_node(
            graph, flow_type_substitution_replacement(substitution))
        prior_index = exact_index
    }
}

fn validate_core_callable_value_contract(
    target_type: CoreTypeRef, callable: CoreCallableContract,
    graph: CoreTypeGraph
) {
    let node = core_type_graph_node(graph, target_type)
    if flow_type_kind_tag(flow_type_node_kind(node)) !=
            flow_type_kind_tag(flow_type_kind_callable()) {
        panic("CoreHIR: callable value target is not callable typed")
    }
    let target_effects = flow_type_node_callable_effects(node)
    let contract = callable.semantic_contract
    let parameter_types = flow_call_contract_parameter_types(contract)
    let children = flow_type_node_children(node)
    if flow_type_node_parameter_count(node) != parameter_types.len() ||
       children.len() != parameter_types.len() + 1 {
        panic("CoreHIR: callable value type arity differs from exact contract")
    }
    let mut index = 0
    while index < parameter_types.len() {
        if !core_type_ref_same(
                children.get(index).unwrap(),
                parameter_types.get(index).unwrap()) {
            panic("CoreHIR: callable value parameter type differs")
        }
        index = index + 1
    }
    if !core_type_ref_same(
            children.get(parameter_types.len()).unwrap(),
            flow_call_contract_result_type(contract)) {
        panic("CoreHIR: callable value result type differs")
    }
    if !core_effect_contract_same(target_effects, callable.effects) {
        panic("CoreHIR: callable value effect contract differs")
    }
}

fn validate_expr_with_program(
    value: CoreExpr, body: CoreBody, graph: CoreTypeGraph,
    callables: List<CoreCallableContract>,
    impls: List<CoreImplMetadata>,
    current_callable: CoreCallableContract, loop_depth: Int
) {
    validate_expr_with_loop_depth(value, body, loop_depth)
    let _ = core_type_graph_node(graph, value.ty)
    match value.value {
        CoreExprValue::LiteralExprValue(literal) =>
            validate_core_literal_type(literal, value.ty, graph),
        CoreExprValue::CallableValueExprValue { executable, evidence } => {
            let callable = core_callable_for(callables, executable)
            validate_core_callable_value_contract(
                value.ty, callable, graph)
            validate_evidence_with_program(evidence, body, impls)
        },
        CoreExprValue::ReadExprValue(source) => require_core_type_same(
            core_binder_type_for(body, source), value.ty,
            "CoreHIR: Read source/result type differs"),
        CoreExprValue::PrimitiveExprValue { operation, operands } => {
            for operand in operands {
                validate_expr_with_program(
                    operand, body, graph, callables,
                    impls, current_callable, loop_depth)
            }
            validate_core_primitive_signature(
                operation, operands, value.ty, body, graph)
        },
        CoreExprValue::CallExprValue {
            callee, arguments, evidence, handled_evidence
        } => {
            for argument in arguments {
                validate_expr_with_program(
                    argument, body, graph, callables,
                    impls, current_callable, loop_depth)
            }
            validate_evidence_with_program(evidence, body, impls)
            validate_call_signature(
                callee, arguments, value.ty, value.effects,
                evidence, handled_evidence,
                body, graph, callables)
        },
        CoreExprValue::MethodCallExprValue {
            callee, method, receiver, arguments, evidence, handled_evidence
        } => {
            validate_method_call_identity(
                method, callee, evidence, body, impls)
            validate_expr_with_program(
                receiver, body, graph, callables,
                impls, current_callable, loop_depth)
            let mut all_arguments: List<CoreExpr> = [receiver]
            for argument in arguments {
                validate_expr_with_program(
                    argument, body, graph, callables,
                    impls, current_callable, loop_depth)
                all_arguments.push(argument)
            }
            validate_evidence_with_program(evidence, body, impls)
            validate_call_signature(
                callee, all_arguments, value.ty, value.effects,
                evidence, handled_evidence,
                body, graph, callables)
        },
        CoreExprValue::EffectCallExprValue {
            operation, arguments, evidence, handled_evidence
        } => {
            for argument in arguments {
                validate_expr_with_program(
                    argument, body, graph, callables,
                    impls, current_callable, loop_depth)
            }
            let callable = core_callable_for(
                callables, effect_operation_ref_callable(operation))
            if !core_effect_contract_handled_requirements(
                    callable.effects).any(fn(requirement) {
                        handled_effect_ref_same(
                            requirement,
                            effect_operation_ref_effect(operation))
                    }) {
                panic("CoreHIR: handled operation callable lacks its effect")
            }
            validate_call_signature(
                make_core_direct_callee(
                    callable.reference, callable.semantic_contract,
                    [],
                    make_explicit_core_effect_instantiation(
                        callable.effects, callable.effects,
                        callable.effects)),
                arguments, value.ty, value.effects,
                evidence, handled_evidence,
                body, graph, callables)
            validate_evidence_with_program(evidence, body, impls)
            let handled = effect_operation_ref_effect(operation)
            let mut present = false
            for atom in core_effect_set_atoms(value.effects) {
                if core_effect_atom_kind_tag(atom) == 3 &&
                   handled_effect_ref_same(
                        core_effect_atom_handled_ref(atom), handled) {
                    present = true
                }
            }
            if !present {
                panic("CoreHIR: handled operation is absent from effect set")
            }
        },
        CoreExprValue::SystemCallExprValue { host, arguments } => {
            for argument in arguments {
                validate_expr_with_program(
                    argument, body, graph, callables,
                    impls, current_callable, loop_depth)
            }
            let callable = core_callable_for(
                callables, system_host_callable_executable(host))
            if callable.handled_evidence.len() != 0 {
                panic("CoreHIR: system host call entered evidence domain")
            }
            let system = system_host_callable_effect(host)
            let mut callable_system_present = false
            for atom in core_effect_set_atoms(
                    core_effect_contract_exact(callable.effects)) {
                if core_effect_atom_kind_tag(atom) == 4 &&
                   system_effect_ref_same(
                        core_effect_atom_system_ref(atom), system) {
                    callable_system_present = true
                }
            }
            if !callable_system_present {
                panic("CoreHIR: system host callable lacks exact capability")
            }
            validate_call_signature(
                make_core_direct_callee(
                    callable.reference, callable.semantic_contract,
                    [],
                    make_explicit_core_effect_instantiation(
                        callable.effects, callable.effects,
                        callable.effects)),
                arguments, value.ty, value.effects,
                [], [], body, graph, callables)
            let mut present = false
            for atom in core_effect_set_atoms(value.effects) {
                if core_effect_atom_kind_tag(atom) == 4 &&
                   system_effect_ref_same(
                        core_effect_atom_system_ref(atom), system) {
                    present = true
                }
            }
            if !present {
                panic("CoreHIR: system call is absent from effect set")
            }
        },
        CoreExprValue::FailRaiseExprValue { payload } => {
            validate_expr_with_program(
                payload, body, graph, callables,
                impls, current_callable, loop_depth)
            let mut found = false
            for atom in core_effect_set_atoms(value.effects) {
                if core_effect_atom_kind_tag(atom) == 0 &&
                   core_type_ref_same(core_effect_atom_type(atom), payload.ty) {
                    found = true
                }
            }
            if !found {
                panic("CoreHIR: FailRaise payload is absent from fail effect")
            }
        },
        CoreExprValue::ProjectExprValue { base, field, .. } => {
            validate_expr_with_program(
                base, body, graph, callables,
                impls, current_callable, loop_depth)
            require_core_type_actual_satisfies_formal(
                value.ty,
                projection_result_type(
                    field, core_expr_type(base), graph),
                graph, "CoreHIR: projection result type differs")
        },
        CoreExprValue::ConstructExprValue { constructor, fields } => {
            for field in fields {
                validate_expr_with_program(
                    field.value, body, graph, callables,
                    impls, current_callable, loop_depth)
            }
            validate_construct_with_graph(
                constructor, fields, value.ty, graph)
            match constructor.executable {
                some(executable) => {
                    if core_constructor_kind_tag(constructor) != 1 {
                        panic("CoreHIR: structural constructor has executable")
                    }
                    let _ = core_callable_for(callables, executable)
                },
                none => if core_constructor_kind_tag(constructor) == 1 {
                    panic("CoreHIR: variant constructor has no exact executable")
                }
            }
        },
        CoreExprValue::MoveUpdateExprValue {
            base, constructor, schema, overrides
        } => {
            validate_expr_with_program(
                base, body, graph, callables,
                impls, current_callable, loop_depth)
            for field in overrides {
                validate_expr_with_program(
                    field.value, body, graph, callables,
                    impls, current_callable, loop_depth)
            }
            validate_move_update_with_graph(
                constructor, schema, overrides, core_expr_type(base),
                value.ty, graph)
            match constructor.executable {
                some(executable) => {
                    if core_constructor_kind_tag(constructor) != 1 {
                        panic("CoreHIR: move update structural constructor has executable")
                    }
                    let _ = core_callable_for(callables, executable)
                },
                none => if core_constructor_kind_tag(constructor) == 1 {
                    panic("CoreHIR: move update variant constructor has no executable")
                }
            }
        },
        CoreExprValue::LambdaExprValue {
            executable, handled_captures, ..
        } => {
            let contract = core_callable_for(callables, executable)
            validate_core_callable_value_contract(
                value.ty, contract, graph)
            if !executable_contract_mode_same(
                    contract.mode, executable_contract_mode_concrete_body()) {
                panic("CoreHIR: lambda references a bodyless callable")
            }
            validate_handled_capture_targets(
                handled_captures, contract, graph)
        },
        CoreExprValue::BlockExprValue(block) => {
            validate_block_with_program(
                block, body, graph, callables, impls,
                current_callable, loop_depth)
            require_block_result_type(block, value.ty, graph)
        },
        CoreExprValue::IfExprValue {
            condition, then_block, else_block
        } => {
            validate_expr_with_program(
                condition, body, graph, callables,
                impls, current_callable, loop_depth)
            if type_kind(graph, core_expr_type(condition)) !=
               flow_type_kind_tag(flow_type_kind_bool()) {
                panic("CoreHIR: If condition is not Bool")
            }
            validate_block_with_program(
                then_block, body, graph, callables,
                impls, current_callable, loop_depth)
            validate_block_with_program(
                else_block, body, graph, callables,
                impls, current_callable, loop_depth)
            require_block_result_type(then_block, value.ty, graph)
            require_block_result_type(else_block, value.ty, graph)
        },
        CoreExprValue::MatchExprValue { scrutinee, arms } => {
            validate_expr_with_program(
                scrutinee, body, graph, callables,
                impls, current_callable, loop_depth)
            let scrutinee_type = core_expr_type(scrutinee)
            for arm in arms {
                validate_pattern_with_graph(
                    arm.pattern, scrutinee_type, body, graph)
                match arm.guard {
                    some(guard) => {
                        validate_expr_with_program(
                            guard, body, graph, callables,
                            impls, current_callable, loop_depth)
                        if type_kind(graph, guard.ty) !=
                           flow_type_kind_tag(flow_type_kind_bool()) {
                            panic("CoreHIR: match guard is not Bool")
                        }
                    },
                    none => {}
                }
                validate_block_with_program(
                    arm.body, body, graph, callables,
                    impls, current_callable, loop_depth)
                require_block_result_type(arm.body, value.ty, graph)
            }
        },
        CoreExprValue::TryCatchExprValue {
            body: protected, error_slot, arms
        } => {
            validate_block_with_program(
                protected, body, graph, callables,
                impls, current_callable, loop_depth)
            require_block_result_type(protected, value.ty, graph)
            let error_type = core_binder_type_for(body, error_slot)
            for arm in arms {
                validate_pattern_with_graph(
                    arm.pattern, error_type, body, graph)
                validate_block_with_program(
                    arm.body, body, graph, callables,
                    impls, current_callable, loop_depth)
                require_block_result_type(arm.body, value.ty, graph)
            }
        },
        CoreExprValue::HandleExprValue { body: handled, installations } => {
            validate_block_with_program(
                handled, body, graph, callables,
                impls, current_callable, loop_depth)
            require_block_result_type(handled, value.ty, graph)
            for installation in installations {
                let _ = core_type_graph_node(
                    graph, installation.evidence.aggregate_type)
                if !executable_ref_same(
                        core_handled_evidence_owner(installation.evidence),
                        current_callable.reference) {
                    panic("CoreHIR: handler installation owner differs")
                }
                for operation in installation.operations {
                    let operation_callable = effect_operation_ref_callable(
                        operation.operation)
                    let handler_contract = core_callable_for(
                        callables, operation.executable)
                    let _ = core_callable_for(callables, operation_callable)
                    if !executable_contract_mode_same(
                            handler_contract.mode,
                            executable_contract_mode_concrete_body()) {
                        panic("CoreHIR: handler executable is bodyless")
                    }
                    validate_handled_capture_targets(
                        operation.handled_captures,
                        handler_contract, graph)
                }
            }
        }
    }
}

fn validate_statement_with_program(
    value: CoreStmt, body: CoreBody, graph: CoreTypeGraph,
    callables: List<CoreCallableContract>,
    impls: List<CoreImplMetadata>,
    current_callable: CoreCallableContract, loop_depth: Int
) {
    validate_statement(value, body, loop_depth)
    match value.value {
        CoreStmtValue::Bind { target, value: expr, .. } => {
            validate_expr_with_program(
                expr, body, graph, callables, impls,
                current_callable, loop_depth)
            require_core_type_same(
                core_binder_type_for(body, target), expr.ty,
                "CoreHIR: Bind target/value type differs")
        },
        CoreStmtValue::Assign { target, value: expr, .. } => {
            if !core_place_is_slot(target) {
                validate_expr_with_program(
                    core_place_base(target), body, graph, callables,
                    impls, current_callable, loop_depth)
            }
            validate_expr_with_program(
                expr, body, graph, callables, impls,
                current_callable, loop_depth)
            require_core_type_same(
                core_place_type(target, body, graph, callables), expr.ty,
                "CoreHIR: Assign target/value type differs")
        },
        CoreStmtValue::ExprStmt { value: expr, .. } =>
            validate_expr_with_program(
                expr, body, graph, callables, impls,
                current_callable, loop_depth),
        CoreStmtValue::While { condition, body: loop_body, .. } => {
            validate_expr_with_program(
                condition, body, graph, callables,
                impls, current_callable, loop_depth)
            if type_kind(graph, condition.ty) !=
               flow_type_kind_tag(flow_type_kind_bool()) {
                panic("CoreHIR: While condition is not Bool")
            }
            validate_block_with_program(
                loop_body, body, graph, callables,
                impls, current_callable, loop_depth + 1)
        },
        CoreStmtValue::Return { value: returned, .. } => match returned {
            some(expr) => {
                validate_expr_with_program(
                    expr, body, graph, callables,
                    impls, current_callable, loop_depth)
                require_core_type_same(
                    expr.ty, body.result_type,
                    "CoreHIR: Return type differs from callable")
            },
            none => {
                let kind = type_kind(graph, body.result_type)
                if kind != flow_type_kind_tag(flow_type_kind_unit()) &&
                   kind != flow_type_kind_tag(flow_type_kind_never()) {
                    panic("CoreHIR: value callable has empty Return")
                }
            }
        },
        _ => {}
    }
}

fn validate_block_with_program(
    value: CoreBlock, body: CoreBody, graph: CoreTypeGraph,
    callables: List<CoreCallableContract>,
    impls: List<CoreImplMetadata>,
    current_callable: CoreCallableContract, loop_depth: Int
) {
    for statement in value.statements {
        validate_statement_with_program(
            statement, body, graph, callables,
            impls, current_callable, loop_depth)
    }
    match value.tail {
        some(expr) => validate_expr_with_program(
            expr, body, graph, callables, impls,
            current_callable, loop_depth),
        none => {}
    }
}

pub fn validate_core_body_with_program(
    value: CoreBody, graph: CoreTypeGraph,
    callables: List<CoreCallableContract>,
    impls: List<CoreImplMetadata>,
    current_callable: CoreCallableContract
) {
    validate_core_body(value)
    if !executable_ref_same(value.reference, current_callable.reference) ||
       !origin_ref_same(value.origin, current_callable.origin) ||
       value.parameter_slots.len() != current_callable.parameter_slots.len() {
        panic("CoreHIR: body/program callable closure differs")
    }
    let mut index = 0
    while index < value.parameter_slots.len() {
        if !slot_ref_same(
                value.parameter_slots.get(index).unwrap(),
                current_callable.parameter_slots.get(index).unwrap()) {
            panic("CoreHIR: body parameter slot order differs")
        }
        index = index + 1
    }
    validate_block_with_program(
        value.body, value, graph, callables, impls, current_callable, 0)
}
