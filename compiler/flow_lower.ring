// Strict CoreHIR -> FlowIR adapter contract.
//
// CoreHIR does not yet expose a canonical CoreExpr tree.  Consequently this
// module intentionally contains no legacy HProgram/HExpr adapter and no
// speculative semantic lowering.  The eventual Core producer must supply the
// complete, already-elaborated type graph, callable table, precreated slots,
// neutral operations, and fixed CFG through FlowIR smart constructors.  This
// append-only input is sealed exactly once by `lower_core_to_flow`; FlowIR then
// performs all collection-complete validation and freezes the topology.

use flow_ir::{
    FlowTypeNode, FlowCallable, FlowBody, FlowProgram,
    FlowTypeRef, FlowCallableMode,
    flow_type_node_reference, flow_type_ref_index,
    flow_callable_reference, flow_callable_mode,
    flow_callable_mode_same, flow_callable_mode_concrete_body,
    flow_body_reference,
    make_flow_program
}
use ir_inventory::{ExecutableRef, executable_ref_same}

pub struct FlowLoweringInput {
    type_nodes: List<FlowTypeNode>,
    callables: List<FlowCallable>,
    bodies: List<FlowBody>,
    concrete_callable_count: Int,
    sealed: Bool
}

pub fn make_flow_lowering_input() -> FlowLoweringInput {
    FlowLoweringInput {
        type_nodes: [], callables: [], bodies: [],
        concrete_callable_count: 0, sealed: false
    }
}

fn require_open(value: FlowLoweringInput) {
    if value.sealed {
        panic("FlowIR lowering: input was already sealed")
    }
}

pub fn flow_lowering_add_type_node(
    mut input: FlowLoweringInput, node: FlowTypeNode
) {
    require_open(input)
    let reference = flow_type_node_reference(node)
    if flow_type_ref_index(reference) != input.type_nodes.len() {
        panic("FlowIR lowering: type nodes are not appended in ordinal order")
    }
    input.type_nodes.push(node)
}

pub fn flow_lowering_add_callable(
    mut input: FlowLoweringInput, callable: FlowCallable
) {
    require_open(input)
    let reference = flow_callable_reference(callable)
    for existing in input.callables {
        if executable_ref_same(flow_callable_reference(existing), reference) {
            panic("FlowIR lowering: callable was appended twice")
        }
    }
    if flow_callable_mode_same(
            flow_callable_mode(callable),
            flow_callable_mode_concrete_body()) {
        input.concrete_callable_count = input.concrete_callable_count + 1
    }
    input.callables.push(callable)
}

pub fn flow_lowering_add_body(
    mut input: FlowLoweringInput, body: FlowBody
) {
    require_open(input)
    let reference = flow_body_reference(body)
    for existing in input.bodies {
        if executable_ref_same(flow_body_reference(existing), reference) {
            panic("FlowIR lowering: body was appended twice")
        }
    }
    if input.bodies.len() >= input.concrete_callable_count {
        panic("FlowIR lowering: body precedes a concrete callable contract")
    }
    // Bodies are an exact subsequence of the callable table.  Reject an
    // out-of-order producer here; make_flow_program repeats the collection-wide
    // proof at the freeze boundary.
    let mut concrete_index = 0
    let mut expected: ExecutableRef? = none
    for callable in input.callables {
        if flow_callable_mode_same(
                flow_callable_mode(callable),
                flow_callable_mode_concrete_body()) {
            if concrete_index == input.bodies.len() {
                expected = some(flow_callable_reference(callable))
            }
            concrete_index = concrete_index + 1
        }
    }
    match expected {
        some(executable) => if !executable_ref_same(executable, reference) {
            panic("FlowIR lowering: body order differs from callable table")
        },
        none => panic("FlowIR lowering: body has no concrete callable")
    }
    input.bodies.push(body)
}

pub fn flow_lowering_type_count(value: FlowLoweringInput) -> Int {
    value.type_nodes.len()
}

pub fn flow_lowering_callable_count(value: FlowLoweringInput) -> Int {
    value.callables.len()
}

pub fn flow_lowering_body_count(value: FlowLoweringInput) -> Int {
    value.bodies.len()
}

pub fn flow_lowering_input_is_sealed(value: FlowLoweringInput) -> Bool {
    value.sealed
}

// There is deliberately one entry for single-file and project compilation.
// A single file is simply an input whose exact identities all originate from
// one module; no mode flag or alternate ordering path exists here.
pub fn lower_core_to_flow(mut input: FlowLoweringInput) -> FlowProgram {
    require_open(input)
    if input.bodies.len() != input.concrete_callable_count {
        panic("FlowIR lowering: concrete callable/body census differs")
    }
    input.sealed = true
    make_flow_program(input.type_nodes, input.callables, input.bodies)
}

