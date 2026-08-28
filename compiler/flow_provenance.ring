// Exact callable-value provenance over frozen FlowIR.
// This module owns no resolver, type/effect inference, candidate solver, or
// fallback. It projects only callable-typed slot/place facts already present
// in one Flow instruction.

use ir_identity::{
    CoreTypeRef, core_type_ref_index, SlotRef, slot_ref_same
}
use resource_model::{flow_semantic_role_read}
use core_type_source::{
    FlowTypeNode, flow_type_node_kind,
    flow_type_kind_tag, flow_type_kind_callable
}
use flow_ir::{
    FlowInstruction, FlowSlot,
    FlowAggregateInputRef, FlowProjectionContract,
    FlowCallableProvenanceFact,
    flow_instruction_reference, flow_instruction_kind_tag,
    make_flow_instruction_step_ref,
    flow_slot_reference, flow_slot_type,
    flow_initialize_operation, flow_initialize_inputs, flow_initialize_target,
    flow_operation_contract_kind_tag,
    flow_operation_contract_closure_executable,
    flow_operation_contract_callable_executable,
    flow_operation_contract_input_locations,
    flow_read_source, flow_read_target,
    flow_assign_rhs_temp, flow_assign_target,
    flow_move_place_source, flow_move_place_target,
    flow_place_is_slot, flow_place_slot, flow_place_base,
    flow_place_projection,
    flow_call_target, flow_call_arguments, flow_call_result,
    flow_project_contract, flow_project_base, flow_project_result,
    flow_capture_source, flow_capture_target,
    flow_aggregate_input_kind_tag, flow_aggregate_input_nominal,
    flow_aggregate_input_variant, flow_aggregate_input_tuple_index,
    flow_aggregate_input_structural_path,
    make_nominal_flow_projection_contract,
    make_variant_flow_projection_contract,
    make_tuple_flow_projection_contract,
    make_structural_flow_projection_contract,
    make_flow_callable_slot_location,
    make_flow_callable_projection_location,
    make_flow_direct_callable_origin,
    make_flow_slots_callable_origin,
    make_flow_locations_callable_origin,
    make_flow_call_callable_origin,
    make_flow_callable_provenance_fact
}

fn slot_type(slots: List<FlowSlot>, target: SlotRef) -> CoreTypeRef {
    for slot in slots {
        if slot_ref_same(flow_slot_reference(slot), target) {
            return flow_slot_type(slot)
        }
    }
    panic("Flow callable provenance: slot is absent")
}

fn slot_is_callable(
    slots: List<FlowSlot>, types: List<FlowTypeNode>, target: SlotRef
) -> Bool {
    let ty = slot_type(slots, target)
    flow_type_kind_tag(flow_type_node_kind(
        types.get(core_type_ref_index(ty)).unwrap())) ==
        flow_type_kind_tag(flow_type_kind_callable())
}

fn aggregate_projection(
    location: FlowAggregateInputRef,
    base_type: CoreTypeRef, result_type: CoreTypeRef
) -> FlowProjectionContract {
    let kind = flow_aggregate_input_kind_tag(location)
    if kind == 0 {
        return make_nominal_flow_projection_contract(
            flow_aggregate_input_nominal(location), base_type, result_type,
            flow_semantic_role_read(), false)
    }
    if kind == 1 {
        return make_variant_flow_projection_contract(
            flow_aggregate_input_variant(location), base_type, result_type,
            flow_semantic_role_read(), false)
    }
    if kind == 2 {
        return make_tuple_flow_projection_contract(
            flow_aggregate_input_tuple_index(location), base_type, result_type,
            flow_semantic_role_read(), false)
    }
    make_structural_flow_projection_contract(
        flow_aggregate_input_structural_path(location),
        base_type, result_type, flow_semantic_role_read(), false)
}

pub fn flow_instruction_callable_provenance(
    instruction: FlowInstruction,
    slots: List<FlowSlot>, types: List<FlowTypeNode>
) -> List<FlowCallableProvenanceFact> {
    let step = make_flow_instruction_step_ref(
        flow_instruction_reference(instruction))
    let mut result: List<FlowCallableProvenanceFact> = []
    let kind = flow_instruction_kind_tag(instruction)
    if kind == 0 {
        let operation = flow_initialize_operation(instruction)
        if flow_operation_contract_kind_tag(operation) == 13 {
            return []
        }
        let target = flow_initialize_target(instruction)
        if slot_is_callable(slots, types, target) {
            let operation_kind = flow_operation_contract_kind_tag(operation)
            let executable = if operation_kind == 11 {
                flow_operation_contract_closure_executable(operation)
            } else if operation_kind == 12 {
                flow_operation_contract_callable_executable(operation)
            } else {
                panic("Flow callable provenance: callable Initialize lacks executable")
            }
            result.push(make_flow_callable_provenance_fact(
                step, make_flow_callable_slot_location(target),
                make_flow_direct_callable_origin(executable)))
        } else {
            let inputs = flow_initialize_inputs(instruction)
            let locations = flow_operation_contract_input_locations(operation)
            let mut index = 0
            while index < inputs.len() {
                let input = inputs.get(index).unwrap()
                if slot_is_callable(slots, types, input) {
                    let location = match locations.get(index).unwrap() {
                        some(value) => value,
                        none => panic(
                            "Flow callable provenance: aggregate field location absent")
                    }
                    result.push(make_flow_callable_provenance_fact(
                        step,
                        make_flow_callable_projection_location(
                            target, aggregate_projection(
                                location, slot_type(slots, target),
                                slot_type(slots, input))),
                        make_flow_slots_callable_origin([input])))
                }
                index = index + 1
            }
        }
        return result
    }
    if kind == 1 {
        let target = flow_read_target(instruction)
        if slot_is_callable(slots, types, target) {
            result.push(make_flow_callable_provenance_fact(
                step, make_flow_callable_slot_location(target),
                make_flow_slots_callable_origin([
                    flow_read_source(instruction)])))
        }
        return result
    }
    if kind == 5 {
        let rhs = flow_assign_rhs_temp(instruction)
        let place = flow_assign_target(instruction)
        if slot_is_callable(slots, types, rhs) {
            let target = if flow_place_is_slot(place) {
                make_flow_callable_slot_location(flow_place_slot(place))
            } else {
                make_flow_callable_projection_location(
                    flow_place_base(place), flow_place_projection(place))
            }
            result.push(make_flow_callable_provenance_fact(
                step, target, make_flow_slots_callable_origin([rhs])))
        }
        return result
    }
    if kind == 6 {
        match flow_call_result(instruction) {
            some(target) => if slot_is_callable(slots, types, target) {
                result.push(make_flow_callable_provenance_fact(
                    step, make_flow_callable_slot_location(target),
                    make_flow_call_callable_origin(
                        flow_call_target(instruction),
                        flow_call_arguments(instruction))))
            },
            none => {}
        }
        return result
    }
    if kind == 7 {
        let target = flow_project_result(instruction)
        if slot_is_callable(slots, types, target) {
            result.push(make_flow_callable_provenance_fact(
                step, make_flow_callable_slot_location(target),
                make_flow_locations_callable_origin([
                    make_flow_callable_projection_location(
                        flow_project_base(instruction),
                        flow_project_contract(instruction))
                ])))
        }
        return result
    }
    if kind == 8 {
        let target = flow_capture_target(instruction)
        if slot_is_callable(slots, types, target) {
            result.push(make_flow_callable_provenance_fact(
                step, make_flow_callable_slot_location(target),
                make_flow_slots_callable_origin([
                    flow_capture_source(instruction)])))
        }
    }
    if kind == 12 {
        let target = flow_move_place_target(instruction)
        if slot_is_callable(slots, types, target) {
            let source = flow_move_place_source(instruction)
            let origin = if flow_place_is_slot(source) {
                make_flow_slots_callable_origin([flow_place_slot(source)])
            } else {
                make_flow_locations_callable_origin([
                    make_flow_callable_projection_location(
                        flow_place_base(source), flow_place_projection(source))
                ])
            }
            result.push(make_flow_callable_provenance_fact(
                step, make_flow_callable_slot_location(target), origin))
        }
    }
    result
}
