// Pure 0.1 semantic elaboration into ordinary structured CoreHIR bodies.
//
// Trait/default and non-Clone derived bodies arrive as already-explicit Core
// trees from their unique typed producer. Derived Clone is elaborated here so
// field completeness and deep-copy semantics are visible before FlowIR: every
// payload is projected or pattern-bound, passed to one exact MethodCallRef, and
// assembled into a fresh exact constructor. Core never contains administrative
// result temporaries, Flow scopes, resource operations, or name/span fallback.

use ir_identity::{
    SlotRef, OriginRef, RegisteredNominalRef, VariantRef,
    slot_ref_same, symbol_ref_same,
    registered_nominal_ref_same, registered_nominal_ref_symbol,
    variant_ref_owner, variant_ref_same, variant_ref_source_index,
    variant_field_ref_variant
}
use ir_inventory::{ExecutableRef}
use hir::{MethodCallRef}
use core_expr::{
    CoreTypeRef, CoreTypeGraph, CoreEffectSet, CoreCalleeRef, CoreEvidenceRef,
    CoreFieldRef, CoreFieldValue, CoreConstructorRef,
    CoreBinder, CoreBody, CoreStmt, CoreExpr, CoreMatchArm,
    make_core_effect_set, core_effect_set_atoms,
    make_core_field_value,
    make_core_nominal_field, make_core_variant_field,
    make_core_binding_pattern,
    make_core_pattern_field, make_core_variant_pattern,
    make_core_read_expr, make_core_project_expr, make_core_method_call_expr,
    make_core_construct_expr, make_core_match_expr,
    make_core_block, make_core_match_arm,
    make_core_body, validate_core_body,
    core_field_ref_kind_tag, core_field_ref_same,
    core_constructor_kind_tag, core_constructor_struct_owner,
    core_constructor_variant,
    core_binder_reference, core_binder_type,
    core_type_graph_node,
    copy_core_type_graph, core_type_graph_ref_from_flow,
    core_type_ref_same
}
use flow_ir::{
    flow_type_node_kind, flow_type_node_nominal,
    flow_type_node_nominal_fields,
    flow_type_kind_tag, flow_type_kind_struct, flow_type_kind_enum,
    flow_nominal_field_identity, flow_nominal_field_type,
    flow_field_identity_is_nominal, flow_field_identity_nominal,
    flow_field_identity_is_variant, flow_field_identity_variant
}

const CORE_ELAB_TRAIT_DEFAULT: Int = 0
const CORE_ELAB_DEFAULT_SPECIALIZATION: Int = 1
const CORE_ELAB_DERIVED_EQ: Int = 2
const CORE_ELAB_DERIVED_NE: Int = 3
const CORE_ELAB_DERIVED_HASH: Int = 4
const CORE_ELAB_DERIVED_CLONE: Int = 5
const CORE_ELAB_DERIVED_ORD: Int = 6
const CORE_ELAB_DERIVED_DEBUG: Int = 7
const CORE_ELAB_DERIVED_JSON: Int = 8

pub struct CoreElaborationKind { tag: Int }

fn core_elaboration_kind_from_tag(tag: Int) -> CoreElaborationKind {
    if tag < CORE_ELAB_TRAIT_DEFAULT || tag > CORE_ELAB_DERIVED_JSON {
        panic("CoreHIR elaboration: invalid 0.1 body kind")
    }
    CoreElaborationKind { tag: tag }
}
pub fn core_elaboration_kind_tag(value: CoreElaborationKind) -> Int {
    core_elaboration_kind_from_tag(value.tag).tag
}

pub struct CoreElaboratedBody {
    kind: CoreElaborationKind,
    body: CoreBody
}

pub struct CoreOrdinaryBodyPlan {
    reference: ExecutableRef,
    origin: OriginRef,
    binders: List<CoreBinder>,
    parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef,
    statements: List<CoreStmt>,
    tail: CoreExpr?,
    body_origin: OriginRef
}

fn copy_binders(values: List<CoreBinder>) -> List<CoreBinder> {
    let mut result: List<CoreBinder> = []
    for value in values { result.push(value) }
    result
}
fn copy_slot_refs(values: List<SlotRef>) -> List<SlotRef> {
    let mut result: List<SlotRef> = []
    for value in values { result.push(value) }
    result
}
fn copy_statements(values: List<CoreStmt>) -> List<CoreStmt> {
    let mut result: List<CoreStmt> = []
    for value in values { result.push(value) }
    result
}
fn copy_evidence(values: List<CoreEvidenceRef>) -> List<CoreEvidenceRef> {
    let mut result: List<CoreEvidenceRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_core_ordinary_body_plan(
    reference: ExecutableRef, origin: OriginRef,
    binders: List<CoreBinder>, parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef, statements: List<CoreStmt>, tail: CoreExpr?,
    body_origin: OriginRef
) -> CoreOrdinaryBodyPlan {
    CoreOrdinaryBodyPlan {
        reference: reference, origin: origin,
        binders: copy_binders(binders),
        parameter_slots: copy_slot_refs(parameter_slots),
        result_type: result_type, statements: copy_statements(statements),
        tail: tail, body_origin: body_origin
    }
}

fn make_explicit_elaborated_body(
    kind: CoreElaborationKind, plan: CoreOrdinaryBodyPlan
) -> CoreElaboratedBody {
    if kind.tag == CORE_ELAB_DERIVED_CLONE {
        panic("CoreHIR elaboration: derived Clone requires a deep plan")
    }
    let block = make_core_block(plan.statements, plan.tail, plan.body_origin)
    let body = make_core_body(
        plan.reference, plan.origin, plan.binders, plan.parameter_slots,
        plan.result_type, block)
    validate_core_body(body)
    CoreElaboratedBody { kind: kind, body: body }
}

pub fn elaborate_core_trait_default(plan: CoreOrdinaryBodyPlan) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_TRAIT_DEFAULT), plan)
}
pub fn elaborate_core_default_specialization(
    plan: CoreOrdinaryBodyPlan
) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DEFAULT_SPECIALIZATION), plan)
}
pub fn elaborate_core_derived_eq(plan: CoreOrdinaryBodyPlan) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_EQ), plan)
}
pub fn elaborate_core_derived_ne(plan: CoreOrdinaryBodyPlan) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_NE), plan)
}
pub fn elaborate_core_derived_hash(plan: CoreOrdinaryBodyPlan) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_HASH), plan)
}
pub fn elaborate_core_derived_ord(plan: CoreOrdinaryBodyPlan) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_ORD), plan)
}
pub fn elaborate_core_derived_debug(plan: CoreOrdinaryBodyPlan) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_DEBUG), plan)
}
pub fn elaborate_core_derived_json(plan: CoreOrdinaryBodyPlan) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_JSON), plan)
}
pub fn core_elaborated_body_kind(value: CoreElaboratedBody) -> CoreElaborationKind {
    value.kind
}
pub fn core_elaborated_body(value: CoreElaboratedBody) -> CoreBody { value.body }
