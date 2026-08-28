// Mechanical CoreHIR -> FlowIR lowering.
//
// CoreProgram is the sole type/callable/body authority.  This module has no
// public builder and accepts no side table: stable block/instruction ordinals,
// CFG edges and pattern decisions are derived once from the immutable Core
// tree, while exact slots/scopes/contracts are copied from Core.

use ir_identity::{
    CoreTypeRef, core_type_ref_same, core_type_ref_index,
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
    make_semantic_effect_ctx_binder,
    effect_ctx_binding, effect_ctx_slot,
    effect_ctx_parent_capture_source, effect_ctx_parent_capture_target,
    make_binder_manifest,
    binder_kind_tag,
    binder_kind_source_param, binder_kind_generated_synthetic_parameter,
    binder_kind_lambda_capture, binder_kind_lambda_value,
    binder_kind_call_result, binder_kind_pattern_projection,
    binder_kind_scope_result, binder_kind_control_result,
    binder_kind_assign_temp, binder_kind_pre_anf,
    binder_kind_effect_ctx_param,
    binder_kind_effect_ctx_local,
    binder_kind_effect_ctx_parent_capture,
    binder_kind_dictionary_evidence_param,
    effect_operation_ref_callable,
    system_host_callable_executable
}
use core_hir::{
    CoreProgram, CoreBodyEntry,
    core_program_type_graph, core_program_callables,
    core_program_bodies,
    core_body_entry_body
}
use core_expr::{
    CoreBody, CoreBinder, CoreBlock, CoreStmt, CoreExpr, CorePattern, CoreMatchArm,
    CorePatternField, CoreFieldRef, CoreFieldValue,
    CoreCalleeRef, CoreEvidenceRef,
    CoreConstructorRef, CorePlaceRef,
    CoreCallableContract,
    core_callable_reference, core_callable_origin,
    core_callable_header_type, core_callable_type_formals,
    core_callable_effect_formals,
    core_callable_parameter_slots, core_callable_mode,
    core_callable_semantic_contract,
    core_callable_effect_contract, core_callable_effect_ctx,
    core_callable_effect_ctx_reference, core_callable_effect_ctx_type,
    core_body_reference, core_body_origin, core_body_binders,
    core_body_parameter_slots, core_body_block, core_body_result_type,
    core_binder_reference, core_binder_type, core_binder_kind,
    core_binder_site, core_binder_storage_contract,
    core_block_statements, core_block_tail, core_block_origin,
    core_stmt_kind_tag, core_stmt_origin, core_stmt_target,
    core_stmt_value, core_stmt_while_condition, core_stmt_while_body,
    core_stmt_return_value, core_stmt_bind_is_mutable,
    core_place_is_slot, core_place_slot, core_place_base,
    core_place_field,
    core_place_value_type,
    core_expr_kind_tag, core_expr_type,
    core_expr_origin, core_expr_literal, core_literal_kind_tag,
    core_expr_callable_executable, core_expr_callable_evidence,
    core_expr_callable_type_substitutions,
    core_expr_callable_effect_substitutions,
    core_expr_callable_effect_instantiation,
    core_literal_int, core_literal_float, core_literal_str, core_literal_bool,
    core_expr_read_source, core_expr_primitive_operation,
    core_primitive_op_tag, core_expr_primitive_operands,
    core_expr_call_callee, core_expr_call_arguments,
    core_expr_call_evidence, core_expr_call_effect_ctx_argument,
    core_expr_method_receiver, core_expr_effect_ctx_lookup,
    core_expr_effect_operation, core_expr_system_host,
    core_expr_fail_payload,
    core_expr_project_base, core_expr_project_field,
    core_expr_project_is_partial,
    core_expr_constructor, core_expr_constructor_fields,
    core_expr_constructor_effect_ctx,
    core_expr_move_update_base, core_expr_move_update_constructor,
    core_expr_move_update_schema, core_expr_move_update_overrides,
    core_expr_move_update_effect_ctx,
    core_constructor_kind_tag, core_constructor_executable,
    core_expr_lambda_executable, core_expr_block,
    core_expr_lambda_captures, core_capture_source, core_capture_target,
    core_expr_condition, core_expr_then_block, core_expr_else_block,
    core_expr_scrutinee, core_expr_match_arms,
    core_expr_try_body, core_expr_error_slot,
    core_expr_handle_body, core_expr_effect_ctx_install,
    core_match_arm_pattern, core_match_arm_guard,
    core_match_arm_body, core_match_arm_origin,
    core_handler_installation_token,
    core_handler_installation_operations,
    core_handler_operation_ref, core_handler_operation_executable,
    core_handler_operation_captures,
    core_handler_operation_parent_ctx,
    core_handler_operation_origin,
    core_pattern_type, core_pattern_kind_tag, core_pattern_binding,
    core_pattern_literal, core_pattern_elements,
    core_pattern_fields, core_pattern_struct_owner,
    core_pattern_variant, core_pattern_field_ref,
    core_pattern_field_pattern,
    make_core_tuple_field,
    core_field_ref_kind_tag, core_field_ref_nominal,
    core_field_ref_variant, core_field_ref_tuple_index,
    core_field_ref_record_path, core_field_ref_same,
    core_field_value_field, core_field_value_expr,
    core_callee_kind_tag, core_callee_direct, core_callee_local,
    core_callee_dynamic, core_callee_contract,
    core_callee_type_substitutions,
    core_callee_effect_substitutions,
    core_callee_effect_instantiation,
    core_evidence_dict,
    core_effect_ctx_install_parent, core_effect_ctx_install_child,
    core_effect_ctx_install_entries,
    core_effect_ctx_token_instance,
    core_effect_ctx_argument_kind_tag, core_effect_ctx_argument_context,
    core_effect_ctx_lookup_context,
    core_effect_ctx_layout_entries
}
use effect_contract::{
    CoreEffectContract, CoreEffectInstantiation,
    make_explicit_core_effect_instantiation
}
use core_type_source::{
    core_type_graph_nodes,
    FlowTypeNode, FlowFieldIdentity,
    flow_type_node_children, copy_flow_type_graph_nodes,
    flow_type_node_nominal_fields, flow_nominal_field_identity,
    flow_nominal_field_type, flow_field_identity_same,
    make_nominal_flow_field_identity, make_variant_flow_field_identity,
    make_path_flow_field_identity
}
use resource_model::{
    FlowStorageContract, flow_own_storage,
    FlowSemanticRole, flow_semantic_role_read,
    flow_semantic_role_mutate, flow_semantic_role_consume,
    make_fresh_flow_value_origin,
    flow_call_contract_parameter_types,
    flow_call_contract_parameter_roles,
    flow_call_contract_result_type, flow_call_contract_result_role,
    flow_call_contract_result_origin
}
use flow_ir::{
    FlowProgram, FlowCallable, FlowBody,
    FlowScope, FlowScopeRef, FlowSlot,
    FlowInitialSlotState, FlowStorageClass,
    FlowBlock, FlowBlockRef, FlowInstructionRef, FlowInstruction,
    FlowSemanticStepRef,
    FlowTerminator, FlowSuccessor, FlowHandlerBinding,
    FlowEffectCtxEntry, FlowEffectCtxInstall,
    FlowPatternContract, FlowPatternField, FlowPrimitiveOp,
    FlowEvidenceRef, FlowEffectCtxUse,
    FlowCallTarget, FlowPlaceRef, FlowProjectionContract,
    make_flow_callable, make_flow_program,
    make_flow_slot, make_flow_block_ref, make_flow_instruction_ref,
    make_flow_block, make_flow_body,
    make_flow_scope_ref, make_flow_root_scope, make_flow_child_scope,
    flow_initial_slot_empty, flow_initial_slot_live,
    flow_storage_parameter, flow_storage_local,
    flow_storage_temp, flow_storage_result, flow_storage_capture,
    flow_storage_context,
    flow_slot_reference, flow_slot_type, flow_slot_scope,
    make_flow_successor,
    make_flow_goto, make_flow_branch, make_flow_loop,
    make_flow_return, make_flow_continue,
    make_flow_unreachable, make_flow_diverge,
    make_flow_pattern_branch, make_flow_try,
    make_flow_handler_binding, make_flow_effect_ctx_entry,
    make_flow_effect_ctx_install,
    flow_effect_ctx_entry_token,
    make_flow_handle_install,
    make_flow_initialize, make_flow_read, make_flow_assign,
    make_flow_move_place,
    make_flow_fail_raise,
    make_flow_slot_place, make_flow_project_place,
    make_flow_call, make_flow_project, make_flow_capture,
    make_flow_int_literal_contract, make_flow_float_literal_contract,
    make_flow_str_literal_contract, make_flow_bool_literal_contract,
    make_flow_unit_literal_contract,
    make_flow_primitive_contract, make_flow_constructor_contract,
    make_flow_effect_ctx_overlay_contract,
    make_flow_tuple_aggregate_contract, make_flow_record_aggregate_contract,
    make_flow_closure_contract,
    make_flow_callable_value_contract,
    FlowAggregateInputRef,
    make_nominal_flow_aggregate_input,
    make_variant_flow_aggregate_input,
    make_tuple_flow_aggregate_input,
    make_structural_flow_aggregate_input,
    make_direct_flow_call_target, make_local_flow_call_target,
    make_dynamic_flow_call_target,
    make_flow_dict_evidence,
    make_foreign_leaf_flow_effect_ctx_use,
    make_argument_flow_effect_ctx_use, make_lookup_flow_effect_ctx_use,
    make_nominal_flow_projection_contract,
    make_variant_flow_projection_contract,
    make_tuple_flow_projection_contract,
    make_structural_flow_projection_contract,
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
            } else if relation.node.kind_tag == 18 {
                role_tag == CORE_FLOW_ROLE_EXPR_PRIMARY ||
                role_tag == CORE_FLOW_ROLE_CONTROL_EXIT
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
    type_nodes: List<FlowTypeNode>,
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
    let kind_tag = binder_kind_tag(kind)
    let ctx_param = kind_tag == binder_kind_tag(binder_kind_effect_ctx_param())
    let ctx_local = kind_tag == binder_kind_tag(binder_kind_effect_ctx_local())
    let ctx_parent_capture = kind_tag == binder_kind_tag(
        binder_kind_effect_ctx_parent_capture())
    let lambda_capture = kind_tag == binder_kind_tag(
        binder_kind_lambda_capture())
    let dictionary_param = kind_tag == binder_kind_tag(
        binder_kind_dictionary_evidence_param())
    let entry = if ctx_param || ctx_local || ctx_parent_capture {
        make_semantic_effect_ctx_binder(reference, ctx.owner, kind, site)
    } else if slot_ref_is_source(reference) {
        make_source_binder_entry(reference, ctx.owner, kind, site)
    } else {
        make_synthetic_binder_entry(reference, ctx.owner, kind, site)
    }
    let ordinal = parameter_ordinal(ctx.core_body, reference)
    let entry_live = ordinal.is_some() || ctx_param || ctx_parent_capture ||
        lambda_capture || dictionary_param
    let storage = if ctx_parent_capture || lambda_capture {
        flow_storage_capture()
    } else if ctx_param {
        flow_storage_context()
    } else if ordinal.is_some() || dictionary_param {
        flow_storage_parameter()
    } else { flow_storage_local() }
    let initial = if entry_live {
        flow_initial_slot_live()
    } else {
        flow_initial_slot_empty()
    }
    ctx.binders.push(entry)
    ctx.slots.push(make_flow_slot(
        reference, core_binder_type(binder), scope,
        scope_slot_count(ctx, scope), initial, storage,
        core_binder_storage_contract(binder), ordinal))
}

fn new_admin_slot(
    mut ctx: FlowLowerCtx, ty: CoreTypeRef, scope: FlowScopeRef,
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
fn frozen_slot_type_at(ctx: FlowLowerCtx, slot: SlotRef) -> CoreTypeRef {
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
        result.push(make_flow_dict_evidence(core_evidence_dict(value)))
    }
    result
}

fn callable_identity_effects(
    value: CoreCallableContract
) -> CoreEffectInstantiation {
    let effects = core_callable_effect_contract(value)
    make_explicit_core_effect_instantiation(effects, effects, effects)
}
fn flow_call_target(value: CoreCalleeRef) -> FlowCallTarget {
    let contract = core_callee_contract(value)
    let effects = core_callee_effect_instantiation(value)
    let kind = core_callee_kind_tag(value)
    if kind == 0 {
        make_direct_flow_call_target(
            core_callee_direct(value), contract,
            core_callee_type_substitutions(value),
            core_callee_effect_substitutions(value), effects)
    } else if kind == 1 {
        make_local_flow_call_target(
            core_callee_local(value), contract, effects)
    } else if kind == 2 {
        make_dynamic_flow_call_target(
            core_callee_dynamic(value), contract, effects)
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

fn flow_aggregate_input(field: CoreFieldRef) -> FlowAggregateInputRef {
    let kind = core_field_ref_kind_tag(field)
    if kind == 0 {
        return make_nominal_flow_aggregate_input(
            core_field_ref_nominal(field))
    }
    if kind == 1 {
        return make_tuple_flow_aggregate_input(
            core_field_ref_tuple_index(field))
    }
    if kind == 2 {
        return make_structural_flow_aggregate_input(
            core_field_ref_record_path(field))
    }
    make_variant_flow_aggregate_input(core_field_ref_variant(field))
}

fn move_update_field_type(
    ctx: FlowLowerCtx, base_type: CoreTypeRef, field: CoreFieldRef
) -> CoreTypeRef {
    let node = ctx.type_nodes.get(core_type_ref_index(base_type)).unwrap_or_else(fn() {
        panic("Flow lowering: move update base type is absent")
    })
    if core_field_ref_kind_tag(field) == 1 {
        return flow_type_node_children(node).get(
            core_field_ref_tuple_index(field)).unwrap_or_else(fn() {
                panic("Flow lowering: move update tuple field is absent")
            })
    }
    let identity = flow_field(field)
    let mut found: CoreTypeRef? = none
    for fact in flow_type_node_nominal_fields(node) {
        if flow_field_identity_same(flow_nominal_field_identity(fact), identity) {
            if found.is_some() {
                panic("Flow lowering: move update field fact repeats")
            }
            found = some(flow_nominal_field_type(fact))
        }
    }
    match found {
        some(value) => value,
        none => panic("Flow lowering: move update field is absent")
    }
}

fn partial_projection_contract(
    field: CoreFieldRef, base_type: CoreTypeRef,
    value_type: CoreTypeRef, role: FlowSemanticRole
) -> FlowProjectionContract {
    let kind = core_field_ref_kind_tag(field)
    if kind == 0 {
        return make_nominal_flow_projection_contract(
            core_field_ref_nominal(field), base_type, value_type, role, true)
    }
    if kind == 1 {
        return make_tuple_flow_projection_contract(
            core_field_ref_tuple_index(field), base_type, value_type, role, true)
    }
    if kind == 2 {
        return make_structural_flow_projection_contract(
            core_field_ref_record_path(field), base_type, value_type, role, true)
    }
    make_variant_flow_projection_contract(
        core_field_ref_variant(field), base_type, value_type, role, true)
}

fn lower_move_update_source_place(
    mut ctx: FlowLowerCtx, base: CoreExpr,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) -> FlowPlaceRef? {
    if core_expr_kind_tag(base) == 1 {
        let source = core_expr_read_source(base)
        if !flow_slot_exists(ctx, source) {
            panic("Flow lowering: move update source slot is inactive")
        }
        let previous = enter_core_node(
            ctx, CORE_FLOW_NODE_EXPR, 1, core_expr_origin(base), some(source))
        restore_core_node(ctx, previous)
        return some(make_flow_slot_place(source))
    }
    if core_expr_kind_tag(base) == 9 {
        let receiver = core_expr_project_base(base)
        if core_expr_kind_tag(receiver) == 1 {
            let source = core_expr_read_source(receiver)
            let previous = enter_core_node(
                ctx, CORE_FLOW_NODE_EXPR, 9, core_expr_origin(base), some(source))
            let source_place = lower_move_update_source_place(
                ctx, receiver, continue_target, break_target)
            if source_place.is_none() {
                restore_core_node(ctx, previous)
                return none
            }
            let base_type = frozen_slot_type_at(ctx, source)
            let value_type = core_expr_type(base)
            let result = make_flow_project_place(
            source, partial_projection_contract(
                    core_expr_project_field(base), base_type, value_type,
                    flow_semantic_role_consume()), value_type)
            restore_core_node(ctx, previous)
            return some(result)
        }
    }
    let source = lower_expr(ctx, base, continue_target, break_target)
    if is_terminated(ctx) { return none }
    some(make_flow_slot_place(source))
}

fn lower_flow_place(
    mut ctx: FlowLowerCtx, value: CorePlaceRef,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) -> FlowPlaceRef? {
    if core_place_is_slot(value) {
        if !flow_slot_exists(ctx, core_place_slot(value)) {
            panic("Flow lowering: assignment target is not active")
        }
        return some(make_flow_slot_place(core_place_slot(value)))
    }
    let base = lower_expr(
        ctx, core_place_base(value), continue_target, break_target)
    if is_terminated(ctx) { return none }
    let base_type = frozen_slot_type_at(ctx, base)
    let value_type = core_place_value_type(value)
    let field = core_place_field(value)
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
    some(make_flow_project_place(base, contract, value_type))
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
    let ty = core_pattern_type(value)
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

fn pattern_has_bindings(value: CorePattern) -> Bool {
    let kind = core_pattern_kind_tag(value)
    if kind == 1 { return true }
    if kind == 3 {
        for element in core_pattern_elements(value) {
            if pattern_has_bindings(element) { return true }
        }
    } else if kind == 4 || kind == 5 {
        for field in core_pattern_fields(value) {
            if pattern_has_bindings(core_pattern_field_pattern(field)) {
                return true
            }
        }
    }
    false
}

fn lower_pattern_projection(
    mut ctx: FlowLowerCtx, source: SlotRef, pattern: CorePattern,
    scope: FlowScopeRef, origin: OriginRef, mut dispatch_ordinal: Int
) -> Int {
    let kind = core_pattern_kind_tag(pattern)
    if kind == 1 {
        emit_instruction(ctx, make_flow_read(
            next_instruction_ref(ctx), origin, source,
            core_pattern_binding(pattern)),
            core_flow_role_control_dispatch(dispatch_ordinal))
        return dispatch_ordinal + 1
    }
    if kind == 0 || kind == 2 { return dispatch_ordinal }
    let base_type = frozen_slot_type_at(ctx, source)
    if kind == 3 {
        let elements = core_pattern_elements(pattern)
        let mut index = 0
        while index < elements.len() {
            let child = elements.get(index).unwrap()
            if pattern_has_bindings(child) {
                let child_type = core_pattern_type(child)
                let target = if core_pattern_kind_tag(child) == 1 {
                    core_pattern_binding(child)
                } else {
                    new_admin_slot(
                        ctx, child_type, scope, binder_kind_pattern_projection(),
                        "pattern-projection", dispatch_ordinal,
                        flow_storage_temp(), flow_initial_slot_empty())
                }
                emit_instruction(ctx, make_flow_project(
                    next_instruction_ref(ctx), origin,
                    partial_projection_contract(
                        make_core_tuple_field(index), base_type, child_type,
                        flow_semantic_role_read()),
                    source, target),
                    core_flow_role_control_dispatch(dispatch_ordinal))
                dispatch_ordinal = dispatch_ordinal + 1
                if core_pattern_kind_tag(child) != 1 {
                    dispatch_ordinal = lower_pattern_projection(
                        ctx, target, child, scope, origin,
                        dispatch_ordinal)
                }
            }
            index = index + 1
        }
        return dispatch_ordinal
    }
    if kind == 4 || kind == 5 {
        for field in core_pattern_fields(pattern) {
            let child = core_pattern_field_pattern(field)
            if pattern_has_bindings(child) {
                let child_type = core_pattern_type(child)
                let target = if core_pattern_kind_tag(child) == 1 {
                    core_pattern_binding(child)
                } else {
                    new_admin_slot(
                        ctx, child_type, scope, binder_kind_pattern_projection(),
                        "pattern-projection", dispatch_ordinal,
                        flow_storage_temp(), flow_initial_slot_empty())
                }
                emit_instruction(ctx, make_flow_project(
                    next_instruction_ref(ctx), origin,
                    partial_projection_contract(
                        core_pattern_field_ref(field), base_type, child_type,
                        flow_semantic_role_read()),
                    source, target),
                    core_flow_role_control_dispatch(dispatch_ordinal))
                dispatch_ordinal = dispatch_ordinal + 1
                if core_pattern_kind_tag(child) != 1 {
                    dispatch_ordinal = lower_pattern_projection(
                        ctx, target, child, scope, origin,
                        dispatch_ordinal)
                }
            }
        }
        return dispatch_ordinal
    }
    panic("Flow lowering: unknown pattern projection")
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
    let origin = core_expr_origin(expr)
    let result_type = core_expr_type(expr)
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
            next_instruction_ref(ctx), origin, contract, [], result),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 1 {
        let _ = frozen_slot_type_at(ctx, core_expr_read_source(expr))
        emit_instruction(ctx, make_flow_read(
            next_instruction_ref(ctx), origin,
            core_expr_read_source(expr), result),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 2 {
        let mut operands: List<SlotRef> = []
        for operand in core_expr_primitive_operands(expr) {
            operands.push(lower_expr(
                ctx, operand, continue_target, break_target))
            if is_terminated(ctx) { return true }
        }
        if is_terminated(ctx) { return true }
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
            next_instruction_ref(ctx), origin, contract, operands, result),
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
            if is_terminated(ctx) { return true }
        }
        for argument in core_expr_call_arguments(expr) {
            arguments.push(lower_expr(
                ctx, argument, continue_target, break_target))
            if is_terminated(ctx) { return true }
        }
        if is_terminated(ctx) { return true }
        let evidence = flow_evidence(core_expr_call_evidence(expr))
        let effect_ctx = if core_callee_kind_tag(callee) == 0 &&
                core_callable_effect_ctx(callable_for(
                    ctx, core_callee_direct(callee))).is_none() {
            make_foreign_leaf_flow_effect_ctx_use()
        } else {
            make_argument_flow_effect_ctx_use(
                core_expr_call_effect_ctx_argument(expr))
        }
        emit_instruction(ctx, make_flow_call(
            next_instruction_ref(ctx), origin,
            flow_call_target(callee), arguments,
            evidence,
            effect_ctx,
            some(result)), core_flow_role_expr_primary())
        return true
    }
    if kind == 5 {
        let mut arguments: List<SlotRef> = []
        for argument in core_expr_call_arguments(expr) {
            arguments.push(lower_expr(
                ctx, argument, continue_target, break_target))
            if is_terminated(ctx) { return true }
        }
        if is_terminated(ctx) { return true }
        let callable = callable_for(
            ctx, effect_operation_ref_callable(
                core_expr_effect_operation(expr)))
        emit_instruction(ctx, make_flow_call(
            next_instruction_ref(ctx), origin,
            make_direct_flow_call_target(
                core_callable_reference(callable),
                core_callable_semantic_contract(callable),
                [], [],
                callable_identity_effects(callable)),
            arguments,
            flow_evidence(core_expr_call_evidence(expr)),
            make_lookup_flow_effect_ctx_use(
                core_expr_effect_ctx_lookup(expr)),
            some(result)),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 6 {
        let mut arguments: List<SlotRef> = []
        for argument in core_expr_call_arguments(expr) {
            arguments.push(lower_expr(
                ctx, argument, continue_target, break_target))
            if is_terminated(ctx) { return true }
        }
        if is_terminated(ctx) { return true }
        let callable = callable_for(
            ctx, system_host_callable_executable(core_expr_system_host(expr)))
        emit_instruction(ctx, make_flow_call(
            next_instruction_ref(ctx), origin,
            make_direct_flow_call_target(
                core_callable_reference(callable),
                core_callable_semantic_contract(callable),
                [], [],
                callable_identity_effects(callable)),
            arguments, [], make_foreign_leaf_flow_effect_ctx_use(),
            some(result)),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 19 {
        // Evaluate the source first without consuming an addressable place,
        // then evaluate every override left-to-right.  The first MovePlace is
        // the commit point: no user expression remains after it.
        let base_place = match lower_move_update_source_place(
                ctx, core_expr_move_update_base(expr),
                continue_target, break_target) {
            some(value) => value,
            none => return true
        }
        let overrides = core_expr_move_update_overrides(expr)
        let mut override_fields: List<CoreFieldRef> = []
        let mut override_slots: List<SlotRef> = []
        for field in overrides {
            override_fields.push(core_field_value_field(field))
            override_slots.push(lower_expr(
                ctx, core_field_value_expr(field),
                continue_target, break_target))
            if is_terminated(ctx) { return true }
        }

        let scope = current_draft(ctx).scope
        let committed_base = new_admin_slot(
            ctx, result_type, scope, binder_kind_pre_anf(),
            "move-update-base", 0, flow_storage_temp(),
            flow_initial_slot_empty())
        let mut role_ordinal = 0
        emit_instruction(ctx, make_flow_move_place(
            next_instruction_ref(ctx), origin, base_place, committed_base),
            core_flow_role_control_dispatch(role_ordinal))
        role_ordinal = role_ordinal + 1

        let schema = core_expr_move_update_schema(expr)
        let mut inputs: List<SlotRef> = []
        let mut input_locations: List<FlowAggregateInputRef?> = []
        for field in schema {
            let field_type = move_update_field_type(ctx, result_type, field)
            let mut override_slot: SlotRef? = none
            let mut index = 0
            while index < override_fields.len() {
                if core_field_ref_same(
                        override_fields.get(index).unwrap(), field) {
                    if override_slot.is_some() {
                        panic("Flow lowering: move update override repeats")
                    }
                    override_slot = some(override_slots.get(index).unwrap())
                }
                index = index + 1
            }
            match override_slot {
                some(slot) => {
                    let target_contract = partial_projection_contract(
                        field, result_type, field_type,
                        flow_semantic_role_mutate())
                    emit_instruction(ctx, make_flow_assign(
                        next_instruction_ref(ctx), origin, slot,
                        make_flow_project_place(
                            committed_base, target_contract, field_type)),
                        core_flow_role_control_dispatch(role_ordinal))
                    role_ordinal = role_ordinal + 1
                },
                none => {}
            }
            let field_slot = new_admin_slot(
                ctx, field_type, scope, binder_kind_pre_anf(),
                "move-update-field", inputs.len(), flow_storage_temp(),
                flow_initial_slot_empty())
            let projection = partial_projection_contract(
                field, result_type, field_type,
                flow_semantic_role_consume())
            emit_instruction(ctx, make_flow_project(
                next_instruction_ref(ctx), origin, projection,
                committed_base, field_slot),
                core_flow_role_control_dispatch(role_ordinal))
            role_ordinal = role_ordinal + 1
            inputs.push(field_slot)
            input_locations.push(some(flow_aggregate_input(field)))
        }

        let constructor = core_expr_move_update_constructor(expr)
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
                    input_locations, result_type,
                    flow_call_contract_result_role(callable_contract),
                    flow_call_contract_result_origin(callable_contract),
                    core_expr_move_update_effect_ctx(expr).unwrap_or_else(fn() {
                        panic("Flow lowering: executable update lacks EffectCtx")
                    }))
            },
            none => if constructor_kind == 0 || constructor_kind == 3 {
                make_flow_record_aggregate_contract(
                    inputs.len(), input_types, roles,
                    input_locations, result_type)
            } else {
                panic("Flow lowering: move update variant lacks executable")
            }
        }
        emit_instruction(ctx, make_flow_initialize(
            next_instruction_ref(ctx), origin, contract, inputs, result),
            core_flow_role_control_dispatch(role_ordinal))
        return true
    }
    if kind == 9 {
        let base = lower_expr(
            ctx, core_expr_project_base(expr),
            continue_target, break_target)
        if is_terminated(ctx) { return true }
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
            next_instruction_ref(ctx), origin, contract, base, result),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 10 {
        let constructor = core_expr_constructor(expr)
        let fields = core_expr_constructor_fields(expr)
        let mut inputs: List<SlotRef> = []
        let mut input_locations: List<FlowAggregateInputRef?> = []
        for field in fields {
            inputs.push(lower_expr(
                ctx, core_field_value_expr(field),
                continue_target, break_target))
            input_locations.push(some(flow_aggregate_input(
                core_field_value_field(field))))
            if is_terminated(ctx) { return true }
        }
        if is_terminated(ctx) { return true }
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
                    input_locations,
                    result_type,
                    flow_call_contract_result_role(callable_contract),
                    flow_call_contract_result_origin(callable_contract),
                    core_expr_constructor_effect_ctx(expr).unwrap_or_else(fn() {
                        panic("Flow lowering: executable constructor lacks EffectCtx")
                    }))
            },
            none => if constructor_kind == 2 {
                make_flow_tuple_aggregate_contract(
                    inputs.len(), input_types, roles, result_type)
            } else if constructor_kind == 0 || constructor_kind == 3 {
                make_flow_record_aggregate_contract(
                    inputs.len(), input_types, roles,
                    input_locations, result_type)
            } else {
                panic("Flow lowering: variant constructor lacks executable")
            }
        }
        emit_instruction(ctx, make_flow_initialize(
            next_instruction_ref(ctx), origin, contract, inputs, result),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 11 {
        let executable = core_expr_lambda_executable(expr)
        let _ = callable_for(ctx, executable)
        let exact_captures = core_expr_lambda_captures(expr)
        let captures = exact_captures.map(fn(capture) {
            core_capture_source(capture)
        })
        let capture_targets = exact_captures.map(fn(capture) {
            core_capture_target(capture)
        })
        let input_types = captures.map(fn(slot) {
            frozen_slot_type_at(ctx, slot)
        })
        let contract = make_flow_closure_contract(
            executable, input_types,
            repeated_role(captures.len(), flow_semantic_role_read()),
            capture_targets, result_type)
        emit_instruction(ctx, make_flow_initialize(
            next_instruction_ref(ctx), origin, contract, captures, result),
            core_flow_role_expr_primary())
        return true
    }
    if kind == 17 {
        let executable = core_expr_callable_executable(expr)
        let _ = callable_for(ctx, executable)
        emit_instruction(ctx, make_flow_initialize(
            next_instruction_ref(ctx), origin,
            make_flow_callable_value_contract(
                executable, result_type,
                flow_evidence(core_expr_callable_evidence(expr)),
                core_expr_callable_type_substitutions(expr),
                core_expr_callable_effect_substitutions(expr),
                core_expr_callable_effect_instantiation(expr)),
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
    if is_terminated(ctx) { return }
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
    let mut dispatch_ordinal = arm_base
    while index < arms.len() {
        set_current(ctx, tests.get(index).unwrap())
        let arm = arms.get(index).unwrap()
        let arm_body = core_match_arm_body(arm)
        let arm_scope = new_child_scope(ctx, parent_scope)
        activate_pattern_binders(
            ctx, core_match_arm_pattern(arm), arm_scope)
        let projection = new_draft(
            ctx, core_match_arm_origin(arm), arm_scope)
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
            successor_to(ctx, projection), successor_to(ctx, next)),
            core_flow_role_control_dispatch(dispatch_ordinal))
        dispatch_ordinal = dispatch_ordinal + 1
        set_current(ctx, projection)
        dispatch_ordinal = lower_pattern_projection(
            ctx, scrutinee, core_match_arm_pattern(arm), arm_scope,
            core_match_arm_origin(arm), dispatch_ordinal)
        terminate_goto(ctx, candidate, core_match_arm_origin(arm),
            core_flow_role_control_dispatch(dispatch_ordinal))
        dispatch_ordinal = dispatch_ordinal + 1
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
                    core_flow_role_control_dispatch(dispatch_ordinal))
                dispatch_ordinal = dispatch_ordinal + 1
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
    if is_terminated(ctx) { return }
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
    let mut dispatch_ordinal = 1
    match core_expr_effect_ctx_install(expr) {
        some(installation) => {
            let parent = core_effect_ctx_install_parent(installation)
            let child = core_effect_ctx_install_child(installation)
            let parent_slot = effect_ctx_slot(parent)
            let child_slot = effect_ctx_slot(child)
            activate_core_binder(ctx, child_slot, body_scope)
            let ctx_type = frozen_slot_type_at(ctx, parent_slot)
            let mut entries: List<FlowEffectCtxEntry> = []
            let mut overlay_inputs: List<SlotRef> = [parent_slot]
            let mut overlay_types: List<CoreTypeRef> = [ctx_type]
            let mut overlay_roles: List<FlowSemanticRole> = [
                flow_semantic_role_read()
            ]
            for entry in core_effect_ctx_install_entries(installation) {
                let mut handlers: List<FlowHandlerBinding> = []
                for operation in core_handler_installation_operations(entry) {
                    let executable = core_handler_operation_executable(operation)
                    let handler_callable = callable_for(ctx, executable)
                    let mut capture_sources: List<SlotRef> = []
                    let mut capture_targets: List<SlotRef> = []
                    let mut capture_types: List<CoreTypeRef> = []
                    for capture in core_handler_operation_captures(operation) {
                        let source = core_capture_source(capture)
                        capture_sources.push(source)
                        capture_targets.push(core_capture_target(capture))
                        capture_types.push(frozen_slot_type_at(ctx, source))
                    }
                    let parent_capture = core_handler_operation_parent_ctx(
                        operation)
                    let parent_source = effect_ctx_slot(
                        effect_ctx_parent_capture_source(parent_capture))
                    capture_sources.push(parent_source)
                    capture_targets.push(effect_ctx_slot(
                        effect_ctx_parent_capture_target(parent_capture)))
                    capture_types.push(frozen_slot_type_at(ctx, parent_source))
                    let closure_type = core_callable_header_type(
                        handler_callable)
                    let closure_slot = new_admin_slot(
                        ctx, closure_type, body_scope,
                        binder_kind_lambda_value(), "handler-closure", 0,
                        flow_storage_temp(), flow_initial_slot_empty())
                    emit_instruction(ctx, make_flow_initialize(
                        next_instruction_ref(ctx),
                        core_handler_operation_origin(operation),
                        make_flow_closure_contract(
                            executable, capture_types,
                            repeated_role(capture_sources.len(),
                                flow_semantic_role_read()),
                            capture_targets, closure_type),
                        capture_sources, closure_slot),
                        core_flow_role_control_dispatch(dispatch_ordinal))
                    dispatch_ordinal = dispatch_ordinal + 1
                    handlers.push(make_flow_handler_binding(
                        core_handler_operation_ref(operation), executable,
                        closure_slot))
                    overlay_inputs.push(closure_slot)
                    overlay_types.push(closure_type)
                    overlay_roles.push(flow_semantic_role_consume())
                }
                entries.push(make_flow_effect_ctx_entry(
                    core_handler_installation_token(entry), handlers))
            }
            emit_instruction(ctx, make_flow_initialize(
                next_instruction_ref(ctx), origin,
                make_flow_effect_ctx_overlay_contract(
                    parent, child,
                    entries.map(fn(entry) {
                        flow_effect_ctx_entry_token(entry)
                    }), overlay_types, overlay_roles, ctx_type),
                overlay_inputs, child_slot),
                core_flow_role_control_dispatch(dispatch_ordinal))
            let flow_install = make_flow_effect_ctx_install(
                parent, child, entries)
            terminate(ctx, make_flow_handle_install(
                origin, successor_to(ctx, body_entry), flow_install),
                core_flow_role_control_dispatch(0))
        },
        none => terminate_goto(
            ctx, body_entry, origin, core_flow_role_control_dispatch(0))
    }
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
        ctx, core_expr_type(expr),
        current_draft(ctx).scope, binder_kind_pre_anf(), "expr", 3,
        flow_storage_temp(), flow_initial_slot_empty())
    let previous = enter_core_node(
        ctx, CORE_FLOW_NODE_EXPR, kind,
        core_expr_origin(expr), some(result))
    if kind == 18 {
        let payload = lower_expr(
            ctx, core_expr_fail_payload(expr),
            continue_target, break_target)
        if !is_terminated(ctx) {
            let sink = new_admin_slot(
                ctx, frozen_slot_type_at(ctx, payload),
                current_draft(ctx).scope, binder_kind_pre_anf(),
                "fail-payload", 3,
                flow_storage_temp(), flow_initial_slot_empty())
            emit_instruction(ctx, make_flow_fail_raise(
                next_instruction_ref(ctx), core_expr_origin(expr),
                payload, sink),
                core_flow_role_expr_primary())
            terminate(ctx, make_flow_diverge(
                core_expr_origin(expr), all_exited_scopes(ctx)),
                core_flow_role_control_exit(0))
        }
        restore_core_node(ctx, previous)
        return result
    }
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
    if is_terminated(ctx) { return }
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
        if is_terminated(ctx) {
            restore_core_node(ctx, previous)
            return
        }
        emit_instruction(ctx, make_flow_assign(
            next_instruction_ref(ctx), origin, rhs,
            make_flow_slot_place(target)), core_flow_role_stmt_assign())
    } else if kind == 1 {
        let target_result = lower_flow_place(
            ctx, core_stmt_target(statement),
            continue_target, break_target)
        if target_result.is_none() {
            restore_core_node(ctx, previous)
            return
        }
        let target = target_result.unwrap()
        let rhs = lower_expr(
            ctx, core_stmt_value(statement), continue_target, break_target)
        if is_terminated(ctx) {
            restore_core_node(ctx, previous)
            return
        }
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
        if is_terminated(ctx) {
            restore_core_node(ctx, previous)
            return
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
    type_nodes: List<FlowTypeNode>,
    first_node_ordinal: Int
) -> LoweredFlowBody {
    let owner = core_body_reference(body)
    let root_block = core_body_block(body)
    let root_scope = make_flow_scope_ref(owner, 0)
    let mut ctx = FlowLowerCtx {
        owner: owner, type_nodes: type_nodes,
        scopes: [make_flow_root_scope(root_scope)],
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
    for binder in core_body_binders(body) {
        let kind_tag = binder_kind_tag(core_binder_kind(binder))
        if kind_tag == binder_kind_tag(binder_kind_lambda_capture()) ||
           kind_tag == binder_kind_tag(
                binder_kind_effect_ctx_param()) ||
           kind_tag == binder_kind_tag(
                binder_kind_effect_ctx_parent_capture()) {
            activate_core_binder(
                ctx, core_binder_reference(binder), root_scope)
        }
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
        core_callable_header_type(value), core_callable_type_formals(value),
        core_callable_effect_formals(value),
        core_callable_parameter_slots(value),
        core_callable_mode(value), core_callable_semantic_contract(value),
        core_callable_effect_contract(value),
        core_callable_effect_ctx(value))
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
            core_body_entry_body(entry), core_callables,
            core_type_graph_nodes(graph), next_node_ordinal)
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
