// RcIR: a binder- and topology-preserving resource-explicit projection.
//
// FlowIR remains the semantic CFG authority.  This module stores only an
// exact snapshot of that frozen topology plus explicit resource operations.
// It has no resolver, type/effect solver, layout, ABI, or code-generation
// fallback.  ResourcePlanner is the sole producer.

use ir_identity::{SlotRef, slot_ref_same}
use ir_inventory::{ExecutableRef, executable_ref_same}

// ============================================================
// Explicit resource operations
// ============================================================

const RC_OP_CLONE: Int = 0
const RC_OP_TAKE: Int = 1
const RC_OP_DROP: Int = 2
const RC_OP_CLEANUP: Int = 3
const RC_OP_KIND_COUNT: Int = 4

pub struct RcOpKind { tag: Int }

pub fn rc_op_kind_from_tag(tag: Int) -> RcOpKind {
    if tag < RC_OP_CLONE || tag >= RC_OP_KIND_COUNT {
        panic("RcIR: invalid resource operation kind")
    }
    RcOpKind { tag: tag }
}

pub fn rc_op_kind_tag(kind: RcOpKind) -> Int {
    rc_op_kind_from_tag(kind.tag).tag
}

pub fn rc_op_kind_clone() -> RcOpKind {
    rc_op_kind_from_tag(RC_OP_CLONE)
}

pub fn rc_op_kind_take() -> RcOpKind {
    rc_op_kind_from_tag(RC_OP_TAKE)
}

pub fn rc_op_kind_drop() -> RcOpKind {
    rc_op_kind_from_tag(RC_OP_DROP)
}

pub fn rc_op_kind_cleanup() -> RcOpKind {
    rc_op_kind_from_tag(RC_OP_CLEANUP)
}

pub fn rc_op_kind_same(left: RcOpKind, right: RcOpKind) -> Bool {
    rc_op_kind_tag(left) == rc_op_kind_tag(right)
}

// target_slot is present only when the already-existing FlowIR destination is
// a storage slot.  A missing target means the value moves/clones directly into
// a semantic sink (call argument, return, constructor field, etc.).  Neither
// form creates a binder.
pub struct RcOperation {
    kind: RcOpKind,
    source_slot: SlotRef,
    target_slot: SlotRef?
}

fn validate_rc_operation(
    kind: RcOpKind, source_slot: SlotRef, target_slot: SlotRef?
) {
    if rc_op_kind_same(kind, rc_op_kind_drop()) ||
       rc_op_kind_same(kind, rc_op_kind_cleanup()) {
        if target_slot.is_some() {
            panic("RcIR: Drop/Cleanup cannot have a target slot")
        }
        return
    }
    match target_slot {
        some(target) => if slot_ref_same(source_slot, target) {
            panic("RcIR: Clone/Take source and target are identical")
        },
        none => {}
    }
}

pub fn make_rc_clone(source: SlotRef, target: SlotRef?) -> RcOperation {
    validate_rc_operation(rc_op_kind_clone(), source, target)
    RcOperation {
        kind: rc_op_kind_clone(),
        source_slot: source,
        target_slot: target
    }
}

pub fn make_rc_take(source: SlotRef, target: SlotRef?) -> RcOperation {
    validate_rc_operation(rc_op_kind_take(), source, target)
    RcOperation {
        kind: rc_op_kind_take(),
        source_slot: source,
        target_slot: target
    }
}

pub fn make_rc_drop(slot: SlotRef) -> RcOperation {
    RcOperation {
        kind: rc_op_kind_drop(), source_slot: slot, target_slot: none
    }
}

pub fn make_rc_cleanup(slot: SlotRef) -> RcOperation {
    RcOperation {
        kind: rc_op_kind_cleanup(), source_slot: slot, target_slot: none
    }
}

pub fn rc_operation_kind(value: RcOperation) -> RcOpKind { value.kind }
pub fn rc_operation_source(value: RcOperation) -> SlotRef { value.source_slot }
pub fn rc_operation_target(value: RcOperation) -> SlotRef? { value.target_slot }

fn copy_rc_operations(values: List<RcOperation>) -> List<RcOperation> {
    let mut result: List<RcOperation> = []
    for value in values {
        result.push(RcOperation {
            kind: value.kind,
            source_slot: value.source_slot,
            target_slot: value.target_slot
        })
    }
    result
}

// ============================================================
// Frozen binder snapshot
// ============================================================

pub struct RcSlot {
    reference: SlotRef,
    type_index: Int,
    scope_id: Int,
    scope_depth: Int,
    reverse_lexical_ordinal: Int
}

pub fn make_rc_slot(
    reference: SlotRef, type_index: Int, scope_id: Int,
    scope_depth: Int, reverse_lexical_ordinal: Int
) -> RcSlot {
    if type_index < 0 || scope_id < 0 || scope_depth < 0 ||
       reverse_lexical_ordinal < 0 {
        panic("RcIR: slot metadata is negative")
    }
    RcSlot {
        reference: reference,
        type_index: type_index,
        scope_id: scope_id,
        scope_depth: scope_depth,
        reverse_lexical_ordinal: reverse_lexical_ordinal
    }
}

pub fn rc_slot_reference(value: RcSlot) -> SlotRef { value.reference }
pub fn rc_slot_type_index(value: RcSlot) -> Int { value.type_index }
pub fn rc_slot_scope_id(value: RcSlot) -> Int { value.scope_id }
pub fn rc_slot_scope_depth(value: RcSlot) -> Int { value.scope_depth }
pub fn rc_slot_reverse_lexical_ordinal(value: RcSlot) -> Int {
    value.reverse_lexical_ordinal
}

fn copy_rc_slots(values: List<RcSlot>) -> List<RcSlot> {
    let mut result: List<RcSlot> = []
    for value in values {
        result.push(make_rc_slot(
            value.reference, value.type_index, value.scope_id,
            value.scope_depth, value.reverse_lexical_ordinal))
    }
    result
}

fn rc_slots_contain(values: List<RcSlot>, target: SlotRef) -> Bool {
    for value in values {
        if slot_ref_same(value.reference, target) { return true }
    }
    false
}

fn validate_rc_slots(values: List<RcSlot>) {
    let mut left_index = 0
    while left_index < values.len() {
        let left = values.get(left_index).unwrap()
        let mut right_index = left_index + 1
        while right_index < values.len() {
            let right = values.get(right_index).unwrap()
            if slot_ref_same(left.reference, right.reference) {
                panic("RcIR: duplicate binder slot")
            }
            if left.scope_id == right.scope_id &&
               left.reverse_lexical_ordinal ==
                   right.reverse_lexical_ordinal {
                panic("RcIR: duplicate reverse-lexical slot ordinal")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
}

// ============================================================
// Topology-preserving block projection
// ============================================================

pub struct RcStep {
    semantic_op_index: Int,
    before: List<RcOperation>,
    after: List<RcOperation>
}

pub fn make_rc_step(
    semantic_op_index: Int,
    before: List<RcOperation>, after: List<RcOperation>
) -> RcStep {
    if semantic_op_index < 0 {
        panic("RcIR: semantic operation index is negative")
    }
    RcStep {
        semantic_op_index: semantic_op_index,
        before: copy_rc_operations(before),
        after: copy_rc_operations(after)
    }
}

pub fn rc_step_semantic_op_index(value: RcStep) -> Int {
    value.semantic_op_index
}
pub fn rc_step_before(value: RcStep) -> List<RcOperation> {
    copy_rc_operations(value.before)
}
pub fn rc_step_after(value: RcStep) -> List<RcOperation> {
    copy_rc_operations(value.after)
}

fn copy_rc_steps(values: List<RcStep>) -> List<RcStep> {
    let mut result: List<RcStep> = []
    for value in values {
        result.push(make_rc_step(
            value.semantic_op_index, value.before, value.after))
    }
    result
}

// Each edge preserves one FlowIR successor exactly.  target_block is absent
// only for a terminal Return/Break-to-caller/Diverge edge already present in
// FlowIR.  cleanup is the only materialized edge sequence.
pub struct RcEdge {
    successor_ordinal: Int,
    target_block: Int?,
    cleanup: List<RcOperation>
}

pub fn make_rc_edge(
    successor_ordinal: Int, target_block: Int?, cleanup: List<RcOperation>
) -> RcEdge {
    if successor_ordinal < 0 {
        panic("RcIR: successor ordinal is negative")
    }
    for operation in cleanup {
        if !rc_op_kind_same(operation.kind, rc_op_kind_cleanup()) {
            panic("RcIR: edge materialization contains a non-cleanup operation")
        }
    }
    RcEdge {
        successor_ordinal: successor_ordinal,
        target_block: target_block,
        cleanup: copy_rc_operations(cleanup)
    }
}

pub fn rc_edge_successor_ordinal(value: RcEdge) -> Int {
    value.successor_ordinal
}
pub fn rc_edge_target_block(value: RcEdge) -> Int? { value.target_block }
pub fn rc_edge_cleanup(value: RcEdge) -> List<RcOperation> {
    copy_rc_operations(value.cleanup)
}

fn copy_rc_edges(values: List<RcEdge>) -> List<RcEdge> {
    let mut result: List<RcEdge> = []
    for value in values {
        result.push(make_rc_edge(
            value.successor_ordinal, value.target_block, value.cleanup))
    }
    result
}

pub struct RcBlock {
    source_block_index: Int,
    semantic_op_count: Int,
    steps: List<RcStep>,
    before_terminator: List<RcOperation>,
    edges: List<RcEdge>
}

fn validate_operation_slots(operation: RcOperation, slots: List<RcSlot>) {
    if !rc_slots_contain(slots, operation.source_slot) {
        panic("RcIR: resource operation source is not a frozen binder")
    }
    match operation.target_slot {
        some(target) => if !rc_slots_contain(slots, target) {
            panic("RcIR: resource operation target is not a frozen binder")
        },
        none => {}
    }
}

fn validate_rc_block(block: RcBlock, slots: List<RcSlot>, block_count: Int) {
    if block.source_block_index < 0 ||
       block.source_block_index >= block_count ||
       block.semantic_op_count < 0 {
        panic("RcIR: invalid source block metadata")
    }
    if block.steps.len() != block.semantic_op_count {
        panic("RcIR: resource step census differs from semantic operation census")
    }
    let mut step_index = 0
    while step_index < block.steps.len() {
        let step = block.steps.get(step_index).unwrap()
        if step.semantic_op_index != step_index {
            panic("RcIR: resource steps changed semantic operation order")
        }
        for operation in step.before {
            validate_operation_slots(operation, slots)
        }
        for operation in step.after {
            validate_operation_slots(operation, slots)
        }
        step_index = step_index + 1
    }
    for operation in block.before_terminator {
        validate_operation_slots(operation, slots)
    }
    let mut edge_index = 0
    while edge_index < block.edges.len() {
        let edge = block.edges.get(edge_index).unwrap()
        if edge.successor_ordinal != edge_index {
            panic("RcIR: resource edges changed successor order")
        }
        match edge.target_block {
            some(target) => if target < 0 || target >= block_count {
                panic("RcIR: resource edge target is outside frozen CFG")
            },
            none => {}
        }
        for operation in edge.cleanup {
            validate_operation_slots(operation, slots)
        }
        edge_index = edge_index + 1
    }
}

pub fn make_rc_block(
    source_block_index: Int, semantic_op_count: Int,
    steps: List<RcStep>, before_terminator: List<RcOperation>,
    edges: List<RcEdge>
) -> RcBlock {
    // Body-level construction performs the closure checks that require the
    // complete frozen binder/block census.
    RcBlock {
        source_block_index: source_block_index,
        semantic_op_count: semantic_op_count,
        steps: copy_rc_steps(steps),
        before_terminator: copy_rc_operations(before_terminator),
        edges: copy_rc_edges(edges)
    }
}

pub fn rc_block_source_index(value: RcBlock) -> Int {
    value.source_block_index
}
pub fn rc_block_semantic_op_count(value: RcBlock) -> Int {
    value.semantic_op_count
}
pub fn rc_block_steps(value: RcBlock) -> List<RcStep> {
    copy_rc_steps(value.steps)
}
pub fn rc_block_before_terminator(value: RcBlock) -> List<RcOperation> {
    copy_rc_operations(value.before_terminator)
}
pub fn rc_block_edges(value: RcBlock) -> List<RcEdge> {
    copy_rc_edges(value.edges)
}

fn copy_rc_blocks(values: List<RcBlock>) -> List<RcBlock> {
    let mut result: List<RcBlock> = []
    for value in values {
        result.push(make_rc_block(
            value.source_block_index, value.semantic_op_count,
            value.steps, value.before_terminator, value.edges))
    }
    result
}

pub struct RcBody {
    reference: ExecutableRef,
    slots: List<RcSlot>,
    entry_block: Int,
    blocks: List<RcBlock>
}

pub fn make_rc_body(
    reference: ExecutableRef, slots: List<RcSlot>,
    entry_block: Int, blocks: List<RcBlock>
) -> RcBody {
    if blocks.len() == 0 {
        panic("RcIR: executable body has no CFG block")
    }
    if entry_block < 0 || entry_block >= blocks.len() {
        panic("RcIR: entry block is outside frozen CFG")
    }
    validate_rc_slots(slots)
    let mut block_index = 0
    while block_index < blocks.len() {
        let block = blocks.get(block_index).unwrap()
        if block.source_block_index != block_index {
            panic("RcIR: block order differs from FlowIR")
        }
        validate_rc_block(block, slots, blocks.len())
        block_index = block_index + 1
    }
    RcBody {
        reference: reference,
        slots: copy_rc_slots(slots),
        entry_block: entry_block,
        blocks: copy_rc_blocks(blocks)
    }
}

pub fn rc_body_reference(value: RcBody) -> ExecutableRef { value.reference }
pub fn rc_body_slots(value: RcBody) -> List<RcSlot> {
    copy_rc_slots(value.slots)
}
pub fn rc_body_entry_block(value: RcBody) -> Int { value.entry_block }
pub fn rc_body_blocks(value: RcBody) -> List<RcBlock> {
    copy_rc_blocks(value.blocks)
}

fn copy_rc_bodies(values: List<RcBody>) -> List<RcBody> {
    let mut result: List<RcBody> = []
    for value in values {
        result.push(make_rc_body(
            value.reference, value.slots, value.entry_block, value.blocks))
    }
    result
}

pub struct RcProgram {
    flow_fingerprint: Str,
    type_count: Int,
    callable_count: Int,
    bodies: List<RcBody>
}

pub fn make_rc_program(
    flow_fingerprint: Str, type_count: Int,
    callable_count: Int, bodies: List<RcBody>
) -> RcProgram {
    if flow_fingerprint.len() == 0 {
        panic("RcIR: missing frozen FlowIR fingerprint")
    }
    if type_count < 0 || callable_count < 0 {
        panic("RcIR: negative frozen graph census")
    }
    let mut left_index = 0
    while left_index < bodies.len() {
        let left = bodies.get(left_index).unwrap()
        let mut right_index = left_index + 1
        while right_index < bodies.len() {
            let right = bodies.get(right_index).unwrap()
            if executable_ref_same(left.reference, right.reference) {
                panic("RcIR: duplicate executable body")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    RcProgram {
        flow_fingerprint: flow_fingerprint,
        type_count: type_count,
        callable_count: callable_count,
        bodies: copy_rc_bodies(bodies)
    }
}

pub fn rc_program_flow_fingerprint(value: RcProgram) -> Str {
    value.flow_fingerprint
}
pub fn rc_program_type_count(value: RcProgram) -> Int { value.type_count }
pub fn rc_program_callable_count(value: RcProgram) -> Int {
    value.callable_count
}
pub fn rc_program_bodies(value: RcProgram) -> List<RcBody> {
    copy_rc_bodies(value.bodies)
}

