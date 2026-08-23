// Ranked proof objects for ResourcePlanner.
//
// The verifier checks finite monotone derivations and CFG/RC conservation.  It
// never calls the resolver, type/effect inference, trait selection, or the
// planner solver.  The frozen FlowIR fingerprint binds every proof to exactly
// one input graph.

use ir_identity::{SlotRef, slot_ref_same}
use ir_inventory::{executable_ref_same}
use resource_model::{
    SlotFlow,
    slot_flow_from_tag, slot_flow_tag, slot_flow_same,
    slot_flow_unreachable, slot_flow_empty, slot_flow_live,
    slot_flow_moved, slot_flow_maybe_moved,
    slot_flow_join}
use rc_ir::{
    RcProgram, RcBody, RcBlock, RcStep, RcEdge, RcSlot, RcOperation,
    RcOpKind,
    rc_program_flow_fingerprint, rc_program_type_count,
    rc_program_callable_count, rc_program_bodies,
    rc_body_reference, rc_body_slots, rc_body_entry_block, rc_body_blocks,
    rc_block_steps, rc_block_before_terminator, rc_block_edges,
    rc_step_before, rc_step_after,
    rc_edge_target_block, rc_edge_cleanup,
    rc_operation_kind, rc_operation_source, rc_operation_target,
    rc_op_kind_clone, rc_op_kind_take, rc_op_kind_drop,
    rc_op_kind_cleanup, rc_op_kind_same,
    rc_slot_reference}

// ============================================================
// Frozen finite lattice proof
// ============================================================

const RESOURCE_CELL_LOGICAL_SHAPE: Int = 0
const RESOURCE_CELL_PHYSICAL_SHAPE: Int = 1
const RESOURCE_CELL_CALLABLE_PARAM_MODE: Int = 2
const RESOURCE_CELL_CALLABLE_FORCE: Int = 3
const RESOURCE_CELL_CALLABLE_RESULT: Int = 4
const RESOURCE_CELL_KIND_COUNT: Int = 5

pub struct ResourceCellKind { tag: Int }

pub fn resource_cell_kind_from_tag(tag: Int) -> ResourceCellKind {
    if tag < RESOURCE_CELL_LOGICAL_SHAPE || tag >= RESOURCE_CELL_KIND_COUNT {
        panic("resource certificate: invalid cell kind")
    }
    ResourceCellKind { tag: tag }
}

pub fn resource_cell_kind_tag(kind: ResourceCellKind) -> Int {
    resource_cell_kind_from_tag(kind.tag).tag
}

pub fn resource_cell_kind_logical_shape() -> ResourceCellKind {
    resource_cell_kind_from_tag(RESOURCE_CELL_LOGICAL_SHAPE)
}
pub fn resource_cell_kind_physical_shape() -> ResourceCellKind {
    resource_cell_kind_from_tag(RESOURCE_CELL_PHYSICAL_SHAPE)
}
pub fn resource_cell_kind_callable_param_mode() -> ResourceCellKind {
    resource_cell_kind_from_tag(RESOURCE_CELL_CALLABLE_PARAM_MODE)
}
pub fn resource_cell_kind_callable_force() -> ResourceCellKind {
    resource_cell_kind_from_tag(RESOURCE_CELL_CALLABLE_FORCE)
}
pub fn resource_cell_kind_callable_result() -> ResourceCellKind {
    resource_cell_kind_from_tag(RESOURCE_CELL_CALLABLE_RESULT)
}

pub struct ResourceCellSpec {
    kind: ResourceCellKind,
    owner_index: Int,
    component_index: Int,
    max_rank: Int
}

pub fn make_resource_cell_spec(
    kind: ResourceCellKind, owner_index: Int,
    component_index: Int, max_rank: Int
) -> ResourceCellSpec {
    if owner_index < 0 || component_index < 0 || max_rank < 0 {
        panic("resource certificate: invalid cell metadata")
    }
    ResourceCellSpec {
        kind: kind,
        owner_index: owner_index,
        component_index: component_index,
        max_rank: max_rank
    }
}

pub fn resource_cell_spec_kind(value: ResourceCellSpec) -> ResourceCellKind {
    value.kind
}
pub fn resource_cell_spec_owner_index(value: ResourceCellSpec) -> Int {
    value.owner_index
}
pub fn resource_cell_spec_component_index(value: ResourceCellSpec) -> Int {
    value.component_index
}
pub fn resource_cell_spec_max_rank(value: ResourceCellSpec) -> Int {
    value.max_rank
}

fn resource_cell_spec_same(
    left: ResourceCellSpec, right: ResourceCellSpec
) -> Bool {
    resource_cell_kind_tag(left.kind) == resource_cell_kind_tag(right.kind) &&
        left.owner_index == right.owner_index &&
        left.component_index == right.component_index
}

fn copy_resource_cell_specs(
    values: List<ResourceCellSpec>
) -> List<ResourceCellSpec> {
    let mut result: List<ResourceCellSpec> = []
    for value in values {
        result.push(make_resource_cell_spec(
            value.kind, value.owner_index,
            value.component_index, value.max_rank))
    }
    result
}

// A constraint is target >= max(floor_rank, ranks[premises...]).  Splitting
// each finite product into monotone cells makes this small rule complete for
// type-shape bits, callable mode chains, FORCE, and owned-result bits.
pub struct ResourceConstraint {
    rule_tag: Int,
    target_cell: Int,
    floor_rank: Int,
    premise_cells: List<Int>
}

pub fn make_resource_constraint(
    rule_tag: Int, target_cell: Int,
    floor_rank: Int, premise_cells: List<Int>
) -> ResourceConstraint {
    if rule_tag < 0 || target_cell < 0 || floor_rank < 0 {
        panic("resource certificate: invalid constraint metadata")
    }
    let mut copied: List<Int> = []
    for premise in premise_cells {
        if premise < 0 {
            panic("resource certificate: negative premise cell")
        }
        copied.push(premise)
    }
    ResourceConstraint {
        rule_tag: rule_tag,
        target_cell: target_cell,
        floor_rank: floor_rank,
        premise_cells: copied
    }
}

pub fn resource_constraint_rule_tag(value: ResourceConstraint) -> Int {
    value.rule_tag
}
pub fn resource_constraint_target_cell(value: ResourceConstraint) -> Int {
    value.target_cell
}
pub fn resource_constraint_floor_rank(value: ResourceConstraint) -> Int {
    value.floor_rank
}
pub fn resource_constraint_premise_cells(
    value: ResourceConstraint
) -> List<Int> {
    let mut result: List<Int> = []
    for premise in value.premise_cells { result.push(premise) }
    result
}

fn copy_resource_constraints(
    values: List<ResourceConstraint>
) -> List<ResourceConstraint> {
    let mut result: List<ResourceConstraint> = []
    for value in values {
        result.push(make_resource_constraint(
            value.rule_tag, value.target_cell,
            value.floor_rank, value.premise_cells))
    }
    result
}

pub struct ResourcePromotion {
    constraint_index: Int,
    target_cell: Int,
    from_rank: Int,
    to_rank: Int,
    premise_ranks: List<Int>
}

pub fn make_resource_promotion(
    constraint_index: Int, target_cell: Int,
    from_rank: Int, to_rank: Int, premise_ranks: List<Int>
) -> ResourcePromotion {
    if constraint_index < 0 || target_cell < 0 || from_rank < 0 ||
       to_rank <= from_rank {
        panic("resource certificate: promotion is not strictly ranked")
    }
    let mut copied: List<Int> = []
    for rank in premise_ranks {
        if rank < 0 {
            panic("resource certificate: negative premise rank")
        }
        copied.push(rank)
    }
    ResourcePromotion {
        constraint_index: constraint_index,
        target_cell: target_cell,
        from_rank: from_rank,
        to_rank: to_rank,
        premise_ranks: copied
    }
}

pub fn resource_promotion_constraint_index(
    value: ResourcePromotion
) -> Int { value.constraint_index }
pub fn resource_promotion_target_cell(value: ResourcePromotion) -> Int {
    value.target_cell
}
pub fn resource_promotion_from_rank(value: ResourcePromotion) -> Int {
    value.from_rank
}
pub fn resource_promotion_to_rank(value: ResourcePromotion) -> Int {
    value.to_rank
}
pub fn resource_promotion_premise_ranks(
    value: ResourcePromotion
) -> List<Int> {
    let mut result: List<Int> = []
    for rank in value.premise_ranks { result.push(rank) }
    result
}

fn copy_resource_promotions(
    values: List<ResourcePromotion>
) -> List<ResourcePromotion> {
    let mut result: List<ResourcePromotion> = []
    for value in values {
        result.push(make_resource_promotion(
            value.constraint_index, value.target_cell,
            value.from_rank, value.to_rank, value.premise_ranks))
    }
    result
}

pub struct ResourceFixedPointProof {
    cells: List<ResourceCellSpec>,
    constraints: List<ResourceConstraint>,
    promotions: List<ResourcePromotion>,
    final_ranks: List<Int>
}

pub fn make_resource_fixed_point_proof(
    cells: List<ResourceCellSpec>,
    constraints: List<ResourceConstraint>,
    promotions: List<ResourcePromotion>,
    final_ranks: List<Int>
) -> ResourceFixedPointProof {
    ResourceFixedPointProof {
        cells: copy_resource_cell_specs(cells),
        constraints: copy_resource_constraints(constraints),
        promotions: copy_resource_promotions(promotions),
        final_ranks: final_ranks
    }
}

pub fn resource_fixed_point_cells(
    value: ResourceFixedPointProof
) -> List<ResourceCellSpec> { copy_resource_cell_specs(value.cells) }
pub fn resource_fixed_point_constraints(
    value: ResourceFixedPointProof
) -> List<ResourceConstraint> {
    copy_resource_constraints(value.constraints)
}
pub fn resource_fixed_point_promotions(
    value: ResourceFixedPointProof
) -> List<ResourcePromotion> { copy_resource_promotions(value.promotions) }
pub fn resource_fixed_point_final_ranks(
    value: ResourceFixedPointProof
) -> List<Int> {
    let mut result: List<Int> = []
    for rank in value.final_ranks { result.push(rank) }
    result
}

fn constraint_required_rank(
    constraint: ResourceConstraint, ranks: List<Int>
) -> Int {
    let mut required = constraint.floor_rank
    for premise in constraint.premise_cells {
        let rank = match ranks.get(premise) {
            some(value) => value,
            none => panic("resource certificate: premise cell is outside graph")
        }
        if rank > required { required = rank }
    }
    required
}

fn verify_fixed_point_proof(value: ResourceFixedPointProof) {
    if value.final_ranks.len() != value.cells.len() {
        panic("resource certificate: final cell census differs")
    }
    let mut left_index = 0
    while left_index < value.cells.len() {
        let left = value.cells.get(left_index).unwrap()
        let mut right_index = left_index + 1
        while right_index < value.cells.len() {
            let right = value.cells.get(right_index).unwrap()
            if resource_cell_spec_same(left, right) {
                panic("resource certificate: duplicate finite-lattice cell")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }

    for constraint in value.constraints {
        let target = match value.cells.get(constraint.target_cell) {
            some(cell) => cell,
            none => panic("resource certificate: constraint target is outside graph")
        }
        if constraint.floor_rank > target.max_rank {
            panic("resource certificate: constraint floor exceeds lattice")
        }
        for premise in constraint.premise_cells {
            if premise < 0 || premise >= value.cells.len() {
                panic("resource certificate: constraint premise is outside graph")
            }
        }
    }

    let mut current: List<Int> = []
    let mut total_rank_capacity = 0
    for cell in value.cells {
        current.push(0)
        total_rank_capacity = total_rank_capacity + cell.max_rank
    }
    if value.promotions.len() > total_rank_capacity {
        panic("resource certificate: derivation exceeds exact finite rank budget")
    }

    for promotion in value.promotions {
        let constraint = match value.constraints.get(
                promotion.constraint_index) {
            some(item) => item,
            none => panic("resource certificate: promotion rule is absent")
        }
        if promotion.target_cell != constraint.target_cell {
            panic("resource certificate: promotion targets the wrong cell")
        }
        let cell = value.cells.get(promotion.target_cell).unwrap()
        let actual_from = current.get(promotion.target_cell).unwrap()
        if promotion.from_rank != actual_from {
            panic("resource certificate: promotion source rank drifted")
        }
        if promotion.premise_ranks.len() !=
           constraint.premise_cells.len() {
            panic("resource certificate: promotion premise census differs")
        }
        let mut premise_index = 0
        while premise_index < constraint.premise_cells.len() {
            let premise_cell = constraint.premise_cells.get(
                premise_index).unwrap()
            let actual_rank = current.get(premise_cell).unwrap()
            let claimed_rank = promotion.premise_ranks.get(
                premise_index).unwrap()
            if actual_rank != claimed_rank {
                panic("resource certificate: promotion premise rank drifted")
            }
            premise_index = premise_index + 1
        }
        let required = constraint_required_rank(constraint, current)
        if promotion.to_rank != required ||
           promotion.to_rank <= promotion.from_rank ||
           promotion.to_rank > cell.max_rank {
            panic("resource certificate: promotion is not the exact monotone rule step")
        }
        current.set(promotion.target_cell, promotion.to_rank)
    }

    let mut cell_index = 0
    while cell_index < value.cells.len() {
        let expected = value.final_ranks.get(cell_index).unwrap()
        let actual = current.get(cell_index).unwrap()
        let cell = value.cells.get(cell_index).unwrap()
        if expected != actual || expected < 0 || expected > cell.max_rank {
            panic("resource certificate: final rank does not match derivation")
        }
        cell_index = cell_index + 1
    }
    // Post-fixed point proves completeness.  The derivation above starts at
    // bottom and every strict promotion is justified by current lower ranks,
    // so the same sequence proves the result is the least fixed point.
    for constraint in value.constraints {
        let actual = current.get(constraint.target_cell).unwrap()
        let required = constraint_required_rank(constraint, current)
        if actual < required {
            panic("resource certificate: claimed solution is not a fixed point")
        }
    }
}

fn verify_fixed_point_domains(
    rc_program: RcProgram, value: ResourceFixedPointProof
) {
    for cell in value.cells {
        let kind = resource_cell_kind_tag(cell.kind)
        if kind == RESOURCE_CELL_LOGICAL_SHAPE ||
           kind == RESOURCE_CELL_PHYSICAL_SHAPE {
            if cell.owner_index < 0 ||
               cell.owner_index >= rc_program_type_count(rc_program) ||
               cell.max_rank != 1 {
                panic("resource certificate: type-shape cell domain drifted")
            }
        } else if kind == RESOURCE_CELL_CALLABLE_PARAM_MODE {
            if cell.owner_index < 0 ||
               cell.owner_index >= rc_program_callable_count(rc_program) ||
               cell.max_rank != 3 {
                panic("resource certificate: callable mode cell domain drifted")
            }
        } else if kind == RESOURCE_CELL_CALLABLE_FORCE ||
                  kind == RESOURCE_CELL_CALLABLE_RESULT {
            if cell.owner_index < 0 ||
               cell.owner_index >= rc_program_callable_count(rc_program) ||
               cell.max_rank != 1 {
                panic("resource certificate: callable bit cell domain drifted")
            }
        } else {
            panic("resource certificate: unknown proof cell domain")
        }
    }
}

// ============================================================
// Per-body CFG proof
// ============================================================

const SLOT_REASON_INIT_EMPTY: Int = 0
const SLOT_REASON_INIT_LIVE: Int = 1
const SLOT_REASON_BORROW: Int = 2
const SLOT_REASON_MUTATE: Int = 3
const SLOT_REASON_CLONE_SOURCE: Int = 4
const SLOT_REASON_CLONE_TARGET: Int = 5
const SLOT_REASON_TAKE_SOURCE: Int = 6
const SLOT_REASON_TAKE_TARGET: Int = 7
const SLOT_REASON_DROP: Int = 8
const SLOT_REASON_CLEANUP: Int = 9
const SLOT_REASON_ASSIGN_SCALAR: Int = 10
const SLOT_REASON_CALL_RESULT: Int = 11
const SLOT_REASON_JOIN: Int = 12
const SLOT_REASON_SCOPE_END: Int = 13
const SLOT_REASON_COUNT: Int = 14

pub struct SlotTransitionReason { tag: Int }

pub fn slot_transition_reason_from_tag(tag: Int) -> SlotTransitionReason {
    if tag < SLOT_REASON_INIT_EMPTY || tag >= SLOT_REASON_COUNT {
        panic("resource certificate: invalid slot transition reason")
    }
    SlotTransitionReason { tag: tag }
}

pub fn slot_transition_reason_tag(value: SlotTransitionReason) -> Int {
    slot_transition_reason_from_tag(value.tag).tag
}

pub fn slot_reason_init_empty() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_INIT_EMPTY) }
pub fn slot_reason_init_live() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_INIT_LIVE) }
pub fn slot_reason_borrow() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_BORROW) }
pub fn slot_reason_mutate() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_MUTATE) }
pub fn slot_reason_clone_source() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_CLONE_SOURCE) }
pub fn slot_reason_clone_target() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_CLONE_TARGET) }
pub fn slot_reason_take_source() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_TAKE_SOURCE) }
pub fn slot_reason_take_target() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_TAKE_TARGET) }
pub fn slot_reason_drop() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_DROP) }
pub fn slot_reason_cleanup() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_CLEANUP) }
pub fn slot_reason_assign_scalar() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_ASSIGN_SCALAR) }
pub fn slot_reason_call_result() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_CALL_RESULT) }
pub fn slot_reason_join() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_JOIN) }
pub fn slot_reason_scope_end() -> SlotTransitionReason { slot_transition_reason_from_tag(SLOT_REASON_SCOPE_END) }

pub struct SlotTransitionWitness {
    slot_index: Int,
    before: SlotFlow,
    after: SlotFlow,
    reason: SlotTransitionReason
}

pub fn make_slot_transition_witness(
    slot_index: Int, before: SlotFlow,
    after: SlotFlow, reason: SlotTransitionReason
) -> SlotTransitionWitness {
    if slot_index < 0 {
        panic("resource certificate: negative slot transition index")
    }
    SlotTransitionWitness {
        slot_index: slot_index,
        before: slot_flow_from_tag(slot_flow_tag(before)),
        after: slot_flow_from_tag(slot_flow_tag(after)),
        reason: reason
    }
}

pub fn slot_transition_witness_slot_index(
    value: SlotTransitionWitness
) -> Int { value.slot_index }
pub fn slot_transition_witness_before(
    value: SlotTransitionWitness
) -> SlotFlow { value.before }
pub fn slot_transition_witness_after(
    value: SlotTransitionWitness
) -> SlotFlow { value.after }
pub fn slot_transition_witness_reason(
    value: SlotTransitionWitness
) -> SlotTransitionReason { value.reason }

fn copy_slot_transitions(
    values: List<SlotTransitionWitness>
) -> List<SlotTransitionWitness> {
    let mut result: List<SlotTransitionWitness> = []
    for value in values {
        result.push(make_slot_transition_witness(
            value.slot_index, value.before, value.after, value.reason))
    }
    result
}

fn transition_reason_is(
    reason: SlotTransitionReason, expected: Int
) -> Bool { slot_transition_reason_tag(reason) == expected }

fn verify_slot_transition(value: SlotTransitionWitness) {
    let before = value.before
    let after = value.after
    let reason = value.reason
    if transition_reason_is(reason, SLOT_REASON_INIT_EMPTY) {
        if slot_flow_same(before, slot_flow_live()) ||
           !slot_flow_same(after, slot_flow_empty()) {
            panic("resource certificate: invalid empty initialization")
        }
    } else if transition_reason_is(reason, SLOT_REASON_INIT_LIVE) {
        if slot_flow_same(before, slot_flow_unreachable()) ||
           slot_flow_same(before, slot_flow_live()) ||
           !slot_flow_same(after, slot_flow_live()) {
            panic("resource certificate: invalid live initialization")
        }
    } else if transition_reason_is(reason, SLOT_REASON_BORROW) ||
              transition_reason_is(reason, SLOT_REASON_MUTATE) ||
              transition_reason_is(reason, SLOT_REASON_CLONE_SOURCE) {
        if !slot_flow_same(before, slot_flow_live()) ||
           !slot_flow_same(after, slot_flow_live()) {
            panic("resource certificate: read requires one live owner")
        }
    } else if transition_reason_is(reason, SLOT_REASON_TAKE_SOURCE) {
        if !slot_flow_same(before, slot_flow_live()) ||
           !slot_flow_same(after, slot_flow_moved()) {
            panic("resource certificate: Take does not clear one live source")
        }
    } else if transition_reason_is(reason, SLOT_REASON_CLONE_TARGET) ||
              transition_reason_is(reason, SLOT_REASON_TAKE_TARGET) ||
              transition_reason_is(reason, SLOT_REASON_CALL_RESULT) {
        if slot_flow_same(before, slot_flow_live()) ||
           slot_flow_same(before, slot_flow_unreachable()) ||
           !slot_flow_same(after, slot_flow_live()) {
            panic("resource certificate: resource target was not empty")
        }
    } else if transition_reason_is(reason, SLOT_REASON_DROP) {
        if slot_flow_same(before, slot_flow_unreachable()) ||
           !slot_flow_same(after, slot_flow_empty()) {
            panic("resource certificate: Drop does not normalize old storage")
        }
    } else if transition_reason_is(reason, SLOT_REASON_CLEANUP) {
        if slot_flow_same(before, slot_flow_unreachable()) ||
           !slot_flow_same(after, slot_flow_empty()) {
            panic("resource certificate: Cleanup does not normalize storage to empty")
        }
    } else if transition_reason_is(reason, SLOT_REASON_ASSIGN_SCALAR) {
        if slot_flow_same(before, slot_flow_unreachable()) ||
           !slot_flow_same(after, slot_flow_live()) {
            panic("resource certificate: scalar assignment has invalid state")
        }
    } else if transition_reason_is(reason, SLOT_REASON_JOIN) {
        // The enclosing edge proof checks the actual join operands.
        if slot_flow_same(after, slot_flow_unreachable()) &&
           !slot_flow_same(before, slot_flow_unreachable()) {
            panic("resource certificate: reachable state joined to unreachable")
        }
    } else if transition_reason_is(reason, SLOT_REASON_SCOPE_END) {
        if slot_flow_same(before, slot_flow_unreachable()) ||
           !slot_flow_same(after, slot_flow_empty()) {
            panic("resource certificate: lexical scope exit does not clear slot state")
        }
    }
}

pub struct CfgEdgeCertificate {
    target_block: Int?,
    exit_states: List<SlotFlow>,
    transitions: List<SlotTransitionWitness>
}

pub fn make_cfg_edge_certificate(
    target_block: Int?, exit_states: List<SlotFlow>,
    transitions: List<SlotTransitionWitness>
) -> CfgEdgeCertificate {
    let mut states: List<SlotFlow> = []
    for state in exit_states {
        states.push(slot_flow_from_tag(slot_flow_tag(state)))
    }
    CfgEdgeCertificate {
        target_block: target_block,
        exit_states: states,
        transitions: copy_slot_transitions(transitions)
    }
}

pub fn cfg_edge_certificate_target(value: CfgEdgeCertificate) -> Int? {
    value.target_block
}
pub fn cfg_edge_certificate_exit_states(
    value: CfgEdgeCertificate
) -> List<SlotFlow> {
    let mut result: List<SlotFlow> = []
    for state in value.exit_states { result.push(state) }
    result
}
pub fn cfg_edge_certificate_transitions(
    value: CfgEdgeCertificate
) -> List<SlotTransitionWitness> {
    copy_slot_transitions(value.transitions)
}

fn copy_cfg_edge_certificates(
    values: List<CfgEdgeCertificate>
) -> List<CfgEdgeCertificate> {
    let mut result: List<CfgEdgeCertificate> = []
    for value in values {
        result.push(make_cfg_edge_certificate(
            value.target_block, value.exit_states, value.transitions))
    }
    result
}

pub struct CfgBlockCertificate {
    block_index: Int,
    entry_states: List<SlotFlow>,
    semantic_transitions: List<SlotTransitionWitness>,
    edges: List<CfgEdgeCertificate>
}

pub fn make_cfg_block_certificate(
    block_index: Int, entry_states: List<SlotFlow>,
    semantic_transitions: List<SlotTransitionWitness>,
    edges: List<CfgEdgeCertificate>
) -> CfgBlockCertificate {
    if block_index < 0 {
        panic("resource certificate: negative CFG block index")
    }
    let mut states: List<SlotFlow> = []
    for state in entry_states {
        states.push(slot_flow_from_tag(slot_flow_tag(state)))
    }
    CfgBlockCertificate {
        block_index: block_index,
        entry_states: states,
        semantic_transitions: copy_slot_transitions(semantic_transitions),
        edges: copy_cfg_edge_certificates(edges)
    }
}

pub fn cfg_block_certificate_index(value: CfgBlockCertificate) -> Int {
    value.block_index
}
pub fn cfg_block_certificate_entry_states(
    value: CfgBlockCertificate
) -> List<SlotFlow> {
    let mut result: List<SlotFlow> = []
    for state in value.entry_states { result.push(state) }
    result
}
pub fn cfg_block_certificate_semantic_transitions(
    value: CfgBlockCertificate
) -> List<SlotTransitionWitness> {
    copy_slot_transitions(value.semantic_transitions)
}
pub fn cfg_block_certificate_edges(
    value: CfgBlockCertificate
) -> List<CfgEdgeCertificate> {
    copy_cfg_edge_certificates(value.edges)
}

fn copy_cfg_block_certificates(
    values: List<CfgBlockCertificate>
) -> List<CfgBlockCertificate> {
    let mut result: List<CfgBlockCertificate> = []
    for value in values {
        result.push(make_cfg_block_certificate(
            value.block_index, value.entry_states,
            value.semantic_transitions, value.edges))
    }
    result
}

pub struct CfgBodyCertificate {
    entry_block: Int,
    entry_seed: List<SlotFlow>,
    blocks: List<CfgBlockCertificate>
}

pub fn make_cfg_body_certificate(
    entry_block: Int, entry_seed: List<SlotFlow>,
    blocks: List<CfgBlockCertificate>
) -> CfgBodyCertificate {
    if entry_block < 0 || entry_block >= blocks.len() {
        panic("resource certificate: invalid CFG entry block")
    }
    let mut seed: List<SlotFlow> = []
    for state in entry_seed {
        seed.push(slot_flow_from_tag(slot_flow_tag(state)))
    }
    CfgBodyCertificate {
        entry_block: entry_block,
        entry_seed: seed,
        blocks: copy_cfg_block_certificates(blocks)
    }
}

pub fn cfg_body_certificate_entry_block(
    value: CfgBodyCertificate
) -> Int { value.entry_block }
pub fn cfg_body_certificate_entry_seed(
    value: CfgBodyCertificate
) -> List<SlotFlow> {
    let mut result: List<SlotFlow> = []
    for state in value.entry_seed { result.push(state) }
    result
}

pub fn cfg_body_certificate_blocks(
    value: CfgBodyCertificate
) -> List<CfgBlockCertificate> {
    copy_cfg_block_certificates(value.blocks)
}

fn copy_cfg_body_certificates(
    values: List<CfgBodyCertificate>
) -> List<CfgBodyCertificate> {
    let mut result: List<CfgBodyCertificate> = []
    for value in values {
        result.push(make_cfg_body_certificate(
            value.entry_block, value.entry_seed, value.blocks))
    }
    result
}

fn copy_state_vector(values: List<SlotFlow>) -> List<SlotFlow> {
    let mut result: List<SlotFlow> = []
    for value in values {
        result.push(slot_flow_from_tag(slot_flow_tag(value)))
    }
    result
}

fn join_state_vectors(
    left: List<SlotFlow>, right: List<SlotFlow>
) -> List<SlotFlow> {
    if left.len() != right.len() {
        panic("resource certificate: CFG join arity differs")
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

pub struct ResourceCertificate {
    flow_fingerprint: Str,
    fixed_point: ResourceFixedPointProof,
    cfg_bodies: List<CfgBodyCertificate>
}

pub fn make_resource_certificate(
    flow_fingerprint: Str,
    fixed_point: ResourceFixedPointProof,
    cfg_bodies: List<CfgBodyCertificate>
) -> ResourceCertificate {
    if flow_fingerprint.len() == 0 {
        panic("resource certificate: missing FlowIR fingerprint")
    }
    ResourceCertificate {
        flow_fingerprint: flow_fingerprint,
        fixed_point: fixed_point,
        cfg_bodies: copy_cfg_body_certificates(cfg_bodies)
    }
}

pub fn resource_certificate_flow_fingerprint(
    value: ResourceCertificate
) -> Str { value.flow_fingerprint }
pub fn resource_certificate_fixed_point(
    value: ResourceCertificate
) -> ResourceFixedPointProof { value.fixed_point }
pub fn resource_certificate_cfg_bodies(
    value: ResourceCertificate
) -> List<CfgBodyCertificate> {
    copy_cfg_body_certificates(value.cfg_bodies)
}

// Opaque proof token.  Downstream consumers receive it only after all local
// certificate checks have succeeded for the exact RcProgram fingerprint.
pub struct VerifiedResourceCertificate {
    flow_fingerprint: Str
}

pub fn verified_resource_certificate_flow_fingerprint(
    value: VerifiedResourceCertificate
) -> Str { value.flow_fingerprint }

fn verify_transition_sequence(
    initial: List<SlotFlow>, transitions: List<SlotTransitionWitness>
) -> List<SlotFlow> {
    let mut current: List<SlotFlow> = []
    for state in initial { current.push(state) }
    for transition in transitions {
        if transition.slot_index < 0 || transition.slot_index >= current.len() {
            panic("resource certificate: transition slot is outside body")
        }
        let actual = current.get(transition.slot_index).unwrap()
        if !slot_flow_same(actual, transition.before) {
            panic("resource certificate: transition source state drifted")
        }
        verify_slot_transition(transition)
        current.set(transition.slot_index, transition.after)
    }
    current
}

fn rc_slot_index_for(slots: List<RcSlot>, target: SlotRef) -> Int {
    let mut index = 0
    while index < slots.len() {
        if slot_ref_same(
                rc_slot_reference(slots.get(index).unwrap()), target) {
            return index
        }
        index = index + 1
    }
    panic("resource certificate: Rc operation slot is not registered")
}

fn reason_is_resource_source(reason: SlotTransitionReason) -> Bool {
    let tag = slot_transition_reason_tag(reason)
    tag == SLOT_REASON_CLONE_SOURCE || tag == SLOT_REASON_TAKE_SOURCE ||
        tag == SLOT_REASON_DROP
}

fn resource_source_transitions(
    transitions: List<SlotTransitionWitness>
) -> List<SlotTransitionWitness> {
    let mut result: List<SlotTransitionWitness> = []
    for transition in transitions {
        if reason_is_resource_source(transition.reason) {
            result.push(transition)
        }
    }
    result
}

fn block_resource_operations(block: RcBlock) -> List<RcOperation> {
    let mut result: List<RcOperation> = []
    for step in rc_block_steps(block) {
        for operation in rc_step_before(step) { result.push(operation) }
        for operation in rc_step_after(step) { result.push(operation) }
    }
    for operation in rc_block_before_terminator(block) {
        result.push(operation)
    }
    result
}

fn operation_matches_source_reason(
    operation: RcOperation, reason: SlotTransitionReason
) -> Bool {
    if rc_op_kind_same(rc_operation_kind(operation), rc_op_kind_clone()) {
        return transition_reason_is(reason, SLOT_REASON_CLONE_SOURCE)
    }
    if rc_op_kind_same(rc_operation_kind(operation), rc_op_kind_take()) {
        return transition_reason_is(reason, SLOT_REASON_TAKE_SOURCE)
    }
    if rc_op_kind_same(rc_operation_kind(operation), rc_op_kind_drop()) {
        return transition_reason_is(reason, SLOT_REASON_DROP)
    }
    false
}

fn verify_block_resource_witnesses(
    block: RcBlock, slots: List<RcSlot>,
    transitions: List<SlotTransitionWitness>
) {
    let operations = block_resource_operations(block)
    let witnesses = resource_source_transitions(transitions)
    if operations.len() != witnesses.len() {
        panic("resource certificate: block RC operation/witness census differs")
    }
    let mut index = 0
    while index < operations.len() {
        let operation = operations.get(index).unwrap()
        let witness = witnesses.get(index).unwrap()
        if rc_op_kind_same(
                rc_operation_kind(operation), rc_op_kind_cleanup()) {
            panic("resource certificate: Cleanup appears inside semantic block")
        }
        if !operation_matches_source_reason(operation, witness.reason) ||
           rc_slot_index_for(slots, rc_operation_source(operation)) !=
               witness.slot_index {
            panic("resource certificate: block RC operation witness drifted")
        }
        match rc_operation_target(operation) {
            some(target) => { let _ = rc_slot_index_for(slots, target) },
            none => {}
        }
        index = index + 1
    }
}

fn verify_edge_resource_witnesses(
    edge: RcEdge, slots: List<RcSlot>,
    transitions: List<SlotTransitionWitness>
) {
    let operations = rc_edge_cleanup(edge)
    let mut cleanup_witnesses: List<SlotTransitionWitness> = []
    for transition in transitions {
        if transition_reason_is(
                transition.reason, SLOT_REASON_CLEANUP) {
            cleanup_witnesses.push(transition)
        }
    }
    if operations.len() != cleanup_witnesses.len() {
        panic("resource certificate: edge Cleanup/witness census differs")
    }
    let mut index = 0
    while index < operations.len() {
        let operation = operations.get(index).unwrap()
        let witness = cleanup_witnesses.get(index).unwrap()
        if !rc_op_kind_same(
                rc_operation_kind(operation), rc_op_kind_cleanup()) ||
           !transition_reason_is(witness.reason, SLOT_REASON_CLEANUP) ||
           rc_slot_index_for(slots, rc_operation_source(operation)) !=
               witness.slot_index {
            panic("resource certificate: edge Cleanup witness drifted")
        }
        index = index + 1
    }
}

fn verify_cfg_body_certificate(
    rc_body: RcBody, certificate: CfgBodyCertificate
) {
    let blocks = rc_body_blocks(rc_body)
    let slots = rc_body_slots(rc_body)
    if certificate.blocks.len() != blocks.len() ||
       certificate.entry_block != rc_body_entry_block(rc_body) ||
       certificate.entry_seed.len() != slots.len() {
        panic("resource certificate: CFG block census differs")
    }
    let mut block_index = 0
    while block_index < blocks.len() {
        let rc_block = blocks.get(block_index).unwrap()
        let proof = certificate.blocks.get(block_index).unwrap()
        if proof.block_index != block_index ||
           proof.entry_states.len() != slots.len() {
            panic("resource certificate: CFG block identity/state census differs")
        }
        verify_block_resource_witnesses(
            rc_block, slots, proof.semantic_transitions)
        let after_semantic = verify_transition_sequence(
            proof.entry_states, proof.semantic_transitions)
        let rc_edges = rc_block_edges(rc_block)
        if proof.edges.len() != rc_edges.len() {
            panic("resource certificate: CFG edge census differs")
        }
        let mut edge_index = 0
        while edge_index < rc_edges.len() {
            let rc_edge = rc_edges.get(edge_index).unwrap()
            let edge_proof = proof.edges.get(edge_index).unwrap()
            if rc_edge_target_block(rc_edge) != edge_proof.target_block {
                panic("resource certificate: CFG edge endpoint drifted")
            }
            verify_edge_resource_witnesses(
                rc_edge, slots, edge_proof.transitions)
            if edge_proof.exit_states.len() != slots.len() {
                panic("resource certificate: CFG edge state census differs")
            }
            let derived = verify_transition_sequence(
                after_semantic, edge_proof.transitions)
            let mut slot_index = 0
            while slot_index < slots.len() {
                if !slot_flow_same(
                        derived.get(slot_index).unwrap(),
                        edge_proof.exit_states.get(slot_index).unwrap()) {
                    panic("resource certificate: CFG edge exit state drifted")
                }
                slot_index = slot_index + 1
            }
            edge_index = edge_index + 1
        }
        block_index = block_index + 1
    }

    // Every reachable predecessor contributes exactly to the target entry
    // state.  Equality with the join prevents both under- and over-claiming.
    let mut target_index = 0
    while target_index < certificate.blocks.len() {
        let target = certificate.blocks.get(target_index).unwrap()
        let mut joined: List<SlotFlow> = []
        let mut has_predecessor = false
        let mut source_index = 0
        while source_index < certificate.blocks.len() {
            let source = certificate.blocks.get(source_index).unwrap()
            for edge in source.edges {
                match edge.target_block {
                    some(candidate) => if candidate == target_index {
                        if !has_predecessor {
                            for state in edge.exit_states { joined.push(state) }
                            has_predecessor = true
                        } else {
                            let mut slot_index = 0
                            while slot_index < joined.len() {
                                joined.set(slot_index, slot_flow_join(
                                    joined.get(slot_index).unwrap(),
                                    edge.exit_states.get(slot_index).unwrap()))
                                slot_index = slot_index + 1
                            }
                        }
                    },
                    none => {}
                }
            }
            source_index = source_index + 1
        }
        let expected = if target_index == certificate.entry_block {
            if has_predecessor {
                join_state_vectors(joined, certificate.entry_seed)
            } else {
                copy_state_vector(certificate.entry_seed)
            }
        } else if has_predecessor {
            joined
        } else {
            let mut bottom: List<SlotFlow> = []
            for _ in slots { bottom.push(slot_flow_unreachable()) }
            bottom
        }
        let mut slot_index = 0
        while slot_index < expected.len() {
            let actual = target.entry_states.get(slot_index).unwrap()
            if !slot_flow_same(actual, expected.get(slot_index).unwrap()) {
                panic("resource certificate: CFG join is not exact")
            }
            slot_index = slot_index + 1
        }
        target_index = target_index + 1
    }
}

pub fn verify_resource_certificate(
    rc_program: RcProgram, certificate: ResourceCertificate
) -> VerifiedResourceCertificate {
    if rc_program_flow_fingerprint(rc_program) != certificate.flow_fingerprint {
        panic("resource certificate: FlowIR fingerprint mismatch")
    }
    verify_fixed_point_domains(rc_program, certificate.fixed_point)
    verify_fixed_point_proof(certificate.fixed_point)
    let bodies = rc_program_bodies(rc_program)
    if bodies.len() != certificate.cfg_bodies.len() {
        panic("resource certificate: executable body census differs")
    }
    let mut body_index = 0
    while body_index < bodies.len() {
        verify_cfg_body_certificate(
            bodies.get(body_index).unwrap(),
            certificate.cfg_bodies.get(body_index).unwrap())
        body_index = body_index + 1
    }
    VerifiedResourceCertificate {
        flow_fingerprint: certificate.flow_fingerprint
    }
}
