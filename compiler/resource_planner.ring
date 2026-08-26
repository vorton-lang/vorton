// ONE ResourcePlanner orchestration authority for frozen FlowIR.
//
// This file owns the sole FlowProgram adapter, component sequencing, and opaque
// verified acceptance token. Type/callable LFP, candidate provenance, CFG/RcIR
// materialization, and independent verification live in bounded components. None
// resolves names, re-runs type/effect/trait selection, or creates semantic
// binders, blocks, edges, event phases, or slot identities.

use ir_identity::{
    CoreTypeRef, core_type_ref_index, core_type_ref_same,
    SlotRef, PathRef, slot_ref_same, slot_ref_is_source,
    slot_ref_synthetic_path, path_ref_same}
use ir_inventory::{
    ExecutableRef, executable_ref_same,
    executable_contract_mode_concrete_body,
    executable_contract_mode_same}
use core_type_source::{
    FlowTypeNode,
    flow_type_node_reference, flow_type_node_kind, flow_type_node_children,
    flow_type_node_generic_param, flow_type_node_resource_edges,
    flow_resource_edge_is_application, flow_resource_edge_child,
    flow_resource_edge_child_dependency_ordinal,
    flow_resource_edge_target,
    flow_resource_dependency_target_is_parent,
    flow_resource_dependency_target_parent,
    flow_resource_dependency_target_parent_ordinal,
    flow_resource_dependency_target_concrete_type,
    flow_type_node_semantic_seed, flow_type_node_drop_contract,
    flow_type_kind_tag,
    flow_generic_param_index, flow_generic_param_arity
}
use flow_ir::{
    FlowProgram,
    FlowCallable, FlowBody, FlowSlot, FlowScope, FlowScopeRef,
    FlowInstruction, FlowPlaceRef, FlowCallableLocation, FlowOperandRef,
    FlowTerminator, FlowCallTarget,
    validate_flow_program, flow_program_type_nodes,
    flow_program_callables, flow_program_bodies,
    flow_program_topology_fingerprint,
    flow_topology_fingerprint_canonical,
    flow_callable_reference,
    flow_callable_parameter_types, flow_callable_parameter_slots,
    flow_callable_result_type, flow_callable_mode,
    flow_callable_semantic_contract, flow_call_target_contract,
    flow_call_target_is_direct, flow_call_target_is_local,
    flow_call_target_direct, flow_call_target_local,
    flow_call_target_dynamic, flow_callable_provenance_target,
    flow_callable_provenance_origin, flow_callable_origin_is_direct,
    flow_callable_origin_is_call, flow_callable_origin_direct,
    flow_callable_origin_locations, flow_callable_origin_call_target,
    flow_callable_origin_call_arguments,
    flow_callable_location_is_slot, flow_callable_location_slot,
    flow_callable_location_base, flow_callable_location_projection,
    flow_body_reference, flow_body_scopes, flow_body_slots,
    flow_body_entry, flow_body_blocks, flow_scope_reference,
    flow_scope_has_parent, flow_scope_parent, flow_scope_ref_ordinal,
    flow_scope_ref_same, flow_slot_reference, flow_slot_type,
    flow_slot_scope, flow_slot_reverse_ordinal, flow_slot_initial_state,
    flow_slot_storage, flow_slot_storage_contract,
    flow_slot_parameter_ordinal, flow_initial_slot_state_tag,
    flow_storage_class_tag,
    flow_block_reference, flow_block_instructions,
    flow_block_terminator, flow_block_terminator_operands,
    flow_block_ref_ordinal,
    flow_instruction_reference, flow_instruction_operands,
    make_flow_instruction_step_ref,
    flow_operand_step, flow_operand_ordinal,
    flow_operand_slot, flow_operand_role,
    flow_instruction_kind_tag, flow_initialize_operation,
    flow_initialize_inputs, flow_initialize_target,
    flow_operation_contract_input_roles,
    flow_operation_contract_target_origin, flow_read_source,
    flow_read_target, flow_mutate_target, flow_mutate_value,
    flow_mutate_target_role, flow_mutate_value_role,
    flow_consume_source, flow_discard_source, flow_fail_raise_payload,
    flow_fail_raise_sink, flow_assign_rhs_temp, flow_assign_target,
    flow_place_is_slot, flow_place_slot, flow_place_base,
    flow_place_projection, flow_place_value_type, flow_call_target,
    flow_call_arguments, flow_call_result, flow_project_base,
    flow_project_result, flow_project_is_partial, flow_capture_source,
    flow_capture_target, flow_capture_source_role,
    flow_capture_target_role, flow_scope_instruction_scope,
    flow_terminator_kind_tag, flow_terminator_successors,
    flow_terminator_terminal_exited_scopes,
    flow_successor_target, flow_successor_exited_scopes}
use flow_provenance::{flow_instruction_callable_provenance}
use resource_model::{
    FlowSemanticRole, FlowValueOriginContract,
    flow_type_semantic_seed_tag, flow_semantic_role_tag,
    flow_call_contract_parameter_roles, flow_call_contract_result_type,
    flow_call_contract_result_role, flow_call_contract_result_origin,
    flow_value_origin_is_fresh, flow_value_origin_alias_ordinals,
    flow_storage_contract_tag,
    TransferDemand, LogicalOwnershipShape, PhysicalRcShape,
    param_mode_borrow, param_mode_mut_borrow, param_mode_own,
    make_transfer_demand, transfer_demand_mode, transfer_demand_force,
    make_logical_ownership_shape, logical_ownership_shape_direct_drop,
    logical_ownership_shape_may_unique, logical_ownership_shape_param_deps,
    make_physical_rc_shape, physical_rc_shape_physical_rc,
    physical_rc_shape_boxing, physical_rc_shape_drop_glue,
    physical_rc_shape_foreign_containment, physical_rc_shape_param_deps}
use rc_ir::{
    RcProgram, RcBody, make_rc_program, rc_program_flow_fingerprint}
use resource_certificate::{
    ResourceCertificate, CfgBodyCertificate,
    make_resource_certificate, verify_resource_certificate}

pub use resource_type_lfp::{
    ResourceDiagnostic, PlannerPlace, planner_place_exact,
    resource_diagnostic_step, resource_diagnostic_operand_ordinal,
    resource_diagnostic_is_place, resource_diagnostic_slot,
    resource_diagnostic_place, resource_diagnostic_state,
    resource_diagnostic_state_kind}

use resource_type_lfp::{
    PlannerTypeKind, planner_type_kind_atomic,
    planner_type_kind_ptr, planner_type_kind_extern,
    planner_type_kind_nominal, planner_type_kind_tuple,
    planner_type_kind_record, planner_type_kind_callable,
    planner_type_kind_parameter,
    PlannerResourceDependency, make_parent_resource_dependency,
    make_concrete_resource_dependency, PlannerTypeNode,
    make_planner_type_node,
    PlannerCallable, make_planner_callable, PlannerScope, make_planner_scope,
    PlannerSlot, make_planner_slot, make_planner_slot_place,
    make_planner_project_place, PlannerCallTarget,
    make_planner_direct_call_target, make_planner_slot_call_target,
    PlannerCallableProvenance, PlannerOperand, make_planner_operand,
    PlannerEvent, make_planner_noop,
    make_planner_scope_exit, make_planner_initialize,
    make_planner_read, make_planner_mutate, make_planner_consume,
    make_planner_discard, make_planner_assign, make_planner_call,
    make_planner_project, make_planner_capture, PlannerEdge,
    make_planner_edge, PlannerTerminatorUse, make_planner_terminator_use,
    PlannerBlock, make_planner_block, PlannerBody, make_planner_body}
use resource_type_lfp::{
    FrozenPlannerInput, SolvedResourceGraph, PlannerCallableLocation,
    make_planner_callable_slot_location,
    make_planner_callable_projection_location,
    make_direct_planner_callable_provenance,
    make_locations_planner_callable_provenance,
    make_call_planner_callable_provenance,
    with_planner_callable_provenance, make_frozen_planner_input,
    build_constraint_graph, solve_constraint_graph,
    materialize_solved_graph}
use resource_candidate_provenance::{
    build_candidate_proof_graph, solve_candidate_proof_graph,
    derive_candidate_selections, with_candidate_selections,
    resolve_bodies_from_candidate_proof}
use resource_cfg_materialize::{
    plan_body, collect_stable_resource_diagnostics}
use resource_verifier::{
    verify_candidate_graph_contract, verify_fixed_graph_contract,
    verify_rc_topology_contract}

// ============================================================
// Sole frozen FlowProgram adapter
// ============================================================

fn transfer_demand_from_flow_role(role: FlowSemanticRole) -> TransferDemand {
    let tag = flow_semantic_role_tag(role)
    if tag == 0 {
        return make_transfer_demand(param_mode_borrow(), false)
    }
    if tag == 1 {
        return make_transfer_demand(param_mode_mut_borrow(), false)
    }
    if tag == 2 {
        return make_transfer_demand(param_mode_own(), false)
    }
    if tag == 3 {
        return make_transfer_demand(param_mode_own(), true)
    }
    panic("ResourcePlanner: unknown FlowIR semantic role")
}

fn flow_role_is_owned(role: FlowSemanticRole) -> Bool {
    let tag = flow_semantic_role_tag(role)
    tag == 2 || tag == 3
}

fn flow_origin_ordinals(value: FlowValueOriginContract) -> List<Int> {
    if flow_value_origin_is_fresh(value) { return [] }
    flow_value_origin_alias_ordinals(value)
}

fn flow_resource_children(node: FlowTypeNode) -> List<CoreTypeRef> {
    let tag = flow_type_kind_tag(flow_type_node_kind(node))
    // Ptr pointees and callable signatures do not contribute to the value's
    // own resource representation. Nominal fields and structural elements do.
    let mut result: List<CoreTypeRef> = []
    if tag == 6 || tag == 7 || tag == 8 || tag == 9 {
        for child in flow_type_node_children(node) { result.push(child) }
    }
    for edge in flow_type_node_resource_edges(node) {
        if flow_resource_edge_is_application(edge) {
            let child = flow_resource_edge_child(edge)
            if !result.any(fn(existing) {
                    core_type_ref_same(existing, child)
                }) {
                result.push(child)
            }
        }
    }
    result
}

fn compute_flow_type_arities(nodes: List<FlowTypeNode>) -> List<Int> {
    let mut arities: List<Int> = []
    for node in nodes {
        let tag = flow_type_kind_tag(flow_type_node_kind(node))
        let mut arity = if tag == 12 {
            flow_generic_param_arity(flow_type_node_generic_param(node))
        } else {
            0
        }
        for edge in flow_type_node_resource_edges(node) {
            let target = flow_resource_edge_target(edge)
            if flow_resource_dependency_target_is_parent(target) {
                let target_arity = flow_generic_param_arity(
                    flow_resource_dependency_target_parent(target))
                if arity != 0 && arity != target_arity {
                    panic("ResourcePlanner: FlowIR parent generic arity differs")
                }
                arity = target_arity
            }
        }
        arities.push(arity)
    }
    arities
}

fn planner_type_kind_from_flow(node: FlowTypeNode) -> PlannerTypeKind {
    let tag = flow_type_kind_tag(flow_type_node_kind(node))
    if tag >= 0 && tag <= 5 { return planner_type_kind_atomic() }
    if tag == 6 || tag == 7 { return planner_type_kind_nominal() }
    if tag == 8 { return planner_type_kind_tuple() }
    if tag == 9 { return planner_type_kind_record() }
    if tag == 10 { return planner_type_kind_callable() }
    if tag == 11 { return planner_type_kind_ptr() }
    if tag == 12 { return planner_type_kind_parameter() }
    if tag == 13 { return planner_type_kind_extern() }
    panic("ResourcePlanner: unknown FlowIR type kind crossed adapter")
}

fn planner_type_node_from_flow(
    node: FlowTypeNode, arity: Int
) -> PlannerTypeNode {
    let seed_tag = flow_type_semantic_seed_tag(
        flow_type_node_semantic_seed(node))
    let drop_contract = flow_type_node_drop_contract(node)
    // Ring 0.1 extern values are borrowed by kind; managed foreign contracts
    // have no producer and do not enter planning.
    let managed_foreign = false
    let mut children: List<Int> = []
    for child in flow_resource_children(node) {
        children.push(core_type_ref_index(child))
    }
    let mut dependencies: List<PlannerResourceDependency> = []
    for edge in flow_type_node_resource_edges(node) {
        let child_index = core_type_ref_index(flow_resource_edge_child(edge))
        let child_dependency = flow_resource_edge_child_dependency_ordinal(edge)
        let target = flow_resource_edge_target(edge)
        if flow_resource_dependency_target_is_parent(target) {
            dependencies.push(make_parent_resource_dependency(
                child_index, child_dependency,
                flow_resource_dependency_target_parent_ordinal(target)))
        } else {
            dependencies.push(make_concrete_resource_dependency(
                child_index, child_dependency,
                core_type_ref_index(
                    flow_resource_dependency_target_concrete_type(target))))
        }
    }
    let is_unique = seed_tag == 2 || drop_contract.is_some()
    let is_shareable = seed_tag == 3 || managed_foreign
    let parameter_index = if flow_type_kind_tag(
            flow_type_node_kind(node)) == 12 {
        some(flow_generic_param_index(flow_type_node_generic_param(node)))
    } else {
        none
    }
    make_planner_type_node(
        planner_type_kind_from_flow(node), children, dependencies,
        arity, parameter_index,
        drop_contract.is_some(), is_unique,
        is_shareable, is_shareable || is_unique,
        is_shareable || drop_contract.is_some(), seed_tag == 4)
}

fn flow_callable_index(
    callables: List<FlowCallable>, reference: ExecutableRef
) -> Int {
    let mut index = 0
    while index < callables.len() {
        if executable_ref_same(
                flow_callable_reference(callables.get(index).unwrap()),
                reference) {
            return index
        }
        index = index + 1
    }
    panic("ResourcePlanner: exact FlowIR callable is absent")
}

fn flow_body_for_reference(
    bodies: List<FlowBody>, reference: ExecutableRef
) -> FlowBody? {
    for body in bodies {
        if executable_ref_same(flow_body_reference(body), reference) {
            return some(body)
        }
    }
    none
}

fn flow_parameter_slots(
    body: FlowBody, callable: FlowCallable
) -> List<FlowSlot> {
    let mut result: List<FlowSlot> = []
    let exact_slots = flow_callable_parameter_slots(callable)
    let mut ordinal = 0
    while ordinal < exact_slots.len() {
        let expected = exact_slots.get(ordinal).unwrap()
        let mut matches = 0
        let mut found: FlowSlot? = none
        for slot in flow_body_slots(body) {
            if flow_storage_class_tag(flow_slot_storage(slot)) == 0 &&
               flow_slot_parameter_ordinal(slot) == ordinal {
                if !slot_ref_same(flow_slot_reference(slot), expected) {
                    panic("ResourcePlanner: parameter ordinal/ref relation drifted")
                }
                found = some(slot)
                matches = matches + 1
            }
        }
        if matches != 1 {
            panic("ResourcePlanner: parameter ordinal is missing or duplicated")
        }
        result.push(found.unwrap())
        ordinal = ordinal + 1
    }
    result
}

fn planner_callable_from_flow(
    callable: FlowCallable, bodies: List<FlowBody>
) -> PlannerCallable {
    let mut parameter_types: List<Int> = []
    for ty in flow_callable_parameter_types(callable) {
        parameter_types.push(core_type_ref_index(ty))
    }
    let contract = flow_callable_semantic_contract(callable)
    let mut seeds: List<TransferDemand> = []
    for role in flow_call_contract_parameter_roles(contract) {
        seeds.push(transfer_demand_from_flow_role(role))
    }
    let has_body = executable_contract_mode_same(
        flow_callable_mode(callable), executable_contract_mode_concrete_body())
    if has_body {
        let body = match flow_body_for_reference(
                bodies, flow_callable_reference(callable)) {
            some(value) => value,
            none => panic("ResourcePlanner: concrete FlowIR callable lacks body")
        }
        let parameters = flow_parameter_slots(body, callable)
        if parameters.len() != parameter_types.len() {
            panic("ResourcePlanner: FlowIR parameter slot census differs")
        }
    }
    make_planner_callable(
        flow_callable_reference(callable), parameter_types,
        core_type_ref_index(flow_callable_result_type(callable)),
        seeds,
        if has_body { false } else {
            flow_role_is_owned(flow_call_contract_result_role(contract))
        },
        if has_body { [] } else {
            flow_origin_ordinals(flow_call_contract_result_origin(contract))
        },
        has_body)
}

fn flow_scope_depth(
    scopes: List<FlowScope>, target: FlowScopeRef
) -> Int {
    let mut current = target
    let mut depth = 0
    let mut traversed = 0
    while true {
        let mut found: FlowScope? = none
        for scope in scopes {
            if flow_scope_ref_same(flow_scope_reference(scope), current) {
                found = some(scope)
            }
        }
        let scope = match found {
            some(value) => value,
            none => panic("ResourcePlanner: slot scope is outside FlowIR body")
        }
        if !flow_scope_has_parent(scope) { return depth }
        current = flow_scope_parent(scope)
        depth = depth + 1
        traversed = traversed + 1
        if traversed >= scopes.len() {
            panic("ResourcePlanner: FlowIR scope parent cycle")
        }
    }
    0
}

fn flow_slot_index(slots: List<FlowSlot>, target: SlotRef) -> Int {
    let mut index = 0
    while index < slots.len() {
        if slot_ref_same(flow_slot_reference(slots.get(index).unwrap()), target) {
            return index
        }
        index = index + 1
    }
    panic("ResourcePlanner: FlowIR operand lacks frozen slot")
}

fn planner_place_from_flow(
    value: FlowPlaceRef, slots: List<FlowSlot>
) -> PlannerPlace {
    if flow_place_is_slot(value) {
        return make_planner_slot_place(
            flow_slot_index(slots, flow_place_slot(value)), value)
    }
    make_planner_project_place(
        flow_slot_index(slots, flow_place_base(value)),
        flow_place_projection(value),
        core_type_ref_index(flow_place_value_type(value)), value)
}

fn flow_dynamic_call_slot(
    path: PathRef, slots: List<FlowSlot>
) -> Int {
    let mut found: Int? = none
    let mut index = 0
    while index < slots.len() {
        let reference = flow_slot_reference(slots.get(index).unwrap())
        if !slot_ref_is_source(reference) &&
           path_ref_same(slot_ref_synthetic_path(reference), path) {
            if found.is_some() {
                panic("ResourcePlanner: dynamic callable path maps to multiple slots")
            }
            found = some(index)
        }
        index = index + 1
    }
    match found {
        some(value) => value,
        none => panic("ResourcePlanner: dynamic callable path lacks exact slot")
    }
}

fn planner_call_target_from_flow(
    target: FlowCallTarget, slots: List<FlowSlot>,
    callables: List<FlowCallable>
) -> PlannerCallTarget {
    if flow_call_target_is_direct(target) {
        return make_planner_direct_call_target(flow_callable_index(
            callables, flow_call_target_direct(target)))
    }
    if flow_call_target_is_local(target) {
        return make_planner_slot_call_target(flow_slot_index(
            slots, flow_call_target_local(target)))
    }
    make_planner_slot_call_target(flow_dynamic_call_slot(
        flow_call_target_dynamic(target), slots))
}

fn planner_operands_from_flow(
    instruction: FlowInstruction, slots: List<FlowSlot>
) -> List<PlannerOperand> {
    let mut result: List<PlannerOperand> = []
    for operand in flow_instruction_operands(instruction) {
        let reference = flow_operand_slot(operand)
        result.push(make_planner_operand(
            flow_operand_step(operand), flow_operand_ordinal(operand),
            flow_slot_index(slots, reference), reference,
            transfer_demand_from_flow_role(flow_operand_role(operand))))
    }
    result
}

fn planner_event_value_from_flow(
    instruction: FlowInstruction, slots: List<FlowSlot>,
    callables: List<FlowCallable>
) -> PlannerEvent {
    let step = make_flow_instruction_step_ref(
        flow_instruction_reference(instruction))
    let operands = planner_operands_from_flow(instruction, slots)
    let tag = flow_instruction_kind_tag(instruction)
    if tag == 0 {
        let operation = flow_initialize_operation(instruction)
        let mut inputs: List<Int> = []
        for slot in flow_initialize_inputs(instruction) {
            inputs.push(flow_slot_index(slots, slot))
        }
        let mut demands: List<TransferDemand> = []
        for role in flow_operation_contract_input_roles(operation) {
            demands.push(transfer_demand_from_flow_role(role))
        }
        return make_planner_initialize(
            step, operands, inputs, demands,
            flow_origin_ordinals(
                flow_operation_contract_target_origin(operation)),
            flow_slot_index(slots, flow_initialize_target(instruction)))
    }
    if tag == 1 {
        return make_planner_read(
            step, operands,
            flow_slot_index(slots, flow_read_source(instruction)),
            flow_slot_index(slots, flow_read_target(instruction)))
    }
    if tag == 2 {
        let target_role = flow_mutate_target_role(instruction)
        if flow_semantic_role_tag(target_role) != 1 {
            panic("ResourcePlanner: mutate target is not exact MutBorrow")
        }
        return make_planner_mutate(
            step, operands,
            flow_slot_index(slots, flow_mutate_target(instruction)),
            flow_slot_index(slots, flow_mutate_value(instruction)),
            transfer_demand_from_flow_role(
                flow_mutate_value_role(instruction)))
    }
    if tag == 3 {
        return make_planner_consume(
            step, operands,
            flow_slot_index(slots, flow_consume_source(instruction)),
            false, none)
    }
    if tag == 4 {
        return make_planner_discard(
            step, operands,
            flow_slot_index(slots, flow_discard_source(instruction)))
    }
    if tag == 5 {
        return make_planner_assign(
            step, operands,
            flow_slot_index(slots, flow_assign_rhs_temp(instruction)),
            planner_place_from_flow(flow_assign_target(instruction), slots))
    }
    if tag == 6 {
        let target = flow_call_target(instruction)
        let contract = flow_call_target_contract(target)
        let mut arguments: List<Int> = []
        for slot in flow_call_arguments(instruction) {
            arguments.push(flow_slot_index(slots, slot))
        }
        let mut demands: List<TransferDemand> = []
        for role in flow_call_contract_parameter_roles(contract) {
            demands.push(transfer_demand_from_flow_role(role))
        }
        let result = match flow_call_result(instruction) {
            some(slot) => some(flow_slot_index(slots, slot)),
            none => none
        }
        return make_planner_call(
            step, operands,
            planner_call_target_from_flow(target, slots, callables),
            if flow_call_target_is_direct(target) {
                [flow_callable_index(callables, flow_call_target_direct(target))]
            } else { [] },
            arguments, demands, false,
            core_type_ref_index(flow_call_contract_result_type(contract)),
            [],
            result)
    }
    if tag == 7 {
        return make_planner_project(
            step, operands,
            flow_slot_index(slots, flow_project_base(instruction)),
            flow_slot_index(slots, flow_project_result(instruction)),
            !flow_project_is_partial(instruction))
    }
    if tag == 8 {
        let source_role = flow_capture_source_role(instruction)
        let target_index = flow_slot_index(
            slots, flow_capture_target(instruction))
        let target_owns = flow_storage_contract_tag(flow_slot_storage_contract(
            slots.get(target_index).unwrap())) == 0
        let target_role_owned = flow_role_is_owned(
            flow_capture_target_role(instruction))
        if target_owns != target_role_owned {
            panic("ResourcePlanner: capture target storage/role differs")
        }
        return make_planner_capture(
            step, operands,
            flow_slot_index(slots, flow_capture_source(instruction)),
            target_index, transfer_demand_from_flow_role(source_role))
    }
    if tag == 9 { return make_planner_noop(step, operands) }
    if tag == 10 {
        return make_planner_scope_exit(step, operands, flow_scope_ref_ordinal(
            flow_scope_instruction_scope(instruction)))
    }
    if tag == 11 {
        return make_planner_consume(
            step, operands,
            flow_slot_index(slots, flow_fail_raise_payload(instruction)),
            true, some(flow_slot_index(
                slots, flow_fail_raise_sink(instruction))))
    }
    panic("ResourcePlanner: unknown FlowIR instruction kind")
}

fn planner_callable_location_from_flow(
    value: FlowCallableLocation, slots: List<FlowSlot>
) -> PlannerCallableLocation {
    if flow_callable_location_is_slot(value) {
        return make_planner_callable_slot_location(flow_slot_index(
            slots, flow_callable_location_slot(value)))
    }
    make_planner_callable_projection_location(
        flow_slot_index(slots, flow_callable_location_base(value)),
        flow_callable_location_projection(value))
}

fn planner_callable_provenance_from_flow(
    instruction: FlowInstruction, slots: List<FlowSlot>,
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>
) -> List<PlannerCallableProvenance> {
    let mut result: List<PlannerCallableProvenance> = []
    for fact in flow_instruction_callable_provenance(
            instruction, slots, type_nodes) {
        let target = planner_callable_location_from_flow(
            flow_callable_provenance_target(fact), slots)
        let origin = flow_callable_provenance_origin(fact)
        if flow_callable_origin_is_direct(origin) {
            result.push(make_direct_planner_callable_provenance(
                target, flow_callable_index(
                    callables, flow_callable_origin_direct(origin))))
        } else if flow_callable_origin_is_call(origin) {
            let mut arguments: List<Int> = []
            for argument in flow_callable_origin_call_arguments(origin) {
                arguments.push(flow_slot_index(slots, argument))
            }
            result.push(make_call_planner_callable_provenance(
                target,
                planner_call_target_from_flow(
                    flow_callable_origin_call_target(origin),
                    slots, callables),
                arguments))
        } else {
            let mut sources: List<PlannerCallableLocation> = []
            for source in flow_callable_origin_locations(origin) {
                sources.push(planner_callable_location_from_flow(source, slots))
            }
            result.push(make_locations_planner_callable_provenance(
                target, sources))
        }
    }
    result
}

fn planner_event_from_flow(
    instruction: FlowInstruction, slots: List<FlowSlot>,
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>
) -> PlannerEvent {
    with_planner_callable_provenance(
        planner_event_value_from_flow(instruction, slots, callables),
        planner_callable_provenance_from_flow(
            instruction, slots, type_nodes, callables))
}

fn planner_terminator_uses_from_flow(
    operands: List<FlowOperandRef>, terminator: FlowTerminator,
    slots: List<FlowSlot>,
    return_demand: TransferDemand
) -> List<PlannerTerminatorUse> {
    let mut result: List<PlannerTerminatorUse> = []
    let tag = flow_terminator_kind_tag(terminator)
    for operand in operands {
        let reference = flow_operand_slot(operand)
        result.push(make_planner_terminator_use(
            flow_operand_step(operand), flow_operand_ordinal(operand),
            flow_slot_index(slots, reference), reference,
            if tag == 3 {
                return_demand
            } else {
                transfer_demand_from_flow_role(flow_operand_role(operand))
            }))
    }
    result
}

fn exited_scope_ids(scopes: List<FlowScopeRef>) -> List<Int> {
    let mut result: List<Int> = []
    for scope in scopes { result.push(flow_scope_ref_ordinal(scope)) }
    result
}

fn planner_edges_from_flow(terminator: FlowTerminator) -> List<PlannerEdge> {
    let mut result: List<PlannerEdge> = []
    let successors = flow_terminator_successors(terminator)
    for successor in successors {
        result.push(make_planner_edge(
            some(flow_block_ref_ordinal(flow_successor_target(successor))),
            exited_scope_ids(flow_successor_exited_scopes(successor))))
    }
    if result.len() == 0 {
        let tag = flow_terminator_kind_tag(terminator)
        if tag != 3 && tag != 8 && tag != 9 {
            panic("ResourcePlanner: non-terminal FlowIR block has no successor")
        }
        result.push(make_planner_edge(
            none, exited_scope_ids(
                flow_terminator_terminal_exited_scopes(terminator))))
    }
    result
}

fn planner_body_from_flow(
    body: FlowBody, type_nodes: List<FlowTypeNode>,
    callables: List<FlowCallable>
) -> PlannerBody {
    let flow_slots = flow_body_slots(body)
    let callable = callables.get(flow_callable_index(
        callables, flow_body_reference(body))).unwrap()
    let return_demand = transfer_demand_from_flow_role(
        flow_call_contract_result_role(
            flow_callable_semantic_contract(callable)))
    let scopes = flow_body_scopes(body)
    let mut planner_scopes: List<PlannerScope> = []
    for scope in scopes {
        let reference = flow_scope_reference(scope)
        planner_scopes.push(make_planner_scope(
            flow_scope_ref_ordinal(reference),
            flow_scope_depth(scopes, reference)))
    }
    let mut slots: List<PlannerSlot> = []
    for slot in flow_slots {
        let scope = flow_slot_scope(slot)
        slots.push(make_planner_slot(
            flow_slot_reference(slot),
            core_type_ref_index(flow_slot_type(slot)),
            flow_scope_ref_ordinal(scope), flow_scope_depth(scopes, scope),
            flow_slot_reverse_ordinal(slot),
            if flow_storage_class_tag(flow_slot_storage(slot)) == 0 {
                some(flow_slot_parameter_ordinal(slot))
            } else { none },
            flow_initial_slot_state_tag(flow_slot_initial_state(slot)) == 1,
            flow_storage_contract_tag(flow_slot_storage_contract(slot)) == 0))
    }
    let mut blocks: List<PlannerBlock> = []
    let mut expected_block = 0
    for block in flow_body_blocks(body) {
        let block_ref = flow_block_reference(block)
        if flow_block_ref_ordinal(block_ref) != expected_block {
            panic("ResourcePlanner: FlowIR block order drifted")
        }
        let mut events: List<PlannerEvent> = []
        for instruction in flow_block_instructions(block) {
            events.push(planner_event_from_flow(
                instruction, flow_slots, type_nodes, callables))
        }
        let terminator = flow_block_terminator(block)
        blocks.push(make_planner_block(
            flow_terminator_kind_tag(terminator), events,
            planner_terminator_uses_from_flow(
                flow_block_terminator_operands(block),
                terminator, flow_slots, return_demand),
            planner_edges_from_flow(terminator)))
        expected_block = expected_block + 1
    }
    make_planner_body(
        flow_body_reference(body), planner_scopes, slots,
        flow_block_ref_ordinal(flow_body_entry(body)), blocks)
}

fn make_frozen_planner_input_from_flow(
    program: FlowProgram
) -> FrozenPlannerInput {
    validate_flow_program(program)
    let flow_types = flow_program_type_nodes(program)
    let arities = compute_flow_type_arities(flow_types)
    let mut types: List<PlannerTypeNode> = []
    let mut type_index = 0
    while type_index < flow_types.len() {
        let node = flow_types.get(type_index).unwrap()
        if core_type_ref_index(flow_type_node_reference(node)) != type_index {
            panic("ResourcePlanner: FlowIR type order drifted")
        }
        types.push(planner_type_node_from_flow(
            node, arities.get(type_index).unwrap()))
        type_index = type_index + 1
    }
    let flow_callables = flow_program_callables(program)
    let flow_bodies = flow_program_bodies(program)
    let mut callables: List<PlannerCallable> = []
    for callable in flow_callables {
        callables.push(planner_callable_from_flow(
            callable, flow_bodies))
    }
    let mut bodies: List<PlannerBody> = []
    for body in flow_bodies {
        bodies.push(planner_body_from_flow(
            body, flow_types, flow_callables))
    }
    let candidate_graph = build_candidate_proof_graph(types, callables, bodies)
    let candidate_base_proof = solve_candidate_proof_graph(candidate_graph)
    let candidate_proof = with_candidate_selections(
        candidate_base_proof,
        derive_candidate_selections(candidate_base_proof, types, bodies))
    let candidate_closed_bodies = resolve_bodies_from_candidate_proof(
        candidate_proof, types, bodies)
    make_frozen_planner_input(
        flow_topology_fingerprint_canonical(
            flow_program_topology_fingerprint(program)),
        candidate_proof,
        types, callables, candidate_closed_bodies)
}

// ============================================================
// Public planning result and verifier boundary
// ============================================================

struct PlannedResources {
    logical_shapes: List<LogicalOwnershipShape>,
    physical_shapes: List<PhysicalRcShape>,
    callable_demands: List<List<TransferDemand>>,
    callable_results_owned: List<Bool>,
    rc_program: RcProgram,
    certificate: ResourceCertificate
}

fn copy_logical_shapes(
    values: List<LogicalOwnershipShape>
) -> List<LogicalOwnershipShape> {
    let mut result: List<LogicalOwnershipShape> = []
    for value in values {
        result.push(make_logical_ownership_shape(
            logical_ownership_shape_direct_drop(value),
            logical_ownership_shape_may_unique(value),
            logical_ownership_shape_param_deps(value)))
    }
    result
}

fn copy_physical_shapes(
    values: List<PhysicalRcShape>
) -> List<PhysicalRcShape> {
    let mut result: List<PhysicalRcShape> = []
    for value in values {
        result.push(make_physical_rc_shape(
            physical_rc_shape_physical_rc(value),
            physical_rc_shape_boxing(value),
            physical_rc_shape_drop_glue(value),
            physical_rc_shape_foreign_containment(value),
            physical_rc_shape_param_deps(value)))
    }
    result
}

fn copy_callable_demands(
    values: List<List<TransferDemand>>
) -> List<List<TransferDemand>> {
    let mut result: List<List<TransferDemand>> = []
    for demands in values {
        let mut copied: List<TransferDemand> = []
        for demand in demands {
            copied.push(make_transfer_demand(
                transfer_demand_mode(demand),
                transfer_demand_force(demand)))
        }
        result.push(copied)
    }
    result
}

fn plan_resources(
    input: FrozenPlannerInput, solved: SolvedResourceGraph
) -> PlannedResources {
    let mut rc_bodies: List<RcBody> = []
    let mut cfg_certificates: List<CfgBodyCertificate> = []
    for body in solved.bodies {
        let planned = plan_body(body, solved)
        rc_bodies.push(planned.rc_body)
        cfg_certificates.push(planned.certificate)
    }
    let rc_program = make_rc_program(
        input.flow_fingerprint, input.type_nodes.len(),
        input.callables.len(), rc_bodies)
    let certificate = make_resource_certificate(
        input.flow_fingerprint, input.candidate_proof,
        solved.fixed_point, cfg_certificates)
    if rc_program_flow_fingerprint(rc_program) != input.flow_fingerprint {
        panic("ResourcePlanner: RcIR changed frozen FlowIR identity")
    }
    PlannedResources {
        logical_shapes: copy_logical_shapes(solved.logical_shapes),
        physical_shapes: copy_physical_shapes(solved.physical_shapes),
        callable_demands: copy_callable_demands(solved.callable_demands),
        callable_results_owned: solved.callable_results_owned,
        rc_program: rc_program,
        certificate: certificate
    }
}
// The only public acceptance token. RcIR/certificate constructors remain data
// builders; downstream codegen/verifier entrypoints must require this wrapper,
// which can only be produced from an actual validated FlowProgram.
pub struct VerifiedResourceProgram {
    flow_fingerprint: Str,
    rc_program: RcProgram,
    certificate: ResourceCertificate
}

enum PlanningOutcomeValue {
    PlanningFailedValue(List<ResourceDiagnostic>),
    PlanningVerifiedValue(VerifiedResourceProgram)
}

pub struct PlanningOutcome { value: PlanningOutcomeValue }

pub fn planning_outcome_is_verified(value: PlanningOutcome) -> Bool {
    match value.value {
        PlanningOutcomeValue::PlanningVerifiedValue(_) => true,
        _ => false
    }
}

pub fn planning_outcome_findings(
    value: PlanningOutcome
) -> List<ResourceDiagnostic> {
    match value.value {
        PlanningOutcomeValue::PlanningFailedValue(findings) => findings,
        _ => panic("ResourcePlanner: verified outcome has no findings")
    }
}

pub fn planning_outcome_verified(
    value: PlanningOutcome
) -> VerifiedResourceProgram {
    match value.value {
        PlanningOutcomeValue::PlanningVerifiedValue(verified) => verified,
        _ => panic("ResourcePlanner: failed outcome has no verified token")
    }
}

pub fn verify_and_plan_resource_program(
    program: FlowProgram
) -> PlanningOutcome {
    validate_flow_program(program)
    let planning_input = make_frozen_planner_input_from_flow(program)
    let build = build_constraint_graph(planning_input)
    let fixed_point = solve_constraint_graph(build)
    let solved = materialize_solved_graph(
        planning_input, build, fixed_point)
    let findings = collect_stable_resource_diagnostics(solved)
    if findings.len() != 0 {
        return PlanningOutcome {
            value: PlanningOutcomeValue::PlanningFailedValue(findings)
        }
    }
    let planned = plan_resources(planning_input, solved)
    // Rebuild rule graphs from the typed adapter facts, but never rerun either
    // fixed-point solver. Ranked certificate promotions prove both solutions.
    verify_candidate_graph_contract(planning_input, planned.certificate)
    let solved = verify_fixed_graph_contract(
        planning_input, planned.certificate)
    verify_rc_topology_contract(
        planning_input, solved, planned.rc_program, planned.certificate)
    verify_resource_certificate(planned.rc_program, planned.certificate)
    PlanningOutcome {
        value: PlanningOutcomeValue::PlanningVerifiedValue(
            VerifiedResourceProgram {
                flow_fingerprint: planning_input.flow_fingerprint,
                rc_program: planned.rc_program,
                certificate: planned.certificate
            })
    }
}

pub fn verified_resource_program_flow_fingerprint(
    value: VerifiedResourceProgram
) -> Str { value.flow_fingerprint }

pub fn verified_resource_program_rc_ir(
    value: VerifiedResourceProgram
) -> RcProgram { value.rc_program }
