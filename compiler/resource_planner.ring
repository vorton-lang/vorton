// ONE ResourcePlanner authority for frozen FlowIR.
//
// This file owns the finite type-shape/callable solve and the per-body slot
// state machine.  Its input is a deliberately narrow, index-stable adapter
// snapshot populated from frozen FlowIR.  It never resolves a name, compares a
// source/span spelling, re-runs type/effect/trait selection, or creates a
// semantic binder/block/edge.  The final FlowProgram adapter constructor is
// intentionally the only glue point to the concurrently landed flow_ir API.

use ir_identity::{SlotRef, slot_ref_same}
use ir_inventory::{ExecutableRef, executable_ref_same}
use flow_ir::{
    FlowProgram, FlowTypeNode, FlowTypeRef, FlowSemanticRole,
    FlowCallable, FlowBody, FlowSlot, FlowScope, FlowScopeRef,
    FlowInstruction, FlowTerminator, FlowCallTarget,
    validate_flow_program,
    flow_program_type_nodes, flow_program_callables, flow_program_bodies,
    flow_program_topology_fingerprint,
    flow_topology_fingerprint_canonical,
    flow_type_ref_index, flow_type_ref_same,
    flow_type_node_reference, flow_type_node_kind,
    flow_type_node_children, flow_type_node_generic_param,
    flow_type_node_semantic_seed, flow_type_node_drop_contract,
    flow_type_node_foreign_contract,
    flow_type_kind_tag, flow_type_semantic_seed_tag,
    flow_generic_param_index, flow_generic_param_arity,
    flow_foreign_contract_is_managed,
    flow_semantic_role_tag,
    flow_call_contract_parameter_roles, flow_call_contract_result_role,
    flow_callable_reference, flow_callable_parameter_types,
    flow_callable_parameter_slots,
    flow_callable_result_type, flow_callable_mode,
    flow_callable_mode_concrete_body, flow_callable_mode_same,
    flow_callable_semantic_contract, flow_callable_call_edges,
    flow_call_edge_target, flow_call_edge_arguments, flow_call_edge_result,
    flow_call_target_contract, flow_call_target_candidates,
    flow_body_reference, flow_body_scopes, flow_body_slots,
    flow_body_entry, flow_body_blocks, flow_body_exit_edges,
    flow_scope_reference, flow_scope_has_parent, flow_scope_parent,
    flow_scope_ref_ordinal, flow_scope_ref_same,
    flow_slot_reference, flow_slot_type, flow_slot_scope,
    flow_slot_reverse_ordinal, flow_slot_initial_state,
    flow_slot_storage, flow_slot_storage_contract,
    flow_slot_parameter_ordinal,
    flow_initial_slot_state_tag, flow_storage_class_tag,
    flow_storage_contract_tag,
    flow_block_reference, flow_block_instructions, flow_block_terminator,
    flow_block_ref_ordinal,
    flow_instruction_kind_tag,
    flow_initialize_operation, flow_initialize_inputs,
    flow_initialize_target,
    flow_operation_contract_input_roles,
    flow_read_source, flow_read_target,
    flow_mutate_target, flow_mutate_value,
    flow_mutate_target_role, flow_mutate_value_role,
    flow_consume_source, flow_discard_source,
    flow_assign_rhs_temp, flow_assign_target,
    flow_call_target, flow_call_arguments, flow_call_result,
    flow_project_base, flow_project_result, flow_project_is_partial,
    flow_capture_source, flow_capture_target, flow_capture_source_role,
    flow_capture_target_role,
    flow_scope_instruction_scope,
    flow_terminator_kind_tag, flow_terminator_successors,
    flow_terminator_read_slots, flow_terminator_terminal_exited_scopes,
    flow_successor_target, flow_successor_exited_scopes,
    flow_exit_kind_tag, flow_exit_edge_kind, flow_exit_edge_value}
use resource_model::{
    ParamMode, TransferDemand,
    LogicalOwnershipShape, PhysicalRcShape,
    SlotFlow,
    param_mode_from_tag, param_mode_tag, param_mode_same,
    param_mode_bottom, param_mode_borrow, param_mode_mut_borrow,
    param_mode_own, param_mode_is_conflict,
    make_transfer_demand, transfer_demand_mode,
    transfer_demand_force, transfer_demand_join,
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
    make_rc_program, make_rc_body, make_rc_block, make_rc_step,
    make_rc_edge, make_rc_slot,
    make_rc_clone, make_rc_take, make_rc_drop, make_rc_cleanup,
    rc_program_flow_fingerprint}
use resource_certificate::{
    ResourceCellKind, ResourceCellSpec, ResourceConstraint, ResourcePromotion,
    ResourceFixedPointProof, ResourceCertificate,
    VerifiedResourceCertificate,
    CfgBodyCertificate, CfgBlockCertificate, CfgEdgeCertificate,
    SlotTransitionReason, SlotTransitionWitness,
    make_resource_cell_spec, make_resource_constraint,
    make_resource_promotion, make_resource_fixed_point_proof,
    make_resource_certificate,
    make_cfg_body_certificate, make_cfg_block_certificate,
    make_cfg_edge_certificate, make_slot_transition_witness,
    resource_cell_kind_logical_shape,
    resource_cell_kind_physical_shape,
    resource_cell_kind_callable_param_mode,
    resource_cell_kind_callable_force,
    resource_cell_kind_callable_result,
    resource_cell_spec_max_rank,
    resource_constraint_target_cell,
    resource_constraint_floor_rank,
    resource_constraint_premise_cells,
    resource_fixed_point_final_ranks,
    slot_reason_init_empty, slot_reason_init_live,
    slot_reason_borrow, slot_reason_mutate,
    slot_reason_clone_source, slot_reason_clone_target,
    slot_reason_take_source, slot_reason_take_target,
    slot_reason_drop, slot_reason_cleanup,
    slot_reason_assign_scalar, slot_reason_call_result,
    slot_reason_scope_end,
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

pub struct PlannerTypeNode {
    kind: PlannerTypeKind,
    child_type_indices: List<Int>,
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
    PlannerTypeNode {
        kind: kind,
        child_type_indices: children,
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

enum PlannerArgumentSourceValue {
    CallerParameterValue(Int),
    LocalValue
}

pub struct PlannerArgumentSource { value: PlannerArgumentSourceValue }

pub fn make_caller_parameter_source(index: Int) -> PlannerArgumentSource {
    if index < 0 { panic("ResourcePlanner: negative caller parameter index") }
    PlannerArgumentSource {
        value: PlannerArgumentSourceValue::CallerParameterValue(index)
    }
}

pub fn make_local_argument_source() -> PlannerArgumentSource {
    PlannerArgumentSource { value: PlannerArgumentSourceValue::LocalValue }
}

fn planner_argument_source_parameter(value: PlannerArgumentSource) -> Int? {
    match value.value {
        PlannerArgumentSourceValue::CallerParameterValue(index) => some(index),
        PlannerArgumentSourceValue::LocalValue => none
    }
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
    for source in argument_sources { sources.push(source) }
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
    call_edges: List<PlannerCallEdge>,
    has_body: Bool
}

pub fn make_planner_callable(
    reference: ExecutableRef,
    parameter_type_indices: List<Int>, result_type_index: Int,
    parameter_seeds: List<TransferDemand>, result_owned_seed: Bool,
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
            value.result_owned_seed, value.call_edges, value.has_body))
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
    initially_live: Bool,
    owns_storage: Bool
}

pub fn make_planner_slot(
    reference: SlotRef, type_index: Int,
    scope_id: Int, scope_depth: Int,
    reverse_lexical_ordinal: Int,
    initially_live: Bool, owns_storage: Bool
) -> PlannerSlot {
    if type_index < 0 || scope_id < 0 || scope_depth < 0 ||
       reverse_lexical_ordinal < 0 {
        panic("ResourcePlanner: invalid frozen slot metadata")
    }
    PlannerSlot {
        reference: reference,
        type_index: type_index,
        scope_id: scope_id,
        scope_depth: scope_depth,
        reverse_lexical_ordinal: reverse_lexical_ordinal,
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
            value.initially_live, value.owns_storage))
    }
    result
}

enum PlannerEventValue {
    NoOpValue,
    ScopeExitValue(Int),
    InitializeValue {
        input_slots: List<Int>,
        input_demands: List<TransferDemand>,
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
    ConsumeValue(Int, Bool),
    DiscardValue(Int),
    AssignValue { rhs_temp: Int, target: Int },
    CallValue {
        callable_indices: List<Int>,
        argument_demands: List<TransferDemand>,
        result_owned: Bool,
        result_type_index: Int,
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

pub struct PlannerEvent { value: PlannerEventValue }

pub fn make_planner_noop() -> PlannerEvent {
    PlannerEvent { value: PlannerEventValue::NoOpValue }
}

pub fn make_planner_scope_exit(scope_id: Int) -> PlannerEvent {
    if scope_id < 0 { panic("ResourcePlanner: negative lexical scope exit") }
    PlannerEvent { value: PlannerEventValue::ScopeExitValue(scope_id) }
}

pub fn make_planner_initialize(
    input_slots: List<Int>, input_demands: List<TransferDemand>, target: Int
) -> PlannerEvent {
    if input_slots.len() != input_demands.len() {
        panic("ResourcePlanner: initialize input/demand census differs")
    }
    let mut slots: List<Int> = []
    let mut demands: List<TransferDemand> = []
    for slot in input_slots { slots.push(slot) }
    for demand in input_demands {
        if param_mode_is_conflict(transfer_demand_mode(demand)) {
            panic("ResourcePlanner: initialize demand is conflicting")
        }
        demands.push(make_transfer_demand(
            transfer_demand_mode(demand), transfer_demand_force(demand)))
    }
    PlannerEvent {
        value: PlannerEventValue::InitializeValue {
            input_slots: slots, input_demands: demands, target: target
        }
    }
}

pub fn make_planner_initialize_empty(slot: Int) -> PlannerEvent {
    PlannerEvent { value: PlannerEventValue::InitializeEmptyValue(slot) }
}
pub fn make_planner_initialize_live(slot: Int) -> PlannerEvent {
    PlannerEvent { value: PlannerEventValue::InitializeLiveValue(slot) }
}
pub fn make_planner_read(source: Int, target: Int) -> PlannerEvent {
    PlannerEvent {
        value: PlannerEventValue::ReadValue {
            source: source, target: target
        }
    }
}
pub fn make_planner_mutate(
    target: Int, value: Int, value_demand: TransferDemand
) -> PlannerEvent {
    if param_mode_is_conflict(transfer_demand_mode(value_demand)) {
        panic("ResourcePlanner: mutate value demand is conflicting")
    }
    PlannerEvent {
        value: PlannerEventValue::MutateValue {
            target: target, value: value,
            value_demand: make_transfer_demand(
                transfer_demand_mode(value_demand),
                transfer_demand_force(value_demand))
        }
    }
}
pub fn make_planner_consume(slot: Int, force: Bool) -> PlannerEvent {
    PlannerEvent { value: PlannerEventValue::ConsumeValue(slot, force) }
}
pub fn make_planner_discard(slot: Int) -> PlannerEvent {
    PlannerEvent { value: PlannerEventValue::DiscardValue(slot) }
}
pub fn make_planner_assign(rhs_temp: Int, target: Int) -> PlannerEvent {
    PlannerEvent {
        value: PlannerEventValue::AssignValue {
            rhs_temp: rhs_temp, target: target
        }
    }
}
pub fn make_planner_call(
    callable_indices: List<Int>, argument_slots: List<Int>,
    argument_demands: List<TransferDemand>,
    result_owned: Bool, result_type_index: Int, result_slot: Int?
) -> PlannerEvent {
    if callable_indices.len() == 0 ||
       argument_slots.len() != argument_demands.len() ||
       result_type_index < 0 {
        panic("ResourcePlanner: call contract is incomplete")
    }
    let mut candidates: List<Int> = []
    let mut arguments: List<Int> = []
    let mut demands: List<TransferDemand> = []
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
    PlannerEvent {
        value: PlannerEventValue::CallValue {
            callable_indices: candidates,
            argument_demands: demands,
            result_owned: result_owned,
            result_type_index: result_type_index,
            argument_slots: arguments,
            result_slot: result_slot
        }
    }
}
pub fn make_planner_project(
    source: Int, target: Int, whole_slot: Bool
) -> PlannerEvent {
    PlannerEvent {
        value: PlannerEventValue::ProjectValue {
            source: source, target: target, whole_slot: whole_slot
        }
    }
}
pub fn make_planner_capture(
    source: Int, target: Int, demand: TransferDemand
) -> PlannerEvent {
    if param_mode_is_conflict(transfer_demand_mode(demand)) {
        panic("ResourcePlanner: capture demand is conflicting")
    }
    PlannerEvent {
        value: PlannerEventValue::CaptureValue {
            source: source,
            target: target,
            demand: make_transfer_demand(
                transfer_demand_mode(demand),
                transfer_demand_force(demand))
        }
    }
}

fn copy_planner_event(value: PlannerEvent) -> PlannerEvent {
    match value.value {
        PlannerEventValue::NoOpValue => make_planner_noop(),
        PlannerEventValue::ScopeExitValue(scope_id) =>
            make_planner_scope_exit(scope_id),
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, target
        } => make_planner_initialize(input_slots, input_demands, target),
        PlannerEventValue::InitializeEmptyValue(slot) =>
            make_planner_initialize_empty(slot),
        PlannerEventValue::InitializeLiveValue(slot) =>
            make_planner_initialize_live(slot),
        PlannerEventValue::ReadValue { source, target } =>
            make_planner_read(source, target),
        PlannerEventValue::MutateValue {
            target, value: input, value_demand
        } => make_planner_mutate(target, input, value_demand),
        PlannerEventValue::ConsumeValue(slot, force) =>
            make_planner_consume(slot, force),
        PlannerEventValue::DiscardValue(slot) => make_planner_discard(slot),
        PlannerEventValue::AssignValue { rhs_temp, target } =>
            make_planner_assign(rhs_temp, target),
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            result_owned, result_type_index,
            argument_slots, result_slot
        } => make_planner_call(
            callable_indices, argument_slots, argument_demands,
            result_owned, result_type_index, result_slot),
        PlannerEventValue::ProjectValue {
            source, target, whole_slot
        } => make_planner_project(source, target, whole_slot),
        PlannerEventValue::CaptureValue { source, target, demand } =>
            make_planner_capture(source, target, demand)
    }
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
    events: List<PlannerEvent>,
    terminator_uses: List<PlannerTerminatorUse>,
    edges: List<PlannerEdge>
}

pub fn make_planner_block(
    events: List<PlannerEvent>,
    terminator_uses: List<PlannerTerminatorUse>,
    edges: List<PlannerEdge>
) -> PlannerBlock {
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
            block.events, block.terminator_uses, block.edges))
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

pub struct FrozenPlannerInput {
    flow_fingerprint: Str,
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
    match event.value {
        PlannerEventValue::NoOpValue => {},
        PlannerEventValue::ScopeExitValue(scope_id) => {
            if planner_scope_depth(scopes, scope_id).is_none() {
                panic("ResourcePlanner: scope-exit marker has no frozen scope")
            }
        },
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, target
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
        PlannerEventValue::ConsumeValue(slot, _) =>
            validate_slot_index(slot, slots),
        PlannerEventValue::DiscardValue(slot) =>
            validate_slot_index(slot, slots),
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            validate_slot_index(rhs_temp, slots)
            validate_slot_index(target, slots)
            if rhs_temp == target {
                panic("ResourcePlanner: Assign temp aliases target")
            }
            if !slots.get(rhs_temp).unwrap().owns_storage ||
               !slots.get(target).unwrap().owns_storage {
                panic("ResourcePlanner: Assign lacks precreated owning storage")
            }
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            result_owned: _, result_type_index,
            argument_slots, result_slot
        } => {
            if callable_indices.len() == 0 ||
               argument_slots.len() != argument_demands.len() ||
               result_type_index < 0 ||
               result_type_index >= type_nodes.len() {
                panic("ResourcePlanner: call contract is incomplete")
            }
            for callable_index in callable_indices {
                if callable_index < 0 || callable_index >= callables.len() {
                    panic("ResourcePlanner: call lacks exact callable candidate")
                }
                if argument_slots.len() != callables.get(
                        callable_index).unwrap().parameter_type_indices.len() {
                    panic("ResourcePlanner: call candidate arity differs")
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

pub fn make_frozen_planner_input(
    flow_fingerprint: Str,
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
            if child_node.type_parameter_count > node.type_parameter_count {
                panic("ResourcePlanner: child type parameter domain escapes parent")
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
                match planner_argument_source_parameter(source) {
                    some(parameter) => if parameter < 0 || parameter >=
                                             callable.parameter_type_indices.len() {
                        panic("ResourcePlanner: callable edge source parameter is absent")
                    },
                    none => {}
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
        type_nodes: copied_types,
        callables: copied_callables,
        bodies: copied_bodies
    }
}

pub fn frozen_planner_input_flow_fingerprint(
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
            let mut parameter = 0
            while parameter < child.parameter_count {
                add_constraint(constraints, RULE_TYPE_CHILD,
                    layout.logical_start + 2 + parameter, 0,
                    [child.logical_start + 2 + parameter])
                add_constraint(constraints, RULE_TYPE_CHILD,
                    layout.physical_start + 4 + parameter, 0,
                    [child.physical_start + 4 + parameter])
                parameter = parameter + 1
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
                match planner_argument_source_parameter(
                        edge.argument_sources.get(argument).unwrap()) {
                    some(caller_parameter) => {
                        add_constraint(constraints, RULE_CALLABLE_EDGE,
                            layout.mode_start + caller_parameter, 0,
                            [callee.mode_start + argument])
                        add_constraint(constraints, RULE_CALLABLE_EDGE,
                            layout.force_start + caller_parameter, 0,
                            [callee.force_start + argument])
                    },
                    none => {}
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
        logical_ownership_shape_may_unique(shape) ||
        bool_list_has_true(logical_ownership_shape_param_deps(shape))
}

fn physical_shape_may_drop(shape: PhysicalRcShape) -> Bool {
    physical_rc_shape_physical_rc(shape) ||
        physical_rc_shape_drop_glue(shape) ||
        bool_list_has_true(physical_rc_shape_param_deps(shape))
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
                let before = states.get(slot_index).unwrap()
                if !slot_flow_same(before, slot_flow_unreachable()) {
                    states.set(slot_index, slot_flow_empty())
                }
            }
        },
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, target
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
        PlannerEventValue::ConsumeValue(slot, force) =>
            apply_demand_abstract(
                slot, make_transfer_demand(param_mode_own(), force),
                slots, logical_shapes, physical_shapes, states),
        PlannerEventValue::DiscardValue(slot) => {
            require_live_state(states.get(slot).unwrap(), "discard")
            let type_index = slots.get(slot).unwrap().type_index
            if physical_shape_may_drop(
                    physical_shapes.get(type_index).unwrap()) ||
               logical_shape_may_take(
                    logical_shapes.get(type_index).unwrap()) {
                states.set(slot, slot_flow_empty())
            }
        },
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            require_live_state(states.get(rhs_temp).unwrap(), "Assign RHS temp")
            require_writable_state(states.get(target).unwrap(), "Assign")
            // The semantic event occurs only after its RHS-producing events.
            // Resource materialization later emits Drop-old then Take(temp).
            states.set(target, slot_flow_live())
            states.set(rhs_temp, slot_flow_moved())
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            result_owned, result_type_index,
            argument_slots, result_slot
        } => {
            let demands = effective_call_demands(
                callable_indices, argument_demands, callable_demands)
            let effective_result_owned = effective_call_result_owned(
                callable_indices, result_owned, callable_results_owned)
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
    mut states: List<SlotFlow>
) {
    for slot_index in cleanup_slot_order(slots, edge.exited_scope_ids) {
        let slot = slots.get(slot_index).unwrap()
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
                                edge, body.slots, edge_states)
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
    solved: SolvedResourceGraph,
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
        operations.push(make_rc_take(rc_slot_for(body, slot), target_ref))
        states.set(slot, slot_flow_moved())
        push_transition(transitions, slot, before,
            slot_flow_moved(), slot_reason_take_source())
    } else if physical_shape_may_drop(physical) {
        operations.push(make_rc_clone(rc_slot_for(body, slot), target_ref))
        push_transition(transitions, slot, before,
            before, slot_reason_clone_source())
    } else {
        push_transition(transitions, slot, before,
            before, slot_reason_borrow())
    }
}

struct MaterializedStep {
    step: RcStep,
    transitions: List<SlotTransitionWitness>
}

fn materialize_event(
    body: PlannerBody, event: PlannerEvent, event_index: Int,
    solved: SolvedResourceGraph, mut states: List<SlotFlow>
) -> MaterializedStep {
    let mut before_ops: List<RcOperation> = []
    let mut after_ops: List<RcOperation> = []
    let transitions: List<SlotTransitionWitness> = []
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
                    if slot.owns_storage &&
                       (physical_shape_may_drop(physical) ||
                        logical_shape_may_take(logical)) {
                        before_ops.push(make_rc_cleanup(slot.reference))
                        push_transition(transitions, slot_index, before,
                            slot_flow_empty(), slot_reason_cleanup())
                    } else {
                        push_transition(transitions, slot_index, before,
                            slot_flow_empty(), slot_reason_scope_end())
                    }
                    states.set(slot_index, slot_flow_empty())
                }
            }
        },
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, target
        } => {
            let mut input_index = 0
            while input_index < input_slots.len() {
                apply_demand_materialized(
                    body, input_slots.get(input_index).unwrap(),
                    input_demands.get(input_index).unwrap(),
                    solved, none, states, before_ops, transitions)
                input_index = input_index + 1
            }
            let before = states.get(target).unwrap()
            if slot_flow_same(before, slot_flow_live()) ||
               slot_flow_same(before, slot_flow_unreachable()) {
                panic("ResourcePlanner: initialize overwrites live storage")
            }
            states.set(target, slot_flow_live())
            push_transition(transitions, target, before,
                slot_flow_live(), slot_reason_call_result())
        },
        PlannerEventValue::InitializeEmptyValue(slot) => {
            let before = states.get(slot).unwrap()
            if slot_flow_same(before, slot_flow_live()) {
                panic("ResourcePlanner: empty initialization overwrites live slot")
            }
            states.set(slot, slot_flow_empty())
            push_transition(transitions, slot, before,
                slot_flow_empty(), slot_reason_init_empty())
        },
        PlannerEventValue::InitializeLiveValue(slot) => {
            let before = states.get(slot).unwrap()
            if slot_flow_same(before, slot_flow_live()) ||
               slot_flow_same(before, slot_flow_unreachable()) {
                panic("ResourcePlanner: live initialization lacks empty storage")
            }
            states.set(slot, slot_flow_live())
            push_transition(transitions, slot, before,
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
                body, source, demand, solved, some(target),
                states, before_ops, transitions)
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
            push_transition(transitions, target, target_before,
                slot_flow_live(), target_reason)
        },
        PlannerEventValue::MutateValue {
            target, value: input, value_demand
        } => {
            let target_before = states.get(target).unwrap()
            require_live_state(target_before, "mutation target")
            push_transition(transitions, target, target_before,
                target_before, slot_reason_mutate())
            apply_demand_materialized(
                body, input, value_demand, solved, none,
                states, before_ops, transitions)
        },
        PlannerEventValue::ConsumeValue(slot, force) =>
            apply_demand_materialized(
                body, slot, make_transfer_demand(param_mode_own(), force),
                solved, none, states, before_ops, transitions),
        PlannerEventValue::DiscardValue(slot) => {
            let before = states.get(slot).unwrap()
            require_live_state(before, "discard")
            let type_index = body.slots.get(slot).unwrap().type_index
            let logical = solved.logical_shapes.get(type_index).unwrap()
            let physical = solved.physical_shapes.get(type_index).unwrap()
            if physical_shape_may_drop(physical) ||
               logical_shape_may_take(logical) {
                before_ops.push(make_rc_drop(rc_slot_for(body, slot)))
                states.set(slot, slot_flow_empty())
                push_transition(transitions, slot, before,
                    slot_flow_empty(), slot_reason_drop())
            }
        },
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            let rhs_before = states.get(rhs_temp).unwrap()
            let target_before = states.get(target).unwrap()
            require_live_state(rhs_before, "Assign RHS temp")
            require_writable_state(target_before, "Assign")
            let target_type = body.slots.get(target).unwrap().type_index
            let target_logical = solved.logical_shapes.get(target_type).unwrap()
            let target_physical = solved.physical_shapes.get(target_type).unwrap()
            if physical_shape_may_drop(target_physical) ||
               logical_shape_may_take(target_logical) {
                // Exact order: all RHS events already ran; only now Drop old.
                before_ops.push(make_rc_drop(rc_slot_for(body, target)))
                states.set(target, slot_flow_empty())
                push_transition(transitions, target, target_before,
                    slot_flow_empty(), slot_reason_drop())
            }
            // Take saves the already-evaluated temp, clears it, and feeds the
            // existing semantic Assign destination.  No slot is created here.
            before_ops.push(make_rc_take(
                rc_slot_for(body, rhs_temp), some(rc_slot_for(body, target))))
            states.set(rhs_temp, slot_flow_moved())
            push_transition(transitions, rhs_temp, rhs_before,
                slot_flow_moved(), slot_reason_take_source())
            let before_target_write = states.get(target).unwrap()
            states.set(target, slot_flow_live())
            push_transition(transitions, target, before_target_write,
                slot_flow_live(),
                if slot_flow_same(before_target_write, slot_flow_empty()) {
                    slot_reason_take_target()
                } else {
                    slot_reason_assign_scalar()
                })
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            result_owned, result_type_index,
            argument_slots, result_slot
        } => {
            let demands = effective_call_demands(
                callable_indices, argument_demands,
                solved.callable_demands)
            let effective_result_owned = effective_call_result_owned(
                callable_indices, result_owned,
                solved.callable_results_owned)
            let mut argument = 0
            while argument < argument_slots.len() {
                apply_demand_materialized(
                    body, argument_slots.get(argument).unwrap(),
                    demands.get(argument).unwrap(), solved, none,
                    states, before_ops, transitions)
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
                    push_transition(transitions, slot, before,
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
                            after_ops.push(make_rc_clone(
                                rc_slot_for(body, slot), none))
                            push_transition(transitions, slot,
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
                body, source, demand, solved, some(target),
                states, before_ops, transitions)
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
            push_transition(transitions, target, before_target_write,
                slot_flow_live(), target_reason)
        },
        PlannerEventValue::CaptureValue { source, target, demand } => {
            let target_before = states.get(target).unwrap()
            if slot_flow_same(target_before, slot_flow_live()) ||
               slot_flow_same(target_before, slot_flow_unreachable()) {
                panic("ResourcePlanner: capture overwrites live storage")
            }
            apply_demand_materialized(
                body, source, demand, solved, some(target),
                states, before_ops, transitions)
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
            push_transition(transitions, target, target_before,
                slot_flow_live(), reason)
        }
    }
    MaterializedStep {
        step: make_rc_step(event_index, before_ops, after_ops),
        transitions: transitions
    }
}

struct MaterializedEdge {
    edge: RcEdge,
    certificate: CfgEdgeCertificate
}

fn materialize_edge(
    body: PlannerBody, edge: PlannerEdge, edge_index: Int,
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
                if physical_shape_may_drop(physical) ||
                   logical_shape_may_take(logical) {
                    cleanup_ops.push(make_rc_cleanup(slot.reference))
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
            edge.target_block, states, transitions)
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
            let mut event_index = 0
            while event_index < block.events.len() {
                steps.push(make_rc_step(event_index, [], []))
                event_index = event_index + 1
            }
            let mut edges: List<RcEdge> = []
            let mut edge_proofs: List<CfgEdgeCertificate> = []
            let mut edge_index = 0
            while edge_index < block.edges.len() {
                let edge = block.edges.get(edge_index).unwrap()
                edges.push(make_rc_edge(edge_index, edge.target_block, []))
                edge_proofs.push(make_cfg_edge_certificate(
                    edge.target_block, entry_states, []))
                edge_index = edge_index + 1
            }
            rc_blocks.push(make_rc_block(
                block_index, block.events.len(), steps, [], edges))
            block_certificates.push(make_cfg_block_certificate(
                block_index, entry_states, [], edge_proofs))
            block_index = block_index + 1
            continue
        }
        let states = copy_slot_states(entry_states)
        let mut steps: List<RcStep> = []
        let mut semantic_transitions: List<SlotTransitionWitness> = []
        let mut event_index = 0
        while event_index < block.events.len() {
            let materialized = materialize_event(
                body, block.events.get(event_index).unwrap(),
                event_index, solved, states)
            steps.push(materialized.step)
            for transition in materialized.transitions {
                semantic_transitions.push(transition)
            }
            event_index = event_index + 1
        }
        let mut terminator_ops: List<RcOperation> = []
        for usage in block.terminator_uses {
            apply_demand_materialized(
                body, usage.slot, usage.demand, solved, none,
                states, terminator_ops, semantic_transitions)
        }
        let mut edges: List<RcEdge> = []
        let mut edge_proofs: List<CfgEdgeCertificate> = []
        let mut edge_index = 0
        while edge_index < block.edges.len() {
            let materialized = materialize_edge(
                body, block.edges.get(edge_index).unwrap(),
                edge_index, solved, states)
            edges.push(materialized.edge)
            edge_proofs.push(materialized.certificate)
            edge_index = edge_index + 1
        }
        rc_blocks.push(make_rc_block(
            block_index, block.events.len(), steps, terminator_ops, edges))
        block_certificates.push(make_cfg_block_certificate(
            block_index, entry_states,
            semantic_transitions, edge_proofs))
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
    let mut max_arity = 0
    for node in nodes {
        let tag = flow_type_kind_tag(flow_type_node_kind(node))
        let arity = if tag == 12 {
            flow_generic_param_arity(flow_type_node_generic_param(node))
        } else {
            0
        }
        arities.push(arity)
        if arity > max_arity { max_arity = arity }
    }
    let exact_rank_budget = nodes.len() * max_arity
    let mut promotions = 0
    let mut changed = true
    while changed {
        changed = false
        let mut node_index = 0
        while node_index < nodes.len() {
            let node = nodes.get(node_index).unwrap()
            let mut required = arities.get(node_index).unwrap()
            for child in flow_resource_children(node) {
                let child_arity = arities.get(
                    flow_type_ref_index(child)).unwrap()
                if child_arity > required { required = child_arity }
            }
            if required > arities.get(node_index).unwrap() {
                arities.set(node_index, required)
                promotions = promotions + 1
                if promotions > exact_rank_budget {
                    panic("ResourcePlanner: FlowIR generic arity graph did not converge")
                }
                changed = true
            }
            node_index = node_index + 1
        }
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
    let is_unique = seed_tag == 2 || drop_contract.is_some()
    let is_shareable = seed_tag == 3 || managed_foreign
    let parameter_index = if flow_type_kind_tag(
            flow_type_node_kind(node)) == 12 {
        some(flow_generic_param_index(flow_type_node_generic_param(node)))
    } else {
        none
    }
    make_planner_type_node(
        planner_type_kind_from_flow(node), children, arity, parameter_index,
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

fn argument_source_from_flow(
    argument: SlotRef, parameters: List<FlowSlot>
) -> PlannerArgumentSource {
    let mut index = 0
    while index < parameters.len() {
        if slot_ref_same(
                argument, flow_slot_reference(parameters.get(index).unwrap())) {
            return make_caller_parameter_source(index)
        }
        index = index + 1
    }
    make_local_argument_source()
}

fn flow_result_is_direct_return(body: FlowBody, result: SlotRef?) -> Bool {
    match result {
        none => return false,
        some(slot) => {
            for edge in flow_body_exit_edges(body) {
                if flow_exit_kind_tag(flow_exit_edge_kind(edge)) == 0 {
                    match flow_exit_edge_value(edge) {
                        some(returned) => if slot_ref_same(slot, returned) {
                            return true
                        },
                        none => {}
                    }
                }
            }
        }
    }
    false
}

fn planner_callable_from_flow(
    callable: FlowCallable, all_callables: List<FlowCallable>,
    bodies: List<FlowBody>
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
    let mut edges: List<PlannerCallEdge> = []
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
        for edge in flow_callable_call_edges(callable) {
            let mut sources: List<PlannerArgumentSource> = []
            for argument in flow_call_edge_arguments(edge) {
                sources.push(argument_source_from_flow(argument, parameters))
            }
            let forwards_result = flow_result_is_direct_return(
                body, flow_call_edge_result(edge))
            for candidate in flow_call_target_candidates(
                    flow_call_edge_target(edge)) {
                edges.push(make_planner_call_edge(
                    flow_callable_index(all_callables, candidate),
                    sources, forwards_result))
            }
        }
    }
    make_planner_callable(
        flow_callable_reference(callable), parameter_types,
        flow_type_ref_index(flow_callable_result_type(callable)),
        seeds,
        flow_role_is_owned(flow_call_contract_result_role(contract)),
        edges, has_body)
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

fn flow_call_candidate_indices(
    target: FlowCallTarget, callables: List<FlowCallable>
) -> List<Int> {
    let mut result: List<Int> = []
    for candidate in flow_call_target_candidates(target) {
        result.push(flow_callable_index(callables, candidate))
    }
    result
}

fn flow_call_result_type_index(
    target: FlowCallTarget, callables: List<FlowCallable>
) -> Int {
    let candidates = flow_call_target_candidates(target)
    let first = match candidates.get(0) {
        some(value) => flow_callable_result_type(
            callables.get(flow_callable_index(callables, value)).unwrap()),
        none => panic("ResourcePlanner: call target has empty candidate set")
    }
    for candidate in candidates {
        let result = flow_callable_result_type(
            callables.get(flow_callable_index(callables, candidate)).unwrap())
        if !flow_type_ref_same(first, result) {
            panic("ResourcePlanner: dynamic callable result type differs")
        }
    }
    flow_type_ref_index(first)
}

fn planner_event_from_flow(
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
            flow_slot_index(slots, flow_consume_source(instruction)), false)
    }
    if tag == 4 {
        return make_planner_discard(
            flow_slot_index(slots, flow_discard_source(instruction)))
    }
    if tag == 5 {
        return make_planner_assign(
            flow_slot_index(slots, flow_assign_rhs_temp(instruction)),
            flow_slot_index(slots, flow_assign_target(instruction)))
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
            flow_call_candidate_indices(target, callables),
            arguments, demands,
            flow_role_is_owned(flow_call_contract_result_role(contract)),
            flow_call_result_type_index(target, callables), result)
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
    panic("ResourcePlanner: unknown FlowIR instruction kind")
}

fn planner_terminator_uses_from_flow(
    terminator: FlowTerminator, slots: List<FlowSlot>
) -> List<PlannerTerminatorUse> {
    let mut result: List<PlannerTerminatorUse> = []
    let tag = flow_terminator_kind_tag(terminator)
    for slot in flow_terminator_read_slots(terminator) {
        result.push(make_planner_terminator_use(
            flow_slot_index(slots, slot),
            if tag == 3 {
                make_transfer_demand(param_mode_own(), false)
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
    body: FlowBody, callables: List<FlowCallable>
) -> PlannerBody {
    let flow_slots = flow_body_slots(body)
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
                instruction, flow_slots, callables))
        }
        let terminator = flow_block_terminator(block)
        blocks.push(make_planner_block(
            events, planner_terminator_uses_from_flow(terminator, flow_slots),
            planner_edges_from_flow(terminator)))
        expected_block = expected_block + 1
    }
    make_planner_body(
        flow_body_reference(body), planner_scopes, slots,
        flow_block_ref_ordinal(flow_body_entry(body)), blocks)
}

pub fn make_frozen_planner_input_from_flow(
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
            callable, flow_callables, flow_bodies))
    }
    let mut bodies: List<PlannerBody> = []
    for body in flow_bodies {
        bodies.push(planner_body_from_flow(body, flow_callables))
    }
    make_frozen_planner_input(
        flow_topology_fingerprint_canonical(
            flow_program_topology_fingerprint(program)),
        types, callables, bodies)
}

// ============================================================
// Public planning result and verifier boundary
// ============================================================

pub struct PlannedResources {
    logical_shapes: List<LogicalOwnershipShape>,
    physical_shapes: List<PhysicalRcShape>,
    callable_demands: List<List<TransferDemand>>,
    callable_results_owned: List<Bool>,
    rc_program: RcProgram,
    certificate: ResourceCertificate,
    verified: VerifiedResourceCertificate
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

pub fn planned_resources_logical_shapes(
    value: PlannedResources
) -> List<LogicalOwnershipShape> {
    copy_logical_shapes(value.logical_shapes)
}
pub fn planned_resources_physical_shapes(
    value: PlannedResources
) -> List<PhysicalRcShape> {
    copy_physical_shapes(value.physical_shapes)
}
pub fn planned_resources_callable_demands(
    value: PlannedResources
) -> List<List<TransferDemand>> {
    copy_callable_demands(value.callable_demands)
}
pub fn planned_resources_callable_results_owned(
    value: PlannedResources
) -> List<Bool> {
    let mut result: List<Bool> = []
    for owned in value.callable_results_owned { result.push(owned) }
    result
}
pub fn planned_resources_rc_program(value: PlannedResources) -> RcProgram {
    value.rc_program
}
pub fn planned_resources_certificate(
    value: PlannedResources
) -> ResourceCertificate { value.certificate }
pub fn planned_resources_verified_certificate(
    value: PlannedResources
) -> VerifiedResourceCertificate { value.verified }

pub fn plan_resources(input: FrozenPlannerInput) -> PlannedResources {
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
        input.flow_fingerprint, solved.fixed_point, cfg_certificates)
    let verified = verify_resource_certificate(rc_program, certificate)
    if rc_program_flow_fingerprint(rc_program) != input.flow_fingerprint {
        panic("ResourcePlanner: RcIR changed frozen FlowIR identity")
    }
    PlannedResources {
        logical_shapes: copy_logical_shapes(solved.logical_shapes),
        physical_shapes: copy_physical_shapes(solved.physical_shapes),
        callable_demands: copy_callable_demands(solved.callable_demands),
        callable_results_owned: solved.callable_results_owned,
        rc_program: rc_program,
        certificate: certificate,
        verified: verified
    }
}
