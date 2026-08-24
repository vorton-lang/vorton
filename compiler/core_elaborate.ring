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

// ============================================================
// Exact deep-Clone plans
// ============================================================

pub struct CoreBodyHeader {
    reference: ExecutableRef,
    origin: OriginRef,
    binders: List<CoreBinder>,
    parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef,
    self_slot: SlotRef,
    body_origin: OriginRef,
    result_effects: CoreEffectSet
}

pub struct CoreNominalContract {
    graph: CoreTypeGraph,
    owner: RegisteredNominalRef,
    ty: CoreTypeRef,
    variants: List<VariantRef>
}

fn copy_variants(values: List<VariantRef>) -> List<VariantRef> {
    let mut result: List<VariantRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_core_nominal_contract(
    graph: CoreTypeGraph, owner: RegisteredNominalRef,
    ty: CoreTypeRef, variants: List<VariantRef>
) -> CoreNominalContract {
    let node = core_type_graph_node(graph, ty)
    if !symbol_ref_same(
            registered_nominal_ref_symbol(owner),
            flow_type_node_nominal(node)) {
        panic("CoreHIR elaboration: nominal contract owner/type differs")
    }
    let kind = flow_type_kind_tag(flow_type_node_kind(node))
    if kind == flow_type_kind_tag(flow_type_kind_struct()) {
        if variants.len() != 0 {
            panic("CoreHIR elaboration: struct contract carries variants")
        }
    } else if kind == flow_type_kind_tag(flow_type_kind_enum()) {
        let mut index = 0
        while index < variants.len() {
            if !registered_nominal_ref_same(
                    variant_ref_owner(variants.get(index).unwrap()), owner) ||
               (index > 0 &&
                variant_ref_source_index(variants.get(index).unwrap()) <=
                variant_ref_source_index(variants.get(index - 1).unwrap())) {
                panic("CoreHIR elaboration: variant contract owner/order differs")
            }
            index = index + 1
        }
    } else {
        panic("CoreHIR elaboration: nominal contract is not struct/enum")
    }
    CoreNominalContract {
        graph: copy_core_type_graph(graph), owner: owner, ty: ty,
        variants: copy_variants(variants)
    }
}

fn binder_type(values: List<CoreBinder>, target: SlotRef) -> CoreTypeRef {
    let mut found: CoreTypeRef? = none
    for binder in values {
        if slot_ref_same(core_binder_reference(binder), target) {
            if found.is_some() {
                panic("CoreHIR elaboration: binder is duplicated")
            }
            found = some(core_binder_type(binder))
        }
    }
    match found {
        some(value) => value,
        none => panic("CoreHIR elaboration: binder is undeclared")
    }
}

pub fn make_core_body_header(
    reference: ExecutableRef, origin: OriginRef,
    binders: List<CoreBinder>, parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef, self_slot: SlotRef,
    body_origin: OriginRef, result_effects: CoreEffectSet
) -> CoreBodyHeader {
    if parameter_slots.len() == 0 ||
       !slot_ref_same(parameter_slots.get(0).unwrap(), self_slot) ||
       !core_type_ref_same(binder_type(binders, self_slot), result_type) {
        panic("CoreHIR elaboration: Clone self parameter/type differs")
    }
    let mut self_params = 0
    for parameter in parameter_slots {
        if slot_ref_same(parameter, self_slot) { self_params = self_params + 1 }
    }
    if self_params != 1 {
        panic("CoreHIR elaboration: Clone self is not one exact parameter")
    }
    CoreBodyHeader {
        reference: reference, origin: origin,
        binders: copy_binders(binders),
        parameter_slots: copy_slot_refs(parameter_slots),
        result_type: result_type, self_slot: self_slot,
        body_origin: body_origin,
        result_effects: make_core_effect_set(core_effect_set_atoms(result_effects))
    }
}

// `binding` exists only for an enum payload binder introduced by an exact
// variant pattern. Struct fields remain nested projections and never allocate
// a Core temporary.
pub struct CoreCloneFieldPlan {
    field: CoreFieldRef,
    ty: CoreTypeRef,
    binding: SlotRef?,
    callee: CoreCalleeRef,
    method: MethodCallRef,
    evidence: List<CoreEvidenceRef>,
    effects: CoreEffectSet,
    origin: OriginRef
}

pub fn make_core_clone_field_plan(
    field: CoreFieldRef, ty: CoreTypeRef, binding: SlotRef?,
    callee: CoreCalleeRef, method: MethodCallRef,
    evidence: List<CoreEvidenceRef>, effects: CoreEffectSet,
    origin: OriginRef
) -> CoreCloneFieldPlan {
    CoreCloneFieldPlan {
        field: field, ty: ty, binding: binding,
        callee: callee, method: method,
        evidence: copy_evidence(evidence),
        effects: make_core_effect_set(core_effect_set_atoms(effects)),
        origin: origin
    }
}

fn copy_clone_field_plans(values: List<CoreCloneFieldPlan>) -> List<CoreCloneFieldPlan> {
    let mut result: List<CoreCloneFieldPlan> = []
    for value in values {
        result.push(CoreCloneFieldPlan {
            field: value.field, ty: value.ty, binding: value.binding,
            callee: value.callee, method: value.method,
            evidence: copy_evidence(value.evidence),
            effects: make_core_effect_set(core_effect_set_atoms(value.effects)),
            origin: value.origin
        })
    }
    result
}

fn require_unique_clone_fields(values: List<CoreCloneFieldPlan>) {
    let mut left_index = 0
    while left_index < values.len() {
        let left = values.get(left_index).unwrap()
        let mut right_index = left_index + 1
        while right_index < values.len() {
            let right = values.get(right_index).unwrap()
            let repeated_binding = match (left.binding, right.binding) {
                (some(left_slot), some(right_slot)) =>
                    slot_ref_same(left_slot, right_slot),
                _ => false
            }
            if core_field_ref_same(left.field, right.field) || repeated_binding {
                panic("CoreHIR elaboration: Clone field plan is not one-to-one")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
}

fn read_binder(ty: CoreTypeRef, origin: OriginRef, binder: SlotRef) -> CoreExpr {
    make_core_read_expr(ty, make_core_effect_set([]), origin, binder)
}

fn clone_field_value(value: CoreCloneFieldPlan, receiver: CoreExpr) -> CoreExpr {
    make_core_method_call_expr(
        value.ty, value.effects, value.origin,
        value.callee, value.method, receiver, [], value.evidence)
}

pub struct CoreStructClonePlan {
    header: CoreBodyHeader,
    contract: CoreNominalContract,
    constructor: CoreConstructorRef,
    fields: List<CoreCloneFieldPlan>
}

pub fn make_core_struct_clone_plan(
    header: CoreBodyHeader, contract: CoreNominalContract,
    constructor: CoreConstructorRef, fields: List<CoreCloneFieldPlan>
) -> CoreStructClonePlan {
    require_unique_clone_fields(fields)
    if !core_type_ref_same(header.result_type, contract.ty) ||
       core_constructor_kind_tag(constructor) != 0 ||
       !registered_nominal_ref_same(
            core_constructor_struct_owner(constructor), contract.owner) {
        panic("CoreHIR elaboration: struct Clone constructor/owner differs")
    }
    let mut expected_fields: List<CoreFieldRef> = []
    let mut expected_types: List<CoreTypeRef> = []
    for fact in flow_type_node_nominal_fields(
            core_type_graph_node(contract.graph, contract.ty)) {
        let identity = flow_nominal_field_identity(fact)
        if !flow_field_identity_is_nominal(identity) {
            panic("CoreHIR elaboration: struct contract has non-field identity")
        }
        expected_fields.push(make_core_nominal_field(
            flow_field_identity_nominal(identity)))
        expected_types.push(core_type_graph_ref_from_flow(
            contract.graph, flow_nominal_field_type(fact)))
    }
    if expected_fields.len() != fields.len() {
        panic("CoreHIR elaboration: struct Clone field census differs")
    }
    let mut field_index = 0
    while field_index < fields.len() {
        let field = fields.get(field_index).unwrap()
        if field.binding.is_some() || core_field_ref_kind_tag(field.field) != 0 ||
           !core_field_ref_same(
                expected_fields.get(field_index).unwrap(), field.field) ||
           !core_type_ref_same(
                expected_types.get(field_index).unwrap(), field.ty) {
            panic("CoreHIR elaboration: struct Clone field order differs")
        }
        field_index = field_index + 1
    }
    CoreStructClonePlan {
        header: header, contract: contract, constructor: constructor,
        fields: copy_clone_field_plans(fields)
    }
}

pub fn elaborate_core_struct_deep_clone(plan: CoreStructClonePlan) -> CoreElaboratedBody {
    let mut constructor_fields: List<CoreFieldValue> = []
    for field in plan.fields {
        let receiver = make_core_project_expr(
            field.ty, make_core_effect_set([]), field.origin,
            read_binder(plan.header.result_type, field.origin, plan.header.self_slot),
            field.field, false)
        constructor_fields.push(make_core_field_value(
            field.field, clone_field_value(field, receiver)))
    }
    let result = make_core_construct_expr(
        plan.header.result_type, plan.header.result_effects,
        plan.header.body_origin, plan.constructor, constructor_fields)
    let block = make_core_block([], some(result), plan.header.body_origin)
    let body = make_core_body(
        plan.header.reference, plan.header.origin, plan.header.binders,
        plan.header.parameter_slots, plan.header.result_type, block)
    validate_core_body(body)
    CoreElaboratedBody {
        kind: core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_CLONE),
        body: body
    }
}

pub struct CoreCloneVariantPlan {
    variant: VariantRef,
    constructor: CoreConstructorRef,
    fields: List<CoreCloneFieldPlan>,
    origin: OriginRef
}

pub fn make_core_clone_variant_plan(
    variant: VariantRef, constructor: CoreConstructorRef,
    fields: List<CoreCloneFieldPlan>, origin: OriginRef
) -> CoreCloneVariantPlan {
    require_unique_clone_fields(fields)
    for field in fields {
        if field.binding.is_none() {
            panic("CoreHIR elaboration: enum Clone field has no pattern binder")
        }
    }
    CoreCloneVariantPlan {
        variant: variant, constructor: constructor,
        fields: copy_clone_field_plans(fields), origin: origin
    }
}

fn copy_variant_plans(values: List<CoreCloneVariantPlan>) -> List<CoreCloneVariantPlan> {
    let mut result: List<CoreCloneVariantPlan> = []
    for value in values {
        result.push(CoreCloneVariantPlan {
            variant: value.variant, constructor: value.constructor,
            fields: copy_clone_field_plans(value.fields), origin: value.origin
        })
    }
    result
}

pub struct CoreEnumClonePlan {
    header: CoreBodyHeader,
    contract: CoreNominalContract,
    variants: List<CoreCloneVariantPlan>
}

pub fn make_core_enum_clone_plan(
    header: CoreBodyHeader, contract: CoreNominalContract,
    variants: List<CoreCloneVariantPlan>
) -> CoreEnumClonePlan {
    if variants.len() == 0 || variants.len() != contract.variants.len() ||
       !core_type_ref_same(header.result_type, contract.ty) {
        panic("CoreHIR elaboration: enum Clone has no variants")
    }
    let node = core_type_graph_node(contract.graph, contract.ty)
    let mut left_index = 0
    while left_index < variants.len() {
        let left = variants.get(left_index).unwrap()
        if !variant_ref_same(
                left.variant, contract.variants.get(left_index).unwrap()) ||
           !registered_nominal_ref_same(
                variant_ref_owner(left.variant), contract.owner) ||
           core_constructor_kind_tag(left.constructor) != 1 ||
           !variant_ref_same(
                core_constructor_variant(left.constructor), left.variant) {
            panic("CoreHIR elaboration: enum Clone variant/constructor differs")
        }
        let mut expected_fields: List<CoreFieldRef> = []
        let mut expected_types: List<CoreTypeRef> = []
        for fact in flow_type_node_nominal_fields(node) {
            let identity = flow_nominal_field_identity(fact)
            if flow_field_identity_is_variant(identity) &&
               variant_ref_same(
                    variant_field_ref_variant(
                        flow_field_identity_variant(identity)),
                    left.variant) {
                expected_fields.push(make_core_variant_field(
                    flow_field_identity_variant(identity)))
                expected_types.push(core_type_graph_ref_from_flow(
                    contract.graph, flow_nominal_field_type(fact)))
            }
        }
        if expected_fields.len() != left.fields.len() {
            panic("CoreHIR elaboration: variant Clone field census differs")
        }
        let mut field_index = 0
        while field_index < left.fields.len() {
            let field = left.fields.get(field_index).unwrap()
            let binding = match field.binding {
                some(value) => value,
                none => panic("CoreHIR elaboration: enum Clone field binder absent")
            }
            if !core_field_ref_same(
                    expected_fields.get(field_index).unwrap(), field.field) ||
               !core_type_ref_same(
                    expected_types.get(field_index).unwrap(), field.ty) ||
               !core_type_ref_same(binder_type(header.binders, binding), field.ty) {
                panic("CoreHIR elaboration: variant Clone field order differs")
            }
            field_index = field_index + 1
        }
        let mut right_index = left_index + 1
        while right_index < variants.len() {
            if variant_ref_same(left.variant, variants.get(right_index).unwrap().variant) {
                panic("CoreHIR elaboration: enum Clone repeats a variant")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    CoreEnumClonePlan {
        header: header, contract: contract, variants: copy_variant_plans(variants)
    }
}

pub fn elaborate_core_enum_deep_clone(plan: CoreEnumClonePlan) -> CoreElaboratedBody {
    let mut arms: List<CoreMatchArm> = []
    for variant in plan.variants {
        let mut pattern_fields = []
        let mut constructor_fields: List<CoreFieldValue> = []
        for field in variant.fields {
            let binding = match field.binding {
                some(value) => value,
                none => panic("CoreHIR elaboration: enum Clone field binder absent")
            }
            pattern_fields.push(make_core_pattern_field(
                field.field, make_core_binding_pattern(field.ty, binding)))
            constructor_fields.push(make_core_field_value(
                field.field, clone_field_value(
                    field, read_binder(field.ty, field.origin, binding))))
        }
        let pattern = make_core_variant_pattern(
            plan.header.result_type, variant.variant, pattern_fields)
        let constructed = make_core_construct_expr(
            plan.header.result_type, plan.header.result_effects,
            variant.origin, variant.constructor, constructor_fields)
        let arm_body = make_core_block([], some(constructed), variant.origin)
        arms.push(make_core_match_arm(pattern, none, arm_body, variant.origin))
    }
    let matched = make_core_match_expr(
        plan.header.result_type, plan.header.result_effects,
        plan.header.body_origin,
        read_binder(
            plan.header.result_type, plan.header.body_origin,
            plan.header.self_slot),
        arms)
    let block = make_core_block([], some(matched), plan.header.body_origin)
    let body = make_core_body(
        plan.header.reference, plan.header.origin, plan.header.binders,
        plan.header.parameter_slots, plan.header.result_type, block)
    validate_core_body(body)
    CoreElaboratedBody {
        kind: core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_CLONE),
        body: body
    }
}
