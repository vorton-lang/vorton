// Frozen resource facts and the exact type/callable least fixed point.
// Exact generic facts are closed only over frozen resource-child edges; ranked
// cells then carry both that derivation and the logical/physical shape solve.

use ir_identity::{
    core_type_ref_index, SlotRef, slot_ref_same, symbol_ref_same}
use ir_inventory::{ExecutableRef, executable_ref_same}
use core_type_source::{
    FlowGenericParamFact, make_flow_generic_param_fact,
    flow_generic_param_owner, flow_generic_param_index,
    flow_generic_param_arity, flow_generic_param_bounds}
use flow_ir::{
    FlowProjectionContract, FlowPlaceRef, FlowSemanticStepRef,
    flow_semantic_step_same,
    flow_semantic_step_is_instruction,
    flow_place_is_slot, flow_place_slot, flow_place_base,
    flow_place_projection, flow_place_value_type,
    make_flow_slot_place, make_flow_project_place,
    make_flow_instruction_ref, make_flow_block_ref,
    copy_flow_projection_contract, flow_projection_contract_same,
    flow_projection_contract_base_type,
    flow_projection_contract_result_type}
use resource_model::{
    TransferDemand, LogicalOwnershipShape, PhysicalRcShape, SlotFlow,
    param_mode_from_tag, param_mode_tag, param_mode_same,
    param_mode_bottom, param_mode_borrow, param_mode_mut_borrow,
    param_mode_own,
    make_transfer_demand, transfer_demand_mode, transfer_demand_force,
    transfer_demand_join, transfer_demand_leq,
    make_logical_ownership_shape,
    make_physical_rc_shape, slot_flow_tag, slot_flow_same}
use resource_certificate::{
    ResourceCellKind, ResourceCellSource, ResourceRuleSource,
    ResourceCellSpec, ResourceConstraint, ResourcePromotion,
    ResourceFixedPointProof, CallableCandidateProof,
    make_resource_cell_spec, make_resource_cell_spec_with_source,
    make_resource_constraint, make_resource_constraint_at,
    make_resource_all_constraint_at,
    make_callable_result_owned_source, make_callable_result_origin_source,
    make_body_reach_source, make_body_slot_origin_source,
    make_body_slot_owned_source, make_body_slot_mode_source,
    make_body_slot_force_source, make_callable_resource_rule_source,
    make_instruction_resource_rule_source, make_block_resource_rule_source,
    make_edge_resource_rule_source, make_resource_promotion,
    make_resource_fixed_point_proof,
    resource_cell_kind_logical_shape,
    resource_cell_kind_physical_shape,
    resource_cell_kind_callable_param_mode,
    resource_cell_kind_callable_force,
    resource_cell_kind_callable_result,
    resource_cell_kind_callable_result_origin,
    resource_cell_kind_body_slot_origin,
    resource_cell_kind_body_slot_owned,
    resource_cell_kind_body_block_reachable,
    resource_cell_kind_body_slot_mode,
    resource_cell_kind_body_slot_force,
    resource_cell_spec_max_rank, resource_constraint_target_cell,
    resource_constraint_floor_rank, resource_constraint_premise_cells,
    resource_constraint_requires_all, resource_constraint_guard_cell,
    make_resource_guarded_constraint_at,
    resource_fixed_point_final_ranks}

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
const PLANNER_TYPE_KIND_COUNT: Int = 8

pub struct PlannerTypeKind { tag: Int }

fn planner_type_kind_from_tag(tag: Int) -> PlannerTypeKind {
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
fn planner_type_kind_tag(kind: PlannerTypeKind) -> Int {
    planner_type_kind_from_tag(kind.tag).tag
}

fn copy_planner_generic_param_fact(
    value: FlowGenericParamFact
) -> FlowGenericParamFact {
    make_flow_generic_param_fact(
        flow_generic_param_owner(value), flow_generic_param_index(value),
        flow_generic_param_arity(value), flow_generic_param_bounds(value))
}

fn planner_generic_param_fact_same(
    left: FlowGenericParamFact, right: FlowGenericParamFact
) -> Bool {
    if !symbol_ref_same(
            flow_generic_param_owner(left),
            flow_generic_param_owner(right)) ||
       flow_generic_param_index(left) != flow_generic_param_index(right) ||
       flow_generic_param_arity(left) != flow_generic_param_arity(right) {
        return false
    }
    let left_bounds = flow_generic_param_bounds(left)
    let right_bounds = flow_generic_param_bounds(right)
    if left_bounds.len() != right_bounds.len() { return false }
    let mut index = 0
    while index < left_bounds.len() {
        if !symbol_ref_same(
                left_bounds.get(index).unwrap(),
                right_bounds.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}

fn planner_generic_param_facts_contain(
    values: List<FlowGenericParamFact>, target: FlowGenericParamFact
) -> Bool {
    values.any(fn(value) {
        planner_generic_param_fact_same(value, target)
    })
}

fn planner_generic_param_fact_index(
    values: List<FlowGenericParamFact>, target: FlowGenericParamFact
) -> Int {
    let mut index = 0
    while index < values.len() {
        if planner_generic_param_fact_same(
                values.get(index).unwrap(), target) {
            return index
        }
        index = index + 1
    }
    panic("ResourcePlanner: exact resource dependency fact is absent")
}

fn append_planner_generic_param_fact(
    mut values: List<FlowGenericParamFact>, value: FlowGenericParamFact
) -> Bool {
    if planner_generic_param_facts_contain(values, value) { return false }
    values.push(copy_planner_generic_param_fact(value))
    true
}

fn copy_planner_generic_param_facts(
    values: List<FlowGenericParamFact>
) -> List<FlowGenericParamFact> {
    let mut result: List<FlowGenericParamFact> = []
    for value in values {
        if !append_planner_generic_param_fact(result, value) {
            panic("ResourcePlanner: duplicate exact resource dependency fact")
        }
    }
    result
}

pub struct PlannerTypeNode {
    pub kind: PlannerTypeKind,
    pub child_type_indices: List<Int>,
    pub resource_dependency_facts: List<FlowGenericParamFact>,
    pub parameter_fact: FlowGenericParamFact?,
    pub direct_drop_seed: Bool,
    pub may_unique_seed: Bool,
    pub physical_rc_seed: Bool,
    pub boxing_seed: Bool,
    pub drop_glue_seed: Bool,
    pub foreign_containment_seed: Bool
}

fn make_planner_type_node_with_dependencies(
    kind: PlannerTypeKind, child_type_indices: List<Int>,
    resource_dependency_facts: List<FlowGenericParamFact>,
    parameter_fact: FlowGenericParamFact?,
    direct_drop_seed: Bool, may_unique_seed: Bool,
    physical_rc_seed: Bool, boxing_seed: Bool,
    drop_glue_seed: Bool, foreign_containment_seed: Bool
) -> PlannerTypeNode {
    if direct_drop_seed && !may_unique_seed {
        panic("ResourcePlanner: direct Drop type is not unique-capable")
    }
    let is_parameter = planner_type_kind_tag(kind) == PLANNER_TYPE_PARAMETER
    match parameter_fact {
        some(_) => if !is_parameter {
            panic("ResourcePlanner: non-parameter type has a generic fact")
        },
        none => if is_parameter {
            panic("ResourcePlanner: type-parameter node lacks exact fact")
        }
    }
    if (planner_type_kind_tag(kind) == PLANNER_TYPE_ATOMIC ||
        planner_type_kind_tag(kind) == PLANNER_TYPE_PTR ||
        planner_type_kind_tag(kind) == PLANNER_TYPE_EXTERN ||
        planner_type_kind_tag(kind) == PLANNER_TYPE_CALLABLE ||
        planner_type_kind_tag(kind) == PLANNER_TYPE_PARAMETER) &&
       child_type_indices.len() != 0 {
        panic("ResourcePlanner: leaf type has child edges")
    }
    let mut children: List<Int> = []
    for child in child_type_indices {
        if child < 0 { panic("ResourcePlanner: negative type edge") }
        children.push(child)
    }
    let dependencies = copy_planner_generic_param_facts(
        resource_dependency_facts)
    match parameter_fact {
        some(parameter) => {
            if dependencies.len() != 1 ||
               !planner_generic_param_fact_same(
                    dependencies.get(0).unwrap(), parameter) {
                panic("ResourcePlanner: parameter dependency seed is not exact")
            }
        },
        none => if (planner_type_kind_tag(kind) == PLANNER_TYPE_ATOMIC ||
                    planner_type_kind_tag(kind) == PLANNER_TYPE_PTR ||
                    planner_type_kind_tag(kind) == PLANNER_TYPE_EXTERN ||
                    planner_type_kind_tag(kind) == PLANNER_TYPE_CALLABLE) &&
                   dependencies.len() != 0 {
            panic("ResourcePlanner: resource leaf has dependency facts")
        }
    }
    PlannerTypeNode {
        kind: kind,
        child_type_indices: children,
        resource_dependency_facts: dependencies,
        parameter_fact: match parameter_fact {
            some(parameter) => some(copy_planner_generic_param_fact(parameter)),
            none => none
        },
        direct_drop_seed: direct_drop_seed,
        may_unique_seed: may_unique_seed,
        physical_rc_seed: physical_rc_seed,
        boxing_seed: boxing_seed,
        drop_glue_seed: drop_glue_seed,
        foreign_containment_seed: foreign_containment_seed
    }
}

pub fn make_planner_type_node(
    kind: PlannerTypeKind, child_type_indices: List<Int>,
    parameter_fact: FlowGenericParamFact?,
    direct_drop_seed: Bool, may_unique_seed: Bool,
    physical_rc_seed: Bool, boxing_seed: Bool,
    drop_glue_seed: Bool, foreign_containment_seed: Bool
) -> PlannerTypeNode {
    let mut dependencies: List<FlowGenericParamFact> = []
    match parameter_fact {
        some(parameter) => dependencies.push(
            copy_planner_generic_param_fact(parameter)),
        none => {}
    }
    make_planner_type_node_with_dependencies(
        kind, child_type_indices, dependencies, parameter_fact,
        direct_drop_seed, may_unique_seed, physical_rc_seed, boxing_seed,
        drop_glue_seed, foreign_containment_seed)
}

fn copy_planner_type_nodes(values: List<PlannerTypeNode>) -> List<PlannerTypeNode> {
    let mut result: List<PlannerTypeNode> = []
    for value in values {
        result.push(make_planner_type_node_with_dependencies(
            value.kind, value.child_type_indices,
            value.resource_dependency_facts, value.parameter_fact,
            value.direct_drop_seed, value.may_unique_seed,
            value.physical_rc_seed, value.boxing_seed,
            value.drop_glue_seed, value.foreign_containment_seed))
    }
    result
}

// ============================================================
// Frozen FlowIR adapter: callable graph
// ============================================================

pub struct PlannerCallable {
    pub reference: ExecutableRef,
    pub parameter_type_indices: List<Int>,
    pub result_type_index: Int,
    pub parameter_seeds: List<TransferDemand>,
    pub result_owned_seed: Bool,
    pub result_origin_parameter_ordinals: List<Int>,
    pub has_body: Bool
}

pub fn make_planner_callable(
    reference: ExecutableRef,
    parameter_type_indices: List<Int>, result_type_index: Int,
    parameter_seeds: List<TransferDemand>, result_owned_seed: Bool,
    result_origin_parameter_ordinals: List<Int>,
    has_body: Bool
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
    PlannerCallable {
        reference: reference,
        parameter_type_indices: parameter_types,
        result_type_index: result_type_index,
        parameter_seeds: seeds,
        result_owned_seed: result_owned_seed,
        result_origin_parameter_ordinals: result_origins,
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
            value.has_body))
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
    pub reference: SlotRef,
    pub type_index: Int,
    pub scope_id: Int,
    pub scope_depth: Int,
    pub reverse_lexical_ordinal: Int,
    pub parameter_ordinal: Int?,
    pub initially_live: Bool,
    pub owns_storage: Bool
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
        projection: FlowProjectionContract,
        value_type_index: Int
    }
}

pub struct PlannerPlace {
    value: PlannerPlaceValue,
    exact: FlowPlaceRef
}

pub fn make_planner_slot_place(
    slot: Int, exact: FlowPlaceRef
) -> PlannerPlace {
    if slot < 0 || !flow_place_is_slot(exact) {
        panic("ResourcePlanner: invalid exact slot place")
    }
    PlannerPlace {
        value: PlannerPlaceValue::SlotPlaceValue(slot),
        exact: make_flow_slot_place(flow_place_slot(exact))
    }
}

pub fn make_planner_project_place(
    base: Int, projection: FlowProjectionContract,
    value_type_index: Int, exact: FlowPlaceRef
) -> PlannerPlace {
    if base < 0 || value_type_index < 0 || flow_place_is_slot(exact) ||
       !flow_projection_contract_same(
            projection, flow_place_projection(exact)) ||
       value_type_index != core_type_ref_index(flow_place_value_type(exact)) {
        panic("ResourcePlanner: invalid projected place")
    }
    PlannerPlace {
        value: PlannerPlaceValue::ProjectPlaceValue {
            base: base,
            projection: copy_flow_projection_contract(projection),
            value_type_index: value_type_index
        },
        exact: make_flow_project_place(
            flow_place_base(exact), flow_place_projection(exact),
            flow_place_value_type(exact))
    }
}

fn copy_planner_place(value: PlannerPlace) -> PlannerPlace {
    match value.value {
        PlannerPlaceValue::SlotPlaceValue(slot) =>
            make_planner_slot_place(slot, value.exact),
        PlannerPlaceValue::ProjectPlaceValue {
            base, projection, value_type_index
        } => make_planner_project_place(
            base, projection, value_type_index, value.exact)
    }
}

pub fn planner_place_is_slot(value: PlannerPlace) -> Bool {
    match value.value {
        PlannerPlaceValue::SlotPlaceValue(_) => true,
        PlannerPlaceValue::ProjectPlaceValue { .. } => false
    }
}

pub fn planner_place_slot(value: PlannerPlace) -> Int {
    match value.value {
        PlannerPlaceValue::SlotPlaceValue(slot) => slot,
        _ => panic("ResourcePlanner: projected place has no target slot")
    }
}

pub fn planner_place_base(value: PlannerPlace) -> Int {
    match value.value {
        PlannerPlaceValue::ProjectPlaceValue { base, .. } => base,
        _ => panic("ResourcePlanner: slot place has no projection base")
    }
}

pub fn planner_place_projection(value: PlannerPlace) -> FlowProjectionContract {
    match value.value {
        PlannerPlaceValue::ProjectPlaceValue { projection, .. } => projection,
        _ => panic("ResourcePlanner: slot place has no projection")
    }
}

pub fn planner_place_value_type(value: PlannerPlace) -> Int {
    match value.value {
        PlannerPlaceValue::ProjectPlaceValue { value_type_index, .. } =>
            value_type_index,
        _ => panic("ResourcePlanner: slot place type comes from slot table")
    }
}

pub fn planner_place_exact(value: PlannerPlace) -> FlowPlaceRef {
    if planner_place_is_slot(value) {
        make_flow_slot_place(flow_place_slot(value.exact))
    } else {
        make_flow_project_place(
            flow_place_base(value.exact), flow_place_projection(value.exact),
            flow_place_value_type(value.exact))
    }
}

enum ResourceDiagnosticTargetValue {
    DiagnosticSlotValue(SlotRef),
    DiagnosticPlaceValue(PlannerPlace)
}

pub struct ResourceDiagnostic {
    target: ResourceDiagnosticTargetValue,
    step: FlowSemanticStepRef,
    operand_ordinal: Int,
    state: SlotFlow
}

pub fn make_slot_resource_diagnostic(
    step: FlowSemanticStepRef, operand_ordinal: Int,
    slot: SlotRef, state: SlotFlow
) -> ResourceDiagnostic {
    if operand_ordinal < 0 {
        panic("ResourcePlanner: negative diagnostic operand")
    }
    ResourceDiagnostic {
        target: ResourceDiagnosticTargetValue::DiagnosticSlotValue(slot),
        step: step, operand_ordinal: operand_ordinal, state: state
    }
}

pub fn make_place_resource_diagnostic(
    step: FlowSemanticStepRef, operand_ordinal: Int,
    place: PlannerPlace, state: SlotFlow
) -> ResourceDiagnostic {
    if operand_ordinal < 0 {
        panic("ResourcePlanner: negative diagnostic place operand")
    }
    ResourceDiagnostic {
        target: ResourceDiagnosticTargetValue::DiagnosticPlaceValue(
            copy_planner_place(place)),
        step: step, operand_ordinal: operand_ordinal, state: state
    }
}

pub fn resource_diagnostic_step(
    value: ResourceDiagnostic
) -> FlowSemanticStepRef { value.step }
pub fn resource_diagnostic_operand_ordinal(value: ResourceDiagnostic) -> Int {
    value.operand_ordinal
}
pub fn resource_diagnostic_is_place(value: ResourceDiagnostic) -> Bool {
    match value.target {
        ResourceDiagnosticTargetValue::DiagnosticPlaceValue(_) => true,
        _ => false
    }
}
pub fn resource_diagnostic_slot(value: ResourceDiagnostic) -> SlotRef {
    match value.target {
        ResourceDiagnosticTargetValue::DiagnosticSlotValue(slot) => slot,
        _ => panic("ResourcePlanner: diagnostic target is a place")
    }
}
pub fn resource_diagnostic_place(value: ResourceDiagnostic) -> PlannerPlace {
    match value.target {
        ResourceDiagnosticTargetValue::DiagnosticPlaceValue(place) =>
            copy_planner_place(place),
        _ => panic("ResourcePlanner: diagnostic target is a slot")
    }
}
pub fn resource_diagnostic_state(value: ResourceDiagnostic) -> SlotFlow {
    value.state
}
pub fn resource_diagnostic_state_kind(value: ResourceDiagnostic) -> Int {
    slot_flow_tag(value.state)
}

pub fn resource_diagnostic_same(
    left: ResourceDiagnostic, right: ResourceDiagnostic
) -> Bool {
    if !flow_semantic_step_same(left.step, right.step) ||
       left.operand_ordinal != right.operand_ordinal ||
       !slot_flow_same(left.state, right.state) {
        return false
    }
    match (left.target, right.target) {
        (ResourceDiagnosticTargetValue::DiagnosticSlotValue(a),
         ResourceDiagnosticTargetValue::DiagnosticSlotValue(b)) =>
            slot_ref_same(a, b),
        (ResourceDiagnosticTargetValue::DiagnosticPlaceValue(a),
         ResourceDiagnosticTargetValue::DiagnosticPlaceValue(b)) =>
            if planner_place_is_slot(a) && planner_place_is_slot(b) {
                slot_ref_same(
                    flow_place_slot(a.exact), flow_place_slot(b.exact))
            } else if !planner_place_is_slot(a) &&
                      !planner_place_is_slot(b) {
                slot_ref_same(
                    flow_place_base(a.exact), flow_place_base(b.exact)) &&
                    flow_projection_contract_same(
                        planner_place_projection(a),
                        planner_place_projection(b))
            } else { false },
        _ => false
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

pub fn planner_call_target_is_direct(value: PlannerCallTarget) -> Bool {
    match value.value {
        PlannerCallTargetValue::DirectCallTargetValue(_) => true,
        PlannerCallTargetValue::SlotCallTargetValue(_) => false
    }
}

pub fn planner_call_target_direct(value: PlannerCallTarget) -> Int {
    match value.value {
        PlannerCallTargetValue::DirectCallTargetValue(index) => index,
        _ => panic("ResourcePlanner: slot call target has no direct callable")
    }
}

pub fn planner_call_target_slot(value: PlannerCallTarget) -> Int {
    match value.value {
        PlannerCallTargetValue::SlotCallTargetValue(slot) => slot,
        _ => panic("ResourcePlanner: direct call target has no callable slot")
    }
}

pub struct PlannerOperand {
    pub step: FlowSemanticStepRef,
    pub ordinal: Int,
    pub slot: Int,
    pub reference: SlotRef,
    pub lower_bound: TransferDemand
}

pub fn make_planner_operand(
    step: FlowSemanticStepRef, ordinal: Int,
    slot: Int, reference: SlotRef, lower_bound: TransferDemand
) -> PlannerOperand {
    if ordinal < 0 || slot < 0 ||
       param_mode_same(
            transfer_demand_mode(lower_bound), param_mode_bottom()) {
        panic("ResourcePlanner: invalid exact operand")
    }
    PlannerOperand {
        step: step, ordinal: ordinal, slot: slot, reference: reference,
        lower_bound: make_transfer_demand(
            transfer_demand_mode(lower_bound),
            transfer_demand_force(lower_bound))
    }
}

fn copy_planner_operands(values: List<PlannerOperand>) -> List<PlannerOperand> {
    let mut result: List<PlannerOperand> = []
    for value in values {
        result.push(make_planner_operand(
            value.step, value.ordinal, value.slot,
            value.reference, value.lower_bound))
    }
    result
}

pub struct TransferDecision {
    pub step: FlowSemanticStepRef,
    pub operand_ordinal: Int,
    pub slot: Int,
    pub reference: SlotRef,
    pub demand: TransferDemand
}

pub fn make_transfer_decision(
    operand: PlannerOperand, demand: TransferDemand
) -> TransferDecision {
    let exact = transfer_demand_join(operand.lower_bound, demand)
    TransferDecision {
        step: operand.step,
        operand_ordinal: operand.ordinal,
        slot: operand.slot,
        reference: operand.reference,
        demand: make_transfer_demand(
            transfer_demand_mode(exact), transfer_demand_force(exact))
    }
}

fn copy_transfer_decisions(
    values: List<TransferDecision>
) -> List<TransferDecision> {
    let mut result: List<TransferDecision> = []
    for value in values {
        result.push(TransferDecision {
            step: value.step, operand_ordinal: value.operand_ordinal,
            slot: value.slot, reference: value.reference,
            demand: make_transfer_demand(
                transfer_demand_mode(value.demand),
                transfer_demand_force(value.demand))
        })
    }
    result
}

pub struct EventDecision {
    pub step: FlowSemanticStepRef,
    pub transfers: List<TransferDecision>,
    pub result_owned: Bool
}

pub fn make_event_decision(
    step: FlowSemanticStepRef,
    transfers: List<TransferDecision>, result_owned: Bool
) -> EventDecision {
    let copied = copy_transfer_decisions(transfers)
    let mut ordinal = 0
    for transfer in copied {
        if !flow_semantic_step_same(step, transfer.step) ||
           transfer.operand_ordinal < ordinal {
            panic("ResourcePlanner: event decision is not exact/stable")
        }
        ordinal = transfer.operand_ordinal + 1
    }
    EventDecision {
        step: step, transfers: copied, result_owned: result_owned
    }
}


pub enum PlannerEventValue {
    NoOpValue,
    ScopeExitValue(Int),
    InitializeValue {
        input_slots: List<Int>,
        input_demands: List<TransferDemand>,
        origin_input_ordinals: List<Int>,
        target: Int
    },
    ReadValue { source: Int, target: Int },
    MutateValue {
        target: Int,
        value: Int,
        value_demand: TransferDemand
    },
    ConsumeValue(Int, Bool, Int?),
    DiscardValue(Int),
    AssignValue { rhs_temp: Int, target: PlannerPlace },
    MovePlaceValue { source: PlannerPlace, target: Int },
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
        projection: FlowProjectionContract,
        value_type_index: Int,
        partial: Bool
    },
    CaptureValue {
        source: Int,
        target: Int,
        demand: TransferDemand
    }
}

enum PlannerCallableLocationValue {
    PlannerCallableSlotLocationValue(Int),
    PlannerCallableProjectionLocationValue {
        base: Int,
        projection: FlowProjectionContract
    }
}

pub struct PlannerCallableLocation { value: PlannerCallableLocationValue }

pub fn make_planner_callable_slot_location(slot: Int) -> PlannerCallableLocation {
    if slot < 0 { panic("ResourcePlanner: negative callable slot location") }
    PlannerCallableLocation {
        value: PlannerCallableLocationValue::PlannerCallableSlotLocationValue(
            slot)
    }
}

pub fn make_planner_callable_projection_location(
    base: Int, projection: FlowProjectionContract
) -> PlannerCallableLocation {
    if base < 0 { panic("ResourcePlanner: negative callable projection base") }
    PlannerCallableLocation {
        value:
            PlannerCallableLocationValue::PlannerCallableProjectionLocationValue {
                base: base,
                projection: copy_flow_projection_contract(projection)
            }
    }
}

pub fn planner_callable_location_is_slot(
    value: PlannerCallableLocation
) -> Bool {
    match value.value {
        PlannerCallableLocationValue::PlannerCallableSlotLocationValue(_) => true,
        PlannerCallableLocationValue::PlannerCallableProjectionLocationValue {
            ..
        } => false
    }
}

pub fn planner_callable_location_slot(value: PlannerCallableLocation) -> Int {
    match value.value {
        PlannerCallableLocationValue::PlannerCallableSlotLocationValue(slot) =>
            slot,
        _ => panic("ResourcePlanner: projected callable location has no slot")
    }
}

pub fn planner_callable_location_base(value: PlannerCallableLocation) -> Int {
    match value.value {
        PlannerCallableLocationValue::PlannerCallableProjectionLocationValue {
            base, ..
        } => base,
        _ => panic("ResourcePlanner: callable slot location has no base")
    }
}

fn planner_callable_location_projection(
    value: PlannerCallableLocation
) -> FlowProjectionContract {
    match value.value {
        PlannerCallableLocationValue::PlannerCallableProjectionLocationValue {
            projection, ..
        } => copy_flow_projection_contract(projection),
        _ => panic("ResourcePlanner: callable slot location has no projection")
    }
}

pub fn planner_callable_location_same(
    left: PlannerCallableLocation, right: PlannerCallableLocation
) -> Bool {
    match (left.value, right.value) {
        (PlannerCallableLocationValue::PlannerCallableSlotLocationValue(a),
         PlannerCallableLocationValue::PlannerCallableSlotLocationValue(b)) =>
            a == b,
        (PlannerCallableLocationValue::PlannerCallableProjectionLocationValue {
            base: a_base, projection: a_projection
         },
         PlannerCallableLocationValue::PlannerCallableProjectionLocationValue {
            base: b_base, projection: b_projection
         }) => a_base == b_base && flow_projection_contract_same(
            a_projection, b_projection),
        _ => false
    }
}

pub fn copy_planner_callable_location(
    value: PlannerCallableLocation
) -> PlannerCallableLocation {
    if planner_callable_location_is_slot(value) {
        make_planner_callable_slot_location(
            planner_callable_location_slot(value))
    } else {
        make_planner_callable_projection_location(
            planner_callable_location_base(value),
            planner_callable_location_projection(value))
    }
}

pub enum PlannerCallableOriginValue {
    DirectCallableOriginValue(Int),
    LocationCallableOriginValue(List<PlannerCallableLocation>),
    CallCallableOriginValue {
        target: PlannerCallTarget,
        arguments: List<Int>
    }
}

pub struct PlannerCallableProvenance {
    pub target: PlannerCallableLocation,
    pub origin: PlannerCallableOriginValue
}

pub fn make_direct_planner_callable_provenance(
    target: PlannerCallableLocation, callable: Int
) -> PlannerCallableProvenance {
    if callable < 0 {
        panic("ResourcePlanner: negative direct callable provenance")
    }
    PlannerCallableProvenance {
        target: copy_planner_callable_location(target),
        origin: PlannerCallableOriginValue::DirectCallableOriginValue(callable)
    }
}

pub fn make_locations_planner_callable_provenance(
    target: PlannerCallableLocation,
    sources: List<PlannerCallableLocation>
) -> PlannerCallableProvenance {
    if sources.len() == 0 {
        panic("ResourcePlanner: callable slot provenance is empty")
    }
    let mut copied: List<PlannerCallableLocation> = []
    for source in sources {
        if copied.any(fn(existing) {
                planner_callable_location_same(existing, source)
            }) {
            panic("ResourcePlanner: callable location provenance is invalid")
        }
        copied.push(copy_planner_callable_location(source))
    }
    PlannerCallableProvenance {
        target: copy_planner_callable_location(target),
        origin: PlannerCallableOriginValue::LocationCallableOriginValue(copied)
    }
}

pub fn make_call_planner_callable_provenance(
    target: PlannerCallableLocation,
    call_target: PlannerCallTarget, arguments: List<Int>
) -> PlannerCallableProvenance {
    let mut copied: List<Int> = []
    for argument in arguments {
        if argument < 0 { panic("ResourcePlanner: negative provenance argument") }
        copied.push(argument)
    }
    PlannerCallableProvenance {
        target: copy_planner_callable_location(target),
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
            PlannerCallableOriginValue::LocationCallableOriginValue(sources) =>
                result.push(make_locations_planner_callable_provenance(
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
    pub step: FlowSemanticStepRef,
    pub operands: List<PlannerOperand>,
    pub decision: EventDecision,
    pub value: PlannerEventValue,
    pub callable_provenance: List<PlannerCallableProvenance>
}

fn make_planner_event(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>,
    value: PlannerEventValue
) -> PlannerEvent {
    let copied_operands = copy_planner_operands(operands)
    let mut ordinal = 0
    for operand in copied_operands {
        if !flow_semantic_step_same(step, operand.step) ||
           operand.ordinal != ordinal {
            panic("ResourcePlanner: event operands are not exact/stable")
        }
        ordinal = ordinal + 1
    }
    PlannerEvent {
        step: step, operands: copied_operands,
        decision: make_event_decision(step, [], false),
        value: value, callable_provenance: []
    }
}

pub fn with_planner_callable_provenance(
    value: PlannerEvent, provenance: List<PlannerCallableProvenance>
) -> PlannerEvent {
    PlannerEvent {
        step: value.step, operands: copy_planner_operands(value.operands),
        decision: make_event_decision(
            value.decision.step, value.decision.transfers,
            value.decision.result_owned),
        value: value.value,
        callable_provenance: copy_planner_callable_provenance(provenance)
    }
}

pub fn with_planner_event_decision(
    value: PlannerEvent, decision: EventDecision
) -> PlannerEvent {
    if !flow_semantic_step_same(value.step, decision.step) {
        panic("ResourcePlanner: event decision belongs to another step")
    }
    PlannerEvent {
        step: value.step, operands: copy_planner_operands(value.operands),
        decision: make_event_decision(
            decision.step, decision.transfers, decision.result_owned),
        value: value.value,
        callable_provenance:
            copy_planner_callable_provenance(value.callable_provenance)
    }
}

pub fn planner_event_operand(
    event: PlannerEvent, ordinal: Int
) -> PlannerOperand {
    if ordinal < 0 || ordinal >= event.operands.len() {
        panic("ResourcePlanner: event operand ordinal is absent")
    }
    let operand = event.operands.get(ordinal).unwrap()
    if operand.ordinal != ordinal ||
       !flow_semantic_step_same(event.step, operand.step) {
        panic("ResourcePlanner: event operand identity drifted")
    }
    operand
}

pub fn event_decision_transfer(
    decision: EventDecision, ordinal: Int
) -> TransferDecision {
    for transfer in decision.transfers {
        if transfer.operand_ordinal == ordinal { return transfer }
    }
    panic("ResourcePlanner: event transfer decision is absent")
}

pub fn make_planner_noop(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>
) -> PlannerEvent {
    make_planner_event(step, operands, PlannerEventValue::NoOpValue)
}

pub fn make_planner_scope_exit(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>, scope_id: Int
) -> PlannerEvent {
    if scope_id < 0 { panic("ResourcePlanner: negative lexical scope exit") }
    make_planner_event(
        step, operands, PlannerEventValue::ScopeExitValue(scope_id))
}

pub fn make_planner_initialize(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>,
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
    make_planner_event(step, operands, PlannerEventValue::InitializeValue {
            input_slots: slots, input_demands: demands,
            origin_input_ordinals: origins, target: target
        })
}

pub fn make_planner_read(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>,
    source: Int, target: Int
) -> PlannerEvent {
    make_planner_event(step, operands, PlannerEventValue::ReadValue {
            source: source, target: target
        })
}
pub fn make_planner_mutate(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>,
    target: Int, value: Int, value_demand: TransferDemand
) -> PlannerEvent {
    make_planner_event(step, operands, PlannerEventValue::MutateValue {
            target: target, value: value,
            value_demand: make_transfer_demand(
                transfer_demand_mode(value_demand),
                transfer_demand_force(value_demand))
        })
}
pub fn make_planner_consume(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>,
    slot: Int, force: Bool, target: Int?
) -> PlannerEvent {
    match target {
        some(value) => if value < 0 || value == slot {
            panic("ResourcePlanner: Consume target is invalid")
        },
        none => {}
    }
    make_planner_event(
        step, operands, PlannerEventValue::ConsumeValue(slot, force, target))
}
pub fn make_planner_discard(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>, slot: Int
) -> PlannerEvent {
    make_planner_event(step, operands, PlannerEventValue::DiscardValue(slot))
}
pub fn make_planner_assign(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>,
    rhs_temp: Int, target: PlannerPlace
) -> PlannerEvent {
    if rhs_temp < 0 ||
       (planner_place_is_slot(target) &&
        rhs_temp == planner_place_slot(target)) {
        panic("ResourcePlanner: Assign RHS aliases target place")
    }
    make_planner_event(step, operands, PlannerEventValue::AssignValue {
        rhs_temp: rhs_temp, target: copy_planner_place(target)
    })
}
pub fn make_planner_move_place(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>,
    source: PlannerPlace, target: Int
) -> PlannerEvent {
    make_planner_event(step, operands, PlannerEventValue::MovePlaceValue {
        source: copy_planner_place(source), target: target
    })
}
pub fn make_planner_call(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>,
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
    make_planner_event(step, operands, PlannerEventValue::CallValue {
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
    step: FlowSemanticStepRef, operands: List<PlannerOperand>,
    source: Int, target: Int, projection: FlowProjectionContract,
    value_type_index: Int, partial: Bool
) -> PlannerEvent {
    make_planner_event(step, operands, PlannerEventValue::ProjectValue {
            source: source, target: target,
            projection: copy_flow_projection_contract(projection),
            value_type_index: value_type_index, partial: partial
        })
}
pub fn make_planner_capture(
    step: FlowSemanticStepRef, operands: List<PlannerOperand>,
    source: Int, target: Int, demand: TransferDemand
) -> PlannerEvent {
    make_planner_event(step, operands, PlannerEventValue::CaptureValue {
            source: source,
            target: target,
            demand: make_transfer_demand(
                transfer_demand_mode(demand),
                transfer_demand_force(demand))
        })
}

pub fn copy_planner_event(value: PlannerEvent) -> PlannerEvent {
    let copied = match value.value {
        PlannerEventValue::NoOpValue =>
            make_planner_noop(value.step, value.operands),
        PlannerEventValue::ScopeExitValue(scope_id) =>
            make_planner_scope_exit(value.step, value.operands, scope_id),
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, origin_input_ordinals, target
        } => make_planner_initialize(
            value.step, value.operands, input_slots, input_demands,
            origin_input_ordinals, target),
        PlannerEventValue::ReadValue { source, target } =>
            make_planner_read(value.step, value.operands, source, target),
        PlannerEventValue::MutateValue {
            target, value: input, value_demand
        } => make_planner_mutate(
            value.step, value.operands, target, input, value_demand),
        PlannerEventValue::ConsumeValue(slot, force, target) =>
            make_planner_consume(
                value.step, value.operands, slot, force, target),
        PlannerEventValue::DiscardValue(slot) =>
            make_planner_discard(value.step, value.operands, slot),
        PlannerEventValue::AssignValue { rhs_temp, target } =>
            make_planner_assign(
                value.step, value.operands, rhs_temp, target),
        PlannerEventValue::MovePlaceValue { source, target } =>
            make_planner_move_place(
                value.step, value.operands, source, target),
        PlannerEventValue::CallValue {
            call_target, callable_indices, argument_demands,
            result_owned, result_type_index,
            result_origin_argument_ordinals,
            argument_slots, result_slot
        } => make_planner_call(
            value.step, value.operands, call_target, callable_indices,
            argument_slots, argument_demands,
            result_owned, result_type_index,
            result_origin_argument_ordinals, result_slot),
        PlannerEventValue::ProjectValue {
            source, target, projection, value_type_index, partial
        } => make_planner_project(
            value.step, value.operands, source, target,
            projection, value_type_index, partial),
        PlannerEventValue::CaptureValue { source, target, demand } =>
            make_planner_capture(
                value.step, value.operands, source, target, demand)
    }
    with_planner_event_decision(
        with_planner_callable_provenance(
            copied, value.callable_provenance),
        value.decision)
}

pub struct PlannerEdge {
    pub target_block: Int?,
    pub exited_scope_ids: List<Int>,
    pub fresh_result_slots: List<Int>
}

pub fn make_planner_edge(
    target_block: Int?, exited_scope_ids: List<Int>,
    fresh_result_slots: List<Int>
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
    let mut results: List<Int> = []
    for slot in fresh_result_slots {
        if slot < 0 || int_list_contains(results, slot) {
            panic("ResourcePlanner: invalid fresh edge result")
        }
        results.push(slot)
    }
    if target_block.is_none() && results.len() != 0 {
        panic("ResourcePlanner: terminal edge has fresh results")
    }
    PlannerEdge {
        target_block: target_block, exited_scope_ids: scopes,
        fresh_result_slots: results
    }
}

pub struct PlannerTerminatorUse {
    pub step: FlowSemanticStepRef,
    pub operand_ordinal: Int,
    pub slot: Int,
    pub reference: SlotRef,
    pub demand: TransferDemand
}

pub fn make_planner_terminator_use(
    step: FlowSemanticStepRef, operand_ordinal: Int,
    slot: Int, reference: SlotRef, demand: TransferDemand
) -> PlannerTerminatorUse {
    if operand_ordinal < 0 || slot < 0 {
        panic("ResourcePlanner: invalid terminator value edge")
    }
    PlannerTerminatorUse {
        step: step, operand_ordinal: operand_ordinal,
        slot: slot, reference: reference,
        demand: make_transfer_demand(
            transfer_demand_mode(demand), transfer_demand_force(demand))
    }
}

pub struct PlannerBlock {
    pub terminator_kind: Int,
    pub events: List<PlannerEvent>,
    pub terminator_uses: List<PlannerTerminatorUse>,
    pub edges: List<PlannerEdge>
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
            usage.step, usage.operand_ordinal,
            usage.slot, usage.reference, usage.demand))
    }
    for edge in edges {
        copied_edges.push(make_planner_edge(
            edge.target_block, edge.exited_scope_ids,
            edge.fresh_result_slots))
    }
    PlannerBlock {
        terminator_kind: terminator_kind,
        events: copied_events,
        terminator_uses: copied_uses,
        edges: copied_edges
    }
}

pub struct PlannerBody {
    pub reference: ExecutableRef,
    pub scopes: List<PlannerScope>,
    pub slots: List<PlannerSlot>,
    pub entry_block: Int,
    pub blocks: List<PlannerBlock>
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

// Structural reachability is a frozen-CFG fact, not an ownership solution.
// Candidate provenance, validation, and certificate checks share this one
// entry/edge walk so a dead Flow block cannot contribute semantic facts.
pub fn planner_body_reachable_blocks(body: PlannerBody) -> List<Bool> {
    if body.blocks.len() == 0 || body.entry_block < 0 ||
       body.entry_block >= body.blocks.len() {
        panic("ResourcePlanner: body lacks a valid frozen entry block")
    }
    let mut reachable: List<Bool> = []
    for _ in body.blocks { reachable.push(false) }
    reachable.set(body.entry_block, true)
    let mut changed = true
    while changed {
        changed = false
        let mut block_index = 0
        while block_index < body.blocks.len() {
            if reachable.get(block_index).unwrap() {
                for edge in body.blocks.get(block_index).unwrap().edges {
                    match edge.target_block {
                        some(target) => {
                            if target < 0 || target >= body.blocks.len() {
                                panic("ResourcePlanner: edge target is outside frozen CFG")
                            }
                            if !reachable.get(target).unwrap() {
                                reachable.set(target, true)
                                changed = true
                            }
                        },
                        none => {}
                    }
                }
            }
            block_index = block_index + 1
        }
    }
    reachable
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
    pub flow_fingerprint: Str,
    pub candidate_proof: CallableCandidateProof,
    pub type_nodes: List<PlannerTypeNode>,
    pub callables: List<PlannerCallable>,
    pub bodies: List<PlannerBody>
}

fn validate_slot_index(index: Int, slots: List<PlannerSlot>) {
    if index < 0 || index >= slots.len() {
        panic("ResourcePlanner: event slot is outside frozen binder set")
    }
}

fn validate_event(
    event: PlannerEvent, slots: List<PlannerSlot>,
    scopes: List<PlannerScope>, callables: List<PlannerCallable>,
    type_nodes: List<PlannerTypeNode>, block_reachable: Bool
) {
    if !flow_semantic_step_same(event.step, event.decision.step) {
        panic("ResourcePlanner: event/decision step differs")
    }
    let mut exact_ordinal = 0
    for operand in event.operands {
        if operand.ordinal != exact_ordinal ||
           !flow_semantic_step_same(event.step, operand.step) {
            panic("ResourcePlanner: event operand order differs")
        }
        validate_slot_index(operand.slot, slots)
        if !slot_ref_same(
                operand.reference,
                slots.get(operand.slot).unwrap().reference) {
            panic("ResourcePlanner: event operand slot identity differs")
        }
        exact_ordinal = exact_ordinal + 1
    }
    for transfer in event.decision.transfers {
        let operand = planner_event_operand(event, transfer.operand_ordinal)
        if transfer.slot != operand.slot ||
           !slot_ref_same(transfer.reference, operand.reference) ||
           !transfer_demand_leq(operand.lower_bound, transfer.demand) {
            panic("ResourcePlanner: event transfer decision differs")
        }
    }
    for fact in event.callable_provenance {
        if planner_callable_location_is_slot(fact.target) {
            let target = planner_callable_location_slot(fact.target)
            validate_slot_index(target, slots)
            if !planner_type_is_callable(
                    type_nodes, slots.get(target).unwrap().type_index) {
                panic("ResourcePlanner: callable provenance targets non-callable slot")
            }
        } else {
            let base = planner_callable_location_base(fact.target)
            let projection = planner_callable_location_projection(fact.target)
            validate_slot_index(base, slots)
            if slots.get(base).unwrap().type_index !=
                   core_type_ref_index(
                       flow_projection_contract_base_type(projection)) ||
               !planner_type_is_callable(
                    type_nodes, core_type_ref_index(
                        flow_projection_contract_result_type(projection))) {
                panic("ResourcePlanner: callable projection location type differs")
            }
        }
        match fact.origin {
            PlannerCallableOriginValue::DirectCallableOriginValue(callable) =>
                if callable < 0 || callable >= callables.len() {
                    panic("ResourcePlanner: direct callable provenance is absent")
                },
            PlannerCallableOriginValue::LocationCallableOriginValue(sources) =>
                { for source in sources {
                    if planner_callable_location_is_slot(source) {
                        validate_slot_index(
                            planner_callable_location_slot(source), slots)
                    } else {
                        validate_slot_index(
                            planner_callable_location_base(source), slots)
                    }
                } },
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
                   !flow_place_is_slot(target.exact) ||
                   !slot_ref_same(
                        flow_place_slot(target.exact),
                        slots.get(target_slot).unwrap().reference) ||
                   !slots.get(target_slot).unwrap().owns_storage ||
                   slots.get(rhs_temp).unwrap().type_index !=
                        slots.get(target_slot).unwrap().type_index {
                    panic("ResourcePlanner: direct Assign place contract differs")
                }
            } else {
                let base = planner_place_base(target)
                validate_slot_index(base, slots)
                let value_type = planner_place_value_type(target)
                if flow_place_is_slot(target.exact) ||
                   !slot_ref_same(
                        flow_place_base(target.exact),
                        slots.get(base).unwrap().reference) ||
                   value_type != core_type_ref_index(
                        flow_place_value_type(target.exact)) ||
                   value_type < 0 || value_type >= type_nodes.len() ||
                   slots.get(rhs_temp).unwrap().type_index != value_type {
                    panic("ResourcePlanner: projected Assign value type differs")
                }
            }
        },
        PlannerEventValue::MovePlaceValue { source, target } => {
            let source_slot = if planner_place_is_slot(source) {
                planner_place_slot(source)
            } else { planner_place_base(source) }
            validate_slot_index(source_slot, slots)
            validate_slot_index(target, slots)
            if source_slot == target ||
               slots.get(target).unwrap().type_index !=
                    if planner_place_is_slot(source) {
                        slots.get(source_slot).unwrap().type_index
                    } else { planner_place_value_type(source) } {
                panic("ResourcePlanner: MovePlace source/target differs")
            }
        },
        PlannerEventValue::CallValue {
            call_target, callable_indices, argument_demands,
            result_owned, result_type_index,
            argument_slots, result_slot, ..
        } => {
            if argument_slots.len() != argument_demands.len() ||
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
                if block_reachable && callable_indices.len() == 0 {
                    panic("ResourcePlanner: reachable call lacks exact candidates")
                }
                if !block_reachable && callable_indices.len() != 0 {
                    panic("ResourcePlanner: unreachable call retained candidates")
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
                    if !transfer_demand_leq(
                            argument_demands.get(argument).unwrap(),
                            candidate.parameter_seeds.get(argument).unwrap()) {
                        panic("ResourcePlanner: derived callable contract differs")
                    }
                    argument = argument + 1
                }
                if result_type_index != candidate.result_type_index ||
                   (result_owned && !candidate.result_owned_seed) {
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
            source, target, projection, value_type_index, ..
        } => {
            validate_slot_index(source, slots)
            validate_slot_index(target, slots)
            if source == target ||
               slots.get(target).unwrap().type_index != value_type_index ||
               core_type_ref_index(
                    flow_projection_contract_result_type(projection)) !=
                    value_type_index ||
               core_type_ref_index(
                    flow_projection_contract_base_type(projection)) !=
                    slots.get(source).unwrap().type_index {
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

fn validate_raise_planner_block(body: PlannerBody, block: PlannerBlock) {
    if block.terminator_kind != 11 { return }
    if block.events.len() < 2 || block.terminator_uses.len() != 1 ||
       block.edges.len() != 1 {
        panic("ResourcePlanner: Raise contract census differs")
    }
    let consume = block.events.get(block.events.len() - 2).unwrap()
    let moved = block.events.get(block.events.len() - 1).unwrap()
    let (failure_sink, caught_error) = match (consume.value, moved.value) {
        (PlannerEventValue::ConsumeValue(_, true, some(sink)),
         PlannerEventValue::MovePlaceValue { source, target }) => {
            if !planner_place_is_slot(source) ||
               planner_place_slot(source) != sink {
                panic("ResourcePlanner: Raise failure sink transfer differs")
            }
            (sink, target)
        },
        _ => panic("ResourcePlanner: Raise event sequence differs")
    }
    let usage = block.terminator_uses.get(0).unwrap()
    let edge = block.edges.get(0).unwrap()
    if usage.slot != caught_error || edge.target_block.is_none() ||
       !param_mode_same(
            transfer_demand_mode(usage.demand), param_mode_borrow()) ||
       transfer_demand_force(usage.demand) ||
       !body.slots.get(caught_error).unwrap().owns_storage ||
       body.slots.get(caught_error).unwrap().initially_live ||
       !int_list_contains(
            edge.exited_scope_ids,
            body.slots.get(failure_sink).unwrap().scope_id) ||
       int_list_contains(
            edge.exited_scope_ids,
            body.slots.get(caught_error).unwrap().scope_id) {
        panic("ResourcePlanner: Raise state/cleanup boundary differs")
    }
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
    let reachable = planner_body_reachable_blocks(body)
    let mut block_index = 0
    while block_index < body.blocks.len() {
        let block = body.blocks.get(block_index).unwrap()
        for event in block.events {
            validate_event(
                event, body.slots, body.scopes, callables, type_nodes,
                reachable.get(block_index).unwrap())
        }
        validate_raise_planner_block(body, block)
        let mut terminator_ordinal = 0
        for usage in block.terminator_uses {
            validate_slot_index(usage.slot, body.slots)
            if flow_semantic_step_is_instruction(usage.step) ||
               usage.operand_ordinal != terminator_ordinal ||
               !slot_ref_same(
                    usage.reference,
                    body.slots.get(usage.slot).unwrap().reference) ||
               param_mode_same(
                    transfer_demand_mode(usage.demand),
                    param_mode_bottom()) {
                panic("ResourcePlanner: terminator exact use differs")
            }
            terminator_ordinal = terminator_ordinal + 1
        }
        let mut previous_depth: Int? = none
        if block.terminator_kind == 11 && block.edges.len() != 1 {
            panic("ResourcePlanner: Raise successor census differs")
        }
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
            for result_slot in edge.fresh_result_slots {
                validate_slot_index(result_slot, body.slots)
                if body.slots.get(result_slot).unwrap().initially_live {
                    panic("ResourcePlanner: fresh edge result is already live")
                }
                if int_list_contains(
                        edge.exited_scope_ids,
                        body.slots.get(result_slot).unwrap().scope_id) {
                    panic("ResourcePlanner: fresh edge result exits its scope")
                }
            }
            if edge.fresh_result_slots.len() != 0 {
                panic("ResourcePlanner: terminator edge result census differs")
            }
        }
        block_index = block_index + 1
    }
}

fn planner_parameter_owner_same(
    left: FlowGenericParamFact, right: FlowGenericParamFact
) -> Bool {
    symbol_ref_same(
        flow_generic_param_owner(left), flow_generic_param_owner(right)) &&
        flow_generic_param_arity(left) == flow_generic_param_arity(right)
}

fn planner_exact_parameter_universe(
    values: List<PlannerTypeNode>
) -> List<FlowGenericParamFact> {
    let mut owners: List<FlowGenericParamFact> = []
    for node in values {
        match node.parameter_fact {
            some(parameter) => if !owners.any(fn(owner) {
                    planner_parameter_owner_same(owner, parameter)
                }) {
                owners.push(copy_planner_generic_param_fact(parameter))
            },
            none => {}
        }
    }
    let mut result: List<FlowGenericParamFact> = []
    for owner in owners {
        let mut ordinal = 0
        while ordinal < flow_generic_param_arity(owner) {
            for node in values {
                match node.parameter_fact {
                    some(parameter) => if planner_parameter_owner_same(
                            owner, parameter) &&
                           flow_generic_param_index(parameter) == ordinal {
                        let _ = append_planner_generic_param_fact(
                            result, parameter)
                    },
                    none => {}
                }
            }
            ordinal = ordinal + 1
        }
    }
    result
}

fn close_planner_type_dependencies(
    values: List<PlannerTypeNode>
) -> List<PlannerTypeNode> {
    let exact_facts = planner_exact_parameter_universe(values)
    let mut dependencies: List<List<FlowGenericParamFact>> = []
    let mut queued: List<Bool> = []
    let mut worklist: List<Int> = []
    let mut index = 0
    while index < values.len() {
        let node = values.get(index).unwrap()
        let mut seeds: List<FlowGenericParamFact> = []
        match node.parameter_fact {
            some(parameter) => {
                let _ = append_planner_generic_param_fact(seeds, parameter)
                worklist.push(index)
                queued.push(true)
            },
            none => queued.push(false)
        }
        dependencies.push(seeds)
        index = index + 1
    }
    let mut cursor = 0
    while cursor < worklist.len() {
        let child_index = worklist.get(cursor).unwrap()
        cursor = cursor + 1
        queued.set(child_index, false)
        let child_facts = dependencies.get(child_index).unwrap()
        let mut parent_index = 0
        while parent_index < values.len() {
            let parent = values.get(parent_index).unwrap()
            if int_list_contains(parent.child_type_indices, child_index) {
                let mut parent_facts = dependencies.get(parent_index).unwrap()
                let mut changed = false
                for fact in child_facts {
                    if append_planner_generic_param_fact(parent_facts, fact) {
                        changed = true
                    }
                }
                dependencies.set(parent_index, parent_facts)
                if changed && !queued.get(parent_index).unwrap() {
                    queued.set(parent_index, true)
                    worklist.push(parent_index)
                }
            }
            parent_index = parent_index + 1
        }
    }
    let mut result: List<PlannerTypeNode> = []
    index = 0
    while index < values.len() {
        let node = values.get(index).unwrap()
        let discovered = dependencies.get(index).unwrap()
        let mut canonical: List<FlowGenericParamFact> = []
        for fact in exact_facts {
            if planner_generic_param_facts_contain(discovered, fact) {
                canonical.push(copy_planner_generic_param_fact(fact))
            }
        }
        result.push(make_planner_type_node_with_dependencies(
            node.kind, node.child_type_indices, canonical,
            node.parameter_fact, node.direct_drop_seed,
            node.may_unique_seed, node.physical_rc_seed,
            node.boxing_seed, node.drop_glue_seed,
            node.foreign_containment_seed))
        index = index + 1
    }
    result
}

fn validate_planner_type_dependency_closure(
    values: List<PlannerTypeNode>
) {
    let exact_facts = planner_exact_parameter_universe(values)
    for node in values {
        let mut canonical_cursor = 0
        for exact in exact_facts {
            if canonical_cursor < node.resource_dependency_facts.len() &&
               planner_generic_param_fact_same(
                    node.resource_dependency_facts.get(
                        canonical_cursor).unwrap(), exact) {
                canonical_cursor = canonical_cursor + 1
            }
        }
        if canonical_cursor != node.resource_dependency_facts.len() {
            panic("ResourcePlanner: dependency facts are not in exact formal order")
        }
        for dependency in node.resource_dependency_facts {
            let mut witnessed = match node.parameter_fact {
                some(parameter) => planner_generic_param_fact_same(
                    parameter, dependency),
                none => false
            }
            for child_index in node.child_type_indices {
                if planner_generic_param_facts_contain(
                        values.get(child_index).unwrap().resource_dependency_facts,
                        dependency) {
                    witnessed = true
                }
            }
            if !witnessed {
                panic("ResourcePlanner: derived dependency lacks a direct child witness")
            }
        }
        for child_index in node.child_type_indices {
            for dependency in values.get(
                    child_index).unwrap().resource_dependency_facts {
                if !planner_generic_param_facts_contain(
                        node.resource_dependency_facts, dependency) {
                    panic("ResourcePlanner: type dependency closure is partial")
                }
            }
        }
    }
}

pub fn make_frozen_planner_input(
    flow_fingerprint: Str,
    candidate_proof: CallableCandidateProof,
    type_nodes: List<PlannerTypeNode>,
    callables: List<PlannerCallable>,
    bodies: List<PlannerBody>
) -> FrozenPlannerInput {
    if flow_fingerprint.len() == 0 {
        panic("ResourcePlanner: FlowIR fingerprint is missing")
    }
    let raw_types = copy_planner_type_nodes(type_nodes)
    let copied_callables = copy_planner_callables(callables)
    let copied_bodies = copy_planner_bodies(bodies)
    let mut type_index = 0
    while type_index < raw_types.len() {
        let node = raw_types.get(type_index).unwrap()
        for child in node.child_type_indices {
            if child < 0 || child >= raw_types.len() {
                panic("ResourcePlanner: type child is outside frozen graph")
            }
        }
        type_index = type_index + 1
    }
    let copied_types = close_planner_type_dependencies(raw_types)
    validate_planner_type_dependency_closure(copied_types)
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

// ============================================================
// Exact finite monotone graph construction and solve
// ============================================================

struct TypeCellLayout {
    logical_start: Int,
    physical_start: Int,
    dependency_count: Int
}

struct CallableCellLayout {
    mode_start: Int,
    force_start: Int,
    result_cell: Int,
    result_origin_start: Int,
    parameter_count: Int
}

struct BodyOriginBoundaryLayout {
    origin_start: Int,
    owned_start: Int,
    mode_start: Int,
    force_start: Int
}

struct BodyOriginBlockLayout {
    boundaries: List<BodyOriginBoundaryLayout>
}

struct BodyOriginCellLayout {
    parameter_count: Int,
    slot_count: Int,
    reach_start: Int,
    blocks: List<BodyOriginBlockLayout>
}

fn body_origin_cell(
    layout: BodyOriginCellLayout, block: Int, boundary: Int,
    slot: Int, parameter: Int
) -> Int {
    if slot < 0 || slot >= layout.slot_count ||
       parameter < 0 || parameter >= layout.parameter_count {
        panic("ResourcePlanner: body origin proof coordinate is invalid")
    }
    layout.blocks.get(block).unwrap().boundaries.get(
        boundary).unwrap().origin_start +
        slot * layout.parameter_count + parameter
}

fn body_owned_cell(
    layout: BodyOriginCellLayout, block: Int, boundary: Int, slot: Int
) -> Int {
    if slot < 0 || slot >= layout.slot_count {
        panic("ResourcePlanner: body owned proof coordinate is invalid")
    }
    layout.blocks.get(block).unwrap().boundaries.get(
        boundary).unwrap().owned_start + slot
}

fn body_reach_cell(layout: BodyOriginCellLayout, block: Int) -> Int {
    if block < 0 || block >= layout.blocks.len() {
        panic("ResourcePlanner: body reachability proof coordinate is invalid")
    }
    layout.reach_start + block
}

fn body_mode_cell(
    layout: BodyOriginCellLayout, block: Int, boundary: Int, slot: Int
) -> Int {
    if slot < 0 || slot >= layout.slot_count {
        panic("ResourcePlanner: body mode proof coordinate is invalid")
    }
    layout.blocks.get(block).unwrap().boundaries.get(
        boundary).unwrap().mode_start + slot
}

fn body_force_cell(
    layout: BodyOriginCellLayout, block: Int, boundary: Int, slot: Int
) -> Int {
    if slot < 0 || slot >= layout.slot_count {
        panic("ResourcePlanner: body force proof coordinate is invalid")
    }
    layout.blocks.get(block).unwrap().boundaries.get(
        boundary).unwrap().force_start + slot
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

fn add_cell_with_source(
    mut cells: List<ResourceCellSpec>, kind: ResourceCellKind,
    owner_index: Int, component_index: Int, max_rank: Int,
    source: ResourceCellSource
) -> Int {
    let index = cells.len()
    cells.push(make_resource_cell_spec_with_source(
        kind, owner_index, component_index, max_rank, source))
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

fn add_constraint_at(
    mut constraints: List<ResourceConstraint>, source: ResourceRuleSource,
    rule_tag: Int, target: Int, floor_rank: Int, premises: List<Int>
) {
    constraints.push(make_resource_constraint_at(
        source, rule_tag, target, floor_rank, premises))
}
fn add_all_constraint_at(
    mut constraints: List<ResourceConstraint>, source: ResourceRuleSource,
    rule_tag: Int, target: Int, premises: List<Int>
) {
    constraints.push(make_resource_all_constraint_at(
        source, rule_tag, target, 0, premises))
}

fn add_guarded_constraint_at(
    mut constraints: List<ResourceConstraint>, source: ResourceRuleSource,
    rule_tag: Int, target: Int, premise: Int, guard: Int
) {
    constraints.push(make_resource_guarded_constraint_at(
        source, rule_tag, target, 0, premise, guard))
}

const RULE_TYPE_SEED: Int = 0
const RULE_TYPE_CHILD: Int = 1
const RULE_DIRECT_IMPLIES_UNIQUE: Int = 2
const RULE_CALLABLE_SEED: Int = 3
const RULE_RESULT_ORIGIN_SEED: Int = 6
const RULE_RESULT_ORIGIN_COPY: Int = 7
const RULE_RESULT_ORIGIN_CALL: Int = 8
const RULE_RESULT_OWNED_BODY: Int = 9
const RULE_RESULT_CFG_EDGE: Int = 10
const RULE_LOCAL_CARRY: Int = 11
const RULE_LOCAL_READ: Int = 12
const RULE_LOCAL_CALL: Int = 13
const RULE_LOCAL_RESULT_ORIGIN: Int = 14
const RULE_LOCAL_CFG_EDGE: Int = 15
const RULE_LOCAL_ENTRY_PARAMETER: Int = 16
const RULE_LOCAL_EXPLICIT: Int = 17

pub struct ConstraintGraphBuild {
    cells: List<ResourceCellSpec>,
    constraints: List<ResourceConstraint>,
    type_layouts: List<TypeCellLayout>,
    callable_layouts: List<CallableCellLayout>,
    body_origin_layouts: List<BodyOriginCellLayout>
}

fn event_origin_slot_overwritten(
    event: PlannerEvent, body: PlannerBody, slot: Int
) -> Bool {
    match event.value {
        PlannerEventValue::NoOpValue => false,
        PlannerEventValue::ScopeExitValue(scope_id) =>
            body.slots.get(slot).unwrap().scope_id == scope_id,
        PlannerEventValue::InitializeValue { target, .. } => slot == target,
        PlannerEventValue::ReadValue { target, .. } => slot == target,
        PlannerEventValue::MutateValue { .. } => false,
        PlannerEventValue::ConsumeValue(source, _, target) =>
            slot == source || match target {
                some(value) => slot == value,
                none => false
            },
        PlannerEventValue::DiscardValue(source) => slot == source,
        PlannerEventValue::AssignValue { rhs_temp, target } =>
            slot == rhs_temp || (planner_place_is_slot(target) &&
                slot == planner_place_slot(target)),
        PlannerEventValue::MovePlaceValue { source, target } =>
            slot == target || (planner_place_is_slot(source) &&
                slot == planner_place_slot(source)),
        PlannerEventValue::CallValue { result_slot, .. } => match result_slot {
            some(value) => slot == value,
            none => false
        },
        PlannerEventValue::ProjectValue { target, .. } => slot == target,
        PlannerEventValue::CaptureValue { source, target, demand } =>
            slot == target || (slot == source &&
                param_mode_same(
                    transfer_demand_mode(demand), param_mode_own()) &&
                transfer_demand_force(demand))
    }
}

fn add_body_event_result_constraints(
    mut constraints: List<ResourceConstraint>,
    body: PlannerBody, layout: BodyOriginCellLayout,
    block_index: Int, boundary: Int, event: PlannerEvent,
    callables: List<PlannerCallable>,
    callable_layouts: List<CallableCellLayout>
) {
    let next = boundary + 1
    let source_site = make_instruction_resource_rule_source(
        make_flow_instruction_ref(body.reference, block_index, boundary))
    let mut slot = 0
    while slot < body.slots.len() {
        if !event_origin_slot_overwritten(event, body, slot) {
            let mut parameter = 0
            while parameter < layout.parameter_count {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_ORIGIN_COPY,
                    body_origin_cell(
                        layout, block_index, next, slot, parameter), 0,
                    [body_origin_cell(
                        layout, block_index, boundary, slot, parameter)])
                parameter = parameter + 1
            }
            add_constraint_at(constraints, source_site,
                RULE_RESULT_ORIGIN_COPY,
                body_owned_cell(layout, block_index, next, slot), 0,
                [body_owned_cell(layout, block_index, boundary, slot)])
        }
        slot = slot + 1
    }
    match event.value {
        PlannerEventValue::InitializeValue {
            input_slots, origin_input_ordinals, target, ..
        } => {
            for ordinal in origin_input_ordinals {
                let source = input_slots.get(ordinal).unwrap()
                let mut parameter = 0
                while parameter < layout.parameter_count {
                    add_constraint_at(constraints, source_site,
                        RULE_RESULT_ORIGIN_COPY,
                        body_origin_cell(
                            layout, block_index, next, target, parameter), 0,
                        [body_origin_cell(
                            layout, block_index, boundary, source, parameter)])
                    parameter = parameter + 1
                }
            }
            if body.slots.get(target).unwrap().owns_storage {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_OWNED_BODY,
                    body_owned_cell(layout, block_index, next, target), 0,
                    [body_reach_cell(layout, block_index)])
            }
        },
        PlannerEventValue::ReadValue { source, target } => {
            let mut parameter = 0
            while parameter < layout.parameter_count {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_ORIGIN_COPY,
                    body_origin_cell(
                        layout, block_index, next, target, parameter), 0,
                    [body_origin_cell(
                        layout, block_index, boundary, source, parameter)])
                parameter = parameter + 1
            }
            if body.slots.get(target).unwrap().owns_storage {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_OWNED_BODY,
                    body_owned_cell(layout, block_index, next, target), 0,
                    [body_reach_cell(layout, block_index)])
            }
        },
        PlannerEventValue::ConsumeValue(source, _, target) => match target {
            some(value) => {
                let mut parameter = 0
                while parameter < layout.parameter_count {
                    add_constraint_at(constraints, source_site,
                        RULE_RESULT_ORIGIN_COPY,
                        body_origin_cell(
                            layout, block_index, next, value, parameter), 0,
                        [body_origin_cell(
                            layout, block_index, boundary, source, parameter)])
                    parameter = parameter + 1
                }
                if body.slots.get(value).unwrap().owns_storage {
                    add_constraint_at(constraints, source_site,
                        RULE_RESULT_OWNED_BODY,
                        body_owned_cell(layout, block_index, next, value), 0,
                        [body_reach_cell(layout, block_index)])
                }
            },
            none => {}
        },
        PlannerEventValue::AssignValue { rhs_temp, target } => if
                planner_place_is_slot(target) {
            let target_slot = planner_place_slot(target)
            let mut parameter = 0
            while parameter < layout.parameter_count {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_ORIGIN_COPY,
                    body_origin_cell(
                        layout, block_index, next, target_slot, parameter), 0,
                    [body_origin_cell(
                        layout, block_index, boundary, rhs_temp, parameter)])
                parameter = parameter + 1
            }
            if body.slots.get(target_slot).unwrap().owns_storage {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_OWNED_BODY,
                    body_owned_cell(layout, block_index, next, target_slot), 0,
                    [body_reach_cell(layout, block_index)])
            }
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_slots, result_slot, ..
        } => match result_slot {
            some(target) => {
                for callable_index in callable_indices {
                    let callable = callables.get(callable_index).unwrap()
                    let callee_layout = callable_layouts.get(
                        callable_index).unwrap()
                    let mut callee_parameter = 0
                    while callee_parameter <
                            callable.parameter_type_indices.len() {
                        let argument = argument_slots.get(
                            callee_parameter).unwrap()
                        let mut caller_parameter = 0
                        while caller_parameter < layout.parameter_count {
                            add_all_constraint_at(constraints, source_site,
                                RULE_RESULT_ORIGIN_CALL,
                                body_origin_cell(layout, block_index, next,
                                    target, caller_parameter),
                                [callee_layout.result_origin_start +
                                    callee_parameter,
                                 body_origin_cell(layout, block_index, boundary,
                                    argument, caller_parameter)])
                            caller_parameter = caller_parameter + 1
                        }
                        callee_parameter = callee_parameter + 1
                    }
                    add_all_constraint_at(constraints, source_site,
                        RULE_RESULT_OWNED_BODY,
                        body_owned_cell(layout, block_index, next, target),
                        [body_reach_cell(layout, block_index),
                         callee_layout.result_cell])
                }
            },
            none => {}
        },
        PlannerEventValue::ProjectValue { source, target, .. } => {
            let mut parameter = 0
            while parameter < layout.parameter_count {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_ORIGIN_COPY,
                    body_origin_cell(
                        layout, block_index, next, target, parameter), 0,
                    [body_origin_cell(
                        layout, block_index, boundary, source, parameter)])
                parameter = parameter + 1
            }
            if body.slots.get(target).unwrap().owns_storage {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_OWNED_BODY,
                    body_owned_cell(layout, block_index, next, target), 0,
                    [body_reach_cell(layout, block_index)])
            }
        },
        PlannerEventValue::MovePlaceValue { source, target } => {
            let source_slot = if planner_place_is_slot(source) {
                planner_place_slot(source)
            } else { planner_place_base(source) }
            let mut parameter = 0
            while parameter < layout.parameter_count {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_ORIGIN_COPY,
                    body_origin_cell(
                        layout, block_index, next, target, parameter), 0,
                    [body_origin_cell(
                        layout, block_index, boundary, source_slot, parameter)])
                parameter = parameter + 1
            }
            if body.slots.get(target).unwrap().owns_storage {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_OWNED_BODY,
                    body_owned_cell(layout, block_index, next, target), 0,
                    [body_reach_cell(layout, block_index)])
            }
        },
        PlannerEventValue::CaptureValue { source, target, .. } => {
            let mut parameter = 0
            while parameter < layout.parameter_count {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_ORIGIN_COPY,
                    body_origin_cell(
                        layout, block_index, next, target, parameter), 0,
                    [body_origin_cell(
                        layout, block_index, boundary, source, parameter)])
                parameter = parameter + 1
            }
            if body.slots.get(target).unwrap().owns_storage {
                add_constraint_at(constraints, source_site,
                    RULE_RESULT_OWNED_BODY,
                    body_owned_cell(layout, block_index, next, target), 0,
                    [body_reach_cell(layout, block_index)])
            }
        },
        _ => {}
    }
}

fn add_body_result_constraints(
    mut constraints: List<ResourceConstraint>, body_index: Int,
    body: PlannerBody, layout: BodyOriginCellLayout,
    callable_index: Int, callable_layout: CallableCellLayout,
    callables: List<PlannerCallable>,
    callable_layouts: List<CallableCellLayout>
) {
    let entry_source = make_block_resource_rule_source(
        make_flow_block_ref(body.reference, body.entry_block))
    add_constraint_at(constraints, entry_source, RULE_RESULT_ORIGIN_SEED,
        body_reach_cell(layout, body.entry_block), 1, [])
    let mut slot = 0
    while slot < body.slots.len() {
        let value = body.slots.get(slot).unwrap()
        match value.parameter_ordinal {
            some(parameter) => add_constraint_at(constraints, entry_source,
                RULE_RESULT_ORIGIN_SEED,
                body_origin_cell(
                    layout, body.entry_block, 0, slot, parameter), 0,
                [body_reach_cell(layout, body.entry_block)]),
            none => {}
        }
        if value.initially_live && value.owns_storage {
            add_constraint_at(constraints, entry_source,
                RULE_RESULT_OWNED_BODY,
                body_owned_cell(layout, body.entry_block, 0, slot), 0,
                [body_reach_cell(layout, body.entry_block)])
        }
        slot = slot + 1
    }
    let mut block_index = 0
    while block_index < body.blocks.len() {
        let block = body.blocks.get(block_index).unwrap()
        let mut boundary = 0
        while boundary < block.events.len() {
            add_body_event_result_constraints(
                constraints, body, layout, block_index, boundary,
                block.events.get(boundary).unwrap(),
                callables, callable_layouts)
            boundary = boundary + 1
        }
        let end = block.events.len()
        let block_source = make_block_resource_rule_source(
            make_flow_block_ref(body.reference, block_index))
        if block.terminator_kind == 3 {
            for usage in block.terminator_uses {
                let mut parameter = 0
                while parameter < layout.parameter_count {
                    add_all_constraint_at(constraints, block_source,
                        RULE_RESULT_ORIGIN_COPY,
                        callable_layout.result_origin_start + parameter,
                        [body_reach_cell(layout, block_index),
                         body_origin_cell(layout, block_index, end,
                            usage.slot, parameter)])
                    parameter = parameter + 1
                }
                add_all_constraint_at(constraints, block_source,
                    RULE_RESULT_OWNED_BODY,
                    callable_layout.result_cell,
                    [body_reach_cell(layout, block_index),
                     body_owned_cell(layout, block_index, end, usage.slot)])
            }
        }
        let mut edge_index = 0
        while edge_index < block.edges.len() {
            let edge = block.edges.get(edge_index).unwrap()
            match edge.target_block {
                some(target) => {
                    let edge_source = make_edge_resource_rule_source(
                        make_flow_block_ref(body.reference, block_index),
                        edge_index)
                    add_constraint_at(constraints, edge_source,
                        RULE_RESULT_CFG_EDGE,
                        body_reach_cell(layout, target), 0,
                        [body_reach_cell(layout, block_index)])
                    slot = 0
                    while slot < body.slots.len() {
                        if !int_list_contains(edge.exited_scope_ids,
                                body.slots.get(slot).unwrap().scope_id) {
                            if int_list_contains(
                                    edge.fresh_result_slots, slot) {
                                if body.slots.get(slot).unwrap().owns_storage {
                                    add_constraint_at(constraints, edge_source,
                                        RULE_RESULT_CFG_EDGE,
                                        body_owned_cell(
                                            layout, target, 0, slot), 0,
                                        [body_reach_cell(layout, block_index)])
                                }
                            } else {
                                let mut parameter = 0
                                while parameter < layout.parameter_count {
                                    add_constraint_at(constraints, edge_source,
                                        RULE_RESULT_CFG_EDGE,
                                        body_origin_cell(layout, target, 0,
                                            slot, parameter), 0,
                                        [body_origin_cell(layout, block_index,
                                            end, slot, parameter)])
                                    parameter = parameter + 1
                                }
                                add_constraint_at(constraints, edge_source,
                                    RULE_RESULT_CFG_EDGE,
                                    body_owned_cell(
                                        layout, target, 0, slot), 0,
                                    [body_owned_cell(
                                        layout, block_index, end, slot)])
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
    let _ = body_index
    let _ = callable_index
}

fn event_demand_slot_defined(
    event: PlannerEvent, body: PlannerBody, slot: Int
) -> Bool {
    match event.value {
        PlannerEventValue::NoOpValue => false,
        PlannerEventValue::ScopeExitValue(scope_id) =>
            body.slots.get(slot).unwrap().scope_id == scope_id,
        PlannerEventValue::InitializeValue { target, .. } => slot == target,
        PlannerEventValue::ReadValue { target, .. } => slot == target,
        PlannerEventValue::MutateValue { .. } => false,
        PlannerEventValue::ConsumeValue(source, _, target) =>
            slot == source || match target {
                some(value) => slot == value,
                none => false
            },
        PlannerEventValue::DiscardValue(source) => slot == source,
        PlannerEventValue::AssignValue { rhs_temp, target } =>
            slot == rhs_temp || (planner_place_is_slot(target) &&
                slot == planner_place_slot(target)),
        PlannerEventValue::MovePlaceValue { source, target } =>
            slot == target || (planner_place_is_slot(source) &&
                slot == planner_place_slot(source)),
        PlannerEventValue::CallValue { result_slot, .. } => match result_slot {
            some(value) => slot == value,
            none => false
        },
        PlannerEventValue::ProjectValue { target, .. } => slot == target,
        PlannerEventValue::CaptureValue { target, .. } => slot == target
    }
}

fn add_local_demand_floor(
    mut constraints: List<ResourceConstraint>, source: ResourceRuleSource,
    layout: BodyOriginCellLayout, block: Int, boundary: Int,
    slot: Int, demand: TransferDemand
) {
    add_constraint_at(constraints, source, RULE_LOCAL_EXPLICIT,
        body_mode_cell(layout, block, boundary, slot),
        param_mode_tag(transfer_demand_mode(demand)), [])
    add_constraint_at(constraints, source, RULE_LOCAL_EXPLICIT,
        body_force_cell(layout, block, boundary, slot),
        if transfer_demand_force(demand) { 1 } else { 0 }, [])
}

fn add_local_demand_copy(
    mut constraints: List<ResourceConstraint>, source: ResourceRuleSource,
    rule: Int, layout: BodyOriginCellLayout,
    target_block: Int, target_boundary: Int, target_slot: Int,
    premise_block: Int, premise_boundary: Int, premise_slot: Int
) {
    add_constraint_at(constraints, source, rule,
        body_mode_cell(
            layout, target_block, target_boundary, target_slot), 0,
        [body_mode_cell(
            layout, premise_block, premise_boundary, premise_slot)])
    add_constraint_at(constraints, source, rule,
        body_force_cell(
            layout, target_block, target_boundary, target_slot), 0,
        [body_force_cell(
            layout, premise_block, premise_boundary, premise_slot)])
}

fn add_body_event_demand_constraints(
    mut constraints: List<ResourceConstraint>, body: PlannerBody,
    layout: BodyOriginCellLayout, block_index: Int, boundary: Int,
    event: PlannerEvent, callables: List<PlannerCallable>,
    callable_layouts: List<CallableCellLayout>
) {
    let next = boundary + 1
    let site = make_instruction_resource_rule_source(
        make_flow_instruction_ref(body.reference, block_index, boundary))
    let mut slot = 0
    while slot < body.slots.len() {
        if !event_demand_slot_defined(event, body, slot) {
            add_local_demand_copy(
                constraints, site, RULE_LOCAL_CARRY, layout,
                block_index, boundary, slot,
                block_index, next, slot)
        }
        slot = slot + 1
    }
    match event.value {
        PlannerEventValue::NoOpValue |
        PlannerEventValue::ScopeExitValue(_) => {},
        PlannerEventValue::InitializeValue {
            input_slots, input_demands, origin_input_ordinals, target
        } => {
            let mut input = 0
            while input < input_slots.len() {
                let source_slot = input_slots.get(input).unwrap()
                add_local_demand_floor(
                    constraints, site, layout,
                    block_index, boundary, source_slot,
                    input_demands.get(input).unwrap())
                if int_list_contains(origin_input_ordinals, input) {
                    add_local_demand_copy(
                        constraints, site, RULE_LOCAL_RESULT_ORIGIN, layout,
                        block_index, boundary, source_slot,
                        block_index, next, target)
                }
                input = input + 1
            }
        },
        PlannerEventValue::ReadValue { source, target } =>
            add_local_demand_copy(
                constraints, site, RULE_LOCAL_READ, layout,
                block_index, boundary, source,
                block_index, next, target),
        PlannerEventValue::MutateValue {
            target, value: input, value_demand
        } => {
            add_local_demand_floor(
                constraints, site, layout, block_index, boundary, target,
                make_transfer_demand(param_mode_mut_borrow(), false))
            add_local_demand_floor(
                constraints, site, layout, block_index, boundary, input,
                value_demand)
        },
        PlannerEventValue::ConsumeValue(source, force, _) =>
            add_local_demand_floor(
                constraints, site, layout, block_index, boundary, source,
                make_transfer_demand(param_mode_own(), force)),
        PlannerEventValue::DiscardValue(source) =>
            add_local_demand_floor(
                constraints, site, layout, block_index, boundary, source,
                make_transfer_demand(param_mode_own(), false)),
        PlannerEventValue::AssignValue { rhs_temp, target } => {
            add_local_demand_floor(
                constraints, site, layout, block_index, boundary, rhs_temp,
                make_transfer_demand(param_mode_own(), false))
            add_local_demand_floor(
                constraints, site, layout, block_index, boundary,
                if planner_place_is_slot(target) {
                    planner_place_slot(target)
                } else {
                    planner_place_base(target)
                },
                make_transfer_demand(param_mode_mut_borrow(), false))
        },
        PlannerEventValue::MovePlaceValue { source, target } => {
            let source_slot = if planner_place_is_slot(source) {
                planner_place_slot(source)
            } else { planner_place_base(source) }
            add_local_demand_floor(
                constraints, site, layout, block_index, boundary,
                source_slot, make_transfer_demand(param_mode_own(), true))
            add_local_demand_copy(
                constraints, site, RULE_LOCAL_READ, layout,
                block_index, boundary, source_slot,
                block_index, next, target)
        },
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            argument_slots, result_slot, ..
        } => {
            let mut argument = 0
            while argument < argument_slots.len() {
                let argument_slot = argument_slots.get(argument).unwrap()
                add_local_demand_floor(
                    constraints, site, layout, block_index, boundary,
                    argument_slot, argument_demands.get(argument).unwrap())
                for callable_index in callable_indices {
                    let callee = callable_layouts.get(callable_index).unwrap()
                    add_constraint_at(constraints, site, RULE_LOCAL_CALL,
                        body_mode_cell(
                            layout, block_index, boundary, argument_slot), 0,
                        [callee.mode_start + argument])
                    add_constraint_at(constraints, site, RULE_LOCAL_CALL,
                        body_force_cell(
                            layout, block_index, boundary, argument_slot), 0,
                        [callee.force_start + argument])
                    match result_slot {
                        some(result) => {
                            add_guarded_constraint_at(
                                constraints, site,
                                RULE_LOCAL_RESULT_ORIGIN,
                                body_mode_cell(layout, block_index, boundary,
                                    argument_slot),
                                body_mode_cell(layout, block_index, next,
                                    result),
                                callee.result_origin_start + argument)
                            add_guarded_constraint_at(
                                constraints, site,
                                RULE_LOCAL_RESULT_ORIGIN,
                                body_force_cell(layout, block_index, boundary,
                                    argument_slot),
                                body_force_cell(layout, block_index, next,
                                    result),
                                callee.result_origin_start + argument)
                        },
                        none => {}
                    }
                }
                argument = argument + 1
            }
        },
        PlannerEventValue::ProjectValue {
            source, target, partial, ..
        } => {
            // Every projection observes its aggregate base. Ordinary field
            // reads never turn result demand into whole-aggregate ownership.
            add_local_demand_floor(
                constraints, site, layout, block_index, boundary, source,
                make_transfer_demand(param_mode_borrow(), false))
            // Pattern projection is the one 0.1 partial-transfer producer.
            // Its exact result demand therefore propagates to the base so an
            // owning extraction reaches the callable parameter/entry seed.
            if partial {
                add_local_demand_copy(
                    constraints, site, RULE_LOCAL_READ, layout,
                    block_index, boundary, source,
                    block_index, next, target)
            }
        },
        PlannerEventValue::CaptureValue { source, demand, .. } =>
            add_local_demand_floor(
                constraints, site, layout, block_index, boundary,
                source, demand)
    }
    let _ = callables
}

fn add_body_demand_constraints(
    mut constraints: List<ResourceConstraint>, body: PlannerBody,
    layout: BodyOriginCellLayout, callable_layout: CallableCellLayout,
    callables: List<PlannerCallable>,
    callable_layouts: List<CallableCellLayout>
) {
    let mut block_index = 0
    while block_index < body.blocks.len() {
        let block = body.blocks.get(block_index).unwrap()
        let mut boundary = 0
        while boundary < block.events.len() {
            add_body_event_demand_constraints(
                constraints, body, layout, block_index, boundary,
                block.events.get(boundary).unwrap(),
                callables, callable_layouts)
            boundary = boundary + 1
        }
        let end = block.events.len()
        let terminator_site = make_block_resource_rule_source(
            make_flow_block_ref(body.reference, block_index))
        for usage in block.terminator_uses {
            add_local_demand_floor(
                constraints, terminator_site, layout,
                block_index, end, usage.slot, usage.demand)
        }
        let mut edge_index = 0
        while edge_index < block.edges.len() {
            let edge = block.edges.get(edge_index).unwrap()
            match edge.target_block {
                some(target) => {
                    let edge_site = make_edge_resource_rule_source(
                        make_flow_block_ref(body.reference, block_index),
                        edge_index)
                    let mut slot = 0
                    while slot < body.slots.len() {
                        if !int_list_contains(edge.fresh_result_slots, slot) &&
                           !int_list_contains(
                                edge.exited_scope_ids,
                                body.slots.get(slot).unwrap().scope_id) {
                            add_local_demand_copy(
                                constraints, edge_site, RULE_LOCAL_CFG_EDGE,
                                layout, block_index, end, slot,
                                target, 0, slot)
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
    let entry_site = make_block_resource_rule_source(
        make_flow_block_ref(body.reference, body.entry_block))
    let mut slot = 0
    while slot < body.slots.len() {
        match body.slots.get(slot).unwrap().parameter_ordinal {
            some(parameter) => {
                add_constraint_at(constraints, entry_site,
                    RULE_LOCAL_ENTRY_PARAMETER,
                    callable_layout.mode_start + parameter, 0,
                    [body_mode_cell(
                        layout, body.entry_block, 0, slot)])
                add_constraint_at(constraints, entry_site,
                    RULE_LOCAL_ENTRY_PARAMETER,
                    callable_layout.force_start + parameter, 0,
                    [body_force_cell(
                        layout, body.entry_block, 0, slot)])
            },
            none => {}
        }
        slot = slot + 1
    }
}

pub fn build_constraint_graph(input: FrozenPlannerInput) -> ConstraintGraphBuild {
    let cells: List<ResourceCellSpec> = []
    let constraints: List<ResourceConstraint> = []
    let mut type_layouts: List<TypeCellLayout> = []
    let mut callable_layouts: List<CallableCellLayout> = []
    let mut body_origin_layouts: List<BodyOriginCellLayout> = []

    let mut type_index = 0
    while type_index < input.type_nodes.len() {
        let node = input.type_nodes.get(type_index).unwrap()
        let logical_start = cells.len()
        let mut component = 0
        while component < 2 + node.resource_dependency_facts.len() {
            add_cell(cells, resource_cell_kind_logical_shape(),
                type_index, component, 1)
            component = component + 1
        }
        let physical_start = cells.len()
        component = 0
        while component < 4 + node.resource_dependency_facts.len() {
            add_cell(cells, resource_cell_kind_physical_shape(),
                type_index, component, 1)
            component = component + 1
        }
        type_layouts.push(TypeCellLayout {
            logical_start: logical_start,
            physical_start: physical_start,
            dependency_count: node.resource_dependency_facts.len()
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
        let result_cell = add_cell_with_source(
            cells, resource_cell_kind_callable_result(),
            callable_index, 0, 1,
            make_callable_result_owned_source(callable.reference))
        let result_origin_start = cells.len()
        parameter = 0
        while parameter < callable.parameter_type_indices.len() {
            add_cell_with_source(cells,
                resource_cell_kind_callable_result_origin(),
                callable_index, parameter, 1,
                make_callable_result_origin_source(
                    callable.reference, parameter))
            parameter = parameter + 1
        }
        callable_layouts.push(CallableCellLayout {
            mode_start: mode_start,
            force_start: force_start,
            result_cell: result_cell,
            result_origin_start: result_origin_start,
            parameter_count: callable.parameter_type_indices.len()
        })
        callable_index = callable_index + 1
    }


    let mut body_index = 0
    while body_index < input.bodies.len() {
        let body = input.bodies.get(body_index).unwrap()
        let callable_index = flow_callable_index_for_planner(
            input.callables, body.reference)
        let parameter_count = input.callables.get(
            callable_index).unwrap().parameter_type_indices.len()
        let mut block_layouts: List<BodyOriginBlockLayout> = []
        let reach_start = cells.len()
        let mut reach_block = 0
        while reach_block < body.blocks.len() {
            add_cell_with_source(cells,
                resource_cell_kind_body_block_reachable(),
                body_index, reach_block, 1,
                make_body_reach_source(make_flow_block_ref(
                    body.reference, reach_block)))
            reach_block = reach_block + 1
        }
        let mut origin_component = 0
        let mut owned_component = 0
        let mut mode_component = 0
        let mut force_component = 0
        for block in body.blocks {
            let mut boundaries: List<BodyOriginBoundaryLayout> = []
            let mut boundary = 0
            while boundary <= block.events.len() {
                let origin_start = cells.len()
                let mut slot = 0
                while slot < body.slots.len() {
                    let mut parameter = 0
                    while parameter < parameter_count {
                        add_cell_with_source(cells,
                            resource_cell_kind_body_slot_origin(),
                            body_index, origin_component, 1,
                            make_body_slot_origin_source(
                                make_flow_block_ref(body.reference,
                                    block_layouts.len()),
                                boundary,
                                body.slots.get(slot).unwrap().reference,
                                parameter))
                        origin_component = origin_component + 1
                        parameter = parameter + 1
                    }
                    slot = slot + 1
                }
                let owned_start = cells.len()
                slot = 0
                while slot < body.slots.len() {
                    add_cell_with_source(cells,
                        resource_cell_kind_body_slot_owned(),
                        body_index, owned_component, 1,
                        make_body_slot_owned_source(
                            make_flow_block_ref(body.reference,
                                block_layouts.len()),
                            boundary,
                            body.slots.get(slot).unwrap().reference))
                    owned_component = owned_component + 1
                    slot = slot + 1
                }
                let mode_start = cells.len()
                slot = 0
                while slot < body.slots.len() {
                    add_cell_with_source(cells,
                        resource_cell_kind_body_slot_mode(),
                        body_index, mode_component, 3,
                        make_body_slot_mode_source(
                            make_flow_block_ref(body.reference,
                                block_layouts.len()),
                            boundary,
                            body.slots.get(slot).unwrap().reference))
                    mode_component = mode_component + 1
                    slot = slot + 1
                }
                let force_start = cells.len()
                slot = 0
                while slot < body.slots.len() {
                    add_cell_with_source(cells,
                        resource_cell_kind_body_slot_force(),
                        body_index, force_component, 1,
                        make_body_slot_force_source(
                            make_flow_block_ref(body.reference,
                                block_layouts.len()),
                            boundary,
                            body.slots.get(slot).unwrap().reference))
                    force_component = force_component + 1
                    slot = slot + 1
                }
                boundaries.push(BodyOriginBoundaryLayout {
                    origin_start: origin_start, owned_start: owned_start,
                    mode_start: mode_start, force_start: force_start
                })
                boundary = boundary + 1
            }
            block_layouts.push(BodyOriginBlockLayout {
                boundaries: boundaries
            })
        }
        body_origin_layouts.push(BodyOriginCellLayout {
            parameter_count: parameter_count,
            slot_count: body.slots.len(), reach_start: reach_start,
            blocks: block_layouts
        })
        body_index = body_index + 1
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
        match node.parameter_fact {
            some(parameter) => {
                let dependency = planner_generic_param_fact_index(
                    node.resource_dependency_facts, parameter)
                add_constraint(constraints, RULE_TYPE_SEED,
                    layout.logical_start + 2 + dependency, 1, [])
                add_constraint(constraints, RULE_TYPE_SEED,
                    layout.physical_start + 4 + dependency, 1, [])
            },
            none => {}
        }
        for child_index in node.child_type_indices {
            let child = type_layouts.get(child_index).unwrap()
            // A Drop provider is exact to its declaring type. Containment only
            // inherits the child's resulting unique capability.
            add_constraint(constraints, RULE_TYPE_CHILD,
                layout.logical_start + 1, 0,
                [child.logical_start + 1])
            let mut physical_component = 0
            while physical_component < 4 {
                add_constraint(constraints, RULE_TYPE_CHILD,
                    layout.physical_start + physical_component, 0,
                    [child.physical_start + physical_component])
                physical_component = physical_component + 1
            }
        }
        let mut dependency = 0
        while dependency < node.resource_dependency_facts.len() {
            let fact = node.resource_dependency_facts.get(dependency).unwrap()
            for child_index in node.child_type_indices {
                let child_node = input.type_nodes.get(child_index).unwrap()
                if planner_generic_param_facts_contain(
                        child_node.resource_dependency_facts, fact) {
                    let child_dependency = planner_generic_param_fact_index(
                        child_node.resource_dependency_facts, fact)
                    let child = type_layouts.get(child_index).unwrap()
                    add_constraint(constraints, RULE_TYPE_CHILD,
                        layout.logical_start + 2 + dependency, 0,
                        [child.logical_start + 2 +
                            child_dependency])
                    add_constraint(constraints, RULE_TYPE_CHILD,
                        layout.physical_start + 4 + dependency, 0,
                        [child.physical_start + 4 +
                            child_dependency])
                }
            }
            dependency = dependency + 1
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
        if !callable.has_body {
            let callable_source = make_callable_resource_rule_source(
                callable.reference)
            add_constraint_at(constraints, callable_source,
                RULE_CALLABLE_SEED,
                layout.result_cell,
                if callable.result_owned_seed { 1 } else { 0 }, [])
            for origin in callable.result_origin_parameter_ordinals {
                add_constraint_at(constraints, callable_source,
                    RULE_RESULT_ORIGIN_SEED,
                    layout.result_origin_start + origin, 1, [])
            }
        }
        callable_index = callable_index + 1
    }
    let mut body_index = 0
    while body_index < input.bodies.len() {
        let body = input.bodies.get(body_index).unwrap()
        let callable_index = flow_callable_index_for_planner(
            input.callables, body.reference)
        add_body_result_constraints(
            constraints, body_index, body,
            body_origin_layouts.get(body_index).unwrap(),
            callable_index, callable_layouts.get(callable_index).unwrap(),
            input.callables, callable_layouts)
        add_body_demand_constraints(
            constraints, body,
            body_origin_layouts.get(body_index).unwrap(),
            callable_layouts.get(callable_index).unwrap(),
            input.callables, callable_layouts)
        body_index = body_index + 1
    }
    ConstraintGraphBuild {
        cells: cells,
        constraints: constraints,
        type_layouts: type_layouts,
        callable_layouts: callable_layouts,
        body_origin_layouts: body_origin_layouts
    }
}

fn required_constraint_rank(
    constraint: ResourceConstraint, ranks: List<Int>
) -> Int {
    match resource_constraint_guard_cell(constraint) {
        some(guard) => if ranks.get(guard).unwrap() == 0 {
            return resource_constraint_floor_rank(constraint)
        },
        none => {}
    }
    if resource_constraint_requires_all(constraint) {
        let mut all = true
        for premise in resource_constraint_premise_cells(constraint) {
            if ranks.get(premise).unwrap() == 0 { all = false }
        }
        if all && resource_constraint_floor_rank(constraint) < 1 { return 1 }
        return resource_constraint_floor_rank(constraint)
    }
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

pub fn solve_constraint_graph(build: ConstraintGraphBuild) -> ResourceFixedPointProof {
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

pub struct SolvedResourceGraph {
    pub fixed_point: ResourceFixedPointProof,
    pub logical_shapes: List<LogicalOwnershipShape>,
    pub physical_shapes: List<PhysicalRcShape>,
    pub callable_demands: List<List<TransferDemand>>,
    pub callable_results_owned: List<Bool>,
    pub callable_result_type_indices: List<Int>,
    pub bodies: List<PlannerBody>
}

fn bool_rank(ranks: List<Int>, index: Int) -> Bool {
    ranks.get(index).unwrap() > 0
}

fn demand_from_body_cells(
    ranks: List<Int>, layout: BodyOriginCellLayout,
    block: Int, boundary: Int, slot: Int
) -> TransferDemand {
    make_transfer_demand(
        param_mode_from_tag(ranks.get(
            body_mode_cell(layout, block, boundary, slot)).unwrap()),
        bool_rank(ranks, body_force_cell(layout, block, boundary, slot)))
}

fn solved_event_decision(
    event: PlannerEvent, layout: BodyOriginCellLayout,
    block: Int, boundary: Int,
    callable_layouts: List<CallableCellLayout>,
    ranks: List<Int>
) -> EventDecision {
    let mut transfers: List<TransferDecision> = []
    let mut result_owned = false
    match event.value {
        PlannerEventValue::NoOpValue |
        PlannerEventValue::ScopeExitValue(_) => {},
        PlannerEventValue::InitializeValue {
            input_demands, origin_input_ordinals, target, ..
        } => {
            let target_demand = demand_from_body_cells(
                ranks, layout, block, boundary + 1, target)
            let mut input = 0
            while input < input_demands.len() {
                transfers.push(make_transfer_decision(
                    planner_event_operand(event, input),
                    if int_list_contains(origin_input_ordinals, input) {
                        transfer_demand_join(
                            input_demands.get(input).unwrap(), target_demand)
                    } else {
                        input_demands.get(input).unwrap()
                    }))
                input = input + 1
            }
        },
        PlannerEventValue::ReadValue { target, .. } =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                demand_from_body_cells(
                    ranks, layout, block, boundary + 1, target))),
        PlannerEventValue::MutateValue { value_demand, .. } => {
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                make_transfer_demand(param_mode_mut_borrow(), false)))
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 1), value_demand))
        },
        PlannerEventValue::ConsumeValue(_, force, _) =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                make_transfer_demand(param_mode_own(), force))),
        PlannerEventValue::DiscardValue(_) =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                make_transfer_demand(param_mode_own(), false))),
        PlannerEventValue::AssignValue { .. } => {
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                make_transfer_demand(param_mode_own(), false)))
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 1),
                make_transfer_demand(param_mode_mut_borrow(), false)))
        },
        PlannerEventValue::MovePlaceValue { .. } =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                make_transfer_demand(param_mode_own(), true))),
        PlannerEventValue::CallValue {
            callable_indices, argument_demands,
            result_owned: lower_owned, result_slot, ..
        } => {
            let mut argument = 0
            while argument < argument_demands.len() {
                let mut demand = argument_demands.get(argument).unwrap()
                for callable_index in callable_indices {
                    let callee = callable_layouts.get(callable_index).unwrap()
                    demand = transfer_demand_join(demand,
                        make_transfer_demand(
                            param_mode_from_tag(ranks.get(
                                callee.mode_start + argument).unwrap()),
                            bool_rank(ranks,
                                callee.force_start + argument)))
                    match result_slot {
                        some(result) => if bool_rank(
                                ranks,
                                callee.result_origin_start + argument) {
                            demand = transfer_demand_join(demand,
                                demand_from_body_cells(
                                    ranks, layout, block, boundary + 1,
                                    result))
                        },
                        none => {}
                    }
                }
                transfers.push(make_transfer_decision(
                    planner_event_operand(event, argument), demand))
                argument = argument + 1
            }
            result_owned = lower_owned
            for callable_index in callable_indices {
                if bool_rank(ranks, callable_layouts.get(
                        callable_index).unwrap().result_cell) {
                    result_owned = true
                }
            }
        },
        PlannerEventValue::ProjectValue { target, .. } =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0),
                demand_from_body_cells(
                    ranks, layout, block, boundary + 1, target))),
        PlannerEventValue::CaptureValue { demand, .. } =>
            transfers.push(make_transfer_decision(
                planner_event_operand(event, 0), demand))
    }
    make_event_decision(event.step, transfers, result_owned)
}

fn materialize_solved_body_decisions(
    bodies: List<PlannerBody>, layouts: List<BodyOriginCellLayout>,
    callable_layouts: List<CallableCellLayout>, ranks: List<Int>
) -> List<PlannerBody> {
    let mut result: List<PlannerBody> = []
    let mut body_index = 0
    while body_index < bodies.len() {
        let body = bodies.get(body_index).unwrap()
        let layout = layouts.get(body_index).unwrap()
        let mut blocks: List<PlannerBlock> = []
        let mut block_index = 0
        while block_index < body.blocks.len() {
            let block = body.blocks.get(block_index).unwrap()
            let mut events: List<PlannerEvent> = []
            let mut boundary = 0
            while boundary < block.events.len() {
                let event = block.events.get(boundary).unwrap()
                events.push(with_planner_event_decision(
                    event, solved_event_decision(
                        event, layout, block_index, boundary,
                        callable_layouts, ranks)))
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

pub fn materialize_solved_graph(
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
        while parameter < layout.dependency_count {
            let logical_dependency = bool_rank(
                ranks, layout.logical_start + 2 + parameter)
            let physical_dependency = bool_rank(
                ranks, layout.physical_start + 4 + parameter)
            if !logical_dependency || !physical_dependency {
                panic("ResourcePlanner: exact type dependency lacks a finite derivation")
            }
            logical_deps.push(logical_dependency)
            physical_deps.push(physical_dependency)
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
        let certified_owned = bool_rank(ranks, layout.result_cell)
        let callable = input.callables.get(callable_index).unwrap()
        if !callable.has_body &&
           certified_owned != callable.result_owned_seed {
            panic("ResourcePlanner: certified callable owned result differs")
        }
        parameter = 0
        while parameter < layout.parameter_count {
            let certified_origin = bool_rank(
                ranks, layout.result_origin_start + parameter)
            if !callable.has_body && certified_origin != int_list_contains(
                    callable.result_origin_parameter_ordinals, parameter) {
                panic("ResourcePlanner: certified callable result origin differs")
            }
            parameter = parameter + 1
        }
        callable_results_owned.push(certified_owned)
        callable_result_type_indices.push(
            callable.result_type_index)
        callable_index = callable_index + 1
    }
    SolvedResourceGraph {
        fixed_point: fixed_point,
        logical_shapes: logical_shapes,
        physical_shapes: physical_shapes,
        callable_demands: callable_demands,
        callable_results_owned: callable_results_owned,
        callable_result_type_indices: callable_result_type_indices,
        bodies: materialize_solved_body_decisions(
            input.bodies, build.body_origin_layouts,
            build.callable_layouts, ranks)
    }
}

// Shared finite-set helpers used by the four resource planning components.
pub fn int_list_contains(values: List<Int>, target: Int) -> Bool {
    for value in values { if value == target { return true } }
    false
}


pub fn planner_type_is_callable(
    type_nodes: List<PlannerTypeNode>, type_index: Int
) -> Bool {
    planner_type_kind_tag(type_nodes.get(type_index).unwrap().kind) ==
        PLANNER_TYPE_CALLABLE
}

pub fn flow_callable_index_for_planner(
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

pub fn int_lists_same(left: List<Int>, right: List<Int>) -> Bool {
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
