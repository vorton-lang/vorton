// Callable candidate provenance graph construction, ranked solve, and body cutover.
// Extracted mechanically from resource_planner; rule sites, candidate cells,
// promotion ordering, selections, and resolved event bindings are unchanged.

use flow_ir::{make_flow_instruction_ref, make_flow_block_ref}
use resource_certificate::{
    CandidateCellKind, CandidateCellSpec, CandidateRuleSite,
    CandidateRuleKind, CandidateRule, CandidatePromotion,
    CandidateSelection, CallableCandidateProof,
    make_candidate_cell_spec, make_global_candidate_rule_site,
    make_instruction_candidate_rule_site,
    make_terminator_candidate_rule_site, make_edge_candidate_rule_site,
    make_candidate_rule, make_candidate_promotion,
    make_candidate_selection, make_callable_candidate_proof,
    candidate_cell_parameter, candidate_cell_result, candidate_cell_state,
    candidate_rule_seed, candidate_rule_copy, candidate_rule_all,
    callable_candidate_proof_callable_count,
    callable_candidate_proof_cells, callable_candidate_proof_rules,
    callable_candidate_proof_promotions,
    callable_candidate_proof_final_values,
    candidate_cell_spec_kind, candidate_cell_spec_owner,
    candidate_cell_spec_block, candidate_cell_spec_boundary,
    candidate_cell_spec_component, candidate_cell_spec_candidate,
    candidate_cell_kind_tag, candidate_rule_kind,
    candidate_rule_target_cell, candidate_rule_premise_cells,
    candidate_rule_kind_tag}
use resource_type_lfp::{
    PlannerTypeNode, PlannerCallable, PlannerBody, PlannerBlock,
    PlannerEvent, PlannerEventValue, PlannerCallableOriginValue,
    PlannerCallableLocation,
    planner_type_is_callable, planner_place_is_slot, planner_place_slot,
    planner_call_target_is_direct, planner_call_target_direct,
    planner_call_target_slot, make_planner_callable_slot_location,
    planner_callable_location_is_slot, planner_callable_location_slot,
    planner_callable_location_base, planner_callable_location_same,
    copy_planner_callable_location, with_planner_callable_provenance,
    with_planner_event_decision, make_planner_call,
    copy_planner_event, make_planner_block,
    make_planner_body, int_list_contains,
    flow_callable_index_for_planner}

// ============================================================
// Planner-owned callable-slot candidate fixed point
// ============================================================

fn empty_candidate_set(callable_count: Int) -> List<Bool> {
    let mut result: List<Bool> = []
    let mut index = 0
    while index < callable_count {
        result.push(false)
        index = index + 1
    }
    result
}

fn candidate_set_indices(values: List<Bool>) -> List<Int> {
    let mut result: List<Int> = []
    let mut index = 0
    while index < values.len() {
        if values.get(index).unwrap() { result.push(index) }
        index = index + 1
    }
    result
}

fn replace_call_candidates(
    event: PlannerEvent, candidates: List<Int>
) -> PlannerEvent {
    match event.value {
        PlannerEventValue::CallValue {
            call_target, argument_demands, result_owned,
            result_type_index, result_origin_argument_ordinals,
            argument_slots, result_slot, ..
        } => with_planner_event_decision(
            with_planner_callable_provenance(make_planner_call(
                event.step, event.operands,
                call_target, candidates, argument_slots, argument_demands,
                result_owned, result_type_index,
                result_origin_argument_ordinals, result_slot),
                event.callable_provenance),
            event.decision),
        _ => copy_planner_event(event)
    }
}

pub struct CandidateProofGraph {
    callable_count: Int,
    cells: List<CandidateCellSpec>,
    rules: List<CandidateRule>
}

fn candidate_cell_index(
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

fn add_candidate_rule(
    mut rules: List<CandidateRule>, kind: CandidateRuleKind,
    site: CandidateRuleSite, target: Int, premises: List<Int>
) {
    rules.push(make_candidate_rule(kind, site, target, premises))
}

fn add_candidate_conjunction_rule(
    mut rules: List<CandidateRule>, site: CandidateRuleSite,
    target: Int, left: Int, right: Int
) {
    if left == right {
        add_candidate_rule(
            rules, candidate_rule_copy(), site, target, [left])
    } else {
        add_candidate_rule(
            rules, candidate_rule_all(), site, target, [left, right])
    }
}

fn append_callable_location(
    mut values: List<PlannerCallableLocation>,
    value: PlannerCallableLocation
) {
    if !values.any(fn(existing) {
            planner_callable_location_same(existing, value)
        }) {
        values.push(copy_planner_callable_location(value))
    }
}

fn body_callable_locations(
    body: PlannerBody, type_nodes: List<PlannerTypeNode>
) -> List<PlannerCallableLocation> {
    let mut result: List<PlannerCallableLocation> = []
    let mut slot = 0
    while slot < body.slots.len() {
        if planner_type_is_callable(
                type_nodes, body.slots.get(slot).unwrap().type_index) {
            append_callable_location(
                result, make_planner_callable_slot_location(slot))
        }
        slot = slot + 1
    }
    for block in body.blocks {
        for event in block.events {
            for fact in event.callable_provenance {
                append_callable_location(result, fact.target)
                match fact.origin {
                    PlannerCallableOriginValue::LocationCallableOriginValue(
                        sources) => {
                            for source in sources {
                                append_callable_location(result, source)
                            }
                        },
                    _ => {}
                }
            }
        }
    }
    result
}

fn callable_location_index(
    body: PlannerBody, type_nodes: List<PlannerTypeNode>,
    target: PlannerCallableLocation
) -> Int {
    let locations = body_callable_locations(body, type_nodes)
    let mut index = 0
    while index < locations.len() {
        if planner_callable_location_same(
                locations.get(index).unwrap(), target) { return index }
        index = index + 1
    }
    panic("ResourcePlanner: callable location is not registered")
}

fn event_candidate_location_overwritten(
    event: PlannerEvent, body: PlannerBody,
    location: PlannerCallableLocation
) -> Bool {
    for fact in event.callable_provenance {
        if planner_callable_location_same(fact.target, location) { return true }
    }
    let base_slot = if planner_callable_location_is_slot(location) {
        planner_callable_location_slot(location)
    } else {
        planner_callable_location_base(location)
    }
    match event.value {
        PlannerEventValue::ConsumeValue(target, _, _) => target == base_slot,
        PlannerEventValue::DiscardValue(target) => target == base_slot,
        PlannerEventValue::ScopeExitValue(scope_id) =>
            body.slots.get(base_slot).unwrap().scope_id == scope_id,
        PlannerEventValue::AssignValue { rhs_temp, target } =>
            rhs_temp == base_slot ||
            (planner_place_is_slot(target) &&
             planner_place_slot(target) == base_slot),
        _ => false
    }
}

fn add_candidate_provenance_rules(
    graph: CandidateProofGraph, body_index: Int, block_index: Int,
    boundary: Int, event: PlannerEvent,
    type_nodes: List<PlannerTypeNode>,
    callables: List<PlannerCallable>, bodies: List<PlannerBody>
) {
    let body = bodies.get(body_index).unwrap()
    let site = make_instruction_candidate_rule_site(
        make_flow_instruction_ref(
            bodies.get(body_index).unwrap().reference,
            block_index, boundary))
    for fact in event.callable_provenance {
        let mut candidate = 0
        while candidate < graph.callable_count {
            let target = candidate_cell_index(
                graph.cells, candidate_cell_state(), body_index,
                block_index, boundary + 1,
                callable_location_index(body, type_nodes, fact.target),
                candidate)
            match fact.origin {
                PlannerCallableOriginValue::DirectCallableOriginValue(direct) =>
                    if direct == candidate {
                        add_candidate_rule(
                            graph.rules, candidate_rule_seed(), site,
                            target, [])
                    },
                PlannerCallableOriginValue::LocationCallableOriginValue(sources) =>
                    { for source in sources {
                        add_candidate_rule(
                            graph.rules, candidate_rule_copy(), site, target,
                            [candidate_cell_index(
                                graph.cells, candidate_cell_state(), body_index,
                                block_index, boundary,
                                callable_location_index(
                                    body, type_nodes, source), candidate)])
                    } },
                PlannerCallableOriginValue::CallCallableOriginValue {
                    target: call_target, arguments: _
                } => {
                    let mut callee = 0
                    while callee < graph.callable_count {
                        if !planner_type_is_callable(
                                type_nodes, callables.get(
                                    callee).unwrap().result_type_index) {
                            callee = callee + 1
                            continue
                        }
                        let result_cell = candidate_cell_index(
                            graph.cells, candidate_cell_result(), callee,
                            0, 0, 0, candidate)
                        if planner_call_target_is_direct(call_target) {
                            if planner_call_target_direct(call_target) == callee {
                                add_candidate_rule(
                                    graph.rules, candidate_rule_copy(), site,
                                    target, [result_cell])
                            }
                        } else {
                            add_candidate_conjunction_rule(
                                graph.rules, site, target,
                                candidate_cell_index(
                                    graph.cells, candidate_cell_state(),
                                    body_index, block_index, boundary,
                                    callable_location_index(
                                        body, type_nodes,
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
                    if !planner_type_is_callable(
                            type_nodes,
                            body.slots.get(argument_slot).unwrap().type_index) {
                        panic("ResourcePlanner: callable result aliases non-callable argument")
                    }
                    add_candidate_rule(
                        graph.rules, candidate_rule_copy(), site, target,
                        [candidate_cell_index(
                            graph.cells, candidate_cell_state(), body_index,
                            block_index, boundary,
                            callable_location_index(
                                body, type_nodes,
                                make_planner_callable_slot_location(
                                    argument_slot)), candidate)])
                } },
                _ => {}
            }
            candidate = candidate + 1
        }
    }
}

fn add_candidate_call_argument_rules(
    graph: CandidateProofGraph, body_index: Int, block_index: Int,
    boundary: Int, event: PlannerEvent,
    type_nodes: List<PlannerTypeNode>,
    callables: List<PlannerCallable>, bodies: List<PlannerBody>
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
                    if !planner_type_is_callable(
                            type_nodes, callables.get(callee).unwrap()
                                .parameter_type_indices.get(parameter).unwrap()) {
                        parameter = parameter + 1
                        continue
                    }
                    let argument_slot = argument_slots.get(parameter).unwrap()
                    if !planner_type_is_callable(
                            type_nodes,
                            body.slots.get(argument_slot).unwrap().type_index) {
                        panic("ResourcePlanner: callable parameter receives non-callable slot")
                    }
                    let mut candidate = 0
                    while candidate < graph.callable_count {
                        let target = candidate_cell_index(
                            graph.cells, candidate_cell_parameter(), callee,
                            0, 0, parameter, candidate)
                        let argument_cell = candidate_cell_index(
                            graph.cells, candidate_cell_state(), body_index,
                            block_index, boundary,
                            callable_location_index(
                                body, type_nodes,
                                make_planner_callable_slot_location(
                                    argument_slot)), candidate)
                        if planner_call_target_is_direct(call_target) {
                            if planner_call_target_direct(call_target) == callee {
                                add_candidate_rule(
                                    graph.rules, candidate_rule_copy(), site,
                                    target, [argument_cell])
                            }
                        } else {
                            add_candidate_conjunction_rule(
                                graph.rules, site, target,
                                candidate_cell_index(
                                    graph.cells, candidate_cell_state(),
                                    body_index, block_index, boundary,
                                    callable_location_index(
                                        body, type_nodes,
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

pub fn build_candidate_proof_graph(
    type_nodes: List<PlannerTypeNode>,
    callables: List<PlannerCallable>, bodies: List<PlannerBody>
) -> CandidateProofGraph {
    let mut cells: List<CandidateCellSpec> = []
    let rules: List<CandidateRule> = []
    let callable_count = callables.len()
    let mut callable_index = 0
    while callable_index < callable_count {
        let callable = callables.get(callable_index).unwrap()
        let mut parameter = 0
        while parameter < callable.parameter_type_indices.len() {
            if planner_type_is_callable(
                    type_nodes,
                    callable.parameter_type_indices.get(parameter).unwrap()) {
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
        if planner_type_is_callable(type_nodes, callable.result_type_index) {
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
        let locations = body_callable_locations(body, type_nodes)
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
    let graph = CandidateProofGraph {
        callable_count: callable_count, cells: cells, rules: rules
    }
    // ContractOnly callable result aliases are global copy rules.
    callable_index = 0
    while callable_index < callable_count {
        let callable = callables.get(callable_index).unwrap()
        if !callable.has_body &&
           planner_type_is_callable(type_nodes, callable.result_type_index) {
            for parameter in callable.result_origin_parameter_ordinals {
                if !planner_type_is_callable(
                        type_nodes,
                        callable.parameter_type_indices.get(parameter).unwrap()) {
                    panic("ResourcePlanner: callable result aliases non-callable parameter")
                }
                let mut candidate = 0
                while candidate < callable_count {
                    add_candidate_rule(
                        graph.rules, candidate_rule_copy(),
                        make_global_candidate_rule_site(),
                        candidate_cell_index(
                            graph.cells, candidate_cell_result(),
                            callable_index, 0, 0, 0, candidate),
                        [candidate_cell_index(
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
        let locations = body_callable_locations(body, type_nodes)
        let callable = flow_callable_index_for_planner(
            callables, body.reference)
        // Entry parameter cells.
        let mut slot_index = 0
        while slot_index < body.slots.len() {
            match body.slots.get(slot_index).unwrap().parameter_ordinal {
                some(parameter) => {
                    if !planner_type_is_callable(
                            type_nodes,
                            body.slots.get(slot_index).unwrap().type_index) {
                        slot_index = slot_index + 1
                        continue
                    }
                    let mut candidate = 0
                    while candidate < callable_count {
                        add_candidate_rule(
                            graph.rules, candidate_rule_copy(),
                            make_global_candidate_rule_site(),
                            candidate_cell_index(
                                graph.cells, candidate_cell_state(), body_index,
                                body.entry_block, 0,
                                callable_location_index(
                                    body, type_nodes,
                                    make_planner_callable_slot_location(
                                        slot_index)), candidate),
                            [candidate_cell_index(
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
            let mut boundary = 0
            while boundary < block.events.len() {
                let event = block.events.get(boundary).unwrap()
                let site = make_instruction_candidate_rule_site(
                    make_flow_instruction_ref(
                        body.reference, block_index, boundary))
                let mut location = 0
                while location < locations.len() {
                    if !event_candidate_location_overwritten(
                            event, body, locations.get(location).unwrap()) {
                        let mut candidate = 0
                        while candidate < callable_count {
                            add_candidate_rule(
                                graph.rules, candidate_rule_copy(), site,
                                candidate_cell_index(
                                    graph.cells, candidate_cell_state(),
                                    body_index, block_index, boundary + 1,
                                    location, candidate),
                                [candidate_cell_index(
                                    graph.cells, candidate_cell_state(),
                                    body_index, block_index, boundary,
                                    location, candidate)])
                            candidate = candidate + 1
                        }
                    }
                    location = location + 1
                }
                add_candidate_provenance_rules(
                    graph, body_index, block_index, boundary,
                    event, type_nodes, callables, bodies)
                add_candidate_call_argument_rules(
                    graph, body_index, block_index, boundary,
                    event, type_nodes, callables, bodies)
                boundary = boundary + 1
            }
            let end_boundary = block.events.len()
            if block.terminator_kind == 3 &&
               planner_type_is_callable(
                    type_nodes,
                    callables.get(callable).unwrap().result_type_index) {
                for usage in block.terminator_uses {
                    if !planner_type_is_callable(
                            type_nodes,
                            body.slots.get(usage.slot).unwrap().type_index) {
                        panic("ResourcePlanner: callable return uses non-callable slot")
                    }
                    let mut candidate = 0
                    while candidate < callable_count {
                        add_candidate_rule(
                            graph.rules, candidate_rule_copy(),
                            make_terminator_candidate_rule_site(
                                make_flow_block_ref(body.reference, block_index)),
                            candidate_cell_index(
                                graph.cells, candidate_cell_result(),
                                callable, 0, 0, 0, candidate),
                            [candidate_cell_index(
                                graph.cells, candidate_cell_state(), body_index,
                                block_index, end_boundary,
                                callable_location_index(
                                    body, type_nodes,
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
                                    add_candidate_rule(
                                        graph.rules, candidate_rule_copy(),
                                        make_edge_candidate_rule_site(
                                            make_flow_block_ref(
                                                body.reference, block_index),
                                            edge_index),
                                        candidate_cell_index(
                                            graph.cells, candidate_cell_state(),
                                            body_index, target_block, 0,
                                            location, candidate),
                                        [candidate_cell_index(
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

fn candidate_rule_is_enabled(
    rule: CandidateRule, values: List<Bool>
) -> Bool {
    if candidate_rule_kind_tag(candidate_rule_kind(rule)) ==
       candidate_rule_kind_tag(candidate_rule_seed()) {
        return true
    }
    for premise in candidate_rule_premise_cells(rule) {
        if !values.get(premise).unwrap() { return false }
    }
    true
}

pub fn solve_candidate_proof_graph(
    graph: CandidateProofGraph
) -> CallableCandidateProof {
    let mut values: List<Bool> = []
    for _ in graph.cells { values.push(false) }
    let mut promotions: List<CandidatePromotion> = []
    let mut changed = true
    while changed {
        changed = false
        let mut rule_index = 0
        while rule_index < graph.rules.len() {
            let rule = graph.rules.get(rule_index).unwrap()
            let target = candidate_rule_target_cell(rule)
            if !values.get(target).unwrap() &&
               candidate_rule_is_enabled(rule, values) {
                let mut premises: List<Bool> = []
                for premise in candidate_rule_premise_cells(rule) {
                    premises.push(values.get(premise).unwrap())
                }
                promotions.push(make_candidate_promotion(
                    rule_index, target, premises))
                values.set(target, true)
                changed = true
                if promotions.len() > graph.cells.len() {
                    panic("ResourcePlanner: candidate proof exceeds strict rank budget")
                }
            }
            rule_index = rule_index + 1
        }
    }
    make_callable_candidate_proof(
        graph.callable_count, graph.cells, graph.rules,
        promotions, values, [])
}

fn proof_state_candidate_set(
    proof: CallableCandidateProof, body: Int, block: Int,
    boundary: Int, component: Int
) -> List<Bool> {
    let cells = callable_candidate_proof_cells(proof)
    let values = callable_candidate_proof_final_values(proof)
    let mut result = empty_candidate_set(
        callable_candidate_proof_callable_count(proof))
    let mut candidate = 0
    while candidate < result.len() {
        let cell = candidate_cell_index(
            cells, candidate_cell_state(), body,
            block, boundary, component, candidate)
        result.set(candidate, values.get(cell).unwrap())
        candidate = candidate + 1
    }
    result
}

pub fn derive_candidate_selections(
    proof: CallableCandidateProof, type_nodes: List<PlannerTypeNode>,
    bodies: List<PlannerBody>
) -> List<CandidateSelection> {
    let mut result: List<CandidateSelection> = []
    let mut body_index = 0
    while body_index < bodies.len() {
        let body = bodies.get(body_index).unwrap()
        let mut block_index = 0
        while block_index < body.blocks.len() {
            let block = body.blocks.get(block_index).unwrap()
            let mut boundary = 0
            while boundary < block.events.len() {
                match block.events.get(boundary).unwrap().value {
                    PlannerEventValue::CallValue { call_target, .. } => {
                        if !planner_call_target_is_direct(call_target) {
                            let candidates = candidate_set_indices(
                                proof_state_candidate_set(
                                    proof, body_index, block_index, boundary,
                                    callable_location_index(
                                        body, type_nodes,
                                        make_planner_callable_slot_location(
                                            planner_call_target_slot(
                                                call_target)))))
                            result.push(make_candidate_selection(
                                make_flow_instruction_ref(
                                    body.reference, block_index, boundary),
                                candidates))
                        }
                    },
                    _ => {}
                }
                boundary = boundary + 1
            }
            block_index = block_index + 1
        }
        body_index = body_index + 1
    }
    result
}

pub fn with_candidate_selections(
    value: CallableCandidateProof, selections: List<CandidateSelection>
) -> CallableCandidateProof {
    make_callable_candidate_proof(
        callable_candidate_proof_callable_count(value),
        callable_candidate_proof_cells(value),
        callable_candidate_proof_rules(value),
        callable_candidate_proof_promotions(value),
        callable_candidate_proof_final_values(value), selections)
}

pub fn resolve_bodies_from_candidate_proof(
    proof: CallableCandidateProof, type_nodes: List<PlannerTypeNode>,
    bodies: List<PlannerBody>
) -> List<PlannerBody> {
    let mut result: List<PlannerBody> = []
    let mut body_index = 0
    while body_index < bodies.len() {
        let body = bodies.get(body_index).unwrap()
        let mut blocks: List<PlannerBlock> = []
        let mut block_index = 0
        while block_index < body.blocks.len() {
            let block = body.blocks.get(block_index).unwrap()
            let mut events: List<PlannerEvent> = []
            let mut boundary = 0
            while boundary < block.events.len() {
                let event = block.events.get(boundary).unwrap()
                let resolved = match event.value {
                    PlannerEventValue::CallValue { call_target, .. } => {
                        let candidates = if planner_call_target_is_direct(
                                call_target) {
                            [planner_call_target_direct(call_target)]
                        } else {
                            candidate_set_indices(proof_state_candidate_set(
                                proof, body_index, block_index, boundary,
                                callable_location_index(
                                    body, type_nodes,
                                    make_planner_callable_slot_location(
                                        planner_call_target_slot(call_target)))))
                        }
                        if candidates.len() == 0 {
                            panic("ResourcePlanner: certified required call is empty")
                        }
                        replace_call_candidates(event, candidates)
                    },
                    _ => copy_planner_event(event)
                }
                events.push(resolved)
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
