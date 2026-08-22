// F0 inert resource lattices.
//
// Identity belongs to ir_identity.ring.  Staged IR nodes, resource planning,
// certificates, and executable-tree storage are deliberately absent here.

// ============================================================
// ParamMode chain and independent FORCE product
// ============================================================

const PARAM_MODE_BOTTOM: Int = 0
const PARAM_MODE_BORROW: Int = 1
const PARAM_MODE_MUT_BORROW: Int = 2
const PARAM_MODE_OWN: Int = 3
const PARAM_MODE_CONFLICT: Int = 4
const PARAM_MODE_COUNT: Int = 5

// Bottom < Borrow < MutBorrow < Own < Conflict.  Conflict is an explicit
// diagnostic top: joining ordinary modes (tags 0..3) never creates it.
const PARAM_MODE_JOIN_TAGS: List<Int> = [
    0, 1, 2, 3, 4,
    1, 1, 2, 3, 4,
    2, 2, 2, 3, 4,
    3, 3, 3, 3, 4,
    4, 4, 4, 4, 4
]
const PARAM_MODE_RANKS: List<Int> = [0, 1, 2, 3, 4]

pub struct ParamMode {
    tag: Int
}

pub fn param_mode_from_tag(tag: Int) -> ParamMode {
    if tag < PARAM_MODE_BOTTOM || tag >= PARAM_MODE_COUNT {
        panic("resource model: invalid ParamMode tag")
    }
    ParamMode { tag: tag }
}

pub fn param_mode_bottom() -> ParamMode {
    param_mode_from_tag(PARAM_MODE_BOTTOM)
}

pub fn param_mode_borrow() -> ParamMode {
    param_mode_from_tag(PARAM_MODE_BORROW)
}

pub fn param_mode_mut_borrow() -> ParamMode {
    param_mode_from_tag(PARAM_MODE_MUT_BORROW)
}

pub fn param_mode_own() -> ParamMode {
    param_mode_from_tag(PARAM_MODE_OWN)
}

pub fn param_mode_conflict() -> ParamMode {
    param_mode_from_tag(PARAM_MODE_CONFLICT)
}

pub fn param_mode_tag(mode: ParamMode) -> Int {
    param_mode_from_tag(mode.tag).tag
}

pub fn param_mode_is_conflict(mode: ParamMode) -> Bool {
    param_mode_tag(mode) == PARAM_MODE_CONFLICT
}

pub fn param_mode_same(left: ParamMode, right: ParamMode) -> Bool {
    param_mode_tag(left) == param_mode_tag(right)
}

pub fn param_mode_join(left: ParamMode, right: ParamMode) -> ParamMode {
    let left_tag = param_mode_tag(left)
    let right_tag = param_mode_tag(right)
    let index = left_tag * PARAM_MODE_COUNT + right_tag
    match PARAM_MODE_JOIN_TAGS.get(index) {
        some(tag) => param_mode_from_tag(tag),
        none => panic("resource model: ParamMode join table is incomplete")
    }
}

pub fn param_mode_leq(left: ParamMode, right: ParamMode) -> Bool {
    param_mode_same(param_mode_join(left, right), right)
}

pub fn param_mode_rank(mode: ParamMode) -> Int {
    match PARAM_MODE_RANKS.get(param_mode_tag(mode)) {
        some(rank) => rank,
        none => panic("resource model: ParamMode rank table is incomplete")
    }
}

pub struct TransferDemand {
    mode: ParamMode,
    force: Bool
}

pub fn make_transfer_demand(mode: ParamMode, force: Bool) -> TransferDemand {
    let checked_mode = param_mode_from_tag(param_mode_tag(mode))
    if force && !param_mode_same(checked_mode, param_mode_own()) {
        panic("resource model: FORCE requires Own ParamMode")
    }
    TransferDemand { mode: checked_mode, force: force }
}

pub fn transfer_demand_mode(value: TransferDemand) -> ParamMode {
    value.mode
}

pub fn transfer_demand_force(value: TransferDemand) -> Bool {
    value.force
}

pub fn transfer_demand_join(
    left: TransferDemand, right: TransferDemand
) -> TransferDemand {
    let joined_mode = param_mode_join(left.mode, right.mode)
    // Explicit Conflict is the diagnostic top for the complete product.  It
    // absorbs FORCE; every non-conflict FORCE value still has exactly Own.
    let joined_force = if param_mode_is_conflict(joined_mode) {
        false
    } else {
        left.force || right.force
    }
    make_transfer_demand(
        joined_mode, joined_force)
}

pub fn transfer_demand_same(
    left: TransferDemand, right: TransferDemand
) -> Bool {
    param_mode_same(left.mode, right.mode) && left.force == right.force
}

pub fn transfer_demand_leq(
    left: TransferDemand, right: TransferDemand
) -> Bool {
    transfer_demand_same(transfer_demand_join(left, right), right)
}

pub fn transfer_demand_rank(value: TransferDemand) -> Int {
    if param_mode_is_conflict(value.mode) { return 5 }
    let force_rank = if value.force { 1 } else { 0 }
    param_mode_rank(value.mode) + force_rank
}

// ============================================================
// Independent logical and physical shape lattices
// ============================================================

pub struct LogicalOwnershipShape {
    direct_drop: Bool,
    may_unique: Bool,
    param_deps: List<Bool>
}

pub struct PhysicalRcShape {
    physical_rc: Bool,
    boxing: Bool,
    drop_glue: Bool,
    foreign_containment: Bool,
    param_deps: List<Bool>
}

fn bool_list_join(left: List<Bool>, right: List<Bool>) -> List<Bool> {
    if left.len() != right.len() {
        panic("resource model: shape dependency arity mismatch")
    }
    let mut result: List<Bool> = []
    let mut index = 0
    while index < left.len() {
        match (left.get(index), right.get(index)) {
            (some(a), some(b)) => result.push(a || b),
            _ => panic("resource model: shape dependency list is incomplete")
        }
        index = index + 1
    }
    result
}

fn bool_list_same(left: List<Bool>, right: List<Bool>) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        match (left.get(index), right.get(index)) {
            (some(a), some(b)) => if a != b { return false },
            _ => return false
        }
        index = index + 1
    }
    true
}

fn bool_list_rank(values: List<Bool>) -> Int {
    let mut rank = 0
    for value in values { if value { rank = rank + 1 } }
    rank
}

fn copy_bool_list(values: List<Bool>) -> List<Bool> {
    let mut result: List<Bool> = []
    for value in values { result.push(value) }
    result
}

pub fn make_logical_ownership_shape(
    direct_drop: Bool, may_unique: Bool, param_deps: List<Bool>
) -> LogicalOwnershipShape {
    if direct_drop && !may_unique {
        panic("resource model: direct-drop logical shape is not unique-capable")
    }
    LogicalOwnershipShape {
        direct_drop: direct_drop,
        may_unique: may_unique,
        param_deps: copy_bool_list(param_deps)
    }
}

pub fn logical_ownership_shape_direct_drop(
    value: LogicalOwnershipShape
) -> Bool {
    value.direct_drop
}

pub fn logical_ownership_shape_may_unique(
    value: LogicalOwnershipShape
) -> Bool {
    value.may_unique
}

pub fn logical_ownership_shape_param_deps(
    value: LogicalOwnershipShape
) -> List<Bool> {
    copy_bool_list(value.param_deps)
}

pub fn logical_ownership_shape_join(
    left: LogicalOwnershipShape, right: LogicalOwnershipShape
) -> LogicalOwnershipShape {
    make_logical_ownership_shape(
        left.direct_drop || right.direct_drop,
        left.may_unique || right.may_unique,
        bool_list_join(left.param_deps, right.param_deps))
}

pub fn logical_ownership_shape_same(
    left: LogicalOwnershipShape, right: LogicalOwnershipShape
) -> Bool {
    left.direct_drop == right.direct_drop &&
        left.may_unique == right.may_unique &&
        bool_list_same(left.param_deps, right.param_deps)
}

pub fn logical_ownership_shape_leq(
    left: LogicalOwnershipShape, right: LogicalOwnershipShape
) -> Bool {
    logical_ownership_shape_same(
        logical_ownership_shape_join(left, right), right)
}

pub fn logical_ownership_shape_rank(shape: LogicalOwnershipShape) -> Int {
    let direct = if shape.direct_drop { 1 } else { 0 }
    let unique = if shape.may_unique { 1 } else { 0 }
    direct + unique + bool_list_rank(shape.param_deps)
}

pub fn make_physical_rc_shape(
    physical_rc: Bool, boxing: Bool, drop_glue: Bool,
    foreign_containment: Bool, param_deps: List<Bool>
) -> PhysicalRcShape {
    PhysicalRcShape {
        physical_rc: physical_rc,
        boxing: boxing,
        drop_glue: drop_glue,
        foreign_containment: foreign_containment,
        param_deps: copy_bool_list(param_deps)
    }
}

pub fn physical_rc_shape_physical_rc(value: PhysicalRcShape) -> Bool {
    value.physical_rc
}

pub fn physical_rc_shape_boxing(value: PhysicalRcShape) -> Bool {
    value.boxing
}

pub fn physical_rc_shape_drop_glue(value: PhysicalRcShape) -> Bool {
    value.drop_glue
}

pub fn physical_rc_shape_foreign_containment(
    value: PhysicalRcShape
) -> Bool {
    value.foreign_containment
}

pub fn physical_rc_shape_param_deps(value: PhysicalRcShape) -> List<Bool> {
    copy_bool_list(value.param_deps)
}

pub fn physical_rc_shape_join(
    left: PhysicalRcShape, right: PhysicalRcShape
) -> PhysicalRcShape {
    make_physical_rc_shape(
        left.physical_rc || right.physical_rc,
        left.boxing || right.boxing,
        left.drop_glue || right.drop_glue,
        left.foreign_containment || right.foreign_containment,
        bool_list_join(left.param_deps, right.param_deps))
}

pub fn physical_rc_shape_same(
    left: PhysicalRcShape, right: PhysicalRcShape
) -> Bool {
    left.physical_rc == right.physical_rc &&
        left.boxing == right.boxing &&
        left.drop_glue == right.drop_glue &&
        left.foreign_containment == right.foreign_containment &&
        bool_list_same(left.param_deps, right.param_deps)
}

pub fn physical_rc_shape_leq(
    left: PhysicalRcShape, right: PhysicalRcShape
) -> Bool {
    physical_rc_shape_same(physical_rc_shape_join(left, right), right)
}

pub fn physical_rc_shape_rank(shape: PhysicalRcShape) -> Int {
    let rc = if shape.physical_rc { 1 } else { 0 }
    let boxed = if shape.boxing { 1 } else { 0 }
    let glue = if shape.drop_glue { 1 } else { 0 }
    let foreign = if shape.foreign_containment { 1 } else { 0 }
    rc + boxed + glue + foreign + bool_list_rank(shape.param_deps)
}

// ============================================================
// SlotFlow lattice and explicit transitions
// ============================================================

const SLOT_FLOW_UNREACHABLE: Int = 0
const SLOT_FLOW_EMPTY: Int = 1
const SLOT_FLOW_LIVE: Int = 2
const SLOT_FLOW_MOVED: Int = 3
const SLOT_FLOW_MAYBE_MOVED: Int = 4
const SLOT_FLOW_COUNT: Int = 5

// Unreachable is Bottom.  Empty, Live, and Moved are incomparable reachable
// states; any distinct reachable join is MaybeMoved, which is top.
const SLOT_FLOW_JOIN_TAGS: List<Int> = [
    0, 1, 2, 3, 4,
    1, 1, 4, 4, 4,
    2, 4, 2, 4, 4,
    3, 4, 4, 3, 4,
    4, 4, 4, 4, 4
]
const SLOT_FLOW_RANKS: List<Int> = [0, 1, 1, 1, 2]
const SLOT_FLOW_ASSIGNMENT_TAGS: List<Int> = [0, 2, 2, 2, 2]
const SLOT_FLOW_TAKE_TAGS: List<Int> = [0, 1, 3, 3, 4]
const SLOT_FLOW_TAKE_FINDINGS: List<Bool> = [false, true, false, true, true]

pub struct SlotFlow {
    tag: Int
}

pub struct SlotFlowTransition {
    flow: SlotFlow,
    requires_finding: Bool
}

pub fn slot_flow_from_tag(tag: Int) -> SlotFlow {
    if tag < SLOT_FLOW_UNREACHABLE || tag >= SLOT_FLOW_COUNT {
        panic("resource model: invalid SlotFlow tag")
    }
    SlotFlow { tag: tag }
}

pub fn slot_flow_unreachable() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_UNREACHABLE)
}

pub fn slot_flow_empty() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_EMPTY)
}

pub fn slot_flow_live() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_LIVE)
}

pub fn slot_flow_moved() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_MOVED)
}

pub fn slot_flow_maybe_moved() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_MAYBE_MOVED)
}

pub fn slot_flow_tag(flow: SlotFlow) -> Int {
    slot_flow_from_tag(flow.tag).tag
}

pub fn slot_flow_same(left: SlotFlow, right: SlotFlow) -> Bool {
    slot_flow_tag(left) == slot_flow_tag(right)
}

pub fn slot_flow_join(left: SlotFlow, right: SlotFlow) -> SlotFlow {
    let left_tag = slot_flow_tag(left)
    let right_tag = slot_flow_tag(right)
    let index = left_tag * SLOT_FLOW_COUNT + right_tag
    match SLOT_FLOW_JOIN_TAGS.get(index) {
        some(tag) => slot_flow_from_tag(tag),
        none => panic("resource model: SlotFlow join table is incomplete")
    }
}

pub fn slot_flow_leq(left: SlotFlow, right: SlotFlow) -> Bool {
    slot_flow_same(slot_flow_join(left, right), right)
}

pub fn slot_flow_rank(flow: SlotFlow) -> Int {
    match SLOT_FLOW_RANKS.get(slot_flow_tag(flow)) {
        some(rank) => rank,
        none => panic("resource model: SlotFlow rank table is incomplete")
    }
}

pub fn slot_flow_after_assignment(flow: SlotFlow) -> SlotFlow {
    match SLOT_FLOW_ASSIGNMENT_TAGS.get(slot_flow_tag(flow)) {
        some(tag) => slot_flow_from_tag(tag),
        none => panic("resource model: assignment transition table is incomplete")
    }
}

pub fn slot_flow_take(flow: SlotFlow) -> SlotFlowTransition {
    let tag = slot_flow_tag(flow)
    match (SLOT_FLOW_TAKE_TAGS.get(tag),
           SLOT_FLOW_TAKE_FINDINGS.get(tag)) {
        (some(next), some(finding)) => SlotFlowTransition {
            flow: slot_flow_from_tag(next),
            requires_finding: finding
        },
        _ => panic("resource model: Take transition table is incomplete")
    }
}

pub fn slot_flow_transition_flow(value: SlotFlowTransition) -> SlotFlow {
    value.flow
}

pub fn slot_flow_transition_requires_finding(
    value: SlotFlowTransition
) -> Bool {
    value.requires_finding
}
