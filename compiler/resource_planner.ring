// ONE ResourcePlanner authority for frozen FlowIR.
//
// This file owns the finite type-shape/callable solve and the per-body slot
// state machine.  Its input is a deliberately narrow, index-stable adapter
// snapshot populated from frozen FlowIR.  It never resolves a name, compares a
// source/span spelling, re-runs type/effect/trait selection, or creates a
// semantic binder/block/edge.  The final FlowProgram adapter constructor is
// intentionally the only glue point to the concurrently landed flow_ir API.

use ir_identity::{
    SlotRef, PathRef, slot_ref_same, slot_ref_is_source, slot_ref_synthetic_path,
    path_ref_same}
use ir_inventory::{ExecutableRef, executable_ref_same}
use flow_ir::{
    FlowProgram, FlowTypeNode, FlowTypeRef,
    FlowSemanticRole, FlowValueOriginContract,
    FlowCallable, FlowBody, FlowSlot, FlowScope, FlowScopeRef,
    FlowInstruction, FlowInstructionRef, FlowBlockRef, FlowPlaceRef,
    FlowTerminator, FlowCallTarget,
    validate_flow_program,
    flow_program_type_nodes, flow_program_callables, flow_program_bodies,
    flow_program_topology_fingerprint,
    flow_topology_fingerprint_canonical,
    flow_type_ref_index, flow_type_ref_same,
    flow_type_node_reference, flow_type_node_kind,
    flow_type_node_children, flow_type_node_generic_param,
    flow_type_node_resource_edges,
    flow_resource_edge_child,
    flow_resource_edge_child_dependency_ordinal,
    flow_resource_edge_target,
    flow_resource_dependency_target_is_parent,
    flow_resource_dependency_target_parent,
    flow_resource_dependency_target_parent_ordinal,
    flow_resource_dependency_target_concrete_type,
    flow_type_node_semantic_seed, flow_type_node_drop_contract,
    flow_type_node_foreign_contract,
    flow_type_kind_tag, flow_type_semantic_seed_tag,
    flow_generic_param_index, flow_generic_param_arity,
    flow_foreign_contract_is_managed,
    flow_semantic_role_tag,
    flow_call_contract_parameter_roles, flow_call_contract_result_type,
    flow_call_contract_result_role,
    flow_call_contract_result_origin,
    flow_value_origin_is_fresh, flow_value_origin_alias_ordinals,
    flow_callable_reference, flow_callable_parameter_types,
    flow_callable_parameter_slots,
    flow_callable_result_type, flow_callable_mode,
    flow_callable_mode_concrete_body, flow_callable_mode_same,
    flow_callable_semantic_contract,
    flow_call_target_contract,
    flow_call_target_is_direct, flow_call_target_is_local,
    flow_call_target_direct, flow_call_target_local,
    flow_call_target_dynamic,
    flow_instruction_callable_provenance,
    flow_callable_provenance_target, flow_callable_provenance_origin,
    flow_callable_origin_is_direct, flow_callable_origin_is_call,
    flow_callable_origin_direct, flow_callable_origin_slots,
    flow_callable_origin_call_target,
    flow_callable_origin_call_arguments,
    flow_body_reference, flow_body_scopes, flow_body_slots,
    flow_body_entry, flow_body_blocks,
    flow_scope_reference, flow_scope_has_parent, flow_scope_parent,
    flow_scope_ref_ordinal, flow_scope_ref_same,
    flow_slot_reference, flow_slot_type, flow_slot_scope,
    flow_slot_reverse_ordinal, flow_slot_initial_state,
    flow_slot_storage, flow_slot_storage_contract,
    flow_slot_parameter_ordinal,
    flow_initial_slot_state_tag, flow_storage_class_tag,
    flow_storage_contract_tag,
    flow_block_reference, flow_block_instructions, flow_block_terminator,
    flow_block_ref_ordinal, flow_block_ref_same,
    flow_instruction_ref_same,
    make_flow_instruction_ref, make_flow_block_ref,
    flow_instruction_kind_tag,
    flow_initialize_operation, flow_initialize_inputs,
    flow_initialize_target,
    flow_operation_contract_input_roles,
    flow_operation_contract_target_origin,
    flow_read_source, flow_read_target,
    flow_mutate_target, flow_mutate_value,
    flow_mutate_target_role, flow_mutate_value_role,
    flow_consume_source, flow_discard_source,
    flow_fail_raise_payload, flow_fail_raise_sink,
    flow_assign_rhs_temp, flow_assign_target,
    flow_place_is_slot, flow_place_slot, flow_place_base,
    flow_place_projection, flow_place_evaluated_index,
    flow_place_value_type,
    flow_call_target, flow_call_arguments, flow_call_result,
    flow_project_base, flow_project_result, flow_project_is_partial,
    flow_capture_source, flow_capture_target, flow_capture_source_role,
    flow_capture_target_role,
    flow_scope_instruction_scope,
    flow_terminator_kind_tag, flow_terminator_successors,
    flow_terminator_read_slots, flow_terminator_terminal_exited_scopes,
    flow_successor_target, flow_successor_exited_scopes}
use resource_model::{
    ParamMode, TransferDemand,
    LogicalOwnershipShape, PhysicalRcShape,
    SlotFlow,
    param_mode_from_tag, param_mode_tag, param_mode_same,
    param_mode_bottom, param_mode_borrow, param_mode_mut_borrow,
    param_mode_own, param_mode_is_conflict,
    make_transfer_demand, transfer_demand_mode,
    transfer_demand_force, transfer_demand_join, transfer_demand_leq,
    make_logical_ownership_shape,
    logical_ownership_shape_direct_drop,
    logical_ownership_shape_may_unique,
    logical_ownership_shape_param_deps,
    make_physical_rc_shape,
    physical_rc_shape_physical_rc,
    physical_rc_shape_boxing,
    physical_rc_shape_drop_glue,
    physical_rc_shape_foreign_containment,
    physical_rc_shape_param_deps,
    slot_flow_from_tag, slot_flow_tag, slot_flow_same,
    slot_flow_unreachable, slot_flow_empty, slot_flow_live,
    slot_flow_moved, slot_flow_maybe_moved,
    slot_flow_join}
use rc_ir::{
    RcProgram, RcBody, RcBlock, RcStep, RcEdge, RcSlot, RcOperation,
    RcSemanticSite,
    make_rc_program, make_rc_body, make_rc_block, make_rc_step,
    make_rc_edge, make_rc_slot,
    make_rc_clone_at, make_rc_take_at, make_rc_drop_at, make_rc_cleanup_at,
    make_rc_instruction_site, make_rc_terminator_site, make_rc_edge_site,
    rc_site_before_instruction, rc_site_after_instruction,
    rc_program_flow_fingerprint, rc_program_type_count,
    rc_program_callable_count, rc_program_bodies,
    rc_body_reference, rc_body_slots, rc_body_entry_block, rc_body_blocks,
    rc_slot_reference, rc_slot_type_index, rc_slot_scope_id,
    rc_slot_scope_depth, rc_slot_reverse_lexical_ordinal,
    rc_block_source_index, rc_block_source_ref,
    rc_block_terminator_kind, rc_block_semantic_op_count,
    rc_block_steps, rc_block_before_terminator, rc_block_edges,
    rc_step_semantic_op_index, rc_step_instruction,
    rc_step_before, rc_step_after,
    rc_edge_successor_ordinal, rc_edge_target_block, rc_edge_cleanup,
    rc_operation_site, rc_operation_kind,
    rc_operation_source, rc_operation_target,
    rc_op_kind_cleanup, rc_op_kind_same,
    rc_semantic_site_operand_ordinal}
use resource_certificate::{
    ResourceCellKind, ResourceCellSpec, ResourceConstraint, ResourcePromotion,
    ResourceFixedPointProof, ResourceCertificate,
    CandidateCellKind, CandidateCellSpec, CandidateRuleSite,
    CandidateRuleKind, CandidateRule, CandidatePromotion,
    CandidateSelection, CallableCandidateProof,
    CfgBodyCertificate, CfgBlockCertificate,
    CfgStepCertificate, CfgEdgeCertificate,
    SlotTransitionReason, SlotTransitionWitness,
    make_resource_cell_spec, make_resource_constraint,
    make_resource_promotion, make_resource_fixed_point_proof,
    make_resource_certificate,
    make_candidate_cell_spec,
    make_global_candidate_rule_site,
    make_instruction_candidate_rule_site,
    make_terminator_candidate_rule_site,
    make_edge_candidate_rule_site,
    make_candidate_rule, make_candidate_promotion,
    make_candidate_selection, make_callable_candidate_proof,
    candidate_cell_parameter, candidate_cell_result,
    candidate_cell_state, candidate_rule_seed,
    candidate_rule_copy, candidate_rule_all,
    make_cfg_body_certificate, make_cfg_block_certificate,
    make_cfg_step_certificate,
    make_cfg_edge_certificate, make_slot_transition_witness,
    resource_cell_kind_logical_shape,
    resource_cell_kind_physical_shape,
    resource_cell_kind_callable_param_mode,
    resource_cell_kind_callable_force,
    resource_cell_kind_callable_result,
    resource_cell_spec_max_rank,
    resource_cell_spec_kind, resource_cell_spec_owner_index,
    resource_cell_spec_component_index, resource_cell_kind_tag,
    resource_constraint_rule_tag,
    resource_constraint_target_cell,
    resource_constraint_floor_rank,
    resource_constraint_premise_cells,
    resource_fixed_point_final_ranks,
    resource_fixed_point_cells, resource_fixed_point_constraints,
    resource_certificate_fixed_point,
    resource_certificate_candidate_proof,
    resource_certificate_cfg_bodies,
    cfg_body_certificate_blocks,
    cfg_body_certificate_entry_block,
    cfg_block_certificate_index, cfg_block_certificate_source_block,
    cfg_block_certificate_terminator_kind,
    cfg_block_certificate_entry_states,
    cfg_block_certificate_steps, cfg_block_certificate_edges,
    cfg_step_certificate_instruction,
    cfg_edge_certificate_successor_ordinal,
    cfg_edge_certificate_target,
    callable_candidate_proof_callable_count,
    callable_candidate_proof_cells,
    callable_candidate_proof_rules,
    callable_candidate_proof_promotions,
    callable_candidate_proof_final_values,
    callable_candidate_proof_selections,
    candidate_cell_spec_kind, candidate_cell_spec_owner,
    candidate_cell_spec_block, candidate_cell_spec_boundary,
    candidate_cell_spec_component, candidate_cell_spec_candidate,
    candidate_cell_kind_tag,
    candidate_rule_kind, candidate_rule_site,
    candidate_rule_target_cell, candidate_rule_premise_cells,
    candidate_rule_kind_tag, candidate_rule_site_kind_tag,
    candidate_rule_site_instruction, candidate_rule_site_block,
    candidate_rule_site_successor_ordinal,
    candidate_selection_instruction, candidate_selection_candidates,
    slot_reason_init_empty, slot_reason_init_live,
    slot_reason_borrow, slot_reason_mutate,
    slot_reason_clone_source, slot_reason_clone_target,
    slot_reason_take_source, slot_reason_take_target,
    slot_reason_drop, slot_reason_cleanup,
    slot_reason_assign_scalar, slot_reason_call_result,
    slot_reason_scope_end, slot_reason_drop_projected_old,
    verify_resource_certificate}

// ============================================================
// Frozen FlowIR adapter: type graph
// ============================================================

// The adapter uses semantic categories, never display names.  Nominal/tuple/
// record/callable representation facts arrive as primitive seeds plus exact
// child edges.  ResourcePlanner alone computes transitive shapes.
const PLANNER_TYPE_ATOMIC: Int = 0
const PLANNER_TYPE_PTR: Int = 1
const PLANNER_TYPE_EXTERN: Int = 2
const PLANNER_TYPE_NOMINAL: Int = 3
const PLANNER_TYPE_TUPLE: Int = 4
const PLANNER_TYPE_RECORD: Int = 5
const PLANNER_TYPE_CALLABLE: Int = 6
const PLANNER_TYPE_PARAMETER: Int = 7
const PLANNER_TYPE_OPTION: Int = 8
const PLANNER_TYPE_KIND_COUNT: Int = 9

pub struct PlannerTypeKind { tag: Int }

pub fn planner_type_kind_from_tag(tag: Int) -> PlannerTypeKind {
    if tag < PLANNER_TYPE_ATOMIC || tag >= PLANNER_TYPE_KIND_COUNT {
        panic("ResourcePlanner: unknown FlowIR type kind")
    }
    PlannerTypeKind { tag: tag }
}

pub fn planner_type_kind_atomic() -> PlannerTypeKind {
    planner_type_kind_from_tag(PLANNER_TYPE_ATOMIC)
}
pub fn planner_type_kind_ptr() -> PlannerTypeKind {
    planner_type_kind_from_tag(PLANNER_TYPE_PTR)
}
pub fn planner_type_kind_extern() -> PlannerTypeKind {
    planner_type_kind_from_tag(PLANNER_TYPE_EXTERN)
}
pub fn planner_type_kind_nominal() -> PlannerTypeKind {
    planner_type_kind_from_tag(PLANNER_TYPE_NOMINAL)
}
pub fn planner_type_kind_tuple() -> PlannerTypeKind {
    planner_type_kind_from_tag(PLANNER_TYPE_TUPLE)
}
pub fn planner_type_kind_record() -> PlannerTypeKind {
    planner_type_kind_from_tag(PLANNER_TYPE_RECORD)
}
pub fn planner_type_kind_callable() -> PlannerTypeKind {
    planner_type_kind_from_tag(PLANNER_TYPE_CALLABLE)
}
pub fn planner_type_kind_parameter() -> PlannerTypeKind {
    planner_type_kind_from_tag(PLANNER_TYPE_PARAMETER)
}
pub fn planner_type_kind_option() -> PlannerTypeKind {
    planner_type_kind_from_tag(PLANNER_TYPE_OPTION)
}

fn planner_type_kind_tag(kind: PlannerTypeKind) -> Int {
    planner_type_kind_from_tag(kind.tag).tag
}

enum PlannerDependencyTargetValue {
    ParentParameterTargetValue(Int),
    ConcreteTypeTargetValue(Int)
}

pub struct PlannerResourceDependency {
    child_type_index: Int,
    child_dependency_ordinal: Int,
    target: PlannerDependencyTargetValue
}

pub fn make_parent_resource_dependency(
    child_type_index: Int, child_dependency_ordinal: Int,
    parent_parameter_ordinal: Int
) -> PlannerResourceDependency {
    if child_type_index < 0 || child_dependency_ordinal < 0 ||
       parent_parameter_ordinal < 0 {
        panic("ResourcePlanner: negative parent resource dependency")
    }
    PlannerResourceDependency {
        child_type_index: child_type_index,
        child_dependency_ordinal: child_dependency_ordinal,
        target: PlannerDependencyTargetValue::ParentParameterTargetValue(
            parent_parameter_ordinal)
    }
}

pub fn make_concrete_resource_dependency(
    child_type_index: Int, child_dependency_ordinal: Int,
    concrete_type_index: Int
) -> PlannerResourceDependency {
    if child_type_index < 0 || child_dependency_ordinal < 0 ||
       concrete_type_index < 0 {
        panic("ResourcePlanner: negative concrete resource dependency")
    }
    PlannerResourceDependency {
        child_type_index: child_type_index,
        child_dependency_ordinal: child_dependency_ordinal,
        target: PlannerDependencyTargetValue::ConcreteTypeTargetValue(
            concrete_type_index)
    }
}

fn copy_resource_dependencies(
    values: List<PlannerResourceDependency>
) -> List<PlannerResourceDependency> {
    let mut result: List<PlannerResourceDependency> = []
    for value in values {
        match value.target {
            PlannerDependencyTargetValue::ParentParameterTargetValue(parent) =>
                result.push(make_parent_resource_dependency(
                    value.child_type_index,
                    value.child_dependency_ordinal, parent)),
            PlannerDependencyTargetValue::ConcreteTypeTargetValue(concrete) =>
                result.push(make_concrete_resource_dependency(
                    value.child_type_index,
                    value.child_dependency_ordinal, concrete))
        }
    }
    result
}

pub struct PlannerTypeNode {
    kind: PlannerTypeKind,
    child_type_indices: List<Int>,
    resource_dependencies: List<PlannerResourceDependency>,
    type_parameter_count: Int,
    parameter_index: Int?,
    direct_drop_seed: Bool,
    may_unique_seed: Bool,
    physical_rc_seed: Bool,
    boxing_seed: Bool,
    drop_glue_seed: Bool,
    foreign_containment_seed: Bool
}

pub fn make_planner_type_node(
    kind: PlannerTypeKind, child_type_indices: List<Int>,
    resource_dependencies: List<PlannerResourceDependency>,
    type_parameter_count: Int, parameter_index: Int?,
    direct_drop_seed: Bool, may_unique_seed: Bool,
    physical_rc_seed: Bool, boxing_seed: Bool,
    drop_glue_seed: Bool, foreign_containment_seed: Bool
) -> PlannerTypeNode {
    if type_parameter_count < 0 {
        panic("ResourcePlanner: negative type-parameter census")
    }
    if direct_drop_seed && !may_unique_seed {
        panic("ResourcePlanner: direct Drop type is not unique-capable")
    }
    let is_parameter = planner_type_kind_tag(kind) == PLANNER_TYPE_PARAMETER
    match parameter_index {
        some(index) => if !is_parameter || index < 0 ||
                          index >= type_parameter_count {
            panic("ResourcePlanner: invalid type-parameter node")
        },
        none => if is_parameter {
            panic("ResourcePlanner: type-parameter node lacks exact index")
        }
    }
    if (planner_type_kind_tag(kind) == PLANNER_TYPE_ATOMIC ||
        planner_type_kind_tag(kind) == PLANNER_TYPE_PTR ||
        planner_type_kind_tag(kind) == PLANNER_TYPE_EXTERN ||
        planner_type_kind_tag(kind) == PLANNER_TYPE_PARAMETER) &&
       child_type_indices.len() != 0 {
        panic("ResourcePlanner: leaf type has child edges")
    }
    let mut children: List<Int> = []
    for child in child_type_indices {
        if child < 0 { panic("ResourcePlanner: negative type edge") }
        children.push(child)
    }
    let dependencies = copy_resource_dependencies(resource_dependencies)
    for dependency in dependencies {
        if !int_list_contains(children, dependency.child_type_index) {
            panic("ResourcePlanner: resource dependency names a non-child type")
        }
        match dependency.target {
            PlannerDependencyTargetValue::ParentParameterTargetValue(index) =>
                if index >= type_parameter_count {
                    panic("ResourcePlanner: dependency target escapes parent parameters")
                },
            PlannerDependencyTargetValue::ConcreteTypeTargetValue(_) => {}
        }
    }
    PlannerTypeNode {
        kind: kind,
        child_type_indices: children,
        resource_dependencies: dependencies,
        type_parameter_count: type_parameter_count,
        parameter_index: parameter_index,
        direct_drop_seed: direct_drop_seed,
        may_unique_seed: may_unique_seed,
        physical_rc_seed: physical_rc_seed,
        boxing_seed: boxing_seed,
        drop_glue_seed: drop_glue_seed,
        foreign_containment_seed: foreign_containment_seed
    }
}

fn copy_planner_type_nodes(values: List<PlannerTypeNode>) -> List<PlannerTypeNode> {
    let mut result: List<PlannerTypeNode> = []
    for value in values {
        result.push(make_planner_type_node(
            value.kind, value.child_type_indices,
            value.resource_dependencies,
            value.type_parameter_count, value.parameter_index,
            value.direct_drop_seed, value.may_unique_seed,
            value.physical_rc_seed, value.boxing_seed,
            value.drop_glue_seed, value.foreign_containment_seed))
    }
    result
}

// ============================================================
// Frozen FlowIR adapter: callable graph
// ============================================================

pub struct PlannerArgumentSource { parameter_indices: List<Int> }

pub fn make_caller_parameter_sources(
    parameter_indices: List<Int>
) -> PlannerArgumentSource {
    let mut copied: List<Int> = []
    for index in parameter_indices {
        if index < 0 || int_list_contains(copied, index) {
            panic("ResourcePlanner: invalid caller parameter origin set")
        }
        copied.push(index)
    }
    PlannerArgumentSource { parameter_indices: copied }
}

pub fn make_caller_parameter_source(index: Int) -> PlannerArgumentSource {
    if index < 0 { panic("ResourcePlanner: negative caller parameter index") }
    make_caller_parameter_sources([index])
}

pub fn make_local_argument_source() -> PlannerArgumentSource {
    make_caller_parameter_sources([])
}

fn planner_argument_source_parameters(
    value: PlannerArgumentSource
) -> List<Int> {
    let mut result: List<Int> = []
    for index in value.parameter_indices { result.push(index) }
    result
}

pub struct PlannerCallEdge {
    callee_index: Int,
    argument_sources: List<PlannerArgumentSource>,
    forwards_result: Bool
}

pub fn make_planner_call_edge(
    callee_index: Int, argument_sources: List<PlannerArgumentSource>,
    forwards_result: Bool
) -> PlannerCallEdge {
    if callee_index < 0 {
        panic("ResourcePlanner: negative exact callee index")
    }
    let mut sources: List<PlannerArgumentSource> = []
    for source in argument_sources {
        sources.push(make_caller_parameter_sources(
            source.parameter_indices))
    }
    PlannerCallEdge {
        callee_index: callee_index,
        argument_sources: sources,
        forwards_result: forwards_result
    }
}

pub struct PlannerCallable {
    reference: ExecutableRef,
    parameter_type_indices: List<Int>,
    result_type_index: Int,
    parameter_seeds: List<TransferDemand>,
    result_owned_seed: Bool,
    result_origin_parameter_ordinals: List<Int>,
    call_edges: List<PlannerCallEdge>,
    has_body: Bool
}

pub fn make_planner_callable(
    reference: ExecutableRef,
    parameter_type_indices: List<Int>, result_type_index: Int,
    parameter_seeds: List<TransferDemand>, result_owned_seed: Bool,
    result_origin_parameter_ordinals: List<Int>,
    call_edges: List<PlannerCallEdge>, has_body: Bool
) -> PlannerCallable {
    if result_type_index < 0 ||
       parameter_type_indices.len() != parameter_seeds.len() {
        panic("ResourcePlanner: callable signature census differs")
    }
    let mut parameter_types: List<Int> = []
    let mut seeds: List<TransferDemand> = []
    for index in parameter_type_indices {
        if index < 0 { panic("ResourcePlanner: negative parameter type index") }
        parameter_types.push(index)
    }
    for seed in parameter_seeds {
        if param_mode_is_conflict(transfer_demand_mode(seed)) {
            panic("ResourcePlanner: callable seed contains mode conflict")
        }
        seeds.push(make_transfer_demand(
            transfer_demand_mode(seed), transfer_demand_force(seed)))
    }
    let mut result_origins: List<Int> = []
    for ordinal in result_origin_parameter_ordinals {
        if ordinal < 0 || ordinal >= parameter_types.len() ||
           int_list_contains(result_origins, ordinal) {
            panic("ResourcePlanner: callable result origin set is invalid")
        }
        result_origins.push(ordinal)
    }
    let mut edges: List<PlannerCallEdge> = []
    for edge in call_edges {
        edges.push(make_planner_call_edge(
            edge.callee_index, edge.argument_sources, edge.forwards_result))
    }
    PlannerCallable {
        reference: reference,
        parameter_type_indices: parameter_types,
        result_type_index: result_type_index,
        parameter_seeds: seeds,
        result_owned_seed: result_owned_seed,
        result_origin_parameter_ordinals: result_origins,
        call_edges: edges,
        has_body: has_body
    }
}

fn copy_planner_callables(values: List<PlannerCallable>) -> List<PlannerCallable> {
    let mut result: List<PlannerCallable> = []
    for value in values {
        result.push(make_planner_callable(
            value.reference, value.parameter_type_indices,
            value.result_type_index, value.parameter_seeds,
            value.result_owned_seed,
            value.result_origin_parameter_ordinals,
            value.call_edges, value.has_body))
    }
    result
}

// ============================================================
// Frozen FlowIR adapter: body, slots, operations, CFG edges
// ============================================================

pub struct PlannerScope {
    scope_id: Int,
    depth: Int
}

pub fn make_planner_scope(scope_id: Int, depth: Int) -> PlannerScope {
    if scope_id < 0 || depth < 0 {
        panic("ResourcePlanner: invalid frozen scope metadata")
    }
    PlannerScope { scope_id: scope_id, depth: depth }
}

fn copy_planner_scopes(values: List<PlannerScope>) -> List<PlannerScope> {
    let mut result: List<PlannerScope> = []
    for value in values {
        result.push(make_planner_scope(value.scope_id, value.depth))
    }
    result
}

pub struct PlannerSlot {
    reference: SlotRef,
    type_index: Int,
    scope_id: Int,
    scope_depth: Int,
    reverse_lexical_ordinal: Int,
    parameter_ordinal: Int?,
    initially_live: Bool,
    owns_storage: Bool
}

pub fn make_planner_slot(
    reference: SlotRef, type_index: Int,
    scope_id: Int, scope_depth: Int,
    reverse_lexical_ordinal: Int,
    parameter_ordinal: Int?,
    initially_live: Bool, owns_storage: Bool
) -> PlannerSlot {
    if type_index < 0 || scope_id < 0 || scope_depth < 0 ||
       reverse_lexical_ordinal < 0 {
        panic("ResourcePlanner: invalid frozen slot metadata")
    }
    match parameter_ordinal {
        some(index) => if index < 0 {
            panic("ResourcePlanner: negative parameter ordinal")
        },
        none => {}
    }
    PlannerSlot {
        reference: reference,
        type_index: type_index,
        scope_id: scope_id,
        scope_depth: scope_depth,
        reverse_lexical_ordinal: reverse_lexical_ordinal,
        parameter_ordinal: parameter_ordinal,
        initially_live: initially_live,
        owns_storage: owns_storage
    }
}

fn copy_planner_slots(values: List<PlannerSlot>) -> List<PlannerSlot> {
    let mut result: List<PlannerSlot> = []
    for value in values {
        result.push(make_planner_slot(
            value.reference, value.type_index, value.scope_id,
            value.scope_depth, value.reverse_lexical_ordinal,
            value.parameter_ordinal,
            value.initially_live, value.owns_storage))
    }
    result
}

enum PlannerPlaceValue {
    SlotPlaceValue(Int),
    ProjectPlaceValue {
        base: Int,
        has_static_projection: Bool,
        evaluated_index: Int?,
        value_type_index: Int
    }
}

pub struct PlannerPlace { value: PlannerPlaceValue }

pub fn make_planner_slot_place(slot: Int) -> PlannerPlace {
    if slot < 0 { panic("ResourcePlanner: negative slot place") }
    PlannerPlace { value: PlannerPlaceValue::SlotPlaceValue(slot) }
}

pub fn make_planner_project_place(
    base: Int, has_static_projection: Bool,
    evaluated_index: Int?, value_type_index: Int
) -> PlannerPlace {
    if base < 0 || value_type_index < 0 {
        panic("ResourcePlanner: invalid projected place")
    }
    match evaluated_index {
        some(index) => if index < 0 {
            panic("ResourcePlanner: negative evaluated place index")
        },
        none => {}
    }
    if has_static_projection == evaluated_index.is_some() {
        panic("ResourcePlanner: projected place must select field xor index")
    }
    PlannerPlace {
        value: PlannerPlaceValue::ProjectPlaceValue {
            base: base, has_static_projection: has_static_projection,
            evaluated_index: evaluated_index,
            value_type_index: value_type_index
        }
    }
}

fn copy_planner_place(value: PlannerPlace) -> PlannerPlace {
    match value.value {
        PlannerPlaceValue::SlotPlaceValue(slot) =>
            make_planner_slot_place(slot),
        PlannerPlaceValue::ProjectPlaceValue {
            base, has_static_projection, evaluated_index, value_type_index
        } => make_planner_project_place(
            base, has_static_projection, evaluated_index, value_type_index)
    }
}

fn planner_place_is_slot(value: PlannerPlace) -> Bool {
    match value.value {
        PlannerPlaceValue::SlotPlaceValue(_) => true,
        PlannerPlaceValue::ProjectPlaceValue { .. } => false
    }
}

fn planner_place_slot(value: PlannerPlace) -> Int {
    match value.value {
        PlannerPlaceValue::SlotPlaceValue(slot) => slot,
        _ => panic("ResourcePlanner: projected place has no target slot")
    }
}

fn planner_place_base(value: PlannerPlace) -> Int {
    match value.value {
        PlannerPlaceValue::ProjectPlaceValue { base, .. } => base,
        _ => panic("ResourcePlanner: slot place has no projection base")
    }
}

fn planner_place_evaluated_index(value: PlannerPlace) -> Int? {
    match value.value {
        PlannerPlaceValue::ProjectPlaceValue { evaluated_index, .. } =>
            evaluated_index,
        _ => panic("ResourcePlanner: slot place has no evaluated index")
    }
}

fn planner_place_value_type(value: PlannerPlace) -> Int {
    match value.value {
        PlannerPlaceValue::ProjectPlaceValue { value_type_index, .. } =>
            value_type_index,
        _ => panic("ResourcePlanner: slot place type comes from slot table")
    }
}

enum PlannerCallTargetValue {
    DirectCallTargetValue(Int),
    SlotCallTargetValue(Int)
}

pub struct PlannerCallTarget { value: PlannerCallTargetValue }

pub fn make_planner_direct_call_target(index: Int) -> PlannerCallTarget {
    if index < 0 { panic("ResourcePlanner: negative direct callable index") }
    PlannerCallTarget {
        value: PlannerCallTargetValue::DirectCallTargetValue(index)
    }
}

pub fn make_planner_slot_call_target(slot: Int) -> PlannerCallTarget {
    if slot < 0 { panic("ResourcePlanner: negative callable slot index") }
    PlannerCallTarget {
        value: PlannerCallTargetValue::SlotCallTargetValue(slot)
    }
}

fn copy_planner_call_target(value: PlannerCallTarget) -> PlannerCallTarget {
    match value.value {
        PlannerCallTargetValue::DirectCallTargetValue(index) =>
            make_planner_direct_call_target(index),
        PlannerCallTargetValue::SlotCallTargetValue(slot) =>
            make_planner_slot_call_target(slot)
    }
}

fn planner_call_target_is_direct(value: PlannerCallTarget) -> Bool {
    match value.value {
        PlannerCallTargetValue::DirectCallTargetValue(_) => true,
        PlannerCallTargetValue::SlotCallTargetValue(_) => false
    }
}

fn planner_call_target_direct(value: PlannerCallTarget) -> Int {
    match value.value {
        PlannerCallTargetValue::DirectCallTargetValue(index) => index,
        _ => panic("ResourcePlanner: slot call target has no direct callable")
    }
}

fn planner_call_target_slot(value: PlannerCallTarget) -> Int {
    match value.value {
        PlannerCallTargetValue::SlotCallTargetValue(slot) => slot,
        _ => panic("ResourcePlanner: direct call target has no callable slot")
    }
}

enum PlannerEventValue {
    NoOpValue,
    ScopeExitValue(Int),
    InitializeValue {
        input_slots: List<Int>,
        input_demands: List<TransferDemand>,
        origin_input_ordinals: List<Int>,
        target: Int
    },
    InitializeEmptyValue(Int),
    InitializeLiveValue(Int),
    ReadValue { source: Int, target: Int },
    MutateValue {
        target: Int,
        value: Int,
        value_demand: TransferDemand
    },
    ConsumeValue(Int, Bool, Int?),
    DiscardValue(Int),
    AssignValue { rhs_temp: Int, target: PlannerPlace },
    CallValue {
        call_target: PlannerCallTarget,
        callable_indices: List<Int>,
        argument_demands: List<TransferDemand>,
        result_owned: Bool,
        result_type_index: Int,
        result_origin_argument_ordinals: List<Int>,
        argument_slots: List<Int>,
        result_slot: Int?
    },
    ProjectValue {
        source: Int,
        target: Int,
        whole_slot: Bool
    },
    CaptureValue {
        source: Int,
        target: Int,
        demand: TransferDemand
    }
}

enum PlannerCallableOriginValue {
    DirectCallableOriginValue(Int),
    SlotCallableOriginValue(List<Int>),
    CallCallableOriginValue {
        target: PlannerCallTarget,
        arguments: List<Int>
    }
}

pub struct PlannerCallableProvenance {
    target: Int,
    origin: PlannerCallableOriginValue
}

fn make_direct_planner_callable_provenance(
    target: Int, callable: Int
) -> PlannerCallableProvenance {
    if target < 0 || callable < 0 {
        panic("ResourcePlanner: negative direct callable provenance")
    }
    PlannerCallableProvenance {
        target: target,
        origin: PlannerCallableOriginValue::DirectCallableOriginValue(callable)
    }
}

fn make_slots_planner_callable_provenance(
    target: Int, sources: List<Int>
) -> PlannerCallableProvenance {
    if target < 0 || sources.len() == 0 {
        panic("ResourcePlanner: callable slot provenance is empty")
    }
    let mut copied: List<Int> = []
    for source in sources {
        if source < 0 || int_list_contains(copied, source) {
            panic("ResourcePlanner: callable slot provenance is invalid")
        }
        copied.push(source)
    }
    PlannerCallableProvenance {
        target: target,
        origin: PlannerCallableOriginValue::SlotCallableOriginValue(copied)
    }
}

fn make_call_planner_callable_provenance(
    target: Int, call_target: PlannerCallTarget, arguments: List<Int>
) -> PlannerCallableProvenance {
    if target < 0 { panic("ResourcePlanner: negative call result provenance") }
    let mut copied: List<Int> = []
    for argument in arguments {
        if argument < 0 { panic("ResourcePlanner: negative provenance argument") }
        copied.push(argument)
    }
    PlannerCallableProvenance {
        target: target,
        origin: PlannerCallableOriginValue::CallCallableOriginValue {
            target: copy_planner_call_target(call_target), arguments: copied
        }
    }
}

fn copy_planner_callable_provenance(
    values: List<PlannerCallableProvenance>
) -> List<PlannerCallableProvenance> {
    let mut result: List<PlannerCallableProvenance> = []
    for value in values {
        match value.origin {
            PlannerCallableOriginValue::DirectCallableOriginValue(callable) =>
                result.push(make_direct_planner_callable_provenance(
                    value.target, callable)),
            PlannerCallableOriginValue::SlotCallableOriginValue(sources) =>
                result.push(make_slots_planner_callable_provenance(
                    value.target, sources)),
            PlannerCallableOriginValue::CallCallableOriginValue {
                target, arguments
            } => result.push(make_call_planner_callable_provenance(
                value.target, target, arguments))
        }
    }
    result
}

pub struct PlannerEvent {
    value: PlannerEventValue,
    callable_provenance: List<PlannerCallableProvenance>
}

fn make_planner_event(value: PlannerEventValue) -> PlannerEvent {
    PlannerEvent { value: value, callable_provenance: [] }
}

fn with_planner_callable_provenance(
    value: PlannerEvent, provenance: List<PlannerCallableProvenance>
) -> PlannerEvent {
    PlannerEvent {
        value: value.value,
        callable_provenance: copy_planner_callable_provenance(provenance)
    }
}

pub fn make_planner_noop() -> PlannerEvent {
    make_planner_event(PlannerEventValue::NoOpValue)
}

pub fn make_planner_scope_exit(scope_id: Int) -> PlannerEvent {
    if scope_id < 0 { panic("ResourcePlanner: negative lexical scope exit") }
    make_planner_event(PlannerEventValue::ScopeExitValue(scope_id))
}

pub fn make_planner_initialize(
    input_slots: List<Int>, input_demands: List<TransferDemand>,
    origin_input_ordinals: List<Int>, target: Int
) -> PlannerEvent {
    if input_slots.len() != input_demands.len() {
        panic("ResourcePlanner: initialize input/demand census differs")
    }
    let mut slots: List<Int> = []
    let mut demands: List<TransferDemand> = []
    let mut origins: List<Int> = []
    for slot in input_slots { slots.push(slot) }
    for demand in input_demands {
        if param_mode_is_conflict(transfer_demand_mode(demand)) {
            panic("ResourcePlanner: initialize demand is conflicting")
        }
        demands.push(make_transfer_demand(
            transfer_demand_mode(demand), transfer_demand_force(demand)))
    }
    for ordinal in origin_input_ordinals {
        if ordinal < 0 || ordinal >= slots.len() ||
           int_list_contains(origins, ordinal) {
            panic("ResourcePlanner: Initialize origin input set is invalid")
        }
        origins.push(ordinal)
    }
    make_planner_event(PlannerEventValue::InitializeValue {
            input_slots: slots, input_demands: demands,
            origin_input_ordinals: origins, target: target
        })
}

pub fn make_planner_initialize_empty(slot: Int) -> PlannerEvent {
    make_planner_event(PlannerEventValue::InitializeEmptyValue(slot))
}
pub fn make_planner_initialize_live(slot: Int) -> PlannerEvent {
    make_planner_event(PlannerEventValue::InitializeLiveValue(slot))
}
pub fn make_planner_read(source: Int, target: Int) -> PlannerEvent {
    make_planner_event(PlannerEventValue::ReadValue {
            source: source, target: target
        })
}
pub fn make_planner_mutate(
    target: Int, value: Int, value_demand: TransferDemand
) -> PlannerEvent {
    if param_mode_is_conflict(transfer_demand_mode(value_demand)) {
        panic("ResourcePlanner: mutate value demand is conflicting")
    }
    make_planner_event(PlannerEventValue::MutateValue {
            target: target, value: value,
            value_demand: make_transfer_demand(
                transfer_demand_mode(value_demand),
                transfer_demand_force(value_demand))
        })
}
pub fn make_planner_consume(
    slot: Int, force: Bool, target: Int?
) -> PlannerEvent {
    match target {
        some(value) => if value < 0 || value == slot {
            panic("ResourcePlanner: Consume target is invalid")
        },
        none => {}
    }
    make_planner_event(PlannerEventValue::ConsumeValue(slot, force, target))
}
pub fn make_planner_discard(slot: Int) -> PlannerEvent {
    make_planner_event(PlannerEventValue::DiscardValue(slot))
}
pub fn make_planner_assign(
    rhs_temp: Int, target: PlannerPlace
) -> PlannerEvent {
    if rhs_temp < 0 ||
       (planner_place_is_slot(target) &&
        rhs_temp == planner_place_slot(target)) {
        panic("ResourcePlanner: Assign RHS aliases target place")
    }
    make_planner_event(PlannerEventValue::AssignValue {
        rhs_temp: rhs_temp, target: copy_planner_place(target)
    })
}
pub fn make_planner_call(
    call_target: PlannerCallTarget,
    callable_indices: List<Int>, argument_slots: List<Int>,
    argument_demands: List<TransferDemand>,
    result_owned: Bool, result_type_index: Int,
    result_origin_argument_ordinals: List<Int>, result_slot: Int?
) -> PlannerEvent {
    if argument_slots.len() != argument_demands.len() ||
       result_type_index < 0 {
        panic("ResourcePlanner: call contract is incomplete")
    }
    let mut candidates: List<Int> = []
    let mut arguments: List<Int> = []
    let mut demands: List<TransferDemand> = []
    let mut result_origins: List<Int> = []
    for candidate in callable_indices {
        if candidate < 0 || int_list_contains(candidates, candidate) {
            panic("ResourcePlanner: call candidate set is invalid")
        }
        candidates.push(candidate)
    }
    for slot in argument_slots { arguments.push(slot) }
    for demand in argument_demands {
        if param_mode_is_conflict(transfer_demand_mode(demand)) {
            panic("ResourcePlanner: call argument demand is conflicting")
        }
        demands.push(make_transfer_demand(
            transfer_demand_mode(demand), transfer_demand_force(demand)))
    }
    for ordinal in result_origin_argument_ordinals {
        if ordinal < 0 || ordinal >= arguments.len() ||
           int_list_contains(result_origins, ordinal) {
            panic("ResourcePlanner: call result origin set is invalid")
        }
        result_origins.push(ordinal)
    }
    make_planner_event(PlannerEventValue::CallValue {
            call_target: copy_planner_call_target(call_target),
            callable_indices: candidates,
            argument_demands: demands,
            result_owned: result_owned,
            result_type_index: result_type_index,
            result_origin_argument_ordinals: result_origins,
            argument_slots: arguments,
            result_slot: result_slot
        })
}
pub fn make_planner_project(
    source: Int, target: Int, whole_slot: Bool
) -> PlannerEvent {
    make_planner_event(PlannerEventValue::ProjectValue {
            source: source, target: target, whole_slot: whole_slot
        })
}
pub fn make_planner_capture(
    source: Int, target: Int, demand: TransferDemand
) -> PlannerEvent {
    if param_mode_is_conflict(transfer_demand_mode(demand)) {
        panic("ResourcePlanner: capture demand is conflicting")
    }
    make_planner_event(PlannerEventValue::CaptureValue {
            source: source,
            target: target,
            demand: make_transfer_demand(
                transfer_demand_mode(demand),
                transfer_demand_force(demand))
        })
}

fn copy_planner_event(value: PlannerEvent) -> PlannerEvent {
    let copied = match value.value {
        PlannerEventValue::NoOpValue => make_planner_noop(),
        PlannerEventValue::ScopeExitValue(scope_id) =>
            make_planner_scope_exit(scope_id),
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, origin_input_ordinals, target
        } => make_planner_initialize(
            input_slots, input_demands, origin_input_ordinals, target),
        PlannerEventValue::InitializeEmptyValue(slot) =>
            make_planner_initialize_empty(slot),
        PlannerEventValue::InitializeLiveValue(slot) =>
            make_planner_initialize_live(slot),
        PlannerEventValue::ReadValue { source, target } =>
            make_planner_read(source, target),
        PlannerEventValue::MutateValue {
            target, value: input, value_demand
        } => make_planner_mutate(target, input, value_demand),
        PlannerEventValue::ConsumeValue(slot, force, target) =>
            make_planner_consume(slot, force, target),
        PlannerEventValue::DiscardValue(slot) => make_planner_discard(slot),
        PlannerEventValue::AssignValue { rhs_temp, target } =>
            make_planner_assign(rhs_temp, target),
        PlannerEventValue::CallValue {
            call_target, callable_indices, argument_demands,
            result_owned, result_type_index,
            result_origin_argument_ordinals,
            argument_slots, result_slot
        } => make_planner_call(
            call_target, callable_indices,
            argument_slots, argument_demands,
            result_owned, result_type_index,
            result_origin_argument_ordinals, result_slot),
        PlannerEventValue::ProjectValue {
            source, target, whole_slot
        } => make_planner_project(source, target, whole_slot),
        PlannerEventValue::CaptureValue { source, target, demand } =>
            make_planner_capture(source, target, demand)
    }
    with_planner_callable_provenance(copied, value.callable_provenance)
}

pub struct PlannerEdge {
    target_block: Int?,
    exited_scope_ids: List<Int>
}

pub fn make_planner_edge(
    target_block: Int?, exited_scope_ids: List<Int>
) -> PlannerEdge {
    let mut scopes: List<Int> = []
    for scope in exited_scope_ids {
        if scope < 0 { panic("ResourcePlanner: negative exited scope") }
        for existing in scopes {
            if existing == scope {
                panic("ResourcePlanner: duplicate exited scope")
            }
        }
        scopes.push(scope)
    }
    PlannerEdge { target_block: target_block, exited_scope_ids: scopes }
}

pub struct PlannerTerminatorUse {
    slot: Int,
    demand: TransferDemand
}

pub fn make_planner_terminator_use(
    slot: Int, demand: TransferDemand
) -> PlannerTerminatorUse {
    if slot < 0 || param_mode_is_conflict(transfer_demand_mode(demand)) {
        panic("ResourcePlanner: invalid terminator value edge")
    }
    PlannerTerminatorUse {
        slot: slot,
        demand: make_transfer_demand(
            transfer_demand_mode(demand), transfer_demand_force(demand))
    }
}

pub struct PlannerBlock {
    terminator_kind: Int,
    events: List<PlannerEvent>,
    terminator_uses: List<PlannerTerminatorUse>,
    edges: List<PlannerEdge>
}

pub fn make_planner_block(
    terminator_kind: Int, events: List<PlannerEvent>,
    terminator_uses: List<PlannerTerminatorUse>,
    edges: List<PlannerEdge>
) -> PlannerBlock {
    if terminator_kind < 0 {
        panic("ResourcePlanner: invalid frozen terminator kind")
    }
    let mut copied_events: List<PlannerEvent> = []
    let mut copied_uses: List<PlannerTerminatorUse> = []
    let mut copied_edges: List<PlannerEdge> = []
    for event in events { copied_events.push(copy_planner_event(event)) }
    for usage in terminator_uses {
        copied_uses.push(make_planner_terminator_use(
            usage.slot, usage.demand))
    }
    for edge in edges {
        copied_edges.push(make_planner_edge(
            edge.target_block, edge.exited_scope_ids))
    }
    PlannerBlock {
        terminator_kind: terminator_kind,
        events: copied_events,
        terminator_uses: copied_uses,
        edges: copied_edges
    }
}

pub struct PlannerBody {
    reference: ExecutableRef,
    scopes: List<PlannerScope>,
    slots: List<PlannerSlot>,
    entry_block: Int,
    blocks: List<PlannerBlock>
}

pub fn make_planner_body(
    reference: ExecutableRef, scopes: List<PlannerScope>,
    slots: List<PlannerSlot>,
    entry_block: Int, blocks: List<PlannerBlock>
) -> PlannerBody {
    let mut copied_blocks: List<PlannerBlock> = []
    for block in blocks {
        copied_blocks.push(make_planner_block(
            block.terminator_kind, block.events,
            block.terminator_uses, block.edges))
    }
    PlannerBody {
        reference: reference,
        scopes: copy_planner_scopes(scopes),
        slots: copy_planner_slots(slots),
        entry_block: entry_block,
        blocks: copied_blocks
    }
}

fn copy_planner_bodies(values: List<PlannerBody>) -> List<PlannerBody> {
    let mut result: List<PlannerBody> = []
    for value in values {
        result.push(make_planner_body(
            value.reference, value.scopes, value.slots,
            value.entry_block, value.blocks))
    }
    result
}

struct FrozenPlannerInput {
    flow_fingerprint: Str,
    candidate_proof: CallableCandidateProof,
    type_nodes: List<PlannerTypeNode>,
    callables: List<PlannerCallable>,
    bodies: List<PlannerBody>
}

fn validate_slot_index(index: Int, slots: List<PlannerSlot>) {
    if index < 0 || index >= slots.len() {
        panic("ResourcePlanner: event slot is outside frozen binder set")
    }
}

fn validate_event(
    event: PlannerEvent, slots: List<PlannerSlot>,
    scopes: List<PlannerScope>, callables: List<PlannerCallable>,
    type_nodes: List<PlannerTypeNode>
) {
    for fact in event.callable_provenance {
        validate_slot_index(fact.target, slots)
        if !planner_type_is_callable(
                type_nodes, slots.get(fact.target).unwrap().type_index) {
            panic("ResourcePlanner: callable provenance targets non-callable slot")
        }
        match fact.origin {
            PlannerCallableOriginValue::DirectCallableOriginValue(callable) =>
                if callable < 0 || callable >= callables.len() {
                    panic("ResourcePlanner: direct callable provenance is absent")
                },
            PlannerCallableOriginValue::SlotCallableOriginValue(sources) =>
                { for source in sources { validate_slot_index(source, slots) } },
            PlannerCallableOriginValue::CallCallableOriginValue {
                target, arguments
            } => {
                if planner_call_target_is_direct(target) {
                    let callable = planner_call_target_direct(target)
                    if callable < 0 || callable >= callables.len() {
                        panic("ResourcePlanner: provenance call target is absent")
                    }
                } else {
                    validate_slot_index(planner_call_target_slot(target), slots)
                }
                for argument in arguments {
                    validate_slot_index(argument, slots)
                }
            }
        }
    }
    match event.value {
        PlannerEventValue::NoOpValue => {},
        PlannerEventValue::ScopeExitValue(scope_id) => {
            if planner_scope_depth(scopes, scope_id).is_none() {
                panic("ResourcePlanner: scope-exit marker has no frozen scope")
            }
        },
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, target, ..
        } => {
            if input_slots.len() != input_demands.len() {
                panic("ResourcePlanner: initialize input/demand census differs")
            }
            for slot in input_slots { validate_slot_index(slot, slots) }
            validate_slot_index(target, slots)
        },
        PlannerEventValue::InitializeEmptyValue(slot) =>
            validate_slot_index(slot, slots),
        PlannerEventValue::InitializeLiveValue(slot) =>
            validate_slot_index(slot, slots),
        PlannerEventValue::ReadValue { source, target } => {
            validate_slot_index(source, slots)
            validate_slot_index(target, slots)
            if source == target {
                panic("ResourcePlanner: Read source and target are identical")
            }
        },
        PlannerEventValue::MutateValue {
            target, value: input, value_demand: _
        } => {
            validate_slot_index(target, slots)
            validate_slot_index(input, slots)
        },
        PlannerEventValue::ConsumeValue(slot, _, target) => {
            validate_slot_index(slot, slots)
            match target {
                some(value) => {
                    validate_slot_index(value, slots)
                    if !slots.get(value).unwrap().owns_storage ||
                       slots.get(value).unwrap().type_index !=
                            slots.get(slot).unwrap().type_index {
                        panic("ResourcePlanner: Consume sink does not own storage")
                    }
                },
                none => {}
            }
        },
        PlannerEventValue::DiscardValue(slot) =>
            validate_slot_index(slot, slots),
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            validate_slot_index(rhs_temp, slots)
            if !slots.get(rhs_temp).unwrap().owns_storage {
                panic("ResourcePlanner: Assign RHS lacks precreated owning storage")
            }
            if planner_place_is_slot(target) {
                let target_slot = planner_place_slot(target)
                validate_slot_index(target_slot, slots)
                if rhs_temp == target_slot ||
                   !slots.get(target_slot).unwrap().owns_storage ||
                   slots.get(rhs_temp).unwrap().type_index !=
                        slots.get(target_slot).unwrap().type_index {
                    panic("ResourcePlanner: direct Assign place contract differs")
                }
            } else {
                let base = planner_place_base(target)
                validate_slot_index(base, slots)
                match planner_place_evaluated_index(target) {
                    some(index) => validate_slot_index(index, slots),
                    none => {}
                }
                let value_type = planner_place_value_type(target)
                if value_type < 0 || value_type >= type_nodes.len() ||
                   slots.get(rhs_temp).unwrap().type_index != value_type {
                    panic("ResourcePlanner: projected Assign value type differs")
                }
            }
        },
        PlannerEventValue::CallValue {
            call_target, callable_indices, argument_demands,
            result_owned, result_type_index,
            argument_slots, result_slot, ..
        } => {
            if callable_indices.len() == 0 ||
               argument_slots.len() != argument_demands.len() ||
               result_type_index < 0 ||
               result_type_index >= type_nodes.len() {
                panic("ResourcePlanner: call contract is incomplete")
            }
            if planner_call_target_is_direct(call_target) {
                if callable_indices.len() != 1 ||
                   callable_indices.get(0).unwrap() !=
                        planner_call_target_direct(call_target) {
                    panic("ResourcePlanner: direct call candidate differs")
                }
            } else {
                let target_slot = planner_call_target_slot(call_target)
                validate_slot_index(target_slot, slots)
                if !planner_type_is_callable(
                        type_nodes, slots.get(target_slot).unwrap().type_index) {
                    panic("ResourcePlanner: indirect call target is not callable")
                }
            }
            for callable_index in callable_indices {
                if callable_index < 0 || callable_index >= callables.len() {
                    panic("ResourcePlanner: call lacks exact callable candidate")
                }
                if argument_slots.len() != callables.get(
                        callable_index).unwrap().parameter_type_indices.len() {
                    panic("ResourcePlanner: call candidate arity differs")
                }
                let candidate = callables.get(callable_index).unwrap()
                let mut argument = 0
                while argument < argument_slots.len() {
                    if slots.get(argument_slots.get(argument).unwrap()).unwrap().type_index !=
                           candidate.parameter_type_indices.get(argument).unwrap() ||
                       !transfer_demand_leq(
                            argument_demands.get(argument).unwrap(),
                            candidate.parameter_seeds.get(argument).unwrap()) {
                        panic("ResourcePlanner: derived callable contract differs")
                    }
                    argument = argument + 1
                }
                if result_type_index != candidate.result_type_index ||
                   result_owned != candidate.result_owned_seed {
                    panic("ResourcePlanner: derived callable result contract differs")
                }
            }
            for slot in argument_slots { validate_slot_index(slot, slots) }
            match result_slot {
                some(slot) => validate_slot_index(slot, slots),
                none => {}
            }
        },
        PlannerEventValue::ProjectValue {
            source, target, whole_slot: _
        } => {
            validate_slot_index(source, slots)
            validate_slot_index(target, slots)
            if source == target {
                panic("ResourcePlanner: projection aliases its source slot")
            }
        },
        PlannerEventValue::CaptureValue { source, target, demand } => {
            validate_slot_index(source, slots)
            validate_slot_index(target, slots)
            if source == target {
                panic("ResourcePlanner: capture aliases its source slot")
            }
            if slots.get(target).unwrap().owns_storage &&
               !param_mode_same(
                    transfer_demand_mode(demand), param_mode_own()) {
                panic("ResourcePlanner: owning capture lacks Own demand")
            }
        }
    }
}

fn planner_scope_depth(
    scopes: List<PlannerScope>, scope_id: Int
) -> Int? {
    let mut result: Int? = none
    for scope in scopes {
        if scope.scope_id == scope_id {
            match result {
                some(_) => {
                    panic("ResourcePlanner: one scope has multiple depths")
                },
                none => { result = some(scope.depth) }
            }
        }
    }
    result
}

fn validate_body(
    body: PlannerBody, type_nodes: List<PlannerTypeNode>,
    callables: List<PlannerCallable>
) {
    if body.blocks.len() == 0 || body.entry_block < 0 ||
       body.entry_block >= body.blocks.len() {
        panic("ResourcePlanner: body lacks a valid frozen entry block")
    }
    let mut scope_index = 0
    while scope_index < body.scopes.len() {
        let scope = body.scopes.get(scope_index).unwrap()
        let mut other = scope_index + 1
        while other < body.scopes.len() {
            if scope.scope_id == body.scopes.get(other).unwrap().scope_id {
                panic("ResourcePlanner: duplicate frozen scope")
            }
            other = other + 1
        }
        scope_index = scope_index + 1
    }
    let mut left_index = 0
    while left_index < body.slots.len() {
        let left = body.slots.get(left_index).unwrap()
        match planner_scope_depth(body.scopes, left.scope_id) {
            some(depth) => if depth != left.scope_depth {
                panic("ResourcePlanner: slot/scope depth differs")
            },
            none => panic("ResourcePlanner: slot has no frozen scope")
        }
        if left.type_index < 0 || left.type_index >= type_nodes.len() {
            panic("ResourcePlanner: slot type is outside frozen type graph")
        }
        let mut right_index = left_index + 1
        while right_index < body.slots.len() {
            let right = body.slots.get(right_index).unwrap()
            if slot_ref_same(left.reference, right.reference) {
                panic("ResourcePlanner: duplicate frozen slot")
            }
            if left.scope_id == right.scope_id &&
               left.reverse_lexical_ordinal ==
                   right.reverse_lexical_ordinal {
                panic("ResourcePlanner: reverse lexical slot order is ambiguous")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    for block in body.blocks {
        for event in block.events {
            validate_event(
                event, body.slots, body.scopes, callables, type_nodes)
        }
        for usage in block.terminator_uses {
            validate_slot_index(usage.slot, body.slots)
            if param_mode_same(
                    transfer_demand_mode(usage.demand),
                    param_mode_bottom()) {
                panic("ResourcePlanner: terminator value edge has Bottom demand")
            }
        }
        let mut previous_depth: Int? = none
        for edge in block.edges {
            match edge.target_block {
                some(target) => if target < 0 || target >= body.blocks.len() {
                    panic("ResourcePlanner: edge target is outside frozen CFG")
                },
                none => {}
            }
            previous_depth = none
            for scope_id in edge.exited_scope_ids {
                match planner_scope_depth(body.scopes, scope_id) {
                    some(depth) => {
                        match previous_depth {
                            some(previous) => if depth >= previous {
                                panic("ResourcePlanner: exit scopes are not inner-to-outer")
                            },
                            none => {}
                        }
                        previous_depth = some(depth)
                    },
                    none => panic("ResourcePlanner: exited scope has no frozen binder")
                }
            }
        }
    }
}

fn make_frozen_planner_input(
    flow_fingerprint: Str,
    candidate_proof: CallableCandidateProof,
    type_nodes: List<PlannerTypeNode>,
    callables: List<PlannerCallable>,
    bodies: List<PlannerBody>
) -> FrozenPlannerInput {
    if flow_fingerprint.len() == 0 {
        panic("ResourcePlanner: FlowIR fingerprint is missing")
    }
    let copied_types = copy_planner_type_nodes(type_nodes)
    let copied_callables = copy_planner_callables(callables)
    let copied_bodies = copy_planner_bodies(bodies)
    let mut type_index = 0
    while type_index < copied_types.len() {
        let node = copied_types.get(type_index).unwrap()
        for child in node.child_type_indices {
            if child < 0 || child >= copied_types.len() {
                panic("ResourcePlanner: type child is outside frozen graph")
            }
            let child_node = copied_types.get(child).unwrap()
            let mut dependency_ordinal = 0
            while dependency_ordinal < child_node.type_parameter_count {
                let mut matches = 0
                for dependency in node.resource_dependencies {
                    if dependency.child_type_index == child &&
                       dependency.child_dependency_ordinal == dependency_ordinal {
                        matches = matches + 1
                    }
                }
                if matches != 1 {
                    panic("ResourcePlanner: child resource substitution is partial or ambiguous")
                }
                dependency_ordinal = dependency_ordinal + 1
            }
        }
        for dependency in node.resource_dependencies {
            let child = copied_types.get(
                dependency.child_type_index).unwrap()
            if dependency.child_dependency_ordinal >=
                   child.type_parameter_count {
                panic("ResourcePlanner: child dependency ordinal is outside child")
            }
            match dependency.target {
                PlannerDependencyTargetValue::ConcreteTypeTargetValue(index) =>
                    if index < 0 || index >= copied_types.len() {
                        panic("ResourcePlanner: concrete substitution type is absent")
                    } else if copied_types.get(index).unwrap().type_parameter_count != 0 {
                        panic("ResourcePlanner: concrete substitution still has free dependencies")
                    },
                PlannerDependencyTargetValue::ParentParameterTargetValue(_) => {}
            }
        }
        type_index = type_index + 1
    }
    let mut callable_index = 0
    while callable_index < copied_callables.len() {
        let callable = copied_callables.get(callable_index).unwrap()
        for parameter_type in callable.parameter_type_indices {
            if parameter_type < 0 || parameter_type >= copied_types.len() {
                panic("ResourcePlanner: callable parameter type is absent")
            }
        }
        if callable.result_type_index < 0 ||
           callable.result_type_index >= copied_types.len() {
            panic("ResourcePlanner: callable result type is absent")
        }
        for edge in callable.call_edges {
            if edge.callee_index < 0 ||
               edge.callee_index >= copied_callables.len() {
                panic("ResourcePlanner: callable graph edge has no exact target")
            }
            let callee = copied_callables.get(edge.callee_index).unwrap()
            if edge.argument_sources.len() !=
               callee.parameter_type_indices.len() {
                panic("ResourcePlanner: callable graph argument census differs")
            }
            for source in edge.argument_sources {
                for parameter in planner_argument_source_parameters(source) {
                    if parameter < 0 || parameter >=
                                             callable.parameter_type_indices.len() {
                        panic("ResourcePlanner: callable edge source parameter is absent")
                    }
                }
            }
        }
        let mut other_index = callable_index + 1
        while other_index < copied_callables.len() {
            if executable_ref_same(
                    callable.reference,
                    copied_callables.get(other_index).unwrap().reference) {
                panic("ResourcePlanner: duplicate exact callable")
            }
            other_index = other_index + 1
        }
        callable_index = callable_index + 1
    }
    let mut body_index = 0
    while body_index < copied_bodies.len() {
        let body = copied_bodies.get(body_index).unwrap()
        validate_body(body, copied_types, copied_callables)
        let mut matched_body_callable = 0
        for callable in copied_callables {
            if executable_ref_same(body.reference, callable.reference) {
                if !callable.has_body {
                    panic("ResourcePlanner: body exists for ContractOnly callable")
                }
                matched_body_callable = matched_body_callable + 1
            }
        }
        if matched_body_callable != 1 {
            panic("ResourcePlanner: body lacks one exact callable owner")
        }
        let mut other_index = body_index + 1
        while other_index < copied_bodies.len() {
            if executable_ref_same(
                    body.reference,
                    copied_bodies.get(other_index).unwrap().reference) {
                panic("ResourcePlanner: duplicate executable body")
            }
            other_index = other_index + 1
        }
        body_index = body_index + 1
    }
    for callable in copied_callables {
        let mut body_count = 0
        for body in copied_bodies {
            if executable_ref_same(callable.reference, body.reference) {
                body_count = body_count + 1
            }
        }
        if callable.has_body && body_count != 1 {
            panic("ResourcePlanner: concrete callable lacks one body")
        }
        if !callable.has_body && body_count != 0 {
            panic("ResourcePlanner: ContractOnly callable has a body")
        }
    }
    FrozenPlannerInput {
        flow_fingerprint: flow_fingerprint,
        candidate_proof: candidate_proof,
        type_nodes: copied_types,
        callables: copied_callables,
        bodies: copied_bodies
    }
}

fn frozen_planner_input_flow_fingerprint(
    value: FrozenPlannerInput
) -> Str { value.flow_fingerprint }

// ============================================================
// Exact finite monotone graph construction and solve
// ============================================================

struct TypeCellLayout {
    logical_start: Int,
    physical_start: Int,
    parameter_count: Int
}

struct CallableCellLayout {
    mode_start: Int,
    force_start: Int,
    result_cell: Int,
    parameter_count: Int
}

fn add_cell(
    mut cells: List<ResourceCellSpec>,
    kind: ResourceCellKind,
    owner_index: Int, component_index: Int, max_rank: Int
) -> Int {
    let index = cells.len()
    cells.push(make_resource_cell_spec(
        kind, owner_index, component_index, max_rank))
    index
}

fn add_constraint(
    mut constraints: List<ResourceConstraint>,
    rule_tag: Int, target: Int, floor_rank: Int,
    premises: List<Int>
) {
    constraints.push(make_resource_constraint(
        rule_tag, target, floor_rank, premises))
}

const RULE_TYPE_SEED: Int = 0
const RULE_TYPE_CHILD: Int = 1
const RULE_DIRECT_IMPLIES_UNIQUE: Int = 2
const RULE_CALLABLE_SEED: Int = 3
const RULE_CALLABLE_EDGE: Int = 4
const RULE_CALLABLE_RESULT_EDGE: Int = 5

struct ConstraintGraphBuild {
    cells: List<ResourceCellSpec>,
    constraints: List<ResourceConstraint>,
    type_layouts: List<TypeCellLayout>,
    callable_layouts: List<CallableCellLayout>
}

fn build_constraint_graph(input: FrozenPlannerInput) -> ConstraintGraphBuild {
    let cells: List<ResourceCellSpec> = []
    let constraints: List<ResourceConstraint> = []
    let mut type_layouts: List<TypeCellLayout> = []
    let mut callable_layouts: List<CallableCellLayout> = []

    let mut type_index = 0
    while type_index < input.type_nodes.len() {
        let node = input.type_nodes.get(type_index).unwrap()
        let logical_start = cells.len()
        let mut component = 0
        while component < 2 + node.type_parameter_count {
            add_cell(cells, resource_cell_kind_logical_shape(),
                type_index, component, 1)
            component = component + 1
        }
        let physical_start = cells.len()
        component = 0
        while component < 4 + node.type_parameter_count {
            add_cell(cells, resource_cell_kind_physical_shape(),
                type_index, component, 1)
            component = component + 1
        }
        type_layouts.push(TypeCellLayout {
            logical_start: logical_start,
            physical_start: physical_start,
            parameter_count: node.type_parameter_count
        })
        type_index = type_index + 1
    }

    let mut callable_index = 0
    while callable_index < input.callables.len() {
        let callable = input.callables.get(callable_index).unwrap()
        let mode_start = cells.len()
        let mut parameter = 0
        while parameter < callable.parameter_type_indices.len() {
            add_cell(cells, resource_cell_kind_callable_param_mode(),
                callable_index, parameter, 3)
            parameter = parameter + 1
        }
        let force_start = cells.len()
        parameter = 0
        while parameter < callable.parameter_type_indices.len() {
            add_cell(cells, resource_cell_kind_callable_force(),
                callable_index, parameter, 1)
            parameter = parameter + 1
        }
        let result_cell = add_cell(
            cells, resource_cell_kind_callable_result(),
            callable_index, 0, 1)
        callable_layouts.push(CallableCellLayout {
            mode_start: mode_start,
            force_start: force_start,
            result_cell: result_cell,
            parameter_count: callable.parameter_type_indices.len()
        })
        callable_index = callable_index + 1
    }

    // Type seeds and exact recursive child edges.
    type_index = 0
    while type_index < input.type_nodes.len() {
        let node = input.type_nodes.get(type_index).unwrap()
        let layout = type_layouts.get(type_index).unwrap()
        add_constraint(constraints, RULE_TYPE_SEED,
            layout.logical_start,
            if node.direct_drop_seed { 1 } else { 0 }, [])
        add_constraint(constraints, RULE_TYPE_SEED,
            layout.logical_start + 1,
            if node.may_unique_seed { 1 } else { 0 }, [])
        add_constraint(constraints, RULE_DIRECT_IMPLIES_UNIQUE,
            layout.logical_start + 1, 0, [layout.logical_start])
        add_constraint(constraints, RULE_TYPE_SEED,
            layout.physical_start,
            if node.physical_rc_seed { 1 } else { 0 }, [])
        add_constraint(constraints, RULE_TYPE_SEED,
            layout.physical_start + 1,
            if node.boxing_seed { 1 } else { 0 }, [])
        add_constraint(constraints, RULE_TYPE_SEED,
            layout.physical_start + 2,
            if node.drop_glue_seed { 1 } else { 0 }, [])
        add_constraint(constraints, RULE_TYPE_SEED,
            layout.physical_start + 3,
            if node.foreign_containment_seed { 1 } else { 0 }, [])
        match node.parameter_index {
            some(parameter) => {
                add_constraint(constraints, RULE_TYPE_SEED,
                    layout.logical_start + 2 + parameter, 1, [])
                add_constraint(constraints, RULE_TYPE_SEED,
                    layout.physical_start + 4 + parameter, 1, [])
            },
            none => {}
        }
        for child_index in node.child_type_indices {
            let child = type_layouts.get(child_index).unwrap()
            let mut logical_component = 0
            while logical_component < 2 {
                add_constraint(constraints, RULE_TYPE_CHILD,
                    layout.logical_start + logical_component, 0,
                    [child.logical_start + logical_component])
                logical_component = logical_component + 1
            }
            let mut physical_component = 0
            while physical_component < 4 {
                add_constraint(constraints, RULE_TYPE_CHILD,
                    layout.physical_start + physical_component, 0,
                    [child.physical_start + physical_component])
                physical_component = physical_component + 1
            }
        }
        for dependency in node.resource_dependencies {
            let child = type_layouts.get(
                dependency.child_type_index).unwrap()
            match dependency.target {
                PlannerDependencyTargetValue::ParentParameterTargetValue(
                    parent_parameter) => {
                    add_constraint(constraints, RULE_TYPE_CHILD,
                        layout.logical_start + 2 + parent_parameter, 0,
                        [child.logical_start + 2 +
                            dependency.child_dependency_ordinal])
                    add_constraint(constraints, RULE_TYPE_CHILD,
                        layout.physical_start + 4 + parent_parameter, 0,
                        [child.physical_start + 4 +
                            dependency.child_dependency_ordinal])
                },
                PlannerDependencyTargetValue::ConcreteTypeTargetValue(
                    concrete_index) => {
                    let concrete = type_layouts.get(concrete_index).unwrap()
                    let mut logical_component = 0
                    while logical_component < 2 {
                        add_constraint(constraints, RULE_TYPE_CHILD,
                            layout.logical_start + logical_component, 0,
                            [concrete.logical_start + logical_component])
                        logical_component = logical_component + 1
                    }
                    let mut physical_component = 0
                    while physical_component < 4 {
                        add_constraint(constraints, RULE_TYPE_CHILD,
                            layout.physical_start + physical_component, 0,
                            [concrete.physical_start + physical_component])
                        physical_component = physical_component + 1
                    }
                }
            }
        }
        type_index = type_index + 1
    }

    // Callable seeds and exact call graph propagation.
    callable_index = 0
    while callable_index < input.callables.len() {
        let callable = input.callables.get(callable_index).unwrap()
        let layout = callable_layouts.get(callable_index).unwrap()
        let mut parameter = 0
        while parameter < callable.parameter_seeds.len() {
            let seed = callable.parameter_seeds.get(parameter).unwrap()
            add_constraint(constraints, RULE_CALLABLE_SEED,
                layout.mode_start + parameter,
                param_mode_tag(transfer_demand_mode(seed)), [])
            add_constraint(constraints, RULE_CALLABLE_SEED,
                layout.force_start + parameter,
                if transfer_demand_force(seed) { 1 } else { 0 }, [])
            parameter = parameter + 1
        }
        add_constraint(constraints, RULE_CALLABLE_SEED,
            layout.result_cell,
            if callable.result_owned_seed { 1 } else { 0 }, [])
        for edge in callable.call_edges {
            let callee = callable_layouts.get(edge.callee_index).unwrap()
            let mut argument = 0
            while argument < edge.argument_sources.len() {
                for caller_parameter in planner_argument_source_parameters(
                        edge.argument_sources.get(argument).unwrap()) {
                        add_constraint(constraints, RULE_CALLABLE_EDGE,
                            layout.mode_start + caller_parameter, 0,
                            [callee.mode_start + argument])
                        add_constraint(constraints, RULE_CALLABLE_EDGE,
                            layout.force_start + caller_parameter, 0,
                            [callee.force_start + argument])
                }
                argument = argument + 1
            }
            if edge.forwards_result {
                add_constraint(constraints, RULE_CALLABLE_RESULT_EDGE,
                    layout.result_cell, 0, [callee.result_cell])
            }
        }
        callable_index = callable_index + 1
    }
    ConstraintGraphBuild {
        cells: cells,
        constraints: constraints,
        type_layouts: type_layouts,
        callable_layouts: callable_layouts
    }
}

fn required_constraint_rank(
    constraint: ResourceConstraint, ranks: List<Int>
) -> Int {
    let mut required = resource_constraint_floor_rank(constraint)
    for premise in resource_constraint_premise_cells(constraint) {
        let rank = ranks.get(premise).unwrap()
        if rank > required { required = rank }
    }
    required
}

fn current_premise_ranks(
    constraint: ResourceConstraint, ranks: List<Int>
) -> List<Int> {
    let mut result: List<Int> = []
    for premise in resource_constraint_premise_cells(constraint) {
        result.push(ranks.get(premise).unwrap())
    }
    result
}

fn solve_constraint_graph(build: ConstraintGraphBuild) -> ResourceFixedPointProof {
    let mut ranks: List<Int> = []
    let mut promotions: List<ResourcePromotion> = []
    let mut exact_rank_budget = 0
    for cell in build.cells {
        ranks.push(0)
        exact_rank_budget = exact_rank_budget + resource_cell_spec_max_rank(cell)
    }
    let mut promotion_count = 0
    let mut changed = true
    while changed {
        changed = false
        let mut constraint_index = 0
        while constraint_index < build.constraints.len() {
            let constraint = build.constraints.get(constraint_index).unwrap()
            let target = resource_constraint_target_cell(constraint)
            let before = ranks.get(target).unwrap()
            let required = required_constraint_rank(constraint, ranks)
            if required > before {
                let max_rank = resource_cell_spec_max_rank(
                    build.cells.get(target).unwrap())
                if required > max_rank {
                    panic("ResourcePlanner: monotone rule exceeds finite lattice")
                }
                promotions.push(make_resource_promotion(
                    constraint_index, target, before, required,
                    current_premise_ranks(constraint, ranks)))
                ranks.set(target, required)
                promotion_count = promotion_count + 1
                if promotion_count > exact_rank_budget {
                    panic("ResourcePlanner: finite worklist rank budget exceeded")
                }
                changed = true
            }
            constraint_index = constraint_index + 1
        }
    }
    make_resource_fixed_point_proof(
        build.cells, build.constraints, promotions, ranks)
}

struct SolvedResourceGraph {
    fixed_point: ResourceFixedPointProof,
    logical_shapes: List<LogicalOwnershipShape>,
    physical_shapes: List<PhysicalRcShape>,
    callable_demands: List<List<TransferDemand>>,
    callable_results_owned: List<Bool>,
    callable_result_type_indices: List<Int>
}

fn bool_rank(ranks: List<Int>, index: Int) -> Bool {
    ranks.get(index).unwrap() > 0
}

fn materialize_solved_graph(
    input: FrozenPlannerInput, build: ConstraintGraphBuild,
    fixed_point: ResourceFixedPointProof
) -> SolvedResourceGraph {
    let ranks = resource_fixed_point_final_ranks(fixed_point)
    let mut logical_shapes: List<LogicalOwnershipShape> = []
    let mut physical_shapes: List<PhysicalRcShape> = []
    let mut callable_demands: List<List<TransferDemand>> = []
    let mut callable_results_owned: List<Bool> = []
    let mut callable_result_type_indices: List<Int> = []
    let mut type_index = 0
    while type_index < input.type_nodes.len() {
        let layout = build.type_layouts.get(type_index).unwrap()
        let mut logical_deps: List<Bool> = []
        let mut physical_deps: List<Bool> = []
        let mut parameter = 0
        while parameter < layout.parameter_count {
            logical_deps.push(bool_rank(
                ranks, layout.logical_start + 2 + parameter))
            physical_deps.push(bool_rank(
                ranks, layout.physical_start + 4 + parameter))
            parameter = parameter + 1
        }
        logical_shapes.push(make_logical_ownership_shape(
            bool_rank(ranks, layout.logical_start),
            bool_rank(ranks, layout.logical_start + 1),
            logical_deps))
        physical_shapes.push(make_physical_rc_shape(
            bool_rank(ranks, layout.physical_start),
            bool_rank(ranks, layout.physical_start + 1),
            bool_rank(ranks, layout.physical_start + 2),
            bool_rank(ranks, layout.physical_start + 3),
            physical_deps))
        type_index = type_index + 1
    }
    let mut callable_index = 0
    while callable_index < input.callables.len() {
        let layout = build.callable_layouts.get(callable_index).unwrap()
        let mut demands: List<TransferDemand> = []
        let mut parameter = 0
        while parameter < layout.parameter_count {
            let mode = param_mode_from_tag(
                ranks.get(layout.mode_start + parameter).unwrap())
            let force = bool_rank(ranks, layout.force_start + parameter)
            if force && !param_mode_same(mode, param_mode_own()) {
                panic("ResourcePlanner: FORCE fixed point lacks Own mode")
            }
            demands.push(make_transfer_demand(mode, force))
            parameter = parameter + 1
        }
        callable_demands.push(demands)
        callable_results_owned.push(bool_rank(ranks, layout.result_cell))
        callable_result_type_indices.push(
            input.callables.get(callable_index).unwrap().result_type_index)
        callable_index = callable_index + 1
    }
    SolvedResourceGraph {
        fixed_point: fixed_point,
        logical_shapes: logical_shapes,
        physical_shapes: physical_shapes,
        callable_demands: callable_demands,
        callable_results_owned: callable_results_owned,
        callable_result_type_indices: callable_result_type_indices
    }
}

// ============================================================
// Unified A-prime/S-prime CFG slot-state machine
// ============================================================

fn copy_slot_states(values: List<SlotFlow>) -> List<SlotFlow> {
    let mut result: List<SlotFlow> = []
    for value in values {
        result.push(slot_flow_from_tag(slot_flow_tag(value)))
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
        logical_ownership_shape_may_unique(shape)
}

fn physical_shape_may_drop(shape: PhysicalRcShape) -> Bool {
    physical_rc_shape_physical_rc(shape) ||
        physical_rc_shape_drop_glue(shape)
}

fn require_concrete_resource_shape(
    logical: LogicalOwnershipShape, physical: PhysicalRcShape,
    context: Str
) {
    if bool_list_has_true(logical_ownership_shape_param_deps(logical)) ||
       bool_list_has_true(physical_rc_shape_param_deps(physical)) {
        panic("ResourcePlanner: unresolved generic resource dependency at ${context}")
    }
}

fn require_live_state(state: SlotFlow, operation: Str) {
    if !slot_flow_same(state, slot_flow_live()) {
        panic("ResourcePlanner: ${operation} requires one exact live slot")
    }
}

fn require_writable_state(state: SlotFlow, operation: Str) {
    if slot_flow_same(state, slot_flow_unreachable()) {
        panic("ResourcePlanner: ${operation} targets an unreachable slot")
    }
}

fn apply_demand_abstract(
    slot: Int, demand: TransferDemand,
    slots: List<PlannerSlot>,
    logical_shapes: List<LogicalOwnershipShape>,
    physical_shapes: List<PhysicalRcShape>,
    mut states: List<SlotFlow>
) {
    let before = states.get(slot).unwrap()
    require_live_state(before, "value edge")
    let mode = transfer_demand_mode(demand)
    if param_mode_same(mode, param_mode_bottom()) {
        panic("ResourcePlanner: value edge has Bottom demand")
    }
    let type_index = slots.get(slot).unwrap().type_index
    let logical = logical_shapes.get(type_index).unwrap()
    let physical = physical_shapes.get(type_index).unwrap()
    if param_mode_same(mode, param_mode_own()) {
        require_concrete_resource_shape(logical, physical, "value edge")
    }
    if param_mode_same(mode, param_mode_own()) &&
       (transfer_demand_force(demand) || logical_shape_may_take(logical)) {
        states.set(slot, slot_flow_moved())
    }
}

fn effective_call_demands(
    callable_indices: List<Int>, lower_bounds: List<TransferDemand>,
    solved_demands: List<List<TransferDemand>>
) -> List<TransferDemand> {
    let mut result: List<TransferDemand> = []
    for lower in lower_bounds {
        result.push(make_transfer_demand(
            transfer_demand_mode(lower), transfer_demand_force(lower)))
    }
    for callable_index in callable_indices {
        let candidate = solved_demands.get(callable_index).unwrap()
        if candidate.len() != result.len() {
            panic("ResourcePlanner: callable candidate contract arity differs")
        }
        let mut parameter = 0
        while parameter < result.len() {
            result.set(parameter, transfer_demand_join(
                result.get(parameter).unwrap(),
                candidate.get(parameter).unwrap()))
            parameter = parameter + 1
        }
    }
    result
}

fn effective_call_result_owned(
    callable_indices: List<Int>, lower_bound: Bool,
    solved_results: List<Bool>
) -> Bool {
    if lower_bound { return true }
    for callable_index in callable_indices {
        if solved_results.get(callable_index).unwrap() { return true }
    }
    false
}

fn apply_event_abstract(
    event: PlannerEvent, slots: List<PlannerSlot>,
    logical_shapes: List<LogicalOwnershipShape>,
    physical_shapes: List<PhysicalRcShape>,
    callable_demands: List<List<TransferDemand>>,
    callable_results_owned: List<Bool>,
    mut states: List<SlotFlow>
) {
    match event.value {
        PlannerEventValue::NoOpValue => {},
        PlannerEventValue::ScopeExitValue(scope_id) => {
            for slot_index in cleanup_slot_order(slots, [scope_id]) {
                let slot = slots.get(slot_index).unwrap()
                if slot.owns_storage {
                    require_concrete_resource_shape(
                        logical_shapes.get(slot.type_index).unwrap(),
                        physical_shapes.get(slot.type_index).unwrap(),
                        "scope exit")
                }
                let before = states.get(slot_index).unwrap()
                if !slot_flow_same(before, slot_flow_unreachable()) {
                    states.set(slot_index, slot_flow_empty())
                }
            }
        },
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, target, ..
        } => {
            let mut input_index = 0
            while input_index < input_slots.len() {
                apply_demand_abstract(
                    input_slots.get(input_index).unwrap(),
                    input_demands.get(input_index).unwrap(),
                    slots, logical_shapes, physical_shapes, states)
                input_index = input_index + 1
            }
            let before = states.get(target).unwrap()
            if slot_flow_same(before, slot_flow_live()) ||
               slot_flow_same(before, slot_flow_unreachable()) {
                panic("ResourcePlanner: initialize overwrites live storage")
            }
            states.set(target, slot_flow_live())
        },
        PlannerEventValue::InitializeEmptyValue(slot) => {
            let before = states.get(slot).unwrap()
            if slot_flow_same(before, slot_flow_live()) {
                panic("ResourcePlanner: empty initialization overwrites a live slot")
            }
            states.set(slot, slot_flow_empty())
        },
        PlannerEventValue::InitializeLiveValue(slot) => {
            let before = states.get(slot).unwrap()
            if slot_flow_same(before, slot_flow_live()) ||
               slot_flow_same(before, slot_flow_unreachable()) {
                panic("ResourcePlanner: live initialization lacks empty storage")
            }
            states.set(slot, slot_flow_live())
        },
        PlannerEventValue::ReadValue { source, target } => {
            require_live_state(states.get(source).unwrap(), "read")
            let before = states.get(target).unwrap()
            if slot_flow_same(before, slot_flow_live()) ||
               slot_flow_same(before, slot_flow_unreachable()) {
                panic("ResourcePlanner: Read overwrites live storage")
            }
            let demand = if slots.get(target).unwrap().owns_storage {
                make_transfer_demand(param_mode_own(), false)
            } else {
                make_transfer_demand(param_mode_borrow(), false)
            }
            apply_demand_abstract(
                source, demand, slots, logical_shapes,
                physical_shapes, states)
            states.set(target, slot_flow_live())
        },
        PlannerEventValue::MutateValue {
            target, value: input, value_demand
        } => {
            require_live_state(states.get(target).unwrap(), "mutation target")
            apply_demand_abstract(
                input, value_demand, slots, logical_shapes,
                physical_shapes, states)
        },
        PlannerEventValue::ConsumeValue(slot, force, target) => {
            match target {
                some(value) => {
                    let sink_state = states.get(value).unwrap()
                    if slot_flow_same(sink_state, slot_flow_live()) ||
                       slot_flow_same(sink_state, slot_flow_unreachable()) {
                        panic("ResourcePlanner: abstract Consume sink is not empty")
                    }
                },
                none => {}
            }
            apply_demand_abstract(
                slot, make_transfer_demand(param_mode_own(), force),
                slots, logical_shapes, physical_shapes, states)
        },
        PlannerEventValue::DiscardValue(slot) => {
            require_live_state(states.get(slot).unwrap(), "discard")
            let type_index = slots.get(slot).unwrap().type_index
            let logical = logical_shapes.get(type_index).unwrap()
            let physical = physical_shapes.get(type_index).unwrap()
            require_concrete_resource_shape(logical, physical, "discard")
            if physical_shape_may_drop(physical) ||
               logical_shape_may_take(logical) {
                states.set(slot, slot_flow_empty())
            }
        },
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            require_live_state(states.get(rhs_temp).unwrap(), "Assign RHS temp")
            let rhs_type = slots.get(rhs_temp).unwrap().type_index
            require_concrete_resource_shape(
                logical_shapes.get(rhs_type).unwrap(),
                physical_shapes.get(rhs_type).unwrap(), "Assign RHS")
            // The semantic event occurs only after its RHS-producing events.
            // Resource materialization later emits Drop-old then Take(temp).
            if planner_place_is_slot(target) {
                let target_slot = planner_place_slot(target)
                require_writable_state(
                    states.get(target_slot).unwrap(), "Assign")
                let target_type = slots.get(target_slot).unwrap().type_index
                require_concrete_resource_shape(
                    logical_shapes.get(target_type).unwrap(),
                    physical_shapes.get(target_type).unwrap(), "Assign target")
                states.set(target_slot, slot_flow_live())
            } else {
                let base = planner_place_base(target)
                require_live_state(states.get(base).unwrap(), "Assign place base")
                match planner_place_evaluated_index(target) {
                    some(index) => require_live_state(
                        states.get(index).unwrap(), "Assign evaluated index"),
                    none => {}
                }
                let value_type = planner_place_value_type(target)
                require_concrete_resource_shape(
                    logical_shapes.get(value_type).unwrap(),
                    physical_shapes.get(value_type).unwrap(),
                    "projected Assign value")
            }
            states.set(rhs_temp, slot_flow_moved())
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            result_owned, result_type_index,
            argument_slots, result_slot, ..
        } => {
            let demands = effective_call_demands(
                callable_indices, argument_demands, callable_demands)
            let effective_result_owned = effective_call_result_owned(
                callable_indices, result_owned, callable_results_owned)
            if effective_result_owned || result_slot.is_some() {
                require_concrete_resource_shape(
                    logical_shapes.get(result_type_index).unwrap(),
                    physical_shapes.get(result_type_index).unwrap(),
                    "call result")
            }
            let mut argument = 0
            while argument < argument_slots.len() {
                apply_demand_abstract(
                    argument_slots.get(argument).unwrap(),
                    demands.get(argument).unwrap(), slots,
                    logical_shapes, physical_shapes, states)
                argument = argument + 1
            }
            match result_slot {
                some(slot) => {
                    let before = states.get(slot).unwrap()
                    if slot_flow_same(before, slot_flow_live()) ||
                       slot_flow_same(before, slot_flow_unreachable()) {
                        panic("ResourcePlanner: call result overwrites live storage")
                    }
                    states.set(slot, slot_flow_live())
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
            source, target, whole_slot
        } => {
            require_live_state(states.get(source).unwrap(), "projection")
            let before_target = states.get(target).unwrap()
            if slot_flow_same(before_target, slot_flow_live()) ||
               slot_flow_same(before_target, slot_flow_unreachable()) {
                panic("ResourcePlanner: projection overwrites live storage")
            }
            let type_index = slots.get(source).unwrap().type_index
            let logical = logical_shapes.get(type_index).unwrap()
            if !whole_slot && logical_shape_may_take(logical) {
                panic("ResourcePlanner: partial move of may-own projection")
            }
            if whole_slot && logical_shape_may_take(logical) {
                states.set(source, slot_flow_moved())
            }
            states.set(target, slot_flow_live())
        },
        PlannerEventValue::CaptureValue { source, target, demand } => {
            let before_target = states.get(target).unwrap()
            if slot_flow_same(before_target, slot_flow_live()) ||
               slot_flow_same(before_target, slot_flow_unreachable()) {
                panic("ResourcePlanner: capture overwrites live storage")
            }
            apply_demand_abstract(
                source, demand, slots, logical_shapes,
                physical_shapes, states)
            states.set(target, slot_flow_live())
        }
    }
}

fn int_list_contains(values: List<Int>, target: Int) -> Bool {
    for value in values { if value == target { return true } }
    false
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
    edge: PlannerEdge, slots: List<PlannerSlot>,
    logical_shapes: List<LogicalOwnershipShape>,
    physical_shapes: List<PhysicalRcShape>,
    mut states: List<SlotFlow>
) {
    for slot_index in cleanup_slot_order(slots, edge.exited_scope_ids) {
        let slot = slots.get(slot_index).unwrap()
        if slot.owns_storage {
            require_concrete_resource_shape(
                logical_shapes.get(slot.type_index).unwrap(),
                physical_shapes.get(slot.type_index).unwrap(), "CFG exit")
        }
        let before = states.get(slot_index).unwrap()
        if !slot_flow_same(before, slot_flow_unreachable()) {
            // Empty/Moved/MaybeMoved are represented by cleared storage;
            // unconditional cleanup is physically safe and normalizes all
            // reachable paths to Empty. Non-owning binders also leave the
            // abstract scope even though they emit no RcIR operation.
            states.set(slot_index, slot_flow_empty())
        }
    }
}

// ============================================================
// Finite body slot-origin and direct-demand dataflow
// ============================================================

fn empty_origin_bits(parameter_count: Int) -> List<Bool> {
    let mut result: List<Bool> = []
    let mut index = 0
    while index < parameter_count {
        result.push(false)
        index = index + 1
    }
    result
}

fn copy_origin_bits(values: List<Bool>) -> List<Bool> {
    let mut result: List<Bool> = []
    for value in values { result.push(value) }
    result
}

fn join_origin_bits(left: List<Bool>, right: List<Bool>) -> List<Bool> {
    if left.len() != right.len() {
        panic("ResourcePlanner: slot-origin parameter arity differs")
    }
    let mut result: List<Bool> = []
    let mut index = 0
    while index < left.len() {
        result.push(left.get(index).unwrap() || right.get(index).unwrap())
        index = index + 1
    }
    result
}

fn origin_bits_same(left: List<Bool>, right: List<Bool>) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        if left.get(index).unwrap() != right.get(index).unwrap() {
            return false
        }
        index = index + 1
    }
    true
}

fn copy_origin_state(values: List<List<Bool>>) -> List<List<Bool>> {
    let mut result: List<List<Bool>> = []
    for value in values { result.push(copy_origin_bits(value)) }
    result
}

fn join_origin_states(
    left: List<List<Bool>>, right: List<List<Bool>>
) -> List<List<Bool>> {
    if left.len() != right.len() {
        panic("ResourcePlanner: slot-origin state census differs")
    }
    let mut result: List<List<Bool>> = []
    let mut index = 0
    while index < left.len() {
        result.push(join_origin_bits(
            left.get(index).unwrap(), right.get(index).unwrap()))
        index = index + 1
    }
    result
}

fn origin_states_same(
    left: List<List<Bool>>, right: List<List<Bool>>
) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        if !origin_bits_same(
                left.get(index).unwrap(), right.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}

fn origin_from_inputs(
    states: List<List<Bool>>, input_slots: List<Int>,
    origin_ordinals: List<Int>, parameter_count: Int
) -> List<Bool> {
    let mut result = empty_origin_bits(parameter_count)
    for ordinal in origin_ordinals {
        let slot = input_slots.get(ordinal).unwrap()
        result = join_origin_bits(result, states.get(slot).unwrap())
    }
    result
}

fn body_call_event_count(body: PlannerBody) -> Int {
    let mut count = 0
    for block in body.blocks {
        for event in block.events {
            match event.value {
                PlannerEventValue::CallValue { .. } => { count = count + 1 },
                _ => {}
            }
        }
    }
    count
}

fn body_call_token_ordinal(
    body: PlannerBody, target_block: Int, target_event: Int
) -> Int? {
    let mut token = 0
    let mut block_index = 0
    while block_index < body.blocks.len() {
        let block = body.blocks.get(block_index).unwrap()
        let mut event_index = 0
        while event_index < block.events.len() {
            match block.events.get(event_index).unwrap().value {
                PlannerEventValue::CallValue { .. } => {
                    if block_index == target_block &&
                       event_index == target_event {
                        return some(token)
                    }
                    token = token + 1
                },
                _ => {}
            }
            event_index = event_index + 1
        }
        block_index = block_index + 1
    }
    none
}

fn apply_event_origin(
    event: PlannerEvent, body: PlannerBody,
    origin_width: Int, call_token: Int?,
    mut states: List<List<Bool>>
) {
    match event.value {
        PlannerEventValue::NoOpValue => {},
        PlannerEventValue::ScopeExitValue(scope_id) => {
            for slot_index in cleanup_slot_order(body.slots, [scope_id]) {
                states.set(slot_index, empty_origin_bits(origin_width))
            }
        },
        PlannerEventValue::InitializeValue {
            input_slots, origin_input_ordinals, target, ..
        } => states.set(target, origin_from_inputs(
            states, input_slots, origin_input_ordinals, origin_width)),
        PlannerEventValue::InitializeEmptyValue(slot) |
        PlannerEventValue::InitializeLiveValue(slot) =>
            states.set(slot, empty_origin_bits(origin_width)),
        PlannerEventValue::ReadValue { source, target } =>
            states.set(target, copy_origin_bits(states.get(source).unwrap())),
        PlannerEventValue::MutateValue { .. } => {},
        PlannerEventValue::ConsumeValue(slot, _, _) |
        PlannerEventValue::DiscardValue(slot) =>
            states.set(slot, empty_origin_bits(origin_width)),
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            if planner_place_is_slot(target) {
                states.set(
                    planner_place_slot(target),
                    copy_origin_bits(states.get(rhs_temp).unwrap()))
            }
            states.set(rhs_temp, empty_origin_bits(origin_width))
        },
        PlannerEventValue::CallValue {
            argument_slots, result_origin_argument_ordinals,
            result_slot, ..
        } => match result_slot {
            some(target) => {
                let mut origins = origin_from_inputs(
                    states, argument_slots,
                    result_origin_argument_ordinals, origin_width)
                match call_token {
                    some(token) => {
                        if token < 0 || token >= origin_width {
                            panic("ResourcePlanner: call-result token escapes origin lattice")
                        }
                        origins.set(token, true)
                    },
                    none => panic("ResourcePlanner: call result lacks exact origin token")
                }
                states.set(target, origins)
            },
            none => {}
        },
        PlannerEventValue::ProjectValue {
            source, target, whole_slot: _
        } => {
            states.set(target, copy_origin_bits(states.get(source).unwrap()))
        },
        PlannerEventValue::CaptureValue { source, target, demand } => {
            states.set(target, copy_origin_bits(states.get(source).unwrap()))
            if param_mode_same(
                    transfer_demand_mode(demand), param_mode_own()) &&
               transfer_demand_force(demand) {
                states.set(source, empty_origin_bits(origin_width))
            }
        }
    }
}

fn apply_origin_edge_cleanup(
    edge: PlannerEdge, body: PlannerBody,
    origin_width: Int, mut states: List<List<Bool>>
) {
    for slot_index in cleanup_slot_order(body.slots, edge.exited_scope_ids) {
        states.set(slot_index, empty_origin_bits(origin_width))
    }
}

struct BodyOriginSolution {
    parameter_count: Int,
    origin_width: Int,
    reachable: List<Bool>,
    entry_states: List<List<List<Bool>>>
}

fn solve_body_origins(
    body: PlannerBody, parameter_count: Int
) -> BodyOriginSolution {
    let origin_width = parameter_count + body_call_event_count(body)
    let mut reachable: List<Bool> = []
    let mut entries: List<List<List<Bool>>> = []
    for _ in body.blocks {
        reachable.push(false)
        let mut state: List<List<Bool>> = []
        for _ in body.slots { state.push(empty_origin_bits(origin_width)) }
        entries.push(state)
    }
    let mut seed: List<List<Bool>> = []
    for slot in body.slots {
        let mut origins = empty_origin_bits(origin_width)
        match slot.parameter_ordinal {
            some(parameter) => {
                if parameter < 0 || parameter >= parameter_count {
                    panic("ResourcePlanner: body parameter ordinal escapes signature")
                }
                origins.set(parameter, true)
            },
            none => {}
        }
        seed.push(origins)
    }
    reachable.set(body.entry_block, true)
    entries.set(body.entry_block, seed)
    let exact_rank_budget = body.blocks.len() *
        (body.slots.len() * origin_width + 1)
    let mut promotions = 1
    let mut changed = true
    while changed {
        changed = false
        let mut block_index = 0
        while block_index < body.blocks.len() {
            if reachable.get(block_index).unwrap() {
                let block = body.blocks.get(block_index).unwrap()
                let state = copy_origin_state(entries.get(block_index).unwrap())
                let mut event_index = 0
                while event_index < block.events.len() {
                    let event = block.events.get(event_index).unwrap()
                    let token = match body_call_token_ordinal(
                            body, block_index, event_index) {
                        some(value) => some(parameter_count + value),
                        none => none
                    }
                    apply_event_origin(
                        event, body, origin_width, token, state)
                    event_index = event_index + 1
                }
                for edge in block.edges {
                    match edge.target_block {
                        some(target) => {
                            let edge_state = copy_origin_state(state)
                            apply_origin_edge_cleanup(
                                edge, body, origin_width, edge_state)
                            if !reachable.get(target).unwrap() {
                                reachable.set(target, true)
                                entries.set(target, edge_state)
                                promotions = promotions + 1
                                changed = true
                            } else {
                                let previous = entries.get(target).unwrap()
                                let joined = join_origin_states(previous, edge_state)
                                if !origin_states_same(previous, joined) {
                                    entries.set(target, joined)
                                    promotions = promotions + 1
                                    changed = true
                                }
                            }
                            if promotions > exact_rank_budget {
                                panic("ResourcePlanner: finite slot-origin worklist exceeded rank budget")
                            }
                        },
                        none => {}
                    }
                }
            }
            block_index = block_index + 1
        }
    }
    BodyOriginSolution {
        parameter_count: parameter_count,
        origin_width: origin_width,
        reachable: reachable, entry_states: entries
    }
}

fn add_demand_to_origins(
    origins: List<Bool>, demand: TransferDemand,
    mut seeds: List<TransferDemand>
) {
    let mut parameter = 0
    while parameter < seeds.len() {
        if origins.get(parameter).unwrap() {
            seeds.set(parameter, transfer_demand_join(
                seeds.get(parameter).unwrap(), demand))
        }
        parameter = parameter + 1
    }
}

fn seed_event_demands(
    event: PlannerEvent, body: PlannerBody,
    states: List<List<Bool>>, mut seeds: List<TransferDemand>
) {
    match event.value {
        PlannerEventValue::NoOpValue |
        PlannerEventValue::ScopeExitValue(_) |
        PlannerEventValue::InitializeEmptyValue(_) |
        PlannerEventValue::InitializeLiveValue(_) => {},
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, ..
        } => {
            let mut input = 0
            while input < input_slots.len() {
                add_demand_to_origins(
                    states.get(input_slots.get(input).unwrap()).unwrap(),
                    input_demands.get(input).unwrap(), seeds)
                input = input + 1
            }
        },
        PlannerEventValue::ReadValue { source, target } =>
            add_demand_to_origins(
                states.get(source).unwrap(),
                if body.slots.get(target).unwrap().owns_storage {
                    make_transfer_demand(param_mode_own(), false)
                } else {
                    make_transfer_demand(param_mode_borrow(), false)
                }, seeds),
        PlannerEventValue::MutateValue {
            target, value: input, value_demand
        } => {
            add_demand_to_origins(
                states.get(target).unwrap(),
                make_transfer_demand(param_mode_mut_borrow(), false), seeds)
            add_demand_to_origins(
                states.get(input).unwrap(), value_demand, seeds)
        },
        PlannerEventValue::ConsumeValue(slot, force, _) =>
            add_demand_to_origins(
                states.get(slot).unwrap(),
                make_transfer_demand(param_mode_own(), force), seeds),
        PlannerEventValue::DiscardValue(slot) =>
            add_demand_to_origins(
                states.get(slot).unwrap(),
                make_transfer_demand(param_mode_own(), false), seeds),
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            add_demand_to_origins(
                states.get(rhs_temp).unwrap(),
                make_transfer_demand(param_mode_own(), false), seeds)
            if planner_place_is_slot(target) {
                add_demand_to_origins(
                    states.get(planner_place_slot(target)).unwrap(),
                    make_transfer_demand(param_mode_own(), false), seeds)
            } else {
                add_demand_to_origins(
                    states.get(planner_place_base(target)).unwrap(),
                    make_transfer_demand(param_mode_mut_borrow(), false), seeds)
                match planner_place_evaluated_index(target) {
                    some(index) => add_demand_to_origins(
                        states.get(index).unwrap(),
                        make_transfer_demand(param_mode_borrow(), false), seeds),
                    none => {}
                }
            }
        },
        PlannerEventValue::CallValue {
            argument_slots, argument_demands, ..
        } => {
            let mut argument = 0
            while argument < argument_slots.len() {
                add_demand_to_origins(
                    states.get(argument_slots.get(argument).unwrap()).unwrap(),
                    argument_demands.get(argument).unwrap(), seeds)
                argument = argument + 1
            }
        },
        PlannerEventValue::ProjectValue {
            source, target, whole_slot
        } => add_demand_to_origins(
            states.get(source).unwrap(),
            if whole_slot && body.slots.get(target).unwrap().owns_storage {
                make_transfer_demand(param_mode_own(), false)
            } else {
                make_transfer_demand(param_mode_borrow(), false)
            }, seeds),
        PlannerEventValue::CaptureValue { source, demand, .. } =>
            add_demand_to_origins(
                states.get(source).unwrap(), demand, seeds)
    }
}

fn body_direct_parameter_seeds(
    body: PlannerBody, parameter_count: Int,
    solution: BodyOriginSolution
) -> List<TransferDemand> {
    let mut seeds: List<TransferDemand> = []
    let mut parameter = 0
    while parameter < parameter_count {
        seeds.push(make_transfer_demand(param_mode_bottom(), false))
        parameter = parameter + 1
    }
    let mut block_index = 0
    while block_index < body.blocks.len() {
        if solution.reachable.get(block_index).unwrap() {
            let block = body.blocks.get(block_index).unwrap()
            let state = copy_origin_state(
                solution.entry_states.get(block_index).unwrap())
            let mut event_index = 0
            while event_index < block.events.len() {
                let event = block.events.get(event_index).unwrap()
                seed_event_demands(event, body, state, seeds)
                let token = match body_call_token_ordinal(
                        body, block_index, event_index) {
                    some(value) => some(parameter_count + value),
                    none => none
                }
                apply_event_origin(
                    event, body, solution.origin_width, token, state)
                event_index = event_index + 1
            }
            for usage in block.terminator_uses {
                add_demand_to_origins(
                    state.get(usage.slot).unwrap(), usage.demand, seeds)
            }
        }
        block_index = block_index + 1
    }
    seeds
}

fn body_call_token_is_returned(
    body: PlannerBody, solution: BodyOriginSolution,
    call_token_ordinal: Int
) -> Bool {
    let token_index = solution.parameter_count + call_token_ordinal
    let mut block_index = 0
    while block_index < body.blocks.len() {
        if solution.reachable.get(block_index).unwrap() {
            let block = body.blocks.get(block_index).unwrap()
            let state = copy_origin_state(
                solution.entry_states.get(block_index).unwrap())
            let mut event_index = 0
            while event_index < block.events.len() {
                let event = block.events.get(event_index).unwrap()
                let token = match body_call_token_ordinal(
                        body, block_index, event_index) {
                    some(value) => some(solution.parameter_count + value),
                    none => none
                }
                apply_event_origin(
                    event, body, solution.origin_width, token, state)
                event_index = event_index + 1
            }
            if block.terminator_kind == 3 {
                for usage in block.terminator_uses {
                    if state.get(usage.slot).unwrap().get(
                            token_index).unwrap() {
                        return true
                    }
                }
            }
        }
        block_index = block_index + 1
    }
    false
}

fn body_callable_edges(
    body: PlannerBody, parameter_count: Int,
    solution: BodyOriginSolution
) -> List<PlannerCallEdge> {
    let mut result: List<PlannerCallEdge> = []
    let mut block_index = 0
    while block_index < body.blocks.len() {
        if solution.reachable.get(block_index).unwrap() {
            let block = body.blocks.get(block_index).unwrap()
            let state = copy_origin_state(
                solution.entry_states.get(block_index).unwrap())
            let mut event_index = 0
            while event_index < block.events.len() {
                let event = block.events.get(event_index).unwrap()
                match event.value {
                    PlannerEventValue::CallValue {
                        callable_indices, argument_slots, result_slot, ..
                    } => {
                        let mut sources: List<PlannerArgumentSource> = []
                        for slot in argument_slots {
                            let origins = state.get(slot).unwrap()
                            let mut parameters: List<Int> = []
                            let mut parameter = 0
                            while parameter < parameter_count {
                                if origins.get(parameter).unwrap() {
                                    parameters.push(parameter)
                                }
                                parameter = parameter + 1
                            }
                            sources.push(make_caller_parameter_sources(parameters))
                        }
                        let call_token = match body_call_token_ordinal(
                                body, block_index, event_index) {
                            some(value) => value,
                            none => panic("ResourcePlanner: call edge lacks origin token")
                        }
                        let forwards = body_call_token_is_returned(
                            body, solution, call_token)
                        for callee in callable_indices {
                            result.push(make_planner_call_edge(
                                callee, sources, forwards))
                        }
                    },
                    _ => {}
                }
                let token = match body_call_token_ordinal(
                        body, block_index, event_index) {
                    some(value) => some(parameter_count + value),
                    none => none
                }
                apply_event_origin(
                    event, body, solution.origin_width, token, state)
                event_index = event_index + 1
            }
        }
        block_index = block_index + 1
    }
    result
}

fn planner_body_for_reference(
    bodies: List<PlannerBody>, reference: ExecutableRef
) -> PlannerBody? {
    for body in bodies {
        if executable_ref_same(body.reference, reference) { return some(body) }
    }
    none
}

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

fn planner_type_is_callable(
    type_nodes: List<PlannerTypeNode>, type_index: Int
) -> Bool {
    planner_type_kind_tag(type_nodes.get(type_index).unwrap().kind) ==
        PLANNER_TYPE_CALLABLE
}

fn replace_call_candidates(
    event: PlannerEvent, candidates: List<Int>
) -> PlannerEvent {
    match event.value {
        PlannerEventValue::CallValue {
            call_target, argument_demands, result_owned,
            result_type_index, result_origin_argument_ordinals,
            argument_slots, result_slot, ..
        } => with_planner_callable_provenance(make_planner_call(
            call_target, candidates, argument_slots, argument_demands,
            result_owned, result_type_index,
            result_origin_argument_ordinals, result_slot),
            event.callable_provenance),
        _ => copy_planner_event(event)
    }
}

struct CandidateProofGraph {
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

fn event_candidate_slot_overwritten(
    event: PlannerEvent, body: PlannerBody, slot: Int
) -> Bool {
    for fact in event.callable_provenance {
        if fact.target == slot { return true }
    }
    match event.value {
        PlannerEventValue::InitializeEmptyValue(target) |
        PlannerEventValue::InitializeLiveValue(target) |
        PlannerEventValue::ConsumeValue(target, _, _) |
        PlannerEventValue::DiscardValue(target) => target == slot,
        PlannerEventValue::ScopeExitValue(scope_id) =>
            body.slots.get(slot).unwrap().scope_id == scope_id,
        PlannerEventValue::AssignValue { rhs_temp, .. } => rhs_temp == slot,
        _ => false
    }
}

fn add_candidate_provenance_rules(
    graph: CandidateProofGraph, body_index: Int, block_index: Int,
    boundary: Int, event: PlannerEvent,
    callables: List<PlannerCallable>, bodies: List<PlannerBody>
) {
    let site = make_instruction_candidate_rule_site(
        make_flow_instruction_ref(
            bodies.get(body_index).unwrap().reference,
            block_index, boundary))
    for fact in event.callable_provenance {
        let mut candidate = 0
        while candidate < graph.callable_count {
            let target = candidate_cell_index(
                graph.cells, candidate_cell_state(), body_index,
                block_index, boundary + 1, fact.target, candidate)
            match fact.origin {
                PlannerCallableOriginValue::DirectCallableOriginValue(direct) =>
                    if direct == candidate {
                        add_candidate_rule(
                            graph.rules, candidate_rule_seed(), site,
                            target, [])
                    },
                PlannerCallableOriginValue::SlotCallableOriginValue(sources) =>
                    { for source in sources {
                        add_candidate_rule(
                            graph.rules, candidate_rule_copy(), site, target,
                            [candidate_cell_index(
                                graph.cells, candidate_cell_state(), body_index,
                                block_index, boundary, source, candidate)])
                    } },
                PlannerCallableOriginValue::CallCallableOriginValue {
                    target: call_target, arguments: _
                } => {
                    let mut callee = 0
                    while callee < graph.callable_count {
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
                                    planner_call_target_slot(call_target), callee),
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
                    add_candidate_rule(
                        graph.rules, candidate_rule_copy(), site, target,
                        [candidate_cell_index(
                            graph.cells, candidate_cell_state(), body_index,
                            block_index, boundary,
                            argument_slots.get(ordinal).unwrap(), candidate)])
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
                    let mut candidate = 0
                    while candidate < graph.callable_count {
                        let target = candidate_cell_index(
                            graph.cells, candidate_cell_parameter(), callee,
                            0, 0, parameter, candidate)
                        let argument_cell = candidate_cell_index(
                            graph.cells, candidate_cell_state(), body_index,
                            block_index, boundary,
                            argument_slots.get(parameter).unwrap(), candidate)
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
                                    planner_call_target_slot(call_target), callee),
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

fn build_candidate_proof_graph(
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
            let mut candidate = 0
            while candidate < callable_count {
                cells.push(make_candidate_cell_spec(
                    candidate_cell_parameter(), callable_index,
                    0, 0, parameter, candidate))
                candidate = candidate + 1
            }
            parameter = parameter + 1
        }
        let mut candidate = 0
        while candidate < callable_count {
            cells.push(make_candidate_cell_spec(
                candidate_cell_result(), callable_index,
                0, 0, 0, candidate))
            candidate = candidate + 1
        }
        callable_index = callable_index + 1
    }
    let mut body_index = 0
    while body_index < bodies.len() {
        let body = bodies.get(body_index).unwrap()
        let mut block_index = 0
        while block_index < body.blocks.len() {
            let block = body.blocks.get(block_index).unwrap()
            let mut boundary = 0
            while boundary <= block.events.len() {
                let mut slot = 0
                while slot < body.slots.len() {
                    let mut candidate = 0
                    while candidate < callable_count {
                        cells.push(make_candidate_cell_spec(
                            candidate_cell_state(), body_index,
                            block_index, boundary, slot, candidate))
                        candidate = candidate + 1
                    }
                    slot = slot + 1
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
        if !callable.has_body {
            for parameter in callable.result_origin_parameter_ordinals {
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
        let callable = flow_callable_index_for_planner(
            callables, body.reference)
        // Entry parameter cells.
        let mut slot_index = 0
        while slot_index < body.slots.len() {
            match body.slots.get(slot_index).unwrap().parameter_ordinal {
                some(parameter) => {
                    let mut candidate = 0
                    while candidate < callable_count {
                        add_candidate_rule(
                            graph.rules, candidate_rule_copy(),
                            make_global_candidate_rule_site(),
                            candidate_cell_index(
                                graph.cells, candidate_cell_state(), body_index,
                                body.entry_block, 0, slot_index, candidate),
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
                let mut slot = 0
                while slot < body.slots.len() {
                    if !event_candidate_slot_overwritten(event, body, slot) {
                        let mut candidate = 0
                        while candidate < callable_count {
                            add_candidate_rule(
                                graph.rules, candidate_rule_copy(), site,
                                candidate_cell_index(
                                    graph.cells, candidate_cell_state(),
                                    body_index, block_index, boundary + 1,
                                    slot, candidate),
                                [candidate_cell_index(
                                    graph.cells, candidate_cell_state(),
                                    body_index, block_index, boundary,
                                    slot, candidate)])
                            candidate = candidate + 1
                        }
                    }
                    slot = slot + 1
                }
                add_candidate_provenance_rules(
                    graph, body_index, block_index, boundary,
                    event, callables, bodies)
                add_candidate_call_argument_rules(
                    graph, body_index, block_index, boundary,
                    event, callables, bodies)
                boundary = boundary + 1
            }
            let end_boundary = block.events.len()
            if block.terminator_kind == 3 {
                for usage in block.terminator_uses {
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
                                usage.slot, candidate)])
                        candidate = candidate + 1
                    }
                }
            }
            let mut edge_index = 0
            while edge_index < block.edges.len() {
                let edge = block.edges.get(edge_index).unwrap()
                match edge.target_block {
                    some(target_block) => {
                        let mut slot = 0
                        while slot < body.slots.len() {
                            if !int_list_contains(
                                    edge.exited_scope_ids,
                                    body.slots.get(slot).unwrap().scope_id) {
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
                                            slot, candidate),
                                        [candidate_cell_index(
                                            graph.cells, candidate_cell_state(),
                                            body_index, block_index,
                                            end_boundary, slot, candidate)])
                                    candidate = candidate + 1
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

fn solve_candidate_proof_graph(
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
    boundary: Int, slot: Int
) -> List<Bool> {
    let cells = callable_candidate_proof_cells(proof)
    let values = callable_candidate_proof_final_values(proof)
    let mut result = empty_candidate_set(
        callable_candidate_proof_callable_count(proof))
    let mut candidate = 0
    while candidate < result.len() {
        let cell = candidate_cell_index(
            cells, candidate_cell_state(), body,
            block, boundary, slot, candidate)
        result.set(candidate, values.get(cell).unwrap())
        candidate = candidate + 1
    }
    result
}

fn derive_candidate_selections(
    proof: CallableCandidateProof, bodies: List<PlannerBody>
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
                        let candidates = if planner_call_target_is_direct(
                                call_target) {
                            [planner_call_target_direct(call_target)]
                        } else {
                            candidate_set_indices(proof_state_candidate_set(
                                proof, body_index, block_index, boundary,
                                planner_call_target_slot(call_target)))
                        }
                        result.push(make_candidate_selection(
                            make_flow_instruction_ref(
                                body.reference, block_index, boundary),
                            candidates))
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

fn with_candidate_selections(
    value: CallableCandidateProof, selections: List<CandidateSelection>
) -> CallableCandidateProof {
    make_callable_candidate_proof(
        callable_candidate_proof_callable_count(value),
        callable_candidate_proof_cells(value),
        callable_candidate_proof_rules(value),
        callable_candidate_proof_promotions(value),
        callable_candidate_proof_final_values(value), selections)
}

fn resolve_bodies_from_candidate_proof(
    proof: CallableCandidateProof, bodies: List<PlannerBody>
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
                                planner_call_target_slot(call_target)))
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

fn flow_callable_index_for_planner(
    callables: List<PlannerCallable>, reference: ExecutableRef
) -> Int {
    let mut index = 0
    while index < callables.len() {
        if executable_ref_same(callables.get(index).unwrap().reference, reference) {
            return index
        }
        index = index + 1
    }
    panic("ResourcePlanner: body has no planner callable")
}

fn close_callable_body_dataflow(
    callables: List<PlannerCallable>, bodies: List<PlannerBody>
) -> List<PlannerCallable> {
    let mut result: List<PlannerCallable> = []
    for callable in callables {
        if !callable.has_body {
            result.push(make_planner_callable(
                callable.reference, callable.parameter_type_indices,
                callable.result_type_index, callable.parameter_seeds,
                callable.result_owned_seed,
                callable.result_origin_parameter_ordinals,
                [], false))
        } else {
            let body = match planner_body_for_reference(
                    bodies, callable.reference) {
                some(value) => value,
                none => panic("ResourcePlanner: callable body dataflow is absent")
            }
            let parameter_count = callable.parameter_type_indices.len()
            let solution = solve_body_origins(body, parameter_count)
            let direct = body_direct_parameter_seeds(
                body, parameter_count, solution)
            let mut seeds: List<TransferDemand> = []
            let mut parameter = 0
            while parameter < parameter_count {
                seeds.push(transfer_demand_join(
                    callable.parameter_seeds.get(parameter).unwrap(),
                    direct.get(parameter).unwrap()))
                parameter = parameter + 1
            }
            result.push(make_planner_callable(
                callable.reference, callable.parameter_type_indices,
                callable.result_type_index, seeds,
                callable.result_owned_seed,
                callable.result_origin_parameter_ordinals,
                body_callable_edges(body, parameter_count, solution), true))
        }
    }
    result
}

struct BodyEntrySolution {
    reachable: List<Bool>,
    entry_states: List<List<SlotFlow>>
}

fn solve_body_entry_states(
    body: PlannerBody, solved: SolvedResourceGraph
) -> BodyEntrySolution {
    let mut reachable: List<Bool> = []
    let mut entry_states: List<List<SlotFlow>> = []
    let mut block_index = 0
    while block_index < body.blocks.len() {
        reachable.push(false)
        let mut states: List<SlotFlow> = []
        for _ in body.slots { states.push(slot_flow_unreachable()) }
        entry_states.push(states)
        block_index = block_index + 1
    }
    let mut seed: List<SlotFlow> = []
    for slot in body.slots {
        seed.push(if slot.initially_live {
            slot_flow_live()
        } else {
            slot_flow_empty()
        })
    }
    reachable.set(body.entry_block, true)
    entry_states.set(body.entry_block, seed)

    // Entry states only change by finite joins.  Every SlotFlow cell has rank
    // at most two; block reachability contributes one additional bit.
    let exact_rank_budget = body.blocks.len() *
        (body.slots.len() * 2 + 1)
    let mut promotion_count = 1
    let mut changed = true
    while changed {
        changed = false
        block_index = 0
        while block_index < body.blocks.len() {
            if reachable.get(block_index).unwrap() {
                let block = body.blocks.get(block_index).unwrap()
                let states = copy_slot_states(
                    entry_states.get(block_index).unwrap())
                for event in block.events {
                    apply_event_abstract(
                        event, body.slots, solved.logical_shapes,
                        solved.physical_shapes,
                        solved.callable_demands,
                        solved.callable_results_owned, states)
                }
                for usage in block.terminator_uses {
                    apply_demand_abstract(
                        usage.slot, usage.demand, body.slots,
                        solved.logical_shapes, solved.physical_shapes, states)
                }
                for edge in block.edges {
                    match edge.target_block {
                        some(target) => {
                            let edge_states = copy_slot_states(states)
                            apply_edge_cleanup_abstract(
                                edge, body.slots,
                                solved.logical_shapes,
                                solved.physical_shapes, edge_states)
                            if !reachable.get(target).unwrap() {
                                reachable.set(target, true)
                                entry_states.set(target, edge_states)
                                promotion_count = promotion_count + 1
                                changed = true
                            } else {
                                let previous = entry_states.get(target).unwrap()
                                let joined = join_slot_states(previous, edge_states)
                                if !slot_states_same(previous, joined) {
                                    entry_states.set(target, joined)
                                    promotion_count = promotion_count + 1
                                    changed = true
                                }
                            }
                            if promotion_count > exact_rank_budget {
                                panic("ResourcePlanner: CFG worklist rank budget exceeded")
                            }
                        },
                        none => {}
                    }
                }
            }
            block_index = block_index + 1
        }
    }
    BodyEntrySolution {
        reachable: reachable,
        entry_states: entry_states
    }
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
    require_concrete_resource_shape(
        logical, physical, "materialized value edge")
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

struct MaterializedStep {
    step: RcStep,
    certificate: CfgStepCertificate
}

fn materialize_event(
    body: PlannerBody, block_index: Int,
    event: PlannerEvent, event_index: Int,
    solved: SolvedResourceGraph, mut states: List<SlotFlow>
) -> MaterializedStep {
    let instruction = make_flow_instruction_ref(
        body.reference, block_index, event_index)
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
                if !slot_flow_same(before, slot_flow_unreachable()) {
                    let logical = solved.logical_shapes.get(
                        slot.type_index).unwrap()
                    let physical = solved.physical_shapes.get(
                        slot.type_index).unwrap()
                    if slot.owns_storage {
                        require_concrete_resource_shape(
                            logical, physical, "scope exit")
                    }
                    if slot.owns_storage &&
                       (physical_shape_may_drop(physical) ||
                        logical_shape_may_take(logical)) {
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
            let mut input_index = 0
            while input_index < input_slots.len() {
                apply_demand_materialized(
                    body, input_slots.get(input_index).unwrap(),
                    input_demands.get(input_index).unwrap(),
                    make_rc_instruction_site(
                        instruction, rc_site_before_instruction(), input_index),
                    solved, none, states, before_ops, before_transitions)
                input_index = input_index + 1
            }
            let before = states.get(target).unwrap()
            if slot_flow_same(before, slot_flow_live()) ||
               slot_flow_same(before, slot_flow_unreachable()) {
                panic("ResourcePlanner: initialize overwrites live storage")
            }
            states.set(target, slot_flow_live())
            push_transition(semantic_transitions, target, before,
                slot_flow_live(), slot_reason_call_result())
        },
        PlannerEventValue::InitializeEmptyValue(slot) => {
            let before = states.get(slot).unwrap()
            if slot_flow_same(before, slot_flow_live()) {
                panic("ResourcePlanner: empty initialization overwrites live slot")
            }
            states.set(slot, slot_flow_empty())
            push_transition(semantic_transitions, slot, before,
                slot_flow_empty(), slot_reason_init_empty())
        },
        PlannerEventValue::InitializeLiveValue(slot) => {
            let before = states.get(slot).unwrap()
            if slot_flow_same(before, slot_flow_live()) ||
               slot_flow_same(before, slot_flow_unreachable()) {
                panic("ResourcePlanner: live initialization lacks empty storage")
            }
            states.set(slot, slot_flow_live())
            push_transition(semantic_transitions, slot, before,
                slot_flow_live(), slot_reason_init_live())
        },
        PlannerEventValue::ReadValue { source, target } => {
            let source_before = states.get(source).unwrap()
            let target_before = states.get(target).unwrap()
            require_live_state(source_before, "read")
            if slot_flow_same(target_before, slot_flow_live()) ||
               slot_flow_same(target_before, slot_flow_unreachable()) {
                panic("ResourcePlanner: Read overwrites live storage")
            }
            let demand = if body.slots.get(target).unwrap().owns_storage {
                make_transfer_demand(param_mode_own(), false)
            } else {
                make_transfer_demand(param_mode_borrow(), false)
            }
            apply_demand_materialized(
                body, source, demand,
                make_rc_instruction_site(
                    instruction, rc_site_before_instruction(), 0),
                solved, some(target),
                states, before_ops, before_transitions)
            states.set(target, slot_flow_live())
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
                slot_flow_live(), target_reason)
        },
        PlannerEventValue::MutateValue {
            target, value: input, value_demand
        } => {
            let target_before = states.get(target).unwrap()
            require_live_state(target_before, "mutation target")
            push_transition(semantic_transitions, target, target_before,
                target_before, slot_reason_mutate())
            apply_demand_materialized(
                body, input, value_demand,
                make_rc_instruction_site(
                    instruction, rc_site_before_instruction(), 1),
                solved, none,
                states, before_ops, before_transitions)
        },
        PlannerEventValue::ConsumeValue(slot, force, target) => {
            match target {
                some(value) => {
                    let sink_state = states.get(value).unwrap()
                    if slot_flow_same(sink_state, slot_flow_live()) ||
                       slot_flow_same(sink_state, slot_flow_unreachable()) {
                        panic("ResourcePlanner: Consume sink is not empty")
                    }
                },
                none => {}
            }
            apply_demand_materialized(
                body, slot, make_transfer_demand(param_mode_own(), force),
                make_rc_instruction_site(
                    instruction, rc_site_before_instruction(), 0),
                solved, target, states, before_ops, before_transitions)
        },
        PlannerEventValue::DiscardValue(slot) => {
            let before = states.get(slot).unwrap()
            require_live_state(before, "discard")
            let type_index = body.slots.get(slot).unwrap().type_index
            let logical = solved.logical_shapes.get(type_index).unwrap()
            let physical = solved.physical_shapes.get(type_index).unwrap()
            require_concrete_resource_shape(logical, physical, "discard")
            if physical_shape_may_drop(physical) ||
               logical_shape_may_take(logical) {
                before_ops.push(make_rc_drop_at(
                    make_rc_instruction_site(
                        instruction, rc_site_before_instruction(), 0),
                    rc_slot_for(body, slot)))
                states.set(slot, slot_flow_empty())
                push_transition(before_transitions, slot, before,
                    slot_flow_empty(), slot_reason_drop())
            }
        },
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            let rhs_before = states.get(rhs_temp).unwrap()
            require_live_state(rhs_before, "Assign RHS temp")
            let rhs_type = body.slots.get(rhs_temp).unwrap().type_index
            require_concrete_resource_shape(
                solved.logical_shapes.get(rhs_type).unwrap(),
                solved.physical_shapes.get(rhs_type).unwrap(), "Assign RHS")
            let target_ref: SlotRef? = if planner_place_is_slot(target) {
                let target_slot = planner_place_slot(target)
                let target_before = states.get(target_slot).unwrap()
                require_writable_state(target_before, "Assign")
                let target_type = body.slots.get(target_slot).unwrap().type_index
                let target_logical = solved.logical_shapes.get(target_type).unwrap()
                let target_physical = solved.physical_shapes.get(target_type).unwrap()
                require_concrete_resource_shape(
                    target_logical, target_physical, "Assign target")
                if physical_shape_may_drop(target_physical) ||
                   logical_shape_may_take(target_logical) {
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
                require_concrete_resource_shape(
                    value_logical, value_physical, "projected Assign value")
                push_transition(semantic_transitions, base, base_before,
                    base_before, slot_reason_mutate())
                match planner_place_evaluated_index(target) {
                    some(index) => {
                        let index_before = states.get(index).unwrap()
                        require_live_state(index_before, "Assign evaluated index")
                        push_transition(semantic_transitions, index, index_before,
                            index_before, slot_reason_borrow())
                    },
                    none => {}
                }
                if physical_shape_may_drop(value_physical) ||
                   logical_shape_may_take(value_logical) {
                    before_ops.push(make_rc_drop_at(
                        make_rc_instruction_site(
                            instruction, rc_site_before_instruction(), 1),
                        rc_slot_for(body, base)))
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
                states.set(target_slot, slot_flow_live())
                push_transition(semantic_transitions, target_slot,
                    before_target_write, slot_flow_live(),
                    if slot_flow_same(before_target_write, slot_flow_empty()) {
                        slot_reason_take_target()
                    } else {
                        slot_reason_assign_scalar()
                    })
            }
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            result_owned, result_type_index,
            argument_slots, result_slot, ..
        } => {
            let demands = effective_call_demands(
                callable_indices, argument_demands,
                solved.callable_demands)
            let effective_result_owned = effective_call_result_owned(
                callable_indices, result_owned,
                solved.callable_results_owned)
            if effective_result_owned || result_slot.is_some() {
                require_concrete_resource_shape(
                    solved.logical_shapes.get(result_type_index).unwrap(),
                    solved.physical_shapes.get(result_type_index).unwrap(),
                    "call result")
            }
            let mut argument = 0
            while argument < argument_slots.len() {
                apply_demand_materialized(
                    body, argument_slots.get(argument).unwrap(),
                    demands.get(argument).unwrap(),
                    make_rc_instruction_site(
                        instruction, rc_site_before_instruction(), argument),
                    solved, none,
                    states, before_ops, before_transitions)
                argument = argument + 1
            }
            match result_slot {
                some(slot) => {
                    let before = states.get(slot).unwrap()
                    if slot_flow_same(before, slot_flow_live()) ||
                       slot_flow_same(before, slot_flow_unreachable()) {
                        panic("ResourcePlanner: call result overwrites live storage")
                    }
                    states.set(slot, slot_flow_live())
                    push_transition(semantic_transitions, slot, before,
                        slot_flow_live(), slot_reason_call_result())
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
                                slot_flow_live(), slot_flow_live(),
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
            source, target, whole_slot
        } => {
            let source_before = states.get(source).unwrap()
            let target_before = states.get(target).unwrap()
            require_live_state(source_before, "projection")
            if slot_flow_same(target_before, slot_flow_live()) ||
               slot_flow_same(target_before, slot_flow_unreachable()) {
                panic("ResourcePlanner: projection overwrites live storage")
            }
            let type_index = body.slots.get(source).unwrap().type_index
            let logical = solved.logical_shapes.get(type_index).unwrap()
            if !whole_slot && logical_shape_may_take(logical) {
                panic("ResourcePlanner: partial move of may-own projection")
            }
            let demand = if whole_slot && logical_shape_may_take(logical) {
                make_transfer_demand(param_mode_own(), false)
            } else if body.slots.get(target).unwrap().owns_storage {
                make_transfer_demand(param_mode_own(), false)
            } else {
                make_transfer_demand(param_mode_borrow(), false)
            }
            apply_demand_materialized(
                body, source, demand,
                make_rc_instruction_site(
                    instruction, rc_site_before_instruction(), 0),
                solved, some(target),
                states, before_ops, before_transitions)
            let before_target_write = states.get(target).unwrap()
            states.set(target, slot_flow_live())
            let target_reason = if logical_shape_may_take(logical) && whole_slot {
                slot_reason_take_target()
            } else if physical_shape_may_drop(
                    solved.physical_shapes.get(type_index).unwrap()) &&
                      body.slots.get(target).unwrap().owns_storage {
                slot_reason_clone_target()
            } else {
                slot_reason_assign_scalar()
            }
            push_transition(semantic_transitions, target, before_target_write,
                slot_flow_live(), target_reason)
        },
        PlannerEventValue::CaptureValue { source, target, demand } => {
            let target_before = states.get(target).unwrap()
            if slot_flow_same(target_before, slot_flow_live()) ||
               slot_flow_same(target_before, slot_flow_unreachable()) {
                panic("ResourcePlanner: capture overwrites live storage")
            }
            apply_demand_materialized(
                body, source, demand,
                make_rc_instruction_site(
                    instruction, rc_site_before_instruction(), 0),
                solved, some(target),
                states, before_ops, before_transitions)
            states.set(target, slot_flow_live())
            let mode = transfer_demand_mode(demand)
            let type_index = body.slots.get(source).unwrap().type_index
            let reason = if param_mode_same(mode, param_mode_own()) &&
                    (transfer_demand_force(demand) ||
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
                slot_flow_live(), reason)
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
    for slot_index in cleanup_slot_order(body.slots, edge.exited_scope_ids) {
        let slot = body.slots.get(slot_index).unwrap()
        let before = states.get(slot_index).unwrap()
        if !slot_flow_same(before, slot_flow_unreachable()) {
            let mut emitted_cleanup = false
            if slot.owns_storage {
                let logical = solved.logical_shapes.get(slot.type_index).unwrap()
                let physical = solved.physical_shapes.get(slot.type_index).unwrap()
                require_concrete_resource_shape(
                    logical, physical, "CFG exit")
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

struct PlannedBody {
    rc_body: RcBody,
    certificate: CfgBodyCertificate
}

fn plan_body(body: PlannerBody, solved: SolvedResourceGraph) -> PlannedBody {
    let entry_solution = solve_body_entry_states(body, solved)
    let mut entry_seed: List<SlotFlow> = []
    for slot in body.slots {
        entry_seed.push(if slot.initially_live {
            slot_flow_live()
        } else {
            slot_flow_empty()
        })
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
            body.entry_block, entry_seed, block_certificates)
    }
}

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

fn flow_resource_children(node: FlowTypeNode) -> List<FlowTypeRef> {
    let tag = flow_type_kind_tag(flow_type_node_kind(node))
    // Ptr pointees and callable signatures do not contribute to the value's
    // own resource representation. Nominal fields and structural elements do.
    if tag == 6 || tag == 7 || tag == 8 || tag == 9 {
        return flow_type_node_children(node)
    }
    []
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
    let foreign_contract = flow_type_node_foreign_contract(node)
    let managed_foreign = match foreign_contract {
        some(contract) => flow_foreign_contract_is_managed(contract),
        none => false
    }
    let mut children: List<Int> = []
    for child in flow_resource_children(node) {
        children.push(flow_type_ref_index(child))
    }
    let mut dependencies: List<PlannerResourceDependency> = []
    for edge in flow_type_node_resource_edges(node) {
        let child_index = flow_type_ref_index(flow_resource_edge_child(edge))
        let child_dependency = flow_resource_edge_child_dependency_ordinal(edge)
        let target = flow_resource_edge_target(edge)
        if flow_resource_dependency_target_is_parent(target) {
            dependencies.push(make_parent_resource_dependency(
                child_index, child_dependency,
                flow_resource_dependency_target_parent_ordinal(target)))
        } else {
            dependencies.push(make_concrete_resource_dependency(
                child_index, child_dependency,
                flow_type_ref_index(
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
        parameter_types.push(flow_type_ref_index(ty))
    }
    let contract = flow_callable_semantic_contract(callable)
    let mut seeds: List<TransferDemand> = []
    for role in flow_call_contract_parameter_roles(contract) {
        seeds.push(transfer_demand_from_flow_role(role))
    }
    let has_body = flow_callable_mode_same(
        flow_callable_mode(callable), flow_callable_mode_concrete_body())
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
        let mut parameter = 0
        while parameter < parameters.len() {
            if !flow_type_ref_same(
                    flow_slot_type(parameters.get(parameter).unwrap()),
                    flow_callable_parameter_types(callable).get(parameter).unwrap()) {
                panic("ResourcePlanner: parameter slot/signature type order differs")
            }
            parameter = parameter + 1
        }
    }
    make_planner_callable(
        flow_callable_reference(callable), parameter_types,
        flow_type_ref_index(flow_callable_result_type(callable)),
        seeds,
        flow_role_is_owned(flow_call_contract_result_role(contract)),
        flow_origin_ordinals(flow_call_contract_result_origin(contract)),
        [], has_body)
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
            flow_slot_index(slots, flow_place_slot(value)))
    }
    let projection = flow_place_projection(value)
    let index = match flow_place_evaluated_index(value) {
        some(slot) => some(flow_slot_index(slots, slot)),
        none => none
    }
    make_planner_project_place(
        flow_slot_index(slots, flow_place_base(value)),
        projection.is_some(), index,
        flow_type_ref_index(flow_place_value_type(value)))
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

fn planner_event_value_from_flow(
    instruction: FlowInstruction, slots: List<FlowSlot>,
    callables: List<FlowCallable>
) -> PlannerEvent {
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
            inputs, demands,
            flow_origin_ordinals(
                flow_operation_contract_target_origin(operation)),
            flow_slot_index(slots, flow_initialize_target(instruction)))
    }
    if tag == 1 {
        return make_planner_read(
            flow_slot_index(slots, flow_read_source(instruction)),
            flow_slot_index(slots, flow_read_target(instruction)))
    }
    if tag == 2 {
        let target_role = flow_mutate_target_role(instruction)
        if flow_semantic_role_tag(target_role) != 1 {
            panic("ResourcePlanner: mutate target is not exact MutBorrow")
        }
        return make_planner_mutate(
            flow_slot_index(slots, flow_mutate_target(instruction)),
            flow_slot_index(slots, flow_mutate_value(instruction)),
            transfer_demand_from_flow_role(
                flow_mutate_value_role(instruction)))
    }
    if tag == 3 {
        return make_planner_consume(
            flow_slot_index(slots, flow_consume_source(instruction)),
            false, none)
    }
    if tag == 4 {
        return make_planner_discard(
            flow_slot_index(slots, flow_discard_source(instruction)))
    }
    if tag == 5 {
        return make_planner_assign(
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
            planner_call_target_from_flow(target, slots, callables),
            if flow_call_target_is_direct(target) {
                [flow_callable_index(callables, flow_call_target_direct(target))]
            } else { [] },
            arguments, demands,
            flow_role_is_owned(flow_call_contract_result_role(contract)),
            flow_type_ref_index(flow_call_contract_result_type(contract)),
            flow_origin_ordinals(flow_call_contract_result_origin(contract)),
            result)
    }
    if tag == 7 {
        return make_planner_project(
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
            flow_slot_index(slots, flow_capture_source(instruction)),
            target_index, transfer_demand_from_flow_role(source_role))
    }
    if tag == 9 { return make_planner_noop() }
    if tag == 10 {
        return make_planner_scope_exit(flow_scope_ref_ordinal(
            flow_scope_instruction_scope(instruction)))
    }
    if tag == 11 {
        return make_planner_consume(
            flow_slot_index(slots, flow_fail_raise_payload(instruction)),
            true, some(flow_slot_index(
                slots, flow_fail_raise_sink(instruction))))
    }
    panic("ResourcePlanner: unknown FlowIR instruction kind")
}

fn planner_callable_provenance_from_flow(
    instruction: FlowInstruction, slots: List<FlowSlot>,
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>
) -> List<PlannerCallableProvenance> {
    let mut result: List<PlannerCallableProvenance> = []
    for fact in flow_instruction_callable_provenance(
            instruction, slots, type_nodes) {
        let target = flow_slot_index(
            slots, flow_callable_provenance_target(fact))
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
            let mut sources: List<Int> = []
            for source in flow_callable_origin_slots(origin) {
                sources.push(flow_slot_index(slots, source))
            }
            result.push(make_slots_planner_callable_provenance(
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
    terminator: FlowTerminator, slots: List<FlowSlot>,
    return_demand: TransferDemand
) -> List<PlannerTerminatorUse> {
    let mut result: List<PlannerTerminatorUse> = []
    let tag = flow_terminator_kind_tag(terminator)
    for slot in flow_terminator_read_slots(terminator) {
        result.push(make_planner_terminator_use(
            flow_slot_index(slots, slot),
            if tag == 3 {
                return_demand
            } else {
                make_transfer_demand(param_mode_borrow(), false)
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
            flow_type_ref_index(flow_slot_type(slot)),
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
        if flow_type_ref_index(flow_type_node_reference(node)) != type_index {
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
    let candidate_graph = build_candidate_proof_graph(callables, bodies)
    let candidate_base_proof = solve_candidate_proof_graph(candidate_graph)
    let candidate_proof = with_candidate_selections(
        candidate_base_proof,
        derive_candidate_selections(candidate_base_proof, bodies))
    let candidate_closed_bodies = resolve_bodies_from_candidate_proof(
        candidate_proof, bodies)
    let closed_callables = close_callable_body_dataflow(
        callables, candidate_closed_bodies)
    make_frozen_planner_input(
        flow_topology_fingerprint_canonical(
            flow_program_topology_fingerprint(program)),
        candidate_proof,
        types, closed_callables, candidate_closed_bodies)
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

fn planned_resources_logical_shapes(
    value: PlannedResources
) -> List<LogicalOwnershipShape> {
    copy_logical_shapes(value.logical_shapes)
}
fn planned_resources_physical_shapes(
    value: PlannedResources
) -> List<PhysicalRcShape> {
    copy_physical_shapes(value.physical_shapes)
}
fn planned_resources_callable_demands(
    value: PlannedResources
) -> List<List<TransferDemand>> {
    copy_callable_demands(value.callable_demands)
}
fn planned_resources_callable_results_owned(
    value: PlannedResources
) -> List<Bool> {
    let mut result: List<Bool> = []
    for owned in value.callable_results_owned { result.push(owned) }
    result
}
fn planned_resources_rc_program(value: PlannedResources) -> RcProgram {
    value.rc_program
}
fn planned_resources_certificate(
    value: PlannedResources
) -> ResourceCertificate { value.certificate }
fn plan_resources(input: FrozenPlannerInput) -> PlannedResources {
    let build = build_constraint_graph(input)
    let fixed_point = solve_constraint_graph(build)
    let solved = materialize_solved_graph(input, build, fixed_point)
    let mut rc_bodies: List<RcBody> = []
    let mut cfg_certificates: List<CfgBodyCertificate> = []
    for body in input.bodies {
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
    verify_resource_certificate(rc_program, certificate)
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

fn int_lists_same(left: List<Int>, right: List<Int>) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        if left.get(index).unwrap() != right.get(index).unwrap() {
            return false
        }
        index = index + 1
    }
    true
}

fn verify_fixed_graph_contract(
    input: FrozenPlannerInput, certificate: ResourceCertificate
) {
    let expected = build_constraint_graph(input)
    let proof = resource_certificate_fixed_point(certificate)
    let actual_cells = resource_fixed_point_cells(proof)
    let actual_constraints = resource_fixed_point_constraints(proof)
    if expected.cells.len() == 0 || expected.constraints.len() == 0 ||
       actual_cells.len() != expected.cells.len() ||
       actual_constraints.len() != expected.constraints.len() {
        panic("ResourcePlanner verifier: finite proof graph is empty or incomplete")
    }
    let mut cell_index = 0
    while cell_index < expected.cells.len() {
        let left = expected.cells.get(cell_index).unwrap()
        let right = actual_cells.get(cell_index).unwrap()
        if resource_cell_kind_tag(resource_cell_spec_kind(left)) !=
               resource_cell_kind_tag(resource_cell_spec_kind(right)) ||
           resource_cell_spec_owner_index(left) !=
               resource_cell_spec_owner_index(right) ||
           resource_cell_spec_component_index(left) !=
               resource_cell_spec_component_index(right) ||
           resource_cell_spec_max_rank(left) !=
               resource_cell_spec_max_rank(right) {
            panic("ResourcePlanner verifier: finite proof cell graph drifted")
        }
        cell_index = cell_index + 1
    }
    let mut constraint_index = 0
    while constraint_index < expected.constraints.len() {
        let left = expected.constraints.get(constraint_index).unwrap()
        let right = actual_constraints.get(constraint_index).unwrap()
        if resource_constraint_rule_tag(left) !=
               resource_constraint_rule_tag(right) ||
           resource_constraint_target_cell(left) !=
               resource_constraint_target_cell(right) ||
           resource_constraint_floor_rank(left) !=
               resource_constraint_floor_rank(right) ||
           !int_lists_same(
                resource_constraint_premise_cells(left),
                resource_constraint_premise_cells(right)) {
            panic("ResourcePlanner verifier: finite proof constraint graph drifted")
        }
        constraint_index = constraint_index + 1
    }
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

fn verify_candidate_graph_contract(
    input: FrozenPlannerInput, certificate: ResourceCertificate
) {
    let proof = resource_certificate_candidate_proof(certificate)
    let expected = build_candidate_proof_graph(
        input.callables, input.bodies)
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
    let expected_selections = derive_candidate_selections(proof, input.bodies)
    let actual_selections = callable_candidate_proof_selections(proof)
    if expected_selections.len() != actual_selections.len() {
        panic("ResourcePlanner verifier: call-site selection census drifted")
    }
    index = 0
    while index < expected_selections.len() {
        let actual = actual_selections.get(index).unwrap()
        let wanted = expected_selections.get(index).unwrap()
        if !flow_instruction_ref_same(
                candidate_selection_instruction(actual),
                candidate_selection_instruction(wanted)) ||
           !int_lists_same(
                candidate_selection_candidates(actual),
                candidate_selection_candidates(wanted)) {
            panic("ResourcePlanner verifier: certified call-site selection drifted")
        }
        index = index + 1
    }
}

fn slot_option_same(left: SlotRef?, right: SlotRef?) -> Bool {
    match (left, right) {
        (some(a), some(b)) => slot_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
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

fn verify_event_operation_contract(
    body: PlannerBody, event: PlannerEvent,
    before: List<RcOperation>, after: List<RcOperation>
) {
    match event.value {
        PlannerEventValue::NoOpValue |
        PlannerEventValue::InitializeEmptyValue(_) |
        PlannerEventValue::InitializeLiveValue(_) => {
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
        PlannerEventValue::InitializeValue { input_slots, .. } => {
            if after.len() != 0 {
                panic("ResourcePlanner verifier: Initialize has after-resource op")
            }
            for operation in before {
                let operand = rc_semantic_site_operand_ordinal(
                    rc_operation_site(operation))
                if operand < 0 || operand >= input_slots.len() {
                    panic("ResourcePlanner verifier: Initialize operand ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation,
                    body.slots.get(input_slots.get(operand).unwrap()).unwrap().reference,
                    none)
            }
        },
        PlannerEventValue::ReadValue { source, target } => {
            if after.len() != 0 {
                panic("ResourcePlanner verifier: Read has after-resource op")
            }
            for operation in before {
                if rc_semantic_site_operand_ordinal(
                        rc_operation_site(operation)) != 0 {
                    panic("ResourcePlanner verifier: Read operand ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation, body.slots.get(source).unwrap().reference,
                    some(body.slots.get(target).unwrap().reference))
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
            for operation in before {
                if rc_semantic_site_operand_ordinal(
                        rc_operation_site(operation)) != 0 {
                    panic("ResourcePlanner verifier: consume ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation, body.slots.get(slot).unwrap().reference,
                    target.map(fn(value) {
                        body.slots.get(value).unwrap().reference
                    }))
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
                    verify_operation_slots_exact(
                        operation, body.slots.get(rhs_temp).unwrap().reference,
                        if planner_place_is_slot(target) {
                            some(body.slots.get(
                                planner_place_slot(target)).unwrap().reference)
                        } else { none })
                } else if operand == 1 {
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
        PlannerEventValue::CallValue {
            argument_slots, result_slot, ..
        } => {
            for operation in before {
                let operand = rc_semantic_site_operand_ordinal(
                    rc_operation_site(operation))
                if operand < 0 || operand >= argument_slots.len() {
                    panic("ResourcePlanner verifier: call argument ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation,
                    body.slots.get(argument_slots.get(operand).unwrap()).unwrap().reference,
                    none)
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
        PlannerEventValue::ProjectValue { source, target, .. } |
        PlannerEventValue::CaptureValue { source, target, .. } => {
            if after.len() != 0 {
                panic("ResourcePlanner verifier: projection/capture has after-resource op")
            }
            for operation in before {
                if rc_semantic_site_operand_ordinal(
                        rc_operation_site(operation)) != 0 {
                    panic("ResourcePlanner verifier: projection/capture ordinal drifted")
                }
                verify_operation_slots_exact(
                    operation, body.slots.get(source).unwrap().reference,
                    some(body.slots.get(target).unwrap().reference))
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

fn verify_rc_topology_contract(
    input: FrozenPlannerInput, rc_program: RcProgram,
    certificate: ResourceCertificate
) {
    if rc_program_flow_fingerprint(rc_program) != input.flow_fingerprint ||
       rc_program_type_count(rc_program) != input.type_nodes.len() ||
       rc_program_callable_count(rc_program) != input.callables.len() {
        panic("ResourcePlanner verifier: RcIR frozen graph census drifted")
    }
    let rc_bodies = rc_program_bodies(rc_program)
    let cfg_bodies = resource_certificate_cfg_bodies(certificate)
    if rc_bodies.len() != input.bodies.len() ||
       cfg_bodies.len() != input.bodies.len() {
        panic("ResourcePlanner verifier: executable body census drifted")
    }
    let mut body_index = 0
    while body_index < input.bodies.len() {
        let expected_body = input.bodies.get(body_index).unwrap()
        let rc_body = rc_bodies.get(body_index).unwrap()
        let cfg_body = cfg_bodies.get(body_index).unwrap()
        if !executable_ref_same(
                expected_body.reference, rc_body_reference(rc_body)) ||
           expected_body.entry_block != rc_body_entry_block(rc_body) ||
           expected_body.entry_block !=
                cfg_body_certificate_entry_block(cfg_body) {
            panic("ResourcePlanner verifier: body identity/entry drifted")
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
            let mut step_index = 0
            while step_index < rc_steps.len() {
                let exact_instruction = make_flow_instruction_ref(
                    expected_body.reference, block_index, step_index)
                if rc_step_semantic_op_index(
                        rc_steps.get(step_index).unwrap()) != step_index ||
                   !flow_instruction_ref_same(
                        rc_step_instruction(rc_steps.get(step_index).unwrap()),
                        exact_instruction) ||
                   !flow_instruction_ref_same(
                        cfg_step_certificate_instruction(
                            cfg_steps.get(step_index).unwrap()),
                        exact_instruction) {
                    panic("ResourcePlanner verifier: instruction identity drifted")
                }
                verify_event_operation_contract(
                    expected_body,
                    expected_block.events.get(step_index).unwrap(),
                    rc_step_before(rc_steps.get(step_index).unwrap()),
                    rc_step_after(rc_steps.get(step_index).unwrap()))
                step_index = step_index + 1
            }
            verify_terminator_operation_contract(
                expected_body, expected_block,
                rc_block_before_terminator(rc_block))
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
                verify_edge_operation_contract(
                    expected_body, expected_edge,
                    rc_edge_cleanup(rc_edge))
                edge_index = edge_index + 1
            }
            block_index = block_index + 1
        }
        body_index = body_index + 1
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

pub fn verify_and_plan_resource_program(
    program: FlowProgram
) -> VerifiedResourceProgram {
    validate_flow_program(program)
    let planning_input = make_frozen_planner_input_from_flow(program)
    let planned = plan_resources(planning_input)
    // Rebuild rule graphs from the typed adapter facts, but never rerun either
    // fixed-point solver. Ranked certificate promotions prove both solutions.
    verify_candidate_graph_contract(planning_input, planned.certificate)
    verify_fixed_graph_contract(planning_input, planned.certificate)
    verify_rc_topology_contract(
        planning_input, planned.rc_program, planned.certificate)
    verify_resource_certificate(planned.rc_program, planned.certificate)
    VerifiedResourceProgram {
        flow_fingerprint: planning_input.flow_fingerprint,
        rc_program: planned.rc_program,
        certificate: planned.certificate
    }
}

pub fn verified_resource_program_flow_fingerprint(
    value: VerifiedResourceProgram
) -> Str { value.flow_fingerprint }

pub fn verified_resource_program_rc_ir(
    value: VerifiedResourceProgram
) -> RcProgram { value.rc_program }
