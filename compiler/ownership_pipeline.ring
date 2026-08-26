// Sole 0.1 CoreHIR -> FlowIR -> ResourcePlanner vertical entry.
//
// This wrapper accepts no legacy HProgram, side table, display-name fallback,
// or post-0.1 hook.  CoreProgram is reconstructed through its canonical
// closure first, then lowered exactly once.  The Flow executable projection is
// checked against Core before the opaque verified resource result can escape.

use ir_identity::{SlotRef, origin_ref_same}
use ir_inventory::{
    executable_ref_same,
    executable_inventory_entries,
    executable_entry_reference}
use diagnostics::{Diagnostic, Severity, DiagnosticContext, make_diag}
use codes::{E0801}
use core_from_hir::{
    CoreDiagnosticProjection,
    core_diagnostic_projection_origin_location,
    core_diagnostic_projection_slot_display_label,
    core_diagnostic_location_module_key,
    core_diagnostic_location_span}
use core_type_source::{core_type_graph_count}
use core_expr::{
    core_callable_reference, core_callable_origin}
use core_hir::{
    CoreProgram,
    make_core_program,
    core_program_body_count, core_program_bodies,
    core_body_entry_reference, core_body_entry_origin,
    core_program_type_graph, core_program_callables,
    core_program_impls, core_program_inventory}
use flow_ir::{
    FlowProgram,
    flow_program_type_nodes, flow_program_callables, flow_program_bodies,
    flow_program_topology_fingerprint,
    flow_topology_fingerprint_canonical,
    flow_semantic_step_same,
    flow_place_is_slot, flow_place_slot, flow_place_base,
    flow_callable_reference, flow_callable_origin,
    flow_body_reference, flow_body_origin}
use flow_lower::{
    CoreFlowNodeRef, CoreFlowStepMap, lower_core_to_flow,
    core_flow_node_owner, core_flow_node_origin,
    core_flow_step_map_relations,
    core_flow_step, core_flow_step_node,
    flow_lowering_program, flow_lowering_step_map
}
use resource_planner::{
    VerifiedResourceProgram,
    verify_and_plan_resource_program,
    planning_outcome_is_verified, planning_outcome_findings,
    planning_outcome_verified,
    verified_resource_program_flow_fingerprint}
use resource_type_lfp::{
    ResourceDiagnostic, resource_diagnostic_step,
    resource_diagnostic_is_place, resource_diagnostic_slot,
    resource_diagnostic_place, planner_place_exact}

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
    resources: VerifiedResourceProgram,
    step_map: CoreFlowStepMap
}

struct FailedOwnershipProgram {
    findings: List<ResourceDiagnostic>,
    step_map: CoreFlowStepMap
}

enum OwnershipPipelineOutcomeValue {
    OwnershipPipelineFailedValue(FailedOwnershipProgram),
    OwnershipPipelineVerifiedValue(VerifiedOwnershipProgram)
}

pub struct OwnershipPipelineOutcome {
    value: OwnershipPipelineOutcomeValue
}

pub fn ownership_pipeline_outcome_is_verified(
    value: OwnershipPipelineOutcome
) -> Bool {
    match value.value {
        OwnershipPipelineOutcomeValue::OwnershipPipelineVerifiedValue(_) => true,
        _ => false
    }
}

fn ownership_pipeline_outcome_failed(
    value: OwnershipPipelineOutcome
) -> FailedOwnershipProgram {
    match value.value {
        OwnershipPipelineOutcomeValue::OwnershipPipelineFailedValue(failed) =>
            failed,
        _ => panic("ownership pipeline: verified outcome has no findings")
    }
}

pub fn ownership_pipeline_outcome_verified(
    value: OwnershipPipelineOutcome
) -> VerifiedOwnershipProgram {
    match value.value {
        OwnershipPipelineOutcomeValue::OwnershipPipelineVerifiedValue(verified) =>
            verified,
        _ => panic("ownership pipeline: failed outcome has no verified program")
    }
}

fn failed_ownership_program_core_node_for_finding(
    value: FailedOwnershipProgram, finding: ResourceDiagnostic
) -> CoreFlowNodeRef {
    let step = resource_diagnostic_step(finding)
    for relation in core_flow_step_map_relations(value.step_map) {
        if flow_semantic_step_same(core_flow_step(relation), step) {
            return core_flow_step_node(relation)
        }
    }
    panic("ownership pipeline: finding Flow step has no Core origin")
}

fn ownership_diagnostic_target_slot(
    finding: ResourceDiagnostic
) -> SlotRef {
    if !resource_diagnostic_is_place(finding) {
        return resource_diagnostic_slot(finding)
    }
    let exact = planner_place_exact(resource_diagnostic_place(finding))
    if flow_place_is_slot(exact) {
        flow_place_slot(exact)
    } else {
        flow_place_base(exact)
    }
}

pub fn ownership_pipeline_failure_diagnostics(
    outcome: OwnershipPipelineOutcome,
    projection: CoreDiagnosticProjection
) -> List<(Str, Diagnostic)> {
    let failed = ownership_pipeline_outcome_failed(outcome)
    let mut result: List<(Str, Diagnostic)> = []
    for finding in failed.findings {
        let node = failed_ownership_program_core_node_for_finding(
            failed, finding)
        let location = core_diagnostic_projection_origin_location(
            projection, core_flow_node_owner(node), core_flow_node_origin(node))
        let module_key = core_diagnostic_location_module_key(location)
        let label = core_diagnostic_projection_slot_display_label(
            projection, ownership_diagnostic_target_slot(finding), module_key)
        result.push((module_key, make_diag(
            E0801, Severity::SevError,
            "use of moved value: '${label}'",
            core_diagnostic_location_span(location),
            DiagnosticContext::OtherContext {
                detail: some("value was previously moved")
            })))
    }
    result
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
pub fn verified_ownership_program_step_map(
    value: VerifiedOwnershipProgram
) -> CoreFlowStepMap { value.step_map }

pub fn run_ownership_pipeline(
    core: CoreProgram
) -> OwnershipPipelineOutcome {
    // Re-enter the sole Core closure constructor instead of trusting a copied
    // field or adding a second validator authority.
    let validated_core = make_core_program(
        core_program_type_graph(core),
        core_program_callables(core),
        core_program_impls(core),
        core_program_bodies(core),
        core_program_inventory(core))
    validate_nonempty_core(validated_core)

    let lowering = lower_core_to_flow(validated_core)
    let flow = flow_lowering_program(lowering)
    let step_map = flow_lowering_step_map(lowering)
    validate_core_flow_relation(validated_core, flow)
    let planning = verify_and_plan_resource_program(flow)
    if !planning_outcome_is_verified(planning) {
        let findings = planning_outcome_findings(planning)
        if findings.len() == 0 {
            panic("ownership pipeline: failed planning outcome is empty")
        }
        return OwnershipPipelineOutcome {
            value: OwnershipPipelineOutcomeValue::OwnershipPipelineFailedValue(
                FailedOwnershipProgram {
                    findings: findings, step_map: step_map
                })
        }
    }
    let resources = planning_outcome_verified(planning)
    let flow_fingerprint = flow_topology_fingerprint_canonical(
        flow_program_topology_fingerprint(flow))
    if verified_resource_program_flow_fingerprint(resources) !=
       flow_fingerprint {
        panic("ownership pipeline: verified resources bind another FlowProgram")
    }
    OwnershipPipelineOutcome {
        value: OwnershipPipelineOutcomeValue::OwnershipPipelineVerifiedValue(
            VerifiedOwnershipProgram {
                core: validated_core,
                flow: flow,
                resources: resources,
                step_map: step_map
            })
    }
}
