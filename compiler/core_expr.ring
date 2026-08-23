// CoreHIR structured semantic language for Ring 0.1.
//
// CoreHIR is the last language-semantic representation.  Every callee,
// method, evidence edge, nominal/member projection, generated executable and
// body-local slot is supplied as an exact typed reference by the upstream
// elaborator.  The representation has no source names/spans and deliberately
// has no Clone/Take/Drop/Cleanup, layout, ABI, or backend variant.

use ir_identity::{
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
    nominal_field_ref_same, nominal_field_ref_owner,
    variant_ref_owner, variant_ref_same,
    variant_field_ref_variant, variant_field_ref_same,
    handled_effect_ref_same, system_effect_ref_same,
    impl_owner_ref_same, impl_method_ref_owner,
    impl_method_ref_callable_slot_index, impl_method_ref_member,
    intrinsic_ref_symbol, trait_method_ref_member,
    path_ref_same, path_ref_owner,
    path_owner_ref_is_symbol, path_owner_ref_symbol,
    path_owner_ref_module_body,
    module_body_ref_origin_module_key,
    slot_ref_same,
    make_named_callee_ref, make_local_callee_ref, make_dynamic_callee_ref,
    callee_ref_same, origin_ref_same,
    origin_ref_is_symbol, origin_ref_symbol, origin_ref_path
}
use ir_inventory::{
    ExecutableRef, BinderManifest,
    EffectOperationRef, SystemHostCallableRef,
    executable_ref_same, executable_ref_is_named,
    executable_ref_named_symbol, executable_ref_origin_module_key,
    binder_manifest_owner, binder_manifest_entries,
    binder_entry_slot, make_binder_manifest,
    effect_operation_ref_effect, effect_operation_ref_callable,
    effect_operation_ref_same,
    system_host_callable_effect, system_host_callable_executable
}
use hir::{
    MethodCallRef,
    method_call_ref_is_intrinsic, method_call_ref_is_concrete,
    method_call_ref_is_bound, method_call_ref_intrinsic,
    method_call_ref_impl, method_call_ref_bound
}
use flow_ir::{
    FlowTypeNode, FlowTypeRef, FlowFieldIdentity, FlowNominalFieldFact,
    FlowCallableMode, FlowCallContract,
    FlowScope, FlowScopeRef,
    FlowInitialSlotState, FlowStorageClass, FlowStorageContract,
    make_flow_type_ref,
    validate_flow_type_graph_nodes, copy_flow_type_graph_nodes,
    flow_type_ref_index, flow_type_node_kind, flow_type_node_children,
    flow_type_node_nominal, flow_type_node_nominal_fields,
    flow_type_node_parameter_count,
    flow_type_kind_tag, flow_type_kind_int, flow_type_kind_float,
    flow_type_kind_str, flow_type_kind_bool, flow_type_kind_unit,
    flow_type_kind_never, flow_type_kind_struct, flow_type_kind_enum,
    flow_type_kind_tuple, flow_type_kind_record, flow_type_kind_callable,
    flow_callable_mode_same, flow_callable_mode_concrete_body,
    flow_call_contract_parameter_types, flow_call_contract_result_type,
    flow_call_contract_same,
    flow_nominal_field_identity, flow_nominal_field_type,
    flow_field_identity_is_nominal, flow_field_identity_nominal,
    flow_field_identity_is_variant, flow_field_identity_variant,
    flow_field_identity_path,
    flow_scope_reference, flow_scope_ref_same,
    flow_scope_ref_owner, flow_scope_ref_ordinal,
    flow_initial_slot_state_tag, flow_storage_class_tag,
    flow_storage_contract_tag
}

// ============================================================
// Exact typed/effect references
// ============================================================

pub struct CoreTypeRef { index: Int }

pub fn make_core_type_ref(index: Int) -> CoreTypeRef {
    if index < 0 { panic("CoreHIR: negative type reference") }
    CoreTypeRef { index: index }
}
pub fn core_type_ref_index(value: CoreTypeRef) -> Int { value.index }
pub fn core_type_ref_same(left: CoreTypeRef, right: CoreTypeRef) -> Bool {
    left.index == right.index
}

pub fn core_type_ref_to_flow(value: CoreTypeRef) -> FlowTypeRef {
    make_flow_type_ref(value.index)
}
pub fn flow_type_ref_to_core(value: FlowTypeRef) -> CoreTypeRef {
    make_core_type_ref(flow_type_ref_index(value))
}

pub struct CoreTypeGraph { nodes: List<FlowTypeNode> }

pub fn make_core_type_graph(nodes: List<FlowTypeNode>) -> CoreTypeGraph {
    validate_flow_type_graph_nodes(nodes)
    CoreTypeGraph { nodes: copy_flow_type_graph_nodes(nodes) }
}
pub fn core_type_graph_count(value: CoreTypeGraph) -> Int {
    value.nodes.len()
}
pub fn core_type_graph_nodes(value: CoreTypeGraph) -> List<FlowTypeNode> {
    copy_flow_type_graph_nodes(value.nodes)
}
pub fn core_type_graph_node(
    value: CoreTypeGraph, reference: CoreTypeRef
) -> FlowTypeNode {
    match value.nodes.get(reference.index) {
        some(node) => node,
        none => panic("CoreHIR: type reference is absent from CoreTypeGraph")
    }
}

pub struct CoreCallableContract {
    reference: ExecutableRef,
    origin: OriginRef,
    parameter_types: List<CoreTypeRef>,
    parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef,
    mode: FlowCallableMode,
    semantic_contract: FlowCallContract,
    evidence_requirements: List<SymbolRef>
}

fn copy_core_type_refs(values: List<CoreTypeRef>) -> List<CoreTypeRef> {
    let mut result: List<CoreTypeRef> = []
    for value in values { result.push(value) }
    result
}
fn copy_symbols(values: List<SymbolRef>) -> List<SymbolRef> {
    let mut result: List<SymbolRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_core_callable_contract(
    reference: ExecutableRef, origin: OriginRef,
    parameter_types: List<CoreTypeRef>, parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef, mode: FlowCallableMode,
    semantic_contract: FlowCallContract,
    evidence_requirements: List<SymbolRef>
) -> CoreCallableContract {
    let flow_parameters = flow_call_contract_parameter_types(semantic_contract)
    if parameter_types.len() != flow_parameters.len() ||
       core_type_ref_index(result_type) != flow_type_ref_index(
            flow_call_contract_result_type(semantic_contract)) {
        panic("CoreHIR: callable typed/semantic signature differs")
    }
    let mut index = 0
    while index < parameter_types.len() {
        if core_type_ref_index(parameter_types.get(index).unwrap()) !=
           flow_type_ref_index(flow_parameters.get(index).unwrap()) {
            panic("CoreHIR: callable parameter type projection differs")
        }
        index = index + 1
    }
    let concrete = flow_callable_mode_same(
        mode, flow_callable_mode_concrete_body())
    if (concrete && parameter_slots.len() != parameter_types.len()) ||
       (!concrete && parameter_slots.len() != 0) {
        panic("CoreHIR: callable parameter-slot relation differs")
    }
    let mut left_index = 0
    while left_index < evidence_requirements.len() {
        let mut right_index = left_index + 1
        while right_index < evidence_requirements.len() {
            if symbol_ref_same(
                    evidence_requirements.get(left_index).unwrap(),
                    evidence_requirements.get(right_index).unwrap()) {
                panic("CoreHIR: callable repeats an evidence requirement")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    CoreCallableContract {
        reference: reference, origin: origin,
        parameter_types: copy_core_type_refs(parameter_types),
        parameter_slots: copy_slot_refs(parameter_slots),
        result_type: result_type, mode: mode,
        semantic_contract: semantic_contract,
        evidence_requirements: copy_symbols(evidence_requirements)
    }
}
pub fn core_callable_reference(value: CoreCallableContract) -> ExecutableRef {
    value.reference
}
pub fn core_callable_origin(value: CoreCallableContract) -> OriginRef {
    value.origin
}
pub fn core_callable_parameter_types(
    value: CoreCallableContract
) -> List<CoreTypeRef> { copy_core_type_refs(value.parameter_types) }
pub fn core_callable_parameter_slots(
    value: CoreCallableContract
) -> List<SlotRef> { copy_slot_refs(value.parameter_slots) }
pub fn core_callable_result_type(value: CoreCallableContract) -> CoreTypeRef {
    value.result_type
}
pub fn core_callable_mode(value: CoreCallableContract) -> FlowCallableMode {
    value.mode
}
pub fn core_callable_semantic_contract(
    value: CoreCallableContract
) -> FlowCallContract { value.semantic_contract }
pub fn core_callable_evidence_requirements(
    value: CoreCallableContract
) -> List<SymbolRef> { copy_symbols(value.evidence_requirements) }

fn copy_core_callable_contracts(
    values: List<CoreCallableContract>
) -> List<CoreCallableContract> {
    let mut result: List<CoreCallableContract> = []
    for value in values {
        result.push(make_core_callable_contract(
            value.reference, value.origin, value.parameter_types,
            value.parameter_slots, value.result_type, value.mode,
            value.semantic_contract, value.evidence_requirements))
    }
    result
}
pub fn copy_core_callables(
    values: List<CoreCallableContract>
) -> List<CoreCallableContract> { copy_core_callable_contracts(values) }

enum CoreEffectAtomValue {
    FailEffectValue(CoreTypeRef),
    MutEffectValue(CoreTypeRef),
    UnsafeEffectValue,
    HandledEffectValue(HandledEffectRef),
    SystemEffectValue(SystemEffectRef)
}

pub struct CoreEffectAtom { value: CoreEffectAtomValue }

pub fn make_core_fail_effect(error_type: CoreTypeRef) -> CoreEffectAtom {
    CoreEffectAtom { value: CoreEffectAtomValue::FailEffectValue(error_type) }
}
pub fn make_core_mut_effect(state_type: CoreTypeRef) -> CoreEffectAtom {
    CoreEffectAtom { value: CoreEffectAtomValue::MutEffectValue(state_type) }
}
pub fn make_core_unsafe_effect() -> CoreEffectAtom {
    CoreEffectAtom { value: CoreEffectAtomValue::UnsafeEffectValue }
}
pub fn make_core_handled_effect(effect_ref: HandledEffectRef) -> CoreEffectAtom {
    CoreEffectAtom {
        value: CoreEffectAtomValue::HandledEffectValue(effect_ref)
    }
}
pub fn make_core_system_effect(effect_ref: SystemEffectRef) -> CoreEffectAtom {
    CoreEffectAtom {
        value: CoreEffectAtomValue::SystemEffectValue(effect_ref)
    }
}

pub fn core_effect_atom_kind_tag(value: CoreEffectAtom) -> Int {
    match value.value {
        CoreEffectAtomValue::FailEffectValue(_) => 0,
        CoreEffectAtomValue::MutEffectValue(_) => 1,
        CoreEffectAtomValue::UnsafeEffectValue => 2,
        CoreEffectAtomValue::HandledEffectValue(_) => 3,
        CoreEffectAtomValue::SystemEffectValue(_) => 4
    }
}
pub fn core_effect_atom_type(value: CoreEffectAtom) -> CoreTypeRef {
    match value.value {
        CoreEffectAtomValue::FailEffectValue(ty) |
        CoreEffectAtomValue::MutEffectValue(ty) => ty,
        _ => panic("CoreHIR: effect atom has no type argument")
    }
}
pub fn core_effect_atom_handled_ref(value: CoreEffectAtom) -> HandledEffectRef {
    match value.value {
        CoreEffectAtomValue::HandledEffectValue(effect_ref) => effect_ref,
        _ => panic("CoreHIR: effect atom is not handled")
    }
}
pub fn core_effect_atom_system_ref(value: CoreEffectAtom) -> SystemEffectRef {
    match value.value {
        CoreEffectAtomValue::SystemEffectValue(effect_ref) => effect_ref,
        _ => panic("CoreHIR: effect atom is not system")
    }
}

fn core_effect_atom_same(left: CoreEffectAtom, right: CoreEffectAtom) -> Bool {
    match (left.value, right.value) {
        (CoreEffectAtomValue::FailEffectValue(a),
         CoreEffectAtomValue::FailEffectValue(b)) => core_type_ref_same(a, b),
        (CoreEffectAtomValue::MutEffectValue(a),
         CoreEffectAtomValue::MutEffectValue(b)) => core_type_ref_same(a, b),
        (CoreEffectAtomValue::UnsafeEffectValue,
         CoreEffectAtomValue::UnsafeEffectValue) => true,
        (CoreEffectAtomValue::HandledEffectValue(a),
         CoreEffectAtomValue::HandledEffectValue(b)) =>
            handled_effect_ref_same(a, b),
        (CoreEffectAtomValue::SystemEffectValue(a),
         CoreEffectAtomValue::SystemEffectValue(b)) =>
            system_effect_ref_same(a, b),
        _ => false
    }
}

fn copy_effect_atoms(values: List<CoreEffectAtom>) -> List<CoreEffectAtom> {
    let mut result: List<CoreEffectAtom> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreEffectSet { atoms: List<CoreEffectAtom> }

pub fn make_core_effect_set(atoms: List<CoreEffectAtom>) -> CoreEffectSet {
    let mut left_index = 0
    while left_index < atoms.len() {
        let mut right_index = left_index + 1
        while right_index < atoms.len() {
            if core_effect_atom_same(
                    atoms.get(left_index).unwrap(),
                    atoms.get(right_index).unwrap()) {
                panic("CoreHIR: effect set repeats an exact atom")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    CoreEffectSet { atoms: copy_effect_atoms(atoms) }
}
pub fn core_effect_set_atoms(value: CoreEffectSet) -> List<CoreEffectAtom> {
    copy_effect_atoms(value.atoms)
}

// ============================================================
// Exact callable/evidence/member identities
// ============================================================

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
    candidates: List<ExecutableRef>
}

fn copy_executables(values: List<ExecutableRef>) -> List<ExecutableRef> {
    let mut result: List<ExecutableRef> = []
    for value in values { result.push(value) }
    result
}
fn validate_core_callee_candidates(values: List<ExecutableRef>) {
    if values.len() == 0 { panic("CoreHIR: callee candidate set is empty") }
    let mut left_index = 0
    while left_index < values.len() {
        let mut right_index = left_index + 1
        while right_index < values.len() {
            if executable_ref_same(
                    values.get(left_index).unwrap(),
                    values.get(right_index).unwrap()) {
                panic("CoreHIR: callee candidate set repeats identity")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
}

pub fn make_core_direct_callee(
    value: ExecutableRef, contract: FlowCallContract
) -> CoreCalleeRef {
    if !executable_ref_is_named(value) {
        panic("CoreHIR: direct callee is not a named executable")
    }
    let callee = make_named_callee_ref(executable_ref_named_symbol(value))
    CoreCalleeRef {
        callee: callee, kind: CORE_CALLEE_DIRECT,
        direct: some(value), local: none, dynamic: none,
        contract: contract, candidates: [value]
    }
}
pub fn make_core_local_callee(
    value: SlotRef, contract: FlowCallContract,
    candidates: List<ExecutableRef>
) -> CoreCalleeRef {
    validate_core_callee_candidates(candidates)
    CoreCalleeRef {
        callee: make_local_callee_ref(value), kind: CORE_CALLEE_LOCAL,
        direct: none, local: some(value), dynamic: none,
        contract: contract, candidates: copy_executables(candidates)
    }
}
pub fn make_core_dynamic_callee(
    value: PathRef, contract: FlowCallContract,
    candidates: List<ExecutableRef>
) -> CoreCalleeRef {
    validate_core_callee_candidates(candidates)
    CoreCalleeRef {
        callee: make_dynamic_callee_ref(value), kind: CORE_CALLEE_DYNAMIC,
        direct: none, local: none, dynamic: some(value),
        contract: contract, candidates: copy_executables(candidates)
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
pub fn core_callee_candidates(value: CoreCalleeRef) -> List<ExecutableRef> {
    copy_executables(value.candidates)
}

enum CoreEvidenceRefValue {
    LocalEvidenceValue(SlotRef),
    CallableEvidenceValue(ExecutableRef)
}

pub struct CoreEvidenceRef { value: CoreEvidenceRefValue }

pub fn make_core_local_evidence(value: SlotRef) -> CoreEvidenceRef {
    CoreEvidenceRef { value: CoreEvidenceRefValue::LocalEvidenceValue(value) }
}
pub fn make_core_callable_evidence(value: ExecutableRef) -> CoreEvidenceRef {
    CoreEvidenceRef { value: CoreEvidenceRefValue::CallableEvidenceValue(value) }
}
pub fn core_evidence_is_local(value: CoreEvidenceRef) -> Bool {
    match value.value {
        CoreEvidenceRefValue::LocalEvidenceValue(_) => true,
        CoreEvidenceRefValue::CallableEvidenceValue(_) => false
    }
}
pub fn core_evidence_local(value: CoreEvidenceRef) -> SlotRef {
    match value.value {
        CoreEvidenceRefValue::LocalEvidenceValue(slot) => slot,
        _ => panic("CoreHIR: callable evidence has no local slot")
    }
}
pub fn core_evidence_callable(value: CoreEvidenceRef) -> ExecutableRef {
    match value.value {
        CoreEvidenceRefValue::CallableEvidenceValue(executable) => executable,
        _ => panic("CoreHIR: local evidence has no executable")
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

pub struct CoreObligationBinding {
    requirement: SymbolRef,
    evidence: CoreEvidenceRef
}
pub fn make_core_obligation_binding(
    requirement: SymbolRef, evidence: CoreEvidenceRef
) -> CoreObligationBinding {
    CoreObligationBinding { requirement: requirement, evidence: evidence }
}
pub fn core_obligation_requirement(value: CoreObligationBinding) -> SymbolRef {
    value.requirement
}
pub fn core_obligation_evidence(value: CoreObligationBinding) -> CoreEvidenceRef {
    value.evidence
}
fn copy_core_obligations(
    values: List<CoreObligationBinding>
) -> List<CoreObligationBinding> {
    let mut result: List<CoreObligationBinding> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreImplMetadata {
    owner: ImplOwnerRef,
    methods: List<ImplMethodRef>,
    assoc_bindings: List<CoreAssocBinding>,
    obligations: List<CoreObligationBinding>
}

pub fn make_core_impl_metadata(
    owner: ImplOwnerRef, methods: List<ImplMethodRef>,
    assoc_bindings: List<CoreAssocBinding>,
    obligations: List<CoreObligationBinding>
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
    let mut obligation_index = 0
    while obligation_index < obligations.len() {
        let mut right_index = obligation_index + 1
        while right_index < obligations.len() {
            if symbol_ref_same(
                    obligations.get(obligation_index).unwrap().requirement,
                    obligations.get(right_index).unwrap().requirement) {
                panic("CoreHIR: impl repeats an obligation")
            }
            right_index = right_index + 1
        }
        obligation_index = obligation_index + 1
    }
    CoreImplMetadata {
        owner: owner, methods: methods.map(fn(value) { value }),
        assoc_bindings: copy_core_assoc_bindings(assoc_bindings),
        obligations: copy_core_obligations(obligations)
    }
}
pub fn core_impl_owner(value: CoreImplMetadata) -> ImplOwnerRef { value.owner }
pub fn core_impl_methods(value: CoreImplMetadata) -> List<ImplMethodRef> {
    value.methods.map(fn(method) { method })
}
pub fn core_impl_assoc_bindings(value: CoreImplMetadata) -> List<CoreAssocBinding> {
    copy_core_assoc_bindings(value.assoc_bindings)
}
pub fn core_impl_obligations(value: CoreImplMetadata) -> List<CoreObligationBinding> {
    copy_core_obligations(value.obligations)
}
pub fn copy_core_impl_metadata(values: List<CoreImplMetadata>) -> List<CoreImplMetadata> {
    let mut result: List<CoreImplMetadata> = []
    for value in values {
        result.push(make_core_impl_metadata(
            value.owner, value.methods, value.assoc_bindings, value.obligations))
    }
    result
}

enum CoreFieldRefValue {
    NominalFieldValue(NominalFieldRef),
    VariantFieldValue(VariantFieldRef),
    TupleFieldValue(Int),
    RecordFieldValue(PathRef)
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
pub fn make_core_record_field(value: PathRef) -> CoreFieldRef {
    CoreFieldRef { value: CoreFieldRefValue::RecordFieldValue(value) }
}
pub fn core_field_ref_kind_tag(value: CoreFieldRef) -> Int {
    match value.value {
        CoreFieldRefValue::NominalFieldValue(_) => 0,
        CoreFieldRefValue::TupleFieldValue(_) => 1,
        CoreFieldRefValue::RecordFieldValue(_) => 2,
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
        CoreFieldRefValue::RecordFieldValue(path) => path,
        _ => panic("CoreHIR: non-record field has no path")
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
        (CoreFieldRefValue::RecordFieldValue(a),
         CoreFieldRefValue::RecordFieldValue(b)) => path_ref_same(a, b),
        _ => false
    }
}

enum CoreConstructorRefValue {
    StructConstructorValue(RegisteredNominalRef),
    VariantConstructorValue(VariantRef),
    TupleConstructorValue(Int),
    RecordConstructorValue(Int)
}

pub struct CoreConstructorRef {
    value: CoreConstructorRefValue,
    executable: ExecutableRef?
}

pub fn make_core_struct_constructor(
    owner: RegisteredNominalRef, executable: ExecutableRef
) -> CoreConstructorRef {
    CoreConstructorRef {
        value: CoreConstructorRefValue::StructConstructorValue(owner),
        executable: some(executable)
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
pub fn make_core_record_constructor(arity: Int) -> CoreConstructorRef {
    if arity < 0 { panic("CoreHIR: negative record constructor arity") }
    CoreConstructorRef {
        value: CoreConstructorRefValue::RecordConstructorValue(arity),
        executable: none
    }
}
pub fn core_constructor_kind_tag(value: CoreConstructorRef) -> Int {
    match value.value {
        CoreConstructorRefValue::StructConstructorValue(_) => 0,
        CoreConstructorRefValue::VariantConstructorValue(_) => 1,
        CoreConstructorRefValue::TupleConstructorValue(_) => 2,
        CoreConstructorRefValue::RecordConstructorValue(_) => 3
    }
}
pub fn core_constructor_struct_owner(
    value: CoreConstructorRef
) -> RegisteredNominalRef {
    match value.value {
        CoreConstructorRefValue::StructConstructorValue(owner) => owner,
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
        CoreConstructorRefValue::TupleConstructorValue(arity) |
        CoreConstructorRefValue::RecordConstructorValue(arity) => arity,
        _ => panic("CoreHIR: nominal constructor has no structural arity")
    }
}
pub fn core_constructor_executable(value: CoreConstructorRef) -> ExecutableRef? {
    value.executable
}

pub struct CoreFieldValue {
    field: CoreFieldRef,
    value: SlotRef
}

pub fn make_core_field_value(
    field: CoreFieldRef, value: SlotRef
) -> CoreFieldValue { CoreFieldValue { field: field, value: value } }
pub fn core_field_value_field(value: CoreFieldValue) -> CoreFieldRef { value.field }
pub fn core_field_value_slot(value: CoreFieldValue) -> SlotRef { value.value }
fn copy_field_values(values: List<CoreFieldValue>) -> List<CoreFieldValue> {
    let mut result: List<CoreFieldValue> = []
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
        CorePatternValue::StructPatternValue { fields, .. } |
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
    ReadExprValue(SlotRef),
    PrimitiveExprValue { operation: CorePrimitiveOp, operands: List<SlotRef> },
    CallExprValue {
        callee: CoreCalleeRef,
        arguments: List<SlotRef>,
        evidence: List<CoreEvidenceRef>
    },
    MethodCallExprValue {
        callee: CoreCalleeRef,
        method: MethodCallRef,
        receiver: SlotRef,
        arguments: List<SlotRef>,
        evidence: List<CoreEvidenceRef>
    },
    EffectCallExprValue {
        operation: EffectOperationRef,
        arguments: List<SlotRef>,
        evidence: List<CoreEvidenceRef>
    },
    SystemCallExprValue {
        host: SystemHostCallableRef,
        arguments: List<SlotRef>
    },
    DictConstructExprValue {
        constructor: ExecutableRef,
        evidence: List<CoreEvidenceRef>
    },
    DictProjectExprValue {
        dictionary: SlotRef,
        method: ExecutableRef
    },
    ProjectExprValue {
        base: SlotRef,
        field: CoreFieldRef,
        partial: Bool
    },
    ConstructExprValue {
        constructor: CoreConstructorRef,
        fields: List<CoreFieldValue>
    },
    LambdaExprValue {
        executable: ExecutableRef,
        manifest: BinderManifest,
        captures: List<CoreCapture>
    },
    BlockExprValue(CoreBlock),
    IfExprValue {
        condition: SlotRef,
        then_block: CoreBlock,
        else_block: CoreBlock
    },
    MatchExprValue {
        scrutinee: SlotRef,
        arms: List<CoreMatchArm>
    },
    TryCatchExprValue {
        body: CoreBlock,
        error_slot: SlotRef,
        arms: List<CoreMatchArm>
    },
    HandleExprValue {
        body: CoreBlock,
        handlers: List<CoreHandlerEntry>
    }
}

pub struct CoreExpr {
    result: SlotRef,
    ty: CoreTypeRef,
    effects: CoreEffectSet,
    origin: OriginRef,
    value: CoreExprValue
}

enum CoreStmtValue {
    Initialize {
        target: SlotRef, value: CoreExpr, origin: OriginRef
    },
    Assign {
        target: SlotRef, value: CoreExpr, origin: OriginRef
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
    origin: OriginRef,
    scope: FlowScopeRef
}

pub struct CoreMatchArm {
    pattern: CorePattern,
    guard: CoreExpr?,
    body: CoreBlock,
    origin: OriginRef
}

pub struct CoreHandlerEntry {
    operation: EffectOperationRef,
    executable: ExecutableRef,
    manifest: BinderManifest,
    parameter_slots: List<SlotRef>,
    resume_slot: SlotRef?,
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
fn copy_handler_entries(values: List<CoreHandlerEntry>) -> List<CoreHandlerEntry> {
    let mut result: List<CoreHandlerEntry> = []
    for value in values { result.push(value) }
    result
}
fn copy_manifest(value: BinderManifest) -> BinderManifest {
    make_binder_manifest(
        binder_manifest_owner(value), binder_manifest_entries(value))
}

fn make_core_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, value: CoreExprValue
) -> CoreExpr {
    CoreExpr {
        result: result, ty: ty,
        effects: make_core_effect_set(effects.atoms),
        origin: origin, value: value
    }
}

pub fn make_core_literal_expr(
    result: SlotRef, ty: CoreTypeRef, origin: OriginRef, literal: CoreLiteral
) -> CoreExpr {
    make_core_expr(
        result, ty, make_core_effect_set([]), origin,
        CoreExprValue::LiteralExprValue(literal))
}
pub fn make_core_read_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, source: SlotRef
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::ReadExprValue(source))
}
pub fn make_core_primitive_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, operation: CorePrimitiveOp,
    operands: List<SlotRef>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::PrimitiveExprValue {
            operation: operation, operands: copy_slot_refs(operands)
        })
}
pub fn make_core_call_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, callee: CoreCalleeRef,
    arguments: List<SlotRef>, evidence: List<CoreEvidenceRef>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::CallExprValue {
            callee: callee, arguments: copy_slot_refs(arguments),
            evidence: copy_evidence(evidence)
        })
}
pub fn make_core_method_call_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, callee: CoreCalleeRef, method: MethodCallRef,
    receiver: SlotRef, arguments: List<SlotRef>,
    evidence: List<CoreEvidenceRef>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::MethodCallExprValue {
            callee: callee, method: method, receiver: receiver,
            arguments: copy_slot_refs(arguments),
            evidence: copy_evidence(evidence)
        })
}
pub fn make_core_effect_call_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, operation: EffectOperationRef,
    arguments: List<SlotRef>, evidence: List<CoreEvidenceRef>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::EffectCallExprValue {
            operation: operation, arguments: copy_slot_refs(arguments),
            evidence: copy_evidence(evidence)
        })
}
pub fn make_core_system_call_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, host: SystemHostCallableRef,
    arguments: List<SlotRef>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::SystemCallExprValue {
            host: host, arguments: copy_slot_refs(arguments)
        })
}
pub fn make_core_dict_construct_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, constructor: ExecutableRef,
    evidence: List<CoreEvidenceRef>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::DictConstructExprValue {
            constructor: constructor, evidence: copy_evidence(evidence)
        })
}
pub fn make_core_dict_project_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, dictionary: SlotRef, method: ExecutableRef
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::DictProjectExprValue {
            dictionary: dictionary, method: method
        })
}
pub fn make_core_project_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, base: SlotRef, field: CoreFieldRef, partial: Bool
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::ProjectExprValue {
            base: base, field: field, partial: partial
        })
}
pub fn make_core_construct_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, constructor: CoreConstructorRef,
    fields: List<CoreFieldValue>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::ConstructExprValue {
            constructor: constructor, fields: copy_field_values(fields)
        })
}
pub fn make_core_lambda_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, executable: ExecutableRef,
    manifest: BinderManifest, captures: List<CoreCapture>
) -> CoreExpr {
    if !executable_ref_same(executable, binder_manifest_owner(manifest)) {
        panic("CoreHIR: lambda executable/manifest identity differs")
    }
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::LambdaExprValue {
            executable: executable, manifest: copy_manifest(manifest),
            captures: copy_captures(captures)
        })
}

pub fn make_core_block(
    statements: List<CoreStmt>, tail: CoreExpr?, origin: OriginRef,
    scope: FlowScopeRef
) -> CoreBlock {
    CoreBlock {
        statements: copy_statements(statements), tail: tail,
        origin: origin, scope: scope
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
pub fn make_core_handler_entry(
    operation: EffectOperationRef, executable: ExecutableRef,
    manifest: BinderManifest, parameter_slots: List<SlotRef>,
    resume_slot: SlotRef?, origin: OriginRef
) -> CoreHandlerEntry {
    if !executable_ref_same(executable, binder_manifest_owner(manifest)) {
        panic("CoreHIR: handler executable/manifest identity differs")
    }
    CoreHandlerEntry {
        operation: operation, executable: executable,
        manifest: copy_manifest(manifest),
        parameter_slots: copy_slot_refs(parameter_slots),
        resume_slot: resume_slot, origin: origin
    }
}
pub fn make_core_block_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, block: CoreBlock
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::BlockExprValue(block))
}
pub fn make_core_if_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, condition: SlotRef,
    then_block: CoreBlock, else_block: CoreBlock
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::IfExprValue {
            condition: condition,
            then_block: then_block, else_block: else_block
        })
}
pub fn make_core_match_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, scrutinee: SlotRef, arms: List<CoreMatchArm>
) -> CoreExpr {
    if arms.len() == 0 { panic("CoreHIR: match has no arms") }
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::MatchExprValue {
            scrutinee: scrutinee, arms: copy_match_arms(arms)
        })
}
pub fn make_core_try_catch_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, body: CoreBlock, error_slot: SlotRef,
    arms: List<CoreMatchArm>
) -> CoreExpr {
    if arms.len() == 0 { panic("CoreHIR: catch has no arms") }
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::TryCatchExprValue {
            body: body, error_slot: error_slot,
            arms: copy_match_arms(arms)
        })
}
pub fn make_core_handle_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, body: CoreBlock,
    handlers: List<CoreHandlerEntry>
) -> CoreExpr {
    if handlers.len() == 0 { panic("CoreHIR: handle has no handlers") }
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::HandleExprValue {
            body: body, handlers: copy_handler_entries(handlers)
        })
}

pub fn make_core_initialize_stmt(
    target: SlotRef, value: CoreExpr, origin: OriginRef
) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::Initialize {
        target: target, value: value, origin: origin
    } }
}
pub fn make_core_assign_stmt(
    target: SlotRef, value: CoreExpr, origin: OriginRef
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
        CoreStmtValue::Initialize { .. } => 0,
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
        CoreStmtValue::Initialize { origin, .. } |
        CoreStmtValue::Assign { origin, .. } |
        CoreStmtValue::ExprStmt { origin, .. } |
        CoreStmtValue::While { origin, .. } |
        CoreStmtValue::Break { origin } |
        CoreStmtValue::Continue { origin } |
        CoreStmtValue::Return { origin, .. } => origin
    }
}
pub fn core_stmt_target(value: CoreStmt) -> SlotRef {
    match value.value {
        CoreStmtValue::Initialize { target, .. } |
        CoreStmtValue::Assign { target, .. } => target,
        _ => panic("CoreHIR: statement has no target")
    }
}
pub fn core_stmt_value(value: CoreStmt) -> CoreExpr {
    match value.value {
        CoreStmtValue::Initialize { value: expr, .. } |
        CoreStmtValue::Assign { value: expr, .. } |
        CoreStmtValue::ExprStmt { value: expr, .. } => expr,
        _ => panic("CoreHIR: statement has no required expression")
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

pub fn core_expr_result(value: CoreExpr) -> SlotRef { value.result }
pub fn core_expr_type(value: CoreExpr) -> CoreTypeRef { value.ty }
pub fn core_expr_effects(value: CoreExpr) -> CoreEffectSet {
    make_core_effect_set(value.effects.atoms)
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
        CoreExprValue::DictConstructExprValue { .. } => 7,
        CoreExprValue::DictProjectExprValue { .. } => 8,
        CoreExprValue::ProjectExprValue { .. } => 9,
        CoreExprValue::ConstructExprValue { .. } => 10,
        CoreExprValue::LambdaExprValue { .. } => 11,
        CoreExprValue::BlockExprValue(_) => 12,
        CoreExprValue::IfExprValue { .. } => 13,
        CoreExprValue::MatchExprValue { .. } => 14,
        CoreExprValue::TryCatchExprValue { .. } => 15,
        CoreExprValue::HandleExprValue { .. } => 16
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
pub fn core_expr_primitive_operation(value: CoreExpr) -> CorePrimitiveOp {
    match value.value {
        CoreExprValue::PrimitiveExprValue { operation, .. } => operation,
        _ => panic("CoreHIR: expression is not Primitive")
    }
}
pub fn core_expr_primitive_operands(value: CoreExpr) -> List<SlotRef> {
    match value.value {
        CoreExprValue::PrimitiveExprValue { operands, .. } =>
            copy_slot_refs(operands),
        _ => panic("CoreHIR: expression is not Primitive")
    }
}
pub fn core_expr_call_callee(value: CoreExpr) -> CoreCalleeRef {
    match value.value {
        CoreExprValue::CallExprValue { callee, .. } |
        CoreExprValue::MethodCallExprValue { callee, .. } => callee,
        _ => panic("CoreHIR: expression has no callee")
    }
}
pub fn core_expr_call_arguments(value: CoreExpr) -> List<SlotRef> {
    match value.value {
        CoreExprValue::CallExprValue { arguments, .. } |
        CoreExprValue::MethodCallExprValue { arguments, .. } |
        CoreExprValue::EffectCallExprValue { arguments, .. } |
        CoreExprValue::SystemCallExprValue { arguments, .. } =>
            copy_slot_refs(arguments),
        _ => panic("CoreHIR: expression has no call arguments")
    }
}
pub fn core_expr_call_evidence(value: CoreExpr) -> List<CoreEvidenceRef> {
    match value.value {
        CoreExprValue::CallExprValue { evidence, .. } |
        CoreExprValue::MethodCallExprValue { evidence, .. } |
        CoreExprValue::EffectCallExprValue { evidence, .. } |
        CoreExprValue::DictConstructExprValue { evidence, .. } =>
            copy_evidence(evidence),
        _ => panic("CoreHIR: expression has no evidence list")
    }
}
pub fn core_expr_method_ref(value: CoreExpr) -> MethodCallRef {
    match value.value {
        CoreExprValue::MethodCallExprValue { method, .. } => method,
        _ => panic("CoreHIR: expression is not MethodCall")
    }
}
pub fn core_expr_method_receiver(value: CoreExpr) -> SlotRef {
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
pub fn core_expr_dict_constructor(value: CoreExpr) -> ExecutableRef {
    match value.value {
        CoreExprValue::DictConstructExprValue { constructor, .. } => constructor,
        _ => panic("CoreHIR: expression is not DictConstruct")
    }
}
pub fn core_expr_dict_project_dictionary(value: CoreExpr) -> SlotRef {
    match value.value {
        CoreExprValue::DictProjectExprValue { dictionary, .. } => dictionary,
        _ => panic("CoreHIR: expression is not DictProject")
    }
}
pub fn core_expr_dict_project_method(value: CoreExpr) -> ExecutableRef {
    match value.value {
        CoreExprValue::DictProjectExprValue { method, .. } => method,
        _ => panic("CoreHIR: expression is not DictProject")
    }
}
pub fn core_expr_project_base(value: CoreExpr) -> SlotRef {
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
pub fn core_expr_lambda_executable(value: CoreExpr) -> ExecutableRef {
    match value.value {
        CoreExprValue::LambdaExprValue { executable, .. } => executable,
        _ => panic("CoreHIR: expression is not Lambda")
    }
}
pub fn core_expr_lambda_manifest(value: CoreExpr) -> BinderManifest {
    match value.value {
        CoreExprValue::LambdaExprValue { manifest, .. } => copy_manifest(manifest),
        _ => panic("CoreHIR: expression is not Lambda")
    }
}
pub fn core_expr_lambda_captures(value: CoreExpr) -> List<CoreCapture> {
    match value.value {
        CoreExprValue::LambdaExprValue { captures, .. } => copy_captures(captures),
        _ => panic("CoreHIR: expression is not Lambda")
    }
}
pub fn core_expr_block(value: CoreExpr) -> CoreBlock {
    match value.value {
        CoreExprValue::BlockExprValue(block) => block,
        _ => panic("CoreHIR: expression is not Block")
    }
}
pub fn core_expr_condition(value: CoreExpr) -> SlotRef {
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
pub fn core_expr_scrutinee(value: CoreExpr) -> SlotRef {
    match value.value {
        CoreExprValue::MatchExprValue { scrutinee, .. } => scrutinee,
        _ => panic("CoreHIR: expression is not Match")
    }
}
pub fn core_expr_match_arms(value: CoreExpr) -> List<CoreMatchArm> {
    match value.value {
        CoreExprValue::MatchExprValue { arms, .. } |
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
pub fn core_expr_handlers(value: CoreExpr) -> List<CoreHandlerEntry> {
    match value.value {
        CoreExprValue::HandleExprValue { handlers, .. } =>
            copy_handler_entries(handlers),
        _ => panic("CoreHIR: expression is not Handle")
    }
}
pub fn core_block_statements(value: CoreBlock) -> List<CoreStmt> {
    copy_statements(value.statements)
}
pub fn core_block_tail(value: CoreBlock) -> CoreExpr? { value.tail }
pub fn core_block_origin(value: CoreBlock) -> OriginRef { value.origin }
pub fn core_block_scope(value: CoreBlock) -> FlowScopeRef { value.scope }
pub fn core_match_arm_pattern(value: CoreMatchArm) -> CorePattern { value.pattern }
pub fn core_match_arm_guard(value: CoreMatchArm) -> CoreExpr? { value.guard }
pub fn core_match_arm_body(value: CoreMatchArm) -> CoreBlock { value.body }
pub fn core_match_arm_origin(value: CoreMatchArm) -> OriginRef { value.origin }
pub fn core_handler_operation(
    value: CoreHandlerEntry
) -> EffectOperationRef { value.operation }
pub fn core_handler_executable(value: CoreHandlerEntry) -> ExecutableRef {
    value.executable
}
pub fn core_handler_manifest(value: CoreHandlerEntry) -> BinderManifest {
    copy_manifest(value.manifest)
}
pub fn core_handler_parameter_slots(value: CoreHandlerEntry) -> List<SlotRef> {
    copy_slot_refs(value.parameter_slots)
}
pub fn core_handler_resume_slot(value: CoreHandlerEntry) -> SlotRef? {
    value.resume_slot
}
pub fn core_handler_origin(value: CoreHandlerEntry) -> OriginRef { value.origin }

// ============================================================
// Closed structured body and recursive validator
// ============================================================

pub struct CoreSlot {
    reference: SlotRef,
    ty: CoreTypeRef,
    scope: FlowScopeRef,
    reverse_ordinal: Int,
    initial_state: FlowInitialSlotState,
    storage: FlowStorageClass,
    storage_contract: FlowStorageContract,
    parameter_ordinal: Int?
}

pub fn make_core_slot(
    reference: SlotRef, ty: CoreTypeRef, scope: FlowScopeRef,
    reverse_ordinal: Int, initial_state: FlowInitialSlotState,
    storage: FlowStorageClass, storage_contract: FlowStorageContract,
    parameter_ordinal: Int?
) -> CoreSlot {
    if reverse_ordinal < 0 {
        panic("CoreHIR: negative reverse slot ordinal")
    }
    let _ = flow_initial_slot_state_tag(initial_state)
    let _ = flow_storage_class_tag(storage)
    let _ = flow_storage_contract_tag(storage_contract)
    CoreSlot {
        reference: reference, ty: ty, scope: scope,
        reverse_ordinal: reverse_ordinal,
        initial_state: initial_state, storage: storage,
        storage_contract: storage_contract,
        parameter_ordinal: parameter_ordinal
    }
}
pub fn core_slot_reference(value: CoreSlot) -> SlotRef { value.reference }
pub fn core_slot_type(value: CoreSlot) -> CoreTypeRef { value.ty }
pub fn core_slot_scope(value: CoreSlot) -> FlowScopeRef { value.scope }
pub fn core_slot_reverse_ordinal(value: CoreSlot) -> Int { value.reverse_ordinal }
pub fn core_slot_initial_state(value: CoreSlot) -> FlowInitialSlotState {
    value.initial_state
}
pub fn core_slot_storage(value: CoreSlot) -> FlowStorageClass { value.storage }
pub fn core_slot_storage_contract(value: CoreSlot) -> FlowStorageContract {
    value.storage_contract
}
pub fn core_slot_parameter_ordinal(value: CoreSlot) -> Int? {
    value.parameter_ordinal
}
fn copy_core_slots(values: List<CoreSlot>) -> List<CoreSlot> {
    let mut result: List<CoreSlot> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreBody {
    reference: ExecutableRef,
    origin: OriginRef,
    type_count: Int,
    manifest: BinderManifest,
    scopes: List<FlowScope>,
    slots: List<CoreSlot>,
    parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef,
    body: CoreBlock
}

fn copy_flow_scopes(values: List<FlowScope>) -> List<FlowScope> {
    let mut result: List<FlowScope> = []
    for value in values { result.push(value) }
    result
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
    value.index >= 0 && value.index < type_count
}
fn slot_index(values: List<CoreSlot>, target: SlotRef) -> Int? {
    let mut index = 0
    for value in values {
        if slot_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}
fn require_slot(values: List<CoreSlot>, target: SlotRef) {
    if slot_index(values, target).is_none() {
        panic("CoreHIR: expression references an undeclared slot")
    }
}
fn validate_effect_set(value: CoreEffectSet, type_count: Int) {
    let _ = make_core_effect_set(value.atoms)
    for atom in value.atoms {
        match atom.value {
            CoreEffectAtomValue::FailEffectValue(ty) |
            CoreEffectAtomValue::MutEffectValue(ty) => if !type_ref_valid(
                    ty, type_count) {
                panic("CoreHIR: effect atom has an unresolved type")
            },
            _ => {}
        }
    }
}
fn validate_evidence(values: List<CoreEvidenceRef>, slots: List<CoreSlot>) {
    for value in values {
        if core_evidence_is_local(value) {
            require_slot(slots, core_evidence_local(value))
        }
    }
}

fn manifest_contains_slot(value: BinderManifest, target: SlotRef) -> Bool {
    for binder in binder_manifest_entries(value) {
        if slot_ref_same(binder_entry_slot(binder), target) { return true }
    }
    false
}

fn validate_pattern(
    value: CorePattern, slots: List<CoreSlot>, seen: List<SlotRef>
) -> List<SlotRef> {
    let mut result = copy_slot_refs(seen)
    match value.value {
        CorePatternValue::WildcardPatternValue |
        CorePatternValue::LiteralPatternValue(_) => {},
        CorePatternValue::BindingPatternValue(slot) => {
            require_slot(slots, slot)
            for existing in result {
                if slot_ref_same(existing, slot) {
                    panic("CoreHIR: pattern binds a slot twice")
                }
            }
            result.push(slot)
        },
        CorePatternValue::TuplePatternValue(elements) => {
            for element in elements {
                result = validate_pattern(element, slots, result)
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
                result = validate_pattern(field.pattern, slots, result)
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
                result = validate_pattern(field.pattern, slots, result)
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
        require_slot(body.slots, slot)
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
    slots: List<CoreSlot>
) {
    let mut index = 0
    while index < fields.len() {
        let field = fields.get(index).unwrap()
        require_slot(slots, field.value)
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
        CoreConstructorRefValue::StructConstructorValue(owner) => {
            let symbol = registered_nominal_ref_symbol(owner)
            for field in fields {
                match field.field.value {
                    CoreFieldRefValue::NominalFieldValue(reference) => if
                        !symbol_ref_same(
                            nominal_field_ref_owner(reference), symbol) {
                        panic("CoreHIR: struct constructor field crosses owner")
                    },
                    _ => panic("CoreHIR: struct constructor uses non-nominal field")
                }
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
        CoreConstructorRefValue::TupleConstructorValue(arity) |
        CoreConstructorRefValue::RecordConstructorValue(arity) => {
            if fields.len() != arity {
                panic("CoreHIR: structural constructor arity differs")
            }
        }
    }
}

fn validate_expr_with_loop_depth(
    value: CoreExpr, body: CoreBody, loop_depth: Int
) {
    require_slot(body.slots, value.result)
    if !type_ref_valid(value.ty, body.type_count) {
        panic("CoreHIR: expression has an unresolved type")
    }
    validate_origin(value.origin, body.reference)
    validate_effect_set(value.effects, body.type_count)
    match value.value {
        CoreExprValue::LiteralExprValue(_) => {},
        CoreExprValue::ReadExprValue(source) => require_slot(body.slots, source),
        CoreExprValue::PrimitiveExprValue { operation, operands } => {
            let _ = core_primitive_op_tag(operation)
            for operand in operands { require_slot(body.slots, operand) }
        },
        CoreExprValue::CallExprValue { callee, arguments, evidence } => {
            validate_callee(callee, body)
            for argument in arguments { require_slot(body.slots, argument) }
            validate_evidence(evidence, body.slots)
        },
        CoreExprValue::MethodCallExprValue {
            callee, receiver, arguments, evidence, ..
        } => {
            validate_callee(callee, body)
            require_slot(body.slots, receiver)
            for argument in arguments { require_slot(body.slots, argument) }
            validate_evidence(evidence, body.slots)
        },
        CoreExprValue::EffectCallExprValue {
            arguments, evidence, ..
        } => {
            for argument in arguments { require_slot(body.slots, argument) }
            validate_evidence(evidence, body.slots)
        },
        CoreExprValue::SystemCallExprValue { arguments, .. } => {
            for argument in arguments { require_slot(body.slots, argument) }
        },
        CoreExprValue::DictConstructExprValue { evidence, .. } =>
            validate_evidence(evidence, body.slots),
        CoreExprValue::DictProjectExprValue { dictionary, .. } =>
            require_slot(body.slots, dictionary),
        CoreExprValue::ProjectExprValue { base, .. } =>
            require_slot(body.slots, base),
        CoreExprValue::ConstructExprValue { constructor, fields } =>
            validate_constructor_fields(constructor, fields, body.slots),
        CoreExprValue::LambdaExprValue {
            executable, manifest, captures
        } => {
            if !executable_ref_same(
                    executable, binder_manifest_owner(manifest)) {
                panic("CoreHIR: lambda manifest drifted")
            }
            for capture in captures {
                require_slot(body.slots, capture.source)
                if !manifest_contains_slot(manifest, capture.target) {
                    panic("CoreHIR: lambda capture target is absent from manifest")
                }
            }
        },
        CoreExprValue::BlockExprValue(block) =>
            validate_block_with_loop_depth(block, body, loop_depth),
        CoreExprValue::IfExprValue {
            condition, then_block, else_block
        } => {
            require_slot(body.slots, condition)
            validate_block_with_loop_depth(then_block, body, loop_depth)
            validate_block_with_loop_depth(else_block, body, loop_depth)
        },
        CoreExprValue::MatchExprValue { scrutinee, arms } => {
            require_slot(body.slots, scrutinee)
            for arm in arms { validate_match_arm(arm, body, loop_depth) }
        },
        CoreExprValue::TryCatchExprValue {
            body: protected, error_slot, arms
        } => {
            require_slot(body.slots, error_slot)
            validate_block_with_loop_depth(protected, body, loop_depth)
            for arm in arms { validate_match_arm(arm, body, loop_depth) }
        },
        CoreExprValue::HandleExprValue { body: handled_body, handlers } => {
            validate_block_with_loop_depth(handled_body, body, loop_depth)
            let mut index = 0
            while index < handlers.len() {
                let handler = handlers.get(index).unwrap()
                validate_origin(handler.origin, body.reference)
                if !executable_ref_same(
                        handler.executable,
                        binder_manifest_owner(handler.manifest)) {
                    panic("CoreHIR: handler manifest drifted")
                }
                for parameter in handler.parameter_slots {
                    if !manifest_contains_slot(handler.manifest, parameter) {
                        panic("CoreHIR: handler parameter is absent from manifest")
                    }
                }
                match handler.resume_slot {
                    some(slot) => if !manifest_contains_slot(
                            handler.manifest, slot) {
                        panic("CoreHIR: handler resume slot is absent from manifest")
                    },
                    none => {}
                }
                let mut right_index = index + 1
                while right_index < handlers.len() {
                    let right = handlers.get(right_index).unwrap()
                    if effect_operation_ref_same(
                            handler.operation, right.operation) {
                        panic("CoreHIR: handle repeats an exact operation")
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
    let _ = validate_pattern(value.pattern, body.slots, [])
    match value.guard {
        some(guard) => validate_expr_with_loop_depth(
            guard, body, loop_depth),
        none => {}
    }
    validate_block_with_loop_depth(value.body, body, loop_depth)
}

fn validate_statement(value: CoreStmt, body: CoreBody, loop_depth: Int) {
    match value.value {
        CoreStmtValue::Initialize { target, value: expr, origin } |
        CoreStmtValue::Assign { target, value: expr, origin } => {
            validate_origin(origin, body.reference)
            require_slot(body.slots, target)
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
        CoreStmtValue::Break { origin } | CoreStmtValue::Continue { origin } => {
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
    let mut scope_found = false
    for scope in body.scopes {
        if flow_scope_ref_same(flow_scope_reference(scope), value.scope) {
            scope_found = true
        }
    }
    if !scope_found {
        panic("CoreHIR: block scope is absent from body")
    }
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

pub fn make_core_body(
    reference: ExecutableRef, origin: OriginRef, type_count: Int,
    manifest: BinderManifest, scopes: List<FlowScope>, slots: List<CoreSlot>,
    parameter_slots: List<SlotRef>, result_type: CoreTypeRef,
    body: CoreBlock
) -> CoreBody {
    if type_count <= 0 || !type_ref_valid(result_type, type_count) {
        panic("CoreHIR: body has no closed result type graph")
    }
    if !executable_ref_same(reference, binder_manifest_owner(manifest)) {
        panic("CoreHIR: body executable/manifest identity differs")
    }
    if scopes.len() == 0 {
        panic("CoreHIR: body has no exact scope table")
    }
    let mut scope_index = 0
    while scope_index < scopes.len() {
        let scope = flow_scope_reference(scopes.get(scope_index).unwrap())
        if !executable_ref_same(flow_scope_ref_owner(scope), reference) ||
           flow_scope_ref_ordinal(scope) != scope_index {
            panic("CoreHIR: scope owner/order differs")
        }
        scope_index = scope_index + 1
    }
    let binders = binder_manifest_entries(manifest)
    if binders.len() != slots.len() {
        panic("CoreHIR: binder/typed-slot census differs")
    }
    let mut index = 0
    while index < slots.len() {
        let slot = slots.get(index).unwrap()
        if !slot_ref_same(
                slot.reference, binder_entry_slot(binders.get(index).unwrap())) ||
           !type_ref_valid(slot.ty, type_count) {
            panic("CoreHIR: typed slot order/type is invalid")
        }
        let mut scope_found = false
        for scope in scopes {
            if flow_scope_ref_same(
                    flow_scope_reference(scope), slot.scope) {
                scope_found = true
            }
        }
        if !scope_found {
            panic("CoreHIR: typed slot scope is absent")
        }
        let mut right_index = index + 1
        while right_index < slots.len() {
            if slot_ref_same(
                    slot.reference, slots.get(right_index).unwrap().reference) {
                panic("CoreHIR: body repeats a slot")
            }
            right_index = right_index + 1
        }
        index = index + 1
    }
    let mut parameter_index = 0
    while parameter_index < parameter_slots.len() {
        let parameter = parameter_slots.get(parameter_index).unwrap()
        require_slot(slots, parameter)
        let mut right_index = parameter_index + 1
        while right_index < parameter_slots.len() {
            if slot_ref_same(
                    parameter, parameter_slots.get(right_index).unwrap()) {
                panic("CoreHIR: body repeats a parameter slot")
            }
            right_index = right_index + 1
        }
        parameter_index = parameter_index + 1
    }
    let result = CoreBody {
        reference: reference, origin: origin, type_count: type_count,
        manifest: copy_manifest(manifest), scopes: copy_flow_scopes(scopes),
        slots: copy_core_slots(slots),
        parameter_slots: copy_slot_refs(parameter_slots),
        result_type: result_type, body: body
    }
    validate_core_body(result)
    result
}

pub fn validate_core_body(value: CoreBody) {
    validate_origin(value.origin, value.reference)
    if !executable_ref_same(
            value.reference, binder_manifest_owner(value.manifest)) {
        panic("CoreHIR: body manifest identity drifted")
    }
    validate_block(value.body, value)
}

pub fn core_body_reference(value: CoreBody) -> ExecutableRef { value.reference }
pub fn core_body_origin(value: CoreBody) -> OriginRef { value.origin }
pub fn core_body_type_count(value: CoreBody) -> Int { value.type_count }
pub fn core_body_manifest(value: CoreBody) -> BinderManifest {
    copy_manifest(value.manifest)
}
pub fn core_body_scopes(value: CoreBody) -> List<FlowScope> {
    copy_flow_scopes(value.scopes)
}
pub fn core_body_slots(value: CoreBody) -> List<CoreSlot> {
    copy_core_slots(value.slots)
}
pub fn core_body_parameter_slots(value: CoreBody) -> List<SlotRef> {
    copy_slot_refs(value.parameter_slots)
}
pub fn core_body_result_type(value: CoreBody) -> CoreTypeRef { value.result_type }
pub fn core_body_block(value: CoreBody) -> CoreBlock { value.body }

// ============================================================
// Collection-complete CoreProgram validation
// ============================================================

fn core_slot_type_for(value: CoreBody, slot: SlotRef) -> CoreTypeRef {
    match slot_index(value.slots, slot) {
        some(index) => core_slot_type(value.slots.get(index).unwrap()),
        none => panic("CoreHIR: program validation found an absent slot")
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
        let _ = core_type_graph_node(graph, left.result_type)
        let mut parameter_index = 0
        for parameter in left.parameter_types {
            let _ = core_type_graph_node(graph, parameter)
            if flow_type_ref_index(
                    flow_call_contract_parameter_types(
                        left.semantic_contract).get(
                            parameter_index).unwrap()) != parameter.index {
                panic("CoreHIR: callable semantic parameter type drifted")
            }
            parameter_index = parameter_index + 1
        }
        if flow_type_ref_index(flow_call_contract_result_type(
                left.semantic_contract)) != left.result_type.index {
            panic("CoreHIR: callable semantic result type drifted")
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

fn validate_evidence_count(
    evidence: List<CoreEvidenceRef>, contract: CoreCallableContract,
    body: CoreBody
) {
    if evidence.len() != contract.evidence_requirements.len() {
        panic("CoreHIR: call evidence census differs from exact contract")
    }
    validate_evidence(evidence, body.slots)
}

fn validate_call_signature(
    callee: CoreCalleeRef, arguments: List<SlotRef>, result_type: CoreTypeRef,
    evidence: List<CoreEvidenceRef>, body: CoreBody,
    graph: CoreTypeGraph, callables: List<CoreCallableContract>
) {
    if callee.candidates.len() == 0 {
        panic("CoreHIR: call has no finite candidate set")
    }
    let flow_parameters = flow_call_contract_parameter_types(callee.contract)
    if arguments.len() != flow_parameters.len() {
        panic("CoreHIR: call argument arity differs from exact contract")
    }
    let mut index = 0
    while index < arguments.len() {
        if core_slot_type_for(body, arguments.get(index).unwrap()).index !=
           flow_type_ref_index(flow_parameters.get(index).unwrap()) {
            panic("CoreHIR: call argument type differs from exact contract")
        }
        index = index + 1
    }
    if result_type.index != flow_type_ref_index(
            flow_call_contract_result_type(callee.contract)) {
        panic("CoreHIR: call result type differs from exact contract")
    }
    let mut evidence_contract: CoreCallableContract? = none
    for candidate_ref in callee.candidates {
        let candidate = core_callable_for(callables, candidate_ref)
        if !flow_call_contract_same(
                candidate.semantic_contract, callee.contract) {
            panic("CoreHIR: call candidate semantic contract differs")
        }
        match evidence_contract {
            some(existing) => {
                if existing.evidence_requirements.len() !=
                   candidate.evidence_requirements.len() {
                    panic("CoreHIR: call candidates have different evidence")
                }
                let mut requirement_index = 0
                while requirement_index < existing.evidence_requirements.len() {
                    if !symbol_ref_same(
                            existing.evidence_requirements.get(
                                requirement_index).unwrap(),
                            candidate.evidence_requirements.get(
                                requirement_index).unwrap()) {
                        panic("CoreHIR: call candidate evidence order differs")
                    }
                    requirement_index = requirement_index + 1
                }
            },
            none => { evidence_contract = some(candidate) }
        }
    }
    let exact = match evidence_contract {
        some(value) => value,
        none => panic("CoreHIR: call evidence contract is absent")
    }
    validate_evidence_count(evidence, exact, body)
    if callee.kind == CORE_CALLEE_DIRECT {
        if callee.candidates.len() != 1 ||
           !executable_ref_same(
                callee.candidates.get(0).unwrap(), core_callee_direct(callee)) {
            panic("CoreHIR: direct call candidate differs")
        }
    } else if callee.kind == CORE_CALLEE_LOCAL {
        let callable_ty = core_type_graph_node(
            graph, core_slot_type_for(body, core_callee_local(callee)))
        if flow_type_kind_tag(flow_type_node_kind(callable_ty)) !=
           flow_type_kind_tag(flow_type_kind_callable()) ||
           flow_type_node_parameter_count(callable_ty) != arguments.len() {
            panic("CoreHIR: local callee slot is not exact callable type")
        }
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
        CoreFieldRefValue::RecordFieldValue(path) =>
            !flow_field_identity_is_nominal(flow) &&
                !flow_field_identity_is_variant(flow) &&
                path_ref_same(path, flow_field_identity_path(flow)),
        CoreFieldRefValue::TupleFieldValue(_) => false
    }
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
    operation: CorePrimitiveOp, operands: List<SlotRef>,
    result_type: CoreTypeRef, body: CoreBody, graph: CoreTypeGraph
) {
    let tag = core_primitive_op_tag(operation)
    if tag == CORE_PRIMITIVE_NEGATE {
        if operands.len() != 1 {
            panic("CoreHIR: negate arity differs")
        }
        require_core_type_same(
            core_slot_type_for(body, operands.get(0).unwrap()), result_type,
            "CoreHIR: negate input/result type differs")
    } else if tag == CORE_PRIMITIVE_NOT {
        if operands.len() != 1 ||
           type_kind(graph, result_type) !=
                flow_type_kind_tag(flow_type_kind_bool()) ||
           type_kind(graph, core_slot_type_for(
                body, operands.get(0).unwrap())) !=
                flow_type_kind_tag(flow_type_kind_bool()) {
            panic("CoreHIR: not signature differs")
        }
    } else {
        if operands.len() != 2 {
            panic("CoreHIR: binary primitive arity differs")
        }
        let left = core_slot_type_for(body, operands.get(0).unwrap())
        let right = core_slot_type_for(body, operands.get(1).unwrap())
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
    body: CoreBody
) {
    if fields.len() != expected.len() {
        panic("CoreHIR: constructor field census differs from type graph")
    }
    let mut index = 0
    while index < fields.len() {
        let actual = fields.get(index).unwrap()
        let fact = expected.get(index).unwrap()
        if !core_field_matches_flow(
                actual.field, flow_nominal_field_identity(fact)) ||
           core_slot_type_for(body, actual.value).index !=
                flow_type_ref_index(flow_nominal_field_type(fact)) {
            panic("CoreHIR: constructor field identity/type order differs")
        }
        index = index + 1
    }
}

fn validate_construct_with_graph(
    constructor: CoreConstructorRef, fields: List<CoreFieldValue>,
    result_type: CoreTypeRef, body: CoreBody, graph: CoreTypeGraph
) {
    let node = core_type_graph_node(graph, result_type)
    match constructor.value {
        CoreConstructorRefValue::StructConstructorValue(owner) => {
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
            validate_field_sequence(fields, expected, body)
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
                fields, variant_flow_fields(node, variant), body)
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
                if core_slot_type_for(body, field.value).index !=
                   flow_type_ref_index(children.get(index).unwrap()) {
                    panic("CoreHIR: tuple constructor field type differs")
                }
                index = index + 1
            }
        },
        CoreConstructorRefValue::RecordConstructorValue(arity) => {
            if type_kind(graph, result_type) !=
                    flow_type_kind_tag(flow_type_kind_record()) ||
               arity != fields.len() {
                panic("CoreHIR: record constructor/result arity differs")
            }
            validate_field_sequence(
                fields, flow_type_node_nominal_fields(node), body)
        }
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
            core_slot_type_for(body, slot), pattern.ty,
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
                    flow_type_ref_to_core(children.get(index).unwrap()),
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
                if !core_field_matches_flow(
                        field.field, flow_nominal_field_identity(fact)) {
                    panic("CoreHIR: struct pattern field order differs")
                }
                validate_pattern_with_graph(
                    field.pattern,
                    flow_type_ref_to_core(flow_nominal_field_type(fact)),
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
                if !core_field_matches_flow(
                        field.field, flow_nominal_field_identity(fact)) {
                    panic("CoreHIR: variant pattern field order differs")
                }
                validate_pattern_with_graph(
                    field.pattern,
                    flow_type_ref_to_core(flow_nominal_field_type(fact)),
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
            flow_type_ref_to_core(children.get(index).unwrap())
        },
        _ => {
            let mut found: CoreTypeRef? = none
            for fact in flow_type_node_nominal_fields(node) {
                if core_field_matches_flow(
                        field, flow_nominal_field_identity(fact)) {
                    if found.is_some() {
                        panic("CoreHIR: projection field fact is duplicated")
                    }
                    found = some(flow_type_ref_to_core(
                        flow_nominal_field_type(fact)))
                }
            }
            match found {
                some(value) => value,
                none => panic("CoreHIR: projection field is absent from type graph")
            }
        }
    }
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

fn callee_candidates_contain_symbol(
    callee: CoreCalleeRef, symbol: SymbolRef
) -> Bool {
    for candidate in callee.candidates {
        if executable_ref_is_named(candidate) &&
           symbol_ref_same(executable_ref_named_symbol(candidate), symbol) {
            return true
        }
    }
    false
}

fn validate_method_call_identity(
    method: MethodCallRef, callee: CoreCalleeRef,
    evidence: List<CoreEvidenceRef>
) {
    if method_call_ref_is_intrinsic(method) {
        if !callee_candidates_contain_symbol(
                callee, intrinsic_ref_symbol(
                    method_call_ref_intrinsic(method))) {
            panic("CoreHIR: intrinsic MethodCallRef/callee differs")
        }
    } else if method_call_ref_is_concrete(method) {
        if !callee_candidates_contain_symbol(
                callee, impl_method_ref_member(
                    method_call_ref_impl(method))) {
            panic("CoreHIR: concrete MethodCallRef/callee differs")
        }
    } else if method_call_ref_is_bound(method) {
        let _ = trait_method_ref_member(method_call_ref_bound(method))
        if evidence.len() == 0 {
            panic("CoreHIR: bound MethodCallRef has no exact evidence")
        }
    } else {
        panic("CoreHIR: MethodCallRef identity is not closed")
    }
}

fn validate_expr_with_program(
    value: CoreExpr, body: CoreBody, graph: CoreTypeGraph,
    callables: List<CoreCallableContract>,
    current_callable: CoreCallableContract, loop_depth: Int
) {
    validate_expr_with_loop_depth(value, body, loop_depth)
    require_core_type_same(
        core_slot_type_for(body, value.result), value.ty,
        "CoreHIR: expression result slot/type differs")
    let _ = core_type_graph_node(graph, value.ty)
    match value.value {
        CoreExprValue::LiteralExprValue(literal) =>
            validate_core_literal_type(literal, value.ty, graph),
        CoreExprValue::ReadExprValue(source) => require_core_type_same(
            core_slot_type_for(body, source), value.ty,
            "CoreHIR: Read source/result type differs"),
        CoreExprValue::PrimitiveExprValue { operation, operands } =>
            validate_core_primitive_signature(
                operation, operands, value.ty, body, graph),
        CoreExprValue::CallExprValue { callee, arguments, evidence } =>
            validate_call_signature(
                callee, arguments, value.ty, evidence,
                body, graph, callables),
        CoreExprValue::MethodCallExprValue {
            callee, method, receiver, arguments, evidence
        } => {
            validate_method_call_identity(method, callee, evidence)
            let mut all_arguments: List<SlotRef> = [receiver]
            for argument in arguments { all_arguments.push(argument) }
            validate_call_signature(
                callee, all_arguments, value.ty, evidence,
                body, graph, callables)
        },
        CoreExprValue::EffectCallExprValue {
            operation, arguments, evidence
        } => {
            let callable = core_callable_for(
                callables, effect_operation_ref_callable(operation))
            validate_call_signature(
                make_core_direct_callee(
                    callable.reference, callable.semantic_contract),
                arguments, value.ty, evidence, body, graph, callables)
            let handled = effect_operation_ref_effect(operation)
            let mut present = false
            for atom in value.effects.atoms {
                match atom.value {
                    CoreEffectAtomValue::HandledEffectValue(effect_ref) => if
                        handled_effect_ref_same(effect_ref, handled) {
                        present = true
                    },
                    _ => {}
                }
            }
            if !present {
                panic("CoreHIR: handled operation is absent from effect set")
            }
        },
        CoreExprValue::SystemCallExprValue { host, arguments } => {
            let callable = core_callable_for(
                callables, system_host_callable_executable(host))
            if callable.evidence_requirements.len() != 0 {
                panic("CoreHIR: system host call entered evidence domain")
            }
            validate_call_signature(
                make_core_direct_callee(
                    callable.reference, callable.semantic_contract),
                arguments, value.ty, [], body, graph, callables)
            let system = system_host_callable_effect(host)
            let mut present = false
            for atom in value.effects.atoms {
                match atom.value {
                    CoreEffectAtomValue::SystemEffectValue(effect_ref) => if
                        system_effect_ref_same(effect_ref, system) {
                        present = true
                    },
                    _ => {}
                }
            }
            if !present {
                panic("CoreHIR: system call is absent from effect set")
            }
        },
        CoreExprValue::DictConstructExprValue { constructor, evidence } => {
            let callable = core_callable_for(callables, constructor)
            validate_call_signature(
                make_core_direct_callee(
                    callable.reference, callable.semantic_contract),
                [], value.ty, evidence, body, graph, callables)
        },
        CoreExprValue::DictProjectExprValue { dictionary, method } => {
            let callable = core_callable_for(callables, method)
            validate_call_signature(
                make_core_direct_callee(
                    callable.reference, callable.semantic_contract),
                [dictionary], value.ty, [], body, graph, callables)
        },
        CoreExprValue::ProjectExprValue { base, field, .. } =>
            require_core_type_same(
                projection_result_type(
                    field, core_slot_type_for(body, base), graph),
                value.ty, "CoreHIR: projection result type differs"),
        CoreExprValue::ConstructExprValue { constructor, fields } => {
            validate_construct_with_graph(
                constructor, fields, value.ty, body, graph)
            match constructor.executable {
                some(executable) => {
                    let _ = core_callable_for(callables, executable)
                },
                none => if core_constructor_kind_tag(constructor) < 2 {
                    panic("CoreHIR: nominal constructor has no exact executable")
                }
            }
        },
        CoreExprValue::LambdaExprValue { executable, .. } => {
            let contract = core_callable_for(callables, executable)
            if !flow_callable_mode_same(
                    contract.mode, flow_callable_mode_concrete_body()) {
                panic("CoreHIR: lambda references a bodyless callable")
            }
        },
        CoreExprValue::BlockExprValue(block) => {
            validate_block_with_program(
                block, body, graph, callables, current_callable, loop_depth)
            require_block_result_type(block, value.ty, graph)
        },
        CoreExprValue::IfExprValue {
            condition, then_block, else_block
        } => {
            if type_kind(graph, core_slot_type_for(body, condition)) !=
               flow_type_kind_tag(flow_type_kind_bool()) {
                panic("CoreHIR: If condition is not Bool")
            }
            validate_block_with_program(
                then_block, body, graph, callables,
                current_callable, loop_depth)
            validate_block_with_program(
                else_block, body, graph, callables,
                current_callable, loop_depth)
            require_block_result_type(then_block, value.ty, graph)
            require_block_result_type(else_block, value.ty, graph)
        },
        CoreExprValue::MatchExprValue { scrutinee, arms } => {
            let scrutinee_type = core_slot_type_for(body, scrutinee)
            for arm in arms {
                validate_pattern_with_graph(
                    arm.pattern, scrutinee_type, body, graph)
                match arm.guard {
                    some(guard) => {
                        validate_expr_with_program(
                            guard, body, graph, callables,
                            current_callable, loop_depth)
                        if type_kind(graph, guard.ty) !=
                           flow_type_kind_tag(flow_type_kind_bool()) {
                            panic("CoreHIR: match guard is not Bool")
                        }
                    },
                    none => {}
                }
                validate_block_with_program(
                    arm.body, body, graph, callables,
                    current_callable, loop_depth)
                require_block_result_type(arm.body, value.ty, graph)
            }
        },
        CoreExprValue::TryCatchExprValue {
            body: protected, error_slot, arms
        } => {
            validate_block_with_program(
                protected, body, graph, callables,
                current_callable, loop_depth)
            require_block_result_type(protected, value.ty, graph)
            let error_type = core_slot_type_for(body, error_slot)
            for arm in arms {
                validate_pattern_with_graph(
                    arm.pattern, error_type, body, graph)
                validate_block_with_program(
                    arm.body, body, graph, callables,
                    current_callable, loop_depth)
                require_block_result_type(arm.body, value.ty, graph)
            }
        },
        CoreExprValue::HandleExprValue { body: handled, handlers } => {
            validate_block_with_program(
                handled, body, graph, callables,
                current_callable, loop_depth)
            require_block_result_type(handled, value.ty, graph)
            for handler in handlers {
                let operation_callable = effect_operation_ref_callable(
                    handler.operation)
                let handler_contract = core_callable_for(
                    callables, handler.executable)
                let _ = core_callable_for(callables, operation_callable)
                if !flow_callable_mode_same(
                        handler_contract.mode,
                        flow_callable_mode_concrete_body()) {
                    panic("CoreHIR: handler executable is bodyless")
                }
            }
        }
    }
}

fn validate_statement_with_program(
    value: CoreStmt, body: CoreBody, graph: CoreTypeGraph,
    callables: List<CoreCallableContract>,
    current_callable: CoreCallableContract, loop_depth: Int
) {
    validate_statement(value, body, loop_depth)
    match value.value {
        CoreStmtValue::Initialize { target, value: expr, .. } => {
            validate_expr_with_program(
                expr, body, graph, callables, current_callable, loop_depth)
            require_core_type_same(
                core_slot_type_for(body, target), expr.ty,
                "CoreHIR: Initialize target/value type differs")
            if !slot_ref_same(target, expr.result) {
                panic("CoreHIR: Initialize result is not target slot")
            }
        },
        CoreStmtValue::Assign { target, value: expr, .. } => {
            validate_expr_with_program(
                expr, body, graph, callables, current_callable, loop_depth)
            require_core_type_same(
                core_slot_type_for(body, target), expr.ty,
                "CoreHIR: Assign target/value type differs")
        },
        CoreStmtValue::ExprStmt { value: expr, .. } =>
            validate_expr_with_program(
                expr, body, graph, callables, current_callable, loop_depth),
        CoreStmtValue::While { condition, body: loop_body, .. } => {
            validate_expr_with_program(
                condition, body, graph, callables,
                current_callable, loop_depth)
            if type_kind(graph, condition.ty) !=
               flow_type_kind_tag(flow_type_kind_bool()) {
                panic("CoreHIR: While condition is not Bool")
            }
            validate_block_with_program(
                loop_body, body, graph, callables,
                current_callable, loop_depth + 1)
        },
        CoreStmtValue::Return { value: returned, .. } => match returned {
            some(expr) => {
                validate_expr_with_program(
                    expr, body, graph, callables,
                    current_callable, loop_depth)
                require_core_type_same(
                    expr.ty, current_callable.result_type,
                    "CoreHIR: Return type differs from callable")
            },
            none => {
                let kind = type_kind(graph, current_callable.result_type)
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
    current_callable: CoreCallableContract, loop_depth: Int
) {
    for statement in value.statements {
        validate_statement_with_program(
            statement, body, graph, callables,
            current_callable, loop_depth)
    }
    match value.tail {
        some(expr) => validate_expr_with_program(
            expr, body, graph, callables, current_callable, loop_depth),
        none => {}
    }
}

pub fn validate_core_body_with_program(
    value: CoreBody, graph: CoreTypeGraph,
    callables: List<CoreCallableContract>,
    current_callable: CoreCallableContract
) {
    validate_core_body(value)
    if value.type_count != core_type_graph_count(graph) ||
       !executable_ref_same(value.reference, current_callable.reference) ||
       !origin_ref_same(value.origin, current_callable.origin) ||
       !core_type_ref_same(value.result_type, current_callable.result_type) ||
       value.parameter_slots.len() != current_callable.parameter_slots.len() {
        panic("CoreHIR: body/program callable closure differs")
    }
    let mut index = 0
    while index < value.parameter_slots.len() {
        if !slot_ref_same(
                value.parameter_slots.get(index).unwrap(),
                current_callable.parameter_slots.get(index).unwrap()) ||
           !core_type_ref_same(
                core_slot_type_for(
                    value, value.parameter_slots.get(index).unwrap()),
                current_callable.parameter_types.get(index).unwrap()) {
            panic("CoreHIR: body parameter slot/type order differs")
        }
        index = index + 1
    }
    validate_block_with_program(
        value.body, value, graph, callables, current_callable, 0)
}
