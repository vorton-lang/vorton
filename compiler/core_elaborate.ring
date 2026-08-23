// Pure 0.1 semantic elaboration into ordinary CoreHIR bodies.
//
// Trait/default and non-Clone derived bodies arrive as already-explicit Core
// bodies from their unique typed producer.  Derived Clone uses the specialised
// plans below so the elaborator itself proves field-complete deep cloning: each
// payload is obtained by an exact projection/pattern binding, passed through an
// exact MethodCallRef, and assembled into a new exact constructor.  There is no
// shallow/resource-clone operation in CoreHIR.

use ir_identity::{
    SlotRef, OriginRef, RegisteredNominalRef,
    slot_ref_same, registered_nominal_ref_same
}
use ir_inventory::{ExecutableRef, BinderManifest}
use hir::{MethodCallRef}
use core_expr::{
    CoreTypeRef, CoreEffectSet, CoreCalleeRef, CoreEvidenceRef,
    CoreFieldRef, CoreFieldValue, CoreConstructorRef, CoreVariantRef,
    CoreSlot, CoreBody, CoreBlock, CoreStmt, CoreExpr, CoreMatchArm,
    make_core_effect_set, core_effect_set_atoms,
    make_core_field_value,
    make_core_nominal_field, make_core_binding_pattern,
    make_core_pattern_field, make_core_struct_pattern,
    make_core_variant_pattern,
    make_core_project_expr, make_core_method_call_expr,
    make_core_construct_expr, make_core_match_expr,
    make_core_initialize_stmt, make_core_block, make_core_match_arm,
    make_core_body, validate_core_body,
    core_field_ref_kind_tag, core_field_ref_same,
    core_constructor_kind_tag, core_constructor_struct_owner,
    core_constructor_variant,
    core_variant_owner, core_variant_ref_same,
    core_body_reference, core_body_origin, core_slot_reference
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
    type_count: Int,
    manifest: BinderManifest,
    slots: List<CoreSlot>,
    parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef,
    statements: List<CoreStmt>,
    tail: CoreExpr?,
    body_origin: OriginRef
}

fn copy_statements(values: List<CoreStmt>) -> List<CoreStmt> {
    let mut result: List<CoreStmt> = []
    for value in values { result.push(value) }
    result
}

pub fn make_core_ordinary_body_plan(
    reference: ExecutableRef, origin: OriginRef, type_count: Int,
    manifest: BinderManifest, slots: List<CoreSlot>,
    parameter_slots: List<SlotRef>, result_type: CoreTypeRef,
    statements: List<CoreStmt>, tail: CoreExpr?, body_origin: OriginRef
) -> CoreOrdinaryBodyPlan {
    CoreOrdinaryBodyPlan {
        reference: reference, origin: origin, type_count: type_count,
        manifest: manifest, slots: copy_slots(slots),
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
    let block = make_core_block(
        plan.statements, plan.tail, plan.body_origin)
    let body = make_core_body(
        plan.reference, plan.origin, plan.type_count,
        plan.manifest, plan.slots, plan.parameter_slots,
        plan.result_type, block)
    validate_core_body(body)
    CoreElaboratedBody { kind: kind, body: body }
}

pub fn elaborate_core_trait_default(
    plan: CoreOrdinaryBodyPlan
) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_TRAIT_DEFAULT), plan)
}
pub fn elaborate_core_default_specialization(
    plan: CoreOrdinaryBodyPlan
) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DEFAULT_SPECIALIZATION), plan)
}
pub fn elaborate_core_derived_eq(
    plan: CoreOrdinaryBodyPlan
) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_EQ), plan)
}
pub fn elaborate_core_derived_ne(
    plan: CoreOrdinaryBodyPlan
) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_NE), plan)
}
pub fn elaborate_core_derived_hash(
    plan: CoreOrdinaryBodyPlan
) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_HASH), plan)
}
pub fn elaborate_core_derived_ord(
    plan: CoreOrdinaryBodyPlan
) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_ORD), plan)
}
pub fn elaborate_core_derived_debug(
    plan: CoreOrdinaryBodyPlan
) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_DEBUG), plan)
}
pub fn elaborate_core_derived_json(
    plan: CoreOrdinaryBodyPlan
) -> CoreElaboratedBody {
    make_explicit_elaborated_body(
        core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_JSON), plan)
}
pub fn core_elaborated_body_kind(
    value: CoreElaboratedBody
) -> CoreElaborationKind { value.kind }
pub fn core_elaborated_body(value: CoreElaboratedBody) -> CoreBody { value.body }

// ============================================================
// Exact deep-Clone plans
// ============================================================

pub struct CoreBodyHeader {
    reference: ExecutableRef,
    origin: OriginRef,
    type_count: Int,
    manifest: BinderManifest,
    slots: List<CoreSlot>,
    parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef,
    self_slot: SlotRef,
    result_slot: SlotRef,
    body_origin: OriginRef,
    result_effects: CoreEffectSet
}

fn copy_slots(values: List<CoreSlot>) -> List<CoreSlot> {
    let mut result: List<CoreSlot> = []
    for value in values { result.push(value) }
    result
}
fn copy_slot_refs(values: List<SlotRef>) -> List<SlotRef> {
    let mut result: List<SlotRef> = []
    for value in values { result.push(value) }
    result
}
fn copy_evidence(values: List<CoreEvidenceRef>) -> List<CoreEvidenceRef> {
    let mut result: List<CoreEvidenceRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_core_body_header(
    reference: ExecutableRef, origin: OriginRef, type_count: Int,
    manifest: BinderManifest, slots: List<CoreSlot>,
    parameter_slots: List<SlotRef>, result_type: CoreTypeRef,
    self_slot: SlotRef, result_slot: SlotRef,
    body_origin: OriginRef, result_effects: CoreEffectSet
) -> CoreBodyHeader {
    if slot_ref_same(self_slot, result_slot) {
        panic("CoreHIR elaboration: Clone self/result slots alias")
    }
    let mut self_params = 0
    for parameter in parameter_slots {
        if slot_ref_same(parameter, self_slot) { self_params = self_params + 1 }
    }
    if self_params != 1 {
        panic("CoreHIR elaboration: Clone self is not one exact parameter")
    }
    let mut self_declared = 0
    let mut result_declared = 0
    for slot in slots {
        if slot_ref_same(core_slot_reference(slot), self_slot) {
            self_declared = self_declared + 1
        }
        if slot_ref_same(core_slot_reference(slot), result_slot) {
            result_declared = result_declared + 1
        }
    }
    if self_declared != 1 || result_declared != 1 {
        panic("CoreHIR elaboration: Clone self/result slot census differs")
    }
    CoreBodyHeader {
        reference: reference, origin: origin, type_count: type_count,
        manifest: manifest, slots: copy_slots(slots),
        parameter_slots: copy_slot_refs(parameter_slots),
        result_type: result_type, self_slot: self_slot,
        result_slot: result_slot, body_origin: body_origin,
        result_effects: make_core_effect_set(
            core_effect_set_atoms(result_effects))
    }
}

pub struct CoreCloneFieldPlan {
    field: CoreFieldRef,
    ty: CoreTypeRef,
    source_slot: SlotRef,
    cloned_slot: SlotRef,
    callee: CoreCalleeRef,
    method: MethodCallRef,
    evidence: List<CoreEvidenceRef>,
    effects: CoreEffectSet,
    origin: OriginRef
}

pub fn make_core_clone_field_plan(
    field: CoreFieldRef, ty: CoreTypeRef,
    source_slot: SlotRef, cloned_slot: SlotRef,
    callee: CoreCalleeRef, method: MethodCallRef,
    evidence: List<CoreEvidenceRef>, effects: CoreEffectSet,
    origin: OriginRef
) -> CoreCloneFieldPlan {
    if slot_ref_same(source_slot, cloned_slot) {
        panic("CoreHIR elaboration: Clone field source/result alias")
    }
    CoreCloneFieldPlan {
        field: field, ty: ty, source_slot: source_slot,
        cloned_slot: cloned_slot, callee: callee, method: method,
        evidence: copy_evidence(evidence),
        effects: make_core_effect_set(core_effect_set_atoms(effects)),
        origin: origin
    }
}

fn copy_clone_field_plans(
    values: List<CoreCloneFieldPlan>
) -> List<CoreCloneFieldPlan> {
    let mut result: List<CoreCloneFieldPlan> = []
    for value in values {
        result.push(CoreCloneFieldPlan {
            field: value.field, ty: value.ty,
            source_slot: value.source_slot, cloned_slot: value.cloned_slot,
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
            if core_field_ref_same(left.field, right.field) ||
               slot_ref_same(left.source_slot, right.source_slot) ||
               slot_ref_same(left.cloned_slot, right.cloned_slot) {
                panic("CoreHIR elaboration: Clone field plan is not one-to-one")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
}

fn clone_field_statements(
    value: CoreCloneFieldPlan, include_projection: Bool,
    base: SlotRef
) -> List<CoreStmt> {
    let mut statements: List<CoreStmt> = []
    if include_projection {
        let projected = make_core_project_expr(
            value.source_slot, value.ty, make_core_effect_set([]),
            value.origin, base, value.field, false)
        statements.push(make_core_initialize_stmt(
            value.source_slot, projected, value.origin))
    }
    let cloned = make_core_method_call_expr(
        value.cloned_slot, value.ty, value.effects, value.origin,
        value.callee, value.method, value.source_slot, [], value.evidence)
    statements.push(make_core_initialize_stmt(
        value.cloned_slot, cloned, value.origin))
    statements
}

pub struct CoreStructClonePlan {
    header: CoreBodyHeader,
    owner: RegisteredNominalRef,
    constructor: CoreConstructorRef,
    fields: List<CoreCloneFieldPlan>
}

pub fn make_core_struct_clone_plan(
    header: CoreBodyHeader, owner: RegisteredNominalRef,
    constructor: CoreConstructorRef,
    expected_fields: List<CoreFieldRef>, fields: List<CoreCloneFieldPlan>
) -> CoreStructClonePlan {
    require_unique_clone_fields(fields)
    if core_constructor_kind_tag(constructor) != 0 ||
       !registered_nominal_ref_same(
            core_constructor_struct_owner(constructor), owner) {
        panic("CoreHIR elaboration: struct Clone constructor/owner differs")
    }
    if expected_fields.len() != fields.len() {
        panic("CoreHIR elaboration: struct Clone field census differs")
    }
    let mut field_index = 0
    while field_index < fields.len() {
        let field = fields.get(field_index).unwrap()
        if core_field_ref_kind_tag(field.field) != 0 {
            panic("CoreHIR elaboration: struct Clone has non-nominal field")
        }
        if !core_field_ref_same(
                expected_fields.get(field_index).unwrap(), field.field) {
            panic("CoreHIR elaboration: struct Clone field order differs")
        }
        field_index = field_index + 1
    }
    CoreStructClonePlan {
        header: header, owner: owner, constructor: constructor,
        fields: copy_clone_field_plans(fields)
    }
}

pub fn elaborate_core_struct_deep_clone(
    plan: CoreStructClonePlan
) -> CoreElaboratedBody {
    let mut statements: List<CoreStmt> = []
    let mut constructor_fields: List<CoreFieldValue> = []
    for field in plan.fields {
        for statement in clone_field_statements(
                field, true, plan.header.self_slot) {
            statements.push(statement)
        }
        constructor_fields.push(make_core_field_value(
            field.field, field.cloned_slot))
    }
    let result = make_core_construct_expr(
        plan.header.result_slot, plan.header.result_type,
        plan.header.result_effects, plan.header.body_origin,
        plan.constructor, constructor_fields)
    let block = make_core_block(
        statements, some(result), plan.header.body_origin)
    let body = make_core_body(
        plan.header.reference, plan.header.origin, plan.header.type_count,
        plan.header.manifest, plan.header.slots,
        plan.header.parameter_slots, plan.header.result_type, block)
    CoreElaboratedBody {
        kind: core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_CLONE),
        body: body
    }
}

pub struct CoreCloneVariantPlan {
    variant: CoreVariantRef,
    constructor: CoreConstructorRef,
    fields: List<CoreCloneFieldPlan>,
    origin: OriginRef
}

pub fn make_core_clone_variant_plan(
    variant: CoreVariantRef, constructor: CoreConstructorRef,
    expected_fields: List<CoreFieldRef>, fields: List<CoreCloneFieldPlan>,
    origin: OriginRef
) -> CoreCloneVariantPlan {
    require_unique_clone_fields(fields)
    if expected_fields.len() != fields.len() {
        panic("CoreHIR elaboration: variant Clone field census differs")
    }
    let mut field_index = 0
    while field_index < fields.len() {
        if !core_field_ref_same(
                expected_fields.get(field_index).unwrap(),
                fields.get(field_index).unwrap().field) {
            panic("CoreHIR elaboration: variant Clone field order differs")
        }
        field_index = field_index + 1
    }
    CoreCloneVariantPlan {
        variant: variant, constructor: constructor,
        fields: copy_clone_field_plans(fields), origin: origin
    }
}

fn copy_variant_plans(
    values: List<CoreCloneVariantPlan>
) -> List<CoreCloneVariantPlan> {
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
    owner: RegisteredNominalRef,
    variants: List<CoreCloneVariantPlan>
}

pub fn make_core_enum_clone_plan(
    header: CoreBodyHeader, owner: RegisteredNominalRef,
    variants: List<CoreCloneVariantPlan>
) -> CoreEnumClonePlan {
    if variants.len() == 0 {
        panic("CoreHIR elaboration: enum Clone has no variants")
    }
    let mut left_index = 0
    while left_index < variants.len() {
        let left = variants.get(left_index).unwrap()
        if !registered_nominal_ref_same(core_variant_owner(left.variant), owner) ||
           core_constructor_kind_tag(left.constructor) != 1 ||
           !core_variant_ref_same(
                core_constructor_variant(left.constructor), left.variant) {
            panic("CoreHIR elaboration: enum Clone variant/constructor differs")
        }
        let mut right_index = left_index + 1
        while right_index < variants.len() {
            if core_variant_ref_same(
                    left.variant, variants.get(right_index).unwrap().variant) {
                panic("CoreHIR elaboration: enum Clone repeats a variant")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    CoreEnumClonePlan {
        header: header, owner: owner, variants: copy_variant_plans(variants)
    }
}

pub fn elaborate_core_enum_deep_clone(
    plan: CoreEnumClonePlan
) -> CoreElaboratedBody {
    let mut arms: List<CoreMatchArm> = []
    for variant in plan.variants {
        let mut pattern_fields = []
        let mut statements: List<CoreStmt> = []
        let mut constructor_fields: List<CoreFieldValue> = []
        for field in variant.fields {
            pattern_fields.push(make_core_pattern_field(
                field.field, make_core_binding_pattern(field.source_slot)))
            for statement in clone_field_statements(
                    field, false, plan.header.self_slot) {
                statements.push(statement)
            }
            constructor_fields.push(make_core_field_value(
                field.field, field.cloned_slot))
        }
        let pattern = make_core_variant_pattern(
            variant.variant, pattern_fields)
        let constructed = make_core_construct_expr(
            plan.header.result_slot, plan.header.result_type,
            plan.header.result_effects, variant.origin,
            variant.constructor, constructor_fields)
        let arm_body = make_core_block(
            statements, some(constructed), variant.origin)
        arms.push(make_core_match_arm(
            pattern, none, arm_body, variant.origin))
    }
    let matched = make_core_match_expr(
        plan.header.result_slot, plan.header.result_type,
        plan.header.result_effects, plan.header.body_origin,
        plan.header.self_slot, arms)
    let block = make_core_block(
        [], some(matched), plan.header.body_origin)
    let body = make_core_body(
        plan.header.reference, plan.header.origin, plan.header.type_count,
        plan.header.manifest, plan.header.slots,
        plan.header.parameter_slots, plan.header.result_type, block)
    CoreElaboratedBody {
        kind: core_elaboration_kind_from_tag(CORE_ELAB_DERIVED_CLONE),
        body: body
    }
}
