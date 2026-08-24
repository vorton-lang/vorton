// Mechanical CoreHIR -> FlowIR lowering.
//
// CoreProgram is the sole type/callable/body authority.  This module has no
// public builder and accepts no side table: stable block/instruction ordinals,
// CFG edges and pattern decisions are derived once from the immutable Core
// tree, while exact slots/scopes/contracts are copied from Core.

use ir_identity::{
    OriginRef, SlotRef, PathRef, PathOwnerRef,
    slot_ref_same, slot_ref_is_source, make_synthetic_slot_ref,
    registered_nominal_ref_symbol, origin_ref_same,
    path_owner_for_symbol, path_ref_owner, path_ref_normalized_child_path,
    make_path_ref, path_role_parameter, path_role_result,
    path_role_child, path_role_synthetic
}
use ir_inventory::{
    ExecutableRef, BinderManifest, BinderEntry, BinderKind,
    EffectOperationRef,
    executable_ref_same, executable_ref_is_named,
    executable_ref_named_symbol, executable_ref_anonymous_path,
    make_source_binder_entry, make_synthetic_binder_entry,
    make_binder_manifest,
    binder_kind_tag,
    binder_kind_source_param, binder_kind_generated_synthetic_parameter,
    binder_kind_call_result, binder_kind_pattern_projection,
    binder_kind_scope_result, binder_kind_control_result,
    binder_kind_assign_temp, binder_kind_pre_anf,
    effect_operation_ref_callable,
    system_host_callable_executable
}
use hir::{method_call_ref_is_bound, method_call_ref_bound_evidence}
use core_hir::{
    CoreProgram, CoreBodyEntry,
    core_program_type_graph, core_program_callables,
    core_program_bodies,
    core_body_entry_body
}
use core_expr::{
    CoreBody, CoreBinder, CoreBlock, CoreStmt, CoreExpr, CorePattern, CoreMatchArm,
    CorePatternField, CoreFieldRef, CoreFieldValue,
    CoreCalleeRef, CoreEvidenceRef, CoreConstructorRef, CorePlaceRef,
    CoreCallableContract,
    core_type_ref_to_flow,
    core_callable_reference, core_callable_origin,
    core_callable_parameter_types, core_callable_parameter_slots,
    core_callable_result_type, core_callable_mode,
    core_callable_semantic_contract,
    core_callable_evidence_requirements,
    core_body_reference, core_body_origin, core_body_binders,
    core_body_parameter_slots, core_body_block, core_body_result_type,
    core_type_graph_nodes,
    core_binder_reference, core_binder_type, core_binder_kind,
    core_binder_site, core_binder_storage_contract,
    core_block_statements, core_block_tail, core_block_origin,
    core_stmt_kind_tag, core_stmt_origin, core_stmt_target,
    core_stmt_value, core_stmt_while_condition, core_stmt_while_body,
    core_stmt_return_value, core_stmt_bind_is_mutable,
    core_place_is_slot, core_place_slot, core_place_base,
    core_place_field, core_place_evaluated_index, core_place_value_type,
    core_expr_kind_tag, core_expr_type,
    core_expr_origin, core_expr_literal, core_literal_kind_tag,
    core_expr_callable_executable,
    core_literal_int, core_literal_float, core_literal_str, core_literal_bool,
    core_expr_read_source, core_expr_primitive_operation,
    core_primitive_op_tag, core_expr_primitive_operands,
    core_expr_call_callee, core_expr_call_arguments,
    core_expr_call_evidence, core_expr_method_ref,
    core_expr_method_receiver,
    core_expr_effect_operation, core_expr_system_host,
    core_expr_dict_constructor, core_expr_dict_project_dictionary,
    core_expr_dict_project_method,
    core_expr_project_base, core_expr_project_field,
    core_expr_project_is_partial,
    core_expr_constructor, core_expr_constructor_fields,
    core_constructor_kind_tag, core_constructor_executable,
    core_expr_lambda_executable, core_expr_block,
    core_expr_lambda_captures, core_capture_source,
    core_expr_condition, core_expr_then_block, core_expr_else_block,
    core_expr_scrutinee, core_expr_match_arms,
    core_expr_try_body, core_expr_error_slot,
    core_expr_handle_body, core_expr_handlers,
    core_match_arm_pattern, core_match_arm_guard,
    core_match_arm_body, core_match_arm_origin,
    core_handler_operation, core_handler_executable,
    core_pattern_type, core_pattern_kind_tag, core_pattern_binding,
    core_pattern_literal, core_pattern_elements,
    core_pattern_fields, core_pattern_struct_owner,
    core_pattern_variant, core_pattern_field_ref,
    core_pattern_field_pattern,
    core_field_ref_kind_tag, core_field_ref_nominal,
    core_field_ref_variant, core_field_ref_tuple_index,
    core_field_ref_record_path,
    core_field_value_field, core_field_value_expr,
    core_callee_kind_tag, core_callee_direct, core_callee_local,
    core_callee_dynamic, core_callee_contract,
    core_evidence_is_local, core_evidence_is_dict,
    core_evidence_local, core_evidence_callable, core_evidence_dict
}
use flow_ir::{
    FlowProgram, FlowTypeNode, FlowTypeRef, FlowCallable, FlowBody,
    FlowScope, FlowScopeRef, FlowSlot,
    FlowInitialSlotState, FlowStorageClass, FlowStorageContract,
    FlowBlock, FlowBlockRef, FlowInstructionRef, FlowInstruction,
    FlowSemanticStepRef,
    FlowTerminator, FlowSuccessor, FlowHandlerBinding,
    FlowPatternContract, FlowPatternField,
    FlowSemanticRole, FlowPrimitiveOp,
    FlowEvidenceRef, FlowCallTarget, FlowFieldIdentity, FlowPlaceRef,
    copy_flow_type_graph_nodes,
    make_flow_callable, make_flow_program,
    make_flow_slot, make_flow_block_ref, make_flow_instruction_ref,
    make_flow_block, make_flow_body,
    make_flow_scope_ref, make_flow_root_scope, make_flow_child_scope,
    flow_initial_slot_empty, flow_initial_slot_live,
    flow_storage_parameter, flow_storage_local,
    flow_storage_temp, flow_storage_result, flow_storage_capture,
    flow_own_storage, flow_slot_reference, flow_slot_type, flow_slot_scope,
    make_flow_successor,
    make_flow_goto, make_flow_branch, make_flow_loop,
    make_flow_return, make_flow_continue,
    make_flow_unreachable, make_flow_diverge,
    make_flow_pattern_branch, make_flow_try,
    make_flow_handler_binding, make_flow_handle_install,
    make_flow_initialize, make_flow_read, make_flow_assign,
    make_flow_slot_place, make_flow_project_place,
    make_flow_call, make_flow_project, make_flow_capture,
    make_flow_int_literal_contract, make_flow_float_literal_contract,
    make_flow_str_literal_contract, make_flow_bool_literal_contract,
    make_flow_unit_literal_contract,
    make_flow_primitive_contract, make_flow_constructor_contract,
    make_fresh_flow_value_origin,
    make_flow_tuple_aggregate_contract, make_flow_record_aggregate_contract,
    make_flow_closure_contract,
    make_flow_callable_value_contract,
    make_direct_flow_call_target, make_local_flow_call_target,
    make_dynamic_flow_call_target,
    make_flow_local_evidence, make_flow_callable_evidence,
    make_flow_dict_evidence,
    make_nominal_flow_projection_contract,
    make_variant_flow_projection_contract,
    make_tuple_flow_projection_contract,
    make_structural_flow_projection_contract,
    make_nominal_flow_field_identity, make_variant_flow_field_identity,
    make_path_flow_field_identity,
    make_flow_pattern_int, make_flow_pattern_float,
    make_flow_pattern_str, make_flow_pattern_bool, make_flow_pattern_unit,
    make_flow_wildcard_pattern, make_flow_binding_pattern,
    make_flow_literal_pattern, make_flow_tuple_pattern,
    make_flow_pattern_field, make_flow_struct_pattern,
    make_flow_variant_pattern,
    flow_primitive_add, flow_primitive_sub, flow_primitive_mul,
    flow_primitive_div, flow_primitive_mod, flow_primitive_negate,
    flow_primitive_not, flow_primitive_lt, flow_primitive_le,
    flow_primitive_gt, flow_primitive_ge,
    flow_semantic_role_read, flow_semantic_role_mutate,
    flow_semantic_role_consume,
    flow_call_contract_parameter_types,
    flow_call_contract_parameter_roles,
    flow_call_contract_result_type, flow_call_contract_result_role,
    flow_call_contract_result_origin,
    flow_scope_reference, flow_scope_has_parent, flow_scope_parent,
    flow_scope_ref_same,
    flow_block_reference, flow_block_scope, flow_block_ref_ordinal,
    flow_instruction_reference,
    make_flow_instruction_step_ref, make_flow_terminator_step_ref,
    flow_semantic_step_owner, flow_semantic_step_same,
    flow_program_bodies, flow_body_blocks, flow_block_instructions
}

// Exact relation emitted by the sole Core->Flow lowering.  Node ordinals are
// deterministic pre-order positions in that lowering's Core traversal; the
// exact origin/anchor tuple makes drift fail loudly rather than degrading to
// a source name/span lookup.
const CORE_FLOW_NODE_BODY: Int = 0
const CORE_FLOW_NODE_EXPR: Int = 1
const CORE_FLOW_NODE_STMT: Int = 2

pub struct CoreFlowNodeRef {
    owner: ExecutableRef,
    ordinal: Int,
    node_class: Int,
    kind_tag: Int,
    origin: OriginRef,
    anchor_slot: SlotRef?
}

fn make_core_flow_node_ref(
    owner: ExecutableRef, ordinal: Int, node_class: Int, kind_tag: Int,
    origin: OriginRef, anchor_slot: SlotRef?
) -> CoreFlowNodeRef {
    if ordinal < 0 || node_class < CORE_FLOW_NODE_BODY ||
       node_class > CORE_FLOW_NODE_STMT || kind_tag < 0 {
        panic("Flow lowering: invalid Core semantic node reference")
    }
    CoreFlowNodeRef {
        owner: owner, ordinal: ordinal, node_class: node_class,
        kind_tag: kind_tag, origin: origin, anchor_slot: anchor_slot
    }
}
pub fn core_flow_node_owner(value: CoreFlowNodeRef) -> ExecutableRef {
    value.owner
}
pub fn core_flow_node_ordinal(value: CoreFlowNodeRef) -> Int { value.ordinal }
pub fn core_flow_node_class(value: CoreFlowNodeRef) -> Int { value.node_class }
pub fn core_flow_node_kind_tag(value: CoreFlowNodeRef) -> Int { value.kind_tag }
pub fn core_flow_node_origin(value: CoreFlowNodeRef) -> OriginRef { value.origin }
pub fn core_flow_node_anchor_slot(value: CoreFlowNodeRef) -> SlotRef? {
    value.anchor_slot
}

fn core_flow_node_same(left: CoreFlowNodeRef, right: CoreFlowNodeRef) -> Bool {
    if !executable_ref_same(left.owner, right.owner) ||
       left.ordinal != right.ordinal || left.node_class != right.node_class ||
       left.kind_tag != right.kind_tag ||
       !origin_ref_same(left.origin, right.origin) {
        return false
    }
    match (left.anchor_slot, right.anchor_slot) {
        (some(a), some(b)) => slot_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
}

pub struct CoreFlowStepRelation {
    node: CoreFlowNodeRef,
    step: FlowSemanticStepRef,
    role: CoreFlowStepRole
}
pub fn core_flow_step_node(value: CoreFlowStepRelation) -> CoreFlowNodeRef {
    value.node
}
pub fn core_flow_step(value: CoreFlowStepRelation) -> FlowSemanticStepRef {
    value.step
}

const CORE_FLOW_ROLE_EXPR_PRIMARY: Int = 0
const CORE_FLOW_ROLE_STMT_ASSIGN: Int = 1
const CORE_FLOW_ROLE_CONTROL_DISPATCH: Int = 2
const CORE_FLOW_ROLE_BRANCH_MERGE: Int = 3
const CORE_FLOW_ROLE_CONTROL_EXIT: Int = 4
const CORE_FLOW_ROLE_BODY_RETURN: Int = 5
const CORE_FLOW_ROLE_COUNT: Int = 6

pub struct CoreFlowStepRole { tag: Int, ordinal: Int }
fn core_flow_step_role_from_tag(
    tag: Int, ordinal: Int
) -> CoreFlowStepRole {
    if tag < CORE_FLOW_ROLE_EXPR_PRIMARY || tag >= CORE_FLOW_ROLE_COUNT ||
       ordinal < 0 ||
       ((tag == CORE_FLOW_ROLE_EXPR_PRIMARY ||
         tag == CORE_FLOW_ROLE_STMT_ASSIGN ||
         tag == CORE_FLOW_ROLE_BODY_RETURN) && ordinal != 0) {
        panic("Flow lowering: invalid Core/Flow step role")
    }
    CoreFlowStepRole { tag: tag, ordinal: ordinal }
}
fn core_flow_role_expr_primary() -> CoreFlowStepRole {
    core_flow_step_role_from_tag(CORE_FLOW_ROLE_EXPR_PRIMARY, 0)
}
fn core_flow_role_stmt_assign() -> CoreFlowStepRole {
    core_flow_step_role_from_tag(CORE_FLOW_ROLE_STMT_ASSIGN, 0)
}
fn core_flow_role_control_dispatch(ordinal: Int) -> CoreFlowStepRole {
    core_flow_step_role_from_tag(CORE_FLOW_ROLE_CONTROL_DISPATCH, ordinal)
}
fn core_flow_role_branch_merge(ordinal: Int) -> CoreFlowStepRole {
    core_flow_step_role_from_tag(CORE_FLOW_ROLE_BRANCH_MERGE, ordinal)
}
fn core_flow_role_control_exit(ordinal: Int) -> CoreFlowStepRole {
    core_flow_step_role_from_tag(CORE_FLOW_ROLE_CONTROL_EXIT, ordinal)
}
fn core_flow_role_body_return() -> CoreFlowStepRole {
    core_flow_step_role_from_tag(CORE_FLOW_ROLE_BODY_RETURN, 0)
}
pub fn core_flow_step_role(value: CoreFlowStepRelation) -> CoreFlowStepRole {
    value.role
}
pub fn core_flow_step_role_tag(value: CoreFlowStepRole) -> Int {
    core_flow_step_role_from_tag(value.tag, value.ordinal).tag
}
pub fn core_flow_step_role_ordinal(value: CoreFlowStepRole) -> Int {
    core_flow_step_role_from_tag(value.tag, value.ordinal).ordinal
}
pub fn core_flow_step_role_is_expr_primary(value: CoreFlowStepRole) -> Bool {
    value.tag == CORE_FLOW_ROLE_EXPR_PRIMARY
}
pub fn core_flow_step_role_is_stmt_assign(value: CoreFlowStepRole) -> Bool {
    value.tag == CORE_FLOW_ROLE_STMT_ASSIGN
}
pub fn core_flow_step_role_is_control_dispatch(value: CoreFlowStepRole) -> Bool {
    value.tag == CORE_FLOW_ROLE_CONTROL_DISPATCH
}
pub fn core_flow_step_role_is_branch_merge(value: CoreFlowStepRole) -> Bool {
    value.tag == CORE_FLOW_ROLE_BRANCH_MERGE
}
pub fn core_flow_step_role_is_control_exit(value: CoreFlowStepRole) -> Bool {
    value.tag == CORE_FLOW_ROLE_CONTROL_EXIT
}
pub fn core_flow_step_role_is_body_return(value: CoreFlowStepRole) -> Bool {
    value.tag == CORE_FLOW_ROLE_BODY_RETURN
}

pub struct CoreFlowStepMap {
    nodes: List<CoreFlowNodeRef>,
    relations: List<CoreFlowStepRelation>
}
pub fn core_flow_step_map_node_count(value: CoreFlowStepMap) -> Int {
    value.nodes.len()
}
pub fn core_flow_step_map_nodes(
    value: CoreFlowStepMap
) -> List<CoreFlowNodeRef> {
    value.nodes.map(fn(node) { node })
}
pub fn core_flow_step_map_relations(
    value: CoreFlowStepMap
) -> List<CoreFlowStepRelation> {
    value.relations.map(fn(relation) {
        CoreFlowStepRelation {
            node: relation.node, step: relation.step, role: relation.role
        }
    })
}

fn validate_core_flow_step_map(
    program: FlowProgram, value: CoreFlowStepMap
) {
    if value.nodes.len() <= 0 {
        panic("Flow lowering: Core semantic node census is empty")
    }
    let mut node_index = 0
    while node_index < value.nodes.len() {
        let node = value.nodes.get(node_index).unwrap()
        if node.ordinal != node_index {
            panic("Flow lowering: Core semantic node order differs")
        }
        node_index = node_index + 1
    }
    let mut expected: List<FlowSemanticStepRef> = []
    for body in flow_program_bodies(program) {
        for block in flow_body_blocks(body) {
            for instruction in flow_block_instructions(block) {
                expected.push(make_flow_instruction_step_ref(
                    flow_instruction_reference(instruction)))
            }
            expected.push(make_flow_terminator_step_ref(
                flow_block_reference(block)))
        }
    }
    if expected.len() != value.relations.len() {
        panic("Flow lowering: Core/Flow semantic step census differs")
    }
    let mut relation_index = 0
    while relation_index < value.relations.len() {
        let relation = value.relations.get(relation_index).unwrap()
        if relation.node.ordinal < 0 ||
           relation.node.ordinal >= value.nodes.len() ||
           !core_flow_node_same(
                relation.node,
                value.nodes.get(relation.node.ordinal).unwrap()) ||
           !executable_ref_same(
                relation.node.owner, flow_semantic_step_owner(relation.step)) {
            panic("Flow lowering: semantic step crosses Core node owner")
        }
        let role_tag = core_flow_step_role_tag(relation.role)
        let allowed = if relation.node.node_class == CORE_FLOW_NODE_BODY {
            role_tag == CORE_FLOW_ROLE_BODY_RETURN
        } else if relation.node.node_class == CORE_FLOW_NODE_EXPR {
            if relation.node.kind_tag <= 11 || relation.node.kind_tag == 17 {
                role_tag == CORE_FLOW_ROLE_EXPR_PRIMARY
            } else {
                role_tag == CORE_FLOW_ROLE_CONTROL_DISPATCH ||
                role_tag == CORE_FLOW_ROLE_BRANCH_MERGE ||
                role_tag == CORE_FLOW_ROLE_CONTROL_EXIT
            }
        } else if relation.node.node_class == CORE_FLOW_NODE_STMT {
            if relation.node.kind_tag == 0 || relation.node.kind_tag == 1 {
                role_tag == CORE_FLOW_ROLE_STMT_ASSIGN
            } else if relation.node.kind_tag == 3 {
                role_tag == CORE_FLOW_ROLE_CONTROL_DISPATCH ||
                role_tag == CORE_FLOW_ROLE_CONTROL_EXIT
            } else if relation.node.kind_tag == 4 ||
                      relation.node.kind_tag == 5 ||
                      relation.node.kind_tag == 6 {
                role_tag == CORE_FLOW_ROLE_CONTROL_EXIT
            } else {
                false
            }
        } else {
            false
        }
        if !allowed {
            panic("Flow lowering: Core node has an invalid step role")
        }
        let mut duplicate_index = relation_index + 1
        while duplicate_index < value.relations.len() {
            let duplicate = value.relations.get(duplicate_index).unwrap()
            if flow_semantic_step_same(relation.step, duplicate.step) {
                panic("Flow lowering: Flow semantic step relation repeats")
            }
            if core_flow_node_same(relation.node, duplicate.node) &&
               core_flow_step_role_tag(relation.role) ==
                    core_flow_step_role_tag(duplicate.role) &&
               core_flow_step_role_ordinal(relation.role) ==
                    core_flow_step_role_ordinal(duplicate.role) {
                panic("Flow lowering: Core node step role repeats")
            }
            duplicate_index = duplicate_index + 1
        }
        let mut matches = 0
        for step in expected {
            if flow_semantic_step_same(step, relation.step) {
                matches = matches + 1
            }
        }
        if matches != 1 {
            panic("Flow lowering: semantic step relation is not total")
        }
        relation_index = relation_index + 1
    }
}

pub struct FlowLoweringResult {
    program: FlowProgram,
    step_map: CoreFlowStepMap
}
fn make_flow_lowering_result(
    program: FlowProgram, step_map: CoreFlowStepMap
) -> FlowLoweringResult {
    validate_core_flow_step_map(program, step_map)
    FlowLoweringResult { program: program, step_map: step_map }
}
pub fn flow_lowering_program(value: FlowLoweringResult) -> FlowProgram {
    value.program
}
pub fn flow_lowering_step_map(value: FlowLoweringResult) -> CoreFlowStepMap {
    value.step_map
}

struct FlowBlockDraft {
    reference: FlowBlockRef,
    origin: OriginRef,
    scope: FlowScopeRef,
    instructions: List<FlowInstruction>,
    terminator: FlowTerminator?
}

struct FlowLowerCtx {
    owner: ExecutableRef,
    scopes: List<FlowScope>,
    binders: List<BinderEntry>,
    slots: List<FlowSlot>,
    drafts: List<FlowBlockDraft>,
    current: Int,
    callables: List<CoreCallableContract>,
    core_body: CoreBody,
    active_node: CoreFlowNodeRef?,
    next_node_ordinal: Int,
    nodes: List<CoreFlowNodeRef>,
    step_relations: List<CoreFlowStepRelation>
}

fn enter_core_node(
    mut ctx: FlowLowerCtx, node_class: Int, kind_tag: Int,
    origin: OriginRef, anchor_slot: SlotRef?
) -> CoreFlowNodeRef? {
    let previous = ctx.active_node
    let node = make_core_flow_node_ref(
        ctx.owner, ctx.next_node_ordinal, node_class, kind_tag,
        origin, anchor_slot)
    ctx.next_node_ordinal = ctx.next_node_ordinal + 1
    ctx.nodes.push(node)
    ctx.active_node = some(node)
    previous
}
fn restore_core_node(mut ctx: FlowLowerCtx, previous: CoreFlowNodeRef?) {
    ctx.active_node = previous
}

fn executable_path_owner(value: ExecutableRef) -> PathOwnerRef {
    if executable_ref_is_named(value) {
        path_owner_for_symbol(executable_ref_named_symbol(value))
    } else {
        path_ref_owner(executable_ref_anonymous_path(value))
    }
}

fn executable_child_prefix(value: ExecutableRef) -> List<Str> {
    if executable_ref_is_named(value) {
        []
    } else {
        path_ref_normalized_child_path(executable_ref_anonymous_path(value))
    }
}

fn admin_site(
    ctx: FlowLowerCtx, label: Str, ordinal: Int, role_tag: Int
) -> PathRef {
    let mut path = executable_child_prefix(ctx.owner)
    path.push("$flow")
    path.push(label)
    path.push(ordinal.to_str())
    let role = if role_tag == 0 { path_role_parameter() }
        else if role_tag == 1 { path_role_result() }
        else if role_tag == 2 { path_role_child() }
        else { path_role_synthetic() }
    make_path_ref(executable_path_owner(ctx.owner), path, role)
}

fn new_child_scope(
    mut ctx: FlowLowerCtx, parent: FlowScopeRef
) -> FlowScopeRef {
    let reference = make_flow_scope_ref(ctx.owner, ctx.scopes.len())
    ctx.scopes.push(make_flow_child_scope(reference, parent))
    reference
}

fn scope_slot_count(ctx: FlowLowerCtx, scope: FlowScopeRef) -> Int {
    let mut count = 0
    for slot in ctx.slots {
        if flow_scope_ref_same(flow_slot_scope(slot), scope) {
            count = count + 1
        }
    }
    count
}

fn parameter_ordinal(body: CoreBody, target: SlotRef) -> Int? {
    let mut ordinal = 0
    for slot in core_body_parameter_slots(body) {
        if slot_ref_same(slot, target) { return some(ordinal) }
        ordinal = ordinal + 1
    }
    none
}

fn core_binder_for(body: CoreBody, target: SlotRef) -> CoreBinder {
    for binder in core_body_binders(body) {
        if slot_ref_same(core_binder_reference(binder), target) {
            return binder
        }
    }
    panic("Flow lowering: Core semantic binder is absent")
}

fn flow_slot_exists(ctx: FlowLowerCtx, target: SlotRef) -> Bool {
    for slot in ctx.slots {
        if slot_ref_same(flow_slot_reference(slot), target) { return true }
    }
    false
}

fn activate_core_binder(
    mut ctx: FlowLowerCtx, target: SlotRef, scope: FlowScopeRef
) {
    if flow_slot_exists(ctx, target) { return }
    let binder = core_binder_for(ctx.core_body, target)
    let reference = core_binder_reference(binder)
    let kind = core_binder_kind(binder)
    let site = core_binder_site(binder)
    let entry = if slot_ref_is_source(reference) {
        make_source_binder_entry(reference, ctx.owner, kind, site)
    } else {
        make_synthetic_binder_entry(reference, ctx.owner, kind, site)
    }
    let ordinal = parameter_ordinal(ctx.core_body, reference)
    let storage = if ordinal.is_some() {
        flow_storage_parameter()
    } else { flow_storage_local() }
    let initial = if ordinal.is_some() {
        flow_initial_slot_live()
    } else {
        flow_initial_slot_empty()
    }
    ctx.binders.push(entry)
    ctx.slots.push(make_flow_slot(
        reference, core_type_ref_to_flow(core_binder_type(binder)), scope,
        scope_slot_count(ctx, scope), initial, storage,
        core_binder_storage_contract(binder), ordinal))
}

fn new_admin_slot(
    mut ctx: FlowLowerCtx, ty: FlowTypeRef, scope: FlowScopeRef,
    kind: BinderKind, label: Str, role_tag: Int,
    storage: FlowStorageClass, initial: FlowInitialSlotState
) -> SlotRef {
    let site = admin_site(ctx, label, ctx.slots.len(), role_tag)
    let reference = make_synthetic_slot_ref(site)
    ctx.binders.push(make_synthetic_binder_entry(
        reference, ctx.owner, kind, site))
    ctx.slots.push(make_flow_slot(
        reference, ty, scope, scope_slot_count(ctx, scope), initial,
        storage, flow_own_storage(), none))
    reference
}
fn record_current_step(
    mut ctx: FlowLowerCtx, step: FlowSemanticStepRef,
    role: CoreFlowStepRole
) {
    let node = match ctx.active_node {
        some(value) => value,
        none => panic("Flow lowering: semantic step has no Core node")
    }
    if !executable_ref_same(node.owner, flow_semantic_step_owner(step)) {
        panic("Flow lowering: semantic step/Core owner differs")
    }
    ctx.step_relations.push(CoreFlowStepRelation {
        node: node, step: step, role: role
    })
}

fn new_draft(
    mut ctx: FlowLowerCtx, origin: OriginRef, scope: FlowScopeRef
) -> FlowBlockRef {
    let reference = make_flow_block_ref(ctx.owner, ctx.drafts.len())
    ctx.drafts.push(FlowBlockDraft {
        reference: reference, origin: origin, scope: scope,
        instructions: [], terminator: none
    })
    reference
}

fn current_draft(ctx: FlowLowerCtx) -> FlowBlockDraft {
    ctx.drafts.get(ctx.current).unwrap()
}
fn current_ref(ctx: FlowLowerCtx) -> FlowBlockRef {
    current_draft(ctx).reference
}
fn set_current(mut ctx: FlowLowerCtx, reference: FlowBlockRef) {
    ctx.current = flow_block_ref_ordinal(reference)
}
fn is_terminated(ctx: FlowLowerCtx) -> Bool {
    current_draft(ctx).terminator.is_some()
}
fn emit_instruction(
    mut ctx: FlowLowerCtx, instruction: FlowInstruction,
    role: CoreFlowStepRole
) {
    let mut draft = current_draft(ctx)
    if draft.terminator.is_some() {
        panic("Flow lowering: instruction after terminator")
    }
    record_current_step(ctx, make_flow_instruction_step_ref(
        flow_instruction_reference(instruction)), role)
    draft.instructions.push(instruction)
    ctx.drafts.set(ctx.current, draft)
}
fn next_instruction_ref(ctx: FlowLowerCtx) -> FlowInstructionRef {
    let draft = current_draft(ctx)
    make_flow_instruction_ref(
        ctx.owner, flow_block_ref_ordinal(draft.reference),
        draft.instructions.len())
}
fn terminate(
    mut ctx: FlowLowerCtx, value: FlowTerminator,
    role: CoreFlowStepRole
) {
    let mut draft = current_draft(ctx)
    if draft.terminator.is_some() {
        panic("Flow lowering: block terminator replay")
    }
    record_current_step(
        ctx, make_flow_terminator_step_ref(draft.reference), role)
    draft.terminator = some(value)
    ctx.drafts.set(ctx.current, draft)
}

fn scope_for(ctx: FlowLowerCtx, reference: FlowScopeRef) -> FlowScope {
    for scope in ctx.scopes {
        if flow_scope_ref_same(flow_scope_reference(scope), reference) {
            return scope
        }
    }
    panic("Flow lowering: scope is absent")
}
fn scope_lineage(ctx: FlowLowerCtx, start: FlowScopeRef) -> List<FlowScopeRef> {
    let mut result: List<FlowScopeRef> = []
    let mut current: FlowScopeRef? = some(start)
    while current.is_some() {
        let reference = current.unwrap()
        result.push(reference)
        let scope = scope_for(ctx, reference)
        current = if flow_scope_has_parent(scope) {
            some(flow_scope_parent(scope))
        } else {
            none
        }
    }
    result
}
fn successor_to(ctx: FlowLowerCtx, target: FlowBlockRef) -> FlowSuccessor {
    let from_scope = current_draft(ctx).scope
    let target_scope = ctx.drafts.get(flow_block_ref_ordinal(target)).unwrap().scope
    let from_lineage = scope_lineage(ctx, from_scope)
    let target_lineage = scope_lineage(ctx, target_scope)
    let mut from_lca = 0
    let mut target_lca = 0
    let mut found = false
    let mut left = 0
    while left < from_lineage.len() && !found {
        let mut right = 0
        while right < target_lineage.len() && !found {
            if flow_scope_ref_same(
                    from_lineage.get(left).unwrap(),
                    target_lineage.get(right).unwrap()) {
                from_lca = left
                target_lca = right
                found = true
            }
            right = right + 1
        }
        left = left + 1
    }
    if !found { panic("Flow lowering: body scopes have no common root") }
    let mut exited: List<FlowScopeRef> = []
    let mut exit_index = 0
    while exit_index < from_lca {
        exited.push(from_lineage.get(exit_index).unwrap())
        exit_index = exit_index + 1
    }
    let mut entered: List<FlowScopeRef> = []
    let mut enter_index = target_lca
    while enter_index > 0 {
        enter_index = enter_index - 1
        entered.push(target_lineage.get(enter_index).unwrap())
    }
    make_flow_successor(target, exited, entered)
}
fn all_exited_scopes(ctx: FlowLowerCtx) -> List<FlowScopeRef> {
    scope_lineage(ctx, current_draft(ctx).scope)
}

fn callable_for(
    ctx: FlowLowerCtx, reference: ExecutableRef
) -> CoreCallableContract {
    for callable in ctx.callables {
        if executable_ref_same(core_callable_reference(callable), reference) {
            return callable
        }
    }
    panic("Flow lowering: exact Core callable is absent")
}
fn frozen_slot_type_at(ctx: FlowLowerCtx, slot: SlotRef) -> FlowTypeRef {
    for value in ctx.slots {
        if slot_ref_same(flow_slot_reference(value), slot) {
            return flow_slot_type(value)
        }
    }
    panic("Flow lowering: Core slot type is absent")
}

fn flow_primitive(tag: Int) -> FlowPrimitiveOp {
    if tag == 0 { return flow_primitive_add() }
    if tag == 1 { return flow_primitive_sub() }
    if tag == 2 { return flow_primitive_mul() }
    if tag == 3 { return flow_primitive_div() }
    if tag == 4 { return flow_primitive_mod() }
    if tag == 5 { return flow_primitive_negate() }
    if tag == 6 { return flow_primitive_not() }
    if tag == 7 { return flow_primitive_lt() }
    if tag == 8 { return flow_primitive_le() }
    if tag == 9 { return flow_primitive_gt() }
    if tag == 10 { return flow_primitive_ge() }
    panic("Flow lowering: unknown Core primitive")
}

fn flow_evidence(values: List<CoreEvidenceRef>) -> List<FlowEvidenceRef> {
    let mut result: List<FlowEvidenceRef> = []
    for value in values {
        result.push(if core_evidence_is_local(value) {
            make_flow_local_evidence(core_evidence_local(value))
        } else if core_evidence_is_dict(value) {
            make_flow_dict_evidence(core_evidence_dict(value))
        } else {
            make_flow_callable_evidence(core_evidence_callable(value))
        })
    }
    result
}

fn flow_call_target(value: CoreCalleeRef) -> FlowCallTarget {
    let contract = core_callee_contract(value)
    let kind = core_callee_kind_tag(value)
    if kind == 0 {
        make_direct_flow_call_target(core_callee_direct(value), contract)
    } else if kind == 1 {
        make_local_flow_call_target(
            core_callee_local(value), contract)
    } else if kind == 2 {
        make_dynamic_flow_call_target(
            core_callee_dynamic(value), contract)
    } else {
        panic("Flow lowering: unknown Core callee form")
    }
}

fn flow_field(value: CoreFieldRef) -> FlowFieldIdentity {
    let kind = core_field_ref_kind_tag(value)
    if kind == 0 {
        make_nominal_flow_field_identity(core_field_ref_nominal(value))
    } else if kind == 2 {
        make_path_flow_field_identity(core_field_ref_record_path(value))
    } else if kind == 3 {
        make_variant_flow_field_identity(core_field_ref_variant(value))
    } else {
        panic("Flow lowering: tuple field has no named field identity")
    }
}

fn lower_flow_place(
    mut ctx: FlowLowerCtx, value: CorePlaceRef,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) -> FlowPlaceRef {
    if core_place_is_slot(value) {
        if !flow_slot_exists(ctx, core_place_slot(value)) {
            panic("Flow lowering: assignment target is not active")
        }
        return make_flow_slot_place(core_place_slot(value))
    }
    let base = lower_expr(
        ctx, core_place_base(value), continue_target, break_target)
    let base_type = frozen_slot_type_at(ctx, base)
    let value_type = core_type_ref_to_flow(core_place_value_type(value))
    match core_place_field(value) {
        some(field) => {
            let kind = core_field_ref_kind_tag(field)
            let contract = if kind == 0 {
                make_nominal_flow_projection_contract(
                    core_field_ref_nominal(field), base_type, value_type,
                    flow_semantic_role_mutate(), false)
            } else if kind == 1 {
                make_tuple_flow_projection_contract(
                    core_field_ref_tuple_index(field), base_type, value_type,
                    flow_semantic_role_mutate(), false)
            } else if kind == 2 {
                make_structural_flow_projection_contract(
                    core_field_ref_record_path(field), base_type, value_type,
                    flow_semantic_role_mutate(), false)
            } else {
                make_variant_flow_projection_contract(
                    core_field_ref_variant(field), base_type, value_type,
                    flow_semantic_role_mutate(), false)
            }
            make_flow_project_place(base, some(contract), none, value_type)
        },
        none => {
            let index = match core_place_evaluated_index(value) {
                some(expr) => some(lower_expr(
                    ctx, expr, continue_target, break_target)),
                none => none
            }
            make_flow_project_place(base, none, index, value_type)
        }
    }
}

fn activate_pattern_binders(
    mut ctx: FlowLowerCtx, pattern: CorePattern, scope: FlowScopeRef
) {
    let kind = core_pattern_kind_tag(pattern)
    if kind == 1 {
        activate_core_binder(ctx, core_pattern_binding(pattern), scope)
    } else if kind == 3 {
        for element in core_pattern_elements(pattern) {
            activate_pattern_binders(ctx, element, scope)
        }
    } else if kind == 4 || kind == 5 {
        for field in core_pattern_fields(pattern) {
            activate_pattern_binders(
                ctx, core_pattern_field_pattern(field), scope)
        }
    }
}

fn flow_pattern(value: CorePattern) -> FlowPatternContract {
    let ty = core_type_ref_to_flow(core_pattern_type(value))
    let kind = core_pattern_kind_tag(value)
    if kind == 0 { return make_flow_wildcard_pattern(ty) }
    if kind == 1 {
        return make_flow_binding_pattern(ty, core_pattern_binding(value))
    }
    if kind == 2 {
        let literal = core_pattern_literal(value)
        let literal_kind = core_literal_kind_tag(literal)
        let flow_literal = if literal_kind == 0 {
            make_flow_pattern_int(core_literal_int(literal))
        } else if literal_kind == 1 {
            make_flow_pattern_float(core_literal_float(literal))
        } else if literal_kind == 2 {
            make_flow_pattern_str(core_literal_str(literal))
        } else if literal_kind == 3 {
            make_flow_pattern_bool(core_literal_bool(literal))
        } else {
            make_flow_pattern_unit()
        }
        return make_flow_literal_pattern(ty, flow_literal)
    }
    if kind == 3 {
        return make_flow_tuple_pattern(
            ty, core_pattern_elements(value).map(fn(item) {
                flow_pattern(item)
            }))
    }
    let fields = core_pattern_fields(value).map(fn(item) {
        make_flow_pattern_field(
            flow_field(core_pattern_field_ref(item)),
            flow_pattern(core_pattern_field_pattern(item)))
    })
    if kind == 4 {
        make_flow_struct_pattern(
            ty, registered_nominal_ref_symbol(
                core_pattern_struct_owner(value)), fields)
    } else if kind == 5 {
        make_flow_variant_pattern(ty, core_pattern_variant(value), fields)
    } else {
        panic("Flow lowering: unknown Core pattern")
    }
}

fn repeated_role(count: Int, role: FlowSemanticRole) -> List<FlowSemanticRole> {
    let mut result: List<FlowSemanticRole> = []
    let mut index = 0
    while index < count { result.push(role); index = index + 1 }
    result
}

fn emit_simple_expr(
    mut ctx: FlowLowerCtx, expr: CoreExpr, result: SlotRef,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) -> Bool {
    let kind = core_expr_kind_tag(expr)
    let reference = next_instruction_ref(ctx)
    let origin = core_expr_origin(expr)
    let result_type = core_type_ref_to_flow(core_expr_type(expr))
    if kind == 0 {
        let literal = core_expr_literal(expr)
        let literal_kind = core_literal_kind_tag(literal)
        let contract = if literal_kind == 0 {
            make_flow_int_literal_contract(core_literal_int(literal), result_type)
        } else if literal_kind == 1 {
            make_flow_float_literal_contract(core_literal_float(literal), result_type)
        } else if literal_kind == 2 {
            make_flow_str_literal_contract(core_literal_str(literal), result_type)
        } else if literal_kind == 3 {
            make_flow_bool_literal_contract(core_literal_bool(literal), result_type)
        } else {
            make_flow_unit_literal_contract(result_type)
        }
        emit_instruction(ctx, make_flow_initialize(
            reference, origin, contract, [], result),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 1 {
        let _ = frozen_slot_type_at(ctx, core_expr_read_source(expr))
        emit_instruction(ctx, make_flow_read(
            reference, origin, core_expr_read_source(expr), result),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 2 {
        let mut operands: List<SlotRef> = []
        for operand in core_expr_primitive_operands(expr) {
            operands.push(lower_expr(
                ctx, operand, continue_target, break_target))
        }
        let input_types = operands.map(fn(slot) {
            frozen_slot_type_at(ctx, slot)
        })
        let contract = make_flow_primitive_contract(
            flow_primitive(core_primitive_op_tag(
                core_expr_primitive_operation(expr))),
            input_types, repeated_role(operands.len(), flow_semantic_role_read()),
            result_type, flow_semantic_role_read(),
            make_fresh_flow_value_origin())
        emit_instruction(ctx, make_flow_initialize(
            reference, origin, contract, operands, result),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 3 || kind == 4 {
        let callee = core_expr_call_callee(expr)
        let mut arguments: List<SlotRef> = []
        if kind == 4 {
            arguments.push(lower_expr(
                ctx, core_expr_method_receiver(expr),
                continue_target, break_target))
        }
        for argument in core_expr_call_arguments(expr) {
            arguments.push(lower_expr(
                ctx, argument, continue_target, break_target))
        }
        let mut evidence = flow_evidence(core_expr_call_evidence(expr))
        if kind == 4 {
            let method = core_expr_method_ref(expr)
            if method_call_ref_is_bound(method) {
                let mut exact = [make_flow_dict_evidence(
                    method_call_ref_bound_evidence(method))]
                for item in evidence { exact.push(item) }
                evidence = exact
            }
        }
        emit_instruction(ctx, make_flow_call(
            reference, origin, flow_call_target(callee), arguments,
            evidence, some(result)), core_flow_role_expr_primary())
        return true
    }
    if kind == 5 {
        let mut arguments: List<SlotRef> = []
        for argument in core_expr_call_arguments(expr) {
            arguments.push(lower_expr(
                ctx, argument, continue_target, break_target))
        }
        let callable = callable_for(
            ctx, effect_operation_ref_callable(
                core_expr_effect_operation(expr)))
        emit_instruction(ctx, make_flow_call(
            reference, origin,
            make_direct_flow_call_target(
                core_callable_reference(callable),
                core_callable_semantic_contract(callable)),
            arguments,
            flow_evidence(core_expr_call_evidence(expr)), some(result)),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 6 {
        let mut arguments: List<SlotRef> = []
        for argument in core_expr_call_arguments(expr) {
            arguments.push(lower_expr(
                ctx, argument, continue_target, break_target))
        }
        let callable = callable_for(
            ctx, system_host_callable_executable(core_expr_system_host(expr)))
        emit_instruction(ctx, make_flow_call(
            reference, origin,
            make_direct_flow_call_target(
                core_callable_reference(callable),
                core_callable_semantic_contract(callable)),
            arguments, [], some(result)),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 7 || kind == 8 {
        let executable = if kind == 7 {
            core_expr_dict_constructor(expr)
        } else {
            core_expr_dict_project_method(expr)
        }
        let callable = callable_for(ctx, executable)
        let arguments: List<SlotRef> = if kind == 7 { [] } else {
            [lower_expr(ctx, core_expr_dict_project_dictionary(expr),
                continue_target, break_target)]
        }
        emit_instruction(ctx, make_flow_call(
            reference, origin,
            make_direct_flow_call_target(
                executable, core_callable_semantic_contract(callable)),
            arguments,
            if kind == 7 {
                flow_evidence(core_expr_call_evidence(expr))
            } else { [] }, some(result)), core_flow_role_expr_primary())
        return true
    }
    if kind == 9 {
        let base = lower_expr(
            ctx, core_expr_project_base(expr),
            continue_target, break_target)
        let field = core_expr_project_field(expr)
        let base_type = frozen_slot_type_at(ctx, base)
        let partial = core_expr_project_is_partial(expr)
        let field_kind = core_field_ref_kind_tag(field)
        let contract = if field_kind == 0 {
            make_nominal_flow_projection_contract(
                core_field_ref_nominal(field), base_type, result_type,
                flow_semantic_role_read(), partial)
        } else if field_kind == 1 {
            make_tuple_flow_projection_contract(
                core_field_ref_tuple_index(field), base_type, result_type,
                flow_semantic_role_read(), partial)
        } else if field_kind == 2 {
            make_structural_flow_projection_contract(
                core_field_ref_record_path(field), base_type, result_type,
                flow_semantic_role_read(), partial)
        } else {
            make_variant_flow_projection_contract(
                core_field_ref_variant(field), base_type, result_type,
                flow_semantic_role_read(), partial)
        }
        emit_instruction(ctx, make_flow_project(
            reference, origin, contract, base, result),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 10 {
        let constructor = core_expr_constructor(expr)
        let fields = core_expr_constructor_fields(expr)
        let mut inputs: List<SlotRef> = []
        for field in fields {
            inputs.push(lower_expr(
                ctx, core_field_value_expr(field),
                continue_target, break_target))
        }
        let input_types = inputs.map(fn(slot) { frozen_slot_type_at(ctx, slot) })
        let roles = repeated_role(inputs.len(), flow_semantic_role_consume())
        let constructor_kind = core_constructor_kind_tag(constructor)
        let contract = match core_constructor_executable(constructor) {
            some(executable) => {
                let callable = callable_for(ctx, executable)
                let callable_contract = core_callable_semantic_contract(callable)
                make_flow_constructor_contract(
                    executable,
                    flow_call_contract_parameter_types(callable_contract),
                    flow_call_contract_parameter_roles(callable_contract),
                    result_type,
                    flow_call_contract_result_role(callable_contract),
                    flow_call_contract_result_origin(callable_contract))
            },
            none => if constructor_kind == 2 {
                make_flow_tuple_aggregate_contract(
                    inputs.len(), input_types, roles, result_type)
            } else if constructor_kind == 3 {
                make_flow_record_aggregate_contract(
                    inputs.len(), input_types, roles, result_type)
            } else {
                panic("Flow lowering: nominal constructor lacks executable")
            }
        }
        emit_instruction(ctx, make_flow_initialize(
            reference, origin, contract, inputs, result),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 11 {
        let executable = core_expr_lambda_executable(expr)
        let _ = callable_for(ctx, executable)
        let captures = core_expr_lambda_captures(expr).map(fn(capture) {
            core_capture_source(capture)
        })
        let input_types = captures.map(fn(slot) { frozen_slot_type_at(ctx, slot) })
        let contract = make_flow_closure_contract(
            executable, input_types,
            repeated_role(captures.len(), flow_semantic_role_read()),
            result_type)
        emit_instruction(ctx, make_flow_initialize(
            reference, origin, contract, captures, result),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 17 {
        let executable = core_expr_callable_executable(expr)
        let _ = callable_for(ctx, executable)
        emit_instruction(ctx, make_flow_initialize(
            reference, origin,
            make_flow_callable_value_contract(executable, result_type),
            [], result), core_flow_role_expr_primary())
        return true
    }
    false
}

fn terminate_goto(
    mut ctx: FlowLowerCtx, target: FlowBlockRef, origin: OriginRef,
    role: CoreFlowStepRole
) {
    if !is_terminated(ctx) {
        terminate(ctx, make_flow_goto(origin, successor_to(ctx, target)), role)
    }
}

fn merge_block_tail(
    mut ctx: FlowLowerCtx, tail: SlotRef?,
    result: SlotRef, origin: OriginRef, branch_ordinal: Int
) {
    match tail {
        some(source) => {
            if !slot_ref_same(source, result) {
                emit_instruction(ctx, make_flow_assign(
                    next_instruction_ref(ctx), origin, source,
                    make_flow_slot_place(result)),
                    core_flow_role_branch_merge(branch_ordinal))
            }
        },
        none => emit_instruction(ctx, make_flow_initialize(
            next_instruction_ref(ctx), origin,
            make_flow_unit_literal_contract(frozen_slot_type_at(ctx, result)),
            [], result), core_flow_role_branch_merge(branch_ordinal))
    }
}

fn lower_block_expression(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    result: SlotRef,
    block: CoreBlock,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let parent_scope = current_draft(ctx).scope
    let block_scope = new_child_scope(ctx, parent_scope)
    let entry = new_draft(ctx, core_block_origin(block), block_scope)
    let join = new_draft(ctx, core_expr_origin(expr), parent_scope)
    terminate_goto(ctx, entry, core_expr_origin(expr),
        core_flow_role_control_dispatch(0))
    set_current(ctx, entry)
    let tail = lower_core_block(ctx, block, continue_target, break_target)
    if !is_terminated(ctx) {
        merge_block_tail(ctx, tail, result, core_expr_origin(expr), 0)
        terminate_goto(ctx, join, core_expr_origin(expr),
            core_flow_role_control_exit(0))
    }
    set_current(ctx, join)
}

fn lower_if_expression(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    result: SlotRef,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let origin = core_expr_origin(expr)
    let parent_scope = current_draft(ctx).scope
    let then_block = core_expr_then_block(expr)
    let else_block = core_expr_else_block(expr)
    let condition = lower_expr(
        ctx, core_expr_condition(expr), continue_target, break_target)
    let then_scope = new_child_scope(ctx, parent_scope)
    let else_scope = new_child_scope(ctx, parent_scope)
    let then_entry = new_draft(ctx, core_block_origin(then_block), then_scope)
    let else_entry = new_draft(ctx, core_block_origin(else_block), else_scope)
    let join = new_draft(ctx, origin, parent_scope)
    terminate(ctx, make_flow_branch(
        origin, condition,
        successor_to(ctx, then_entry), successor_to(ctx, else_entry)),
        core_flow_role_control_dispatch(0))
    set_current(ctx, then_entry)
    let then_tail = lower_core_block(
        ctx, then_block, continue_target, break_target)
    if !is_terminated(ctx) {
        merge_block_tail(ctx, then_tail, result, origin, 0)
        terminate_goto(ctx, join, origin, core_flow_role_control_exit(0))
    }
    set_current(ctx, else_entry)
    let else_tail = lower_core_block(
        ctx, else_block, continue_target, break_target)
    if !is_terminated(ctx) {
        merge_block_tail(ctx, else_tail, result, origin, 1)
        terminate_goto(ctx, join, origin, core_flow_role_control_exit(1))
    }
    set_current(ctx, join)
}

fn lower_match_arms(
    mut ctx: FlowLowerCtx, scrutinee: SlotRef,
    arms: List<CoreMatchArm>, result: SlotRef,
    origin: OriginRef, join: FlowBlockRef,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?,
    arm_base: Int
) {
    let parent_scope = current_draft(ctx).scope
    let final_unmatched = new_draft(ctx, origin, parent_scope)
    let mut tests: List<FlowBlockRef> = [current_ref(ctx)]
    let mut test_index = 1
    while test_index < arms.len() {
        tests.push(new_draft(ctx, origin, parent_scope))
        test_index = test_index + 1
    }
    let mut index = 0
    while index < arms.len() {
        set_current(ctx, tests.get(index).unwrap())
        let arm = arms.get(index).unwrap()
        let arm_body = core_match_arm_body(arm)
        let arm_scope = new_child_scope(ctx, parent_scope)
        activate_pattern_binders(
            ctx, core_match_arm_pattern(arm), arm_scope)
        let candidate = new_draft(
            ctx, core_match_arm_origin(arm), arm_scope)
        let next = if index + 1 < tests.len() {
            tests.get(index + 1).unwrap()
        } else {
            final_unmatched
        }
        terminate(ctx, make_flow_pattern_branch(
            core_match_arm_origin(arm), scrutinee,
            flow_pattern(core_match_arm_pattern(arm)),
            successor_to(ctx, candidate), successor_to(ctx, next)),
            core_flow_role_control_dispatch(arm_base + index * 2))
        set_current(ctx, candidate)
        match core_match_arm_guard(arm) {
            some(guard) => {
                let guard_slot = lower_expr(
                    ctx, guard, continue_target, break_target)
                let guarded_body = new_draft(
                    ctx, core_block_origin(arm_body), arm_scope)
                terminate(ctx, make_flow_branch(
                    core_expr_origin(guard), guard_slot,
                    successor_to(ctx, guarded_body), successor_to(ctx, next)),
                    core_flow_role_control_dispatch(
                        arm_base + index * 2 + 1))
                set_current(ctx, guarded_body)
            },
            none => {}
        }
        let tail = lower_core_block(
            ctx, arm_body, continue_target, break_target)
        if !is_terminated(ctx) {
            merge_block_tail(ctx, tail, result, origin, arm_base + index)
            terminate_goto(ctx, join, origin,
                core_flow_role_control_exit(arm_base + index))
        }
        index = index + 1
    }
    set_current(ctx, final_unmatched)
    terminate(ctx, make_flow_unreachable(origin, all_exited_scopes(ctx)),
        core_flow_role_control_exit(arm_base + arms.len()))
}

fn lower_match_expression(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    result: SlotRef,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let origin = core_expr_origin(expr)
    let scrutinee = lower_expr(
        ctx, core_expr_scrutinee(expr), continue_target, break_target)
    let join = new_draft(ctx, origin, current_draft(ctx).scope)
    lower_match_arms(
        ctx, scrutinee, core_expr_match_arms(expr),
        result, origin, join,
        continue_target, break_target, 0)
    set_current(ctx, join)
}

fn lower_try_expression(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    result: SlotRef,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let origin = core_expr_origin(expr)
    let parent_scope = current_draft(ctx).scope
    let protected = core_expr_try_body(expr)
    let protected_scope = new_child_scope(ctx, parent_scope)
    let caught_scope = new_child_scope(ctx, parent_scope)
    let protected_entry = new_draft(
        ctx, core_block_origin(protected), protected_scope)
    let caught_entry = new_draft(ctx, origin, caught_scope)
    let join = new_draft(ctx, origin, parent_scope)
    activate_core_binder(ctx, core_expr_error_slot(expr), caught_scope)
    terminate(ctx, make_flow_try(
        origin, core_expr_error_slot(expr),
        successor_to(ctx, protected_entry), successor_to(ctx, caught_entry)),
        core_flow_role_control_dispatch(0))
    set_current(ctx, protected_entry)
    let protected_tail = lower_core_block(
        ctx, protected, continue_target, break_target)
    if !is_terminated(ctx) {
        merge_block_tail(ctx, protected_tail, result, origin, 0)
        terminate_goto(ctx, join, origin, core_flow_role_control_exit(0))
    }
    set_current(ctx, caught_entry)
    lower_match_arms(
        ctx, core_expr_error_slot(expr), core_expr_match_arms(expr),
        result, origin, join,
        continue_target, break_target, 1)
    set_current(ctx, join)
}

fn lower_handle_expression(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    result: SlotRef,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let origin = core_expr_origin(expr)
    let parent_scope = current_draft(ctx).scope
    let handled = core_expr_handle_body(expr)
    let body_scope = new_child_scope(ctx, parent_scope)
    let body_entry = new_draft(
        ctx, core_block_origin(handled), body_scope)
    let join = new_draft(ctx, origin, parent_scope)
    let bindings = core_expr_handlers(expr).map(fn(handler) {
        make_flow_handler_binding(
            core_handler_operation(handler), core_handler_executable(handler))
    })
    terminate(ctx, make_flow_handle_install(
        origin, successor_to(ctx, body_entry), bindings),
        core_flow_role_control_dispatch(0))
    set_current(ctx, body_entry)
    let handled_tail = lower_core_block(
        ctx, handled, continue_target, break_target)
    if !is_terminated(ctx) {
        merge_block_tail(ctx, handled_tail, result, origin, 0)
        terminate_goto(ctx, join, origin, core_flow_role_control_exit(0))
    }
    set_current(ctx, join)
}

fn lower_expr(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) -> SlotRef {
    let kind = core_expr_kind_tag(expr)
    let result = new_admin_slot(
        ctx, core_type_ref_to_flow(core_expr_type(expr)),
        current_draft(ctx).scope, binder_kind_pre_anf(), "expr", 3,
        flow_storage_temp(), flow_initial_slot_empty())
    let previous = enter_core_node(
        ctx, CORE_FLOW_NODE_EXPR, kind,
        core_expr_origin(expr), some(result))
    if emit_simple_expr(
            ctx, expr, result, continue_target, break_target) {
        restore_core_node(ctx, previous)
        return result
    }
    if kind == 12 {
        lower_block_expression(
            ctx, expr, result, core_expr_block(expr),
            continue_target, break_target)
    } else if kind == 13 {
        lower_if_expression(
            ctx, expr, result, continue_target, break_target)
    } else if kind == 14 {
        lower_match_expression(
            ctx, expr, result, continue_target, break_target)
    } else if kind == 15 {
        lower_try_expression(
            ctx, expr, result, continue_target, break_target)
    } else if kind == 16 {
        lower_handle_expression(
            ctx, expr, result, continue_target, break_target)
    } else {
        panic("Flow lowering: Core expression is not closed")
    }
    restore_core_node(ctx, previous)
    result
}

fn lower_while_statement(
    mut ctx: FlowLowerCtx, statement: CoreStmt
) {
    let origin = core_stmt_origin(statement)
    let parent_scope = current_draft(ctx).scope
    let condition_expr = core_stmt_while_condition(statement)
    let loop_body = core_stmt_while_body(statement)
    let condition = new_draft(ctx, core_expr_origin(condition_expr), parent_scope)
    let body_scope = new_child_scope(ctx, parent_scope)
    let body_entry = new_draft(ctx, core_block_origin(loop_body), body_scope)
    let exit = new_draft(ctx, origin, parent_scope)
    terminate_goto(ctx, condition, origin,
        core_flow_role_control_dispatch(0))
    set_current(ctx, condition)
    let condition_slot = lower_expr(
        ctx, condition_expr, some(condition), some(exit))
    terminate(ctx, make_flow_loop(
        origin, condition_slot,
        successor_to(ctx, body_entry), successor_to(ctx, exit)),
        core_flow_role_control_dispatch(1))
    set_current(ctx, body_entry)
    let _ = lower_core_block(ctx, loop_body, some(condition), some(exit))
    terminate_goto(ctx, condition, origin, core_flow_role_control_exit(0))
    set_current(ctx, exit)
}

fn lower_statement(
    mut ctx: FlowLowerCtx, statement: CoreStmt,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let kind = core_stmt_kind_tag(statement)
    let origin = core_stmt_origin(statement)
    let anchor = if kind == 0 { some(core_place_slot(
        core_stmt_target(statement))) } else if kind == 1 &&
            core_place_is_slot(core_stmt_target(statement)) {
        some(core_place_slot(core_stmt_target(statement)))
    } else { none }
    let previous = enter_core_node(
        ctx, CORE_FLOW_NODE_STMT, kind, origin, anchor)
    if kind == 0 {
        let target = core_place_slot(core_stmt_target(statement))
        activate_core_binder(ctx, target, current_draft(ctx).scope)
        let rhs = lower_expr(
            ctx, core_stmt_value(statement), continue_target, break_target)
        emit_instruction(ctx, make_flow_assign(
            next_instruction_ref(ctx), origin, rhs,
            make_flow_slot_place(target)), core_flow_role_stmt_assign())
    } else if kind == 1 {
        let target = lower_flow_place(
            ctx, core_stmt_target(statement), continue_target, break_target)
        let rhs = lower_expr(
            ctx, core_stmt_value(statement), continue_target, break_target)
        emit_instruction(ctx, make_flow_assign(
            next_instruction_ref(ctx), origin, rhs, target),
            core_flow_role_stmt_assign())
    } else if kind == 2 {
        let _ = lower_expr(
            ctx, core_stmt_value(statement), continue_target, break_target)
    } else if kind == 3 {
        lower_while_statement(ctx, statement)
    } else if kind == 4 {
        let target = match break_target {
            some(value) => value,
            none => panic("Flow lowering: break outside loop")
        }
        terminate(ctx, make_flow_goto(origin, successor_to(ctx, target)),
            core_flow_role_control_exit(0))
    } else if kind == 5 {
        let target = match continue_target {
            some(value) => value,
            none => panic("Flow lowering: continue outside loop")
        }
        terminate(ctx, make_flow_continue(origin, successor_to(ctx, target)),
            core_flow_role_control_exit(0))
    } else if kind == 6 {
        let returned = core_stmt_return_value(statement)
        let returned_slot = match returned {
            some(expr) => some(lower_expr(
                ctx, expr, continue_target, break_target)),
            none => none
        }
        terminate(ctx, make_flow_return(
            origin, returned_slot, all_exited_scopes(ctx)),
            core_flow_role_control_exit(0))
    } else {
        panic("Flow lowering: unknown Core statement")
    }
    restore_core_node(ctx, previous)
}

fn lower_core_block(
    mut ctx: FlowLowerCtx, block: CoreBlock,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) -> SlotRef? {
    for statement in core_block_statements(block) {
        if is_terminated(ctx) { return none }
        lower_statement(ctx, statement, continue_target, break_target)
    }
    if !is_terminated(ctx) {
        match core_block_tail(block) {
            some(expr) => return some(lower_expr(
                ctx, expr, continue_target, break_target)),
            none => return none
        }
    }
    none
}

fn freeze_drafts(ctx: FlowLowerCtx) -> List<FlowBlock> {
    let mut result: List<FlowBlock> = []
    for draft in ctx.drafts {
        let terminator = match draft.terminator {
            some(value) => value,
            none => panic("Flow lowering: draft block has no terminator")
        }
        result.push(make_flow_block(
            draft.reference, draft.origin, draft.scope,
            draft.instructions, terminator))
    }
    result
}

struct LoweredFlowBody {
    body: FlowBody,
    next_node_ordinal: Int,
    nodes: List<CoreFlowNodeRef>,
    relations: List<CoreFlowStepRelation>
}

fn lower_core_body(
    body: CoreBody, callables: List<CoreCallableContract>,
    first_node_ordinal: Int
) -> LoweredFlowBody {
    let owner = core_body_reference(body)
    let root_block = core_body_block(body)
    let root_scope = make_flow_scope_ref(owner, 0)
    let mut ctx = FlowLowerCtx {
        owner: owner, scopes: [make_flow_root_scope(root_scope)],
        binders: [], slots: [], drafts: [], current: 0,
        callables: callables, core_body: body,
        active_node: none, next_node_ordinal: first_node_ordinal,
        nodes: [], step_relations: []
    }
    let _ = enter_core_node(
        ctx, CORE_FLOW_NODE_BODY, 0, core_body_origin(body), none)
    for parameter in core_body_parameter_slots(body) {
        activate_core_binder(ctx, parameter, root_scope)
    }
    let entry = new_draft(ctx, core_block_origin(root_block), root_scope)
    set_current(ctx, entry)
    let tail = lower_core_block(ctx, root_block, none, none)
    if !is_terminated(ctx) {
        terminate(ctx, make_flow_return(
            core_body_origin(body), tail, all_exited_scopes(ctx)),
            core_flow_role_body_return())
    }
    for binder in core_body_binders(body) {
        if !flow_slot_exists(ctx, core_binder_reference(binder)) {
            activate_core_binder(ctx, core_binder_reference(binder), root_scope)
        }
    }
    let lowered = make_flow_body(
        owner, core_body_origin(body),
        make_binder_manifest(owner, ctx.binders),
        ctx.scopes, ctx.slots, entry, freeze_drafts(ctx))
    LoweredFlowBody {
        body: lowered, next_node_ordinal: ctx.next_node_ordinal,
        nodes: ctx.nodes.map(fn(node) { node }),
        relations: ctx.step_relations.map(fn(relation) {
            CoreFlowStepRelation {
                node: relation.node, step: relation.step, role: relation.role
            }
        })
    }
}

fn lower_core_callable(value: CoreCallableContract) -> FlowCallable {
    make_flow_callable(
        core_callable_reference(value), core_callable_origin(value),
        core_callable_parameter_types(value).map(fn(ty) {
            core_type_ref_to_flow(ty)
        }), core_callable_parameter_slots(value),
        core_type_ref_to_flow(core_callable_result_type(value)),
        core_callable_mode(value), core_callable_semantic_contract(value),
        core_callable_evidence_requirements(value))
}

pub fn lower_core_to_flow(program: CoreProgram) -> FlowLoweringResult {
    let graph = core_program_type_graph(program)
    let core_callables = core_program_callables(program)
    let callables = core_callables.map(fn(value) {
        lower_core_callable(value)
    })
    let mut bodies: List<FlowBody> = []
    let mut relations: List<CoreFlowStepRelation> = []
    let mut nodes: List<CoreFlowNodeRef> = []
    let mut next_node_ordinal = 0
    for entry in core_program_bodies(program) {
        let lowered = lower_core_body(
            core_body_entry_body(entry), core_callables, next_node_ordinal)
        bodies.push(lowered.body)
        for node in lowered.nodes { nodes.push(node) }
        for relation in lowered.relations { relations.push(relation) }
        next_node_ordinal = lowered.next_node_ordinal
    }
    let flow = make_flow_program(
        copy_flow_type_graph_nodes(core_type_graph_nodes(graph)),
        callables, bodies)
    make_flow_lowering_result(flow, CoreFlowStepMap {
        nodes: nodes, relations: relations
    })
}
