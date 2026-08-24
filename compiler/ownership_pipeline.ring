// Sole 0.1 CoreHIR -> FlowIR -> ResourcePlanner vertical entry.
//
// This wrapper accepts no legacy HProgram, side table, display-name fallback,
// or post-0.1 hook.  CoreProgram is reconstructed through its canonical
// closure first, then lowered exactly once.  The Flow executable projection is
// checked against Core before the opaque verified resource result can escape.

use ir_identity::{origin_ref_same}
use ir_inventory::{
    executable_ref_same,
    executable_inventory_entries,
    executable_entry_reference}
use core_expr::{
    core_type_graph_count,
    core_callable_reference, core_callable_origin}
use core_hir::{
    CoreProgram,
    make_core_program,
    core_program_body_count, core_program_bodies,
    core_body_entry_reference, core_body_entry_origin,
    core_program_type_graph, core_program_callables,
    core_program_impls, core_program_inventory,
    core_program_manifests}
use flow_ir::{
    FlowProgram,
    flow_program_type_nodes, flow_program_callables, flow_program_bodies,
    flow_program_topology_fingerprint,
    flow_topology_fingerprint_canonical,
    flow_callable_reference, flow_callable_origin,
    flow_body_reference, flow_body_origin}
use flow_lower::{lower_core_to_flow}
use resource_planner::{
    VerifiedResourceProgram,
    verify_and_plan_resource_program,
    verified_resource_program_flow_fingerprint}

fn validate_nonempty_core(value: CoreProgram) {
    let types = core_type_graph_count(core_program_type_graph(value))
    let callables = core_program_callables(value)
    let inventory = executable_inventory_entries(
        core_program_inventory(value))
    if types == 0 || callables.len() == 0 || inventory.len() == 0 ||
       core_program_body_count(value) == 0 {
        panic("ownership pipeline: empty CoreProgram is not admissible")
    }
}

fn validate_core_flow_relation(core: CoreProgram, flow: FlowProgram) {
    let core_types = core_type_graph_count(core_program_type_graph(core))
    let flow_types = flow_program_type_nodes(flow)
    if core_types != flow_types.len() {
        panic("ownership pipeline: Core/Flow type census differs")
    }

    let core_callables = core_program_callables(core)
    let flow_callables = flow_program_callables(flow)
    let inventory = executable_inventory_entries(
        core_program_inventory(core))
    if core_callables.len() != flow_callables.len() ||
       inventory.len() != flow_callables.len() {
        panic("ownership pipeline: Core/Flow/inventory executable census differs")
    }
    let mut callable_index = 0
    while callable_index < core_callables.len() {
        let core_callable = core_callables.get(callable_index).unwrap()
        let flow_callable = flow_callables.get(callable_index).unwrap()
        let inventory_entry = inventory.get(callable_index).unwrap()
        if !executable_ref_same(
                core_callable_reference(core_callable),
                flow_callable_reference(flow_callable)) ||
           !executable_ref_same(
                core_callable_reference(core_callable),
                executable_entry_reference(inventory_entry)) ||
           !origin_ref_same(
                core_callable_origin(core_callable),
                flow_callable_origin(flow_callable)) {
            panic("ownership pipeline: callable identity/origin projection differs")
        }
        callable_index = callable_index + 1
    }

    let core_bodies = core_program_bodies(core)
    let flow_bodies = flow_program_bodies(flow)
    if core_bodies.len() != flow_bodies.len() ||
       core_bodies.len() != core_program_body_count(core) {
        panic("ownership pipeline: Core/Flow body census differs")
    }
    let mut body_index = 0
    while body_index < core_bodies.len() {
        let core_body = core_bodies.get(body_index).unwrap()
        let flow_body = flow_bodies.get(body_index).unwrap()
        if !executable_ref_same(
                core_body_entry_reference(core_body),
                flow_body_reference(flow_body)) ||
           !origin_ref_same(
                core_body_entry_origin(core_body),
                flow_body_origin(flow_body)) {
            panic("ownership pipeline: body identity/origin projection differs")
        }
        body_index = body_index + 1
    }
}

// Opaque bridge result.  Keeping all three exact stage values together makes
// it impossible for a downstream adapter to pair verified RcIR with a
// different Core/Flow program or to invoke Core->Flow lowering a second time.
pub struct VerifiedOwnershipProgram {
    core: CoreProgram,
    flow: FlowProgram,
    resources: VerifiedResourceProgram
}

pub fn verified_ownership_program_core(
    value: VerifiedOwnershipProgram
) -> CoreProgram { value.core }

pub fn verified_ownership_program_flow(
    value: VerifiedOwnershipProgram
) -> FlowProgram { value.flow }

pub fn verified_ownership_program_resources(
    value: VerifiedOwnershipProgram
) -> VerifiedResourceProgram { value.resources }

pub fn run_ownership_pipeline(
    core: CoreProgram
) -> VerifiedOwnershipProgram {
    // Re-enter the sole Core closure constructor instead of trusting a copied
    // field or adding a second validator authority.
    let validated_core = make_core_program(
        core_program_type_graph(core),
        core_program_callables(core),
        core_program_impls(core),
        core_program_bodies(core),
        core_program_inventory(core),
        core_program_manifests(core))
    validate_nonempty_core(validated_core)

    let flow = lower_core_to_flow(validated_core)
    validate_core_flow_relation(validated_core, flow)
    let resources = verify_and_plan_resource_program(flow)
    let flow_fingerprint = flow_topology_fingerprint_canonical(
        flow_program_topology_fingerprint(flow))
    if verified_resource_program_flow_fingerprint(resources) !=
       flow_fingerprint {
        panic("ownership pipeline: verified resources bind another FlowProgram")
    }
    VerifiedOwnershipProgram {
        core: validated_core,
        flow: flow,
        resources: resources
    }
}
