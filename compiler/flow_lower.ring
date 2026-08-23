// Mechanical CoreHIR -> FlowIR lowering.
//
// CoreProgram is the sole type/callable/body authority.  This module has no
// public builder and accepts no side table: stable block/instruction ordinals,
// CFG edges and pattern decisions are derived once from the immutable Core
// tree, while exact slots/scopes/contracts are copied from Core.

use ir_identity::{
    OriginRef, SlotRef,
    slot_ref_same, registered_nominal_ref_symbol
}
use ir_inventory::{
    ExecutableRef, BinderManifest,
    EffectOperationRef,
    executable_ref_same,
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
    CoreBody, CoreBlock, CoreStmt, CoreExpr, CorePattern, CoreMatchArm,
    CorePatternField, CoreFieldRef, CoreFieldValue,
    CoreCalleeRef, CoreEvidenceRef, CoreConstructorRef,
    CoreCallableContract,
    core_type_ref_to_flow,
    core_callable_reference, core_callable_origin,
    core_callable_parameter_types, core_callable_parameter_slots,
    core_callable_result_type, core_callable_mode,
    core_callable_semantic_contract,
    core_callable_evidence_requirements,
    core_body_reference, core_body_origin, core_body_manifest,
    core_body_scopes, core_body_slots,
    core_body_block, core_body_result_type,
    core_type_graph_nodes,
    core_slot_reference, core_slot_type, core_slot_scope,
    core_slot_reverse_ordinal, core_slot_initial_state,
    core_slot_storage, core_slot_storage_contract,
    core_slot_parameter_ordinal,
    core_block_statements, core_block_tail, core_block_origin,
    core_block_scope,
    core_stmt_kind_tag, core_stmt_origin, core_stmt_target,
    core_stmt_value, core_stmt_while_condition, core_stmt_while_body,
    core_stmt_return_value,
    core_expr_kind_tag, core_expr_result, core_expr_type,
    core_expr_origin, core_expr_literal, core_literal_kind_tag,
    core_literal_int, core_literal_float, core_literal_str, core_literal_bool,
    core_expr_read_source, core_expr_primitive_operation,
    core_primitive_op_tag, core_expr_primitive_operands,
    core_expr_call_callee, core_expr_call_arguments,
    core_expr_call_evidence, core_expr_method_receiver,
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
    core_field_value_field, core_field_value_slot,
    core_callee_kind_tag, core_callee_direct, core_callee_local,
    core_callee_dynamic, core_callee_contract, core_callee_candidates,
    core_evidence_is_local, core_evidence_local, core_evidence_callable
}
use flow_ir::{
    FlowProgram, FlowTypeNode, FlowTypeRef, FlowCallable, FlowBody,
    FlowScope, FlowScopeRef, FlowSlot,
    FlowBlock, FlowBlockRef, FlowInstructionRef, FlowInstruction,
    FlowTerminator, FlowSuccessor, FlowHandlerBinding,
    FlowPatternContract, FlowPatternField,
    FlowSemanticRole, FlowPrimitiveOp,
    FlowEvidenceRef, FlowCallTarget, FlowFieldIdentity,
    copy_flow_type_graph_nodes,
    make_flow_callable, make_flow_program,
    make_flow_slot, make_flow_block_ref, make_flow_instruction_ref,
    make_flow_block, make_flow_body,
    make_flow_successor,
    make_flow_goto, make_flow_branch, make_flow_loop,
    make_flow_return, make_flow_continue,
    make_flow_unreachable, make_flow_diverge,
    make_flow_pattern_branch, make_flow_try,
    make_flow_handler_binding, make_flow_handle_install,
    make_flow_initialize, make_flow_read, make_flow_assign,
    make_flow_call, make_flow_project, make_flow_capture,
    make_flow_int_literal_contract, make_flow_float_literal_contract,
    make_flow_str_literal_contract, make_flow_bool_literal_contract,
    make_flow_unit_literal_contract,
    make_flow_primitive_contract, make_flow_constructor_contract,
    make_fresh_flow_value_origin,
    make_flow_tuple_aggregate_contract, make_flow_record_aggregate_contract,
    make_flow_closure_contract,
    make_direct_flow_call_target, make_local_flow_call_target,
    make_dynamic_flow_call_target,
    make_flow_local_evidence, make_flow_callable_evidence,
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
    flow_semantic_role_read, flow_semantic_role_consume,
    flow_call_contract_parameter_types,
    flow_call_contract_parameter_roles,
    flow_call_contract_result_type, flow_call_contract_result_role,
    flow_call_contract_result_origin,
    flow_scope_reference, flow_scope_has_parent, flow_scope_parent,
    flow_scope_ref_same,
    flow_block_reference, flow_block_scope, flow_block_ref_ordinal
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
    drafts: List<FlowBlockDraft>,
    current: Int,
    callables: List<CoreCallableContract>,
    core_body: CoreBody
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
fn emit_instruction(mut ctx: FlowLowerCtx, instruction: FlowInstruction) {
    let mut draft = current_draft(ctx)
    if draft.terminator.is_some() {
        panic("Flow lowering: instruction after terminator")
    }
    draft.instructions.push(instruction)
    ctx.drafts.set(ctx.current, draft)
}
fn next_instruction_ref(ctx: FlowLowerCtx) -> FlowInstructionRef {
    let draft = current_draft(ctx)
    make_flow_instruction_ref(
        ctx.owner, flow_block_ref_ordinal(draft.reference),
        draft.instructions.len())
}
fn terminate(mut ctx: FlowLowerCtx, value: FlowTerminator) {
    let mut draft = current_draft(ctx)
    if draft.terminator.is_some() {
        panic("Flow lowering: block terminator replay")
    }
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
fn core_slot_type_at(ctx: FlowLowerCtx, slot: SlotRef) -> FlowTypeRef {
    for value in core_body_slots(ctx.core_body) {
        if slot_ref_same(core_slot_reference(value), slot) {
            return core_type_ref_to_flow(core_slot_type(value))
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
        } else {
            make_flow_callable_evidence(core_evidence_callable(value))
        })
    }
    result
}

fn flow_call_target(value: CoreCalleeRef) -> FlowCallTarget {
    let contract = core_callee_contract(value)
    let candidates = core_callee_candidates(value)
    let kind = core_callee_kind_tag(value)
    if kind == 0 {
        make_direct_flow_call_target(core_callee_direct(value), contract)
    } else if kind == 1 {
        make_local_flow_call_target(
            core_callee_local(value), contract, candidates)
    } else if kind == 2 {
        make_dynamic_flow_call_target(
            core_callee_dynamic(value), contract, candidates)
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

fn emit_simple_expr(mut ctx: FlowLowerCtx, expr: CoreExpr) -> Bool {
    let kind = core_expr_kind_tag(expr)
    let reference = next_instruction_ref(ctx)
    let origin = core_expr_origin(expr)
    let result = core_expr_result(expr)
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
            reference, origin, contract, [], result))
        return true
    }
    if kind == 1 {
        emit_instruction(ctx, make_flow_read(
            reference, origin, core_expr_read_source(expr), result))
        return true
    }
    if kind == 2 {
        let operands = core_expr_primitive_operands(expr)
        let input_types = operands.map(fn(slot) {
            core_slot_type_at(ctx, slot)
        })
        let contract = make_flow_primitive_contract(
            flow_primitive(core_primitive_op_tag(
                core_expr_primitive_operation(expr))),
            input_types, repeated_role(operands.len(), flow_semantic_role_read()),
            result_type, flow_semantic_role_read(),
            make_fresh_flow_value_origin())
        emit_instruction(ctx, make_flow_initialize(
            reference, origin, contract, operands, result))
        return true
    }
    if kind == 3 || kind == 4 {
        let callee = core_expr_call_callee(expr)
        let mut arguments = core_expr_call_arguments(expr)
        if kind == 4 {
            let mut with_receiver = [core_expr_method_receiver(expr)]
            for argument in arguments { with_receiver.push(argument) }
            arguments = with_receiver
        }
        emit_instruction(ctx, make_flow_call(
            reference, origin, flow_call_target(callee), arguments,
            flow_evidence(core_expr_call_evidence(expr)), some(result)))
        return true
    }
    if kind == 5 {
        let callable = callable_for(
            ctx, effect_operation_ref_callable(
                core_expr_effect_operation(expr)))
        emit_instruction(ctx, make_flow_call(
            reference, origin,
            make_direct_flow_call_target(
                core_callable_reference(callable),
                core_callable_semantic_contract(callable)),
            core_expr_call_arguments(expr),
            flow_evidence(core_expr_call_evidence(expr)), some(result)))
        return true
    }
    if kind == 6 {
        let callable = callable_for(
            ctx, system_host_callable_executable(core_expr_system_host(expr)))
        emit_instruction(ctx, make_flow_call(
            reference, origin,
            make_direct_flow_call_target(
                core_callable_reference(callable),
                core_callable_semantic_contract(callable)),
            core_expr_call_arguments(expr), [], some(result)))
        return true
    }
    if kind == 7 || kind == 8 {
        let executable = if kind == 7 {
            core_expr_dict_constructor(expr)
        } else {
            core_expr_dict_project_method(expr)
        }
        let callable = callable_for(ctx, executable)
        let arguments = if kind == 7 {
            []
        } else {
            [core_expr_dict_project_dictionary(expr)]
        }
        emit_instruction(ctx, make_flow_call(
            reference, origin,
            make_direct_flow_call_target(
                executable, core_callable_semantic_contract(callable)),
            arguments,
            if kind == 7 {
                flow_evidence(core_expr_call_evidence(expr))
            } else { [] }, some(result)))
        return true
    }
    if kind == 9 {
        let base = core_expr_project_base(expr)
        let field = core_expr_project_field(expr)
        let base_type = core_slot_type_at(ctx, base)
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
            reference, origin, contract, base, result))
        return true
    }
    if kind == 10 {
        let constructor = core_expr_constructor(expr)
        let fields = core_expr_constructor_fields(expr)
        let inputs = fields.map(fn(field) { core_field_value_slot(field) })
        let input_types = inputs.map(fn(slot) { core_slot_type_at(ctx, slot) })
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
            reference, origin, contract, inputs, result))
        return true
    }
    if kind == 11 {
        let executable = core_expr_lambda_executable(expr)
        let _ = callable_for(ctx, executable)
        let captures = core_expr_lambda_captures(expr).map(fn(capture) {
            core_capture_source(capture)
        })
        let input_types = captures.map(fn(slot) { core_slot_type_at(ctx, slot) })
        let contract = make_flow_closure_contract(
            executable, input_types,
            repeated_role(captures.len(), flow_semantic_role_read()),
            result_type)
        emit_instruction(ctx, make_flow_initialize(
            reference, origin, contract, captures, result))
        return true
    }
    false
}

fn terminate_goto(mut ctx: FlowLowerCtx, target: FlowBlockRef, origin: OriginRef) {
    if !is_terminated(ctx) {
        terminate(ctx, make_flow_goto(origin, successor_to(ctx, target)))
    }
}

fn merge_block_tail(
    mut ctx: FlowLowerCtx, block: CoreBlock,
    result: SlotRef, origin: OriginRef
) {
    match core_block_tail(block) {
        some(tail) => {
            let source = core_expr_result(tail)
            if !slot_ref_same(source, result) {
                emit_instruction(ctx, make_flow_assign(
                    next_instruction_ref(ctx), origin, source, result))
            }
        },
        none => {}
    }
}

fn lower_block_expression(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    block: CoreBlock,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let parent_scope = current_draft(ctx).scope
    let entry = new_draft(ctx, core_block_origin(block), core_block_scope(block))
    let join = new_draft(ctx, core_expr_origin(expr), parent_scope)
    terminate_goto(ctx, entry, core_expr_origin(expr))
    set_current(ctx, entry)
    lower_core_block(ctx, block, continue_target, break_target)
    if !is_terminated(ctx) {
        merge_block_tail(ctx, block, core_expr_result(expr), core_expr_origin(expr))
        terminate_goto(ctx, join, core_expr_origin(expr))
    }
    set_current(ctx, join)
}

fn lower_if_expression(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let origin = core_expr_origin(expr)
    let parent_scope = current_draft(ctx).scope
    let then_block = core_expr_then_block(expr)
    let else_block = core_expr_else_block(expr)
    let then_entry = new_draft(
        ctx, core_block_origin(then_block), core_block_scope(then_block))
    let else_entry = new_draft(
        ctx, core_block_origin(else_block), core_block_scope(else_block))
    let join = new_draft(ctx, origin, parent_scope)
    terminate(ctx, make_flow_branch(
        origin, core_expr_condition(expr),
        successor_to(ctx, then_entry), successor_to(ctx, else_entry)))
    set_current(ctx, then_entry)
    lower_core_block(ctx, then_block, continue_target, break_target)
    if !is_terminated(ctx) {
        merge_block_tail(ctx, then_block, core_expr_result(expr), origin)
        terminate_goto(ctx, join, origin)
    }
    set_current(ctx, else_entry)
    lower_core_block(ctx, else_block, continue_target, break_target)
    if !is_terminated(ctx) {
        merge_block_tail(ctx, else_block, core_expr_result(expr), origin)
        terminate_goto(ctx, join, origin)
    }
    set_current(ctx, join)
}

fn lower_match_arms(
    mut ctx: FlowLowerCtx, scrutinee: SlotRef,
    arms: List<CoreMatchArm>, result: SlotRef,
    origin: OriginRef, join: FlowBlockRef,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
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
        let candidate = new_draft(
            ctx, core_match_arm_origin(arm), core_block_scope(arm_body))
        let next = if index + 1 < tests.len() {
            tests.get(index + 1).unwrap()
        } else {
            final_unmatched
        }
        terminate(ctx, make_flow_pattern_branch(
            core_match_arm_origin(arm), scrutinee,
            flow_pattern(core_match_arm_pattern(arm)),
            successor_to(ctx, candidate), successor_to(ctx, next)))
        set_current(ctx, candidate)
        match core_match_arm_guard(arm) {
            some(guard) => {
                lower_expr(ctx, guard, continue_target, break_target)
                let guarded_body = new_draft(
                    ctx, core_block_origin(arm_body), core_block_scope(arm_body))
                terminate(ctx, make_flow_branch(
                    core_expr_origin(guard), core_expr_result(guard),
                    successor_to(ctx, guarded_body), successor_to(ctx, next)))
                set_current(ctx, guarded_body)
            },
            none => {}
        }
        lower_core_block(ctx, arm_body, continue_target, break_target)
        if !is_terminated(ctx) {
            merge_block_tail(ctx, arm_body, result, origin)
            terminate_goto(ctx, join, origin)
        }
        index = index + 1
    }
    set_current(ctx, final_unmatched)
    terminate(ctx, make_flow_unreachable(origin, all_exited_scopes(ctx)))
}

fn lower_match_expression(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let origin = core_expr_origin(expr)
    let join = new_draft(ctx, origin, current_draft(ctx).scope)
    lower_match_arms(
        ctx, core_expr_scrutinee(expr), core_expr_match_arms(expr),
        core_expr_result(expr), origin, join,
        continue_target, break_target)
    set_current(ctx, join)
}

fn lower_try_expression(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let origin = core_expr_origin(expr)
    let parent_scope = current_draft(ctx).scope
    let protected = core_expr_try_body(expr)
    let protected_entry = new_draft(
        ctx, core_block_origin(protected), core_block_scope(protected))
    let caught_entry = new_draft(ctx, origin, parent_scope)
    let join = new_draft(ctx, origin, parent_scope)
    terminate(ctx, make_flow_try(
        origin, core_expr_error_slot(expr),
        successor_to(ctx, protected_entry), successor_to(ctx, caught_entry)))
    set_current(ctx, protected_entry)
    lower_core_block(ctx, protected, continue_target, break_target)
    if !is_terminated(ctx) {
        merge_block_tail(ctx, protected, core_expr_result(expr), origin)
        terminate_goto(ctx, join, origin)
    }
    set_current(ctx, caught_entry)
    lower_match_arms(
        ctx, core_expr_error_slot(expr), core_expr_match_arms(expr),
        core_expr_result(expr), origin, join,
        continue_target, break_target)
    set_current(ctx, join)
}

fn lower_handle_expression(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let origin = core_expr_origin(expr)
    let parent_scope = current_draft(ctx).scope
    let handled = core_expr_handle_body(expr)
    let body_entry = new_draft(
        ctx, core_block_origin(handled), core_block_scope(handled))
    let join = new_draft(ctx, origin, parent_scope)
    let bindings = core_expr_handlers(expr).map(fn(handler) {
        make_flow_handler_binding(
            core_handler_operation(handler), core_handler_executable(handler))
    })
    terminate(ctx, make_flow_handle_install(
        origin, successor_to(ctx, body_entry), bindings))
    set_current(ctx, body_entry)
    lower_core_block(ctx, handled, continue_target, break_target)
    if !is_terminated(ctx) {
        merge_block_tail(ctx, handled, core_expr_result(expr), origin)
        terminate_goto(ctx, join, origin)
    }
    set_current(ctx, join)
}

fn lower_expr(
    mut ctx: FlowLowerCtx, expr: CoreExpr,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    if emit_simple_expr(ctx, expr) { return }
    let kind = core_expr_kind_tag(expr)
    if kind == 12 {
        lower_block_expression(
            ctx, expr, core_expr_block(expr), continue_target, break_target)
    } else if kind == 13 {
        lower_if_expression(ctx, expr, continue_target, break_target)
    } else if kind == 14 {
        lower_match_expression(ctx, expr, continue_target, break_target)
    } else if kind == 15 {
        lower_try_expression(ctx, expr, continue_target, break_target)
    } else if kind == 16 {
        lower_handle_expression(ctx, expr, continue_target, break_target)
    } else {
        panic("Flow lowering: Core expression is not closed")
    }
}

fn lower_while_statement(
    mut ctx: FlowLowerCtx, statement: CoreStmt
) {
    let origin = core_stmt_origin(statement)
    let parent_scope = current_draft(ctx).scope
    let condition_expr = core_stmt_while_condition(statement)
    let loop_body = core_stmt_while_body(statement)
    let condition = new_draft(ctx, core_expr_origin(condition_expr), parent_scope)
    let body_entry = new_draft(
        ctx, core_block_origin(loop_body), core_block_scope(loop_body))
    let exit = new_draft(ctx, origin, parent_scope)
    terminate_goto(ctx, condition, origin)
    set_current(ctx, condition)
    lower_expr(ctx, condition_expr, some(condition), some(exit))
    terminate(ctx, make_flow_loop(
        origin, core_expr_result(condition_expr),
        successor_to(ctx, body_entry), successor_to(ctx, exit)))
    set_current(ctx, body_entry)
    lower_core_block(ctx, loop_body, some(condition), some(exit))
    terminate_goto(ctx, condition, origin)
    set_current(ctx, exit)
}

fn lower_statement(
    mut ctx: FlowLowerCtx, statement: CoreStmt,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    let kind = core_stmt_kind_tag(statement)
    let origin = core_stmt_origin(statement)
    if kind == 0 {
        lower_expr(ctx, core_stmt_value(statement), continue_target, break_target)
    } else if kind == 1 {
        let value = core_stmt_value(statement)
        lower_expr(ctx, value, continue_target, break_target)
        emit_instruction(ctx, make_flow_assign(
            next_instruction_ref(ctx), origin,
            core_expr_result(value), core_stmt_target(statement)))
    } else if kind == 2 {
        lower_expr(ctx, core_stmt_value(statement), continue_target, break_target)
    } else if kind == 3 {
        lower_while_statement(ctx, statement)
    } else if kind == 4 {
        let target = match break_target {
            some(value) => value,
            none => panic("Flow lowering: break outside loop")
        }
        terminate(ctx, make_flow_goto(origin, successor_to(ctx, target)))
    } else if kind == 5 {
        let target = match continue_target {
            some(value) => value,
            none => panic("Flow lowering: continue outside loop")
        }
        terminate(ctx, make_flow_continue(origin, successor_to(ctx, target)))
    } else if kind == 6 {
        let returned = core_stmt_return_value(statement)
        match returned {
            some(expr) => lower_expr(ctx, expr, continue_target, break_target),
            none => {}
        }
        terminate(ctx, make_flow_return(
            origin, match returned {
                some(expr) => some(core_expr_result(expr)),
                none => none
            }, all_exited_scopes(ctx)))
    } else {
        panic("Flow lowering: unknown Core statement")
    }
}

fn lower_core_block(
    mut ctx: FlowLowerCtx, block: CoreBlock,
    continue_target: FlowBlockRef?, break_target: FlowBlockRef?
) {
    for statement in core_block_statements(block) {
        if is_terminated(ctx) { return }
        lower_statement(ctx, statement, continue_target, break_target)
    }
    if !is_terminated(ctx) {
        match core_block_tail(block) {
            some(expr) => lower_expr(ctx, expr, continue_target, break_target),
            none => {}
        }
    }
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

fn lower_core_body(
    body: CoreBody, callables: List<CoreCallableContract>
) -> FlowBody {
    let owner = core_body_reference(body)
    let scopes = core_body_scopes(body)
    let root_block = core_body_block(body)
    let mut ctx = FlowLowerCtx {
        owner: owner, scopes: scopes, drafts: [], current: 0,
        callables: callables, core_body: body
    }
    let entry = new_draft(
        ctx, core_block_origin(root_block), core_block_scope(root_block))
    set_current(ctx, entry)
    lower_core_block(ctx, root_block, none, none)
    if !is_terminated(ctx) {
        let returned = match core_block_tail(root_block) {
            some(expr) => some(core_expr_result(expr)),
            none => none
        }
        terminate(ctx, make_flow_return(
            core_body_origin(body), returned, all_exited_scopes(ctx)))
    }
    let slots = core_body_slots(body).map(fn(slot) {
        make_flow_slot(
            core_slot_reference(slot),
            core_type_ref_to_flow(core_slot_type(slot)),
            core_slot_scope(slot), core_slot_reverse_ordinal(slot),
            core_slot_initial_state(slot), core_slot_storage(slot),
            core_slot_storage_contract(slot),
            core_slot_parameter_ordinal(slot))
    })
    make_flow_body(
        owner, core_body_origin(body), core_body_manifest(body),
        scopes, slots, entry, freeze_drafts(ctx))
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

pub fn lower_core_to_flow(program: CoreProgram) -> FlowProgram {
    let graph = core_program_type_graph(program)
    let core_callables = core_program_callables(program)
    let callables = core_callables.map(fn(value) {
        lower_core_callable(value)
    })
    let mut bodies: List<FlowBody> = []
    for entry in core_program_bodies(program) {
        bodies.push(lower_core_body(
            core_body_entry_body(entry), core_callables))
    }
    make_flow_program(
        copy_flow_type_graph_nodes(core_type_graph_nodes(graph)),
        callables, bodies)
}
