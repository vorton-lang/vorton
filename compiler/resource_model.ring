// F0 inert resource lattices.
//
// Identity belongs to ir_identity.ring.  Staged IR nodes, resource planning,
// certificates, and executable-tree storage are deliberately absent here.

use ir_identity::{CoreTypeRef, core_type_ref_same}

// ============================================================
// Core-frozen resource contracts shared by Core and Flow
// ============================================================

const FLOW_SEED_SCALAR: Int = 0
const FLOW_SEED_PTR: Int = 1
const FLOW_SEED_UNIQUE: Int = 2
const FLOW_SEED_SHAREABLE: Int = 3
const FLOW_SEED_EXTERN: Int = 4
const FLOW_SEED_PARAMETRIC: Int = 5

pub struct FlowTypeSemanticSeed { tag: Int }
fn flow_type_semantic_seed_from_tag(tag: Int) -> FlowTypeSemanticSeed {
    if tag < FLOW_SEED_SCALAR || tag > FLOW_SEED_PARAMETRIC {
        panic("resource model: invalid type semantic seed")
    }
    FlowTypeSemanticSeed { tag: tag }
}
pub fn flow_type_seed_scalar() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_SCALAR)
}
pub fn flow_type_seed_ptr() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_PTR)
}
pub fn flow_type_seed_unique() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_UNIQUE)
}
pub fn flow_type_seed_shareable() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_SHAREABLE)
}
pub fn flow_type_seed_extern() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_EXTERN)
}
pub fn flow_type_seed_parametric() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_PARAMETRIC)
}
pub fn flow_type_semantic_seed_tag(value: FlowTypeSemanticSeed) -> Int {
    flow_type_semantic_seed_from_tag(value.tag).tag
}

const FLOW_ROLE_READ: Int = 0
const FLOW_ROLE_MUTATE: Int = 1
const FLOW_ROLE_CONSUME: Int = 2
const FLOW_ROLE_FORCE: Int = 3

pub struct FlowSemanticRole { tag: Int }
fn flow_semantic_role_from_tag(tag: Int) -> FlowSemanticRole {
    if tag < FLOW_ROLE_READ || tag > FLOW_ROLE_FORCE {
        panic("resource model: invalid semantic role")
    }
    FlowSemanticRole { tag: tag }
}
pub fn flow_semantic_role_read() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_READ)
}
pub fn flow_semantic_role_mutate() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_MUTATE)
}
pub fn flow_semantic_role_consume() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_CONSUME)
}
pub fn flow_semantic_role_force() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_FORCE)
}
pub fn flow_semantic_role_tag(value: FlowSemanticRole) -> Int {
    flow_semantic_role_from_tag(value.tag).tag
}
pub fn copy_semantic_roles(
    values: List<FlowSemanticRole>
) -> List<FlowSemanticRole> {
    values.map(fn(value) { value })
}

enum FlowValueOriginContractValue {
    FreshValueOrigin,
    AliasesValueOrigin(List<Int>)
}
pub struct FlowValueOriginContract { value: FlowValueOriginContractValue }
pub fn make_fresh_flow_value_origin() -> FlowValueOriginContract {
    FlowValueOriginContract {
        value: FlowValueOriginContractValue::FreshValueOrigin
    }
}
pub fn make_aliasing_flow_value_origin(
    ordinals: List<Int>
) -> FlowValueOriginContract {
    if ordinals.len() == 0 {
        panic("resource model: alias origin has no source ordinal")
    }
    let mut copied: List<Int> = []
    let mut left_index = 0
    while left_index < ordinals.len() {
        let left = ordinals.get(left_index).unwrap()
        if left < 0 { panic("resource model: negative alias source ordinal") }
        let mut right_index = left_index + 1
        while right_index < ordinals.len() {
            if left == ordinals.get(right_index).unwrap() {
                panic("resource model: alias origin repeats a source ordinal")
            }
            right_index = right_index + 1
        }
        copied.push(left)
        left_index = left_index + 1
    }
    FlowValueOriginContract {
        value: FlowValueOriginContractValue::AliasesValueOrigin(copied)
    }
}
pub fn flow_value_origin_is_fresh(value: FlowValueOriginContract) -> Bool {
    match value.value {
        FlowValueOriginContractValue::FreshValueOrigin => true,
        FlowValueOriginContractValue::AliasesValueOrigin(_) => false
    }
}
pub fn flow_value_origin_alias_ordinals(
    value: FlowValueOriginContract
) -> List<Int> {
    match value.value {
        FlowValueOriginContractValue::AliasesValueOrigin(ordinals) =>
            ordinals.map(fn(ordinal) { ordinal }),
        FlowValueOriginContractValue::FreshValueOrigin =>
            panic("resource model: fresh value has no alias ordinals")
    }
}
pub fn copy_value_origin(
    value: FlowValueOriginContract
) -> FlowValueOriginContract {
    match value.value {
        FlowValueOriginContractValue::FreshValueOrigin =>
            make_fresh_flow_value_origin(),
        FlowValueOriginContractValue::AliasesValueOrigin(ordinals) =>
            make_aliasing_flow_value_origin(ordinals)
    }
}
pub fn value_origin_same(
    left: FlowValueOriginContract, right: FlowValueOriginContract
) -> Bool {
    match (left.value, right.value) {
        (FlowValueOriginContractValue::FreshValueOrigin,
         FlowValueOriginContractValue::FreshValueOrigin) => true,
        (FlowValueOriginContractValue::AliasesValueOrigin(a),
         FlowValueOriginContractValue::AliasesValueOrigin(b)) => {
            if a.len() != b.len() { return false }
            let mut index = 0
            while index < a.len() {
                if a.get(index).unwrap() != b.get(index).unwrap() {
                    return false
                }
                index = index + 1
            }
            true
        },
        _ => false
    }
}
pub fn validate_value_origin_arity(
    value: FlowValueOriginContract, source_count: Int
) {
    if !flow_value_origin_is_fresh(value) {
        for ordinal in flow_value_origin_alias_ordinals(value) {
            if ordinal < 0 || ordinal >= source_count {
                panic("resource model: alias source ordinal exceeds inputs")
            }
        }
    }
}

fn copy_contract_type_refs(values: List<CoreTypeRef>) -> List<CoreTypeRef> {
    values.map(fn(value) { value })
}
pub struct FlowCallContract {
    module_key: Str?,
    parameter_types: List<CoreTypeRef>,
    parameter_roles: List<FlowSemanticRole>,
    result_type: CoreTypeRef,
    result_role: FlowSemanticRole,
    result_origin: FlowValueOriginContract
}
pub fn make_flow_call_contract(
    parameter_types: List<CoreTypeRef>,
    parameter_roles: List<FlowSemanticRole>,
    result_type: CoreTypeRef, result_role: FlowSemanticRole,
    result_origin: FlowValueOriginContract
) -> FlowCallContract {
    if parameter_types.len() != parameter_roles.len() {
        panic("resource model: call type/role arity differs")
    }
    for role in parameter_roles { let _ = flow_semantic_role_tag(role) }
    let _ = flow_semantic_role_tag(result_role)
    validate_value_origin_arity(result_origin, parameter_types.len())
    FlowCallContract {
        module_key: none,
        parameter_types: copy_contract_type_refs(parameter_types),
        parameter_roles: copy_semantic_roles(parameter_roles),
        result_type: result_type, result_role: result_role,
        result_origin: copy_value_origin(result_origin)
    }
}
pub fn make_module_flow_call_contract(
    module_key: Str, parameter_types: List<CoreTypeRef>,
    parameter_roles: List<FlowSemanticRole>,
    result_type: CoreTypeRef, result_role: FlowSemanticRole,
    result_origin: FlowValueOriginContract
) -> FlowCallContract {
    if module_key == "" { panic("resource model: empty call type domain") }
    let mut result = make_flow_call_contract(
        parameter_types, parameter_roles, result_type, result_role,
        result_origin)
    result.module_key = some(module_key)
    result
}
pub fn flow_call_contract_module_key(value: FlowCallContract) -> Str? {
    value.module_key
}
pub fn flow_call_contract_parameter_types(
    value: FlowCallContract
) -> List<CoreTypeRef> { copy_contract_type_refs(value.parameter_types) }
pub fn flow_call_contract_parameter_roles(
    value: FlowCallContract
) -> List<FlowSemanticRole> { copy_semantic_roles(value.parameter_roles) }
pub fn flow_call_contract_result_role(
    value: FlowCallContract
) -> FlowSemanticRole { value.result_role }
pub fn flow_call_contract_result_type(value: FlowCallContract) -> CoreTypeRef {
    value.result_type
}
pub fn flow_call_contract_result_origin(
    value: FlowCallContract
) -> FlowValueOriginContract { copy_value_origin(value.result_origin) }
pub fn flow_call_contract_same(
    left: FlowCallContract, right: FlowCallContract
) -> Bool {
    if left.module_key != right.module_key ||
       left.parameter_roles.len() != right.parameter_roles.len() ||
       left.parameter_types.len() != right.parameter_types.len() ||
       !core_type_ref_same(left.result_type, right.result_type) ||
       flow_semantic_role_tag(left.result_role) !=
            flow_semantic_role_tag(right.result_role) ||
       !value_origin_same(left.result_origin, right.result_origin) {
        return false
    }
    let mut index = 0
    while index < left.parameter_roles.len() {
        if !core_type_ref_same(
                left.parameter_types.get(index).unwrap(),
                right.parameter_types.get(index).unwrap()) ||
           flow_semantic_role_tag(left.parameter_roles.get(index).unwrap()) !=
                flow_semantic_role_tag(
                    right.parameter_roles.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}
pub fn copy_call_contract(value: FlowCallContract) -> FlowCallContract {
    match value.module_key {
        some(module_key) => make_module_flow_call_contract(
            module_key, value.parameter_types, value.parameter_roles,
            value.result_type, value.result_role, value.result_origin),
        none => make_flow_call_contract(
            value.parameter_types, value.parameter_roles,
            value.result_type, value.result_role, value.result_origin)
    }
}

const FLOW_OWN_STORAGE: Int = 0
const FLOW_BORROW_STORAGE: Int = 1
pub struct FlowStorageContract { tag: Int }
fn flow_storage_contract_from_tag(tag: Int) -> FlowStorageContract {
    if tag < FLOW_OWN_STORAGE || tag > FLOW_BORROW_STORAGE {
        panic("resource model: invalid source storage contract")
    }
    FlowStorageContract { tag: tag }
}
pub fn flow_own_storage() -> FlowStorageContract {
    flow_storage_contract_from_tag(FLOW_OWN_STORAGE)
}
pub fn flow_borrow_storage() -> FlowStorageContract {
    flow_storage_contract_from_tag(FLOW_BORROW_STORAGE)
}
pub fn flow_storage_contract_tag(value: FlowStorageContract) -> Int {
    flow_storage_contract_from_tag(value.tag).tag
}

// ============================================================
// ParamMode chain and independent FORCE product
// ============================================================

const PARAM_MODE_BOTTOM: Int = 0
const PARAM_MODE_BORROW: Int = 1
const PARAM_MODE_MUT_BORROW: Int = 2
const PARAM_MODE_OWN: Int = 3
const PARAM_MODE_COUNT: Int = 4

// Bottom < Borrow < MutBorrow < Own.
const PARAM_MODE_JOIN_TAGS: List<Int> = [
    0, 1, 2, 3,
    1, 1, 2, 3,
    2, 2, 2, 3,
    3, 3, 3, 3
]

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

pub fn param_mode_tag(mode: ParamMode) -> Int {
    param_mode_from_tag(mode.tag).tag
}

pub fn param_mode_same(left: ParamMode, right: ParamMode) -> Bool {
    param_mode_tag(left) == param_mode_tag(right)
}

fn param_mode_join(left: ParamMode, right: ParamMode) -> ParamMode {
    let left_tag = param_mode_tag(left)
    let right_tag = param_mode_tag(right)
    let index = left_tag * PARAM_MODE_COUNT + right_tag
    match PARAM_MODE_JOIN_TAGS.get(index) {
        some(tag) => param_mode_from_tag(tag),
        none => panic("resource model: ParamMode join table is incomplete")
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
    make_transfer_demand(joined_mode, left.force || right.force)
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
pub struct SlotFlow {
    tag: Int,
    cleanup_owner: Bool
}

fn make_slot_flow(tag: Int, cleanup_owner: Bool) -> SlotFlow {
    if tag < SLOT_FLOW_UNREACHABLE || tag >= SLOT_FLOW_COUNT {
        panic("resource model: invalid SlotFlow tag")
    }
    if cleanup_owner && tag != SLOT_FLOW_LIVE &&
       tag != SLOT_FLOW_MAYBE_MOVED {
        panic("resource model: unavailable SlotFlow owns cleanup")
    }
    SlotFlow { tag: tag, cleanup_owner: cleanup_owner }
}

fn slot_flow_from_tag(tag: Int) -> SlotFlow {
    make_slot_flow(tag, false)
}

pub fn slot_flow_unreachable() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_UNREACHABLE)
}

pub fn slot_flow_empty() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_EMPTY)
}


pub fn slot_flow_live_owner(cleanup_owner: Bool) -> SlotFlow {
    make_slot_flow(SLOT_FLOW_LIVE, cleanup_owner)
}

pub fn slot_flow_moved() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_MOVED)
}



pub fn slot_flow_tag(flow: SlotFlow) -> Int {
    make_slot_flow(flow.tag, flow.cleanup_owner).tag
}

pub fn slot_flow_cleanup_owner(flow: SlotFlow) -> Bool {
    make_slot_flow(flow.tag, flow.cleanup_owner).cleanup_owner
}

pub fn slot_flow_is_unreachable(flow: SlotFlow) -> Bool {
    slot_flow_tag(flow) == SLOT_FLOW_UNREACHABLE
}
pub fn slot_flow_is_empty(flow: SlotFlow) -> Bool {
    slot_flow_tag(flow) == SLOT_FLOW_EMPTY
}
pub fn slot_flow_is_live(flow: SlotFlow) -> Bool {
    slot_flow_tag(flow) == SLOT_FLOW_LIVE
}
pub fn slot_flow_is_moved(flow: SlotFlow) -> Bool {
    slot_flow_tag(flow) == SLOT_FLOW_MOVED
}
pub fn slot_flow_is_maybe_moved(flow: SlotFlow) -> Bool {
    slot_flow_tag(flow) == SLOT_FLOW_MAYBE_MOVED
}

pub fn copy_slot_flow(flow: SlotFlow) -> SlotFlow {
    make_slot_flow(slot_flow_tag(flow), slot_flow_cleanup_owner(flow))
}

pub fn slot_flow_same(left: SlotFlow, right: SlotFlow) -> Bool {
    slot_flow_tag(left) == slot_flow_tag(right) &&
        slot_flow_cleanup_owner(left) == slot_flow_cleanup_owner(right)
}

pub fn slot_flow_join(left: SlotFlow, right: SlotFlow) -> SlotFlow {
    let left_tag = slot_flow_tag(left)
    let right_tag = slot_flow_tag(right)
    let index = left_tag * SLOT_FLOW_COUNT + right_tag
    match SLOT_FLOW_JOIN_TAGS.get(index) {
        some(tag) => {
            let left_may_live = left_tag == SLOT_FLOW_LIVE ||
                left_tag == SLOT_FLOW_MAYBE_MOVED
            let right_may_live = right_tag == SLOT_FLOW_LIVE ||
                right_tag == SLOT_FLOW_MAYBE_MOVED
            if left_may_live && right_may_live &&
               slot_flow_cleanup_owner(left) !=
                    slot_flow_cleanup_owner(right) {
                panic("resource model: SlotFlow cleanup owner join differs")
            }
            make_slot_flow(tag,
                if left_may_live {
                    slot_flow_cleanup_owner(left)
                } else if right_may_live {
                    slot_flow_cleanup_owner(right)
                } else { false })
        },
        none => panic("resource model: SlotFlow join table is incomplete")
    }
}
