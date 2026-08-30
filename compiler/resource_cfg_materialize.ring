// CFG slot-state solve and exact RcIR/certificate materialization.
// Extracted mechanically from resource_planner; abstract transfer, origin/owned
// closure, DropOldPlace emission, cleanup order, and witnesses are unchanged.

use ir_identity::{SlotRef, slot_ref_same}
use flow_ir::{
    FlowInstructionRef,
    make_flow_instruction_ref, make_flow_block_ref,
    make_flow_project_place, flow_projection_contract_result_type,
    flow_semantic_step_is_instruction, flow_semantic_step_instruction,
    flow_instruction_ref_same}
use resource_model::{
    TransferDemand, LogicalOwnershipShape, PhysicalRcShape, SlotFlow,
    param_mode_same, param_mode_bottom, param_mode_borrow,
    param_mode_mut_borrow, param_mode_own,
    transfer_demand_mode, transfer_demand_force,
    logical_ownership_shape_direct_drop,
    logical_ownership_shape_may_unique, logical_ownership_shape_param_deps,
    physical_rc_shape_physical_rc, physical_rc_shape_drop_glue,
    physical_rc_shape_foreign_containment, physical_rc_shape_param_deps,
    copy_slot_flow, slot_flow_cleanup_owner,
    slot_flow_live_owner,
    slot_flow_is_unreachable, slot_flow_is_empty, slot_flow_is_live,
    slot_flow_is_moved, slot_flow_is_maybe_moved,
    slot_flow_same, slot_flow_unreachable, slot_flow_empty,
    slot_flow_moved, slot_flow_join}
use rc_ir::{
    RcBody, RcBlock, RcStep, RcEdge, RcSlot, RcOperation, RcSemanticSite,
    make_rc_body, make_rc_block, make_rc_step, make_rc_edge, make_rc_slot,
    make_rc_clone_at, make_rc_take_at,
    make_rc_drop_at, make_rc_cleanup_at,
    make_rc_drop_old_place_at, make_rc_instruction_site,
    make_rc_terminator_site, make_rc_edge_site,
    rc_site_before_instruction, rc_site_after_instruction}
use resource_certificate::{
    CfgBodyCertificate, CfgBlockCertificate, CfgStepCertificate,
    CfgEntryPromotion, CfgEntryEdgeDerivation,
    CfgEdgeCertificate, SlotTransitionReason, SlotTransitionWitness,
    make_cfg_body_certificate, make_cfg_block_certificate,
    make_cfg_step_certificate, make_cfg_edge_certificate,
    make_cfg_entry_promotion, make_cfg_entry_edge_derivation,
    cfg_edge_certificate_transitions,
    make_slot_transition_witness,
    slot_reason_init_live,
    slot_reason_borrow, slot_reason_mutate,
    slot_reason_clone_source, slot_reason_clone_target,
    slot_reason_take_source, slot_reason_take_target,
    slot_reason_drop, slot_reason_cleanup,
    slot_reason_assign_scalar, slot_reason_call_result,
    slot_reason_scope_end, slot_reason_drop_projected_old}
use resource_type_lfp::{
    FrozenPlannerInput, PlannerBody,
    PlannerEdge, PlannerEvent, PlannerEventValue, PlannerSlot, PlannerPlace,
    PlannerTerminatorUse, TransferDecision,
    ResourceDiagnostic, make_slot_resource_diagnostic,
    make_place_resource_diagnostic, resource_diagnostic_same,
    SolvedResourceGraph, int_list_contains,
    event_decision_transfer,
    flow_callable_index_for_planner,
    make_planner_project_place,
    planner_place_is_slot, planner_place_slot, planner_place_base,
    planner_place_projection, planner_place_value_type}

// ============================================================
// Unified A-prime/S-prime CFG slot-state machine
// ============================================================

fn copy_slot_states(values: List<SlotFlow>) -> List<SlotFlow> {
    let mut result: List<SlotFlow> = []
    for value in values {
        result.push(copy_slot_flow(value))
    }
    result
}

fn slot_states_same(left: List<SlotFlow>, right: List<SlotFlow>) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        if !slot_flow_same(
                left.get(index).unwrap(), right.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}

fn join_slot_states(
    left: List<SlotFlow>, right: List<SlotFlow>
) -> List<SlotFlow> {
    if left.len() != right.len() {
        panic("ResourcePlanner: CFG state arity differs")
    }
    let mut result: List<SlotFlow> = []
    let mut index = 0
    while index < left.len() {
        result.push(slot_flow_join(
            left.get(index).unwrap(), right.get(index).unwrap()))
        index = index + 1
    }
    result
}

fn bool_list_has_true(values: List<Bool>) -> Bool {
    for value in values { if value { return true } }
    false
}

fn logical_shape_may_take(shape: LogicalOwnershipShape) -> Bool {
    logical_ownership_shape_direct_drop(shape) ||
        logical_ownership_shape_may_unique(shape) ||
        bool_list_has_true(logical_ownership_shape_param_deps(shape))
}

fn physical_shape_may_drop(shape: PhysicalRcShape) -> Bool {
    !physical_rc_shape_foreign_containment(shape) &&
       (physical_rc_shape_physical_rc(shape) ||
        physical_rc_shape_drop_glue(shape) ||
        bool_list_has_true(physical_rc_shape_param_deps(shape)))
}

fn type_requires_cleanup(
    logical: LogicalOwnershipShape, physical: PhysicalRcShape
) -> Bool {
    logical_shape_may_take(logical) || physical_shape_may_drop(physical)
}

fn transfer_target_cleanup_owner(
    body: PlannerBody, source: Int, target: Int,
    demand: TransferDemand,
    logical_shapes: List<LogicalOwnershipShape>,
    physical_shapes: List<PhysicalRcShape>
) -> Bool {
    if !param_mode_same(transfer_demand_mode(demand), param_mode_own()) {
        return false
    }
    let type_index = body.slots.get(source).unwrap().type_index
    let owns = transfer_demand_force(demand) || type_requires_cleanup(
        logical_shapes.get(type_index).unwrap(),
        physical_shapes.get(type_index).unwrap())
    if owns && !body.slots.get(target).unwrap().owns_storage {
        panic("ResourcePlanner: owning transfer targets borrowed storage")
    }
    owns
}

fn require_live_state(state: SlotFlow, operation: Str) {
    if !slot_flow_is_live(state) {
        panic("ResourcePlanner: ${operation} requires one exact live slot")
    }
}

fn append_resource_finding(
    mut findings: List<ResourceDiagnostic>, value: ResourceDiagnostic
) {
    for existing in findings {
        if resource_diagnostic_same(existing, value) { return }
    }
    findings.push(value)
}

fn preflight_live_slot(
    body: PlannerBody, event: PlannerEvent,
    operand_ordinal: Int, slot: Int, state: SlotFlow,
    collect: Bool, mut findings: List<ResourceDiagnostic>
) -> Bool {
    if slot_flow_is_unreachable(state) {
        panic("ResourcePlanner: reachable event uses unreachable slot")
    }
    if slot_flow_is_live(state) { return true }
    if !slot_flow_is_empty(state) && !slot_flow_is_moved(state) &&
       !slot_flow_is_maybe_moved(state) {
        panic("ResourcePlanner: unknown unavailable slot state")
    }
    if collect {
        append_resource_finding(findings, make_slot_resource_diagnostic(
            event.step, operand_ordinal,
            body.slots.get(slot).unwrap().reference, state))
    }
    false
}

fn preflight_live_place(
    body: PlannerBody, event: PlannerEvent,
    operand_ordinal: Int, place: PlannerPlace,
    state: SlotFlow, collect: Bool,
    mut findings: List<ResourceDiagnostic>
) -> Bool {
    if slot_flow_is_unreachable(state) {
        panic("ResourcePlanner: reachable event uses unreachable place")
    }
    if slot_flow_is_live(state) { return true }
    if !slot_flow_is_empty(state) && !slot_flow_is_moved(state) &&
       !slot_flow_is_maybe_moved(state) {
        panic("ResourcePlanner: unknown unavailable place state")
    }
    if collect {
        append_resource_finding(findings, make_place_resource_diagnostic(
            event.step, operand_ordinal, place, state))
    }
    let _ = body
    false
}

fn require_writable_state(state: SlotFlow, operation: Str) {
    if slot_flow_is_unreachable(state) {
        panic("ResourcePlanner: ${operation} targets an unreachable slot")
    }
}

fn normalize_reusable_target_abstract(
    mut states: List<SlotFlow>, target: Int, operation: Str
) {
    let before = states.get(target).unwrap()
    if slot_flow_is_unreachable(before) {
        panic("ResourcePlanner: ${operation} targets unreachable storage")
    }
    if slot_flow_is_live(before) {
        panic("ResourcePlanner: ${operation} overwrites live storage")
    }
    if slot_flow_is_maybe_moved(before) &&
       slot_flow_cleanup_owner(before) {
        states.set(target, slot_flow_empty())
    }
}

fn apply_demand_abstract(
    body: PlannerBody, event: PlannerEvent, operand_ordinal: Int,
    slot: Int, demand: TransferDemand,
    logical_shapes: List<LogicalOwnershipShape>,
    mut states: List<SlotFlow>, collect: Bool,
    mut findings: List<ResourceDiagnostic>
) {
    let before = states.get(slot).unwrap()
    let _ = preflight_live_slot(
        body, event, operand_ordinal, slot, before, collect, findings)
    let mode = transfer_demand_mode(demand)
    if param_mode_same(mode, param_mode_bottom()) {
        panic("ResourcePlanner: value edge has Bottom demand")
    }
    let type_index = body.slots.get(slot).unwrap().type_index
    let logical = logical_shapes.get(type_index).unwrap()
    if param_mode_same(mode, param_mode_own()) &&
       (transfer_demand_force(demand) || logical_shape_may_take(logical)) {
        states.set(slot, slot_flow_moved())
    }
}



fn decided_transfer(
    body: PlannerBody, event: PlannerEvent, ordinal: Int
) -> TransferDecision {
    let decision = event_decision_transfer(event.decision, ordinal)
    if decision.slot < 0 || decision.slot >= body.slots.len() ||
       !slot_ref_same(
            decision.reference,
            body.slots.get(decision.slot).unwrap().reference) {
        panic("ResourcePlanner: transfer decision slot identity differs")
    }
    decision
}

fn apply_event_abstract(
    event: PlannerEvent, body: PlannerBody,
    logical_shapes: List<LogicalOwnershipShape>,
    physical_shapes: List<PhysicalRcShape>,
    callable_demands: List<List<TransferDemand>>,
    callable_results_owned: List<Bool>,
    mut states: List<SlotFlow>, collect: Bool,
    mut findings: List<ResourceDiagnostic>
) {
    match event.value {
        PlannerEventValue::NoOpValue => {},
        PlannerEventValue::ScopeExitValue(scope_id) => {
            for slot_index in cleanup_slot_order(body.slots, [scope_id]) {
                let before = states.get(slot_index).unwrap()
                if !slot_flow_is_unreachable(before) {
                    states.set(slot_index, slot_flow_empty())
                }
            }
        },
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, target, ..
        } => {
            normalize_reusable_target_abstract(
                states, target, "Initialize")
            let mut input_index = 0
            while input_index < input_slots.len() {
                apply_demand_abstract(
                    body, event, input_index,
                    input_slots.get(input_index).unwrap(),
                    decided_transfer(body, event, input_index).demand,
                    logical_shapes, states, collect, findings)
                input_index = input_index + 1
            }
            let target_type = body.slots.get(target).unwrap().type_index
            states.set(target, slot_flow_live_owner(
                body.slots.get(target).unwrap().owns_storage &&
                type_requires_cleanup(
                    logical_shapes.get(target_type).unwrap(),
                    physical_shapes.get(target_type).unwrap())))
        },
        PlannerEventValue::ReadValue { source, target } => {
            normalize_reusable_target_abstract(states, target, "Read")
            let demand = decided_transfer(body, event, 0).demand
            apply_demand_abstract(
                body, event, 0, source, demand,
                logical_shapes, states, collect, findings)
            states.set(target, slot_flow_live_owner(
                transfer_target_cleanup_owner(
                    body, source, target, demand,
                    logical_shapes, physical_shapes)))
        },
        PlannerEventValue::MutateValue {
            target, value: input, value_demand
        } => {
            let _ = preflight_live_slot(
                body, event, 0, target, states.get(target).unwrap(),
                collect, findings)
            apply_demand_abstract(
                body, event, 1, input,
                decided_transfer(body, event, 1).demand,
                logical_shapes, states, collect, findings)
        },
        PlannerEventValue::ConsumeValue(slot, force, target) => {
            match target {
                some(value) => normalize_reusable_target_abstract(
                    states, value, "Consume sink"),
                none => {}
            }
            apply_demand_abstract(
                body, event, 0, slot,
                decided_transfer(body, event, 0).demand,
                logical_shapes, states, collect, findings)
            match target {
                some(value) => states.set(value, slot_flow_live_owner(
                    transfer_target_cleanup_owner(
                        body, slot, value,
                        decided_transfer(body, event, 0).demand,
                        logical_shapes, physical_shapes))),
                none => {}
            }
        },
        PlannerEventValue::DiscardValue(slot) => {
            let _ = preflight_live_slot(
                body, event, 0, slot, states.get(slot).unwrap(),
                collect, findings)
            let type_index = body.slots.get(slot).unwrap().type_index
            let logical = logical_shapes.get(type_index).unwrap()
            let physical = physical_shapes.get(type_index).unwrap()
            if physical_shape_may_drop(physical) ||
               logical_shape_may_take(logical) {
                states.set(slot, slot_flow_empty())
            }
        },
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            let _ = preflight_live_slot(
                body, event, 0, rhs_temp, states.get(rhs_temp).unwrap(),
                collect, findings)
            // The semantic event occurs only after its RHS-producing events.
            // Resource materialization later emits Drop-old then Take(temp).
            if planner_place_is_slot(target) {
                let target_slot = planner_place_slot(target)
                require_writable_state(
                    states.get(target_slot).unwrap(), "Assign")
                let target_type = body.slots.get(target_slot).unwrap().type_index
                states.set(target_slot, slot_flow_live_owner(
                    body.slots.get(target_slot).unwrap().owns_storage &&
                    type_requires_cleanup(
                        logical_shapes.get(target_type).unwrap(),
                        physical_shapes.get(target_type).unwrap())))
            } else {
                let base = planner_place_base(target)
                let _ = preflight_live_place(
                    body, event, 1, target, states.get(base).unwrap(),
                    collect, findings)
            }
            states.set(rhs_temp, slot_flow_moved())
        },
        PlannerEventValue::MovePlaceValue { source, target } => {
            normalize_reusable_target_abstract(
                states, target, "MovePlace")
            let source_slot = if planner_place_is_slot(source) {
                planner_place_slot(source)
            } else { planner_place_base(source) }
            if planner_place_is_slot(source) {
                apply_demand_abstract(
                    body, event, 0, source_slot,
                    decided_transfer(body, event, 0).demand,
                    logical_shapes, states, collect, findings)
            } else {
                let _ = preflight_live_place(
                    body, event, 0, source,
                    states.get(source_slot).unwrap(), collect, findings)
                if collect {
                    append_resource_finding(
                        findings, make_place_resource_diagnostic(
                            event.step, 0, source,
                            states.get(source_slot).unwrap()))
                }
            }
            let type_index = if planner_place_is_slot(source) {
                body.slots.get(source_slot).unwrap().type_index
            } else { planner_place_value_type(source) }
            states.set(target, slot_flow_live_owner(
                body.slots.get(target).unwrap().owns_storage &&
                type_requires_cleanup(
                    logical_shapes.get(type_index).unwrap(),
                    physical_shapes.get(type_index).unwrap())))
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            result_owned, result_type_index,
            argument_slots, result_slot, ..
        } => {
            let effective_result_owned = event.decision.result_owned
            match result_slot {
                some(slot) => normalize_reusable_target_abstract(
                    states, slot, "Call result"),
                none => {}
            }
            let mut argument = 0
            while argument < argument_slots.len() {
                apply_demand_abstract(
                    body, event, argument,
                    argument_slots.get(argument).unwrap(),
                    decided_transfer(body, event, argument).demand,
                    logical_shapes, states, collect, findings)
                argument = argument + 1
            }
            match result_slot {
                some(slot) => {
                    let result_logical = logical_shapes.get(
                        result_type_index).unwrap()
                    let result_physical = physical_shapes.get(
                        result_type_index).unwrap()
                    let owner = if effective_result_owned {
                        type_requires_cleanup(result_logical, result_physical)
                    } else if body.slots.get(slot).unwrap().owns_storage &&
                            physical_shape_may_drop(result_physical) {
                        if logical_shape_may_take(result_logical) {
                            panic("ResourcePlanner: borrowed unique result enters owner")
                        }
                        true
                    } else { false }
                    states.set(slot, slot_flow_live_owner(owner))
                },
                none => if effective_result_owned &&
                        (logical_shape_may_take(
                            logical_shapes.get(result_type_index).unwrap()) ||
                         physical_shape_may_drop(
                            physical_shapes.get(result_type_index).unwrap())) {
                    panic("ResourcePlanner: owned call result lacks precreated result slot")
                }
            }
        },
        PlannerEventValue::ProjectValue {
            source, target, projection, value_type_index, partial
        } => {
            normalize_reusable_target_abstract(
                states, target, "Project")
            let demand = decided_transfer(body, event, 0).demand
            let source_live = preflight_live_slot(
                body, event, 0, source, states.get(source).unwrap(),
                collect, findings)
            let logical = logical_shapes.get(value_type_index).unwrap()
            let physical = physical_shapes.get(value_type_index).unwrap()
            let owns_result = param_mode_same(
                transfer_demand_mode(demand), param_mode_own())
            let logical_unique = logical_shape_may_take(logical)
            let needs_clone = owns_result && !logical_unique &&
                physical_shape_may_drop(physical)
            if source_live && collect && owns_result && logical_unique {
                append_resource_finding(
                    findings, make_place_resource_diagnostic(
                        event.step, 0,
                        make_planner_project_place(
                            source, projection, value_type_index,
                            make_flow_project_place(
                                body.slots.get(source).unwrap().reference,
                                projection,
                                flow_projection_contract_result_type(
                                    projection))),
                        slot_flow_moved()))
            }
            if needs_clone && !body.slots.get(target).unwrap().owns_storage {
                panic("ResourcePlanner: owning projection targets borrowed storage")
            }
            if partial && !source_live {
                // Do not manufacture a live pattern binder from an unavailable
                // base; the exact source diagnostic remains authoritative.
                states.set(target, slot_flow_empty())
            } else {
                states.set(target, slot_flow_live_owner(needs_clone))
            }
        },
        PlannerEventValue::CaptureValue { source, target, demand } => {
            normalize_reusable_target_abstract(
                states, target, "Capture")
            apply_demand_abstract(
                body, event, 0, source,
                decided_transfer(body, event, 0).demand,
                logical_shapes, states, collect, findings)
            states.set(target, slot_flow_live_owner(
                transfer_target_cleanup_owner(
                    body, source, target,
                    decided_transfer(body, event, 0).demand,
                    logical_shapes, physical_shapes)))
        }
    }
}

fn apply_terminator_use_abstract(
    body: PlannerBody, usage: PlannerTerminatorUse,
    mut states: List<SlotFlow>, collect: Bool,
    mut findings: List<ResourceDiagnostic>
) {
    let before = states.get(usage.slot).unwrap()
    if slot_flow_is_unreachable(before) {
        panic("ResourcePlanner: reachable terminator uses unreachable slot")
    }
    if !slot_flow_is_live(before) {
        if collect {
            append_resource_finding(findings, make_slot_resource_diagnostic(
                usage.step, usage.operand_ordinal,
                usage.reference, before))
        }
    }
    let mode = transfer_demand_mode(usage.demand)
    if param_mode_same(mode, param_mode_bottom()) {
        panic("ResourcePlanner: terminator demand remains Bottom")
    }
    if param_mode_same(mode, param_mode_own()) {
        states.set(usage.slot, slot_flow_moved())
    }
}

fn cleanup_slot_order(
    slots: List<PlannerSlot>, exited_scope_ids: List<Int>
) -> List<Int> {
    let mut result: List<Int> = []
    for scope_id in exited_scope_ids {
        let mut remaining = 0
        let mut slot_index = 0
        while slot_index < slots.len() {
            if slots.get(slot_index).unwrap().scope_id == scope_id {
                remaining = remaining + 1
            }
            slot_index = slot_index + 1
        }
        while remaining > 0 {
            let mut selected: Int? = none
            slot_index = 0
            while slot_index < slots.len() {
                let slot = slots.get(slot_index).unwrap()
                if slot.scope_id == scope_id &&
                   !int_list_contains(result, slot_index) {
                    match selected {
                        some(current) => if slot.reverse_lexical_ordinal >
                                slots.get(current).unwrap().reverse_lexical_ordinal {
                            selected = some(slot_index)
                        },
                        none => { selected = some(slot_index) }
                    }
                }
                slot_index = slot_index + 1
            }
            match selected {
                some(index) => result.push(index),
                none => panic("ResourcePlanner: reverse lexical cleanup is incomplete")
            }
            remaining = remaining - 1
        }
    }
    result
}

fn apply_edge_cleanup_abstract(
    edge: PlannerEdge, body: PlannerBody,
    solved: SolvedResourceGraph, mut states: List<SlotFlow>
) {
    for result_slot in edge.fresh_result_slots {
        let before = states.get(result_slot).unwrap()
        if !slot_flow_is_empty(before) {
            panic("ResourcePlanner: fresh edge result is not empty")
        }
        let slot = body.slots.get(result_slot).unwrap()
        states.set(result_slot, slot_flow_live_owner(
            slot.owns_storage && type_requires_cleanup(
                solved.logical_shapes.get(slot.type_index).unwrap(),
                solved.physical_shapes.get(slot.type_index).unwrap())))
    }
    for slot_index in cleanup_slot_order(
            body.slots, edge.exited_scope_ids) {
        let before = states.get(slot_index).unwrap()
        if !slot_flow_is_unreachable(before) {
            // Empty/Moved/MaybeMoved are represented by cleared storage;
            // unconditional cleanup is physically safe and normalizes all
            // reachable paths to Empty. Non-owning binders also leave the
            // abstract scope even though they emit no RcIR operation.
            states.set(slot_index, slot_flow_empty())
        }
    }
}

// ============================================================
// Finite body slot-state dataflow
// ============================================================

struct CfgEntryDerivationSeed {
    predecessor_block: Int,
    predecessor_edge: Int,
    predecessor_version: Int,
    entry_states: List<SlotFlow>
}

struct BodyEntrySolution {
    reachable: List<Bool>,
    entry_states: List<List<SlotFlow>>,
    promotions: List<CfgEntryPromotion>,
    derivation_seeds: List<CfgEntryDerivationSeed>,
    findings: List<ResourceDiagnostic>
}

fn cfg_slot_state_rank(value: SlotFlow) -> Int {
    if slot_flow_is_unreachable(value) { return 0 }
    if slot_flow_is_maybe_moved(value) { return 2 }
    1
}

fn append_cfg_reach_promotion(
    mut promotions: List<CfgEntryPromotion>, update_id: Int,
    target_block: Int,
    predecessor_block: Int?, predecessor_edge: Int?,
    predecessor_version: Int?, derivation_index: Int?,
    rank_total: Int, rank_budget: Int
) -> Int {
    promotions.push(make_cfg_entry_promotion(
        promotions.len(), update_id, target_block, none,
        predecessor_block, predecessor_edge,
        predecessor_version, derivation_index,
        none, none, 0, 1))
    let next = rank_total + 1
    if next > rank_budget {
        panic("ResourcePlanner: CFG promotion rank budget exceeded")
    }
    next
}

fn append_cfg_slot_promotion(
    mut promotions: List<CfgEntryPromotion>, update_id: Int,
    target_block: Int,
    slot_index: Int, predecessor_block: Int?, predecessor_edge: Int?,
    predecessor_version: Int?, derivation_index: Int?,
    before: SlotFlow, after: SlotFlow,
    rank_total: Int, rank_budget: Int
) -> Int {
    let from_rank = cfg_slot_state_rank(before)
    let to_rank = cfg_slot_state_rank(after)
    promotions.push(make_cfg_entry_promotion(
        promotions.len(), update_id, target_block, some(slot_index),
        predecessor_block, predecessor_edge,
        predecessor_version, derivation_index,
        some(before), some(after), from_rank, to_rank))
    let next = rank_total + (to_rank - from_rank)
    if next > rank_budget {
        panic("ResourcePlanner: CFG promotion rank budget exceeded")
    }
    next
}

fn append_cfg_derivation_seed(
    mut seeds: List<CfgEntryDerivationSeed>,
    predecessor_block: Int, predecessor_edge: Int,
    predecessor_version: Int, entry_states: List<SlotFlow>
) -> Int {
    let index = seeds.len()
    seeds.push(CfgEntryDerivationSeed {
        predecessor_block: predecessor_block,
        predecessor_edge: predecessor_edge,
        predecessor_version: predecessor_version,
        entry_states: copy_slot_states(entry_states)
    })
    index
}

fn body_entry_slot_state(
    body: PlannerBody, callable_index: Int, slot_index: Int,
    solved: SolvedResourceGraph
) -> SlotFlow {
    let slot = body.slots.get(slot_index).unwrap()
    if !slot.initially_live { return slot_flow_empty() }
    let owner = match slot.parameter_ordinal {
        some(parameter) => {
            let demands = solved.callable_demands.get(callable_index).unwrap()
            if parameter < 0 || parameter >= demands.len() {
                panic("ResourcePlanner: entry parameter demand is absent")
            }
            param_mode_same(
                transfer_demand_mode(demands.get(parameter).unwrap()),
                param_mode_own()) &&
                type_requires_cleanup(
                    solved.logical_shapes.get(slot.type_index).unwrap(),
                    solved.physical_shapes.get(slot.type_index).unwrap())
        },
        // Closure captures and borrowed EffectCtx carriers are environment-
        // owned. A call observes them but never cleans them as per-call args;
        // owned child overlays are ordinary local slots and follow all-exit
        // cleanup below.
        none => false
    }
    slot_flow_live_owner(owner)
}

fn solve_body_entry_states(
    body: PlannerBody, callable_index: Int, solved: SolvedResourceGraph
) -> BodyEntrySolution {
    let mut reachable: List<Bool> = []
    let mut entry_states: List<List<SlotFlow>> = []
    let mut versions: List<Int> = []
    let mut block_index = 0
    while block_index < body.blocks.len() {
        reachable.push(false)
        versions.push(0)
        let mut states: List<SlotFlow> = []
        for _ in body.slots { states.push(slot_flow_unreachable()) }
        entry_states.push(states)
        block_index = block_index + 1
    }
    let mut seed: List<SlotFlow> = []
    let mut slot_index = 0
    while slot_index < body.slots.len() {
        seed.push(body_entry_slot_state(
            body, callable_index, slot_index, solved))
        slot_index = slot_index + 1
    }
    // Reachability contributes one rank per block; each SlotFlow cell has
    // finite height two. One edge evaluation is one atomic update group, so
    // every changed target slot is justified by the same predecessor version.
    let exact_rank_budget = body.blocks.len() *
        (body.slots.len() * 2 + 1)
    let mut promotions: List<CfgEntryPromotion> = []
    let mut derivation_seeds: List<CfgEntryDerivationSeed> = []
    let mut promotion_rank = append_cfg_reach_promotion(
        promotions, 0, body.entry_block,
        none, none, none, none, 0, exact_rank_budget)
    slot_index = 0
    while slot_index < seed.len() {
        promotion_rank = append_cfg_slot_promotion(
            promotions, 0, body.entry_block, slot_index,
            none, none, none, none,
            slot_flow_unreachable(), seed.get(slot_index).unwrap(),
            promotion_rank, exact_rank_budget)
        slot_index = slot_index + 1
    }
    reachable.set(body.entry_block, true)
    entry_states.set(body.entry_block, seed)
    versions.set(body.entry_block, 1)

    let mut changed = true
    while changed {
        changed = false
        block_index = 0
        while block_index < body.blocks.len() {
            if reachable.get(block_index).unwrap() {
                let block = body.blocks.get(block_index).unwrap()
                let mut edge_index = 0
                while edge_index < block.edges.len() {
                    let edge = block.edges.get(edge_index).unwrap()
                    match edge.target_block {
                        some(target) => {
                            // A self-edge may promote this block before its
                            // next outgoing edge. Derive every edge from the
                            // exact current entry revision claimed below.
                            let source_version = versions.get(
                                block_index).unwrap()
                            let source_entry_states = copy_slot_states(
                                entry_states.get(block_index).unwrap())
                            let edge_states = copy_slot_states(
                                source_entry_states)
                            let mut ignored: List<ResourceDiagnostic> = []
                            for event in block.events {
                                apply_event_abstract(
                                    event, body, solved.logical_shapes,
                                    solved.physical_shapes,
                                    solved.callable_demands,
                                    solved.callable_results_owned,
                                    edge_states, false, ignored)
                            }
                            for usage in block.terminator_uses {
                                apply_terminator_use_abstract(
                                    body, usage, edge_states,
                                    false, ignored)
                            }
                            apply_edge_cleanup_abstract(
                                edge, body, solved, edge_states)
                            if !reachable.get(target).unwrap() {
                                let derivation_index = append_cfg_derivation_seed(
                                    derivation_seeds, block_index, edge_index,
                                    source_version, source_entry_states)
                                let update_id = derivation_index + 1
                                promotion_rank = append_cfg_reach_promotion(
                                    promotions, update_id, target,
                                    some(block_index), some(edge_index),
                                    some(source_version),
                                    some(derivation_index),
                                    promotion_rank, exact_rank_budget)
                                slot_index = 0
                                while slot_index < edge_states.len() {
                                    promotion_rank = append_cfg_slot_promotion(
                                        promotions, update_id,
                                        target, slot_index,
                                        some(block_index), some(edge_index),
                                        some(source_version),
                                        some(derivation_index),
                                        slot_flow_unreachable(),
                                        edge_states.get(slot_index).unwrap(),
                                        promotion_rank, exact_rank_budget)
                                    slot_index = slot_index + 1
                                }
                                reachable.set(target, true)
                                entry_states.set(target, edge_states)
                                versions.set(
                                    target,
                                    versions.get(target).unwrap() + 1)
                                changed = true
                            } else {
                                let previous = entry_states.get(target).unwrap()
                                let joined = join_slot_states(previous, edge_states)
                                if !slot_states_same(previous, joined) {
                                    let derivation_index =
                                        append_cfg_derivation_seed(
                                            derivation_seeds,
                                            block_index, edge_index,
                                            source_version,
                                            source_entry_states)
                                    let update_id = derivation_index + 1
                                    slot_index = 0
                                    while slot_index < joined.len() {
                                        let before = previous.get(slot_index).unwrap()
                                        let after = joined.get(slot_index).unwrap()
                                        if !slot_flow_same(before, after) {
                                            promotion_rank = append_cfg_slot_promotion(
                                                promotions, update_id,
                                                target, slot_index,
                                                some(block_index), some(edge_index),
                                                some(source_version),
                                                some(derivation_index),
                                                before, after,
                                                promotion_rank, exact_rank_budget)
                                        }
                                        slot_index = slot_index + 1
                                    }
                                    entry_states.set(target, joined)
                                    versions.set(
                                        target,
                                        versions.get(target).unwrap() + 1)
                                    changed = true
                                }
                            }
                        },
                        none => {}
                    }
                    edge_index = edge_index + 1
                }
            }
            block_index = block_index + 1
        }
    }
    let mut findings: List<ResourceDiagnostic> = []
    block_index = 0
    while block_index < body.blocks.len() {
        if reachable.get(block_index).unwrap() {
            let block = body.blocks.get(block_index).unwrap()
            let states = copy_slot_states(
                entry_states.get(block_index).unwrap())
            for event in block.events {
                apply_event_abstract(
                    event, body, solved.logical_shapes,
                    solved.physical_shapes, solved.callable_demands,
                    solved.callable_results_owned, states, true, findings)
            }
            for usage in block.terminator_uses {
                apply_terminator_use_abstract(
                    body, usage, states, true, findings)
            }
        }
        block_index = block_index + 1
    }
    BodyEntrySolution {
        reachable: reachable,
        entry_states: entry_states,
        promotions: promotions,
        derivation_seeds: derivation_seeds,
        findings: findings
    }
}

pub fn collect_stable_resource_diagnostics(
    input: FrozenPlannerInput, solved: SolvedResourceGraph
) -> List<ResourceDiagnostic> {
    // Bodies, blocks, events, and operands are all frozen in exact ordinal
    // order. Diagnostics are collected only after the CFG join reaches its
    // fixed point, so first occurrence is the stable exact-key sort order.
    let mut result: List<ResourceDiagnostic> = []
    for body in solved.bodies {
        let callable_index = flow_callable_index_for_planner(
            input.callables, body.reference)
        let solution = solve_body_entry_states(
            body, callable_index, solved)
        for finding in solution.findings {
            append_resource_finding(result, finding)
        }
    }
    result
}

fn rc_slot_for(body: PlannerBody, index: Int) -> SlotRef {
    body.slots.get(index).unwrap().reference
}

fn push_transition(
    mut transitions: List<SlotTransitionWitness>, slot: Int,
    before: SlotFlow, after: SlotFlow,
    reason: SlotTransitionReason
) {
    transitions.push(make_slot_transition_witness(
        slot, before, after, reason))
}

fn apply_demand_materialized(
    body: PlannerBody, slot: Int, demand: TransferDemand,
    site: RcSemanticSite, solved: SolvedResourceGraph,
    target: Int?, mut states: List<SlotFlow>,
    mut operations: List<RcOperation>,
    mut transitions: List<SlotTransitionWitness>
) {
    let before = states.get(slot).unwrap()
    require_live_state(before, "materialized value edge")
    let mode = transfer_demand_mode(demand)
    if param_mode_same(mode, param_mode_bottom()) {
        panic("ResourcePlanner: materialized value edge has Bottom demand")
    }
    if param_mode_same(mode, param_mode_borrow()) {
        push_transition(transitions, slot, before, before, slot_reason_borrow())
        return
    }
    if param_mode_same(mode, param_mode_mut_borrow()) {
        push_transition(transitions, slot, before, before, slot_reason_mutate())
        return
    }
    if !param_mode_same(mode, param_mode_own()) {
        panic("ResourcePlanner: materialized value edge has invalid mode")
    }
    let type_index = body.slots.get(slot).unwrap().type_index
    let logical = solved.logical_shapes.get(type_index).unwrap()
    let physical = solved.physical_shapes.get(type_index).unwrap()
    let target_ref = match target {
        some(index) => some(rc_slot_for(body, index)),
        none => none
    }
    if transfer_demand_force(demand) || logical_shape_may_take(logical) {
        operations.push(make_rc_take_at(
            site, rc_slot_for(body, slot), target_ref))
        states.set(slot, slot_flow_moved())
        push_transition(transitions, slot, before,
            slot_flow_moved(), slot_reason_take_source())
    } else if physical_shape_may_drop(physical) {
        operations.push(make_rc_clone_at(
            site, rc_slot_for(body, slot), target_ref))
        push_transition(transitions, slot, before,
            before, slot_reason_clone_source())
    } else {
        push_transition(transitions, slot, before,
            before, slot_reason_borrow())
    }
}

fn normalize_reusable_target_materialized(
    body: PlannerBody, event: PlannerEvent,
    instruction: FlowInstructionRef,
    target: Int, operation: Str,
    solved: SolvedResourceGraph, mut states: List<SlotFlow>,
    mut operations: List<RcOperation>,
    mut transitions: List<SlotTransitionWitness>
) {
    let before = states.get(target).unwrap()
    if slot_flow_is_unreachable(before) {
        panic("ResourcePlanner: ${operation} targets unreachable storage")
    }
    if slot_flow_is_live(before) {
        panic("ResourcePlanner: ${operation} overwrites live storage")
    }
    if slot_flow_is_maybe_moved(before) &&
       slot_flow_cleanup_owner(before) {
        let slot = body.slots.get(target).unwrap()
        if !type_requires_cleanup(
                solved.logical_shapes.get(slot.type_index).unwrap(),
                solved.physical_shapes.get(slot.type_index).unwrap()) {
            panic("ResourcePlanner: reusable target owner lacks cleanup shape")
        }
        operations.push(make_rc_drop_at(
            make_rc_instruction_site(
                instruction, rc_site_before_instruction(),
                event.operands.len()),
            rc_slot_for(body, target)))
        states.set(target, slot_flow_empty())
        push_transition(
            transitions, target, before,
            slot_flow_empty(), slot_reason_drop())
    }
}

struct MaterializedStep {
    step: RcStep,
    certificate: CfgStepCertificate
}

fn materialize_event(
    body: PlannerBody, block_index: Int,
    event: PlannerEvent, event_index: Int,
    solved: SolvedResourceGraph, mut states: List<SlotFlow>
) -> MaterializedStep {
    let reconstructed = make_flow_instruction_ref(
        body.reference, block_index, event_index)
    if !flow_semantic_step_is_instruction(event.step) ||
       !flow_instruction_ref_same(
            flow_semantic_step_instruction(event.step), reconstructed) {
        panic("ResourcePlanner: exact event step/topology differs")
    }
    let instruction = flow_semantic_step_instruction(event.step)
    let mut before_ops: List<RcOperation> = []
    let mut after_ops: List<RcOperation> = []
    let before_transitions: List<SlotTransitionWitness> = []
    let semantic_transitions: List<SlotTransitionWitness> = []
    let after_transitions: List<SlotTransitionWitness> = []
    match event.value {
        PlannerEventValue::NoOpValue => {},
        PlannerEventValue::ScopeExitValue(scope_id) => {
            for slot_index in cleanup_slot_order(body.slots, [scope_id]) {
                let slot = body.slots.get(slot_index).unwrap()
                let before = states.get(slot_index).unwrap()
                if !slot_flow_is_unreachable(before) {
                    let logical = solved.logical_shapes.get(
                        slot.type_index).unwrap()
                    let physical = solved.physical_shapes.get(
                        slot.type_index).unwrap()
                    if slot_flow_cleanup_owner(before) &&
                       type_requires_cleanup(logical, physical) {
                        before_ops.push(make_rc_cleanup_at(
                            make_rc_instruction_site(
                                instruction, rc_site_before_instruction(),
                                slot_index), slot.reference))
                        push_transition(before_transitions, slot_index, before,
                            slot_flow_empty(), slot_reason_cleanup())
                    } else {
                        push_transition(before_transitions, slot_index, before,
                            slot_flow_empty(), slot_reason_scope_end())
                    }
                    states.set(slot_index, slot_flow_empty())
                }
            }
        },
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, target, ..
        } => {
            normalize_reusable_target_materialized(
                body, event, instruction, target, "Initialize",
                solved, states, before_ops, before_transitions)
            let mut input_index = 0
            while input_index < input_slots.len() {
                apply_demand_materialized(
                    body, input_slots.get(input_index).unwrap(),
                    decided_transfer(body, event, input_index).demand,
                    make_rc_instruction_site(
                        instruction, rc_site_before_instruction(), input_index),
                    solved, none, states, before_ops, before_transitions)
                input_index = input_index + 1
            }
            let before = states.get(target).unwrap()
            let target_type = body.slots.get(target).unwrap().type_index
            let target_state = slot_flow_live_owner(
                body.slots.get(target).unwrap().owns_storage &&
                type_requires_cleanup(
                    solved.logical_shapes.get(target_type).unwrap(),
                    solved.physical_shapes.get(target_type).unwrap()))
            states.set(target, target_state)
            push_transition(semantic_transitions, target, before,
                target_state, slot_reason_init_live())
        },
        PlannerEventValue::ReadValue { source, target } => {
            normalize_reusable_target_materialized(
                body, event, instruction, target, "Read",
                solved, states, before_ops, before_transitions)
            let source_before = states.get(source).unwrap()
            let target_before = states.get(target).unwrap()
            require_live_state(source_before, "read")
            let demand = decided_transfer(body, event, 0).demand
            apply_demand_materialized(
                body, source, demand,
                make_rc_instruction_site(
                    instruction, rc_site_before_instruction(), 0),
                solved, some(target),
                states, before_ops, before_transitions)
            let target_state = slot_flow_live_owner(
                transfer_target_cleanup_owner(
                    body, source, target, demand,
                    solved.logical_shapes, solved.physical_shapes))
            states.set(target, target_state)
            let type_index = body.slots.get(source).unwrap().type_index
            let target_reason = if logical_shape_may_take(
                    solved.logical_shapes.get(type_index).unwrap()) &&
                    body.slots.get(target).unwrap().owns_storage {
                slot_reason_take_target()
            } else if physical_shape_may_drop(
                    solved.physical_shapes.get(type_index).unwrap()) &&
                    body.slots.get(target).unwrap().owns_storage {
                slot_reason_clone_target()
            } else {
                slot_reason_assign_scalar()
            }
            push_transition(semantic_transitions, target, target_before,
                target_state, target_reason)
        },
        PlannerEventValue::MutateValue {
            target, value: input, value_demand
        } => {
            let target_before = states.get(target).unwrap()
            require_live_state(target_before, "mutation target")
            push_transition(semantic_transitions, target, target_before,
                target_before, slot_reason_mutate())
            apply_demand_materialized(
                body, input, decided_transfer(body, event, 1).demand,
                make_rc_instruction_site(
                    instruction, rc_site_before_instruction(), 1),
                solved, none,
                states, before_ops, before_transitions)
        },
        PlannerEventValue::ConsumeValue(slot, force, target) => {
            match target {
                some(value) => normalize_reusable_target_materialized(
                    body, event, instruction, value, "Consume sink",
                    solved, states, before_ops, before_transitions),
                none => {}
            }
            let sink_before: SlotFlow? = match target {
                some(value) => some(states.get(value).unwrap()),
                none => none
            }
            apply_demand_materialized(
                body, slot, decided_transfer(body, event, 0).demand,
                make_rc_instruction_site(
                    instruction, rc_site_before_instruction(), 0),
                solved, target, states, before_ops, before_transitions)
            match target {
                some(value) => {
                    let target_state = slot_flow_live_owner(
                        transfer_target_cleanup_owner(
                            body, slot, value,
                            decided_transfer(body, event, 0).demand,
                            solved.logical_shapes, solved.physical_shapes))
                    states.set(value, target_state)
                    push_transition(semantic_transitions, value,
                        sink_before.unwrap(), target_state,
                        slot_reason_take_target())
                },
                none => {}
            }
        },
        PlannerEventValue::DiscardValue(slot) => {
            let before = states.get(slot).unwrap()
            require_live_state(before, "discard")
            let type_index = body.slots.get(slot).unwrap().type_index
            let logical = solved.logical_shapes.get(type_index).unwrap()
            let physical = solved.physical_shapes.get(type_index).unwrap()
            if slot_flow_cleanup_owner(before) &&
               type_requires_cleanup(logical, physical) {
                before_ops.push(make_rc_drop_at(
                    make_rc_instruction_site(
                        instruction, rc_site_before_instruction(), 0),
                    rc_slot_for(body, slot)))
                states.set(slot, slot_flow_empty())
                push_transition(before_transitions, slot, before,
                    slot_flow_empty(), slot_reason_drop())
            } else {
                states.set(slot, slot_flow_empty())
                push_transition(before_transitions, slot, before,
                    slot_flow_empty(), slot_reason_scope_end())
            }
        },
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            let rhs_before = states.get(rhs_temp).unwrap()
            require_live_state(rhs_before, "Assign RHS temp")
            let rhs_type = body.slots.get(rhs_temp).unwrap().type_index
            let target_ref: SlotRef? = if planner_place_is_slot(target) {
                let target_slot = planner_place_slot(target)
                let target_before = states.get(target_slot).unwrap()
                require_writable_state(target_before, "Assign")
                let target_type = body.slots.get(target_slot).unwrap().type_index
                let target_logical = solved.logical_shapes.get(target_type).unwrap()
                let target_physical = solved.physical_shapes.get(target_type).unwrap()
                if slot_flow_cleanup_owner(target_before) &&
                   type_requires_cleanup(target_logical, target_physical) {
                    // Exact order: all RHS events already ran; only now Drop old.
                    before_ops.push(make_rc_drop_at(
                        make_rc_instruction_site(
                            instruction, rc_site_before_instruction(), 1),
                        rc_slot_for(body, target_slot)))
                    states.set(target_slot, slot_flow_empty())
                    push_transition(before_transitions, target_slot, target_before,
                        slot_flow_empty(), slot_reason_drop())
                }
                some(rc_slot_for(body, target_slot))
            } else {
                let base = planner_place_base(target)
                let base_before = states.get(base).unwrap()
                require_live_state(base_before, "Assign place base")
                let value_type = planner_place_value_type(target)
                let value_logical = solved.logical_shapes.get(value_type).unwrap()
                let value_physical = solved.physical_shapes.get(value_type).unwrap()
                push_transition(semantic_transitions, base, base_before,
                    base_before, slot_reason_mutate())
                if physical_shape_may_drop(value_physical) ||
                   logical_shape_may_take(value_logical) {
                    before_ops.push(make_rc_drop_old_place_at(
                        make_rc_instruction_site(
                            instruction, rc_site_before_instruction(), 1),
                        rc_slot_for(body, base),
                        planner_place_projection(target)))
                    push_transition(before_transitions, base, base_before,
                        base_before, slot_reason_drop_projected_old())
                }
                none
            }
            // Take saves the already-evaluated temp, clears it, and feeds the
            // existing semantic place. No result temp or binder is created.
            before_ops.push(make_rc_take_at(
                make_rc_instruction_site(
                    instruction, rc_site_before_instruction(), 0),
                rc_slot_for(body, rhs_temp), target_ref))
            states.set(rhs_temp, slot_flow_moved())
            push_transition(before_transitions, rhs_temp, rhs_before,
                slot_flow_moved(), slot_reason_take_source())
            if planner_place_is_slot(target) {
                let target_slot = planner_place_slot(target)
                let before_target_write = states.get(target_slot).unwrap()
                let target_state = slot_flow_live_owner(
                    body.slots.get(target_slot).unwrap().owns_storage &&
                    type_requires_cleanup(
                        solved.logical_shapes.get(rhs_type).unwrap(),
                        solved.physical_shapes.get(rhs_type).unwrap()))
                states.set(target_slot, target_state)
                push_transition(semantic_transitions, target_slot,
                    before_target_write, target_state,
                    if slot_flow_is_empty(before_target_write) {
                        slot_reason_take_target()
                    } else {
                        slot_reason_assign_scalar()
                    })
            }
        },
        PlannerEventValue::MovePlaceValue { source, target } => {
            normalize_reusable_target_materialized(
                body, event, instruction, target, "MovePlace",
                solved, states, before_ops, before_transitions)
            let target_before = states.get(target).unwrap()
            let source_slot = if planner_place_is_slot(source) {
                planner_place_slot(source)
            } else { planner_place_base(source) }
            let type_index = if planner_place_is_slot(source) {
                body.slots.get(source_slot).unwrap().type_index
            } else { planner_place_value_type(source) }
            let logical = solved.logical_shapes.get(type_index).unwrap()
            let physical = solved.physical_shapes.get(type_index).unwrap()
            if planner_place_is_slot(source) {
                apply_demand_materialized(
                    body, source_slot,
                    decided_transfer(body, event, 0).demand,
                    make_rc_instruction_site(
                        instruction, rc_site_before_instruction(), 0),
                    solved, some(target), states,
                    before_ops, before_transitions)
            } else {
                panic("ResourcePlanner: projected move spread crossed diagnostics")
            }
            let target_state = slot_flow_live_owner(
                body.slots.get(target).unwrap().owns_storage &&
                type_requires_cleanup(logical, physical))
            states.set(target, target_state)
            push_transition(
                semantic_transitions, target, target_before, target_state,
                if type_requires_cleanup(logical, physical) {
                    slot_reason_take_target()
                } else { slot_reason_assign_scalar() })
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            result_owned, result_type_index,
            argument_slots, result_slot, ..
        } => {
            let effective_result_owned = event.decision.result_owned
            match result_slot {
                some(slot) => normalize_reusable_target_materialized(
                    body, event, instruction, slot, "Call result",
                    solved, states, before_ops, before_transitions),
                none => {}
            }
            let mut argument = 0
            while argument < argument_slots.len() {
                apply_demand_materialized(
                    body, argument_slots.get(argument).unwrap(),
                    decided_transfer(body, event, argument).demand,
                    make_rc_instruction_site(
                        instruction, rc_site_before_instruction(), argument),
                    solved, none,
                    states, before_ops, before_transitions)
                argument = argument + 1
            }
            match result_slot {
                some(slot) => {
                    let before = states.get(slot).unwrap()
                    let result_logical = solved.logical_shapes.get(
                        result_type_index).unwrap()
                    let result_physical = solved.physical_shapes.get(
                        result_type_index).unwrap()
                    let owner = if effective_result_owned {
                        type_requires_cleanup(result_logical, result_physical)
                    } else if body.slots.get(slot).unwrap().owns_storage &&
                            physical_shape_may_drop(result_physical) {
                        if logical_shape_may_take(result_logical) {
                            panic("ResourcePlanner: borrowed unique result enters owner")
                        }
                        true
                    } else { false }
                    let result_state = slot_flow_live_owner(owner)
                    states.set(slot, result_state)
                    push_transition(semantic_transitions, slot, before,
                        result_state, slot_reason_call_result())
                    if !effective_result_owned &&
                       body.slots.get(slot).unwrap().owns_storage {
                        let type_index = body.slots.get(slot).unwrap().type_index
                        if logical_shape_may_take(
                                solved.logical_shapes.get(type_index).unwrap()) {
                            panic("ResourcePlanner: borrowed unique call result enters owning storage")
                        }
                        if physical_shape_may_drop(
                                solved.physical_shapes.get(type_index).unwrap()) {
                            after_ops.push(make_rc_clone_at(
                                make_rc_instruction_site(
                                    instruction, rc_site_after_instruction(),
                                    argument_slots.len()),
                                rc_slot_for(body, slot), none))
                            push_transition(after_transitions, slot,
                                result_state, result_state,
                                slot_reason_clone_source())
                        }
                    }
                },
                none => if effective_result_owned {
                    let result_type = result_type_index
                    if logical_shape_may_take(
                            solved.logical_shapes.get(result_type).unwrap()) ||
                       physical_shape_may_drop(
                            solved.physical_shapes.get(result_type).unwrap()) {
                        panic("ResourcePlanner: owned call result lacks precreated result slot")
                    }
                }
            }
        },
        PlannerEventValue::ProjectValue {
            source, target, value_type_index, ..
        } => {
            normalize_reusable_target_materialized(
                body, event, instruction, target, "Project",
                solved, states, before_ops, before_transitions)
            let source_before = states.get(source).unwrap()
            require_live_state(source_before, "projection")
            let demand = decided_transfer(body, event, 0).demand
            let logical = solved.logical_shapes.get(value_type_index).unwrap()
            let physical = solved.physical_shapes.get(value_type_index).unwrap()
            let owns_result = param_mode_same(
                transfer_demand_mode(demand), param_mode_own())
            let logical_unique = logical_shape_may_take(logical)
            if owns_result && logical_unique {
                panic("ResourcePlanner: owning field projection crossed diagnostics")
            }
            // A partial projection can still fall through at its guard. The
            // aggregate remains live; shareable ownership is established by
            // cloning the projected result slot below.
            push_transition(
                before_transitions, source, source_before, source_before,
                slot_reason_borrow())
            let before_target_write = states.get(target).unwrap()
            let needs_clone = owns_result &&
                physical_shape_may_drop(physical)
            if needs_clone && !body.slots.get(target).unwrap().owns_storage {
                panic("ResourcePlanner: owning projection targets borrowed storage")
            }
            let target_state = slot_flow_live_owner(needs_clone)
            states.set(target, target_state)
            let target_reason = if needs_clone {
                slot_reason_clone_target()
            } else {
                slot_reason_assign_scalar()
            }
            push_transition(semantic_transitions, target, before_target_write,
                target_state, target_reason)
            if needs_clone {
                after_ops.push(make_rc_clone_at(
                    make_rc_instruction_site(
                        instruction, rc_site_after_instruction(), 0),
                    rc_slot_for(body, target), none))
                push_transition(
                    after_transitions, target, target_state, target_state,
                    slot_reason_clone_source())
            }
        },
        PlannerEventValue::CaptureValue { source, target, demand } => {
            normalize_reusable_target_materialized(
                body, event, instruction, target, "Capture",
                solved, states, before_ops, before_transitions)
            let target_before = states.get(target).unwrap()
            let exact_demand = decided_transfer(body, event, 0).demand
            apply_demand_materialized(
                body, source, exact_demand,
                make_rc_instruction_site(
                    instruction, rc_site_before_instruction(), 0),
                solved, some(target),
                states, before_ops, before_transitions)
            let target_state = slot_flow_live_owner(
                transfer_target_cleanup_owner(
                    body, source, target, exact_demand,
                    solved.logical_shapes, solved.physical_shapes))
            states.set(target, target_state)
            let mode = transfer_demand_mode(exact_demand)
            let type_index = body.slots.get(source).unwrap().type_index
            let reason = if param_mode_same(mode, param_mode_own()) &&
                    (transfer_demand_force(exact_demand) ||
                     logical_shape_may_take(
                        solved.logical_shapes.get(type_index).unwrap())) {
                slot_reason_take_target()
            } else if param_mode_same(mode, param_mode_own()) &&
                    physical_shape_may_drop(
                        solved.physical_shapes.get(type_index).unwrap()) {
                slot_reason_clone_target()
            } else {
                slot_reason_assign_scalar()
            }
            push_transition(semantic_transitions, target, target_before,
                target_state, reason)
        }
    }
    MaterializedStep {
        step: make_rc_step(event_index, instruction, before_ops, after_ops),
        certificate: make_cfg_step_certificate(
            instruction, before_transitions,
            semantic_transitions, after_transitions)
    }
}

struct MaterializedEdge {
    edge: RcEdge,
    certificate: CfgEdgeCertificate
}

fn materialize_edge(
    body: PlannerBody, block_index: Int, terminator_kind: Int,
    edge: PlannerEdge, edge_index: Int,
    solved: SolvedResourceGraph, states_after_block: List<SlotFlow>
) -> MaterializedEdge {
    let mut states = copy_slot_states(states_after_block)
    let mut cleanup_ops: List<RcOperation> = []
    let transitions: List<SlotTransitionWitness> = []
    for result_slot in edge.fresh_result_slots {
        let before = states.get(result_slot).unwrap()
        if !slot_flow_is_empty(before) {
            panic("ResourcePlanner: fresh edge result is not empty")
        }
        let slot = body.slots.get(result_slot).unwrap()
        let after = slot_flow_live_owner(
            slot.owns_storage && type_requires_cleanup(
                solved.logical_shapes.get(slot.type_index).unwrap(),
                solved.physical_shapes.get(slot.type_index).unwrap()))
        states.set(result_slot, after)
        push_transition(
            transitions, result_slot, before, after, slot_reason_init_live())
    }
    for slot_index in cleanup_slot_order(body.slots, edge.exited_scope_ids) {
        let slot = body.slots.get(slot_index).unwrap()
        let before = states.get(slot_index).unwrap()
        if !slot_flow_is_unreachable(before) {
            let mut emitted_cleanup = false
            if slot_flow_cleanup_owner(before) {
                let logical = solved.logical_shapes.get(slot.type_index).unwrap()
                let physical = solved.physical_shapes.get(slot.type_index).unwrap()
                if physical_shape_may_drop(physical) ||
                   logical_shape_may_take(logical) {
                    cleanup_ops.push(make_rc_cleanup_at(
                        make_rc_edge_site(
                            make_flow_block_ref(body.reference, block_index),
                            terminator_kind, edge_index, slot_index),
                        slot.reference))
                    push_transition(transitions, slot_index, before,
                        slot_flow_empty(), slot_reason_cleanup())
                    emitted_cleanup = true
                }
            }
            if !emitted_cleanup {
                push_transition(transitions, slot_index, before,
                    slot_flow_empty(), slot_reason_scope_end())
            }
            states.set(slot_index, slot_flow_empty())
        }
    }
    MaterializedEdge {
        edge: make_rc_edge(edge_index, edge.target_block, cleanup_ops),
        certificate: make_cfg_edge_certificate(
            edge_index, edge.target_block, states, transitions)
    }
}

fn materialize_cfg_entry_derivation(
    body: PlannerBody, solved: SolvedResourceGraph,
    seed: CfgEntryDerivationSeed
) -> CfgEntryEdgeDerivation {
    let block = body.blocks.get(seed.predecessor_block).unwrap()
    let states = copy_slot_states(seed.entry_states)
    let mut steps: List<CfgStepCertificate> = []
    let mut event_index = 0
    while event_index < block.events.len() {
        let materialized = materialize_event(
            body, seed.predecessor_block,
            block.events.get(event_index).unwrap(),
            event_index, solved, states)
        steps.push(materialized.certificate)
        event_index = event_index + 1
    }
    let mut ignored_terminator_ops: List<RcOperation> = []
    let terminator_transitions: List<SlotTransitionWitness> = []
    let mut terminator_operand = 0
    for usage in block.terminator_uses {
        apply_demand_materialized(
            body, usage.slot, usage.demand,
            make_rc_terminator_site(
                make_flow_block_ref(body.reference, seed.predecessor_block),
                block.terminator_kind, terminator_operand),
            solved, none, states,
            ignored_terminator_ops, terminator_transitions)
        terminator_operand = terminator_operand + 1
    }
    let exact_edge = block.edges.get(seed.predecessor_edge).unwrap()
    let materialized_edge = materialize_edge(
        body, seed.predecessor_block, block.terminator_kind,
        exact_edge, seed.predecessor_edge, solved, states)
    make_cfg_entry_edge_derivation(
        seed.predecessor_block, seed.predecessor_edge,
        seed.predecessor_version, steps, terminator_transitions,
        cfg_edge_certificate_transitions(materialized_edge.certificate))
}

fn materialize_cfg_entry_derivations(
    body: PlannerBody, solved: SolvedResourceGraph,
    seeds: List<CfgEntryDerivationSeed>
) -> List<CfgEntryEdgeDerivation> {
    seeds.map(fn(seed) {
        materialize_cfg_entry_derivation(body, solved, seed)
    })
}

pub struct PlannedBody {
    pub rc_body: RcBody,
    pub certificate: CfgBodyCertificate
}

pub fn plan_body(
    body: PlannerBody, callable_index: Int, solved: SolvedResourceGraph
) -> PlannedBody {
    let entry_solution = solve_body_entry_states(
        body, callable_index, solved)
    if entry_solution.findings.len() != 0 {
        panic("ResourcePlanner: materialization received failed preflight")
    }
    let entry_derivations = materialize_cfg_entry_derivations(
        body, solved, entry_solution.derivation_seeds)
    let mut entry_seed: List<SlotFlow> = []
    let mut entry_slot = 0
    while entry_slot < body.slots.len() {
        entry_seed.push(body_entry_slot_state(
            body, callable_index, entry_slot, solved))
        entry_slot = entry_slot + 1
    }
    let mut rc_slots: List<RcSlot> = []
    for slot in body.slots {
        rc_slots.push(make_rc_slot(
            slot.reference, slot.type_index, slot.scope_id,
            slot.scope_depth, slot.reverse_lexical_ordinal))
    }
    let mut rc_blocks: List<RcBlock> = []
    let mut block_certificates: List<CfgBlockCertificate> = []
    let mut block_index = 0
    while block_index < body.blocks.len() {
        let block = body.blocks.get(block_index).unwrap()
        let entry_states = copy_slot_states(
            entry_solution.entry_states.get(block_index).unwrap())
        if !entry_solution.reachable.get(block_index).unwrap() {
            // Frozen but unreachable blocks remain in topology.  Their events
            // receive no resource operations and carry bottom proof states.
            let mut steps: List<RcStep> = []
            let mut step_proofs: List<CfgStepCertificate> = []
            let mut event_index = 0
            while event_index < block.events.len() {
                steps.push(make_rc_step(
                    event_index,
                    make_flow_instruction_ref(
                        body.reference, block_index, event_index),
                    [], []))
                step_proofs.push(make_cfg_step_certificate(
                    make_flow_instruction_ref(
                        body.reference, block_index, event_index),
                    [], [], []))
                event_index = event_index + 1
            }
            let mut edges: List<RcEdge> = []
            let mut edge_proofs: List<CfgEdgeCertificate> = []
            let mut edge_index = 0
            while edge_index < block.edges.len() {
                let edge = block.edges.get(edge_index).unwrap()
                edges.push(make_rc_edge(edge_index, edge.target_block, []))
                edge_proofs.push(make_cfg_edge_certificate(
                    edge_index, edge.target_block, entry_states, []))
                edge_index = edge_index + 1
            }
            rc_blocks.push(make_rc_block(
                block_index,
                make_flow_block_ref(body.reference, block_index),
                block.terminator_kind,
                block.events.len(), steps, [], edges))
            block_certificates.push(make_cfg_block_certificate(
                block_index,
                make_flow_block_ref(body.reference, block_index),
                block.terminator_kind, entry_states,
                step_proofs, [], edge_proofs))
            block_index = block_index + 1
            continue
        }
        let states = copy_slot_states(entry_states)
        let mut steps: List<RcStep> = []
        let mut step_proofs: List<CfgStepCertificate> = []
        let mut event_index = 0
        while event_index < block.events.len() {
            let materialized = materialize_event(
                body, block_index,
                block.events.get(event_index).unwrap(),
                event_index, solved, states)
            steps.push(materialized.step)
            step_proofs.push(materialized.certificate)
            event_index = event_index + 1
        }
        let mut terminator_ops: List<RcOperation> = []
        let terminator_transitions: List<SlotTransitionWitness> = []
        let mut terminator_operand = 0
        for usage in block.terminator_uses {
            apply_demand_materialized(
                body, usage.slot, usage.demand,
                make_rc_terminator_site(
                    make_flow_block_ref(body.reference, block_index),
                    block.terminator_kind, terminator_operand),
                solved, none,
                states, terminator_ops, terminator_transitions)
            terminator_operand = terminator_operand + 1
        }
        let mut edges: List<RcEdge> = []
        let mut edge_proofs: List<CfgEdgeCertificate> = []
        let mut edge_index = 0
        while edge_index < block.edges.len() {
            let materialized = materialize_edge(
                body, block_index, block.terminator_kind,
                block.edges.get(edge_index).unwrap(),
                edge_index, solved, states)
            edges.push(materialized.edge)
            edge_proofs.push(materialized.certificate)
            edge_index = edge_index + 1
        }
        rc_blocks.push(make_rc_block(
            block_index,
            make_flow_block_ref(body.reference, block_index),
            block.terminator_kind,
            block.events.len(), steps, terminator_ops, edges))
        block_certificates.push(make_cfg_block_certificate(
            block_index,
            make_flow_block_ref(body.reference, block_index),
            block.terminator_kind, entry_states,
            step_proofs, terminator_transitions, edge_proofs))
        block_index = block_index + 1
    }
    PlannedBody {
        rc_body: make_rc_body(
            body.reference, rc_slots, body.entry_block, rc_blocks),
        certificate: make_cfg_body_certificate(
            body.entry_block, entry_seed,
            entry_solution.promotions, entry_derivations,
            block_certificates)
    }
}
