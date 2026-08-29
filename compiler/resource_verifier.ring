// Independent reconstruction and verification of resource planning certificates.
// This component rebuilds candidate/type rule graphs and validates exact CFG/RcIR
// event, phase, slot, edge, and operation contracts without rerunning a solver.

use ir_identity::{core_type_ref_index, SlotRef, slot_ref_same, symbol_ref_same}
use ir_inventory::{executable_ref_same}
use core_type_source::{
    FlowGenericParamFact, flow_generic_param_fact_same,
    flow_generic_param_owner,
    flow_generic_param_index, flow_generic_param_arity,
    flow_generic_param_bounds,
    flow_type_substitution_parameter,
    flow_type_substitution_replacement}
use flow_ir::{
    flow_block_ref_same, flow_instruction_ref_same,
    make_flow_instruction_ref, make_flow_block_ref,
    flow_semantic_step_is_instruction,
    flow_semantic_step_instruction, flow_semantic_step_terminator,
    flow_projection_contract_same,
    flow_projection_contract_result_type}
use resource_model::{
    TransferDemand, LogicalOwnershipShape, PhysicalRcShape, SlotFlow,
    param_mode_from_tag, param_mode_tag, param_mode_same,
    param_mode_borrow, param_mode_mut_borrow, param_mode_own,
    make_transfer_demand, transfer_demand_mode, transfer_demand_force,
    transfer_demand_join, make_logical_ownership_shape,
    logical_ownership_shape_direct_drop,
    logical_ownership_shape_may_unique,
    logical_ownership_shape_param_deps, make_physical_rc_shape,
    physical_rc_shape_physical_rc, physical_rc_shape_drop_glue,
    physical_rc_shape_foreign_containment, physical_rc_shape_param_deps,
    slot_flow_same, slot_flow_empty, slot_flow_live_owner,
    slot_flow_cleanup_owner, slot_flow_is_unreachable, slot_flow_is_live,
    slot_flow_is_maybe_moved, slot_flow_unreachable, slot_flow_join}
use rc_ir::{
    RcProgram, RcOperation, rc_program_flow_fingerprint,
    rc_program_type_count, rc_program_callable_count, rc_program_bodies,
    rc_body_reference, rc_body_slots, rc_body_entry_block, rc_body_blocks,
    rc_slot_reference, rc_slot_type_index, rc_slot_scope_id,
    rc_slot_scope_depth, rc_slot_reverse_lexical_ordinal,
    rc_block_source_index, rc_block_source_ref,
    rc_block_terminator_kind, rc_block_semantic_op_count,
    rc_block_steps, rc_block_before_terminator, rc_block_edges,
    rc_step_semantic_op_index, rc_step_instruction,
    rc_step_before, rc_step_after, rc_edge_successor_ordinal,
    rc_edge_target_block, rc_edge_cleanup, rc_operation_site,
    rc_operation_kind, rc_operation_source, rc_operation_target,
    rc_operation_place_projection, rc_op_kind_clone, rc_op_kind_take,
    rc_op_kind_drop,
    rc_op_kind_cleanup, rc_op_kind_drop_old_place, rc_op_kind_same,
    rc_semantic_site_operand_ordinal}
use resource_certificate::{
    ResourceCellKind, ResourceCellSource, ResourceRuleSource,
    ResourceCellSpec, ResourceConstraint, ResourceFixedPointProof,
    ResourceCertificate, CallableCandidateProof,
    CfgBodyCertificate, CfgBlockCertificate, CfgEntryEdgeDerivation,
    CandidateCellKind, CandidateCellSpec,
    CandidateRuleSite, CandidateRuleKind, CandidateRule,
    CandidateSelection, SlotTransitionReason, SlotTransitionWitness,
    make_callable_result_owned_source, make_callable_result_origin_source,
    make_structural_resource_cell_source, make_body_reach_source,
    make_body_slot_origin_source, make_body_slot_owned_source,
    make_body_slot_mode_source, make_body_slot_force_source,
    make_structural_resource_rule_source,
    make_callable_resource_rule_source,
    make_instruction_resource_rule_source,
    make_block_resource_rule_source, make_edge_resource_rule_source,
    make_candidate_cell_spec, make_global_candidate_rule_site,
    make_instruction_candidate_rule_site,
    make_terminator_candidate_rule_site, make_edge_candidate_rule_site,
    make_candidate_rule, make_candidate_selection,
    candidate_cell_parameter, candidate_cell_result, candidate_cell_state,
    candidate_rule_seed, candidate_rule_copy, candidate_rule_all,
    resource_cell_kind_logical_shape,
    resource_cell_kind_physical_shape,
    resource_cell_kind_callable_param_mode,
    resource_cell_kind_callable_force, resource_cell_kind_callable_result,
    resource_cell_kind_callable_result_origin,
    resource_cell_kind_body_slot_origin,
    resource_cell_kind_body_slot_owned,
    resource_cell_kind_body_block_reachable,
    resource_cell_kind_body_slot_mode, resource_cell_kind_body_slot_force,
    resource_cell_spec_max_rank, resource_cell_spec_kind,
    resource_cell_spec_owner_index, resource_cell_spec_component_index,
    resource_cell_spec_source, resource_cell_source_same,
    resource_cell_kind_tag, resource_constraint_rule_tag,
    resource_constraint_target_cell, resource_constraint_floor_rank,
    resource_constraint_premise_cells,
    resource_constraint_requires_all, resource_constraint_source,
    resource_constraint_guard_cell,
    resource_rule_source_same, resource_fixed_point_final_ranks,
    resource_fixed_point_cells, resource_fixed_point_constraints,
    resource_certificate_fixed_point,
    resource_certificate_candidate_proof,
    resource_certificate_cfg_bodies, cfg_body_certificate_blocks,
    cfg_body_certificate_entry_block, cfg_body_certificate_entry_seed,
    cfg_body_certificate_entry_promotions,
    cfg_body_certificate_entry_derivations,
    cfg_block_certificate_index,
    cfg_block_certificate_source_block,
    cfg_block_certificate_terminator_kind,
    cfg_block_certificate_terminator_transitions,
    cfg_block_certificate_entry_states, cfg_block_certificate_steps,
    cfg_block_certificate_edges, cfg_step_certificate_instruction,
    cfg_step_certificate_before, cfg_step_certificate_semantic,
    cfg_step_certificate_after, cfg_edge_certificate_successor_ordinal,
    cfg_edge_certificate_target, cfg_edge_certificate_transitions,
    cfg_entry_promotion_order, cfg_entry_promotion_update_id,
    cfg_entry_promotion_target_block,
    cfg_entry_promotion_slot, cfg_entry_promotion_predecessor_block,
    cfg_entry_promotion_predecessor_edge,
    cfg_entry_promotion_predecessor_version,
    cfg_entry_promotion_derivation_index,
    cfg_entry_promotion_before, cfg_entry_promotion_after,
    cfg_entry_promotion_from_rank, cfg_entry_promotion_to_rank,
    cfg_entry_derivation_predecessor_block,
    cfg_entry_derivation_predecessor_edge,
    cfg_entry_derivation_predecessor_version,
    cfg_entry_derivation_steps,
    cfg_entry_derivation_terminator_transitions,
    cfg_entry_derivation_edge_transitions,
    verify_slot_transition_witness,
    callable_candidate_proof_callable_count,
    callable_candidate_proof_cells, callable_candidate_proof_rules,
    callable_candidate_proof_final_values,
    callable_candidate_proof_selections, candidate_cell_spec_kind,
    candidate_cell_spec_owner, candidate_cell_spec_block,
    candidate_cell_spec_boundary, candidate_cell_spec_component,
    candidate_cell_spec_candidate, candidate_cell_kind_tag,
    candidate_rule_kind, candidate_rule_site,
    candidate_rule_target_cell, candidate_rule_premise_cells,
    candidate_rule_kind_tag, candidate_rule_site_kind_tag,
    candidate_rule_site_instruction, candidate_rule_site_block,
    candidate_rule_site_successor_ordinal,
    candidate_selection_instruction, candidate_selection_candidates,
    slot_reason_init_live, slot_reason_borrow,
    slot_reason_mutate, slot_reason_clone_source,
    slot_reason_clone_target, slot_reason_take_source,
    slot_reason_take_target, slot_reason_drop, slot_reason_cleanup,
    slot_reason_assign_scalar, slot_reason_call_result,
    slot_reason_scope_end, slot_reason_drop_projected_old,
    slot_reason_take_projected_source,
    slot_transition_reason_tag, slot_transition_witness_slot_index,
    slot_transition_witness_before, slot_transition_witness_after,
    slot_transition_witness_reason}
use resource_type_lfp::{
    FrozenPlannerInput, PlannerTypeNode, PlannerCallable, PlannerBody,
    PlannerBlock, PlannerEvent, PlannerEventValue, PlannerEdge,
    PlannerSlot, PlannerCallableOriginValue, PlannerPlace, PlannerCallTarget,
    PlannerCallableLocation, TransferDecision, EventDecision,
    SolvedResourceGraph, planner_event_operand,
    make_transfer_decision, make_event_decision,
    with_planner_event_decision, make_planner_block, make_planner_body,
    planner_type_is_callable,
    planner_place_is_slot, planner_place_slot, planner_place_base,
    planner_place_projection, planner_place_value_type,
    planner_call_target_is_direct, planner_call_target_direct,
    planner_call_target_slot, planner_call_target_type_substitutions,
    make_planner_callable_slot_location,
    make_planner_callable_projection_location,
    planner_callable_location_is_slot, planner_callable_location_slot,
    planner_callable_location_base, planner_callable_location_projection,
    planner_callable_location_same,
    copy_planner_callable_location, flow_callable_index_for_planner,
    planner_body_reachable_blocks, int_list_contains, int_lists_same}

const RULE_TYPE_SEED: Int = 0
const RULE_TYPE_CHILD: Int = 1
const RULE_DIRECT_IMPLIES_UNIQUE: Int = 2
const RULE_CALLABLE_SEED: Int = 3
const RULE_RESULT_ORIGIN_SEED: Int = 6
const RULE_RESULT_ORIGIN_COPY: Int = 7
const RULE_RESULT_ORIGIN_CALL: Int = 8
const RULE_RESULT_OWNED_BODY: Int = 9
const RULE_RESULT_CFG_EDGE: Int = 10
const RULE_LOCAL_CARRY: Int = 11
const RULE_LOCAL_READ: Int = 12
const RULE_LOCAL_CALL: Int = 13
const RULE_LOCAL_RESULT_ORIGIN: Int = 14
const RULE_LOCAL_CFG_EDGE: Int = 15
const RULE_LOCAL_ENTRY_PARAMETER: Int = 16
const RULE_LOCAL_EXPLICIT: Int = 17

struct ExpectedResourceCell {
    kind: ResourceCellKind,
    owner_index: Int,
    component_index: Int,
    max_rank: Int,
    source: ResourceCellSource
}

fn verifier_generic_param_fact_same(
    left: FlowGenericParamFact, right: FlowGenericParamFact
) -> Bool {
    if !symbol_ref_same(
            flow_generic_param_owner(left),
            flow_generic_param_owner(right)) ||
       flow_generic_param_index(left) != flow_generic_param_index(right) ||
       flow_generic_param_arity(left) != flow_generic_param_arity(right) {
        return false
    }
    let left_bounds = flow_generic_param_bounds(left)
    let right_bounds = flow_generic_param_bounds(right)
    if left_bounds.len() != right_bounds.len() { return false }
    let mut index = 0
    while index < left_bounds.len() {
        if !symbol_ref_same(
                left_bounds.get(index).unwrap(),
                right_bounds.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}

fn verifier_dependency_fact_index(
    values: List<FlowGenericParamFact>, target: FlowGenericParamFact
) -> Int {
    let mut index = 0
    while index < values.len() {
        if verifier_generic_param_fact_same(
                values.get(index).unwrap(), target) {
            return index
        }
        index = index + 1
    }
    panic("ResourcePlanner verifier: exact dependency fact is absent")
}

fn verifier_dependency_facts_contain(
    values: List<FlowGenericParamFact>, target: FlowGenericParamFact
) -> Bool {
    values.any(fn(value) {
        verifier_generic_param_fact_same(value, target)
    })
}

fn verify_type_dependency_closure(input: FrozenPlannerInput) {
    for node in input.type_nodes {
        let mut left = 0
        while left < node.resource_dependency_facts.len() {
            let dependency = node.resource_dependency_facts.get(left).unwrap()
            let mut right = left + 1
            while right < node.resource_dependency_facts.len() {
                if verifier_generic_param_fact_same(
                        dependency,
                        node.resource_dependency_facts.get(right).unwrap()) {
                    panic("ResourcePlanner verifier: duplicate exact dependency fact")
                }
                right = right + 1
            }
            let mut exact_seed_exists = false
            for candidate in input.type_nodes {
                match candidate.parameter_fact {
                    some(parameter) => if verifier_generic_param_fact_same(
                            parameter, dependency) {
                        exact_seed_exists = true
                    },
                    none => {}
                }
            }
            if !exact_seed_exists {
                panic("ResourcePlanner verifier: dependency lacks an exact parameter seed")
            }
            let mut witnessed = match node.parameter_fact {
                some(parameter) => verifier_generic_param_fact_same(
                    parameter, dependency),
                none => false
            }
            for child_index in node.child_type_indices {
                if child_index < 0 || child_index >= input.type_nodes.len() {
                    panic("ResourcePlanner verifier: dependency child is outside graph")
                }
                if verifier_dependency_facts_contain(
                        input.type_nodes.get(
                            child_index).unwrap().resource_dependency_facts,
                        dependency) {
                    witnessed = true
                }
            }
            if !witnessed {
                panic("ResourcePlanner verifier: dependency lacks a direct child witness")
            }
            left = left + 1
        }
        match node.parameter_fact {
            some(parameter) => if node.resource_dependency_facts.len() != 1 ||
                   !verifier_generic_param_fact_same(
                        node.resource_dependency_facts.get(0).unwrap(),
                        parameter) {
                panic("ResourcePlanner verifier: parameter dependency seed drifted")
            },
            none => {}
        }
        for child_index in node.child_type_indices {
            if child_index < 0 || child_index >= input.type_nodes.len() {
                panic("ResourcePlanner verifier: type child is outside graph")
            }
            for dependency in input.type_nodes.get(
                    child_index).unwrap().resource_dependency_facts {
                if !verifier_dependency_facts_contain(
                        node.resource_dependency_facts, dependency) {
                    panic("ResourcePlanner verifier: dependency closure is partial")
                }
            }
        }
    }
}

fn make_expected_resource_cell(
    kind: ResourceCellKind, owner_index: Int, component_index: Int,
    max_rank: Int, source: ResourceCellSource
) -> ExpectedResourceCell {
    ExpectedResourceCell {
        kind: kind, owner_index: owner_index,
        component_index: component_index, max_rank: max_rank,
        source: source
    }
}

fn expected_resource_cells(
    input: FrozenPlannerInput
) -> List<ExpectedResourceCell> {
    let mut result: List<ExpectedResourceCell> = []
    let mut type_index = 0
    while type_index < input.type_nodes.len() {
        let node = input.type_nodes.get(type_index).unwrap()
        let mut component = 0
        while component < 2 + node.resource_dependency_facts.len() {
            let kind = resource_cell_kind_logical_shape()
            result.push(make_expected_resource_cell(
                kind, type_index, component, 1,
                make_structural_resource_cell_source(
                    kind, type_index, component)))
            component = component + 1
        }
        component = 0
        while component < 4 + node.resource_dependency_facts.len() {
            let kind = resource_cell_kind_physical_shape()
            result.push(make_expected_resource_cell(
                kind, type_index, component, 1,
                make_structural_resource_cell_source(
                    kind, type_index, component)))
            component = component + 1
        }
        type_index = type_index + 1
    }
    let mut callable_index = 0
    while callable_index < input.callables.len() {
        let callable = input.callables.get(callable_index).unwrap()
        let mut parameter = 0
        while parameter < callable.parameter_type_indices.len() {
            let kind = resource_cell_kind_callable_param_mode()
            result.push(make_expected_resource_cell(
                kind, callable_index, parameter, 3,
                make_structural_resource_cell_source(
                    kind, callable_index, parameter)))
            parameter = parameter + 1
        }
        parameter = 0
        while parameter < callable.parameter_type_indices.len() {
            let kind = resource_cell_kind_callable_force()
            result.push(make_expected_resource_cell(
                kind, callable_index, parameter, 1,
                make_structural_resource_cell_source(
                    kind, callable_index, parameter)))
            parameter = parameter + 1
        }
        result.push(make_expected_resource_cell(
            resource_cell_kind_callable_result(), callable_index, 0, 1,
            make_callable_result_owned_source(callable.reference)))
        parameter = 0
        while parameter < callable.parameter_type_indices.len() {
            result.push(make_expected_resource_cell(
                resource_cell_kind_callable_result_origin(),
                callable_index, parameter, 1,
                make_callable_result_origin_source(
                    callable.reference, parameter)))
            parameter = parameter + 1
        }
        callable_index = callable_index + 1
    }
    let mut body_index = 0
    while body_index < input.bodies.len() {
        let body = input.bodies.get(body_index).unwrap()
        let callable = input.callables.get(flow_callable_index_for_planner(
            input.callables, body.reference)).unwrap()
        let parameter_count = callable.parameter_type_indices.len()
        let mut block_index = 0
        while block_index < body.blocks.len() {
            result.push(make_expected_resource_cell(
                resource_cell_kind_body_block_reachable(),
                body_index, block_index, 1,
                make_body_reach_source(
                    make_flow_block_ref(body.reference, block_index))))
            block_index = block_index + 1
        }
        let mut origin_component = 0
        let mut owned_component = 0
        let mut mode_component = 0
        let mut force_component = 0
        block_index = 0
        while block_index < body.blocks.len() {
            let block = body.blocks.get(block_index).unwrap()
            let mut boundary = 0
            while boundary <= block.events.len() {
                let mut slot = 0
                while slot < body.slots.len() {
                    let mut parameter = 0
                    while parameter < parameter_count {
                        result.push(make_expected_resource_cell(
                            resource_cell_kind_body_slot_origin(),
                            body_index, origin_component, 1,
                            make_body_slot_origin_source(
                                make_flow_block_ref(
                                    body.reference, block_index),
                                boundary,
                                body.slots.get(slot).unwrap().reference,
                                parameter)))
                        origin_component = origin_component + 1
                        parameter = parameter + 1
                    }
                    slot = slot + 1
                }
                slot = 0
                while slot < body.slots.len() {
                    result.push(make_expected_resource_cell(
                        resource_cell_kind_body_slot_mode(),
                        body_index, mode_component, 3,
                        make_body_slot_mode_source(
                            make_flow_block_ref(body.reference, block_index),
                            boundary,
                            body.slots.get(slot).unwrap().reference)))
                    mode_component = mode_component + 1
                    slot = slot + 1
                }
                slot = 0
                while slot < body.slots.len() {
                    result.push(make_expected_resource_cell(
                        resource_cell_kind_body_slot_force(),
                        body_index, force_component, 1,
                        make_body_slot_force_source(
                            make_flow_block_ref(body.reference, block_index),
                            boundary,
                            body.slots.get(slot).unwrap().reference)))
                    force_component = force_component + 1
                    slot = slot + 1
                }
                slot = 0
                while slot < body.slots.len() {
                    result.push(make_expected_resource_cell(
                        resource_cell_kind_body_slot_owned(),
                        body_index, owned_component, 1,
                        make_body_slot_owned_source(
                            make_flow_block_ref(body.reference, block_index),
                            boundary,
                            body.slots.get(slot).unwrap().reference)))
                    owned_component = owned_component + 1
                    slot = slot + 1
                }
                boundary = boundary + 1
            }
            block_index = block_index + 1
        }
        body_index = body_index + 1
    }
    result
}

struct SourceConstraintSpec {
    source: ResourceRuleSource,
    rule_tag: Int,
    floor_rank: Int,
    requires_all: Bool,
    target: ResourceCellSource,
    premises: List<ResourceCellSource>,
    guard: ResourceCellSource?
}

fn make_source_constraint_spec(
    source: ResourceRuleSource, rule_tag: Int, floor_rank: Int,
    requires_all: Bool, target: ResourceCellSource,
    premises: List<ResourceCellSource>
) -> SourceConstraintSpec {
    SourceConstraintSpec { source: source, rule_tag: rule_tag,
        floor_rank: floor_rank, requires_all: requires_all,
        target: target, premises: premises, guard: none }
}

fn make_guarded_source_constraint_spec(
    source: ResourceRuleSource, rule_tag: Int,
    target: ResourceCellSource, premise: ResourceCellSource,
    guard: ResourceCellSource
) -> SourceConstraintSpec {
    let mut result = make_source_constraint_spec(
        source, rule_tag, 0, false, target, [premise])
    result.guard = some(guard)
    result
}

fn source_constraint_same(
    left: SourceConstraintSpec, right: SourceConstraintSpec
) -> Bool {
    if left.rule_tag != right.rule_tag ||
       left.floor_rank != right.floor_rank ||
       left.requires_all != right.requires_all ||
       !resource_rule_source_same(left.source, right.source) ||
       !resource_cell_source_same(left.target, right.target) ||
       left.premises.len() != right.premises.len() {
        return false
    }
    match (left.guard, right.guard) {
        (some(a), some(b)) => if !resource_cell_source_same(a, b) {
            return false
        },
        (none, none) => {},
        _ => return false
    }
    let mut index = 0
    while index < left.premises.len() {
        if !resource_cell_source_same(
                left.premises.get(index).unwrap(),
                right.premises.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}

fn actual_source_constraints(
    cells: List<ResourceCellSpec>, constraints: List<ResourceConstraint>
) -> List<SourceConstraintSpec> {
    let mut result: List<SourceConstraintSpec> = []
    for constraint in constraints {
        let source = resource_constraint_source(constraint)
        let mut premises: List<ResourceCellSource> = []
        for premise in resource_constraint_premise_cells(constraint) {
            premises.push(resource_cell_spec_source(
                cells.get(premise).unwrap()))
        }
        let mut spec = make_source_constraint_spec(
            source, resource_constraint_rule_tag(constraint),
            resource_constraint_floor_rank(constraint),
            resource_constraint_requires_all(constraint),
            resource_cell_spec_source(cells.get(
                resource_constraint_target_cell(constraint)).unwrap()),
                premises)
        match resource_constraint_guard_cell(constraint) {
            some(guard) => { spec.guard = some(
                resource_cell_spec_source(cells.get(guard).unwrap())) },
            none => {}
        }
        result.push(spec)
    }
    result
}

fn verifier_event_overwrites_slot(
    event: PlannerEvent, body: PlannerBody, slot: Int
) -> Bool {
    match event.value {
        PlannerEventValue::NoOpValue => false,
        PlannerEventValue::ScopeExitValue(scope_id) =>
            body.slots.get(slot).unwrap().scope_id == scope_id,
        PlannerEventValue::InitializeValue { target, .. } => slot == target,
        PlannerEventValue::ReadValue { target, .. } => slot == target,
        PlannerEventValue::MutateValue { .. } => false,
        PlannerEventValue::ConsumeValue(source, _, target) =>
            slot == source || match target {
                some(value) => slot == value,
                none => false
            },
        PlannerEventValue::DiscardValue(source) => slot == source,
        PlannerEventValue::AssignValue { rhs_temp, target } =>
            slot == rhs_temp || (planner_place_is_slot(target) &&
                slot == planner_place_slot(target)),
        PlannerEventValue::MovePlaceValue { source, target } =>
            slot == target || (planner_place_is_slot(source) &&
                slot == planner_place_slot(source)),
        PlannerEventValue::CallValue { result_slot, .. } => match result_slot {
            some(value) => slot == value,
            none => false
        },
        PlannerEventValue::ProjectValue { target, .. } => slot == target,
        PlannerEventValue::CaptureValue { source, target, demand } =>
            slot == target || (slot == source &&
                param_mode_same(transfer_demand_mode(demand),
                    param_mode_own()) && transfer_demand_force(demand))
    }
}

fn source_body_origin(
    body: PlannerBody, block: Int, boundary: Int,
    slot: Int, parameter: Int
) -> ResourceCellSource {
    make_body_slot_origin_source(
        make_flow_block_ref(body.reference, block), boundary,
        body.slots.get(slot).unwrap().reference, parameter)
}
fn source_body_owned(
    body: PlannerBody, block: Int, boundary: Int, slot: Int
) -> ResourceCellSource {
    make_body_slot_owned_source(
        make_flow_block_ref(body.reference, block), boundary,
        body.slots.get(slot).unwrap().reference)
}
fn source_body_reach(body: PlannerBody, block: Int) -> ResourceCellSource {
    make_body_reach_source(make_flow_block_ref(body.reference, block))
}

fn add_expected_event_constraints(
    mut result: List<SourceConstraintSpec>, body: PlannerBody,
    block_index: Int, boundary: Int, event: PlannerEvent,
    parameter_count: Int, callables: List<PlannerCallable>
) {
    let next = boundary + 1
    let site = make_instruction_resource_rule_source(
        make_flow_instruction_ref(body.reference, block_index, boundary))
    let mut slot = 0
    while slot < body.slots.len() {
        if !verifier_event_overwrites_slot(event, body, slot) {
            let mut parameter = 0
            while parameter < parameter_count {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_ORIGIN_COPY, 0, false,
                    source_body_origin(
                        body, block_index, next, slot, parameter),
                    [source_body_origin(
                        body, block_index, boundary, slot, parameter)]))
                parameter = parameter + 1
            }
            result.push(make_source_constraint_spec(
                site, RULE_RESULT_ORIGIN_COPY, 0, false,
                source_body_owned(body, block_index, next, slot),
                [source_body_owned(body, block_index, boundary, slot)]))
        }
        slot = slot + 1
    }
    match event.value {
        PlannerEventValue::InitializeValue {
            input_slots, origin_input_ordinals, target, ..
        } => {
            for ordinal in origin_input_ordinals {
                let input = input_slots.get(ordinal).unwrap()
                let mut parameter = 0
                while parameter < parameter_count {
                    result.push(make_source_constraint_spec(
                        site, RULE_RESULT_ORIGIN_COPY, 0, false,
                        source_body_origin(body, block_index, next,
                            target, parameter),
                        [source_body_origin(body, block_index, boundary,
                            input, parameter)]))
                    parameter = parameter + 1
                }
            }
            if body.slots.get(target).unwrap().owns_storage {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_OWNED_BODY, 0, false,
                    source_body_owned(body, block_index, next, target),
                    [source_body_reach(body, block_index)]))
            }
        },
        PlannerEventValue::ReadValue { source, target } => {
            let mut parameter = 0
            while parameter < parameter_count {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_ORIGIN_COPY, 0, false,
                    source_body_origin(body, block_index, next,
                        target, parameter),
                    [source_body_origin(body, block_index, boundary,
                        source, parameter)]))
                parameter = parameter + 1
            }
            if body.slots.get(target).unwrap().owns_storage {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_OWNED_BODY, 0, false,
                    source_body_owned(body, block_index, next, target),
                    [source_body_reach(body, block_index)]))
            }
        },
        PlannerEventValue::ProjectValue { source, target, .. } => {
            let mut parameter = 0
            while parameter < parameter_count {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_ORIGIN_COPY, 0, false,
                    source_body_origin(body, block_index, next,
                        target, parameter),
                    [source_body_origin(body, block_index, boundary,
                        source, parameter)]))
                parameter = parameter + 1
            }
            if body.slots.get(target).unwrap().owns_storage {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_OWNED_BODY, 0, false,
                    source_body_owned(body, block_index, next, target),
                    [source_body_reach(body, block_index)]))
            }
        },
        PlannerEventValue::CaptureValue { source, target, .. } => {
            let mut parameter = 0
            while parameter < parameter_count {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_ORIGIN_COPY, 0, false,
                    source_body_origin(body, block_index, next,
                        target, parameter),
                    [source_body_origin(body, block_index, boundary,
                        source, parameter)]))
                parameter = parameter + 1
            }
            if body.slots.get(target).unwrap().owns_storage {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_OWNED_BODY, 0, false,
                    source_body_owned(body, block_index, next, target),
                    [source_body_reach(body, block_index)]))
            }
        },
        PlannerEventValue::ConsumeValue(source, _, target) => match target {
            some(target_slot) => {
                let mut parameter = 0
                while parameter < parameter_count {
                    result.push(make_source_constraint_spec(
                        site, RULE_RESULT_ORIGIN_COPY, 0, false,
                        source_body_origin(body, block_index, next,
                            target_slot, parameter),
                        [source_body_origin(body, block_index, boundary,
                            source, parameter)]))
                    parameter = parameter + 1
                }
                if body.slots.get(target_slot).unwrap().owns_storage {
                    result.push(make_source_constraint_spec(
                        site, RULE_RESULT_OWNED_BODY, 0, false,
                        source_body_owned(body, block_index, next, target_slot),
                        [source_body_reach(body, block_index)]))
                }
            },
            none => {}
        },
        PlannerEventValue::AssignValue { rhs_temp, target } => if
                planner_place_is_slot(target) {
            let target_slot = planner_place_slot(target)
            let mut parameter = 0
            while parameter < parameter_count {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_ORIGIN_COPY, 0, false,
                    source_body_origin(body, block_index, next,
                        target_slot, parameter),
                    [source_body_origin(body, block_index, boundary,
                        rhs_temp, parameter)]))
                parameter = parameter + 1
            }
            if body.slots.get(target_slot).unwrap().owns_storage {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_OWNED_BODY, 0, false,
                    source_body_owned(body, block_index, next, target_slot),
                [source_body_reach(body, block_index)]))
            }
        },
        PlannerEventValue::MovePlaceValue { source, target } => {
            let source_slot = if planner_place_is_slot(source) {
                planner_place_slot(source)
            } else { planner_place_base(source) }
            let mut parameter = 0
            while parameter < parameter_count {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_ORIGIN_COPY, 0, false,
                    source_body_origin(body, block_index, next,
                        target, parameter),
                    [source_body_origin(body, block_index, boundary,
                        source_slot, parameter)]))
                parameter = parameter + 1
            }
            if body.slots.get(target).unwrap().owns_storage {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_OWNED_BODY, 0, false,
                    source_body_owned(body, block_index, next, target),
                    [source_body_reach(body, block_index)]))
            }
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_slots, result_slot, ..
        } => match result_slot {
            some(target) => {
                for callable_index in callable_indices {
                    let callee = callables.get(callable_index).unwrap()
                    let mut callee_parameter = 0
                    while callee_parameter < callee.parameter_type_indices.len() {
                        let argument = argument_slots.get(callee_parameter).unwrap()
                        let mut caller_parameter = 0
                        while caller_parameter < parameter_count {
                            result.push(make_source_constraint_spec(
                                site, RULE_RESULT_ORIGIN_CALL, 0, true,
                                source_body_origin(body, block_index, next,
                                    target, caller_parameter),
                                [make_callable_result_origin_source(
                                    callee.reference, callee_parameter),
                                 source_body_origin(body, block_index, boundary,
                                    argument, caller_parameter)]))
                            caller_parameter = caller_parameter + 1
                        }
                        callee_parameter = callee_parameter + 1
                    }
                    result.push(make_source_constraint_spec(
                        site, RULE_RESULT_OWNED_BODY, 0, true,
                        source_body_owned(body, block_index, next, target),
                        [source_body_reach(body, block_index),
                         make_callable_result_owned_source(callee.reference)]))
                }
            },
            none => {}
        },
        _ => {}
    }
}

fn source_body_mode(
    body: PlannerBody, block: Int, boundary: Int, slot: Int
) -> ResourceCellSource {
    make_body_slot_mode_source(
        make_flow_block_ref(body.reference, block), boundary,
        body.slots.get(slot).unwrap().reference)
}

fn source_body_force(
    body: PlannerBody, block: Int, boundary: Int, slot: Int
) -> ResourceCellSource {
    make_body_slot_force_source(
        make_flow_block_ref(body.reference, block), boundary,
        body.slots.get(slot).unwrap().reference)
}

fn append_expected_local_floor(
    mut result: List<SourceConstraintSpec>, source: ResourceRuleSource,
    body: PlannerBody, block: Int, boundary: Int,
    slot: Int, demand: TransferDemand
) {
    result.push(make_source_constraint_spec(
        source, RULE_LOCAL_EXPLICIT,
        param_mode_tag(transfer_demand_mode(demand)), false,
        source_body_mode(body, block, boundary, slot), []))
    result.push(make_source_constraint_spec(
        source, RULE_LOCAL_EXPLICIT,
        if transfer_demand_force(demand) { 1 } else { 0 }, false,
        source_body_force(body, block, boundary, slot), []))
}

fn append_expected_local_copy(
    mut result: List<SourceConstraintSpec>, source: ResourceRuleSource,
    rule: Int, body: PlannerBody,
    target_block: Int, target_boundary: Int, target_slot: Int,
    premise_block: Int, premise_boundary: Int, premise_slot: Int
) {
    result.push(make_source_constraint_spec(
        source, rule, 0, false,
        source_body_mode(
            body, target_block, target_boundary, target_slot),
        [source_body_mode(
            body, premise_block, premise_boundary, premise_slot)]))
    result.push(make_source_constraint_spec(
        source, rule, 0, false,
        source_body_force(
            body, target_block, target_boundary, target_slot),
        [source_body_force(
            body, premise_block, premise_boundary, premise_slot)]))
}

fn verifier_event_demand_slot_defined(
    event: PlannerEvent, body: PlannerBody, slot: Int
) -> Bool {
    match event.value {
        PlannerEventValue::NoOpValue => false,
        PlannerEventValue::ScopeExitValue(scope_id) =>
            body.slots.get(slot).unwrap().scope_id == scope_id,
        PlannerEventValue::InitializeValue { target, .. } => slot == target,
        PlannerEventValue::ReadValue { target, .. } => slot == target,
        PlannerEventValue::MutateValue { .. } => false,
        PlannerEventValue::ConsumeValue(source, _, target) =>
            slot == source || match target {
                some(value) => slot == value,
                none => false
            },
        PlannerEventValue::DiscardValue(source) => slot == source,
        PlannerEventValue::AssignValue { rhs_temp, target } =>
            slot == rhs_temp || (planner_place_is_slot(target) &&
                slot == planner_place_slot(target)),
        PlannerEventValue::MovePlaceValue { source, target } =>
            slot == target || (planner_place_is_slot(source) &&
                slot == planner_place_slot(source)),
        PlannerEventValue::CallValue { result_slot, .. } => match result_slot {
            some(value) => slot == value,
            none => false
        },
        PlannerEventValue::ProjectValue { target, .. } => slot == target,
        PlannerEventValue::CaptureValue { target, .. } => slot == target
    }
}

fn append_expected_event_demand_constraints(
    mut result: List<SourceConstraintSpec>, body: PlannerBody,
    block_index: Int, boundary: Int, event: PlannerEvent,
    callables: List<PlannerCallable>
) {
    let next = boundary + 1
    let site = make_instruction_resource_rule_source(
        make_flow_instruction_ref(body.reference, block_index, boundary))
    let mut slot = 0
    while slot < body.slots.len() {
        if !verifier_event_demand_slot_defined(event, body, slot) {
            append_expected_local_copy(
                result, site, RULE_LOCAL_CARRY, body,
                block_index, boundary, slot,
                block_index, next, slot)
        }
        slot = slot + 1
    }
    match event.value {
        PlannerEventValue::NoOpValue |
        PlannerEventValue::ScopeExitValue(_) => {},
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, origin_input_ordinals, target
        } => {
            let mut input = 0
            while input < input_slots.len() {
                let source_slot = input_slots.get(input).unwrap()
                append_expected_local_floor(
                    result, site, body, block_index, boundary,
                    source_slot, input_demands.get(input).unwrap())
                if int_list_contains(origin_input_ordinals, input) {
                    append_expected_local_copy(
                        result, site, RULE_LOCAL_RESULT_ORIGIN, body,
                        block_index, boundary, source_slot,
                        block_index, next, target)
                }
                input = input + 1
            }
        },
        PlannerEventValue::ReadValue { source, target } =>
            append_expected_local_copy(
                result, site, RULE_LOCAL_READ, body,
                block_index, boundary, source,
                block_index, next, target),
        PlannerEventValue::MutateValue {
            target, value: input, value_demand
        } => {
            append_expected_local_floor(
                result, site, body, block_index, boundary, target,
                make_transfer_demand(param_mode_mut_borrow(), false))
            append_expected_local_floor(
                result, site, body, block_index, boundary, input,
                value_demand)
        },
        PlannerEventValue::ConsumeValue(source, force, _) =>
            append_expected_local_floor(
                result, site, body, block_index, boundary, source,
                make_transfer_demand(param_mode_own(), force)),
        PlannerEventValue::DiscardValue(source) =>
            append_expected_local_floor(
                result, site, body, block_index, boundary, source,
                make_transfer_demand(param_mode_own(), false)),
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            append_expected_local_floor(
                result, site, body, block_index, boundary, rhs_temp,
                make_transfer_demand(param_mode_own(), false))
            append_expected_local_floor(
                result, site, body, block_index, boundary,
                if planner_place_is_slot(target) {
                    planner_place_slot(target)
                } else { planner_place_base(target) },
                make_transfer_demand(param_mode_mut_borrow(), false))
        },
        PlannerEventValue::MovePlaceValue { source, target } => {
            let source_slot = if planner_place_is_slot(source) {
                planner_place_slot(source)
            } else { planner_place_base(source) }
            append_expected_local_floor(
                result, site, body, block_index, boundary, source_slot,
                make_transfer_demand(param_mode_own(), true))
            append_expected_local_copy(
                result, site, RULE_LOCAL_READ, body,
                block_index, boundary, source_slot,
                block_index, next, target)
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            argument_slots, result_slot, ..
        } => {
            let mut argument = 0
            while argument < argument_slots.len() {
                let argument_slot = argument_slots.get(argument).unwrap()
                append_expected_local_floor(
                    result, site, body, block_index, boundary,
                    argument_slot, argument_demands.get(argument).unwrap())
                for callable_index in callable_indices {
                    let callee = callables.get(callable_index).unwrap()
                    let mode = make_structural_resource_cell_source(
                        resource_cell_kind_callable_param_mode(),
                        callable_index, argument)
                    let force = make_structural_resource_cell_source(
                        resource_cell_kind_callable_force(),
                        callable_index, argument)
                    result.push(make_source_constraint_spec(
                        site, RULE_LOCAL_CALL, 0, false,
                        source_body_mode(
                            body, block_index, boundary, argument_slot),
                        [mode]))
                    result.push(make_source_constraint_spec(
                        site, RULE_LOCAL_CALL, 0, false,
                        source_body_force(
                            body, block_index, boundary, argument_slot),
                        [force]))
                    match result_slot {
                        some(value) => {
                            let guard = make_callable_result_origin_source(
                                callee.reference, argument)
                            result.push(make_guarded_source_constraint_spec(
                                site, RULE_LOCAL_RESULT_ORIGIN,
                                source_body_mode(
                                    body, block_index, boundary, argument_slot),
                                source_body_mode(
                                    body, block_index, next, value), guard))
                            result.push(make_guarded_source_constraint_spec(
                                site, RULE_LOCAL_RESULT_ORIGIN,
                                source_body_force(
                                    body, block_index, boundary, argument_slot),
                                source_body_force(
                                    body, block_index, next, value), guard))
                        },
                        none => {}
                    }
                }
                argument = argument + 1
            }
        },
        PlannerEventValue::ProjectValue {
            source, target, partial, ..
        } => {
            append_expected_local_floor(
                result, site, body, block_index, boundary, source,
                make_transfer_demand(param_mode_borrow(), false))
            if partial {
                append_expected_local_copy(
                    result, site, RULE_LOCAL_READ, body,
                    block_index, boundary, source,
                    block_index, next, target)
            }
        },
        PlannerEventValue::CaptureValue { source, demand, .. } =>
            append_expected_local_floor(
                result, site, body, block_index, boundary, source, demand)
    }
}

fn append_expected_body_demand_constraints(
    mut result: List<SourceConstraintSpec>, body: PlannerBody,
    callable_index: Int, callables: List<PlannerCallable>
) {
    let mut block_index = 0
    while block_index < body.blocks.len() {
        let block = body.blocks.get(block_index).unwrap()
        let mut boundary = 0
        while boundary < block.events.len() {
            append_expected_event_demand_constraints(
                result, body, block_index, boundary,
                block.events.get(boundary).unwrap(), callables)
            boundary = boundary + 1
        }
        let end = block.events.len()
        let terminator_site = make_block_resource_rule_source(
            make_flow_block_ref(body.reference, block_index))
        for usage in block.terminator_uses {
            append_expected_local_floor(
                result, terminator_site, body,
                block_index, end, usage.slot, usage.demand)
        }
        let mut edge_index = 0
        while edge_index < block.edges.len() {
            let edge = block.edges.get(edge_index).unwrap()
            match edge.target_block {
                some(target) => {
                    let edge_site = make_edge_resource_rule_source(
                        make_flow_block_ref(body.reference, block_index),
                        edge_index)
                    let mut slot = 0
                    while slot < body.slots.len() {
                        if !int_list_contains(edge.fresh_result_slots, slot) &&
                           !int_list_contains(
                                edge.exited_scope_ids,
                                body.slots.get(slot).unwrap().scope_id) {
                            append_expected_local_copy(
                                result, edge_site, RULE_LOCAL_CFG_EDGE, body,
                                block_index, end, slot, target, 0, slot)
                        }
                        slot = slot + 1
                    }
                },
                none => {}
            }
            edge_index = edge_index + 1
        }
        block_index = block_index + 1
    }
    let entry_site = make_block_resource_rule_source(
        make_flow_block_ref(body.reference, body.entry_block))
    let callable = callables.get(callable_index).unwrap()
    let mut slot = 0
    while slot < body.slots.len() {
        match body.slots.get(slot).unwrap().parameter_ordinal {
            some(parameter) => {
                result.push(make_source_constraint_spec(
                    entry_site, RULE_LOCAL_ENTRY_PARAMETER, 0, false,
                    make_structural_resource_cell_source(
                        resource_cell_kind_callable_param_mode(),
                        callable_index, parameter),
                    [source_body_mode(
                        body, body.entry_block, 0, slot)]))
                result.push(make_source_constraint_spec(
                    entry_site, RULE_LOCAL_ENTRY_PARAMETER, 0, false,
                    make_structural_resource_cell_source(
                        resource_cell_kind_callable_force(),
                        callable_index, parameter),
                    [source_body_force(
                        body, body.entry_block, 0, slot)]))
            },
            none => {}
        }
        slot = slot + 1
    }
    let _ = callable
}

fn expected_source_constraints(
    input: FrozenPlannerInput
) -> List<SourceConstraintSpec> {
    let mut result: List<SourceConstraintSpec> = []
    let mut type_index = 0
    while type_index < input.type_nodes.len() {
        let node = input.type_nodes.get(type_index).unwrap()
        let logical = resource_cell_kind_logical_shape()
        let physical = resource_cell_kind_physical_shape()
        let seed_site = make_structural_resource_rule_source(RULE_TYPE_SEED)
        result.push(make_source_constraint_spec(
            seed_site, RULE_TYPE_SEED,
            if node.direct_drop_seed { 1 } else { 0 }, false,
            make_structural_resource_cell_source(logical, type_index, 0), []))
        result.push(make_source_constraint_spec(
            seed_site, RULE_TYPE_SEED,
            if node.may_unique_seed { 1 } else { 0 }, false,
            make_structural_resource_cell_source(logical, type_index, 1), []))
        result.push(make_source_constraint_spec(
            make_structural_resource_rule_source(
                RULE_DIRECT_IMPLIES_UNIQUE),
            RULE_DIRECT_IMPLIES_UNIQUE, 0, false,
            make_structural_resource_cell_source(logical, type_index, 1),
            [make_structural_resource_cell_source(logical, type_index, 0)]))
        result.push(make_source_constraint_spec(
            seed_site, RULE_TYPE_SEED,
            if node.physical_rc_seed { 1 } else { 0 }, false,
            make_structural_resource_cell_source(physical, type_index, 0), []))
        result.push(make_source_constraint_spec(
            seed_site, RULE_TYPE_SEED,
            if node.boxing_seed { 1 } else { 0 }, false,
            make_structural_resource_cell_source(physical, type_index, 1), []))
        result.push(make_source_constraint_spec(
            seed_site, RULE_TYPE_SEED,
            if node.drop_glue_seed { 1 } else { 0 }, false,
            make_structural_resource_cell_source(physical, type_index, 2), []))
        result.push(make_source_constraint_spec(
            seed_site, RULE_TYPE_SEED,
            if node.foreign_containment_seed { 1 } else { 0 }, false,
            make_structural_resource_cell_source(physical, type_index, 3), []))
        match node.parameter_fact {
            some(parameter) => {
                let dependency = verifier_dependency_fact_index(
                    node.resource_dependency_facts, parameter)
                result.push(make_source_constraint_spec(
                    seed_site, RULE_TYPE_SEED, 1, false,
                    make_structural_resource_cell_source(
                        logical, type_index, 2 + dependency), []))
                result.push(make_source_constraint_spec(
                    seed_site, RULE_TYPE_SEED, 1, false,
                    make_structural_resource_cell_source(
                        physical, type_index, 4 + dependency), []))
            },
            none => {}
        }
        let child_site = make_structural_resource_rule_source(RULE_TYPE_CHILD)
        for child_index in node.child_type_indices {
            result.push(make_source_constraint_spec(
                child_site, RULE_TYPE_CHILD, 0, false,
                make_structural_resource_cell_source(
                    logical, type_index, 1),
                [make_structural_resource_cell_source(
                    logical, child_index, 1)]))
            let mut component = 0
            while component < 4 {
                result.push(make_source_constraint_spec(
                    child_site, RULE_TYPE_CHILD, 0, false,
                    make_structural_resource_cell_source(
                        physical, type_index, component),
                    [make_structural_resource_cell_source(
                        physical, child_index, component)]))
                component = component + 1
            }
        }
        let mut dependency = 0
        while dependency < node.resource_dependency_facts.len() {
            let fact = node.resource_dependency_facts.get(dependency).unwrap()
            for child_index in node.child_type_indices {
                let child_node = input.type_nodes.get(child_index).unwrap()
                if verifier_dependency_facts_contain(
                        child_node.resource_dependency_facts, fact) {
                    let child_dependency = verifier_dependency_fact_index(
                        child_node.resource_dependency_facts, fact)
                    result.push(make_source_constraint_spec(
                        child_site, RULE_TYPE_CHILD, 0, false,
                        make_structural_resource_cell_source(
                            logical, type_index, 2 + dependency),
                        [make_structural_resource_cell_source(
                            logical, child_index,
                            2 + child_dependency)]))
                    result.push(make_source_constraint_spec(
                        child_site, RULE_TYPE_CHILD, 0, false,
                        make_structural_resource_cell_source(
                            physical, type_index, 4 + dependency),
                        [make_structural_resource_cell_source(
                            physical, child_index,
                            4 + child_dependency)]))
                }
            }
            dependency = dependency + 1
        }
        type_index = type_index + 1
    }

    let mut callable_index = 0
    while callable_index < input.callables.len() {
        let callable = input.callables.get(callable_index).unwrap()
        let mode = resource_cell_kind_callable_param_mode()
        let force = resource_cell_kind_callable_force()
        let seed_site = make_structural_resource_rule_source(
            RULE_CALLABLE_SEED)
        let mut parameter = 0
        while parameter < callable.parameter_seeds.len() {
            let seed = callable.parameter_seeds.get(parameter).unwrap()
            result.push(make_source_constraint_spec(
                seed_site, RULE_CALLABLE_SEED,
                param_mode_tag(transfer_demand_mode(seed)), false,
                make_structural_resource_cell_source(
                    mode, callable_index, parameter), []))
            result.push(make_source_constraint_spec(
                seed_site, RULE_CALLABLE_SEED,
                if transfer_demand_force(seed) { 1 } else { 0 }, false,
                make_structural_resource_cell_source(
                    force, callable_index, parameter), []))
            parameter = parameter + 1
        }
        if !callable.has_body {
            let site = make_callable_resource_rule_source(callable.reference)
            result.push(make_source_constraint_spec(
                site, RULE_CALLABLE_SEED,
                if callable.result_owned_seed { 1 } else { 0 }, false,
                make_callable_result_owned_source(callable.reference), []))
            for parameter in callable.result_origin_parameter_ordinals {
                result.push(make_source_constraint_spec(
                    site, RULE_RESULT_ORIGIN_SEED, 1, false,
                    make_callable_result_origin_source(
                        callable.reference, parameter), []))
            }
        }
        callable_index = callable_index + 1
    }
    for body in input.bodies {
        let callable = input.callables.get(flow_callable_index_for_planner(
            input.callables, body.reference)).unwrap()
        let parameter_count = callable.parameter_type_indices.len()
        let entry_site = make_block_resource_rule_source(
            make_flow_block_ref(body.reference, body.entry_block))
        result.push(make_source_constraint_spec(
            entry_site, RULE_RESULT_ORIGIN_SEED, 1, false,
            source_body_reach(body, body.entry_block), []))
        let mut slot = 0
        while slot < body.slots.len() {
            let value = body.slots.get(slot).unwrap()
            match value.parameter_ordinal {
                some(parameter) => result.push(make_source_constraint_spec(
                    entry_site, RULE_RESULT_ORIGIN_SEED, 0, false,
                    source_body_origin(body, body.entry_block, 0,
                        slot, parameter),
                    [source_body_reach(body, body.entry_block)])),
                none => {}
            }
            if value.initially_live && value.owns_storage {
                result.push(make_source_constraint_spec(
                    entry_site, RULE_RESULT_OWNED_BODY, 0, false,
                    source_body_owned(body, body.entry_block, 0, slot),
                    [source_body_reach(body, body.entry_block)]))
            }
            slot = slot + 1
        }
        let mut block_index = 0
        while block_index < body.blocks.len() {
            let block = body.blocks.get(block_index).unwrap()
            let mut boundary = 0
            while boundary < block.events.len() {
                add_expected_event_constraints(
                    result, body, block_index, boundary,
                    block.events.get(boundary).unwrap(),
                    parameter_count, input.callables)
                boundary = boundary + 1
            }
            let end = block.events.len()
            let block_site = make_block_resource_rule_source(
                make_flow_block_ref(body.reference, block_index))
            if block.terminator_kind == 3 {
                for usage in block.terminator_uses {
                    let mut parameter = 0
                    while parameter < parameter_count {
                        result.push(make_source_constraint_spec(
                            block_site, RULE_RESULT_ORIGIN_COPY, 0, true,
                            make_callable_result_origin_source(
                                callable.reference, parameter),
                            [source_body_reach(body, block_index),
                             source_body_origin(body, block_index, end,
                                usage.slot, parameter)]))
                        parameter = parameter + 1
                    }
                    result.push(make_source_constraint_spec(
                        block_site, RULE_RESULT_OWNED_BODY, 0, true,
                        make_callable_result_owned_source(callable.reference),
                        [source_body_reach(body, block_index),
                         source_body_owned(body, block_index, end, usage.slot)]))
                }
            }
            let mut edge_index = 0
            while edge_index < block.edges.len() {
                let edge = block.edges.get(edge_index).unwrap()
                match edge.target_block {
                    some(target) => {
                        let edge_site = make_edge_resource_rule_source(
                            make_flow_block_ref(body.reference, block_index),
                            edge_index)
                        result.push(make_source_constraint_spec(
                            edge_site, RULE_RESULT_CFG_EDGE, 0, false,
                            source_body_reach(body, target),
                            [source_body_reach(body, block_index)]))
                        slot = 0
                        while slot < body.slots.len() {
                            if !int_list_contains(edge.exited_scope_ids,
                                    body.slots.get(slot).unwrap().scope_id) {
                                if int_list_contains(
                                        edge.fresh_result_slots, slot) {
                                    if body.slots.get(slot).unwrap().owns_storage {
                                        result.push(make_source_constraint_spec(
                                            edge_site, RULE_RESULT_CFG_EDGE,
                                            0, false,
                                            source_body_owned(
                                                body, target, 0, slot),
                                            [source_body_reach(
                                                body, block_index)]))
                                    }
                                } else {
                                    let mut parameter = 0
                                    while parameter < parameter_count {
                                        result.push(make_source_constraint_spec(
                                            edge_site, RULE_RESULT_CFG_EDGE,
                                            0, false,
                                            source_body_origin(
                                                body, target, 0,
                                                slot, parameter),
                                            [source_body_origin(
                                                body, block_index, end,
                                                slot, parameter)]))
                                        parameter = parameter + 1
                                    }
                                    result.push(make_source_constraint_spec(
                                        edge_site, RULE_RESULT_CFG_EDGE, 0, false,
                                        source_body_owned(
                                            body, target, 0, slot),
                                        [source_body_owned(
                                            body, block_index, end, slot)]))
                                }
                            }
                            slot = slot + 1
                        }
                    },
                    none => {}
                }
                edge_index = edge_index + 1
            }
            block_index = block_index + 1
        }
        append_expected_body_demand_constraints(
            result, body,
            flow_callable_index_for_planner(
                input.callables, body.reference),
            input.callables)
    }
    result
}

fn verifier_rank_bool(ranks: List<Int>, index: Int) -> Bool {
    ranks.get(index).unwrap() > 0
}

struct VerifierDemandBoundaryLayout {
    mode_start: Int,
    force_start: Int
}
struct VerifierDemandBlockLayout {
    boundaries: List<VerifierDemandBoundaryLayout>
}
struct VerifierDemandBodyLayout {
    blocks: List<VerifierDemandBlockLayout>
}

fn verifier_boundary_demand(
    ranks: List<Int>, layout: VerifierDemandBodyLayout,
    block: Int, boundary: Int, slot: Int
) -> TransferDemand {
    let exact = layout.blocks.get(block).unwrap().boundaries.get(
        boundary).unwrap()
    make_transfer_demand(
        param_mode_from_tag(ranks.get(exact.mode_start + slot).unwrap()),
        verifier_rank_bool(ranks, exact.force_start + slot))
}

fn verifier_solved_event_decision(
    event: PlannerEvent, layout: VerifierDemandBodyLayout,
    block: Int, boundary: Int,
    callable_mode_starts: List<Int>, callable_force_starts: List<Int>,
    callable_result_cells: List<Int>,
    callable_origin_starts: List<Int>, ranks: List<Int>
) -> EventDecision {
    let mut transfers: List<TransferDecision> = []
    let mut result_owned = false
    match event.value {
        PlannerEventValue::NoOpValue |
        PlannerEventValue::ScopeExitValue(_) => {},
        PlannerEventValue::InitializeValue {
            input_demands, origin_input_ordinals, target, ..
        } => {
            let target_demand = verifier_boundary_demand(
                ranks, layout, block, boundary + 1, target)
            let mut input = 0
            while input < input_demands.len() {
                transfers.push(make_transfer_decision(
                    planner_event_operand(event, input),
                    if int_list_contains(origin_input_ordinals, input) {
                        transfer_demand_join(
                            input_demands.get(input).unwrap(), target_demand)
                    } else { input_demands.get(input).unwrap() }))
                input = input + 1
            }
        },
        PlannerEventValue::ReadValue { target, .. } =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                verifier_boundary_demand(
                    ranks, layout, block, boundary + 1, target))),
        PlannerEventValue::MutateValue { value_demand, .. } => {
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                make_transfer_demand(param_mode_mut_borrow(), false)))
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 1), value_demand))
        },
        PlannerEventValue::ConsumeValue(_, force, _) =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                make_transfer_demand(param_mode_own(), force))),
        PlannerEventValue::DiscardValue(_) =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                make_transfer_demand(param_mode_own(), false))),
        PlannerEventValue::AssignValue { .. } => {
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                make_transfer_demand(param_mode_own(), false)))
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 1),
                make_transfer_demand(param_mode_mut_borrow(), false)))
        },
        PlannerEventValue::MovePlaceValue { .. } =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                make_transfer_demand(param_mode_own(), true))),
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            result_owned: lower_owned, result_slot, ..
        } => {
            let mut argument = 0
            while argument < argument_demands.len() {
                let mut demand = argument_demands.get(argument).unwrap()
                for callable_index in callable_indices {
                    demand = transfer_demand_join(demand,
                        make_transfer_demand(
                            param_mode_from_tag(ranks.get(
                                callable_mode_starts.get(
                                    callable_index).unwrap() + argument).unwrap()),
                            verifier_rank_bool(ranks,
                                callable_force_starts.get(
                                    callable_index).unwrap() + argument)))
                    match result_slot {
                        some(result) => if verifier_rank_bool(
                                ranks, callable_origin_starts.get(
                                    callable_index).unwrap() + argument) {
                            demand = transfer_demand_join(demand,
                                verifier_boundary_demand(
                                    ranks, layout, block, boundary + 1,
                                    result))
                        },
                        none => {}
                    }
                }
                transfers.push(make_transfer_decision(
                    planner_event_operand(event, argument), demand))
                argument = argument + 1
            }
            result_owned = lower_owned
            for callable_index in callable_indices {
                if verifier_rank_bool(ranks,
                        callable_result_cells.get(callable_index).unwrap()) {
                    result_owned = true
                }
            }
        },
        PlannerEventValue::ProjectValue { target, .. } =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                verifier_boundary_demand(
                    ranks, layout, block, boundary + 1, target))),
        PlannerEventValue::CaptureValue { demand, .. } =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0), demand))
    }
    make_event_decision(event.step, transfers, result_owned)
}

fn verifier_materialize_body_decisions(
    bodies: List<PlannerBody>, layouts: List<VerifierDemandBodyLayout>,
    callable_mode_starts: List<Int>, callable_force_starts: List<Int>,
    callable_result_cells: List<Int>,
    callable_origin_starts: List<Int>, ranks: List<Int>
) -> List<PlannerBody> {
    let mut result: List<PlannerBody> = []
    let mut body_index = 0
    while body_index < bodies.len() {
        let body = bodies.get(body_index).unwrap()
        let layout = layouts.get(body_index).unwrap()
        let mut blocks: List<PlannerBlock> = []
        let mut block_index = 0
        while block_index < body.blocks.len() {
            let block = body.blocks.get(block_index).unwrap()
            let mut events: List<PlannerEvent> = []
            let mut boundary = 0
            while boundary < block.events.len() {
                let event = block.events.get(boundary).unwrap()
                events.push(with_planner_event_decision(
                    event, verifier_solved_event_decision(
                        event, layout, block_index, boundary,
                        callable_mode_starts, callable_force_starts,
                        callable_result_cells, callable_origin_starts, ranks)))
                boundary = boundary + 1
            }
            blocks.push(make_planner_block(
                block.terminator_kind, events,
                block.terminator_uses, block.edges))
            block_index = block_index + 1
        }
        result.push(make_planner_body(
            body.reference, body.scopes, body.slots,
            body.entry_block, blocks))
        body_index = body_index + 1
    }
    result
}

fn decode_verified_resource_ranks(
    input: FrozenPlannerInput, proof: ResourceFixedPointProof
) -> SolvedResourceGraph {
    let ranks = resource_fixed_point_final_ranks(proof)
    let mut logical_shapes: List<LogicalOwnershipShape> = []
    let mut physical_shapes: List<PhysicalRcShape> = []
    let mut callable_demands: List<List<TransferDemand>> = []
    let mut callable_results_owned: List<Bool> = []
    let mut callable_result_type_indices: List<Int> = []
    let mut callable_mode_starts: List<Int> = []
    let mut callable_force_starts: List<Int> = []
    let mut callable_result_cells: List<Int> = []
    let mut callable_origin_starts: List<Int> = []
    let mut cursor = 0
    for node in input.type_nodes {
        let logical_start = cursor
        cursor = cursor + 2 + node.resource_dependency_facts.len()
        let physical_start = cursor
        cursor = cursor + 4 + node.resource_dependency_facts.len()
        let mut logical_deps: List<Bool> = []
        let mut physical_deps: List<Bool> = []
        let mut parameter = 0
        while parameter < node.resource_dependency_facts.len() {
            let logical_dependency = verifier_rank_bool(
                ranks, logical_start + 2 + parameter)
            let physical_dependency = verifier_rank_bool(
                ranks, physical_start + 4 + parameter)
            if !logical_dependency || !physical_dependency {
                panic("ResourcePlanner verifier: dependency derivation is incomplete")
            }
            logical_deps.push(logical_dependency)
            physical_deps.push(physical_dependency)
            parameter = parameter + 1
        }
        logical_shapes.push(make_logical_ownership_shape(
            verifier_rank_bool(ranks, logical_start),
            verifier_rank_bool(ranks, logical_start + 1), logical_deps))
        physical_shapes.push(make_physical_rc_shape(
            verifier_rank_bool(ranks, physical_start),
            verifier_rank_bool(ranks, physical_start + 1),
            verifier_rank_bool(ranks, physical_start + 2),
            verifier_rank_bool(ranks, physical_start + 3), physical_deps))
    }
    let mut callable_index = 0
    while callable_index < input.callables.len() {
        let callable = input.callables.get(callable_index).unwrap()
        let parameter_count = callable.parameter_type_indices.len()
        let mode_start = cursor
        callable_mode_starts.push(mode_start)
        cursor = cursor + parameter_count
        let force_start = cursor
        callable_force_starts.push(force_start)
        cursor = cursor + parameter_count
        let result_cell = cursor
        callable_result_cells.push(result_cell)
        cursor = cursor + 1
        let result_origin_start = cursor
        callable_origin_starts.push(result_origin_start)
        cursor = cursor + parameter_count
        let mut demands: List<TransferDemand> = []
        let mut parameter = 0
        while parameter < parameter_count {
            let mode = param_mode_from_tag(
                ranks.get(mode_start + parameter).unwrap())
            let force = verifier_rank_bool(ranks, force_start + parameter)
            if force && !param_mode_same(mode, param_mode_own()) {
                panic("ResourcePlanner verifier: FORCE rank lacks Own mode")
            }
            demands.push(make_transfer_demand(mode, force))
            parameter = parameter + 1
        }
        callable_demands.push(demands)
        let owned = verifier_rank_bool(ranks, result_cell)
        if !callable.has_body && owned != callable.result_owned_seed {
            panic("ResourcePlanner verifier: callable owned rank drifted")
        }
        parameter = 0
        while parameter < parameter_count {
            if !callable.has_body &&
               verifier_rank_bool(ranks, result_origin_start + parameter) !=
               int_list_contains(
                    callable.result_origin_parameter_ordinals, parameter) {
                panic("ResourcePlanner verifier: callable origin rank drifted")
            }
            parameter = parameter + 1
        }
        callable_results_owned.push(owned)
        callable_result_type_indices.push(callable.result_type_index)
        callable_index = callable_index + 1
    }
    let mut body_layouts: List<VerifierDemandBodyLayout> = []
    for body in input.bodies {
        let callable = input.callables.get(
            flow_callable_index_for_planner(
                input.callables, body.reference)).unwrap()
        let parameter_count = callable.parameter_type_indices.len()
        cursor = cursor + body.blocks.len()
        let mut block_layouts: List<VerifierDemandBlockLayout> = []
        for block in body.blocks {
            let mut boundaries: List<VerifierDemandBoundaryLayout> = []
            let mut boundary = 0
            while boundary <= block.events.len() {
                cursor = cursor + body.slots.len() * parameter_count
                cursor = cursor + body.slots.len()
                let mode_start = cursor
                cursor = cursor + body.slots.len()
                let force_start = cursor
                cursor = cursor + body.slots.len()
                boundaries.push(VerifierDemandBoundaryLayout {
                    mode_start: mode_start, force_start: force_start
                })
                boundary = boundary + 1
            }
            block_layouts.push(VerifierDemandBlockLayout {
                boundaries: boundaries
            })
        }
        body_layouts.push(VerifierDemandBodyLayout { blocks: block_layouts })
    }
    if cursor != ranks.len() {
        panic("ResourcePlanner verifier: fixed-rank census drifted")
    }
    SolvedResourceGraph {
        fixed_point: proof,
        logical_shapes: logical_shapes,
        physical_shapes: physical_shapes,
        callable_demands: callable_demands,
        callable_results_owned: callable_results_owned,
        callable_result_type_indices: callable_result_type_indices,
        bodies: verifier_materialize_body_decisions(
            input.bodies, body_layouts,
            callable_mode_starts, callable_force_starts,
            callable_result_cells, callable_origin_starts, ranks)
    }
}

pub fn verify_fixed_graph_contract(
    input: FrozenPlannerInput, certificate: ResourceCertificate
) -> SolvedResourceGraph {
    verify_type_dependency_closure(input)
    let proof = resource_certificate_fixed_point(certificate)
    let actual_cells = resource_fixed_point_cells(proof)
    let actual_constraints = resource_fixed_point_constraints(proof)
    let expected_cells = expected_resource_cells(input)
    let source_constraints = expected_source_constraints(input)
    let actual_source_constraints_ = actual_source_constraints(
        actual_cells, actual_constraints)
    if expected_cells.len() == 0 || source_constraints.len() == 0 ||
       actual_cells.len() != expected_cells.len() ||
       actual_source_constraints_.len() != source_constraints.len() ||
       actual_constraints.len() != source_constraints.len() {
        panic("ResourcePlanner verifier: finite proof graph is empty or incomplete")
    }
    let mut source_index = 0
    while source_index < source_constraints.len() {
        if !source_constraint_same(
                source_constraints.get(source_index).unwrap(),
                actual_source_constraints_.get(source_index).unwrap()) {
            panic("ResourcePlanner verifier: source constraint topology drifted")
        }
        source_index = source_index + 1
    }
    let mut cell_index = 0
    while cell_index < expected_cells.len() {
        let left = expected_cells.get(cell_index).unwrap()
        let right = actual_cells.get(cell_index).unwrap()
        if resource_cell_kind_tag(left.kind) !=
               resource_cell_kind_tag(resource_cell_spec_kind(right)) ||
           left.owner_index !=
               resource_cell_spec_owner_index(right) ||
           left.component_index !=
               resource_cell_spec_component_index(right) ||
           left.max_rank !=
               resource_cell_spec_max_rank(right) ||
           !resource_cell_source_same(
                left.source,
                resource_cell_spec_source(right)) {
            panic("ResourcePlanner verifier: finite proof cell graph drifted")
        }
        cell_index = cell_index + 1
    }
    // Decode the already-certified final ranks for topology verification.
    // This does not rerun the fixed-point solver.
    decode_verified_resource_ranks(input, proof)
}

// Independent candidate-rule reconstruction from the frozen planner facts.
// It deliberately shares no producer graph builder or solver.
struct VerifierCandidateGraph {
    callable_count: Int,
    cells: List<CandidateCellSpec>,
    rules: List<CandidateRule>
}

fn verifier_candidate_cell_index(
    cells: List<CandidateCellSpec>, kind: CandidateCellKind,
    owner: Int, block: Int, boundary: Int,
    component: Int, candidate: Int
) -> Int {
    let mut index = 0
    while index < cells.len() {
        let cell = cells.get(index).unwrap()
        if candidate_cell_kind_tag(candidate_cell_spec_kind(cell)) ==
               candidate_cell_kind_tag(kind) &&
           candidate_cell_spec_owner(cell) == owner &&
           candidate_cell_spec_block(cell) == block &&
           candidate_cell_spec_boundary(cell) == boundary &&
           candidate_cell_spec_component(cell) == component &&
           candidate_cell_spec_candidate(cell) == candidate {
            return index
        }
        index = index + 1
    }
    panic("ResourcePlanner: callable-candidate proof cell is absent")
}

fn verifier_add_candidate_rule(
    mut rules: List<CandidateRule>, kind: CandidateRuleKind,
    site: CandidateRuleSite, target: Int, premises: List<Int>
) {
    rules.push(make_candidate_rule(kind, site, target, premises))
}

fn verifier_add_candidate_conjunction_rule(
    mut rules: List<CandidateRule>, site: CandidateRuleSite,
    target: Int, left: Int, right: Int
) {
    if left == right {
        verifier_add_candidate_rule(
            rules, candidate_rule_copy(), site, target, [left])
    } else {
        verifier_add_candidate_rule(
            rules, candidate_rule_all(), site, target, [left, right])
    }
}

fn verifier_append_callable_location(
    mut values: List<PlannerCallableLocation>,
    value: PlannerCallableLocation
) {
    if !values.any(fn(existing) {
            planner_callable_location_same(existing, value)
        }) {
        values.push(copy_planner_callable_location(value))
    }
}

fn verifier_candidate_formal_contains(
    values: List<FlowGenericParamFact>, target: FlowGenericParamFact
) -> Bool {
    values.any(fn(value) { flow_generic_param_fact_same(value, target) })
}

fn verifier_append_candidate_formal(
    mut values: List<FlowGenericParamFact>, value: FlowGenericParamFact
) -> Bool {
    if verifier_candidate_formal_contains(values, value) { return false }
    values.push(value)
    true
}

fn verifier_type_accepts_candidates(
    type_nodes: List<PlannerTypeNode>, type_index: Int,
    active_formals: List<FlowGenericParamFact>
) -> Bool {
    if type_index < 0 || type_index >= type_nodes.len() {
        panic("ResourcePlanner verifier: candidate type is outside frozen graph")
    }
    if planner_type_is_callable(type_nodes, type_index) { return true }
    match type_nodes.get(type_index).unwrap().parameter_fact {
        some(parameter) => verifier_candidate_formal_contains(
            active_formals, parameter),
        none => false
    }
}

fn verifier_type_is_active_formal(
    type_nodes: List<PlannerTypeNode>, type_index: Int,
    active_formals: List<FlowGenericParamFact>
) -> Bool {
    if type_index < 0 || type_index >= type_nodes.len() { return false }
    match type_nodes.get(type_index).unwrap().parameter_fact {
        some(parameter) => verifier_candidate_formal_contains(
            active_formals, parameter),
        none => false
    }
}

fn verifier_direct_actual_for_formal(
    target: PlannerCallTarget, formal: FlowGenericParamFact
) -> Int? {
    if !planner_call_target_is_direct(target) { return none }
    let mut found: Int? = none
    for substitution in planner_call_target_type_substitutions(target) {
        if flow_generic_param_fact_same(
                flow_type_substitution_parameter(substitution), formal) {
            if found.is_some() {
                panic("ResourcePlanner verifier: direct substitution repeats a formal")
            }
            found = some(core_type_ref_index(
                flow_type_substitution_replacement(substitution)))
        }
    }
    found
}

fn verifier_collect_active_candidate_formals(
    type_nodes: List<PlannerTypeNode>, bodies: List<PlannerBody>
) -> List<FlowGenericParamFact> {
    let mut active: List<FlowGenericParamFact> = []
    let mut forwards: List<(FlowGenericParamFact, FlowGenericParamFact)> = []
    for body in bodies {
        let reachable = planner_body_reachable_blocks(body)
        let mut block_index = 0
        while block_index < body.blocks.len() {
            if reachable.get(block_index).unwrap() {
                for event in body.blocks.get(block_index).unwrap().events {
                    match event.value {
                        PlannerEventValue::CallValue { call_target, .. } => if
                                planner_call_target_is_direct(call_target) {
                            for substitution in
                                    planner_call_target_type_substitutions(
                                        call_target) {
                                let formal = flow_type_substitution_parameter(
                                    substitution)
                                let actual = core_type_ref_index(
                                    flow_type_substitution_replacement(
                                        substitution))
                                if actual < 0 || actual >= type_nodes.len() {
                                    panic("ResourcePlanner verifier: direct substitution actual is absent")
                                }
                                if planner_type_is_callable(
                                        type_nodes, actual) {
                                    let _ = verifier_append_candidate_formal(
                                        active, formal)
                                } else {
                                    match type_nodes.get(actual).unwrap()
                                            .parameter_fact {
                                        some(source) => {
                                            if !forwards.any(fn(edge) {
                                                    flow_generic_param_fact_same(
                                                        edge.0, formal) &&
                                                    flow_generic_param_fact_same(
                                                        edge.1, source)
                                                }) {
                                                forwards.push((formal, source))
                                            }
                                        },
                                        none => {}
                                    }
                                }
                            }
                        },
                        _ => {}
                    }
                }
            }
            block_index = block_index + 1
        }
    }
    let mut changed = true
    while changed {
        changed = false
        for edge in forwards {
            if verifier_candidate_formal_contains(active, edge.1) &&
               verifier_append_candidate_formal(active, edge.0) {
                changed = true
            }
        }
    }
    active
}

fn verifier_call_formal_accepts_candidates(
    type_nodes: List<PlannerTypeNode>, call_target: PlannerCallTarget,
    callee: Int, formal_type_index: Int,
    active_formals: List<FlowGenericParamFact>
) -> Bool {
    if planner_type_is_callable(type_nodes, formal_type_index) { return true }
    let formal = match type_nodes.get(formal_type_index).unwrap().parameter_fact {
        some(value) => value,
        none => return false
    }
    if !planner_call_target_is_direct(call_target) ||
       planner_call_target_direct(call_target) != callee {
        return false
    }
    match verifier_direct_actual_for_formal(call_target, formal) {
        some(actual) => verifier_type_accepts_candidates(
            type_nodes, actual, active_formals),
        none => false
    }
}

fn verifier_location_type_index(
    body: PlannerBody, location: PlannerCallableLocation
) -> Int {
    if planner_callable_location_is_slot(location) {
        return body.slots.get(
            planner_callable_location_slot(location)).unwrap().type_index
    }
    core_type_ref_index(flow_projection_contract_result_type(
        planner_callable_location_projection(location)))
}

fn verifier_location_is_active_formal(
    body: PlannerBody, location: PlannerCallableLocation,
    type_nodes: List<PlannerTypeNode>,
    active_formals: List<FlowGenericParamFact>
) -> Bool {
    verifier_type_is_active_formal(
        type_nodes, verifier_location_type_index(body, location),
        active_formals)
}

fn verifier_callable_location_for_place(
    value: PlannerPlace
) -> PlannerCallableLocation {
    if planner_place_is_slot(value) {
        make_planner_callable_slot_location(planner_place_slot(value))
    } else {
        make_planner_callable_projection_location(
            planner_place_base(value), planner_place_projection(value))
    }
}

fn verifier_location_overwritten_by_place(
    location: PlannerCallableLocation, value: PlannerPlace
) -> Bool {
    if planner_place_is_slot(value) {
        let base = if planner_callable_location_is_slot(location) {
            planner_callable_location_slot(location)
        } else { planner_callable_location_base(location) }
        planner_place_slot(value) == base
    } else {
        planner_callable_location_same(
            location, verifier_callable_location_for_place(value))
    }
}

fn verifier_body_callable_locations(
    body: PlannerBody, type_nodes: List<PlannerTypeNode>,
    active_formals: List<FlowGenericParamFact>
) -> List<PlannerCallableLocation> {
    let mut result: List<PlannerCallableLocation> = []
    let mut slot = 0
    while slot < body.slots.len() {
        if verifier_type_accepts_candidates(
                type_nodes, body.slots.get(slot).unwrap().type_index,
                active_formals) {
            verifier_append_callable_location(
                result, make_planner_callable_slot_location(slot))
        }
        slot = slot + 1
    }
    for block in body.blocks {
        for event in block.events {
            match event.value {
                PlannerEventValue::AssignValue { target, .. } => if
                        !planner_place_is_slot(target) {
                    let location = verifier_callable_location_for_place(target)
                    if verifier_location_is_active_formal(
                            body, location, type_nodes, active_formals) {
                        verifier_append_callable_location(result, location)
                    }
                },
                PlannerEventValue::MovePlaceValue { source, .. } => if
                        !planner_place_is_slot(source) {
                    let location = verifier_callable_location_for_place(source)
                    if verifier_location_is_active_formal(
                            body, location, type_nodes, active_formals) {
                        verifier_append_callable_location(result, location)
                    }
                },
                PlannerEventValue::ProjectValue {
                    source, projection, value_type_index, ..
                } => if verifier_type_is_active_formal(
                        type_nodes, value_type_index, active_formals) {
                    verifier_append_callable_location(result,
                        make_planner_callable_projection_location(
                            source, projection))
                },
                _ => {}
            }
            for fact in event.callable_provenance {
                verifier_append_callable_location(result, fact.target)
                match fact.origin {
                    PlannerCallableOriginValue::LocationCallableOriginValue(
                        sources) => {
                            for source in sources {
                                verifier_append_callable_location(result, source)
                            }
                        },
                    _ => {}
                }
            }
        }
    }
    result
}

fn verifier_callable_location_index(
    body: PlannerBody, type_nodes: List<PlannerTypeNode>,
    active_formals: List<FlowGenericParamFact>,
    target: PlannerCallableLocation
) -> Int {
    let locations = verifier_body_callable_locations(
        body, type_nodes, active_formals)
    let mut index = 0
    while index < locations.len() {
        if planner_callable_location_same(
                locations.get(index).unwrap(), target) { return index }
        index = index + 1
    }
    panic("ResourcePlanner: callable location is not registered")
}

fn verifier_candidate_location_overwritten(
    event: PlannerEvent, body: PlannerBody,
    location: PlannerCallableLocation,
    type_nodes: List<PlannerTypeNode>,
    active_formals: List<FlowGenericParamFact>
) -> Bool {
    for fact in event.callable_provenance {
        if planner_callable_location_same(fact.target, location) { return true }
    }
    let base_slot = if planner_callable_location_is_slot(location) {
        planner_callable_location_slot(location)
    } else {
        planner_callable_location_base(location)
    }
    let active_formal = verifier_location_is_active_formal(
        body, location, type_nodes, active_formals)
    match event.value {
        PlannerEventValue::InitializeValue { target, .. } =>
            active_formal && target == base_slot,
        PlannerEventValue::ReadValue { target, .. } =>
            active_formal && target == base_slot,
        PlannerEventValue::ConsumeValue(source, _, target) =>
            source == base_slot || match target {
                some(value) => active_formal && value == base_slot,
                none => false
            },
        PlannerEventValue::DiscardValue(target) => target == base_slot,
        PlannerEventValue::ScopeExitValue(scope_id) =>
            body.slots.get(base_slot).unwrap().scope_id == scope_id,
        PlannerEventValue::AssignValue { rhs_temp, target } =>
            rhs_temp == base_slot ||
            (active_formal && verifier_location_overwritten_by_place(
                location, target)),
        PlannerEventValue::MovePlaceValue { source, target } =>
            verifier_location_overwritten_by_place(location, source) ||
                (active_formal && target == base_slot),
        PlannerEventValue::CallValue { result_slot, .. } => match result_slot {
            some(target) => active_formal && target == base_slot,
            none => false
        },
        PlannerEventValue::ProjectValue { target, .. } =>
            active_formal && target == base_slot,
        PlannerEventValue::CaptureValue { target, .. } =>
            active_formal && target == base_slot,
        _ => false
    }
}

fn verifier_add_location_transfer_rules(
    graph: VerifierCandidateGraph, body_index: Int, block_index: Int,
    boundary: Int, event: PlannerEvent,
    target: PlannerCallableLocation,
    sources: List<PlannerCallableLocation>,
    type_nodes: List<PlannerTypeNode>, bodies: List<PlannerBody>,
    active_formals: List<FlowGenericParamFact>
) {
    let body = bodies.get(body_index).unwrap()
    if !verifier_location_is_active_formal(
            body, target, type_nodes, active_formals) {
        return
    }
    let site = make_instruction_candidate_rule_site(
        make_flow_instruction_ref(
            body.reference, block_index, boundary))
    for source in sources {
        if !verifier_type_accepts_candidates(
                type_nodes, verifier_location_type_index(body, source),
                active_formals) {
            panic("ResourcePlanner verifier: formal transfer source is not callable")
        }
        let mut candidate = 0
        while candidate < graph.callable_count {
            verifier_add_candidate_rule(
                graph.rules, candidate_rule_copy(), site,
                verifier_candidate_cell_index(
                    graph.cells, candidate_cell_state(), body_index,
                    block_index, boundary + 1,
                    verifier_callable_location_index(
                        body, type_nodes, active_formals, target), candidate),
                [verifier_candidate_cell_index(
                    graph.cells, candidate_cell_state(), body_index,
                    block_index, boundary,
                    verifier_callable_location_index(
                        body, type_nodes, active_formals, source), candidate)])
            candidate = candidate + 1
        }
    }
}

fn verifier_add_value_transfer_rules(
    graph: VerifierCandidateGraph, body_index: Int, block_index: Int,
    boundary: Int, event: PlannerEvent,
    type_nodes: List<PlannerTypeNode>,
    callables: List<PlannerCallable>, bodies: List<PlannerBody>,
    active_formals: List<FlowGenericParamFact>
) {
    let body = bodies.get(body_index).unwrap()
    match event.value {
        PlannerEventValue::InitializeValue {
            input_slots, origin_input_ordinals, target, ..
        } => {
            let mut sources: List<PlannerCallableLocation> = []
            for ordinal in origin_input_ordinals {
                sources.push(make_planner_callable_slot_location(
                    input_slots.get(ordinal).unwrap()))
            }
            verifier_add_location_transfer_rules(
                graph, body_index, block_index, boundary, event,
                make_planner_callable_slot_location(target), sources,
                type_nodes, bodies, active_formals)
        },
        PlannerEventValue::ReadValue { source, target } =>
            verifier_add_location_transfer_rules(
                graph, body_index, block_index, boundary, event,
                make_planner_callable_slot_location(target),
                [make_planner_callable_slot_location(source)],
                type_nodes, bodies, active_formals),
        PlannerEventValue::ConsumeValue(source, _, target) => match target {
            some(sink) => verifier_add_location_transfer_rules(
                graph, body_index, block_index, boundary, event,
                make_planner_callable_slot_location(sink),
                [make_planner_callable_slot_location(source)],
                type_nodes, bodies, active_formals),
            none => {}
        },
        PlannerEventValue::AssignValue { rhs_temp, target } =>
            verifier_add_location_transfer_rules(
                graph, body_index, block_index, boundary, event,
                verifier_callable_location_for_place(target),
                [make_planner_callable_slot_location(rhs_temp)],
                type_nodes, bodies, active_formals),
        PlannerEventValue::MovePlaceValue { source, target } =>
            verifier_add_location_transfer_rules(
                graph, body_index, block_index, boundary, event,
                make_planner_callable_slot_location(target),
                [verifier_callable_location_for_place(source)],
                type_nodes, bodies, active_formals),
        PlannerEventValue::ProjectValue {
            source, target, projection, ..
        } => verifier_add_location_transfer_rules(
            graph, body_index, block_index, boundary, event,
            make_planner_callable_slot_location(target),
            [make_planner_callable_projection_location(source, projection)],
            type_nodes, bodies, active_formals),
        PlannerEventValue::CaptureValue { source, target, .. } =>
            verifier_add_location_transfer_rules(
                graph, body_index, block_index, boundary, event,
                make_planner_callable_slot_location(target),
                [make_planner_callable_slot_location(source)],
                type_nodes, bodies, active_formals),
        PlannerEventValue::CallValue {
            call_target, argument_slots,
            result_origin_argument_ordinals, result_slot, ..
        } => match result_slot {
            some(result) => {
                let target = make_planner_callable_slot_location(result)
                if verifier_location_is_active_formal(
                        body, target, type_nodes, active_formals) {
                    let site = make_instruction_candidate_rule_site(
                        make_flow_instruction_ref(
                            body.reference, block_index, boundary))
                    let mut callee = 0
                    while callee < graph.callable_count {
                        if planner_call_target_is_direct(call_target) &&
                           planner_call_target_direct(call_target) == callee &&
                           verifier_call_formal_accepts_candidates(
                                type_nodes, call_target, callee,
                                callables.get(callee).unwrap().result_type_index,
                                active_formals) {
                            let mut candidate = 0
                            while candidate < graph.callable_count {
                                verifier_add_candidate_rule(
                                    graph.rules, candidate_rule_copy(), site,
                                    verifier_candidate_cell_index(
                                        graph.cells, candidate_cell_state(),
                                        body_index, block_index, boundary + 1,
                                        verifier_callable_location_index(
                                            body, type_nodes, active_formals,
                                            target), candidate),
                                    [verifier_candidate_cell_index(
                                        graph.cells, candidate_cell_result(),
                                        callee, 0, 0, 0, candidate)])
                                candidate = candidate + 1
                            }
                        }
                        callee = callee + 1
                    }
                    let mut alias_sources: List<PlannerCallableLocation> = []
                    for ordinal in result_origin_argument_ordinals {
                        alias_sources.push(make_planner_callable_slot_location(
                            argument_slots.get(ordinal).unwrap()))
                    }
                    verifier_add_location_transfer_rules(
                        graph, body_index, block_index, boundary, event,
                        target, alias_sources, type_nodes, bodies,
                        active_formals)
                }
            },
            none => {}
        },
        _ => {}
    }
}

fn verifier_add_candidate_provenance_rules(
    graph: VerifierCandidateGraph, body_index: Int, block_index: Int,
    boundary: Int, event: PlannerEvent,
    type_nodes: List<PlannerTypeNode>,
    callables: List<PlannerCallable>, bodies: List<PlannerBody>,
    active_formals: List<FlowGenericParamFact>
) {
    let body = bodies.get(body_index).unwrap()
    let site = make_instruction_candidate_rule_site(
        make_flow_instruction_ref(
            bodies.get(body_index).unwrap().reference,
            block_index, boundary))
    for fact in event.callable_provenance {
        let mut candidate = 0
        while candidate < graph.callable_count {
            let target = verifier_candidate_cell_index(
                graph.cells, candidate_cell_state(), body_index,
                block_index, boundary + 1,
                verifier_callable_location_index(
                    body, type_nodes, active_formals, fact.target),
                candidate)
            match fact.origin {
                PlannerCallableOriginValue::DirectCallableOriginValue(direct) =>
                    if direct == candidate {
                        verifier_add_candidate_rule(
                            graph.rules, candidate_rule_seed(), site,
                            target, [])
                    },
                PlannerCallableOriginValue::LocationCallableOriginValue(sources) =>
                    { for source in sources {
                        verifier_add_candidate_rule(
                            graph.rules, candidate_rule_copy(), site, target,
                            [verifier_candidate_cell_index(
                                graph.cells, candidate_cell_state(), body_index,
                                block_index, boundary,
                                verifier_callable_location_index(
                                    body, type_nodes, active_formals,
                                    source), candidate)])
                    } },
                PlannerCallableOriginValue::CallCallableOriginValue {
                    target: call_target, arguments: _
                } => {
                    let mut callee = 0
                    while callee < graph.callable_count {
                        let supports_result = if
                                planner_call_target_is_direct(call_target) {
                            planner_call_target_direct(call_target) == callee &&
                                verifier_call_formal_accepts_candidates(
                                    type_nodes, call_target, callee,
                                    callables.get(callee).unwrap()
                                        .result_type_index,
                                    active_formals)
                        } else {
                            planner_type_is_callable(
                                type_nodes, callables.get(
                                    callee).unwrap().result_type_index)
                        }
                        if !supports_result {
                            callee = callee + 1
                            continue
                        }
                        let result_cell = verifier_candidate_cell_index(
                            graph.cells, candidate_cell_result(), callee,
                            0, 0, 0, candidate)
                        if planner_call_target_is_direct(call_target) {
                            if planner_call_target_direct(call_target) == callee {
                                verifier_add_candidate_rule(
                                    graph.rules, candidate_rule_copy(), site,
                                    target, [result_cell])
                            }
                        } else {
                            verifier_add_candidate_conjunction_rule(
                                graph.rules, site, target,
                                verifier_candidate_cell_index(
                                    graph.cells, candidate_cell_state(),
                                    body_index, block_index, boundary,
                                    verifier_callable_location_index(
                                        body, type_nodes, active_formals,
                                        make_planner_callable_slot_location(
                                            planner_call_target_slot(call_target))),
                                    callee),
                                result_cell)
                        }
                        callee = callee + 1
                    }
                }
            }
            match event.value {
                PlannerEventValue::CallValue {
                    argument_slots, result_origin_argument_ordinals, ..
                } => { for ordinal in result_origin_argument_ordinals {
                    let argument_slot = argument_slots.get(ordinal).unwrap()
                    if !verifier_type_accepts_candidates(
                            type_nodes,
                            body.slots.get(argument_slot).unwrap().type_index,
                            active_formals) {
                        panic("ResourcePlanner: callable result aliases non-callable argument")
                    }
                    verifier_add_candidate_rule(
                        graph.rules, candidate_rule_copy(), site, target,
                        [verifier_candidate_cell_index(
                            graph.cells, candidate_cell_state(), body_index,
                            block_index, boundary,
                            verifier_callable_location_index(
                                body, type_nodes, active_formals,
                                make_planner_callable_slot_location(
                                    argument_slot)), candidate)])
                } },
                _ => {}
            }
            candidate = candidate + 1
        }
    }
}

fn verifier_add_candidate_call_argument_rules(
    graph: VerifierCandidateGraph, body_index: Int, block_index: Int,
    boundary: Int, event: PlannerEvent,
    type_nodes: List<PlannerTypeNode>,
    callables: List<PlannerCallable>, bodies: List<PlannerBody>,
    active_formals: List<FlowGenericParamFact>
) {
    match event.value {
        PlannerEventValue::CallValue {
            call_target, argument_slots, ..
        } => {
            let site = make_instruction_candidate_rule_site(
                make_flow_instruction_ref(
                    bodies.get(body_index).unwrap().reference,
                    block_index, boundary))
            let body = bodies.get(body_index).unwrap()
            let mut callee = 0
            while callee < graph.callable_count {
                let parameter_count = callables.get(
                    callee).unwrap().parameter_type_indices.len()
                if parameter_count != argument_slots.len() {
                    callee = callee + 1
                    continue
                }
                let mut parameter = 0
                while parameter < parameter_count {
                    let formal_type = callables.get(callee).unwrap()
                        .parameter_type_indices.get(parameter).unwrap()
                    let supports_parameter = if
                            planner_call_target_is_direct(call_target) {
                        planner_call_target_direct(call_target) == callee &&
                            verifier_call_formal_accepts_candidates(
                                type_nodes, call_target, callee,
                                formal_type, active_formals)
                    } else {
                        planner_type_is_callable(type_nodes, formal_type)
                    }
                    if !supports_parameter {
                        parameter = parameter + 1
                        continue
                    }
                    let argument_slot = argument_slots.get(parameter).unwrap()
                    if !verifier_type_accepts_candidates(
                            type_nodes,
                            body.slots.get(argument_slot).unwrap().type_index,
                            active_formals) {
                        panic("ResourcePlanner: callable parameter receives non-callable slot")
                    }
                    let mut candidate = 0
                    while candidate < graph.callable_count {
                        let target = verifier_candidate_cell_index(
                            graph.cells, candidate_cell_parameter(), callee,
                            0, 0, parameter, candidate)
                        let argument_cell = verifier_candidate_cell_index(
                            graph.cells, candidate_cell_state(), body_index,
                            block_index, boundary,
                            verifier_callable_location_index(
                                body, type_nodes, active_formals,
                                make_planner_callable_slot_location(
                                    argument_slot)), candidate)
                        if planner_call_target_is_direct(call_target) {
                            if planner_call_target_direct(call_target) == callee {
                                verifier_add_candidate_rule(
                                    graph.rules, candidate_rule_copy(), site,
                                    target, [argument_cell])
                            }
                        } else {
                            verifier_add_candidate_conjunction_rule(
                                graph.rules, site, target,
                                verifier_candidate_cell_index(
                                    graph.cells, candidate_cell_state(),
                                    body_index, block_index, boundary,
                                    verifier_callable_location_index(
                                        body, type_nodes, active_formals,
                                        make_planner_callable_slot_location(
                                            planner_call_target_slot(call_target))),
                                    callee),
                                argument_cell)
                        }
                        candidate = candidate + 1
                    }
                    parameter = parameter + 1
                }
                callee = callee + 1
            }
        },
        _ => {}
    }
}

fn build_verifier_candidate_graph(
    type_nodes: List<PlannerTypeNode>,
    callables: List<PlannerCallable>, bodies: List<PlannerBody>
) -> VerifierCandidateGraph {
    let mut cells: List<CandidateCellSpec> = []
    let rules: List<CandidateRule> = []
    let callable_count = callables.len()
    let active_formals = verifier_collect_active_candidate_formals(
        type_nodes, bodies)
    let mut callable_index = 0
    while callable_index < callable_count {
        let callable = callables.get(callable_index).unwrap()
        let mut parameter = 0
        while parameter < callable.parameter_type_indices.len() {
            if verifier_type_accepts_candidates(
                    type_nodes,
                    callable.parameter_type_indices.get(parameter).unwrap(),
                    active_formals) {
                let mut candidate = 0
                while candidate < callable_count {
                    cells.push(make_candidate_cell_spec(
                        candidate_cell_parameter(), callable_index,
                        0, 0, parameter, candidate))
                    candidate = candidate + 1
                }
            }
            parameter = parameter + 1
        }
        if verifier_type_accepts_candidates(
                type_nodes, callable.result_type_index, active_formals) {
            let mut candidate = 0
            while candidate < callable_count {
                cells.push(make_candidate_cell_spec(
                    candidate_cell_result(), callable_index,
                    0, 0, 0, candidate))
                candidate = candidate + 1
            }
        }
        callable_index = callable_index + 1
    }
    let mut body_index = 0
    while body_index < bodies.len() {
        let body = bodies.get(body_index).unwrap()
        let locations = verifier_body_callable_locations(
            body, type_nodes, active_formals)
        let mut block_index = 0
        while block_index < body.blocks.len() {
            let block = body.blocks.get(block_index).unwrap()
            let mut boundary = 0
            while boundary <= block.events.len() {
                let mut location = 0
                while location < locations.len() {
                    let mut candidate = 0
                    while candidate < callable_count {
                        cells.push(make_candidate_cell_spec(
                            candidate_cell_state(), body_index,
                            block_index, boundary, location, candidate))
                        candidate = candidate + 1
                    }
                    location = location + 1
                }
                boundary = boundary + 1
            }
            block_index = block_index + 1
        }
        body_index = body_index + 1
    }
    let graph = VerifierCandidateGraph {
        callable_count: callable_count, cells: cells, rules: rules
    }
    // ContractOnly callable result aliases are global copy rules.
    callable_index = 0
    while callable_index < callable_count {
        let callable = callables.get(callable_index).unwrap()
        if !callable.has_body && verifier_type_accepts_candidates(
                type_nodes, callable.result_type_index, active_formals) {
            for parameter in callable.result_origin_parameter_ordinals {
                if !verifier_type_accepts_candidates(
                        type_nodes,
                        callable.parameter_type_indices.get(parameter).unwrap(),
                        active_formals) {
                    panic("ResourcePlanner: callable result aliases non-callable parameter")
                }
                let mut candidate = 0
                while candidate < callable_count {
                    verifier_add_candidate_rule(
                        graph.rules, candidate_rule_copy(),
                        make_global_candidate_rule_site(),
                        verifier_candidate_cell_index(
                            graph.cells, candidate_cell_result(),
                            callable_index, 0, 0, 0, candidate),
                        [verifier_candidate_cell_index(
                            graph.cells, candidate_cell_parameter(),
                            callable_index, 0, 0, parameter, candidate)])
                    candidate = candidate + 1
                }
            }
        }
        callable_index = callable_index + 1
    }
    body_index = 0
    while body_index < bodies.len() {
        let body = bodies.get(body_index).unwrap()
        let locations = verifier_body_callable_locations(
            body, type_nodes, active_formals)
        let reachable = planner_body_reachable_blocks(body)
        let callable = flow_callable_index_for_planner(
            callables, body.reference)
        // Entry parameter cells.
        let mut slot_index = 0
        while slot_index < body.slots.len() {
            match body.slots.get(slot_index).unwrap().parameter_ordinal {
                some(parameter) => {
                    if !verifier_type_accepts_candidates(
                            type_nodes,
                            body.slots.get(slot_index).unwrap().type_index,
                            active_formals) {
                        slot_index = slot_index + 1
                        continue
                    }
                    let mut candidate = 0
                    while candidate < callable_count {
                        verifier_add_candidate_rule(
                            graph.rules, candidate_rule_copy(),
                            make_global_candidate_rule_site(),
                            verifier_candidate_cell_index(
                                graph.cells, candidate_cell_state(), body_index,
                                body.entry_block, 0,
                                verifier_callable_location_index(
                                    body, type_nodes, active_formals,
                                    make_planner_callable_slot_location(
                                        slot_index)), candidate),
                            [verifier_candidate_cell_index(
                                graph.cells, candidate_cell_parameter(),
                                callable, 0, 0, parameter, candidate)])
                        candidate = candidate + 1
                    }
                },
                none => {}
            }
            slot_index = slot_index + 1
        }
        let mut block_index = 0
        while block_index < body.blocks.len() {
            let block = body.blocks.get(block_index).unwrap()
            if !reachable.get(block_index).unwrap() {
                block_index = block_index + 1
                continue
            }
            let mut boundary = 0
            while boundary < block.events.len() {
                let event = block.events.get(boundary).unwrap()
                let site = make_instruction_candidate_rule_site(
                    make_flow_instruction_ref(
                        body.reference, block_index, boundary))
                let mut location = 0
                while location < locations.len() {
                    if !verifier_candidate_location_overwritten(
                            event, body, locations.get(location).unwrap(),
                            type_nodes, active_formals) {
                        let mut candidate = 0
                        while candidate < callable_count {
                            verifier_add_candidate_rule(
                                graph.rules, candidate_rule_copy(), site,
                                verifier_candidate_cell_index(
                                    graph.cells, candidate_cell_state(),
                                    body_index, block_index, boundary + 1,
                                    location, candidate),
                                [verifier_candidate_cell_index(
                                    graph.cells, candidate_cell_state(),
                                    body_index, block_index, boundary,
                                    location, candidate)])
                            candidate = candidate + 1
                        }
                    }
                    location = location + 1
                }
                verifier_add_candidate_provenance_rules(
                    graph, body_index, block_index, boundary,
                    event, type_nodes, callables, bodies, active_formals)
                verifier_add_value_transfer_rules(
                    graph, body_index, block_index, boundary,
                    event, type_nodes, callables, bodies, active_formals)
                verifier_add_candidate_call_argument_rules(
                    graph, body_index, block_index, boundary,
                    event, type_nodes, callables, bodies, active_formals)
                boundary = boundary + 1
            }
            let end_boundary = block.events.len()
            if block.terminator_kind == 3 &&
               verifier_type_accepts_candidates(
                    type_nodes,
                    callables.get(callable).unwrap().result_type_index,
                    active_formals) {
                for usage in block.terminator_uses {
                    if !verifier_type_accepts_candidates(
                            type_nodes,
                            body.slots.get(usage.slot).unwrap().type_index,
                            active_formals) {
                        panic("ResourcePlanner: callable return uses non-callable slot")
                    }
                    let mut candidate = 0
                    while candidate < callable_count {
                        verifier_add_candidate_rule(
                            graph.rules, candidate_rule_copy(),
                            make_terminator_candidate_rule_site(
                                make_flow_block_ref(body.reference, block_index)),
                            verifier_candidate_cell_index(
                                graph.cells, candidate_cell_result(),
                                callable, 0, 0, 0, candidate),
                            [verifier_candidate_cell_index(
                                graph.cells, candidate_cell_state(), body_index,
                                block_index, end_boundary,
                                verifier_callable_location_index(
                                    body, type_nodes, active_formals,
                                    make_planner_callable_slot_location(
                                        usage.slot)), candidate)])
                        candidate = candidate + 1
                    }
                }
            }
            let mut edge_index = 0
            while edge_index < block.edges.len() {
                let edge = block.edges.get(edge_index).unwrap()
                match edge.target_block {
                    some(target_block) => {
                        let mut location = 0
                        while location < locations.len() {
                            let exact_location = locations.get(location).unwrap()
                            let base_slot = if planner_callable_location_is_slot(
                                    exact_location) {
                                planner_callable_location_slot(exact_location)
                            } else {
                                planner_callable_location_base(exact_location)
                            }
                            if !int_list_contains(
                                    edge.exited_scope_ids,
                                    body.slots.get(base_slot).unwrap().scope_id) {
                                let mut candidate = 0
                                while candidate < callable_count {
                                    verifier_add_candidate_rule(
                                        graph.rules, candidate_rule_copy(),
                                        make_edge_candidate_rule_site(
                                            make_flow_block_ref(
                                                body.reference, block_index),
                                            edge_index),
                                        verifier_candidate_cell_index(
                                            graph.cells, candidate_cell_state(),
                                            body_index, target_block, 0,
                                            location, candidate),
                                        [verifier_candidate_cell_index(
                                            graph.cells, candidate_cell_state(),
                                            body_index, block_index,
                                            end_boundary, location, candidate)])
                                    candidate = candidate + 1
                                }
                            }
                            location = location + 1
                        }
                    },
                    none => {}
                }
                edge_index = edge_index + 1
            }
            block_index = block_index + 1
        }
        body_index = body_index + 1
    }
    graph
}

fn candidate_rule_sites_same(
    left: CandidateRuleSite, right: CandidateRuleSite
) -> Bool {
    if candidate_rule_site_kind_tag(left) !=
       candidate_rule_site_kind_tag(right) {
        return false
    }
    let tag = candidate_rule_site_kind_tag(left)
    if tag == 0 { return true }
    if tag == 1 {
        return flow_instruction_ref_same(
            candidate_rule_site_instruction(left),
            candidate_rule_site_instruction(right))
    }
    if !flow_block_ref_same(
            candidate_rule_site_block(left),
            candidate_rule_site_block(right)) {
        return false
    }
    tag == 2 || candidate_rule_site_successor_ordinal(left) ==
        candidate_rule_site_successor_ordinal(right)
}

fn candidate_cells_same(
    left: CandidateCellSpec, right: CandidateCellSpec
) -> Bool {
    candidate_cell_kind_tag(candidate_cell_spec_kind(left)) ==
        candidate_cell_kind_tag(candidate_cell_spec_kind(right)) &&
        candidate_cell_spec_owner(left) == candidate_cell_spec_owner(right) &&
        candidate_cell_spec_block(left) == candidate_cell_spec_block(right) &&
        candidate_cell_spec_boundary(left) ==
            candidate_cell_spec_boundary(right) &&
        candidate_cell_spec_component(left) ==
            candidate_cell_spec_component(right) &&
        candidate_cell_spec_candidate(left) ==
            candidate_cell_spec_candidate(right)
}

fn actual_call_selections_from_bodies(
    bodies: List<PlannerBody>
) -> List<CandidateSelection> {
    let mut result: List<CandidateSelection> = []
    for body in bodies {
        let reachable = planner_body_reachable_blocks(body)
        let mut block_index = 0
        while block_index < body.blocks.len() {
            let block = body.blocks.get(block_index).unwrap()
            if !reachable.get(block_index).unwrap() {
                block_index = block_index + 1
                continue
            }
            let mut instruction = 0
            while instruction < block.events.len() {
                match block.events.get(instruction).unwrap().value {
                    PlannerEventValue::CallValue {
                        call_target, callable_indices, ..
                    } => if !planner_call_target_is_direct(call_target) {
                        result.push(make_candidate_selection(
                            make_flow_instruction_ref(
                                body.reference, block_index, instruction),
                            callable_indices))
                    },
                    _ => {}
                }
                instruction = instruction + 1
            }
            block_index = block_index + 1
        }
    }
    result
}

fn proof_call_selections_from_cells(
    proof: CallableCandidateProof, type_nodes: List<PlannerTypeNode>,
    bodies: List<PlannerBody>
) -> List<CandidateSelection> {
    let cells = callable_candidate_proof_cells(proof)
    let values = callable_candidate_proof_final_values(proof)
    let callable_count = callable_candidate_proof_callable_count(proof)
    let mut result: List<CandidateSelection> = []
    let active_formals = verifier_collect_active_candidate_formals(
        type_nodes, bodies)
    let mut body_index = 0
    while body_index < bodies.len() {
        let body = bodies.get(body_index).unwrap()
        let reachable = planner_body_reachable_blocks(body)
        let mut block_index = 0
        while block_index < body.blocks.len() {
            if !reachable.get(block_index).unwrap() {
                block_index = block_index + 1
                continue
            }
            let block = body.blocks.get(block_index).unwrap()
            let mut instruction = 0
            while instruction < block.events.len() {
                match block.events.get(instruction).unwrap().value {
                    PlannerEventValue::CallValue { call_target, .. } =>
                        if !planner_call_target_is_direct(call_target) {
                            let location = verifier_callable_location_index(
                                body, type_nodes, active_formals,
                                make_planner_callable_slot_location(
                                    planner_call_target_slot(call_target)))
                            let mut candidates: List<Int> = []
                            let mut candidate = 0
                            while candidate < callable_count {
                                let cell = verifier_candidate_cell_index(
                                    cells, candidate_cell_state(), body_index,
                                    block_index, instruction, location, candidate)
                                if values.get(cell).unwrap() {
                                    candidates.push(candidate)
                                }
                                candidate = candidate + 1
                            }
                            result.push(make_candidate_selection(
                                make_flow_instruction_ref(
                                    body.reference, block_index, instruction),
                                candidates))
                        },
                    _ => {}
                }
                instruction = instruction + 1
            }
            block_index = block_index + 1
        }
        body_index = body_index + 1
    }
    result
}

fn verify_candidate_selections_same(
    actual: List<CandidateSelection>,
    expected: List<CandidateSelection>, context: Str
) {
    if actual.len() != expected.len() {
        panic("ResourcePlanner verifier: ${context} selection census drifted")
    }
    let mut index = 0
    while index < expected.len() {
        let candidate = actual.get(index).unwrap()
        let wanted = expected.get(index).unwrap()
        if !flow_instruction_ref_same(
                candidate_selection_instruction(candidate),
                candidate_selection_instruction(wanted)) ||
           !int_lists_same(
                candidate_selection_candidates(candidate),
                candidate_selection_candidates(wanted)) {
            panic("ResourcePlanner verifier: ${context} selection drifted")
        }
        index = index + 1
    }
}

pub fn verify_candidate_graph_contract(
    input: FrozenPlannerInput, certificate: ResourceCertificate
) {
    let proof = resource_certificate_candidate_proof(certificate)
    let expected = build_verifier_candidate_graph(
        input.type_nodes, input.callables, input.bodies)
    let cells = callable_candidate_proof_cells(proof)
    let rules = callable_candidate_proof_rules(proof)
    if callable_candidate_proof_callable_count(proof) !=
           expected.callable_count || cells.len() != expected.cells.len() ||
       rules.len() != expected.rules.len() {
        panic("ResourcePlanner verifier: callable-candidate graph census drifted")
    }
    let mut index = 0
    while index < cells.len() {
        if !candidate_cells_same(
                cells.get(index).unwrap(), expected.cells.get(index).unwrap()) {
            panic("ResourcePlanner verifier: callable-candidate cell drifted")
        }
        index = index + 1
    }
    index = 0
    while index < rules.len() {
        let actual = rules.get(index).unwrap()
        let wanted = expected.rules.get(index).unwrap()
        if candidate_rule_kind_tag(candidate_rule_kind(actual)) !=
               candidate_rule_kind_tag(candidate_rule_kind(wanted)) ||
           candidate_rule_target_cell(actual) !=
               candidate_rule_target_cell(wanted) ||
           !int_lists_same(
                candidate_rule_premise_cells(actual),
                candidate_rule_premise_cells(wanted)) ||
           !candidate_rule_sites_same(
                candidate_rule_site(actual), candidate_rule_site(wanted)) {
            panic("ResourcePlanner verifier: callable-candidate rule drifted")
        }
        index = index + 1
    }
    // Independently project the exact candidate set from certified state cells.
    // The PlannerBody cutover and the explicit certificate selection must both
    // equal that projection; comparing the two producer outputs to each other
    // would accept the same dropped/swapped candidate in both places.
    let derived_selections = proof_call_selections_from_cells(
        proof, input.type_nodes, input.bodies)
    verify_candidate_selections_same(
        actual_call_selections_from_bodies(input.bodies),
        derived_selections, "frozen body")
    verify_candidate_selections_same(
        callable_candidate_proof_selections(proof),
        derived_selections, "certificate")
}

fn slot_option_same(left: SlotRef?, right: SlotRef?) -> Bool {
    match (left, right) {
        (some(a), some(b)) => slot_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
}

fn transition_reason_same(
    left: SlotTransitionReason, right: SlotTransitionReason
) -> Bool {
    slot_transition_reason_tag(left) == slot_transition_reason_tag(right)
}

fn require_transition(
    transition: SlotTransitionWitness, slot: Int,
    reason: SlotTransitionReason, context: Str
) {
    if slot_transition_witness_slot_index(transition) != slot ||
       !transition_reason_same(
            slot_transition_witness_reason(transition), reason) {
        panic("ResourcePlanner verifier: ${context} transition drifted")
    }
}

fn require_transition_count(
    transitions: List<SlotTransitionWitness>, expected: Int, context: Str
) {
    if transitions.len() != expected {
        panic("ResourcePlanner verifier: ${context} transition census drifted")
    }
}

fn require_transition_after_state(
    transition: SlotTransitionWitness, expected: SlotFlow, context: Str
) {
    if !slot_flow_same(
            slot_transition_witness_after(transition), expected) {
        panic("ResourcePlanner verifier: ${context} owner state drifted")
    }
}

fn apply_topology_transitions(
    mut states: List<SlotFlow>, transitions: List<SlotTransitionWitness>
) {
    for transition in transitions {
        let slot = slot_transition_witness_slot_index(transition)
        if slot < 0 || slot >= states.len() ||
           !slot_flow_same(
                states.get(slot).unwrap(),
                slot_transition_witness_before(transition)) {
            panic("ResourcePlanner verifier: transition state/source drifted")
        }
        verify_slot_transition_witness(transition)
        states.set(slot, slot_transition_witness_after(transition))
    }
}

fn topology_state_is_unreachable(states: List<SlotFlow>) -> Bool {
    if states.len() == 0 { return false }
    for state in states {
        if !slot_flow_is_unreachable(state) { return false }
    }
    true
}

fn verifier_decided_transfer(
    body: PlannerBody, event: PlannerEvent, ordinal: Int
) -> TransferDecision {
    for transfer in event.decision.transfers {
        if transfer.operand_ordinal == ordinal {
            if transfer.slot < 0 || transfer.slot >= body.slots.len() ||
               !slot_ref_same(
                    transfer.reference,
                    body.slots.get(transfer.slot).unwrap().reference) {
                panic("ResourcePlanner verifier: decision slot identity drifted")
            }
            return transfer
        }
    }
    panic("ResourcePlanner verifier: transfer decision is absent")
}

fn verifier_bool_list_has_true(values: List<Bool>) -> Bool {
    for value in values { if value { return true } }
    false
}

fn verifier_logical_shape_may_take(
    shape: LogicalOwnershipShape
) -> Bool {
    logical_ownership_shape_direct_drop(shape) ||
        logical_ownership_shape_may_unique(shape) ||
        verifier_bool_list_has_true(
            logical_ownership_shape_param_deps(shape))
}

fn verifier_physical_shape_may_drop(shape: PhysicalRcShape) -> Bool {
    !physical_rc_shape_foreign_containment(shape) &&
       (physical_rc_shape_physical_rc(shape) ||
        physical_rc_shape_drop_glue(shape) ||
        verifier_bool_list_has_true(physical_rc_shape_param_deps(shape)))
}

fn verifier_type_requires_cleanup(
    logical: LogicalOwnershipShape, physical: PhysicalRcShape
) -> Bool {
    verifier_logical_shape_may_take(logical) ||
        verifier_physical_shape_may_drop(physical)
}



fn verifier_cleanup_slot_order(
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
                none => panic(
                    "ResourcePlanner verifier: cleanup order is incomplete")
            }
            remaining = remaining - 1
        }
    }
    result
}

fn demand_source_transition_reason(
    body: PlannerBody, solved: SolvedResourceGraph,
    slot: Int, demand: TransferDemand
) -> SlotTransitionReason {
    let mode = transfer_demand_mode(demand)
    if param_mode_same(mode, param_mode_borrow()) {
        return slot_reason_borrow()
    }
    if param_mode_same(mode, param_mode_mut_borrow()) {
        return slot_reason_mutate()
    }
    if !param_mode_same(mode, param_mode_own()) {
        panic("ResourcePlanner verifier: materialized demand is not concrete")
    }
    let type_index = body.slots.get(slot).unwrap().type_index
    let logical = solved.logical_shapes.get(type_index).unwrap()
    let physical = solved.physical_shapes.get(type_index).unwrap()
    if transfer_demand_force(demand) || verifier_logical_shape_may_take(logical) {
        return slot_reason_take_source()
    }
    if verifier_physical_shape_may_drop(physical) {
        return slot_reason_clone_source()
    }
    slot_reason_borrow()
}

fn transfer_target_transition_reason(
    body: PlannerBody, solved: SolvedResourceGraph,
    source: Int, target: Int, demand: TransferDemand
) -> SlotTransitionReason {
    let mode = transfer_demand_mode(demand)
    let type_index = body.slots.get(source).unwrap().type_index
    if param_mode_same(mode, param_mode_own()) &&
       (transfer_demand_force(demand) ||
        verifier_logical_shape_may_take(
            solved.logical_shapes.get(type_index).unwrap())) {
        return slot_reason_take_target()
    }
    if param_mode_same(mode, param_mode_own()) &&
       body.slots.get(target).unwrap().owns_storage &&
       verifier_physical_shape_may_drop(
            solved.physical_shapes.get(type_index).unwrap()) {
        return slot_reason_clone_target()
    }
    slot_reason_assign_scalar()
}

fn cleanup_transition_reason(
    body: PlannerBody, solved: SolvedResourceGraph,
    slot: Int, state: SlotFlow
) -> SlotTransitionReason {
    let value = body.slots.get(slot).unwrap()
    if slot_flow_cleanup_owner(state) &&
       (verifier_logical_shape_may_take(
            solved.logical_shapes.get(value.type_index).unwrap()) ||
        verifier_physical_shape_may_drop(
            solved.physical_shapes.get(value.type_index).unwrap())) {
        return slot_reason_cleanup()
    }
    slot_reason_scope_end()
}

fn verify_scope_transitions(
    body: PlannerBody, solved: SolvedResourceGraph,
    scope_ids: List<Int>, states: List<SlotFlow>,
    transitions: List<SlotTransitionWitness>, context: Str
) {
    let mut expected_slots: List<Int> = []
    for slot in verifier_cleanup_slot_order(body.slots, scope_ids) {
        if !slot_flow_is_unreachable(states.get(slot).unwrap()) {
            expected_slots.push(slot)
        }
    }
    require_transition_count(transitions, expected_slots.len(), context)
    let mut index = 0
    while index < expected_slots.len() {
        let slot = expected_slots.get(index).unwrap()
        require_transition(
            transitions.get(index).unwrap(), slot,
            cleanup_transition_reason(
                body, solved, slot, states.get(slot).unwrap()), context)
        index = index + 1
    }
}

fn reusable_target_drop_required(state: SlotFlow) -> Bool {
    slot_flow_is_maybe_moved(state) && slot_flow_cleanup_owner(state)
}

fn verify_reusable_target_transition(
    states: List<SlotFlow>, target: Int,
    before: List<SlotTransitionWitness>, context: Str
) -> Int {
    let state = states.get(target).unwrap()
    if slot_flow_is_unreachable(state) {
        panic("ResourcePlanner verifier: ${context} targets unreachable storage")
    }
    if slot_flow_is_live(state) {
        panic("ResourcePlanner verifier: ${context} overwrites live storage")
    }
    if !reusable_target_drop_required(state) { return 0 }
    let transition = before.get(0).unwrap_or_else(fn() {
        panic("ResourcePlanner verifier: ${context} target Drop is absent")
    })
    require_transition(transition, target, slot_reason_drop(), context)
    require_transition_after_state(
        transition, slot_flow_empty(), context)
    1
}

fn verify_event_transition_contract(
    body: PlannerBody, event: PlannerEvent,
    solved: SolvedResourceGraph, states: List<SlotFlow>,
    before: List<SlotTransitionWitness>,
    semantic: List<SlotTransitionWitness>,
    after: List<SlotTransitionWitness>
) {
    match event.value {
        PlannerEventValue::NoOpValue => {
            require_transition_count(before, 0, "NoOp before")
            require_transition_count(semantic, 0, "NoOp semantic")
            require_transition_count(after, 0, "NoOp after")
        },
        PlannerEventValue::ScopeExitValue(scope_id) => {
            verify_scope_transitions(
                body, solved, [scope_id], states, before, "ScopeExit")
            require_transition_count(semantic, 0, "ScopeExit semantic")
            require_transition_count(after, 0, "ScopeExit after")
        },
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, target, ..
        } => {
            let before_offset = verify_reusable_target_transition(
                states, target, before, "Initialize")
            require_transition_count(
                before, before_offset + input_slots.len(), "Initialize input")
            let mut index = 0
            while index < input_slots.len() {
                let slot = input_slots.get(index).unwrap()
                require_transition(
                    before.get(before_offset + index).unwrap(), slot,
                    demand_source_transition_reason(
                        body, solved, slot,
                        verifier_decided_transfer(
                            body, event, index).demand),
                    "Initialize input")
                index = index + 1
            }
            require_transition_count(semantic, 1, "Initialize target")
            require_transition(
                semantic.get(0).unwrap(), target,
                slot_reason_init_live(), "Initialize target")
            let target_value = body.slots.get(target).unwrap()
            require_transition_after_state(
                semantic.get(0).unwrap(),
                slot_flow_live_owner(
                    target_value.owns_storage &&
                    verifier_type_requires_cleanup(
                        solved.logical_shapes.get(
                            target_value.type_index).unwrap(),
                        solved.physical_shapes.get(
                            target_value.type_index).unwrap())),
                "Initialize target")
            require_transition_count(after, 0, "Initialize after")
        },
        PlannerEventValue::ReadValue { source, target } => {
            let demand = verifier_decided_transfer(body, event, 0).demand
            let before_offset = verify_reusable_target_transition(
                states, target, before, "Read")
            require_transition_count(
                before, before_offset + 1, "Read source")
            require_transition(
                before.get(before_offset).unwrap(), source,
                demand_source_transition_reason(body, solved, source, demand),
                "Read source")
            require_transition_count(semantic, 1, "Read target")
            require_transition(
                semantic.get(0).unwrap(), target,
                transfer_target_transition_reason(
                    body, solved, source, target, demand),
                "Read target")
            require_transition_count(after, 0, "Read after")
        },
        PlannerEventValue::MutateValue {
            target, value, value_demand
        } => {
            require_transition_count(before, 1, "Mutate value")
            require_transition(
                before.get(0).unwrap(), value,
                demand_source_transition_reason(
                    body, solved, value,
                    verifier_decided_transfer(body, event, 1).demand),
                "Mutate value")
            require_transition_count(semantic, 1, "Mutate target")
            require_transition(
                semantic.get(0).unwrap(), target,
                slot_reason_mutate(), "Mutate target")
            require_transition_count(after, 0, "Mutate after")
        },
        PlannerEventValue::ConsumeValue(slot, _, target) => {
            let demand = verifier_decided_transfer(body, event, 0).demand
            let before_offset = match target {
                some(value) => verify_reusable_target_transition(
                    states, value, before, "Consume sink"),
                none => 0
            }
            require_transition_count(
                before, before_offset + 1, "Consume source")
            require_transition(
                before.get(before_offset).unwrap(), slot,
                demand_source_transition_reason(body, solved, slot, demand),
                "Consume source")
            match target {
                some(value) => {
                    require_transition_count(
                        semantic, 1, "Consume sink semantic")
                    require_transition(
                        semantic.get(0).unwrap(), value,
                        slot_reason_take_target(), "Consume sink semantic")
                    let type_index = body.slots.get(slot).unwrap().type_index
                    let owner = param_mode_same(
                            transfer_demand_mode(demand), param_mode_own()) &&
                        (transfer_demand_force(demand) ||
                         verifier_type_requires_cleanup(
                            solved.logical_shapes.get(type_index).unwrap(),
                            solved.physical_shapes.get(type_index).unwrap()))
                    require_transition_after_state(
                        semantic.get(0).unwrap(),
                        slot_flow_live_owner(owner), "Consume sink semantic")
                },
                none => require_transition_count(
                    semantic, 0, "Consume semantic")
            }
            require_transition_count(after, 0, "Consume after")
        },
        PlannerEventValue::DiscardValue(slot) => {
            require_transition_count(before, 1, "Discard")
            require_transition(
                before.get(0).unwrap(), slot,
                if slot_flow_cleanup_owner(states.get(slot).unwrap()) {
                    slot_reason_drop()
                } else { slot_reason_scope_end() }, "Discard")
            require_transition_count(semantic, 0, "Discard semantic")
            require_transition_count(after, 0, "Discard after")
        },
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            let mut before_index = 0
            if planner_place_is_slot(target) {
                let target_slot = planner_place_slot(target)
                let target_value = body.slots.get(target_slot).unwrap()
                let needs_drop = slot_flow_cleanup_owner(
                    states.get(target_slot).unwrap())
                require_transition_count(
                    before, if needs_drop { 2 } else { 1 }, "Assign before")
                if needs_drop {
                    require_transition(
                        before.get(before_index).unwrap(), target_slot,
                        slot_reason_drop(), "Assign old target")
                    before_index = before_index + 1
                }
                require_transition(
                    before.get(before_index).unwrap(), rhs_temp,
                    slot_reason_take_source(), "Assign RHS")
                require_transition_count(semantic, 1, "Assign target")
                let target_transition = semantic.get(0).unwrap()
                require_transition(
                    target_transition, target_slot,
                    if slot_flow_same(
                            slot_transition_witness_before(target_transition),
                            slot_flow_empty()) {
                        slot_reason_take_target()
                    } else {
                        slot_reason_assign_scalar()
                    }, "Assign target")
            } else {
                let base = planner_place_base(target)
                let value_type = planner_place_value_type(target)
                let needs_drop = verifier_logical_shape_may_take(
                        solved.logical_shapes.get(value_type).unwrap()) ||
                    verifier_physical_shape_may_drop(
                        solved.physical_shapes.get(value_type).unwrap())
                require_transition_count(
                    before, if needs_drop { 2 } else { 1 },
                    "projected Assign before")
                if needs_drop {
                    require_transition(
                        before.get(before_index).unwrap(), base,
                        slot_reason_drop_projected_old(),
                        "projected Assign old target")
                    before_index = before_index + 1
                }
                require_transition(
                    before.get(before_index).unwrap(), rhs_temp,
                    slot_reason_take_source(), "projected Assign RHS")
                require_transition_count(
                    semantic, 1, "projected Assign semantic")
                require_transition(
                    semantic.get(0).unwrap(), base,
                    slot_reason_mutate(), "projected Assign base")
            }
            require_transition_count(after, 0, "Assign after")
        },
        PlannerEventValue::MovePlaceValue { source, target } => {
            let source_slot = if planner_place_is_slot(source) {
                planner_place_slot(source)
            } else { planner_place_base(source) }
            let before_offset = verify_reusable_target_transition(
                states, target, before, "MovePlace")
            require_transition_count(
                before, before_offset + 1, "MovePlace source")
            require_transition(
                before.get(before_offset).unwrap(), source_slot,
                if planner_place_is_slot(source) {
                    demand_source_transition_reason(
                        body, solved, source_slot,
                        verifier_decided_transfer(body, event, 0).demand)
                } else { slot_reason_take_projected_source() },
                "MovePlace source")
            let type_index = if planner_place_is_slot(source) {
                body.slots.get(source_slot).unwrap().type_index
            } else { planner_place_value_type(source) }
            let needs_cleanup = verifier_logical_shape_may_take(
                    solved.logical_shapes.get(type_index).unwrap()) ||
                verifier_physical_shape_may_drop(
                    solved.physical_shapes.get(type_index).unwrap())
            require_transition_count(semantic, 1, "MovePlace target")
            require_transition(
                semantic.get(0).unwrap(), target,
                if needs_cleanup { slot_reason_take_target() }
                else { slot_reason_assign_scalar() }, "MovePlace target")
            require_transition_count(after, 0, "MovePlace after")
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_demands, result_owned,
            argument_slots, result_slot, ..
        } => {
            let before_offset = match result_slot {
                some(slot) => verify_reusable_target_transition(
                    states, slot, before, "Call result"),
                none => 0
            }
            require_transition_count(
                before, before_offset + argument_slots.len(), "Call arguments")
            let mut index = 0
            while index < argument_slots.len() {
                let slot = argument_slots.get(index).unwrap()
                require_transition(
                    before.get(before_offset + index).unwrap(), slot,
                    demand_source_transition_reason(
                        body, solved, slot,
                        verifier_decided_transfer(
                            body, event, index).demand),
                    "Call argument")
                index = index + 1
            }
            match result_slot {
                some(slot) => {
                    require_transition_count(semantic, 1, "Call result")
                    require_transition(
                        semantic.get(0).unwrap(), slot,
                        slot_reason_call_result(), "Call result")
                    let effective_owned = event.decision.result_owned
                    let result_value = body.slots.get(slot).unwrap()
                    let result_logical = solved.logical_shapes.get(
                        result_value.type_index).unwrap()
                    let result_physical = solved.physical_shapes.get(
                        result_value.type_index).unwrap()
                    let owner = if effective_owned {
                        verifier_type_requires_cleanup(
                            result_logical, result_physical)
                    } else if result_value.owns_storage &&
                              verifier_physical_shape_may_drop(
                                  result_physical) {
                        if verifier_logical_shape_may_take(result_logical) {
                            panic("ResourcePlanner verifier: borrowed unique result enters owner")
                        }
                        true
                    } else { false }
                    require_transition_after_state(
                        semantic.get(0).unwrap(),
                        slot_flow_live_owner(owner), "Call result")
                    let needs_clone = !effective_owned &&
                        result_value.owns_storage &&
                        verifier_physical_shape_may_drop(
                            solved.physical_shapes.get(
                                result_value.type_index).unwrap())
                    require_transition_count(
                        after, if needs_clone { 1 } else { 0 },
                        "Call after")
                    if needs_clone {
                        require_transition(
                            after.get(0).unwrap(), slot,
                            slot_reason_clone_source(), "Call result clone")
                    }
                },
                none => {
                    require_transition_count(semantic, 0, "Call result")
                    require_transition_count(after, 0, "Call after")
                }
            }
        },
        PlannerEventValue::ProjectValue {
            source, target, value_type_index, partial, ..
        } => {
            let before_offset = verify_reusable_target_transition(
                states, target, before, "Project")
            let demand = verifier_decided_transfer(body, event, 0).demand
            let mode = transfer_demand_mode(demand)
            let needs_cleanup = verifier_logical_shape_may_take(
                    solved.logical_shapes.get(value_type_index).unwrap()) ||
                verifier_physical_shape_may_drop(
                    solved.physical_shapes.get(value_type_index).unwrap())
            if partial {
                let takes_place = param_mode_same(mode, param_mode_own()) &&
                    needs_cleanup
                let source_state = states.get(source).unwrap()
                if !slot_flow_is_live(source_state) {
                    panic("ResourcePlanner verifier: partial Project source is not live")
                }
                if takes_place && !slot_flow_cleanup_owner(source_state) {
                    panic("ResourcePlanner verifier: owning partial Project source is not owner")
                }
                if takes_place && !body.slots.get(target).unwrap().owns_storage {
                    panic("ResourcePlanner verifier: owning partial Project target is borrowed")
                }
                require_transition_count(
                    before, before_offset + 1, "partial Project source")
                if takes_place {
                    require_transition(
                        before.get(before_offset).unwrap(), source,
                        slot_reason_take_projected_source(),
                        "partial Project source")
                } else {
                    require_transition(
                        before.get(before_offset).unwrap(), source,
                        slot_reason_borrow(), "partial Project source")
                }
                require_transition_after_state(
                    before.get(before_offset).unwrap(), source_state,
                    "partial Project source")
            } else {
                if param_mode_same(mode, param_mode_own()) &&
                   verifier_logical_shape_may_take(
                        solved.logical_shapes.get(value_type_index).unwrap()) {
                    panic("ResourcePlanner verifier: owning field projection crossed diagnostics")
                }
                require_transition_count(
                    before, before_offset + 1, "Project source")
                require_transition(
                    before.get(before_offset).unwrap(), source,
                    slot_reason_borrow(), "Project source")
            }
            let needs_clone = !partial &&
                param_mode_same(mode, param_mode_own()) &&
                verifier_physical_shape_may_drop(
                    solved.physical_shapes.get(value_type_index).unwrap())
            if needs_clone && !body.slots.get(target).unwrap().owns_storage {
                panic("ResourcePlanner verifier: owning field projection targets borrowed storage")
            }
            require_transition_count(semantic, 1, "Project target")
            require_transition(
                semantic.get(0).unwrap(), target,
                if partial && param_mode_same(mode, param_mode_own()) &&
                        needs_cleanup { slot_reason_take_target() }
                else if partial { slot_reason_assign_scalar() }
                else if needs_clone { slot_reason_clone_target() }
                else { slot_reason_assign_scalar() },
                "Project target")
            if partial {
                require_transition_after_state(
                    semantic.get(0).unwrap(),
                    slot_flow_live_owner(
                        param_mode_same(mode, param_mode_own()) &&
                            needs_cleanup),
                    "partial Project target")
            }
            require_transition_count(
                after, if needs_clone { 1 } else { 0 }, "Project after")
            if needs_clone {
                require_transition(
                    after.get(0).unwrap(), target,
                    slot_reason_clone_source(), "Project result clone")
            }
        },
        PlannerEventValue::CaptureValue { source, target, demand } => {
            let exact_demand = verifier_decided_transfer(
                body, event, 0).demand
            let before_offset = verify_reusable_target_transition(
                states, target, before, "Capture")
            require_transition_count(
                before, before_offset + 1, "Capture source")
            require_transition(
                before.get(before_offset).unwrap(), source,
                demand_source_transition_reason(
                    body, solved, source, exact_demand),
                "Capture source")
            require_transition_count(semantic, 1, "Capture target")
            require_transition(
                semantic.get(0).unwrap(), target,
                transfer_target_transition_reason(
                    body, solved, source, target, exact_demand),
                "Capture target")
            require_transition_count(after, 0, "Capture after")
        }
    }
}

fn verify_terminator_transition_contract(
    body: PlannerBody, block: PlannerBlock,
    solved: SolvedResourceGraph,
    transitions: List<SlotTransitionWitness>
) {
    require_transition_count(
        transitions, block.terminator_uses.len(), "terminator")
    let mut index = 0
    while index < block.terminator_uses.len() {
        let usage = block.terminator_uses.get(index).unwrap()
        require_transition(
            transitions.get(index).unwrap(), usage.slot,
            demand_source_transition_reason(
                body, solved, usage.slot, usage.demand),
            "terminator")
        index = index + 1
    }
}

fn verify_edge_transition_contract(
    body: PlannerBody, edge: PlannerEdge,
    solved: SolvedResourceGraph, states: List<SlotFlow>,
    transitions: List<SlotTransitionWitness>
) {
    if transitions.len() < edge.fresh_result_slots.len() {
        panic("ResourcePlanner verifier: fresh edge result transition is absent")
    }
    let mut result_index = 0
    while result_index < edge.fresh_result_slots.len() {
        let result_slot = edge.fresh_result_slots.get(result_index).unwrap()
        let slot = body.slots.get(result_slot).unwrap()
        require_transition(
            transitions.get(result_index).unwrap(), result_slot,
            slot_reason_init_live(), "fresh edge result")
        require_transition_after_state(
            transitions.get(result_index).unwrap(),
            slot_flow_live_owner(
                slot.owns_storage && verifier_type_requires_cleanup(
                    solved.logical_shapes.get(slot.type_index).unwrap(),
                    solved.physical_shapes.get(slot.type_index).unwrap())),
            "fresh edge result")
        result_index = result_index + 1
    }
    let mut cleanup_transitions: List<SlotTransitionWitness> = []
    while result_index < transitions.len() {
        cleanup_transitions.push(transitions.get(result_index).unwrap())
        result_index = result_index + 1
    }
    verify_scope_transitions(
        body, solved, edge.exited_scope_ids,
        states, cleanup_transitions, "edge exit")
}

fn verify_operation_slots_exact(
    operation: RcOperation, expected_source: SlotRef,
    expected_target: SlotRef?
) {
    if !slot_ref_same(rc_operation_source(operation), expected_source) ||
       !slot_option_same(rc_operation_target(operation), expected_target) {
        panic("ResourcePlanner verifier: RC operation operand/target drifted")
    }
}

fn verify_reusable_target_drop_operation(
    body: PlannerBody, event: PlannerEvent, target: Int,
    solved: SolvedResourceGraph, states: List<SlotFlow>,
    before: List<RcOperation>, context: Str
) -> Int {
    let state = states.get(target).unwrap()
    if slot_flow_is_unreachable(state) || slot_flow_is_live(state) {
        panic("ResourcePlanner verifier: ${context} target is not reusable")
    }
    if !reusable_target_drop_required(state) { return 0 }
    let target_value = body.slots.get(target).unwrap()
    if !verifier_type_requires_cleanup(
            solved.logical_shapes.get(target_value.type_index).unwrap(),
            solved.physical_shapes.get(target_value.type_index).unwrap()) {
        panic("ResourcePlanner verifier: reusable target owner lacks cleanup shape")
    }
    let operation = before.get(0).unwrap_or_else(fn() {
        panic("ResourcePlanner verifier: ${context} target Drop is absent")
    })
    if rc_semantic_site_operand_ordinal(rc_operation_site(operation)) !=
            event.operands.len() ||
       !rc_op_kind_same(rc_operation_kind(operation), rc_op_kind_drop()) ||
       rc_operation_place_projection(operation).is_some() {
        panic("ResourcePlanner verifier: ${context} target Drop differs")
    }
    verify_operation_slots_exact(
        operation, body.slots.get(target).unwrap().reference, none)
    1
}

fn verify_event_operation_contract(
    body: PlannerBody, event: PlannerEvent, solved: SolvedResourceGraph,
    states: List<SlotFlow>,
    before: List<RcOperation>, after: List<RcOperation>
) {
    match event.value {
        PlannerEventValue::NoOpValue => {
            if before.len() != 0 || after.len() != 0 {
                panic("ResourcePlanner verifier: resource op attached to inert instruction")
            }
        },
        PlannerEventValue::ScopeExitValue(scope_id) => {
            if after.len() != 0 {
                panic("ResourcePlanner verifier: scope Cleanup is after marker")
            }
            for operation in before {
                let site = rc_operation_site(operation)
                let slot_index = rc_semantic_site_operand_ordinal(site)
                if slot_index < 0 || slot_index >= body.slots.len() ||
                   body.slots.get(slot_index).unwrap().scope_id != scope_id ||
                   !rc_op_kind_same(
                        rc_operation_kind(operation), rc_op_kind_cleanup()) {
                    panic("ResourcePlanner verifier: scope Cleanup operand drifted")
                }
                verify_operation_slots_exact(
                    operation, body.slots.get(slot_index).unwrap().reference, none)
            }
        },
        PlannerEventValue::InitializeValue { input_slots, target, .. } => {
            if after.len() != 0 {
                panic("ResourcePlanner verifier: Initialize has after-resource op")
            }
            let mut operation_index = verify_reusable_target_drop_operation(
                body, event, target, solved, states, before, "Initialize")
            while operation_index < before.len() {
                let operation = before.get(operation_index).unwrap()
                let operand = rc_semantic_site_operand_ordinal(
                    rc_operation_site(operation))
                if operand < 0 || operand >= input_slots.len() {
                    panic("ResourcePlanner verifier: Initialize operand ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation,
                    body.slots.get(input_slots.get(operand).unwrap()).unwrap().reference,
                    none)
                operation_index = operation_index + 1
            }
        },
        PlannerEventValue::ReadValue { source, target } => {
            if after.len() != 0 {
                panic("ResourcePlanner verifier: Read has after-resource op")
            }
            let mut operation_index = verify_reusable_target_drop_operation(
                body, event, target, solved, states, before, "Read")
            while operation_index < before.len() {
                let operation = before.get(operation_index).unwrap()
                if rc_semantic_site_operand_ordinal(
                        rc_operation_site(operation)) != 0 {
                    panic("ResourcePlanner verifier: Read operand ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation, body.slots.get(source).unwrap().reference,
                    some(body.slots.get(target).unwrap().reference))
                operation_index = operation_index + 1
            }
        },
        PlannerEventValue::MutateValue { value: input, .. } => {
            if after.len() != 0 {
                panic("ResourcePlanner verifier: Mutate has after-resource op")
            }
            for operation in before {
                if rc_semantic_site_operand_ordinal(
                        rc_operation_site(operation)) != 1 {
                    panic("ResourcePlanner verifier: Mutate value ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation, body.slots.get(input).unwrap().reference, none)
            }
        },
        PlannerEventValue::ConsumeValue(slot, _, target) => {
            if after.len() != 0 {
                panic("ResourcePlanner verifier: consume has after-resource op")
            }
            let mut operation_index = match target {
                some(value) => verify_reusable_target_drop_operation(
                    body, event, value, solved, states, before, "Consume sink"),
                none => 0
            }
            while operation_index < before.len() {
                let operation = before.get(operation_index).unwrap()
                if rc_semantic_site_operand_ordinal(
                        rc_operation_site(operation)) != 0 {
                    panic("ResourcePlanner verifier: consume ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation, body.slots.get(slot).unwrap().reference,
                    target.map(fn(value) {
                        body.slots.get(value).unwrap().reference
                    }))
                operation_index = operation_index + 1
            }
        },
        PlannerEventValue::DiscardValue(slot) => {
            if after.len() != 0 {
                panic("ResourcePlanner verifier: discard has after-resource op")
            }
            for operation in before {
                if rc_semantic_site_operand_ordinal(
                        rc_operation_site(operation)) != 0 {
                    panic("ResourcePlanner verifier: discard ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation, body.slots.get(slot).unwrap().reference, none)
            }
        },
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            if after.len() != 0 || before.len() == 0 {
                panic("ResourcePlanner verifier: Assign resource sequence is absent")
            }
            for operation in before {
                let operand = rc_semantic_site_operand_ordinal(
                    rc_operation_site(operation))
                if operand == 0 {
                    if !rc_op_kind_same(
                            rc_operation_kind(operation), rc_op_kind_take()) {
                        panic("ResourcePlanner verifier: Assign RHS is not Take")
                    }
                    verify_operation_slots_exact(
                        operation, body.slots.get(rhs_temp).unwrap().reference,
                        if planner_place_is_slot(target) {
                            some(body.slots.get(
                                planner_place_slot(target)).unwrap().reference)
                        } else { none })
                } else if operand == 1 {
                    if planner_place_is_slot(target) {
                        if !rc_op_kind_same(
                                rc_operation_kind(operation), rc_op_kind_drop()) ||
                           rc_operation_place_projection(operation).is_some() {
                            panic("ResourcePlanner verifier: slot Assign old value is not Drop")
                        }
                    } else {
                        if !rc_op_kind_same(
                                rc_operation_kind(operation),
                                rc_op_kind_drop_old_place()) {
                            panic("ResourcePlanner verifier: projected Assign lacks DropOldPlace")
                        }
                        let actual_projection = match
                                rc_operation_place_projection(operation) {
                            some(value) => value,
                            none => panic(
                                "ResourcePlanner verifier: DropOldPlace projection is absent")
                        }
                        if !flow_projection_contract_same(
                                actual_projection,
                                planner_place_projection(target)) {
                            panic("ResourcePlanner verifier: DropOldPlace projection drifted")
                        }
                    }
                    verify_operation_slots_exact(
                        operation,
                        body.slots.get(if planner_place_is_slot(target) {
                            planner_place_slot(target)
                        } else {
                            planner_place_base(target)
                        }).unwrap().reference,
                        none)
                } else {
                    panic("ResourcePlanner verifier: Assign operand ordinal drifted")
                }
            }
        },
        PlannerEventValue::MovePlaceValue { source, target } => {
            let operation_index = verify_reusable_target_drop_operation(
                body, event, target, solved, states, before, "MovePlace")
            if after.len() != 0 || before.len() != operation_index + 1 {
                panic("ResourcePlanner verifier: MovePlace Take is absent")
            }
            let operation = before.get(operation_index).unwrap()
            if rc_semantic_site_operand_ordinal(
                    rc_operation_site(operation)) != 0 ||
               !rc_op_kind_same(
                    rc_operation_kind(operation), rc_op_kind_take()) {
                panic("ResourcePlanner verifier: MovePlace operation differs")
            }
            let source_slot = if planner_place_is_slot(source) {
                planner_place_slot(source)
            } else { planner_place_base(source) }
            verify_operation_slots_exact(
                operation, body.slots.get(source_slot).unwrap().reference,
                some(body.slots.get(target).unwrap().reference))
            let actual_projection = rc_operation_place_projection(operation)
            if planner_place_is_slot(source) {
                if actual_projection.is_some() {
                    panic("ResourcePlanner verifier: slot MovePlace has projection")
                }
            } else {
                match actual_projection {
                    some(value) => if !flow_projection_contract_same(
                            value, planner_place_projection(source)) {
                        panic("ResourcePlanner verifier: MovePlace projection drifted")
                    },
                    none => panic("ResourcePlanner verifier: MovePlace projection absent")
                }
            }
        },
        PlannerEventValue::CallValue {
            argument_slots, result_slot, ..
        } => {
            let mut operation_index = match result_slot {
                some(slot) => verify_reusable_target_drop_operation(
                    body, event, slot, solved, states, before, "Call result"),
                none => 0
            }
            while operation_index < before.len() {
                let operation = before.get(operation_index).unwrap()
                let operand = rc_semantic_site_operand_ordinal(
                    rc_operation_site(operation))
                if operand < 0 || operand >= argument_slots.len() {
                    panic("ResourcePlanner verifier: call argument ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation,
                    body.slots.get(argument_slots.get(operand).unwrap()).unwrap().reference,
                    none)
                operation_index = operation_index + 1
            }
            for operation in after {
                if rc_semantic_site_operand_ordinal(
                        rc_operation_site(operation)) != argument_slots.len() {
                    panic("ResourcePlanner verifier: call result ordinal drifted")
                }
                let result = match result_slot {
                    some(index) => body.slots.get(index).unwrap().reference,
                    none => panic("ResourcePlanner verifier: call result op lacks result slot")
                }
                verify_operation_slots_exact(operation, result, none)
            }
        },
        PlannerEventValue::ProjectValue {
            source, target, projection, value_type_index, partial
        } => {
            let operation_index = verify_reusable_target_drop_operation(
                body, event, target, solved, states, before, "Project")
            if partial {
                if after.len() != 0 {
                    panic("ResourcePlanner verifier: partial Project has after-resource op")
                }
                let demand = verifier_decided_transfer(body, event, 0).demand
                let needs_take = param_mode_same(
                        transfer_demand_mode(demand), param_mode_own()) &&
                    (verifier_logical_shape_may_take(
                        solved.logical_shapes.get(value_type_index).unwrap()) ||
                     verifier_physical_shape_may_drop(
                        solved.physical_shapes.get(value_type_index).unwrap()))
                let take_count = if needs_take { 1 } else { 0 }
                if before.len() != operation_index + take_count {
                    panic("ResourcePlanner verifier: partial Project Take census drifted")
                }
                if needs_take {
                    let operation = before.get(operation_index).unwrap()
                    if rc_semantic_site_operand_ordinal(
                            rc_operation_site(operation)) != 0 ||
                       !rc_op_kind_same(
                            rc_operation_kind(operation), rc_op_kind_take()) {
                        panic("ResourcePlanner verifier: partial Project operation drifted")
                    }
                    verify_operation_slots_exact(
                        operation, body.slots.get(source).unwrap().reference,
                        some(body.slots.get(target).unwrap().reference))
                    match rc_operation_place_projection(operation) {
                        some(value) => if !flow_projection_contract_same(
                                value, projection) {
                            panic("ResourcePlanner verifier: projected Take identity drifted")
                        },
                        none => panic("ResourcePlanner verifier: projected Take is untyped")
                    }
                }
            } else {
                if before.len() != operation_index {
                    panic("ResourcePlanner verifier: ordinary Project touches aggregate base")
                }
                let demand = verifier_decided_transfer(body, event, 0).demand
                let needs_clone = param_mode_same(
                        transfer_demand_mode(demand), param_mode_own()) &&
                    verifier_physical_shape_may_drop(
                        solved.physical_shapes.get(value_type_index).unwrap())
                if after.len() != if needs_clone { 1 } else { 0 } {
                    panic("ResourcePlanner verifier: Project result Clone census drifted")
                }
                if needs_clone {
                    let operation = after.get(0).unwrap()
                    if rc_semantic_site_operand_ordinal(
                            rc_operation_site(operation)) != 0 ||
                       !rc_op_kind_same(
                            rc_operation_kind(operation), rc_op_kind_clone()) ||
                       rc_operation_place_projection(operation).is_some() {
                        panic("ResourcePlanner verifier: Project result Clone drifted")
                    }
                    verify_operation_slots_exact(
                        operation, body.slots.get(target).unwrap().reference,
                        none)
                }
            }
        },
        PlannerEventValue::CaptureValue { source, target, .. } => {
            if after.len() != 0 {
                panic("ResourcePlanner verifier: projection/capture has after-resource op")
            }
            let mut operation_index = verify_reusable_target_drop_operation(
                body, event, target, solved, states, before, "Capture")
            while operation_index < before.len() {
                let operation = before.get(operation_index).unwrap()
                if rc_semantic_site_operand_ordinal(
                        rc_operation_site(operation)) != 0 {
                    panic("ResourcePlanner verifier: projection/capture ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation, body.slots.get(source).unwrap().reference,
                    some(body.slots.get(target).unwrap().reference))
                operation_index = operation_index + 1
            }
        }
    }
}

fn verify_terminator_operation_contract(
    body: PlannerBody, block: PlannerBlock,
    operations: List<RcOperation>
) {
    for operation in operations {
        let operand = rc_semantic_site_operand_ordinal(
            rc_operation_site(operation))
        if operand < 0 || operand >= block.terminator_uses.len() {
            panic("ResourcePlanner verifier: terminator operand ordinal drifted")
        }
        verify_operation_slots_exact(
            operation,
            body.slots.get(
                block.terminator_uses.get(operand).unwrap().slot).unwrap().reference,
            none)
    }
}

fn verify_edge_operation_contract(
    body: PlannerBody, edge: PlannerEdge,
    operations: List<RcOperation>
) {
    for operation in operations {
        let slot_index = rc_semantic_site_operand_ordinal(
            rc_operation_site(operation))
        if slot_index < 0 || slot_index >= body.slots.len() ||
           !int_list_contains(
                edge.exited_scope_ids,
                body.slots.get(slot_index).unwrap().scope_id) ||
           !rc_op_kind_same(
                rc_operation_kind(operation), rc_op_kind_cleanup()) {
            panic("ResourcePlanner verifier: edge Cleanup operand drifted")
        }
        verify_operation_slots_exact(
            operation, body.slots.get(slot_index).unwrap().reference, none)
    }
}

fn verifier_cfg_state_rank(value: SlotFlow) -> Int {
    if slot_flow_is_unreachable(value) { return 0 }
    if slot_flow_is_maybe_moved(value) { return 2 }
    1
}

fn copy_verifier_slot_states(
    values: List<SlotFlow>
) -> List<SlotFlow> {
    let mut result: List<SlotFlow> = []
    for value in values { result.push(value) }
    result
}

fn verify_cfg_entry_derivation_exit(
    body: PlannerBody, solved: SolvedResourceGraph,
    derivation: CfgEntryEdgeDerivation,
    source_states: List<SlotFlow>
) -> List<SlotFlow> {
    // Reuse the ordinary event/terminator/edge contracts for one claimed
    // source revision; this is not a worklist or a second fixed-point solve.
    let source = cfg_entry_derivation_predecessor_block(derivation)
    let edge_index = cfg_entry_derivation_predecessor_edge(derivation)
    if source < 0 || source >= body.blocks.len() || edge_index < 0 ||
       edge_index >= body.blocks.get(source).unwrap().edges.len() ||
       source_states.len() != body.slots.len() {
        panic("ResourcePlanner verifier: CFG entry derivation is absent")
    }
    let block = body.blocks.get(source).unwrap()
    let steps = cfg_entry_derivation_steps(derivation)
    if steps.len() != block.events.len() {
        panic("ResourcePlanner verifier: CFG entry derivation step census differs")
    }
    let mut current = copy_verifier_slot_states(source_states)
    let mut step_index = 0
    while step_index < steps.len() {
        let event = block.events.get(step_index).unwrap()
        let step = steps.get(step_index).unwrap()
        let exact_instruction = make_flow_instruction_ref(
            body.reference, source, step_index)
        if !flow_semantic_step_is_instruction(event.step) ||
           !flow_instruction_ref_same(
                flow_semantic_step_instruction(event.step),
                exact_instruction) ||
           !flow_instruction_ref_same(
                cfg_step_certificate_instruction(step),
                exact_instruction) {
            panic("ResourcePlanner verifier: CFG entry derivation step differs")
        }
        let before = cfg_step_certificate_before(step)
        let semantic = cfg_step_certificate_semantic(step)
        let after = cfg_step_certificate_after(step)
        verify_event_transition_contract(
            body, event, solved, current, before, semantic, after)
        apply_topology_transitions(current, before)
        apply_topology_transitions(current, semantic)
        apply_topology_transitions(current, after)
        step_index = step_index + 1
    }
    let terminator = cfg_entry_derivation_terminator_transitions(
        derivation)
    verify_terminator_transition_contract(
        body, block, solved, terminator)
    apply_topology_transitions(current, terminator)
    let edge = block.edges.get(edge_index).unwrap()
    let edge_transitions = cfg_entry_derivation_edge_transitions(
        derivation)
    verify_edge_transition_contract(
        body, edge, solved, current, edge_transitions)
    apply_topology_transitions(current, edge_transitions)
    current
}

fn verify_cfg_entry_promotion_log(
    body: PlannerBody, solved: SolvedResourceGraph,
    entry_seed: List<SlotFlow>,
    cfg_body: CfgBodyCertificate,
    blocks: List<CfgBlockCertificate>
) {
    let promotions = cfg_body_certificate_entry_promotions(cfg_body)
    let derivations = cfg_body_certificate_entry_derivations(cfg_body)
    let mut reachable: List<Bool> = []
    let mut states: List<List<SlotFlow>> = []
    let mut versions: List<Int> = []
    for _ in body.blocks {
        reachable.push(false)
        versions.push(0)
        let mut bottom: List<SlotFlow> = []
        for _ in body.slots { bottom.push(slot_flow_unreachable()) }
        states.push(bottom)
    }
    let rank_budget = body.blocks.len() * (body.slots.len() * 2 + 1)
    let mut rank_total = 0
    let mut order = 0
    let mut update_id = 0
    while order < promotions.len() {
        let first = promotions.get(order).unwrap()
        if cfg_entry_promotion_order(first) != order ||
           cfg_entry_promotion_update_id(first) != update_id {
            panic("ResourcePlanner verifier: CFG promotion order is not dense")
        }
        let target = cfg_entry_promotion_target_block(first)
        if target < 0 || target >= body.blocks.len() {
            panic("ResourcePlanner verifier: CFG promotion target is absent")
        }
        let incoming = if update_id == 0 {
            if target != body.entry_block ||
               cfg_entry_promotion_predecessor_block(first).is_some() ||
               cfg_entry_promotion_predecessor_edge(first).is_some() ||
               cfg_entry_promotion_predecessor_version(first).is_some() ||
               cfg_entry_promotion_derivation_index(first).is_some() {
                panic("ResourcePlanner verifier: CFG entry seed update differs")
            }
            entry_seed
        } else {
            let source = cfg_entry_promotion_predecessor_block(
                first).unwrap()
            let edge = cfg_entry_promotion_predecessor_edge(first).unwrap()
            let version = cfg_entry_promotion_predecessor_version(
                first).unwrap()
            let derivation_index = cfg_entry_promotion_derivation_index(
                first).unwrap()
            if source < 0 || source >= body.blocks.len() || edge < 0 ||
               edge >= body.blocks.get(source).unwrap().edges.len() ||
               !reachable.get(source).unwrap() ||
               versions.get(source).unwrap() != version ||
               derivation_index != update_id - 1 ||
               derivation_index >= derivations.len() ||
               body.blocks.get(source).unwrap().edges.get(
                    edge).unwrap().target_block != some(target) {
                panic("ResourcePlanner verifier: CFG predecessor version differs")
            }
            let derivation = derivations.get(derivation_index).unwrap()
            if cfg_entry_derivation_predecessor_block(derivation) != source ||
               cfg_entry_derivation_predecessor_edge(derivation) != edge ||
               cfg_entry_derivation_predecessor_version(derivation) !=
                    version {
                panic("ResourcePlanner verifier: CFG predecessor derivation differs")
            }
            verify_cfg_entry_derivation_exit(
                body, solved, derivation, states.get(source).unwrap())
        }
        let mut saw_reach = false
        while order < promotions.len() &&
              cfg_entry_promotion_update_id(
                promotions.get(order).unwrap()) == update_id {
            let promotion = promotions.get(order).unwrap()
            if cfg_entry_promotion_order(promotion) != order ||
               cfg_entry_promotion_target_block(promotion) != target ||
               cfg_entry_promotion_predecessor_block(promotion) !=
                    cfg_entry_promotion_predecessor_block(first) ||
               cfg_entry_promotion_predecessor_edge(promotion) !=
                    cfg_entry_promotion_predecessor_edge(first) ||
               cfg_entry_promotion_predecessor_version(promotion) !=
                    cfg_entry_promotion_predecessor_version(first) ||
               cfg_entry_promotion_derivation_index(promotion) !=
                    cfg_entry_promotion_derivation_index(first) {
                panic("ResourcePlanner verifier: CFG promotion update differs")
            }
            match cfg_entry_promotion_slot(promotion) {
                none => {
                    if saw_reach || reachable.get(target).unwrap() ||
                       cfg_entry_promotion_before(promotion).is_some() ||
                       cfg_entry_promotion_after(promotion).is_some() ||
                       cfg_entry_promotion_from_rank(promotion) != 0 ||
                       cfg_entry_promotion_to_rank(promotion) != 1 {
                        panic("ResourcePlanner verifier: CFG reach promotion repeats")
                    }
                    reachable.set(target, true)
                    saw_reach = true
                },
                some(slot) => {
                    if slot < 0 || slot >= body.slots.len() ||
                       !reachable.get(target).unwrap() {
                        panic("ResourcePlanner verifier: CFG slot promotion is invalid")
                    }
                    let before = states.get(target).unwrap().get(slot).unwrap()
                    let joined = slot_flow_join(
                        before, incoming.get(slot).unwrap())
                    let claimed_before = cfg_entry_promotion_before(
                        promotion).unwrap()
                    let claimed_after = cfg_entry_promotion_after(
                        promotion).unwrap()
                    if !slot_flow_same(before, claimed_before) ||
                       slot_flow_same(before, joined) ||
                       !slot_flow_same(joined, claimed_after) ||
                       cfg_entry_promotion_from_rank(promotion) !=
                            verifier_cfg_state_rank(before) ||
                       cfg_entry_promotion_to_rank(promotion) !=
                            verifier_cfg_state_rank(joined) ||
                       cfg_entry_promotion_to_rank(promotion) <=
                            cfg_entry_promotion_from_rank(promotion) {
                        panic("ResourcePlanner verifier: CFG slot promotion is not exact")
                    }
                    let mut target_states = states.get(target).unwrap()
                    target_states.set(slot, joined)
                    states.set(target, target_states)
                }
            }
            rank_total = rank_total + (
                cfg_entry_promotion_to_rank(promotion) -
                cfg_entry_promotion_from_rank(promotion))
            if rank_total > rank_budget {
                panic("ResourcePlanner verifier: CFG promotion rank budget exceeded")
            }
            order = order + 1
        }
        versions.set(target, versions.get(target).unwrap() + 1)
        update_id = update_id + 1
    }
    if update_id != derivations.len() + 1 {
        panic("ResourcePlanner verifier: CFG entry derivation census differs")
    }
    let mut block = 0
    while block < body.blocks.len() {
        let claimed = cfg_block_certificate_entry_states(
            blocks.get(block).unwrap())
        if claimed.len() != body.slots.len() {
            panic("ResourcePlanner verifier: CFG replay state census differs")
        }
        let mut slot = 0
        while slot < body.slots.len() {
            if !slot_flow_same(
                    states.get(block).unwrap().get(slot).unwrap(),
                    claimed.get(slot).unwrap()) {
                panic("ResourcePlanner verifier: CFG promotion log is incomplete")
            }
            slot = slot + 1
        }
        block = block + 1
    }
    if !reachable.get(body.entry_block).unwrap() {
        panic("ResourcePlanner verifier: CFG entry reach promotion is absent")
    }
    block = 0
    while block < body.blocks.len() {
        if reachable.get(block).unwrap() {
            for edge in body.blocks.get(block).unwrap().edges {
                match edge.target_block {
                    some(target) => if !reachable.get(target).unwrap() {
                        panic("ResourcePlanner verifier: CFG reach promotion log is incomplete")
                    },
                    none => {}
                }
            }
        }
        block = block + 1
    }
}

pub fn verify_rc_topology_contract(
    input: FrozenPlannerInput, solved: SolvedResourceGraph,
    rc_program: RcProgram,
    certificate: ResourceCertificate
) {
    if rc_program_flow_fingerprint(rc_program) != input.flow_fingerprint ||
       rc_program_type_count(rc_program) != input.type_nodes.len() ||
       rc_program_callable_count(rc_program) != input.callables.len() {
        panic("ResourcePlanner verifier: RcIR frozen graph census drifted")
    }
    let rc_bodies = rc_program_bodies(rc_program)
    let cfg_bodies = resource_certificate_cfg_bodies(certificate)
    let expected_bodies = solved.bodies
    if expected_bodies.len() != input.bodies.len() ||
       rc_bodies.len() != expected_bodies.len() ||
       cfg_bodies.len() != expected_bodies.len() {
        panic("ResourcePlanner verifier: executable body census drifted")
    }
    let mut body_index = 0
    while body_index < expected_bodies.len() {
        let expected_body = expected_bodies.get(body_index).unwrap()
        let rc_body = rc_bodies.get(body_index).unwrap()
        let cfg_body = cfg_bodies.get(body_index).unwrap()
        if !executable_ref_same(
                expected_body.reference, rc_body_reference(rc_body)) ||
           expected_body.entry_block != rc_body_entry_block(rc_body) ||
           expected_body.entry_block !=
                cfg_body_certificate_entry_block(cfg_body) {
            panic("ResourcePlanner verifier: body identity/entry drifted")
        }
        let body_callable_index = flow_callable_index_for_planner(
            input.callables, expected_body.reference)
        let certified_entry_seed = cfg_body_certificate_entry_seed(cfg_body)
        if certified_entry_seed.len() != expected_body.slots.len() {
            panic("ResourcePlanner verifier: entry seed census drifted")
        }
        let mut entry_slot = 0
        while entry_slot < expected_body.slots.len() {
            let slot = expected_body.slots.get(entry_slot).unwrap()
            let expected_state = if slot.initially_live {
                let owner = match slot.parameter_ordinal {
                    some(parameter) => {
                        let demands = solved.callable_demands.get(
                            body_callable_index).unwrap()
                        if parameter < 0 || parameter >= demands.len() {
                            panic("ResourcePlanner verifier: entry parameter demand is absent")
                        }
                        param_mode_same(
                            transfer_demand_mode(
                                demands.get(parameter).unwrap()),
                            param_mode_own()) &&
                            verifier_type_requires_cleanup(
                                solved.logical_shapes.get(
                                    slot.type_index).unwrap(),
                                solved.physical_shapes.get(
                                    slot.type_index).unwrap())
                    },
                    none => false
                }
                slot_flow_live_owner(owner)
            } else { slot_flow_empty() }
            if !slot_flow_same(
                    certified_entry_seed.get(entry_slot).unwrap(),
                    expected_state) {
                panic("ResourcePlanner verifier: entry seed/owner drifted")
            }
            entry_slot = entry_slot + 1
        }
        let rc_slots = rc_body_slots(rc_body)
        if rc_slots.len() != expected_body.slots.len() {
            panic("ResourcePlanner verifier: frozen binder census drifted")
        }
        let mut slot_index = 0
        while slot_index < expected_body.slots.len() {
            let expected_slot = expected_body.slots.get(slot_index).unwrap()
            let rc_slot = rc_slots.get(slot_index).unwrap()
            if !slot_ref_same(
                    expected_slot.reference, rc_slot_reference(rc_slot)) ||
               expected_slot.type_index != rc_slot_type_index(rc_slot) ||
               expected_slot.scope_id != rc_slot_scope_id(rc_slot) ||
               expected_slot.scope_depth != rc_slot_scope_depth(rc_slot) ||
               expected_slot.reverse_lexical_ordinal !=
                    rc_slot_reverse_lexical_ordinal(rc_slot) {
                panic("ResourcePlanner verifier: frozen binder metadata drifted")
            }
            slot_index = slot_index + 1
        }
        let rc_blocks = rc_body_blocks(rc_body)
        let cfg_blocks = cfg_body_certificate_blocks(cfg_body)
        if rc_blocks.len() != expected_body.blocks.len() ||
           cfg_blocks.len() != expected_body.blocks.len() {
            panic("ResourcePlanner verifier: frozen block census drifted")
        }
        verify_cfg_entry_promotion_log(
            expected_body, solved,
            certified_entry_seed, cfg_body, cfg_blocks)
        let mut block_index = 0
        while block_index < expected_body.blocks.len() {
            let expected_block = expected_body.blocks.get(block_index).unwrap()
            let rc_block = rc_blocks.get(block_index).unwrap()
            let cfg_block = cfg_blocks.get(block_index).unwrap()
            let exact_block = make_flow_block_ref(
                expected_body.reference, block_index)
            if rc_block_source_index(rc_block) != block_index ||
               !flow_block_ref_same(
                    rc_block_source_ref(rc_block), exact_block) ||
               rc_block_terminator_kind(rc_block) !=
                    expected_block.terminator_kind ||
               rc_block_semantic_op_count(rc_block) !=
                    expected_block.events.len() ||
               cfg_block_certificate_index(cfg_block) != block_index ||
               !flow_block_ref_same(
                    cfg_block_certificate_source_block(cfg_block), exact_block) ||
               cfg_block_certificate_terminator_kind(cfg_block) !=
                    expected_block.terminator_kind {
                panic("ResourcePlanner verifier: block/terminator topology drifted")
            }
            let rc_steps = rc_block_steps(rc_block)
            let cfg_steps = cfg_block_certificate_steps(cfg_block)
            if rc_steps.len() != expected_block.events.len() ||
               cfg_steps.len() != expected_block.events.len() {
                panic("ResourcePlanner verifier: semantic step census drifted")
            }
            let mut topology_states =
                cfg_block_certificate_entry_states(cfg_block)
            let block_unreachable =
                topology_state_is_unreachable(topology_states)
            let mut step_index = 0
            while step_index < rc_steps.len() {
                let rc_step = rc_steps.get(step_index).unwrap()
                let cfg_step = cfg_steps.get(step_index).unwrap()
                let exact_instruction = make_flow_instruction_ref(
                    expected_body.reference, block_index, step_index)
                let expected_event = expected_block.events.get(
                    step_index).unwrap()
                if !flow_semantic_step_is_instruction(expected_event.step) ||
                   !flow_instruction_ref_same(
                        flow_semantic_step_instruction(expected_event.step),
                        exact_instruction) ||
                   rc_step_semantic_op_index(
                        rc_step) != step_index ||
                   !flow_instruction_ref_same(
                        rc_step_instruction(rc_step),
                        exact_instruction) ||
                   !flow_instruction_ref_same(
                        cfg_step_certificate_instruction(
                            cfg_step),
                        exact_instruction) {
                    panic("ResourcePlanner verifier: instruction identity drifted")
                }
                let before_transitions =
                    cfg_step_certificate_before(cfg_step)
                let semantic_transitions =
                    cfg_step_certificate_semantic(cfg_step)
                let after_transitions =
                    cfg_step_certificate_after(cfg_step)
                if block_unreachable {
                    require_transition_count(
                        before_transitions, 0, "unreachable instruction before")
                    require_transition_count(
                        semantic_transitions, 0,
                        "unreachable instruction semantic")
                    require_transition_count(
                        after_transitions, 0, "unreachable instruction after")
                    if rc_step_before(rc_step).len() != 0 ||
                       rc_step_after(rc_step).len() != 0 {
                        panic("ResourcePlanner verifier: unreachable instruction has resource ops")
                    }
                } else {
                    verify_event_transition_contract(
                        expected_body,
                        expected_event,
                        solved, topology_states,
                        before_transitions, semantic_transitions,
                        after_transitions)
                    verify_event_operation_contract(
                        expected_body,
                        expected_event,
                        solved,
                        topology_states,
                        rc_step_before(rc_step), rc_step_after(rc_step))
                    apply_topology_transitions(
                        topology_states, before_transitions)
                    apply_topology_transitions(
                        topology_states, semantic_transitions)
                    apply_topology_transitions(
                        topology_states, after_transitions)
                }
                step_index = step_index + 1
            }
            let terminator_transitions =
                cfg_block_certificate_terminator_transitions(cfg_block)
            let mut terminator_ordinal = 0
            for usage in expected_block.terminator_uses {
                if flow_semantic_step_is_instruction(usage.step) ||
                   !flow_block_ref_same(
                        flow_semantic_step_terminator(usage.step), exact_block) ||
                   usage.operand_ordinal != terminator_ordinal ||
                   !slot_ref_same(
                        usage.reference,
                        expected_body.slots.get(
                            usage.slot).unwrap().reference) {
                    panic("ResourcePlanner verifier: exact terminator use drifted")
                }
                terminator_ordinal = terminator_ordinal + 1
            }
            if block_unreachable {
                require_transition_count(
                    terminator_transitions, 0, "unreachable terminator")
                if rc_block_before_terminator(rc_block).len() != 0 {
                    panic("ResourcePlanner verifier: unreachable terminator has resource ops")
                }
            } else {
                verify_terminator_transition_contract(
                    expected_body, expected_block, solved,
                    terminator_transitions)
                verify_terminator_operation_contract(
                    expected_body, expected_block,
                    rc_block_before_terminator(rc_block))
                apply_topology_transitions(
                    topology_states, terminator_transitions)
            }
            let rc_edges = rc_block_edges(rc_block)
            let cfg_edges = cfg_block_certificate_edges(cfg_block)
            if rc_edges.len() != expected_block.edges.len() ||
               cfg_edges.len() != expected_block.edges.len() {
                panic("ResourcePlanner verifier: successor census drifted")
            }
            let mut edge_index = 0
            while edge_index < expected_block.edges.len() {
                let expected_edge = expected_block.edges.get(edge_index).unwrap()
                let rc_edge = rc_edges.get(edge_index).unwrap()
                let cfg_edge = cfg_edges.get(edge_index).unwrap()
                if rc_edge_successor_ordinal(rc_edge) != edge_index ||
                   cfg_edge_certificate_successor_ordinal(cfg_edge) != edge_index ||
                   rc_edge_target_block(rc_edge) != expected_edge.target_block ||
                   cfg_edge_certificate_target(cfg_edge) !=
                        expected_edge.target_block {
                    panic("ResourcePlanner verifier: successor endpoint drifted")
                }
                if expected_edge.fresh_result_slots.len() != 0 {
                    panic("ResourcePlanner verifier: edge result census drifted")
                }
                let edge_transitions =
                    cfg_edge_certificate_transitions(cfg_edge)
                if block_unreachable {
                    require_transition_count(
                        edge_transitions, 0, "unreachable edge")
                    if rc_edge_cleanup(rc_edge).len() != 0 {
                        panic("ResourcePlanner verifier: unreachable edge has resource ops")
                    }
                } else {
                    verify_edge_transition_contract(
                        expected_body, expected_edge, solved,
                        topology_states, edge_transitions)
                    verify_edge_operation_contract(
                        expected_body, expected_edge,
                        rc_edge_cleanup(rc_edge))
                }
                edge_index = edge_index + 1
            }
            block_index = block_index + 1
        }
        body_index = body_index + 1
    }
}
