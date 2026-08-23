// FlowIR: the first ownership-neutral, fixed-topology compiler IR.
//
// Every public value has a private representation.  Construction accepts only
// exact typed references already selected by CoreHIR.  This module never reads
// HProgram/HExpr, resolves a spelling, generates a semantic executable, inserts
// a resource operation, or chooses an ABI/layout.  `make_flow_program` is the
// single freeze barrier: after it returns, the ordered type/callable/body/slot/
// block topology is immutable and can be consumed mechanically by the resource
// planner.

use ir_identity::{
    SymbolRef, PathRef, PathOwnerRef, SlotRef,
    symbol_ref_same, symbol_ref_origin_module_key,
    symbol_ref_namespace_kind, symbol_ref_canonical_payload,
    symbol_ref_declaration_site_path,
    namespace_kind_tag, namespace_kind_same, namespace_nominal,
    path_ref_same, path_ref_owner, path_ref_normalized_child_path,
    path_ref_role, path_role_tag,
    path_owner_ref_is_symbol, path_owner_ref_symbol,
    path_owner_ref_module_body,
    module_body_ref_origin_module_key,
    module_body_ref_declaration_site_path,
    slot_ref_same, slot_ref_is_source,
    slot_ref_source_origin_module_key, slot_ref_source_domain,
    slot_ref_source_def_id, slot_ref_synthetic_path,
    slot_domain_tag,
    OriginRef, origin_ref_is_symbol, origin_ref_symbol, origin_ref_path,
    origin_ref_same
}
use ir_inventory::{
    ExecutableRef, executable_ref_same, executable_ref_is_named,
    executable_ref_named_symbol, executable_ref_anonymous_path,
    executable_ref_origin_module_key,
    BinderManifest, BinderEntry,
    binder_manifest_owner, binder_manifest_entries,
    binder_entry_slot
}

// ============================================================
// Finite, exact type graph
// ============================================================

const FLOW_TYPE_INT: Int = 0
const FLOW_TYPE_FLOAT: Int = 1
const FLOW_TYPE_STR: Int = 2
const FLOW_TYPE_BOOL: Int = 3
const FLOW_TYPE_UNIT: Int = 4
const FLOW_TYPE_NEVER: Int = 5
const FLOW_TYPE_STRUCT: Int = 6
const FLOW_TYPE_ENUM: Int = 7
const FLOW_TYPE_TUPLE: Int = 8
const FLOW_TYPE_RECORD: Int = 9
const FLOW_TYPE_CALLABLE: Int = 10
const FLOW_TYPE_PTR: Int = 11
const FLOW_TYPE_PARAMETER: Int = 12
const FLOW_TYPE_KIND_COUNT: Int = 13

pub struct FlowTypeRef { index: Int }

pub fn make_flow_type_ref(index: Int) -> FlowTypeRef {
    if index < 0 { panic("FlowIR: negative type reference") }
    FlowTypeRef { index: index }
}

pub fn flow_type_ref_index(value: FlowTypeRef) -> Int { value.index }

pub fn flow_type_ref_same(left: FlowTypeRef, right: FlowTypeRef) -> Bool {
    left.index == right.index
}

pub struct FlowTypeKind { tag: Int }

fn flow_type_kind_from_tag(tag: Int) -> FlowTypeKind {
    if tag < FLOW_TYPE_INT || tag >= FLOW_TYPE_KIND_COUNT {
        panic("FlowIR: unknown type kind crossed CoreHIR boundary")
    }
    FlowTypeKind { tag: tag }
}

pub fn flow_type_kind_tag(value: FlowTypeKind) -> Int {
    flow_type_kind_from_tag(value.tag).tag
}

pub fn flow_type_kind_int() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_INT) }
pub fn flow_type_kind_float() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_FLOAT) }
pub fn flow_type_kind_str() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_STR) }
pub fn flow_type_kind_bool() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_BOOL) }
pub fn flow_type_kind_unit() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_UNIT) }
pub fn flow_type_kind_never() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_NEVER) }
pub fn flow_type_kind_struct() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_STRUCT) }
pub fn flow_type_kind_enum() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_ENUM) }
pub fn flow_type_kind_tuple() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_TUPLE) }
pub fn flow_type_kind_record() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_RECORD) }
pub fn flow_type_kind_callable() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_CALLABLE) }
pub fn flow_type_kind_ptr() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_PTR) }
pub fn flow_type_kind_parameter() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_PARAMETER) }

fn flow_type_kind_same(left: FlowTypeKind, right: FlowTypeKind) -> Bool {
    flow_type_kind_tag(left) == flow_type_kind_tag(right)
}

pub struct FlowTypeNode {
    reference: FlowTypeRef,
    kind: FlowTypeKind,
    nominal: SymbolRef?,
    children: List<FlowTypeRef>,
    parameter_count: Int,
    parameter_index: Int
}

fn copy_type_refs(values: List<FlowTypeRef>) -> List<FlowTypeRef> {
    let mut result: List<FlowTypeRef> = []
    for value in values { result.push(value) }
    result
}

fn make_atomic_flow_type_node(
    reference: FlowTypeRef, kind: FlowTypeKind
) -> FlowTypeNode {
    let tag = flow_type_kind_tag(kind)
    if tag < FLOW_TYPE_INT || tag > FLOW_TYPE_NEVER {
        panic("FlowIR: non-atomic type used atomic constructor")
    }
    FlowTypeNode {
        reference: reference, kind: kind, nominal: none, children: [],
        parameter_count: 0, parameter_index: 0 - 1
    }
}

pub fn make_flow_int_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_int())
}
pub fn make_flow_float_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_float())
}
pub fn make_flow_str_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_str())
}
pub fn make_flow_bool_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_bool())
}
pub fn make_flow_unit_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_unit())
}
pub fn make_flow_never_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_never())
}

fn make_nominal_flow_type_node(
    reference: FlowTypeRef, kind: FlowTypeKind, nominal: SymbolRef,
    arguments: List<FlowTypeRef>
) -> FlowTypeNode {
    if !flow_type_kind_same(kind, flow_type_kind_struct()) &&
       !flow_type_kind_same(kind, flow_type_kind_enum()) {
        panic("FlowIR: invalid nominal type kind")
    }
    if !namespace_kind_same(
            symbol_ref_namespace_kind(nominal), namespace_nominal()) {
        panic("FlowIR: nominal type has non-nominal symbol")
    }
    FlowTypeNode {
        reference: reference, kind: kind, nominal: some(nominal),
        children: copy_type_refs(arguments),
        parameter_count: 0, parameter_index: 0 - 1
    }
}

pub fn make_flow_struct_type_node(
    reference: FlowTypeRef, nominal: SymbolRef,
    arguments: List<FlowTypeRef>
) -> FlowTypeNode {
    make_nominal_flow_type_node(
        reference, flow_type_kind_struct(), nominal, arguments)
}

pub fn make_flow_enum_type_node(
    reference: FlowTypeRef, nominal: SymbolRef,
    arguments: List<FlowTypeRef>
) -> FlowTypeNode {
    make_nominal_flow_type_node(
        reference, flow_type_kind_enum(), nominal, arguments)
}

fn make_structural_flow_type_node(
    reference: FlowTypeRef, kind: FlowTypeKind,
    children: List<FlowTypeRef>
) -> FlowTypeNode {
    if !flow_type_kind_same(kind, flow_type_kind_tuple()) &&
       !flow_type_kind_same(kind, flow_type_kind_record()) {
        panic("FlowIR: invalid structural type kind")
    }
    FlowTypeNode {
        reference: reference, kind: kind, nominal: none,
        children: copy_type_refs(children),
        parameter_count: 0, parameter_index: 0 - 1
    }
}

pub fn make_flow_tuple_type_node(
    reference: FlowTypeRef, elements: List<FlowTypeRef>
) -> FlowTypeNode {
    make_structural_flow_type_node(reference, flow_type_kind_tuple(), elements)
}

pub fn make_flow_record_type_node(
    reference: FlowTypeRef, fields: List<FlowTypeRef>
) -> FlowTypeNode {
    make_structural_flow_type_node(reference, flow_type_kind_record(), fields)
}

pub fn make_flow_callable_type_node(
    reference: FlowTypeRef, parameters: List<FlowTypeRef>,
    result: FlowTypeRef
) -> FlowTypeNode {
    let mut children = copy_type_refs(parameters)
    children.push(result)
    FlowTypeNode {
        reference: reference, kind: flow_type_kind_callable(), nominal: none,
        children: children, parameter_count: parameters.len(),
        parameter_index: 0 - 1
    }
}

pub fn make_flow_ptr_type_node(
    reference: FlowTypeRef, pointee: FlowTypeRef
) -> FlowTypeNode {
    FlowTypeNode {
        reference: reference, kind: flow_type_kind_ptr(), nominal: none,
        children: [pointee], parameter_count: 0, parameter_index: 0 - 1
    }
}

pub fn make_flow_parameter_type_node(
    reference: FlowTypeRef, parameter_index: Int
) -> FlowTypeNode {
    if parameter_index < 0 { panic("FlowIR: negative type parameter index") }
    FlowTypeNode {
        reference: reference, kind: flow_type_kind_parameter(), nominal: none,
        children: [], parameter_count: 0, parameter_index: parameter_index
    }
}

pub fn flow_type_node_reference(value: FlowTypeNode) -> FlowTypeRef { value.reference }
pub fn flow_type_node_kind(value: FlowTypeNode) -> FlowTypeKind { value.kind }
pub fn flow_type_node_children(value: FlowTypeNode) -> List<FlowTypeRef> {
    copy_type_refs(value.children)
}
pub fn flow_type_node_nominal(value: FlowTypeNode) -> SymbolRef {
    match value.nominal {
        some(symbol) => symbol,
        none => panic("FlowIR: non-nominal type has no nominal symbol")
    }
}
pub fn flow_type_node_parameter_count(value: FlowTypeNode) -> Int {
    if !flow_type_kind_same(value.kind, flow_type_kind_callable()) {
        panic("FlowIR: non-callable type has no parameter count")
    }
    value.parameter_count
}
pub fn flow_type_node_parameter_index(value: FlowTypeNode) -> Int {
    if !flow_type_kind_same(value.kind, flow_type_kind_parameter()) {
        panic("FlowIR: non-parameter type has no parameter index")
    }
    value.parameter_index
}

fn copy_type_nodes(values: List<FlowTypeNode>) -> List<FlowTypeNode> {
    let mut result: List<FlowTypeNode> = []
    for value in values {
        result.push(FlowTypeNode {
            reference: value.reference, kind: value.kind,
            nominal: value.nominal, children: copy_type_refs(value.children),
            parameter_count: value.parameter_count,
            parameter_index: value.parameter_index
        })
    }
    result
}

fn validate_type_nodes(values: List<FlowTypeNode>) {
    let mut ordinal = 0
    for value in values {
        if value.reference.index != ordinal {
            panic("FlowIR: type nodes are not in stable ordinal order")
        }
        let tag = flow_type_kind_tag(value.kind)
        for child in value.children {
            if child.index < 0 || child.index >= values.len() {
                panic("FlowIR: type node has an unresolved child")
            }
        }
        if tag >= FLOW_TYPE_INT && tag <= FLOW_TYPE_NEVER {
            if value.nominal.is_some() || value.children.len() != 0 ||
               value.parameter_count != 0 || value.parameter_index != 0 - 1 {
                panic("FlowIR: atomic type payload is invalid")
            }
        } else if tag == FLOW_TYPE_STRUCT || tag == FLOW_TYPE_ENUM {
            if value.nominal.is_none() || value.parameter_count != 0 ||
               value.parameter_index != 0 - 1 {
                panic("FlowIR: nominal type payload is invalid")
            }
        } else if tag == FLOW_TYPE_TUPLE || tag == FLOW_TYPE_RECORD {
            if value.nominal.is_some() || value.parameter_count != 0 ||
               value.parameter_index != 0 - 1 {
                panic("FlowIR: structural type payload is invalid")
            }
        } else if tag == FLOW_TYPE_CALLABLE {
            if value.nominal.is_some() || value.parameter_count < 0 ||
               value.children.len() != value.parameter_count + 1 ||
               value.parameter_index != 0 - 1 {
                panic("FlowIR: callable type payload is invalid")
            }
        } else if tag == FLOW_TYPE_PTR {
            if value.nominal.is_some() || value.children.len() != 1 ||
               value.parameter_count != 0 || value.parameter_index != 0 - 1 {
                panic("FlowIR: Ptr type payload is invalid")
            }
        } else if tag == FLOW_TYPE_PARAMETER {
            if value.nominal.is_some() || value.children.len() != 0 ||
               value.parameter_count != 0 || value.parameter_index < 0 {
                panic("FlowIR: type parameter payload is invalid")
            }
        } else {
            panic("FlowIR: unknown type kind crossed freeze")
        }
        ordinal = ordinal + 1
    }
}

// ============================================================
// Callable contract (semantic lower bounds only)
// ============================================================

const FLOW_ROLE_READ: Int = 0
const FLOW_ROLE_MUTATE: Int = 1
const FLOW_ROLE_CONSUME: Int = 2
const FLOW_ROLE_FORCE: Int = 3

pub struct FlowSemanticRole { tag: Int }

fn flow_semantic_role_from_tag(tag: Int) -> FlowSemanticRole {
    if tag < FLOW_ROLE_READ || tag > FLOW_ROLE_FORCE {
        panic("FlowIR: invalid semantic role")
    }
    FlowSemanticRole { tag: tag }
}

pub fn flow_semantic_role_read() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_READ)
}
pub fn flow_semantic_role_mutate() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_MUTATE)
}
pub fn flow_semantic_role_consume() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_CONSUME)
}
pub fn flow_semantic_role_force() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_FORCE)
}
pub fn flow_semantic_role_tag(value: FlowSemanticRole) -> Int {
    flow_semantic_role_from_tag(value.tag).tag
}

const FLOW_CALLABLE_CONCRETE_BODY: Int = 0
const FLOW_CALLABLE_CONTRACT_ONLY: Int = 1

pub struct FlowCallableMode { tag: Int }

fn flow_callable_mode_from_tag(tag: Int) -> FlowCallableMode {
    if tag < FLOW_CALLABLE_CONCRETE_BODY ||
       tag > FLOW_CALLABLE_CONTRACT_ONLY {
        panic("FlowIR: invalid callable mode")
    }
    FlowCallableMode { tag: tag }
}

pub fn flow_callable_mode_concrete_body() -> FlowCallableMode {
    flow_callable_mode_from_tag(FLOW_CALLABLE_CONCRETE_BODY)
}
pub fn flow_callable_mode_contract_only() -> FlowCallableMode {
    flow_callable_mode_from_tag(FLOW_CALLABLE_CONTRACT_ONLY)
}
pub fn flow_callable_mode_same(
    left: FlowCallableMode, right: FlowCallableMode
) -> Bool { left.tag == right.tag }

pub struct FlowCallable {
    reference: ExecutableRef,
    origin: OriginRef,
    parameter_types: List<FlowTypeRef>,
    result_type: FlowTypeRef,
    mode: FlowCallableMode,
    parameter_role_lower_bounds: List<FlowSemanticRole>,
    call_edges: List<FlowCallEdge>
}

pub fn make_flow_callable(
    reference: ExecutableRef, origin: OriginRef,
    parameter_types: List<FlowTypeRef>, result_type: FlowTypeRef,
    mode: FlowCallableMode,
    parameter_role_lower_bounds: List<FlowSemanticRole>
) -> FlowCallable {
    if parameter_types.len() != parameter_role_lower_bounds.len() {
        panic("FlowIR: callable parameter/role arity differs")
    }
    for role in parameter_role_lower_bounds {
        let _ = flow_semantic_role_tag(role)
    }
    FlowCallable {
        reference: reference, origin: origin,
        parameter_types: copy_type_refs(parameter_types),
        result_type: result_type,
        mode: flow_callable_mode_from_tag(mode.tag),
        parameter_role_lower_bounds: parameter_role_lower_bounds,
        call_edges: []
    }
}

pub fn flow_callable_reference(value: FlowCallable) -> ExecutableRef { value.reference }
pub fn flow_callable_origin(value: FlowCallable) -> OriginRef { value.origin }
pub fn flow_callable_parameter_types(value: FlowCallable) -> List<FlowTypeRef> {
    copy_type_refs(value.parameter_types)
}
pub fn flow_callable_result_type(value: FlowCallable) -> FlowTypeRef {
    value.result_type
}
pub fn flow_callable_mode(value: FlowCallable) -> FlowCallableMode { value.mode }
pub fn flow_callable_parameter_role_lower_bounds(
    value: FlowCallable
) -> List<FlowSemanticRole> {
    let mut result: List<FlowSemanticRole> = []
    for role in value.parameter_role_lower_bounds { result.push(role) }
    result
}

// ============================================================
// Body-local frozen identities, scopes, and slots
// ============================================================

pub struct FlowScopeRef {
    owner: ExecutableRef,
    ordinal: Int
}

pub fn make_flow_scope_ref(
    owner: ExecutableRef, ordinal: Int
) -> FlowScopeRef {
    if ordinal < 0 { panic("FlowIR: negative scope ordinal") }
    FlowScopeRef { owner: owner, ordinal: ordinal }
}

pub fn flow_scope_ref_owner(value: FlowScopeRef) -> ExecutableRef { value.owner }
pub fn flow_scope_ref_ordinal(value: FlowScopeRef) -> Int { value.ordinal }
pub fn flow_scope_ref_same(left: FlowScopeRef, right: FlowScopeRef) -> Bool {
    executable_ref_same(left.owner, right.owner) && left.ordinal == right.ordinal
}

pub struct FlowScope {
    reference: FlowScopeRef,
    parent: FlowScopeRef?
}

pub fn make_flow_root_scope(reference: FlowScopeRef) -> FlowScope {
    if reference.ordinal != 0 {
        panic("FlowIR: root scope does not have ordinal zero")
    }
    FlowScope { reference: reference, parent: none }
}

pub fn make_flow_child_scope(
    reference: FlowScopeRef, parent: FlowScopeRef
) -> FlowScope {
    if !executable_ref_same(reference.owner, parent.owner) ||
       reference.ordinal <= parent.ordinal {
        panic("FlowIR: child scope owner/order is invalid")
    }
    FlowScope { reference: reference, parent: some(parent) }
}

pub fn flow_scope_reference(value: FlowScope) -> FlowScopeRef { value.reference }
pub fn flow_scope_has_parent(value: FlowScope) -> Bool { value.parent.is_some() }
pub fn flow_scope_parent(value: FlowScope) -> FlowScopeRef {
    match value.parent {
        some(parent) => parent,
        none => panic("FlowIR: root scope has no parent")
    }
}

fn copy_scopes(values: List<FlowScope>) -> List<FlowScope> {
    let mut result: List<FlowScope> = []
    for value in values {
        result.push(FlowScope {
            reference: value.reference, parent: value.parent
        })
    }
    result
}

const FLOW_SLOT_EMPTY: Int = 0
const FLOW_SLOT_LIVE: Int = 1

pub struct FlowInitialSlotState { tag: Int }

fn flow_initial_slot_state_from_tag(tag: Int) -> FlowInitialSlotState {
    if tag < FLOW_SLOT_EMPTY || tag > FLOW_SLOT_LIVE {
        panic("FlowIR: invalid initial slot state")
    }
    FlowInitialSlotState { tag: tag }
}

pub fn flow_initial_slot_empty() -> FlowInitialSlotState {
    flow_initial_slot_state_from_tag(FLOW_SLOT_EMPTY)
}
pub fn flow_initial_slot_live() -> FlowInitialSlotState {
    flow_initial_slot_state_from_tag(FLOW_SLOT_LIVE)
}
pub fn flow_initial_slot_state_tag(value: FlowInitialSlotState) -> Int {
    flow_initial_slot_state_from_tag(value.tag).tag
}

const FLOW_STORAGE_PARAMETER: Int = 0
const FLOW_STORAGE_LOCAL: Int = 1
const FLOW_STORAGE_TEMP: Int = 2
const FLOW_STORAGE_RESULT: Int = 3
const FLOW_STORAGE_CAPTURE: Int = 4

pub struct FlowStorageClass { tag: Int }

fn flow_storage_class_from_tag(tag: Int) -> FlowStorageClass {
    if tag < FLOW_STORAGE_PARAMETER || tag > FLOW_STORAGE_CAPTURE {
        panic("FlowIR: invalid storage class")
    }
    FlowStorageClass { tag: tag }
}

pub fn flow_storage_parameter() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_PARAMETER)
}
pub fn flow_storage_local() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_LOCAL)
}
pub fn flow_storage_temp() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_TEMP)
}
pub fn flow_storage_result() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_RESULT)
}
pub fn flow_storage_capture() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_CAPTURE)
}
pub fn flow_storage_class_tag(value: FlowStorageClass) -> Int {
    flow_storage_class_from_tag(value.tag).tag
}
pub fn flow_storage_class_same(
    left: FlowStorageClass, right: FlowStorageClass
) -> Bool { left.tag == right.tag }

pub struct FlowSlot {
    reference: SlotRef,
    ty: FlowTypeRef,
    scope: FlowScopeRef,
    reverse_ordinal: Int,
    initial_state: FlowInitialSlotState,
    storage: FlowStorageClass
}

pub fn make_flow_slot(
    reference: SlotRef, ty: FlowTypeRef, scope: FlowScopeRef,
    reverse_ordinal: Int, initial_state: FlowInitialSlotState,
    storage: FlowStorageClass
) -> FlowSlot {
    if reverse_ordinal < 0 {
        panic("FlowIR: negative reverse lexical slot ordinal")
    }
    FlowSlot {
        reference: reference, ty: ty, scope: scope,
        reverse_ordinal: reverse_ordinal,
        initial_state: flow_initial_slot_state_from_tag(initial_state.tag),
        storage: flow_storage_class_from_tag(storage.tag)
    }
}

pub fn flow_slot_reference(value: FlowSlot) -> SlotRef { value.reference }
pub fn flow_slot_type(value: FlowSlot) -> FlowTypeRef { value.ty }
pub fn flow_slot_scope(value: FlowSlot) -> FlowScopeRef { value.scope }
pub fn flow_slot_reverse_ordinal(value: FlowSlot) -> Int { value.reverse_ordinal }
pub fn flow_slot_initial_state(value: FlowSlot) -> FlowInitialSlotState {
    value.initial_state
}
pub fn flow_slot_storage(value: FlowSlot) -> FlowStorageClass { value.storage }

fn copy_flow_slots(values: List<FlowSlot>) -> List<FlowSlot> {
    let mut result: List<FlowSlot> = []
    for value in values {
        result.push(FlowSlot {
            reference: value.reference, ty: value.ty, scope: value.scope,
            reverse_ordinal: value.reverse_ordinal,
            initial_state: value.initial_state, storage: value.storage
        })
    }
    result
}

pub struct FlowBlockRef {
    owner: ExecutableRef,
    ordinal: Int
}

pub fn make_flow_block_ref(
    owner: ExecutableRef, ordinal: Int
) -> FlowBlockRef {
    if ordinal < 0 { panic("FlowIR: negative block ordinal") }
    FlowBlockRef { owner: owner, ordinal: ordinal }
}

pub fn flow_block_ref_owner(value: FlowBlockRef) -> ExecutableRef { value.owner }
pub fn flow_block_ref_ordinal(value: FlowBlockRef) -> Int { value.ordinal }
pub fn flow_block_ref_same(left: FlowBlockRef, right: FlowBlockRef) -> Bool {
    executable_ref_same(left.owner, right.owner) && left.ordinal == right.ordinal
}

pub struct FlowInstructionRef {
    owner: ExecutableRef,
    block_ordinal: Int,
    instruction_ordinal: Int
}

pub fn make_flow_instruction_ref(
    owner: ExecutableRef, block_ordinal: Int, instruction_ordinal: Int
) -> FlowInstructionRef {
    if block_ordinal < 0 || instruction_ordinal < 0 {
        panic("FlowIR: negative instruction site ordinal")
    }
    FlowInstructionRef {
        owner: owner, block_ordinal: block_ordinal,
        instruction_ordinal: instruction_ordinal
    }
}

pub fn flow_instruction_ref_owner(value: FlowInstructionRef) -> ExecutableRef {
    value.owner
}
pub fn flow_instruction_ref_block_ordinal(value: FlowInstructionRef) -> Int {
    value.block_ordinal
}
pub fn flow_instruction_ref_ordinal(value: FlowInstructionRef) -> Int {
    value.instruction_ordinal
}
pub fn flow_instruction_ref_same(
    left: FlowInstructionRef, right: FlowInstructionRef
) -> Bool {
    executable_ref_same(left.owner, right.owner) &&
        left.block_ordinal == right.block_ordinal &&
        left.instruction_ordinal == right.instruction_ordinal
}

// ============================================================
// Exact call target and ownership-neutral instructions
// ============================================================

enum FlowCallTargetValue {
    DirectTargetValue(ExecutableRef),
    LocalTargetValue(SlotRef),
    DynamicTargetValue(PathRef)
}

pub struct FlowCallTarget { value: FlowCallTargetValue }

pub fn make_direct_flow_call_target(
    target: ExecutableRef
) -> FlowCallTarget {
    FlowCallTarget { value: FlowCallTargetValue::DirectTargetValue(target) }
}

pub fn make_local_flow_call_target(target: SlotRef) -> FlowCallTarget {
    FlowCallTarget { value: FlowCallTargetValue::LocalTargetValue(target) }
}

pub fn make_dynamic_flow_call_target(target: PathRef) -> FlowCallTarget {
    FlowCallTarget { value: FlowCallTargetValue::DynamicTargetValue(target) }
}

pub fn flow_call_target_is_direct(value: FlowCallTarget) -> Bool {
    match value.value {
        FlowCallTargetValue::DirectTargetValue(_) => true,
        _ => false
    }
}
pub fn flow_call_target_is_local(value: FlowCallTarget) -> Bool {
    match value.value {
        FlowCallTargetValue::LocalTargetValue(_) => true,
        _ => false
    }
}
pub fn flow_call_target_direct(value: FlowCallTarget) -> ExecutableRef {
    match value.value {
        FlowCallTargetValue::DirectTargetValue(target) => target,
        _ => panic("FlowIR: non-direct call target has no ExecutableRef")
    }
}
pub fn flow_call_target_local(value: FlowCallTarget) -> SlotRef {
    match value.value {
        FlowCallTargetValue::LocalTargetValue(target) => target,
        _ => panic("FlowIR: non-local call target has no SlotRef")
    }
}
pub fn flow_call_target_dynamic(value: FlowCallTarget) -> PathRef {
    match value.value {
        FlowCallTargetValue::DynamicTargetValue(target) => target,
        _ => panic("FlowIR: non-dynamic call target has no PathRef")
    }
}

fn flow_call_target_same(
    left: FlowCallTarget, right: FlowCallTarget
) -> Bool {
    match (left.value, right.value) {
        (FlowCallTargetValue::DirectTargetValue(a),
         FlowCallTargetValue::DirectTargetValue(b)) => executable_ref_same(a, b),
        (FlowCallTargetValue::LocalTargetValue(a),
         FlowCallTargetValue::LocalTargetValue(b)) => slot_ref_same(a, b),
        (FlowCallTargetValue::DynamicTargetValue(a),
         FlowCallTargetValue::DynamicTargetValue(b)) => path_ref_same(a, b),
        _ => false
    }
}

enum FlowInstructionValue {
    InitializeValue {
        operation: PathRef, inputs: List<SlotRef>, target: SlotRef
    },
    ReadValue { source: SlotRef, target: SlotRef },
    MutateValue { target: SlotRef, value: SlotRef },
    ConsumeValue { source: SlotRef },
    DiscardValue { source: SlotRef },
    AssignValue { rhs_temp: SlotRef, target: SlotRef },
    CallValue {
        target: FlowCallTarget, arguments: List<SlotRef>, result: SlotRef?
    },
    ProjectValue {
        projection: PathRef, base: SlotRef, result: SlotRef, partial: Bool
    },
    CaptureValue {
        capture: PathRef, source: SlotRef, target: SlotRef
    },
    ScopeEnterValue { scope: FlowScopeRef },
    ScopeExitValue { scope: FlowScopeRef }
}

pub struct FlowInstruction {
    reference: FlowInstructionRef,
    origin: OriginRef,
    value: FlowInstructionValue
}

fn copy_slot_refs(values: List<SlotRef>) -> List<SlotRef> {
    let mut result: List<SlotRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_flow_initialize(
    reference: FlowInstructionRef, origin: OriginRef,
    operation: PathRef, inputs: List<SlotRef>, target: SlotRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::InitializeValue {
            operation: operation, inputs: copy_slot_refs(inputs), target: target
        }
    }
}

pub fn make_flow_read(
    reference: FlowInstructionRef, origin: OriginRef,
    source: SlotRef, target: SlotRef
) -> FlowInstruction {
    if slot_ref_same(source, target) {
        panic("FlowIR: Read source and target are identical")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ReadValue {
            source: source, target: target
        }
    }
}

pub fn make_flow_mutate(
    reference: FlowInstructionRef, origin: OriginRef,
    target: SlotRef, value: SlotRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::MutateValue {
            target: target, value: value
        }
    }
}

pub fn make_flow_consume(
    reference: FlowInstructionRef, origin: OriginRef, source: SlotRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ConsumeValue { source: source }
    }
}

pub fn make_flow_discard(
    reference: FlowInstructionRef, origin: OriginRef, source: SlotRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::DiscardValue { source: source }
    }
}

pub fn make_flow_assign(
    reference: FlowInstructionRef, origin: OriginRef,
    rhs_temp: SlotRef, target: SlotRef
) -> FlowInstruction {
    if slot_ref_same(rhs_temp, target) {
        panic("FlowIR: Assign RHS temp aliases target")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::AssignValue {
            rhs_temp: rhs_temp, target: target
        }
    }
}

pub fn make_flow_call(
    reference: FlowInstructionRef, origin: OriginRef,
    target: FlowCallTarget, arguments: List<SlotRef>, result: SlotRef?
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::CallValue {
            target: target, arguments: copy_slot_refs(arguments), result: result
        }
    }
}

pub fn make_flow_project(
    reference: FlowInstructionRef, origin: OriginRef,
    projection: PathRef, base: SlotRef, result: SlotRef, partial: Bool
) -> FlowInstruction {
    if slot_ref_same(base, result) {
        panic("FlowIR: projection aliases its base slot")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ProjectValue {
            projection: projection, base: base, result: result,
            partial: partial
        }
    }
}

pub fn make_flow_capture(
    reference: FlowInstructionRef, origin: OriginRef,
    capture: PathRef, source: SlotRef, target: SlotRef
) -> FlowInstruction {
    if slot_ref_same(source, target) {
        panic("FlowIR: capture source aliases target")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::CaptureValue {
            capture: capture, source: source, target: target
        }
    }
}

pub fn make_flow_scope_enter(
    reference: FlowInstructionRef, origin: OriginRef, scope: FlowScopeRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ScopeEnterValue { scope: scope }
    }
}

pub fn make_flow_scope_exit(
    reference: FlowInstructionRef, origin: OriginRef, scope: FlowScopeRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ScopeExitValue { scope: scope }
    }
}

pub fn flow_instruction_reference(
    value: FlowInstruction
) -> FlowInstructionRef { value.reference }
pub fn flow_instruction_origin(value: FlowInstruction) -> OriginRef { value.origin }

pub fn flow_instruction_kind_tag(value: FlowInstruction) -> Int {
    match value.value {
        FlowInstructionValue::InitializeValue { .. } => 0,
        FlowInstructionValue::ReadValue { .. } => 1,
        FlowInstructionValue::MutateValue { .. } => 2,
        FlowInstructionValue::ConsumeValue { .. } => 3,
        FlowInstructionValue::DiscardValue { .. } => 4,
        FlowInstructionValue::AssignValue { .. } => 5,
        FlowInstructionValue::CallValue { .. } => 6,
        FlowInstructionValue::ProjectValue { .. } => 7,
        FlowInstructionValue::CaptureValue { .. } => 8,
        FlowInstructionValue::ScopeEnterValue { .. } => 9,
        FlowInstructionValue::ScopeExitValue { .. } => 10
    }
}

pub fn flow_initialize_operation(value: FlowInstruction) -> PathRef {
    match value.value {
        FlowInstructionValue::InitializeValue { operation, .. } => operation,
        _ => panic("FlowIR: instruction is not Initialize")
    }
}
pub fn flow_initialize_inputs(value: FlowInstruction) -> List<SlotRef> {
    match value.value {
        FlowInstructionValue::InitializeValue { inputs, .. } =>
            copy_slot_refs(inputs),
        _ => panic("FlowIR: instruction is not Initialize")
    }
}
pub fn flow_initialize_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::InitializeValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Initialize")
    }
}
pub fn flow_read_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ReadValue { source, .. } => source,
        _ => panic("FlowIR: instruction is not Read")
    }
}
pub fn flow_read_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ReadValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Read")
    }
}
pub fn flow_mutate_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::MutateValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Mutate")
    }
}
pub fn flow_mutate_value(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::MutateValue { value: input, .. } => input,
        _ => panic("FlowIR: instruction is not Mutate")
    }
}
pub fn flow_consume_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ConsumeValue { source } => source,
        _ => panic("FlowIR: instruction is not Consume")
    }
}
pub fn flow_discard_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::DiscardValue { source } => source,
        _ => panic("FlowIR: instruction is not Discard")
    }
}
pub fn flow_assign_rhs_temp(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::AssignValue { rhs_temp, .. } => rhs_temp,
        _ => panic("FlowIR: instruction is not Assign")
    }
}
pub fn flow_assign_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::AssignValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Assign")
    }
}
pub fn flow_call_target(value: FlowInstruction) -> FlowCallTarget {
    match value.value {
        FlowInstructionValue::CallValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Call")
    }
}
pub fn flow_call_arguments(value: FlowInstruction) -> List<SlotRef> {
    match value.value {
        FlowInstructionValue::CallValue { arguments, .. } =>
            copy_slot_refs(arguments),
        _ => panic("FlowIR: instruction is not Call")
    }
}
pub fn flow_call_result(value: FlowInstruction) -> SlotRef? {
    match value.value {
        FlowInstructionValue::CallValue { result, .. } => result,
        _ => panic("FlowIR: instruction is not Call")
    }
}
pub fn flow_project_projection(value: FlowInstruction) -> PathRef {
    match value.value {
        FlowInstructionValue::ProjectValue { projection, .. } => projection,
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_project_base(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ProjectValue { base, .. } => base,
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_project_result(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ProjectValue { result, .. } => result,
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_project_is_partial(value: FlowInstruction) -> Bool {
    match value.value {
        FlowInstructionValue::ProjectValue { partial, .. } => partial,
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_capture_path(value: FlowInstruction) -> PathRef {
    match value.value {
        FlowInstructionValue::CaptureValue { capture, .. } => capture,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_capture_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::CaptureValue { source, .. } => source,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_capture_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::CaptureValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_scope_instruction_scope(value: FlowInstruction) -> FlowScopeRef {
    match value.value {
        FlowInstructionValue::ScopeEnterValue { scope } |
        FlowInstructionValue::ScopeExitValue { scope } => scope,
        _ => panic("FlowIR: instruction is not a scope operation")
    }
}

// ============================================================
// Fixed control topology
// ============================================================

pub struct FlowSuccessor {
    target: FlowBlockRef,
    exited_scopes: List<FlowScopeRef>
}

fn copy_scope_refs(values: List<FlowScopeRef>) -> List<FlowScopeRef> {
    let mut result: List<FlowScopeRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_flow_successor(
    target: FlowBlockRef, exited_scopes: List<FlowScopeRef>
) -> FlowSuccessor {
    let mut left_index = 0
    while left_index < exited_scopes.len() {
        let left = exited_scopes.get(left_index).unwrap()
        if !executable_ref_same(left.owner, target.owner) {
            panic("FlowIR: successor exits a cross-body scope")
        }
        let mut right_index = left_index + 1
        while right_index < exited_scopes.len() {
            if flow_scope_ref_same(
                    left, exited_scopes.get(right_index).unwrap()) {
                panic("FlowIR: successor repeats an exited scope")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    FlowSuccessor {
        target: target, exited_scopes: copy_scope_refs(exited_scopes)
    }
}

pub fn flow_successor_target(value: FlowSuccessor) -> FlowBlockRef {
    value.target
}
pub fn flow_successor_exited_scopes(
    value: FlowSuccessor
) -> List<FlowScopeRef> { copy_scope_refs(value.exited_scopes) }

enum FlowTerminatorValue {
    GotoValue(FlowSuccessor),
    BranchValue {
        condition: SlotRef,
        when_true: FlowSuccessor,
        when_false: FlowSuccessor
    },
    LoopValue {
        condition: SlotRef,
        body: FlowSuccessor,
        exit: FlowSuccessor
    },
    ReturnValue { value: SlotRef?, exited_scopes: List<FlowScopeRef> },
    BreakValue(FlowSuccessor),
    ContinueValue(FlowSuccessor),
    CatchValue {
        error: SlotRef,
        handled: FlowSuccessor,
        propagate: FlowSuccessor
    },
    HandlerValue {
        operation: SlotRef,
        handled: FlowSuccessor,
        unhandled: FlowSuccessor
    },
    UnreachableValue { exited_scopes: List<FlowScopeRef> },
    DivergeValue { exited_scopes: List<FlowScopeRef> }
}

pub struct FlowTerminator {
    origin: OriginRef,
    value: FlowTerminatorValue
}

pub fn make_flow_goto(
    origin: OriginRef, successor: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::GotoValue(successor)
    }
}

pub fn make_flow_branch(
    origin: OriginRef, condition: SlotRef,
    when_true: FlowSuccessor, when_false: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::BranchValue {
            condition: condition, when_true: when_true, when_false: when_false
        }
    }
}

pub fn make_flow_loop(
    origin: OriginRef, condition: SlotRef,
    body: FlowSuccessor, exit: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::LoopValue {
            condition: condition, body: body, exit: exit
        }
    }
}

pub fn make_flow_return(
    origin: OriginRef, value: SlotRef?, exited_scopes: List<FlowScopeRef>
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::ReturnValue {
            value: value, exited_scopes: copy_scope_refs(exited_scopes)
        }
    }
}

pub fn make_flow_break(
    origin: OriginRef, successor: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::BreakValue(successor)
    }
}

pub fn make_flow_continue(
    origin: OriginRef, successor: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::ContinueValue(successor)
    }
}

pub fn make_flow_catch(
    origin: OriginRef, error: SlotRef,
    handled: FlowSuccessor, propagate: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::CatchValue {
            error: error, handled: handled, propagate: propagate
        }
    }
}

pub fn make_flow_handler(
    origin: OriginRef, operation: SlotRef,
    handled: FlowSuccessor, unhandled: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::HandlerValue {
            operation: operation, handled: handled, unhandled: unhandled
        }
    }
}

pub fn make_flow_unreachable(
    origin: OriginRef, exited_scopes: List<FlowScopeRef>
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::UnreachableValue {
            exited_scopes: copy_scope_refs(exited_scopes)
        }
    }
}

pub fn make_flow_diverge(
    origin: OriginRef, exited_scopes: List<FlowScopeRef>
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::DivergeValue {
            exited_scopes: copy_scope_refs(exited_scopes)
        }
    }
}

pub fn flow_terminator_origin(value: FlowTerminator) -> OriginRef {
    value.origin
}

pub fn flow_terminator_kind_tag(value: FlowTerminator) -> Int {
    match value.value {
        FlowTerminatorValue::GotoValue(_) => 0,
        FlowTerminatorValue::BranchValue { .. } => 1,
        FlowTerminatorValue::LoopValue { .. } => 2,
        FlowTerminatorValue::ReturnValue { .. } => 3,
        FlowTerminatorValue::BreakValue(_) => 4,
        FlowTerminatorValue::ContinueValue(_) => 5,
        FlowTerminatorValue::CatchValue { .. } => 6,
        FlowTerminatorValue::HandlerValue { .. } => 7,
        FlowTerminatorValue::UnreachableValue { .. } => 8,
        FlowTerminatorValue::DivergeValue { .. } => 9
    }
}

fn terminator_successors(value: FlowTerminator) -> List<FlowSuccessor> {
    match value.value {
        FlowTerminatorValue::GotoValue(edge) => [edge],
        FlowTerminatorValue::BranchValue { when_true, when_false, .. } =>
            [when_true, when_false],
        FlowTerminatorValue::LoopValue { body, exit, .. } => [body, exit],
        FlowTerminatorValue::BreakValue(edge) => [edge],
        FlowTerminatorValue::ContinueValue(edge) => [edge],
        FlowTerminatorValue::CatchValue { handled, propagate, .. } =>
            [handled, propagate],
        FlowTerminatorValue::HandlerValue { handled, unhandled, .. } =>
            [handled, unhandled],
        FlowTerminatorValue::ReturnValue { .. } |
        FlowTerminatorValue::UnreachableValue { .. } |
        FlowTerminatorValue::DivergeValue { .. } => []
    }
}

pub fn flow_terminator_successors(
    value: FlowTerminator
) -> List<FlowSuccessor> {
    let mut result: List<FlowSuccessor> = []
    for edge in terminator_successors(value) {
        result.push(FlowSuccessor {
            target: edge.target,
            exited_scopes: copy_scope_refs(edge.exited_scopes)
        })
    }
    result
}

pub fn flow_terminator_read_slots(value: FlowTerminator) -> List<SlotRef> {
    match value.value {
        FlowTerminatorValue::BranchValue { condition, .. } |
        FlowTerminatorValue::LoopValue { condition, .. } => [condition],
        FlowTerminatorValue::ReturnValue { value: returned, .. } =>
            match returned { some(slot) => [slot], none => [] },
        FlowTerminatorValue::CatchValue { error, .. } => [error],
        FlowTerminatorValue::HandlerValue { operation, .. } => [operation],
        _ => []
    }
}

pub fn flow_terminator_terminal_exited_scopes(
    value: FlowTerminator
) -> List<FlowScopeRef> {
    match terminator_terminal_exited_scopes(value) {
        some(scopes) => scopes,
        none => panic("FlowIR: non-terminal terminator has no terminal exits")
    }
}

fn terminator_terminal_exited_scopes(
    value: FlowTerminator
) -> List<FlowScopeRef>? {
    match value.value {
        FlowTerminatorValue::ReturnValue { exited_scopes, .. } =>
            some(copy_scope_refs(exited_scopes)),
        FlowTerminatorValue::UnreachableValue { exited_scopes } =>
            some(copy_scope_refs(exited_scopes)),
        FlowTerminatorValue::DivergeValue { exited_scopes } =>
            some(copy_scope_refs(exited_scopes)),
        _ => none
    }
}

pub struct FlowBlock {
    reference: FlowBlockRef,
    origin: OriginRef,
    scope: FlowScopeRef,
    instructions: List<FlowInstruction>,
    terminator: FlowTerminator
}

fn copy_instructions(values: List<FlowInstruction>) -> List<FlowInstruction> {
    let mut result: List<FlowInstruction> = []
    for value in values { result.push(value) }
    result
}

pub fn make_flow_block(
    reference: FlowBlockRef, origin: OriginRef, scope: FlowScopeRef,
    instructions: List<FlowInstruction>, terminator: FlowTerminator
) -> FlowBlock {
    if !executable_ref_same(reference.owner, scope.owner) {
        panic("FlowIR: block scope crosses executable owner")
    }
    let mut ordinal = 0
    for instruction in instructions {
        let site = instruction.reference
        if !executable_ref_same(site.owner, reference.owner) ||
           site.block_ordinal != reference.ordinal ||
           site.instruction_ordinal != ordinal {
            panic("FlowIR: instruction order/site is not stable")
        }
        ordinal = ordinal + 1
    }
    FlowBlock {
        reference: reference, origin: origin, scope: scope,
        instructions: copy_instructions(instructions), terminator: terminator
    }
}

pub fn flow_block_reference(value: FlowBlock) -> FlowBlockRef { value.reference }
pub fn flow_block_origin(value: FlowBlock) -> OriginRef { value.origin }
pub fn flow_block_scope(value: FlowBlock) -> FlowScopeRef { value.scope }
pub fn flow_block_instructions(value: FlowBlock) -> List<FlowInstruction> {
    copy_instructions(value.instructions)
}
pub fn flow_block_terminator(value: FlowBlock) -> FlowTerminator {
    value.terminator
}
pub fn flow_block_successors(value: FlowBlock) -> List<FlowSuccessor> {
    flow_terminator_successors(value.terminator)
}

fn copy_blocks(values: List<FlowBlock>) -> List<FlowBlock> {
    let mut result: List<FlowBlock> = []
    for value in values {
        result.push(FlowBlock {
            reference: value.reference, origin: value.origin,
            scope: value.scope,
            instructions: copy_instructions(value.instructions),
            terminator: value.terminator
        })
    }
    result
}

pub struct FlowBody {
    reference: ExecutableRef,
    origin: OriginRef,
    manifest: BinderManifest,
    scopes: List<FlowScope>,
    slots: List<FlowSlot>,
    entry: FlowBlockRef,
    blocks: List<FlowBlock>
}

pub fn make_flow_body(
    reference: ExecutableRef, origin: OriginRef,
    manifest: BinderManifest, scopes: List<FlowScope>,
    slots: List<FlowSlot>, entry: FlowBlockRef,
    blocks: List<FlowBlock>
) -> FlowBody {
    if !executable_ref_same(reference, binder_manifest_owner(manifest)) ||
       !executable_ref_same(reference, entry.owner) {
        panic("FlowIR: body identity/manifest/entry differs")
    }
    FlowBody {
        reference: reference, origin: origin, manifest: manifest,
        scopes: copy_scopes(scopes), slots: copy_flow_slots(slots),
        entry: entry, blocks: copy_blocks(blocks)
    }
}

pub fn flow_body_reference(value: FlowBody) -> ExecutableRef { value.reference }
pub fn flow_body_origin(value: FlowBody) -> OriginRef { value.origin }
pub fn flow_body_manifest(value: FlowBody) -> BinderManifest { value.manifest }
pub fn flow_body_scopes(value: FlowBody) -> List<FlowScope> {
    copy_scopes(value.scopes)
}
pub fn flow_body_slots(value: FlowBody) -> List<FlowSlot> {
    copy_flow_slots(value.slots)
}
pub fn flow_body_entry(value: FlowBody) -> FlowBlockRef { value.entry }
pub fn flow_body_blocks(value: FlowBody) -> List<FlowBlock> {
    copy_blocks(value.blocks)
}

fn copy_bodies(values: List<FlowBody>) -> List<FlowBody> {
    let mut result: List<FlowBody> = []
    for value in values {
        result.push(FlowBody {
            reference: value.reference, origin: value.origin,
            manifest: value.manifest, scopes: copy_scopes(value.scopes),
            slots: copy_flow_slots(value.slots), entry: value.entry,
            blocks: copy_blocks(value.blocks)
        })
    }
    result
}

// ============================================================
// Derived graph edges (never a second stored authority)
// ============================================================

pub struct FlowCallEdge {
    caller: ExecutableRef,
    site: FlowInstructionRef,
    target: FlowCallTarget,
    arguments: List<SlotRef>,
    result: SlotRef?
}

pub fn flow_call_edge_caller(value: FlowCallEdge) -> ExecutableRef {
    value.caller
}
pub fn flow_call_edge_site(value: FlowCallEdge) -> FlowInstructionRef {
    value.site
}
pub fn flow_call_edge_target(value: FlowCallEdge) -> FlowCallTarget {
    value.target
}
pub fn flow_call_edge_arguments(value: FlowCallEdge) -> List<SlotRef> {
    copy_slot_refs(value.arguments)
}
pub fn flow_call_edge_result(value: FlowCallEdge) -> SlotRef? { value.result }

fn copy_call_edges(values: List<FlowCallEdge>) -> List<FlowCallEdge> {
    let mut result: List<FlowCallEdge> = []
    for value in values {
        result.push(FlowCallEdge {
            caller: value.caller, site: value.site, target: value.target,
            arguments: copy_slot_refs(value.arguments), result: value.result
        })
    }
    result
}

pub fn flow_callable_call_edges(value: FlowCallable) -> List<FlowCallEdge> {
    copy_call_edges(value.call_edges)
}

pub struct FlowProjectionEdge {
    owner: ExecutableRef,
    site: FlowInstructionRef,
    projection: PathRef,
    base: SlotRef,
    result: SlotRef,
    partial: Bool
}

pub fn flow_projection_edge_owner(value: FlowProjectionEdge) -> ExecutableRef {
    value.owner
}
pub fn flow_projection_edge_site(value: FlowProjectionEdge) -> FlowInstructionRef {
    value.site
}
pub fn flow_projection_edge_projection(value: FlowProjectionEdge) -> PathRef {
    value.projection
}
pub fn flow_projection_edge_base(value: FlowProjectionEdge) -> SlotRef {
    value.base
}
pub fn flow_projection_edge_result(value: FlowProjectionEdge) -> SlotRef {
    value.result
}
pub fn flow_projection_edge_is_partial(value: FlowProjectionEdge) -> Bool {
    value.partial
}

pub struct FlowCaptureEdge {
    owner: ExecutableRef,
    site: FlowInstructionRef,
    capture: PathRef,
    source: SlotRef,
    target: SlotRef
}

pub fn flow_capture_edge_owner(value: FlowCaptureEdge) -> ExecutableRef {
    value.owner
}
pub fn flow_capture_edge_site(value: FlowCaptureEdge) -> FlowInstructionRef {
    value.site
}
pub fn flow_capture_edge_capture(value: FlowCaptureEdge) -> PathRef {
    value.capture
}
pub fn flow_capture_edge_source(value: FlowCaptureEdge) -> SlotRef {
    value.source
}
pub fn flow_capture_edge_target(value: FlowCaptureEdge) -> SlotRef {
    value.target
}

pub struct FlowControlEdge {
    owner: ExecutableRef,
    from: FlowBlockRef,
    to: FlowBlockRef,
    exited_scopes: List<FlowScopeRef>,
    terminator_kind: Int
}

pub fn flow_control_edge_owner(value: FlowControlEdge) -> ExecutableRef {
    value.owner
}
pub fn flow_control_edge_from(value: FlowControlEdge) -> FlowBlockRef {
    value.from
}
pub fn flow_control_edge_to(value: FlowControlEdge) -> FlowBlockRef { value.to }
pub fn flow_control_edge_exited_scopes(
    value: FlowControlEdge
) -> List<FlowScopeRef> { copy_scope_refs(value.exited_scopes) }
pub fn flow_control_edge_terminator_kind(value: FlowControlEdge) -> Int {
    value.terminator_kind
}

const FLOW_EXIT_RETURN: Int = 0
const FLOW_EXIT_UNREACHABLE: Int = 1
const FLOW_EXIT_DIVERGE: Int = 2

pub struct FlowExitKind { tag: Int }

fn flow_exit_kind_from_tag(tag: Int) -> FlowExitKind {
    if tag < FLOW_EXIT_RETURN || tag > FLOW_EXIT_DIVERGE {
        panic("FlowIR: invalid exit kind")
    }
    FlowExitKind { tag: tag }
}

pub fn flow_exit_kind_return() -> FlowExitKind {
    flow_exit_kind_from_tag(FLOW_EXIT_RETURN)
}
pub fn flow_exit_kind_unreachable() -> FlowExitKind {
    flow_exit_kind_from_tag(FLOW_EXIT_UNREACHABLE)
}
pub fn flow_exit_kind_diverge() -> FlowExitKind {
    flow_exit_kind_from_tag(FLOW_EXIT_DIVERGE)
}
pub fn flow_exit_kind_tag(value: FlowExitKind) -> Int {
    flow_exit_kind_from_tag(value.tag).tag
}

pub struct FlowExitEdge {
    owner: ExecutableRef,
    from: FlowBlockRef,
    kind: FlowExitKind,
    value: SlotRef?,
    exited_scopes: List<FlowScopeRef>
}

pub fn flow_exit_edge_owner(value: FlowExitEdge) -> ExecutableRef { value.owner }
pub fn flow_exit_edge_from(value: FlowExitEdge) -> FlowBlockRef { value.from }
pub fn flow_exit_edge_kind(value: FlowExitEdge) -> FlowExitKind { value.kind }
pub fn flow_exit_edge_value(value: FlowExitEdge) -> SlotRef? { value.value }
pub fn flow_exit_edge_exited_scopes(
    value: FlowExitEdge
) -> List<FlowScopeRef> { copy_scope_refs(value.exited_scopes) }

pub fn flow_body_call_edges(value: FlowBody) -> List<FlowCallEdge> {
    let mut result: List<FlowCallEdge> = []
    for block in value.blocks {
        for instruction in block.instructions {
            match instruction.value {
                FlowInstructionValue::CallValue {
                    target, arguments, result: call_result
                } => result.push(FlowCallEdge {
                    caller: value.reference, site: instruction.reference,
                    target: target, arguments: copy_slot_refs(arguments),
                    result: call_result
                }),
                _ => {}
            }
        }
    }
    result
}

pub fn flow_body_projection_edges(value: FlowBody) -> List<FlowProjectionEdge> {
    let mut result: List<FlowProjectionEdge> = []
    for block in value.blocks {
        for instruction in block.instructions {
            match instruction.value {
                FlowInstructionValue::ProjectValue {
                    projection, base, result: projected, partial
                } => result.push(FlowProjectionEdge {
                    owner: value.reference, site: instruction.reference,
                    projection: projection, base: base, result: projected,
                    partial: partial
                }),
                _ => {}
            }
        }
    }
    result
}

pub fn flow_body_capture_edges(value: FlowBody) -> List<FlowCaptureEdge> {
    let mut result: List<FlowCaptureEdge> = []
    for block in value.blocks {
        for instruction in block.instructions {
            match instruction.value {
                FlowInstructionValue::CaptureValue {
                    capture, source, target
                } => result.push(FlowCaptureEdge {
                    owner: value.reference, site: instruction.reference,
                    capture: capture, source: source, target: target
                }),
                _ => {}
            }
        }
    }
    result
}

pub fn flow_body_control_edges(value: FlowBody) -> List<FlowControlEdge> {
    let mut result: List<FlowControlEdge> = []
    for block in value.blocks {
        let kind = flow_terminator_kind_tag(block.terminator)
        for successor in terminator_successors(block.terminator) {
            result.push(FlowControlEdge {
                owner: value.reference, from: block.reference,
                to: successor.target,
                exited_scopes: copy_scope_refs(successor.exited_scopes),
                terminator_kind: kind
            })
        }
    }
    result
}

pub fn flow_body_exit_edges(value: FlowBody) -> List<FlowExitEdge> {
    let mut result: List<FlowExitEdge> = []
    for block in value.blocks {
        match block.terminator.value {
            FlowTerminatorValue::ReturnValue {
                value: returned, exited_scopes
            } => result.push(FlowExitEdge {
                owner: value.reference, from: block.reference,
                kind: flow_exit_kind_return(), value: returned,
                exited_scopes: copy_scope_refs(exited_scopes)
            }),
            FlowTerminatorValue::UnreachableValue { exited_scopes } =>
                result.push(FlowExitEdge {
                    owner: value.reference, from: block.reference,
                    kind: flow_exit_kind_unreachable(), value: none,
                    exited_scopes: copy_scope_refs(exited_scopes)
                }),
            FlowTerminatorValue::DivergeValue { exited_scopes } =>
                result.push(FlowExitEdge {
                    owner: value.reference, from: block.reference,
                    kind: flow_exit_kind_diverge(), value: none,
                    exited_scopes: copy_scope_refs(exited_scopes)
                }),
            _ => {}
        }
    }
    result
}

// ============================================================
// Freeze validation
// ============================================================

fn path_owner_module_key(value: PathOwnerRef) -> Str {
    if path_owner_ref_is_symbol(value) {
        symbol_ref_origin_module_key(path_owner_ref_symbol(value))
    } else {
        module_body_ref_origin_module_key(path_owner_ref_module_body(value))
    }
}

fn path_ref_module_key(value: PathRef) -> Str {
    path_owner_module_key(path_ref_owner(value))
}

fn origin_ref_module_key(value: OriginRef) -> Str {
    if origin_ref_is_symbol(value) {
        symbol_ref_origin_module_key(origin_ref_symbol(value))
    } else {
        path_ref_module_key(origin_ref_path(value))
    }
}

fn validate_origin_for_executable(
    origin: OriginRef, owner: ExecutableRef
) {
    if origin_ref_module_key(origin) != executable_ref_origin_module_key(owner) {
        panic("FlowIR: origin crosses executable module identity")
    }
}

fn type_ref_exists(values: List<FlowTypeNode>, target: FlowTypeRef) -> Bool {
    target.index >= 0 && target.index < values.len()
}

fn callable_index(
    values: List<FlowCallable>, target: ExecutableRef
) -> Int? {
    let mut index = 0
    for value in values {
        if executable_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn callable_for_ref(
    values: List<FlowCallable>, target: ExecutableRef
) -> FlowCallable {
    match callable_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: exact callable reference is absent")
    }
}

fn validate_callables(
    values: List<FlowCallable>, type_nodes: List<FlowTypeNode>
) {
    let mut left_index = 0
    while left_index < values.len() {
        let left = values.get(left_index).unwrap()
        validate_origin_for_executable(left.origin, left.reference)
        if !type_ref_exists(type_nodes, left.result_type) {
            panic("FlowIR: callable result type is absent")
        }
        if left.parameter_types.len() !=
           left.parameter_role_lower_bounds.len() {
            panic("FlowIR: callable role vector is not total")
        }
        for ty in left.parameter_types {
            if !type_ref_exists(type_nodes, ty) {
                panic("FlowIR: callable parameter type is absent")
            }
        }
        for role in left.parameter_role_lower_bounds {
            let _ = flow_semantic_role_tag(role)
        }
        let _ = flow_callable_mode_from_tag(left.mode.tag)
        let mut right_index = left_index + 1
        while right_index < values.len() {
            if executable_ref_same(
                    left.reference, values.get(right_index).unwrap().reference) {
                panic("FlowIR: duplicate callable reference")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
}

fn scope_index(values: List<FlowScope>, target: FlowScopeRef) -> Int? {
    let mut index = 0
    for value in values {
        if flow_scope_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn scope_for_ref(values: List<FlowScope>, target: FlowScopeRef) -> FlowScope {
    match scope_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: scope reference is absent")
    }
}

fn validate_scopes(owner: ExecutableRef, values: List<FlowScope>) {
    if values.len() == 0 { panic("FlowIR: body has no root scope") }
    let mut ordinal = 0
    for value in values {
        if !executable_ref_same(value.reference.owner, owner) ||
           value.reference.ordinal != ordinal {
            panic("FlowIR: scope order/owner is not frozen")
        }
        if ordinal == 0 {
            if value.parent.is_some() {
                panic("FlowIR: root scope has a parent")
            }
        } else {
            let parent = match value.parent {
                some(parent) => parent,
                none => panic("FlowIR: non-root scope has no parent")
            }
            if !executable_ref_same(parent.owner, owner) ||
               parent.ordinal < 0 || parent.ordinal >= ordinal {
                panic("FlowIR: scope parent is not an earlier local scope")
            }
        }
        ordinal = ordinal + 1
    }
}

fn slot_index(values: List<FlowSlot>, target: SlotRef) -> Int? {
    let mut index = 0
    for value in values {
        if slot_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn slot_for_ref(values: List<FlowSlot>, target: SlotRef) -> FlowSlot {
    match slot_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: instruction references an undeclared slot")
    }
}

fn validate_slots(
    body: FlowBody, type_nodes: List<FlowTypeNode>
) {
    let binders = binder_manifest_entries(body.manifest)
    if binders.len() != body.slots.len() {
        panic("FlowIR: binder manifest/slot census differs")
    }
    let mut index = 0
    while index < body.slots.len() {
        let slot = body.slots.get(index).unwrap()
        let binder = binders.get(index).unwrap()
        if !slot_ref_same(slot.reference, binder_entry_slot(binder)) {
            panic("FlowIR: slot order differs from binder manifest")
        }
        if !type_ref_exists(type_nodes, slot.ty) {
            panic("FlowIR: slot type is absent")
        }
        if !executable_ref_same(slot.scope.owner, body.reference) ||
           scope_index(body.scopes, slot.scope).is_none() {
            panic("FlowIR: slot scope is absent or cross-body")
        }
        let _ = flow_initial_slot_state_from_tag(slot.initial_state.tag)
        let _ = flow_storage_class_from_tag(slot.storage.tag)
        let mut right_index = index + 1
        while right_index < body.slots.len() {
            let right = body.slots.get(right_index).unwrap()
            if slot_ref_same(slot.reference, right.reference) {
                panic("FlowIR: duplicate frozen slot")
            }
            if flow_scope_ref_same(slot.scope, right.scope) &&
               slot.reverse_ordinal == right.reverse_ordinal {
                panic("FlowIR: duplicate reverse lexical slot ordinal")
            }
            right_index = right_index + 1
        }
        index = index + 1
    }
    // Reverse ordinals are dense per scope.  This makes cleanup order a finite
    // table rather than a backend spelling/order guess.
    for scope in body.scopes {
        let mut count = 0
        for slot in body.slots {
            if flow_scope_ref_same(slot.scope, scope.reference) {
                count = count + 1
            }
        }
        let mut expected = 0
        while expected < count {
            let mut matches = 0
            for slot in body.slots {
                if flow_scope_ref_same(slot.scope, scope.reference) &&
                   slot.reverse_ordinal == expected {
                    matches = matches + 1
                }
            }
            if matches != 1 {
                panic("FlowIR: reverse lexical slot order is not dense")
            }
            expected = expected + 1
        }
    }
}

fn block_index(values: List<FlowBlock>, target: FlowBlockRef) -> Int? {
    let mut index = 0
    for value in values {
        if flow_block_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn block_for_ref(values: List<FlowBlock>, target: FlowBlockRef) -> FlowBlock {
    match block_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: successor block is absent")
    }
}

fn scope_lineage(
    scopes: List<FlowScope>, start: FlowScopeRef
) -> List<FlowScopeRef> {
    let mut result: List<FlowScopeRef> = []
    let mut current: FlowScopeRef? = some(start)
    while current.is_some() {
        let reference = current.unwrap()
        result.push(reference)
        let scope = scope_for_ref(scopes, reference)
        current = scope.parent
    }
    result
}

fn validate_exited_scope_prefix(
    lineage: List<FlowScopeRef>, exited: List<FlowScopeRef>
) {
    if exited.len() > lineage.len() {
        panic("FlowIR: edge exits more scopes than are active")
    }
    let mut index = 0
    while index < exited.len() {
        if !flow_scope_ref_same(
                exited.get(index).unwrap(), lineage.get(index).unwrap()) {
            panic("FlowIR: exited scopes are not inner-to-outer")
        }
        index = index + 1
    }
}

fn validate_successor(
    body: FlowBody, from_scope: FlowScopeRef, successor: FlowSuccessor
) {
    if !executable_ref_same(successor.target.owner, body.reference) {
        panic("FlowIR: successor crosses executable body")
    }
    let target_block = block_for_ref(body.blocks, successor.target)
    let lineage = scope_lineage(body.scopes, from_scope)
    validate_exited_scope_prefix(lineage, successor.exited_scopes)
    if successor.exited_scopes.len() >= lineage.len() {
        panic("FlowIR: non-terminal edge exits the root scope")
    }
    let remaining = lineage.get(successor.exited_scopes.len()).unwrap()
    if !flow_scope_ref_same(target_block.scope, remaining) {
        panic("FlowIR: successor target scope differs after exits")
    }
}

fn validate_terminal_exits(
    body: FlowBody, from_scope: FlowScopeRef, exited: List<FlowScopeRef>
) {
    let lineage = scope_lineage(body.scopes, from_scope)
    validate_exited_scope_prefix(lineage, exited)
    if exited.len() != lineage.len() {
        panic("FlowIR: terminal edge does not exit every active scope")
    }
}

fn validate_instruction_slots(body: FlowBody, instruction: FlowInstruction) {
    validate_origin_for_executable(instruction.origin, body.reference)
    match instruction.value {
        FlowInstructionValue::InitializeValue { inputs, target, .. } => {
            for input in inputs { let _ = slot_for_ref(body.slots, input) }
            let _ = slot_for_ref(body.slots, target)
        },
        FlowInstructionValue::ReadValue { source, target } => {
            let _ = slot_for_ref(body.slots, source)
            let _ = slot_for_ref(body.slots, target)
        },
        FlowInstructionValue::MutateValue { target, value } => {
            let _ = slot_for_ref(body.slots, target)
            let _ = slot_for_ref(body.slots, value)
        },
        FlowInstructionValue::ConsumeValue { source } |
        FlowInstructionValue::DiscardValue { source } => {
            let _ = slot_for_ref(body.slots, source)
        },
        FlowInstructionValue::AssignValue { rhs_temp, target } => {
            let rhs = slot_for_ref(body.slots, rhs_temp)
            let _ = slot_for_ref(body.slots, target)
            if !flow_storage_class_same(rhs.storage, flow_storage_temp()) {
                panic("FlowIR: Assign RHS is not an explicit temp slot")
            }
        },
        FlowInstructionValue::CallValue { target, arguments, result } => {
            for argument in arguments {
                let _ = slot_for_ref(body.slots, argument)
            }
            match result {
                some(slot) => { let _ = slot_for_ref(body.slots, slot) },
                none => {}
            }
            if flow_call_target_is_local(target) {
                let _ = slot_for_ref(body.slots, flow_call_target_local(target))
            } else if !flow_call_target_is_direct(target) {
                if path_ref_module_key(flow_call_target_dynamic(target)) !=
                   executable_ref_origin_module_key(body.reference) {
                    panic("FlowIR: dynamic call adapter crosses module")
                }
            }
        },
        FlowInstructionValue::ProjectValue { base, result, .. } => {
            let _ = slot_for_ref(body.slots, base)
            let _ = slot_for_ref(body.slots, result)
        },
        FlowInstructionValue::CaptureValue { capture, source, target } => {
            if path_ref_module_key(capture) !=
               executable_ref_origin_module_key(body.reference) {
                panic("FlowIR: capture path crosses executable module")
            }
            let _ = slot_for_ref(body.slots, source)
            let _ = slot_for_ref(body.slots, target)
        },
        FlowInstructionValue::ScopeEnterValue { scope } |
        FlowInstructionValue::ScopeExitValue { scope } => {
            if !executable_ref_same(scope.owner, body.reference) ||
               scope_index(body.scopes, scope).is_none() {
                panic("FlowIR: scope operation references an absent scope")
            }
        }
    }
}

fn advance_instruction_scope(
    body: FlowBody, current: FlowScopeRef, instruction: FlowInstruction
) -> FlowScopeRef {
    match instruction.value {
        FlowInstructionValue::ScopeEnterValue { scope } => {
            let entered = scope_for_ref(body.scopes, scope)
            let parent = match entered.parent {
                some(value) => value,
                none => panic("FlowIR: cannot enter the root scope")
            }
            if !flow_scope_ref_same(parent, current) {
                panic("FlowIR: scope enter is not a direct child")
            }
            scope
        },
        FlowInstructionValue::ScopeExitValue { scope } => {
            if !flow_scope_ref_same(scope, current) {
                panic("FlowIR: scope exit is not the active scope")
            }
            let exited = scope_for_ref(body.scopes, scope)
            match exited.parent {
                some(parent) => parent,
                none => panic("FlowIR: instruction cannot exit root scope")
            }
        },
        _ => current
    }
}

fn validate_terminator_slots(body: FlowBody, terminator: FlowTerminator) {
    validate_origin_for_executable(terminator.origin, body.reference)
    match terminator.value {
        FlowTerminatorValue::BranchValue { condition, .. } |
        FlowTerminatorValue::LoopValue { condition, .. } => {
            let _ = slot_for_ref(body.slots, condition)
        },
        FlowTerminatorValue::ReturnValue { value, .. } => match value {
            some(slot) => { let _ = slot_for_ref(body.slots, slot) },
            none => {}
        },
        FlowTerminatorValue::CatchValue { error, .. } => {
            let _ = slot_for_ref(body.slots, error)
        },
        FlowTerminatorValue::HandlerValue { operation, .. } => {
            let _ = slot_for_ref(body.slots, operation)
        },
        _ => {}
    }
}

fn validate_body_blocks(body: FlowBody) {
    if body.blocks.len() == 0 {
        panic("FlowIR: concrete body has no blocks")
    }
    if !flow_block_ref_same(body.entry, body.blocks.get(0).unwrap().reference) ||
       body.entry.ordinal != 0 {
        panic("FlowIR: entry is not the first stable block")
    }
    let mut ordinal = 0
    for block in body.blocks {
        if !executable_ref_same(block.reference.owner, body.reference) ||
           block.reference.ordinal != ordinal {
            panic("FlowIR: block order/owner is not frozen")
        }
        if scope_index(body.scopes, block.scope).is_none() {
            panic("FlowIR: block scope is absent")
        }
        validate_origin_for_executable(block.origin, body.reference)
        let mut instruction_ordinal = 0
        let mut active_scope = block.scope
        for instruction in block.instructions {
            if !executable_ref_same(
                    instruction.reference.owner, body.reference) ||
               instruction.reference.block_ordinal != ordinal ||
               instruction.reference.instruction_ordinal != instruction_ordinal {
                panic("FlowIR: instruction site/order drifted")
            }
            validate_instruction_slots(body, instruction)
            active_scope = advance_instruction_scope(
                body, active_scope, instruction)
            instruction_ordinal = instruction_ordinal + 1
        }
        validate_terminator_slots(body, block.terminator)
        for successor in terminator_successors(block.terminator) {
            validate_successor(body, active_scope, successor)
        }
        match terminator_terminal_exited_scopes(block.terminator) {
            some(exited) => validate_terminal_exits(body, active_scope, exited),
            none => {}
        }
        ordinal = ordinal + 1
    }
    // Reject dead blocks: the frozen topology is exactly the executable graph,
    // not a bag of future or backend-only alternatives.
    let mut reachable: List<FlowBlockRef> = [body.entry]
    let mut cursor = 0
    while cursor < reachable.len() {
        let current = reachable.get(cursor).unwrap()
        let block = block_for_ref(body.blocks, current)
        for successor in terminator_successors(block.terminator) {
            let mut present = false
            for seen in reachable {
                if flow_block_ref_same(seen, successor.target) {
                    present = true
                }
            }
            if !present { reachable.push(successor.target) }
        }
        cursor = cursor + 1
    }
    if reachable.len() != body.blocks.len() {
        panic("FlowIR: frozen body contains an unreachable block")
    }
}

fn validate_bodies(
    bodies: List<FlowBody>, callables: List<FlowCallable>,
    type_nodes: List<FlowTypeNode>
) {
    let mut expected_body_index = 0
    for callable in callables {
        if flow_callable_mode_same(
                callable.mode, flow_callable_mode_concrete_body()) {
            let body = match bodies.get(expected_body_index) {
                some(value) => value,
                none => panic("FlowIR: concrete callable body is missing")
            }
            if !executable_ref_same(callable.reference, body.reference) ||
               !origin_ref_same(callable.origin, body.origin) {
                panic("FlowIR: body order/identity differs from callable table")
            }
            validate_scopes(body.reference, body.scopes)
            validate_slots(body, type_nodes)
            validate_body_blocks(body)
            expected_body_index = expected_body_index + 1
        }
    }
    if expected_body_index != bodies.len() {
        panic("FlowIR: body has no concrete callable contract")
    }
}

fn validate_direct_calls(
    bodies: List<FlowBody>, callables: List<FlowCallable>
) {
    for body in bodies {
        for edge in flow_body_call_edges(body) {
            if flow_call_target_is_direct(edge.target) {
                let target = callable_for_ref(
                    callables, flow_call_target_direct(edge.target))
                if edge.arguments.len() != target.parameter_types.len() {
                    panic("FlowIR: direct call arity differs from exact contract")
                }
            }
        }
    }
}

// ============================================================
// Deterministic topology fingerprint and frozen program
// ============================================================

fn encode_atom(value: Str) -> Str { "${value.len()}:${value}" }

fn encode_symbol(value: SymbolRef) -> Str {
    [
        "S",
        encode_atom(symbol_ref_origin_module_key(value)),
        namespace_kind_tag(symbol_ref_namespace_kind(value)).to_str(),
        encode_atom(symbol_ref_canonical_payload(value)),
        encode_atom(symbol_ref_declaration_site_path(value))
    ].join("/")
}

fn encode_path_owner(value: PathOwnerRef) -> Str {
    if path_owner_ref_is_symbol(value) {
        "OS/${encode_symbol(path_owner_ref_symbol(value))}"
    } else {
        let body = path_owner_ref_module_body(value)
        "OM/${encode_atom(module_body_ref_origin_module_key(body))}/${encode_atom(module_body_ref_declaration_site_path(body))}"
    }
}

fn encode_path(value: PathRef) -> Str {
    let mut parts: List<Str> = [
        "P", encode_path_owner(path_ref_owner(value)),
        path_role_tag(path_ref_role(value)).to_str()
    ]
    for component in path_ref_normalized_child_path(value) {
        parts.push(encode_atom(component))
    }
    parts.join("/")
}

fn encode_slot(value: SlotRef) -> Str {
    if slot_ref_is_source(value) {
        [
            "SL", encode_atom(slot_ref_source_origin_module_key(value)),
            slot_domain_tag(slot_ref_source_domain(value)).to_str(),
            slot_ref_source_def_id(value).to_str()
        ].join("/")
    } else {
        "SS/${encode_path(slot_ref_synthetic_path(value))}"
    }
}

fn encode_executable(value: ExecutableRef) -> Str {
    if executable_ref_is_named(value) {
        "EN/${encode_symbol(executable_ref_named_symbol(value))}"
    } else {
        "EA/${encode_path(executable_ref_anonymous_path(value))}"
    }
}

fn encode_origin(value: OriginRef) -> Str {
    if origin_ref_is_symbol(value) {
        "ON/${encode_symbol(origin_ref_symbol(value))}"
    } else {
        "OP/${encode_path(origin_ref_path(value))}"
    }
}

fn encode_type_ref(value: FlowTypeRef) -> Str { "T${value.index.to_str()}" }
fn encode_scope_ref(value: FlowScopeRef) -> Str {
    "Q/${encode_executable(value.owner)}/${value.ordinal.to_str()}"
}
fn encode_block_ref(value: FlowBlockRef) -> Str {
    "B/${encode_executable(value.owner)}/${value.ordinal.to_str()}"
}
fn encode_instruction_ref(value: FlowInstructionRef) -> Str {
    "I/${encode_executable(value.owner)}/${value.block_ordinal.to_str()}/${value.instruction_ordinal.to_str()}"
}

fn encode_call_target(value: FlowCallTarget) -> Str {
    match value.value {
        FlowCallTargetValue::DirectTargetValue(target) =>
            "CD/${encode_executable(target)}",
        FlowCallTargetValue::LocalTargetValue(target) =>
            "CL/${encode_slot(target)}",
        FlowCallTargetValue::DynamicTargetValue(target) =>
            "CY/${encode_path(target)}"
    }
}

fn encode_scope_refs(values: List<FlowScopeRef>) -> Str {
    let mut parts: List<Str> = []
    for value in values { parts.push(encode_scope_ref(value)) }
    parts.join(",")
}

fn encode_successor(value: FlowSuccessor) -> Str {
    "${encode_block_ref(value.target)}[${encode_scope_refs(value.exited_scopes)}]"
}

fn encode_instruction(value: FlowInstruction) -> Str {
    let mut parts: List<Str> = [
        encode_instruction_ref(value.reference),
        encode_origin(value.origin),
        flow_instruction_kind_tag(value).to_str()
    ]
    match value.value {
        FlowInstructionValue::InitializeValue { operation, inputs, target } => {
            parts.push(encode_path(operation))
            for input in inputs { parts.push(encode_slot(input)) }
            parts.push(encode_slot(target))
        },
        FlowInstructionValue::ReadValue { source, target } => {
            parts.push(encode_slot(source)); parts.push(encode_slot(target))
        },
        FlowInstructionValue::MutateValue { target, value: input } => {
            parts.push(encode_slot(target)); parts.push(encode_slot(input))
        },
        FlowInstructionValue::ConsumeValue { source } |
        FlowInstructionValue::DiscardValue { source } =>
            parts.push(encode_slot(source)),
        FlowInstructionValue::AssignValue { rhs_temp, target } => {
            parts.push(encode_slot(rhs_temp)); parts.push(encode_slot(target))
        },
        FlowInstructionValue::CallValue { target, arguments, result } => {
            parts.push(encode_call_target(target))
            for argument in arguments { parts.push(encode_slot(argument)) }
            match result {
                some(slot) => parts.push(encode_slot(slot)),
                none => parts.push("void")
            }
        },
        FlowInstructionValue::ProjectValue {
            projection, base, result, partial
        } => {
            parts.push(encode_path(projection)); parts.push(encode_slot(base))
            parts.push(encode_slot(result))
            parts.push(if partial { "partial" } else { "total" })
        },
        FlowInstructionValue::CaptureValue { capture, source, target } => {
            parts.push(encode_path(capture)); parts.push(encode_slot(source))
            parts.push(encode_slot(target))
        },
        FlowInstructionValue::ScopeEnterValue { scope } |
        FlowInstructionValue::ScopeExitValue { scope } => {
            parts.push(encode_scope_ref(scope))
        }
    }
    parts.join(";")
}

fn encode_terminator(value: FlowTerminator) -> Str {
    let mut parts: List<Str> = [
        encode_origin(value.origin), flow_terminator_kind_tag(value).to_str()
    ]
    match value.value {
        FlowTerminatorValue::GotoValue(edge) |
        FlowTerminatorValue::BreakValue(edge) |
        FlowTerminatorValue::ContinueValue(edge) =>
            parts.push(encode_successor(edge)),
        FlowTerminatorValue::BranchValue {
            condition, when_true, when_false
        } => {
            parts.push(encode_slot(condition))
            parts.push(encode_successor(when_true))
            parts.push(encode_successor(when_false))
        },
        FlowTerminatorValue::LoopValue { condition, body, exit } => {
            parts.push(encode_slot(condition)); parts.push(encode_successor(body))
            parts.push(encode_successor(exit))
        },
        FlowTerminatorValue::ReturnValue { value: returned, exited_scopes } => {
            match returned {
                some(slot) => parts.push(encode_slot(slot)),
                none => parts.push("void")
            }
            parts.push(encode_scope_refs(exited_scopes))
        },
        FlowTerminatorValue::CatchValue { error, handled, propagate } => {
            parts.push(encode_slot(error)); parts.push(encode_successor(handled))
            parts.push(encode_successor(propagate))
        },
        FlowTerminatorValue::HandlerValue {
            operation, handled, unhandled
        } => {
            parts.push(encode_slot(operation))
            parts.push(encode_successor(handled))
            parts.push(encode_successor(unhandled))
        },
        FlowTerminatorValue::UnreachableValue { exited_scopes } |
        FlowTerminatorValue::DivergeValue { exited_scopes } =>
            parts.push(encode_scope_refs(exited_scopes))
    }
    parts.join(";")
}

fn compute_topology_encoding(
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>,
    bodies: List<FlowBody>
) -> Str {
    let mut parts: List<Str> = ["FlowIR/0.1"]
    for node in type_nodes {
        let mut item: List<Str> = [
            "TY", node.reference.index.to_str(),
            flow_type_kind_tag(node.kind).to_str(),
            node.parameter_count.to_str(), node.parameter_index.to_str()
        ]
        match node.nominal {
            some(symbol) => item.push(encode_symbol(symbol)),
            none => item.push("none")
        }
        for child in node.children { item.push(encode_type_ref(child)) }
        parts.push(item.join(";"))
    }
    for callable in callables {
        let mut item: List<Str> = [
            "CA", encode_executable(callable.reference),
            encode_origin(callable.origin), callable.mode.tag.to_str()
        ]
        for parameter in callable.parameter_types {
            item.push(encode_type_ref(parameter))
        }
        item.push("R${encode_type_ref(callable.result_type)}")
        for role in callable.parameter_role_lower_bounds {
            item.push("L${flow_semantic_role_tag(role).to_str()}")
        }
        parts.push(item.join(";"))
    }
    for body in bodies {
        parts.push("BO/${encode_executable(body.reference)}/${encode_origin(body.origin)}")
        for scope in body.scopes {
            let parent = match scope.parent {
                some(value) => encode_scope_ref(value),
                none => "root"
            }
            parts.push("SC/${encode_scope_ref(scope.reference)}/${parent}")
        }
        for slot in body.slots {
            parts.push([
                "SL", encode_slot(slot.reference), encode_type_ref(slot.ty),
                encode_scope_ref(slot.scope), slot.reverse_ordinal.to_str(),
                slot.initial_state.tag.to_str(), slot.storage.tag.to_str()
            ].join(";"))
        }
        for block in body.blocks {
            parts.push([
                "BL", encode_block_ref(block.reference),
                encode_origin(block.origin), encode_scope_ref(block.scope)
            ].join(";"))
            for instruction in block.instructions {
                parts.push(encode_instruction(instruction))
            }
            parts.push(encode_terminator(block.terminator))
        }
    }
    parts.join("|")
}

pub struct FlowTopologyFingerprint { canonical: Str }

pub fn flow_topology_fingerprint_same(
    left: FlowTopologyFingerprint, right: FlowTopologyFingerprint
) -> Bool { left.canonical == right.canonical }

pub fn flow_topology_fingerprint_canonical(
    value: FlowTopologyFingerprint
) -> Str { value.canonical }

pub struct FlowProgram {
    type_nodes: List<FlowTypeNode>,
    callables: List<FlowCallable>,
    bodies: List<FlowBody>,
    topology_fingerprint: FlowTopologyFingerprint
}

fn freeze_callables_with_edges(
    callables: List<FlowCallable>, bodies: List<FlowBody>
) -> List<FlowCallable> {
    let mut result: List<FlowCallable> = []
    for callable in callables {
        let edges = if flow_callable_mode_same(
                callable.mode, flow_callable_mode_concrete_body()) {
            let mut found: FlowBody? = none
            for body in bodies {
                if executable_ref_same(body.reference, callable.reference) {
                    found = some(body)
                }
            }
            match found {
                some(body) => flow_body_call_edges(body),
                none => panic("FlowIR: cannot derive concrete callable edges")
            }
        } else {
            []
        }
        result.push(FlowCallable {
            reference: callable.reference, origin: callable.origin,
            parameter_types: copy_type_refs(callable.parameter_types),
            result_type: callable.result_type, mode: callable.mode,
            parameter_role_lower_bounds:
                callable.parameter_role_lower_bounds,
            call_edges: copy_call_edges(edges)
        })
    }
    result
}

pub fn make_flow_program(
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>,
    bodies: List<FlowBody>
) -> FlowProgram {
    validate_type_nodes(type_nodes)
    validate_callables(callables, type_nodes)
    validate_bodies(bodies, callables, type_nodes)
    validate_direct_calls(bodies, callables)
    let frozen_types = copy_type_nodes(type_nodes)
    let frozen_bodies = copy_bodies(bodies)
    let frozen_callables = freeze_callables_with_edges(callables, frozen_bodies)
    let fingerprint = FlowTopologyFingerprint {
        canonical: compute_topology_encoding(
            frozen_types, frozen_callables, frozen_bodies)
    }
    FlowProgram {
        type_nodes: frozen_types, callables: frozen_callables,
        bodies: frozen_bodies, topology_fingerprint: fingerprint
    }
}

pub fn flow_program_type_nodes(value: FlowProgram) -> List<FlowTypeNode> {
    copy_type_nodes(value.type_nodes)
}
pub fn flow_program_callables(value: FlowProgram) -> List<FlowCallable> {
    let mut result: List<FlowCallable> = []
    for callable in value.callables {
        result.push(FlowCallable {
            reference: callable.reference, origin: callable.origin,
            parameter_types: copy_type_refs(callable.parameter_types),
            result_type: callable.result_type, mode: callable.mode,
            parameter_role_lower_bounds:
                callable.parameter_role_lower_bounds,
            call_edges: copy_call_edges(callable.call_edges)
        })
    }
    result
}
pub fn flow_program_bodies(value: FlowProgram) -> List<FlowBody> {
    copy_bodies(value.bodies)
}
pub fn flow_program_topology_fingerprint(
    value: FlowProgram
) -> FlowTopologyFingerprint { value.topology_fingerprint }

pub fn validate_flow_program(value: FlowProgram) {
    // Reconstructing through the sole freeze barrier rejects any representation
    // drift and recomputes, rather than trusts, the topology fingerprint.
    let rebuilt = make_flow_program(
        value.type_nodes, value.callables.map(fn(callable) {
            make_flow_callable(
                callable.reference, callable.origin,
                callable.parameter_types, callable.result_type,
                callable.mode, callable.parameter_role_lower_bounds)
        }), value.bodies)
    if !flow_topology_fingerprint_same(
            rebuilt.topology_fingerprint, value.topology_fingerprint) {
        panic("FlowIR: frozen topology fingerprint drifted")
    }
}
