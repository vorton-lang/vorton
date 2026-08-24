// Exact 0.1 derived-trait elaboration into ordinary structured Core bodies.
//
// This module owns no resolver, type, layout, field-name, or backend policy.
// Every method, projection, constructor, evidence value, binder, literal
// segment, and variant discriminator is supplied by the typed producer. The
// elaborator only assembles those closed facts into ordinary CoreExpr trees.

use ir_identity::{
    SlotRef, OriginRef, RegisteredNominalRef, VariantRef,
    slot_ref_same, variant_ref_same,
    registered_nominal_ref_same
}
use ir_inventory::{ExecutableRef}
use hir::{MethodCallRef}
use core_expr::{
    CoreTypeRef, CoreEffectSet, CoreCalleeRef, CoreEvidenceRef,
    CoreFieldRef, CoreFieldValue, CoreConstructorRef,
    CoreBinder, CoreBody, CoreBlock, CoreStmt, CoreExpr,
    CorePattern, CorePatternField, CoreMatchArm,
    make_core_effect_set, core_effect_set_atoms,
    make_core_read_expr, make_core_project_expr,
    make_core_call_expr, make_core_method_call_expr,
    make_core_construct_expr, make_core_if_expr, make_core_match_expr,
    make_core_block_expr,
    make_core_primitive_expr, make_core_primitive_op,
    make_core_literal_expr, make_core_int_literal,
    make_core_str_literal, make_core_bool_literal,
    make_core_binding_pattern, make_core_wildcard_pattern,
    make_core_pattern_field, make_core_variant_pattern,
    make_core_field_value, make_core_match_arm,
    make_core_block, make_core_bind_stmt, make_core_expr_stmt,
    make_core_body, validate_core_body,
    core_binder_reference, core_binder_type,
    core_field_ref_same, core_type_ref_same
}
use core_elaborate::{
    CoreStructClonePlan, CoreEnumClonePlan,
    elaborate_core_struct_deep_clone, elaborate_core_enum_deep_clone,
    core_elaborated_body
}

fn copy_binders(values: List<CoreBinder>) -> List<CoreBinder> {
    let mut result: List<CoreBinder> = []
    for value in values { result.push(value) }
    result
}
fn copy_slots(values: List<SlotRef>) -> List<SlotRef> {
    let mut result: List<SlotRef> = []
    for value in values { result.push(value) }
    result
}
fn copy_evidence(values: List<CoreEvidenceRef>) -> List<CoreEvidenceRef> {
    let mut result: List<CoreEvidenceRef> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreDerivedHeader {
    reference: ExecutableRef,
    origin: OriginRef,
    binders: List<CoreBinder>,
    parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef,
    self_slot: SlotRef,
    other_slot: SlotRef?,
    body_origin: OriginRef,
    result_effects: CoreEffectSet
}

fn binder_type(values: List<CoreBinder>, target: SlotRef) -> CoreTypeRef {
    let mut result: CoreTypeRef? = none
    for binder in values {
        if slot_ref_same(core_binder_reference(binder), target) {
            if result.is_some() {
                panic("Core derive: binder identity is duplicated")
            }
            result = some(core_binder_type(binder))
        }
    }
    match result {
        some(value) => value,
        none => panic("Core derive: binder identity is absent")
    }
}

pub fn make_core_derived_header(
    reference: ExecutableRef, origin: OriginRef,
    binders: List<CoreBinder>, parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef, self_slot: SlotRef, other_slot: SlotRef?,
    body_origin: OriginRef, result_effects: CoreEffectSet
) -> CoreDerivedHeader {
    if parameter_slots.len() == 0 ||
       !slot_ref_same(parameter_slots.get(0).unwrap(), self_slot) {
        panic("Core derive: self is not the first exact parameter")
    }
    let _ = binder_type(binders, self_slot)
    match other_slot {
        some(other) => {
            if parameter_slots.len() < 2 ||
               !slot_ref_same(parameter_slots.get(1).unwrap(), other) ||
               slot_ref_same(self_slot, other) {
                panic("Core derive: other parameter relation differs")
            }
            let _ = binder_type(binders, other)
        },
        none => {}
    }
    CoreDerivedHeader {
        reference: reference, origin: origin,
        binders: copy_binders(binders),
        parameter_slots: copy_slots(parameter_slots),
        result_type: result_type, self_slot: self_slot,
        other_slot: other_slot, body_origin: body_origin,
        result_effects: make_core_effect_set(
            core_effect_set_atoms(result_effects))
    }
}

pub struct CoreDerivedValueRef {
    root: SlotRef,
    root_type: CoreTypeRef,
    projections: List<CoreFieldRef>,
    projection_types: List<CoreTypeRef>,
    ty: CoreTypeRef,
    origin: OriginRef
}

fn copy_fields(values: List<CoreFieldRef>) -> List<CoreFieldRef> {
    let mut result: List<CoreFieldRef> = []
    for value in values { result.push(value) }
    result
}
fn copy_types(values: List<CoreTypeRef>) -> List<CoreTypeRef> {
    let mut result: List<CoreTypeRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_core_derived_value_ref(
    root: SlotRef, root_type: CoreTypeRef,
    projections: List<CoreFieldRef>, projection_types: List<CoreTypeRef>,
    ty: CoreTypeRef, origin: OriginRef
) -> CoreDerivedValueRef {
    if projections.len() != projection_types.len() ||
       (projections.len() == 0 && !core_type_ref_same(root_type, ty)) ||
       (projections.len() > 0 && !core_type_ref_same(
            projection_types.get(projection_types.len() - 1).unwrap(), ty)) {
        panic("Core derive: value projection type path differs")
    }
    CoreDerivedValueRef {
        root: root, root_type: root_type,
        projections: copy_fields(projections),
        projection_types: copy_types(projection_types),
        ty: ty, origin: origin
    }
}

fn derived_value_expr(value: CoreDerivedValueRef) -> CoreExpr {
    let mut result = make_core_read_expr(
        value.root_type, make_core_effect_set([]), value.origin, value.root)
    let mut index = 0
    while index < value.projections.len() {
        result = make_core_project_expr(
            value.projection_types.get(index).unwrap(),
            make_core_effect_set([]), value.origin, result,
            value.projections.get(index).unwrap(), false)
        index = index + 1
    }
    result
}

pub struct CoreDerivedCallPlan {
    callee: CoreCalleeRef,
    method: MethodCallRef?,
    result_type: CoreTypeRef,
    effects: CoreEffectSet,
    evidence: List<CoreEvidenceRef>,
    origin: OriginRef
}

pub fn make_core_derived_call_plan(
    callee: CoreCalleeRef, method: MethodCallRef?,
    result_type: CoreTypeRef, effects: CoreEffectSet,
    evidence: List<CoreEvidenceRef>, origin: OriginRef
) -> CoreDerivedCallPlan {
    CoreDerivedCallPlan {
        callee: callee, method: method, result_type: result_type,
        effects: make_core_effect_set(core_effect_set_atoms(effects)),
        evidence: copy_evidence(evidence), origin: origin
    }
}

fn derived_call(
    plan: CoreDerivedCallPlan, arguments: List<CoreExpr>
) -> CoreExpr {
    match plan.method {
        some(method) => {
            if arguments.len() == 0 {
                panic("Core derive: exact method call has no receiver")
            }
            let receiver = arguments.get(0).unwrap()
            let mut params: List<CoreExpr> = []
            let mut index = 1
            while index < arguments.len() {
                params.push(arguments.get(index).unwrap())
                index = index + 1
            }
            make_core_method_call_expr(
                plan.result_type, plan.effects, plan.origin,
                plan.callee, method, receiver, params, plan.evidence)
        },
        none => make_core_call_expr(
            plan.result_type, plan.effects, plan.origin,
            plan.callee, arguments, plan.evidence)
    }
}

pub struct CoreDerivedFieldPlan {
    field: CoreFieldRef,
    ty: CoreTypeRef,
    left: CoreDerivedValueRef,
    right: CoreDerivedValueRef?,
    operation: CoreDerivedCallPlan
}

pub fn make_core_derived_field_plan(
    field: CoreFieldRef, ty: CoreTypeRef,
    left: CoreDerivedValueRef, right: CoreDerivedValueRef?,
    operation: CoreDerivedCallPlan
) -> CoreDerivedFieldPlan {
    if !core_type_ref_same(left.ty, ty) ||
       match right {
            some(value) => !core_type_ref_same(value.ty, ty),
            none => false
       } {
        panic("Core derive: field operand type differs")
    }
    if operation.method.is_none() {
        panic("Core derive: field operation lacks exact MethodCallRef")
    }
    if left.projections.len() > 0 && !core_field_ref_same(
            left.projections.get(left.projections.len() - 1).unwrap(), field) {
        panic("Core derive: left projection does not end at exact field")
    }
    match right {
        some(value) => if value.projections.len() > 0 &&
            !core_field_ref_same(
                value.projections.get(value.projections.len() - 1).unwrap(),
                field) {
            panic("Core derive: right projection does not end at exact field")
        },
        none => {}
    }
    CoreDerivedFieldPlan {
        field: field, ty: ty, left: left, right: right,
        operation: operation
    }
}

fn copy_derived_fields(
    values: List<CoreDerivedFieldPlan>
) -> List<CoreDerivedFieldPlan> {
    let mut result: List<CoreDerivedFieldPlan> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreDerivedVariantPlan {
    variant: VariantRef,
    left_pattern_slots: List<SlotRef>,
    right_pattern_slots: List<SlotRef>,
    fields: List<CoreDerivedFieldPlan>,
    discriminator: Int,
    origin: OriginRef
}

pub fn make_core_derived_variant_plan(
    variant: VariantRef,
    left_pattern_slots: List<SlotRef>, right_pattern_slots: List<SlotRef>,
    fields: List<CoreDerivedFieldPlan>, discriminator: Int,
    origin: OriginRef
) -> CoreDerivedVariantPlan {
    if left_pattern_slots.len() != fields.len() ||
       (right_pattern_slots.len() != 0 &&
        right_pattern_slots.len() != fields.len()) {
        panic("Core derive: variant pattern/field census differs")
    }
    CoreDerivedVariantPlan {
        variant: variant,
        left_pattern_slots: copy_slots(left_pattern_slots),
        right_pattern_slots: copy_slots(right_pattern_slots),
        fields: copy_derived_fields(fields),
        discriminator: discriminator, origin: origin
    }
}

fn copy_variants(
    values: List<CoreDerivedVariantPlan>
) -> List<CoreDerivedVariantPlan> {
    let mut result: List<CoreDerivedVariantPlan> = []
    for value in values { result.push(value) }
    result
}

fn require_unique_variants(values: List<CoreDerivedVariantPlan>) {
    let mut left = 0
    while left < values.len() {
        let mut right = left + 1
        while right < values.len() {
            if variant_ref_same(
                    values.get(left).unwrap().variant,
                    values.get(right).unwrap().variant) ||
               values.get(left).unwrap().discriminator ==
                    values.get(right).unwrap().discriminator {
                panic("Core derive: enum variant/discriminator is duplicated")
            }
            right = right + 1
        }
        left = left + 1
    }
}

enum CoreDerivedShapeValue {
    StructShape(List<CoreDerivedFieldPlan>),
    EnumShape(List<CoreDerivedVariantPlan>)
}

fn require_unique_fields(values: List<CoreDerivedFieldPlan>) {
    let mut left = 0
    while left < values.len() {
        let mut right = left + 1
        while right < values.len() {
            if core_field_ref_same(
                    values.get(left).unwrap().field,
                    values.get(right).unwrap().field) {
                panic("Core derive: field identity is duplicated")
            }
            right = right + 1
        }
        left = left + 1
    }
}
pub struct CoreDerivedShape {
    owner: RegisteredNominalRef,
    ty: CoreTypeRef,
    value: CoreDerivedShapeValue
}

pub fn make_core_derived_struct_shape(
    owner: RegisteredNominalRef, ty: CoreTypeRef,
    fields: List<CoreDerivedFieldPlan>
) -> CoreDerivedShape {
    require_unique_fields(fields)
    CoreDerivedShape {
        owner: owner, ty: ty,
        value: CoreDerivedShapeValue::StructShape(
            copy_derived_fields(fields))
    }
}
pub fn make_core_derived_enum_shape(
    owner: RegisteredNominalRef, ty: CoreTypeRef,
    variants: List<CoreDerivedVariantPlan>
) -> CoreDerivedShape {
    if variants.len() == 0 {
        panic("Core derive: enum shape has no variants")
    }
    require_unique_variants(variants)
    for variant in variants { require_unique_fields(variant.fields) }
    CoreDerivedShape {
        owner: owner, ty: ty,
        value: CoreDerivedShapeValue::EnumShape(copy_variants(variants))
    }
}

fn finalize_body(header: CoreDerivedHeader, tail: CoreExpr) -> CoreBody {
    let block = make_core_block([], some(tail), header.body_origin)
    let body = make_core_body(
        header.reference, header.origin, header.binders,
        header.parameter_slots, header.result_type, block)
    validate_core_body(body)
    body
}

fn bool_literal(ty: CoreTypeRef, value: Bool, origin: OriginRef) -> CoreExpr {
    make_core_literal_expr(ty, origin, make_core_bool_literal(value))
}
fn int_literal(ty: CoreTypeRef, value: Int, origin: OriginRef) -> CoreExpr {
    make_core_literal_expr(ty, origin, make_core_int_literal(value))
}

fn pattern_for_variant(
    shape_type: CoreTypeRef, value: CoreDerivedVariantPlan,
    use_right: Bool
) -> CorePattern {
    let slots = if use_right {
        value.right_pattern_slots
    } else {
        value.left_pattern_slots
    }
    let mut fields: List<CorePatternField> = []
    let mut index = 0
    while index < value.fields.len() {
        let field = value.fields.get(index).unwrap()
        fields.push(make_core_pattern_field(
            field.field,
            make_core_binding_pattern(
                field.ty, slots.get(index).unwrap())))
        index = index + 1
    }
    make_core_variant_pattern(shape_type, value.variant, fields)
}

// ============================================================
// Eq / Ne — exact field calls with lexical short-circuiting
// ============================================================

pub struct CoreDerivedEqPlan {
    header: CoreDerivedHeader,
    shape: CoreDerivedShape,
    bool_type: CoreTypeRef
}

pub fn make_core_derived_eq_plan(
    header: CoreDerivedHeader, shape: CoreDerivedShape,
    bool_type: CoreTypeRef
) -> CoreDerivedEqPlan {
    let other = match header.other_slot {
        some(value) => value,
        none => panic("Core derive Eq: other parameter is absent")
    }
    if !core_type_ref_same(binder_type(header.binders, header.self_slot), shape.ty) ||
       !core_type_ref_same(binder_type(header.binders, other), shape.ty) ||
       !core_type_ref_same(header.result_type, bool_type) {
        panic("Core derive Eq: header/shape type differs")
    }
    match shape.value {
        CoreDerivedShapeValue::StructShape(fields) => {
            for field in fields {
                if field.right.is_none() ||
                   !core_type_ref_same(field.operation.result_type, bool_type) {
                    panic("Core derive Eq: field result is not Bool")
                }
            }
        },
        CoreDerivedShapeValue::EnumShape(variants) => {
            for variant in variants {
                for field in variant.fields {
                    if field.right.is_none() ||
                       !core_type_ref_same(
                            field.operation.result_type, bool_type) {
                        panic("Core derive Eq: enum field result is not Bool")
                    }
                }
            }
        }
    }
    CoreDerivedEqPlan {
        header: header, shape: shape, bool_type: bool_type
    }
}

fn field_binary_call(value: CoreDerivedFieldPlan) -> CoreExpr {
    let right = match value.right {
        some(item) => item,
        none => panic("Core derive: binary field operation lacks right operand")
    }
    derived_call(value.operation, [
        derived_value_expr(value.left), derived_value_expr(right)
    ])
}

fn eq_fields(
    fields: List<CoreDerivedFieldPlan>, index: Int,
    bool_type: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef
) -> CoreExpr {
    if index >= fields.len() { return bool_literal(bool_type, true, origin) }
    let condition = field_binary_call(fields.get(index).unwrap())
    let success = eq_fields(fields, index + 1, bool_type, effects, origin)
    make_core_if_expr(
        bool_type, effects, origin, condition,
        make_core_block([], some(success), origin),
        make_core_block([], some(bool_literal(bool_type, false, origin)), origin))
}

fn eq_enum(
    header: CoreDerivedHeader, shape: CoreDerivedShape,
    variants: List<CoreDerivedVariantPlan>, bool_type: CoreTypeRef
) -> CoreExpr {
    let other_slot = header.other_slot.unwrap()
    let left = make_core_read_expr(
        shape.ty, make_core_effect_set([]), header.body_origin,
        header.self_slot)
    let mut outer_arms: List<CoreMatchArm> = []
    for variant in variants {
        if variant.right_pattern_slots.len() != variant.fields.len() {
            panic("Core derive Eq: enum right pattern is incomplete")
        }
        let right = make_core_read_expr(
            shape.ty, make_core_effect_set([]), variant.origin, other_slot)
        let same = eq_fields(
            variant.fields, 0, bool_type,
            header.result_effects, variant.origin)
        let inner_arms = [
            make_core_match_arm(
                pattern_for_variant(shape.ty, variant, true), none,
                make_core_block([], some(same), variant.origin),
                variant.origin),
            make_core_match_arm(
                make_core_wildcard_pattern(shape.ty), none,
                make_core_block([], some(
                    bool_literal(bool_type, false, variant.origin)),
                    variant.origin),
                variant.origin)
        ]
        let inner = make_core_match_expr(
            bool_type, header.result_effects, variant.origin,
            right, inner_arms)
        outer_arms.push(make_core_match_arm(
            pattern_for_variant(shape.ty, variant, false), none,
            make_core_block([], some(inner), variant.origin),
            variant.origin))
    }
    make_core_match_expr(
        bool_type, header.result_effects, header.body_origin,
        left, outer_arms)
}

fn derived_eq_expr(plan: CoreDerivedEqPlan) -> CoreExpr {
    match plan.shape.value {
        CoreDerivedShapeValue::StructShape(fields) => eq_fields(
            fields, 0, plan.bool_type,
            plan.header.result_effects, plan.header.body_origin),
        CoreDerivedShapeValue::EnumShape(variants) => eq_enum(
            plan.header, plan.shape, variants, plan.bool_type)
    }
}

pub fn elaborate_core_derived_eq_body(plan: CoreDerivedEqPlan) -> CoreBody {
    let header = plan.header
    finalize_body(header, derived_eq_expr(plan))
}

pub fn elaborate_core_derived_ne_body(plan: CoreDerivedEqPlan) -> CoreBody {
    let header = plan.header
    let equality = derived_eq_expr(plan)
    let negated = make_core_primitive_expr(
        plan.bool_type, header.result_effects, header.body_origin,
        make_core_primitive_op(6), [equality])
    finalize_body(header, negated)
}

// ============================================================
// Hash — exact field hash + exact accumulator mix
// ============================================================

pub struct CoreDerivedHashPlan {
    header: CoreDerivedHeader,
    shape: CoreDerivedShape,
    int_type: CoreTypeRef,
    seed: Int,
    mix: CoreDerivedCallPlan
}

pub fn make_core_derived_hash_plan(
    header: CoreDerivedHeader, shape: CoreDerivedShape,
    int_type: CoreTypeRef, seed: Int, mix: CoreDerivedCallPlan
) -> CoreDerivedHashPlan {
    if header.other_slot.is_some() ||
       !core_type_ref_same(binder_type(header.binders, header.self_slot), shape.ty) ||
       !core_type_ref_same(header.result_type, int_type) ||
       !core_type_ref_same(mix.result_type, int_type) {
        panic("Core derive Hash: header/mix type differs")
    }
    match shape.value {
        CoreDerivedShapeValue::StructShape(fields) => {
            for field in fields {
                if field.right.is_some() ||
                   !core_type_ref_same(field.operation.result_type, int_type) {
                    panic("Core derive Hash: field result is not Int")
                }
            }
        },
        CoreDerivedShapeValue::EnumShape(variants) => {
            for variant in variants {
                for field in variant.fields {
                    if field.right.is_some() ||
                       !core_type_ref_same(
                            field.operation.result_type, int_type) {
                        panic("Core derive Hash: enum field result is not Int")
                    }
                }
            }
        }
    }
    CoreDerivedHashPlan {
        header: header, shape: shape, int_type: int_type,
        seed: seed, mix: mix
    }
}

fn hash_fields(
    fields: List<CoreDerivedFieldPlan>, mut accumulator: CoreExpr,
    mix: CoreDerivedCallPlan
) -> CoreExpr {
    for field in fields {
        if field.right.is_some() {
            panic("Core derive Hash: field unexpectedly has right operand")
        }
        let hashed = derived_call(
            field.operation, [derived_value_expr(field.left)])
        accumulator = derived_call(mix, [accumulator, hashed])
    }
    accumulator
}

fn derived_hash_expr(plan: CoreDerivedHashPlan) -> CoreExpr {
    let seed = int_literal(
        plan.int_type, plan.seed, plan.header.body_origin)
    match plan.shape.value {
        CoreDerivedShapeValue::StructShape(fields) =>
            hash_fields(fields, seed, plan.mix),
        CoreDerivedShapeValue::EnumShape(variants) => {
            let scrutinee = make_core_read_expr(
                plan.shape.ty, make_core_effect_set([]),
                plan.header.body_origin, plan.header.self_slot)
            let mut arms: List<CoreMatchArm> = []
            for variant in variants {
                let with_discriminator = derived_call(plan.mix, [
                    int_literal(plan.int_type, plan.seed, variant.origin),
                    int_literal(
                        plan.int_type, variant.discriminator, variant.origin)
                ])
                let value = hash_fields(
                    variant.fields, with_discriminator, plan.mix)
                arms.push(make_core_match_arm(
                    pattern_for_variant(plan.shape.ty, variant, false), none,
                    make_core_block([], some(value), variant.origin),
                    variant.origin))
            }
            make_core_match_expr(
                plan.int_type, plan.header.result_effects,
                plan.header.body_origin, scrutinee, arms)
        }
    }
}

pub fn elaborate_core_derived_hash_body(
    plan: CoreDerivedHashPlan
) -> CoreBody {
    let header = plan.header
    finalize_body(header, derived_hash_expr(plan))
}

// ============================================================
// Ord — lexicographic exact cmp, each cmp evaluated once
// ============================================================

pub struct CoreDerivedOrdFieldPlan {
    field: CoreDerivedFieldPlan,
    result_slot: SlotRef
}
pub fn make_core_derived_ord_field_plan(
    field: CoreDerivedFieldPlan, result_slot: SlotRef
) -> CoreDerivedOrdFieldPlan {
    if field.right.is_none() {
        panic("Core derive Ord: field has no right operand")
    }
    CoreDerivedOrdFieldPlan { field: field, result_slot: result_slot }
}
fn copy_ord_fields(
    values: List<CoreDerivedOrdFieldPlan>
) -> List<CoreDerivedOrdFieldPlan> {
    let mut result: List<CoreDerivedOrdFieldPlan> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreDerivedOrdVariantPlan {
    variant: CoreDerivedVariantPlan,
    fields: List<CoreDerivedOrdFieldPlan>
}
pub fn make_core_derived_ord_variant_plan(
    variant: CoreDerivedVariantPlan,
    fields: List<CoreDerivedOrdFieldPlan>
) -> CoreDerivedOrdVariantPlan {
    if variant.fields.len() != fields.len() {
        panic("Core derive Ord: variant field census differs")
    }
    let mut index = 0
    while index < fields.len() {
        if !core_field_ref_same(
                variant.fields.get(index).unwrap().field,
                fields.get(index).unwrap().field.field) {
            panic("Core derive Ord: variant field order differs")
        }
        index = index + 1
    }
    CoreDerivedOrdVariantPlan {
        variant: variant, fields: copy_ord_fields(fields)
    }
}
fn copy_ord_variants(
    values: List<CoreDerivedOrdVariantPlan>
) -> List<CoreDerivedOrdVariantPlan> {
    let mut result: List<CoreDerivedOrdVariantPlan> = []
    for value in values { result.push(value) }
    result
}

enum CoreDerivedOrdShapeValue {
    StructOrd(List<CoreDerivedOrdFieldPlan>),
    EnumOrd(List<CoreDerivedOrdVariantPlan>)
}
pub struct CoreDerivedOrdPlan {
    header: CoreDerivedHeader,
    owner: RegisteredNominalRef,
    target_type: CoreTypeRef,
    int_type: CoreTypeRef,
    bool_type: CoreTypeRef,
    zero_test: CoreDerivedCallPlan,
    discriminator_cmp: CoreDerivedCallPlan,
    value: CoreDerivedOrdShapeValue
}

pub fn make_core_derived_struct_ord_plan(
    header: CoreDerivedHeader, owner: RegisteredNominalRef,
    target_type: CoreTypeRef, int_type: CoreTypeRef, bool_type: CoreTypeRef,
    zero_test: CoreDerivedCallPlan,
    discriminator_cmp: CoreDerivedCallPlan,
    fields: List<CoreDerivedOrdFieldPlan>
) -> CoreDerivedOrdPlan {
    if header.other_slot.is_none() ||
       !core_type_ref_same(header.result_type, int_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.self_slot), target_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.other_slot.unwrap()), target_type) ||
       !core_type_ref_same(zero_test.result_type, bool_type) ||
       !core_type_ref_same(discriminator_cmp.result_type, int_type) {
        panic("Core derive Ord: header/call result type differs")
    }
    for field in fields {
        if !core_type_ref_same(
                binder_type(header.binders, field.result_slot), int_type) ||
           !core_type_ref_same(
                field.field.operation.result_type, int_type) {
            panic("Core derive Ord: cmp binder is not Int")
        }
    }
    CoreDerivedOrdPlan {
        header: header, owner: owner, target_type: target_type,
        int_type: int_type, bool_type: bool_type,
        zero_test: zero_test, discriminator_cmp: discriminator_cmp,
        value: CoreDerivedOrdShapeValue::StructOrd(copy_ord_fields(fields))
    }
}

pub fn make_core_derived_enum_ord_plan(
    header: CoreDerivedHeader, owner: RegisteredNominalRef,
    target_type: CoreTypeRef, int_type: CoreTypeRef, bool_type: CoreTypeRef,
    zero_test: CoreDerivedCallPlan,
    discriminator_cmp: CoreDerivedCallPlan,
    variants: List<CoreDerivedOrdVariantPlan>
) -> CoreDerivedOrdPlan {
    if variants.len() == 0 || header.other_slot.is_none() ||
       !core_type_ref_same(header.result_type, int_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.self_slot), target_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.other_slot.unwrap()), target_type) ||
       !core_type_ref_same(zero_test.result_type, bool_type) ||
       !core_type_ref_same(discriminator_cmp.result_type, int_type) {
        panic("Core derive Ord: enum header/call result type differs")
    }
    let mut exact_variants: List<CoreDerivedVariantPlan> = []
    for variant in variants { exact_variants.push(variant.variant) }
    require_unique_variants(exact_variants)
    for variant in variants {
        if variant.variant.right_pattern_slots.len() !=
               variant.variant.fields.len() {
            panic("Core derive Ord: enum right pattern is incomplete")
        }
        for field in variant.fields {
            if !core_type_ref_same(
                    binder_type(header.binders, field.result_slot), int_type) ||
               !core_type_ref_same(
                    field.field.operation.result_type, int_type) {
                panic("Core derive Ord: cmp binder is not Int")
            }
        }
    }
    CoreDerivedOrdPlan {
        header: header, owner: owner, target_type: target_type,
        int_type: int_type, bool_type: bool_type,
        zero_test: zero_test, discriminator_cmp: discriminator_cmp,
        value: CoreDerivedOrdShapeValue::EnumOrd(copy_ord_variants(variants))
    }
}

fn ord_fields(
    fields: List<CoreDerivedOrdFieldPlan>, index: Int,
    plan: CoreDerivedOrdPlan, origin: OriginRef
) -> CoreExpr {
    if index >= fields.len() {
        return int_literal(plan.int_type, 0, origin)
    }
    let field = fields.get(index).unwrap()
    let compared = field_binary_call(field.field)
    let bind = make_core_bind_stmt(
        field.result_slot, compared, false, field.field.operation.origin)
    let read_for_test = make_core_read_expr(
        plan.int_type, make_core_effect_set([]), origin, field.result_slot)
    let is_zero = derived_call(plan.zero_test, [read_for_test])
    let next = ord_fields(fields, index + 1, plan, origin)
    let current = make_core_read_expr(
        plan.int_type, make_core_effect_set([]), origin, field.result_slot)
    let selected = make_core_if_expr(
        plan.int_type, plan.header.result_effects, origin, is_zero,
        make_core_block([], some(next), origin),
        make_core_block([], some(current), origin))
    make_core_block_expr(
        plan.int_type, plan.header.result_effects, origin,
        make_core_block([bind], some(selected), origin))
}

fn discriminator_compare(
    left: Int, right: Int, plan: CoreDerivedOrdPlan,
    origin: OriginRef
) -> CoreExpr {
    derived_call(plan.discriminator_cmp, [
        int_literal(plan.int_type, left, origin),
        int_literal(plan.int_type, right, origin)
    ])
}

fn derived_ord_expr(plan: CoreDerivedOrdPlan) -> CoreExpr {
    match plan.value {
        CoreDerivedOrdShapeValue::StructOrd(fields) =>
            ord_fields(fields, 0, plan, plan.header.body_origin),
        CoreDerivedOrdShapeValue::EnumOrd(variants) => {
            let left = make_core_read_expr(
                plan.target_type, make_core_effect_set([]),
                plan.header.body_origin, plan.header.self_slot)
            let right_slot = plan.header.other_slot.unwrap()
            let mut outer: List<CoreMatchArm> = []
            for left_variant in variants {
                let right = make_core_read_expr(
                    plan.target_type, make_core_effect_set([]),
                    left_variant.variant.origin, right_slot)
                let mut inner: List<CoreMatchArm> = []
                for right_variant in variants {
                    let result = if variant_ref_same(
                            left_variant.variant.variant,
                            right_variant.variant.variant) {
                        ord_fields(
                            left_variant.fields, 0, plan,
                            left_variant.variant.origin)
                    } else {
                        discriminator_compare(
                            left_variant.variant.discriminator,
                            right_variant.variant.discriminator,
                            plan, left_variant.variant.origin)
                    }
                    inner.push(make_core_match_arm(
                        pattern_for_variant(
                            plan.target_type, right_variant.variant, true),
                        none,
                        make_core_block(
                            [], some(result), right_variant.variant.origin),
                        right_variant.variant.origin))
                }
                let inner_match = make_core_match_expr(
                    plan.int_type, plan.header.result_effects,
                    left_variant.variant.origin, right, inner)
                outer.push(make_core_match_arm(
                    pattern_for_variant(
                        plan.target_type, left_variant.variant, false),
                    none,
                    make_core_block(
                        [], some(inner_match), left_variant.variant.origin),
                    left_variant.variant.origin))
            }
            make_core_match_expr(
                plan.int_type, plan.header.result_effects,
                plan.header.body_origin, left, outer)
        }
    }
}

pub fn elaborate_core_derived_ord_body(plan: CoreDerivedOrdPlan) -> CoreBody {
    let header = plan.header
    finalize_body(header, derived_ord_expr(plan))
}

// ============================================================
// Debug / Json — exact literal segments and exact builder calls
// ============================================================

enum CoreDerivedTextPieceValue {
    LiteralText {
        value: Str, ty: CoreTypeRef, append: CoreDerivedCallPlan
    },
    RenderedValue {
        value: CoreDerivedValueRef,
        render: CoreDerivedCallPlan,
        append: CoreDerivedCallPlan
    }
}
pub struct CoreDerivedTextPiece { value: CoreDerivedTextPieceValue }

pub fn make_core_derived_literal_text_piece(
    value: Str, ty: CoreTypeRef, append: CoreDerivedCallPlan
) -> CoreDerivedTextPiece {
    if value == "" {
        panic("Core derive text: empty literal segment")
    }
    CoreDerivedTextPiece { value: CoreDerivedTextPieceValue::LiteralText {
        value: value, ty: ty, append: append
    } }
}
pub fn make_core_derived_rendered_text_piece(
    value: CoreDerivedValueRef, render: CoreDerivedCallPlan,
    append: CoreDerivedCallPlan
) -> CoreDerivedTextPiece {
    CoreDerivedTextPiece { value: CoreDerivedTextPieceValue::RenderedValue {
        value: value, render: render, append: append
    } }
}
fn copy_text_pieces(values: List<CoreDerivedTextPiece>) -> List<CoreDerivedTextPiece> {
    let mut result: List<CoreDerivedTextPiece> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreDerivedTextSequence { pieces: List<CoreDerivedTextPiece> }
pub fn make_core_derived_text_sequence(
    pieces: List<CoreDerivedTextPiece>
) -> CoreDerivedTextSequence {
    if pieces.len() == 0 {
        panic("Core derive text: sequence has no semantic segments")
    }
    CoreDerivedTextSequence { pieces: copy_text_pieces(pieces) }
}

pub struct CoreDerivedTextVariantPlan {
    variant: CoreDerivedVariantPlan,
    sequence: CoreDerivedTextSequence
}
pub fn make_core_derived_text_variant_plan(
    variant: CoreDerivedVariantPlan,
    sequence: CoreDerivedTextSequence
) -> CoreDerivedTextVariantPlan {
    if variant.right_pattern_slots.len() != 0 {
        panic("Core derive text: variant unexpectedly has right pattern")
    }
    CoreDerivedTextVariantPlan { variant: variant, sequence: sequence }
}
fn copy_text_variants(
    values: List<CoreDerivedTextVariantPlan>
) -> List<CoreDerivedTextVariantPlan> {
    let mut result: List<CoreDerivedTextVariantPlan> = []
    for value in values { result.push(value) }
    result
}

enum CoreDerivedTextShapeValue {
    StructText(CoreDerivedTextSequence),
    EnumText(List<CoreDerivedTextVariantPlan>)
}
pub struct CoreDerivedTextPlan {
    header: CoreDerivedHeader,
    owner: RegisteredNominalRef,
    target_type: CoreTypeRef,
    string_type: CoreTypeRef,
    unit_type: CoreTypeRef,
    builder_slot: SlotRef,
    builder_type: CoreTypeRef,
    builder: CoreDerivedCallPlan,
    finish: CoreDerivedCallPlan,
    value: CoreDerivedTextShapeValue
}

fn validate_text_sequence(
    value: CoreDerivedTextSequence,
    string_type: CoreTypeRef, unit_type: CoreTypeRef
) {
    for piece in value.pieces {
        match piece.value {
            CoreDerivedTextPieceValue::LiteralText { ty, append, .. } => {
                if !core_type_ref_same(ty, string_type) ||
                   !core_type_ref_same(append.result_type, unit_type) {
                    panic("Core derive text: literal/append type differs")
                }
            },
            CoreDerivedTextPieceValue::RenderedValue {
                render, append, ..
            } => {
                if !core_type_ref_same(render.result_type, string_type) ||
                   !core_type_ref_same(append.result_type, unit_type) {
                    panic("Core derive text: render/append type differs")
                }
            }
        }
    }
}

pub fn make_core_derived_struct_text_plan(
    header: CoreDerivedHeader, owner: RegisteredNominalRef,
    target_type: CoreTypeRef, string_type: CoreTypeRef,
    unit_type: CoreTypeRef, builder_slot: SlotRef,
    builder_type: CoreTypeRef, builder: CoreDerivedCallPlan,
    finish: CoreDerivedCallPlan, sequence: CoreDerivedTextSequence
) -> CoreDerivedTextPlan {
    if header.other_slot.is_some() ||
       !core_type_ref_same(header.result_type, string_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.self_slot), target_type) ||
       !core_type_ref_same(binder_type(header.binders, builder_slot), builder_type) ||
       !core_type_ref_same(builder.result_type, builder_type) ||
       !core_type_ref_same(finish.result_type, string_type) {
        panic("Core derive text: struct header/builder type differs")
    }
    validate_text_sequence(sequence, string_type, unit_type)
    CoreDerivedTextPlan {
        header: header, owner: owner, target_type: target_type,
        string_type: string_type, unit_type: unit_type,
        builder_slot: builder_slot, builder_type: builder_type,
        builder: builder, finish: finish,
        value: CoreDerivedTextShapeValue::StructText(sequence)
    }
}

pub fn make_core_derived_enum_text_plan(
    header: CoreDerivedHeader, owner: RegisteredNominalRef,
    target_type: CoreTypeRef, string_type: CoreTypeRef,
    unit_type: CoreTypeRef, builder_slot: SlotRef,
    builder_type: CoreTypeRef, builder: CoreDerivedCallPlan,
    finish: CoreDerivedCallPlan,
    variants: List<CoreDerivedTextVariantPlan>
) -> CoreDerivedTextPlan {
    if variants.len() == 0 || header.other_slot.is_some() ||
       !core_type_ref_same(header.result_type, string_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.self_slot), target_type) ||
       !core_type_ref_same(binder_type(header.binders, builder_slot), builder_type) ||
       !core_type_ref_same(builder.result_type, builder_type) ||
       !core_type_ref_same(finish.result_type, string_type) {
        panic("Core derive text: enum header/builder type differs")
    }
    let mut exact_variants: List<CoreDerivedVariantPlan> = []
    for variant in variants { exact_variants.push(variant.variant) }
    require_unique_variants(exact_variants)
    for variant in variants {
        validate_text_sequence(variant.sequence, string_type, unit_type)
    }
    CoreDerivedTextPlan {
        header: header, owner: owner, target_type: target_type,
        string_type: string_type, unit_type: unit_type,
        builder_slot: builder_slot, builder_type: builder_type,
        builder: builder, finish: finish,
        value: CoreDerivedTextShapeValue::EnumText(
            copy_text_variants(variants))
    }
}

fn text_sequence_block(
    plan: CoreDerivedTextPlan, sequence: CoreDerivedTextSequence,
    origin: OriginRef
) -> CoreBlock {
    let builder_value = derived_call(plan.builder, [])
    let mut statements: List<CoreStmt> = [make_core_bind_stmt(
        plan.builder_slot, builder_value, true, origin)]
    for piece in sequence.pieces {
        let (text, append) = match piece.value {
            CoreDerivedTextPieceValue::LiteralText { value, ty, append } => (
                make_core_literal_expr(
                    ty, origin, make_core_str_literal(value)), append),
            CoreDerivedTextPieceValue::RenderedValue {
                value, render, append
            } => (derived_call(render, [derived_value_expr(value)]), append)
        }
        if !core_type_ref_same(append.result_type, plan.unit_type) {
            panic("Core derive text: append result is not Unit")
        }
        let builder_read = make_core_read_expr(
            plan.builder_type, make_core_effect_set([]),
            origin, plan.builder_slot)
        statements.push(make_core_expr_stmt(
            derived_call(append, [builder_read, text]), origin))
    }
    let finish_receiver = make_core_read_expr(
        plan.builder_type, make_core_effect_set([]), origin,
        plan.builder_slot)
    let finished = derived_call(plan.finish, [finish_receiver])
    make_core_block(statements, some(finished), origin)
}

fn elaborate_text_body(plan: CoreDerivedTextPlan) -> CoreBody {
    let block = match plan.value {
        CoreDerivedTextShapeValue::StructText(sequence) =>
            text_sequence_block(plan, sequence, plan.header.body_origin),
        CoreDerivedTextShapeValue::EnumText(variants) => {
            let scrutinee = make_core_read_expr(
                plan.target_type, make_core_effect_set([]),
                plan.header.body_origin, plan.header.self_slot)
            let mut arms: List<CoreMatchArm> = []
            for variant in variants {
                let body = text_sequence_block(
                    plan, variant.sequence, variant.variant.origin)
                arms.push(make_core_match_arm(
                    pattern_for_variant(
                        plan.target_type, variant.variant, false),
                    none, body, variant.variant.origin))
            }
            make_core_block([], some(make_core_match_expr(
                plan.string_type, plan.header.result_effects,
                plan.header.body_origin, scrutinee, arms)),
                plan.header.body_origin)
        }
    }
    let body = make_core_body(
        plan.header.reference, plan.header.origin, plan.header.binders,
        plan.header.parameter_slots, plan.header.result_type, block)
    validate_core_body(body)
    body
}

pub struct CoreDerivedDebugPlan { plan: CoreDerivedTextPlan }
pub struct CoreDerivedJsonPlan { plan: CoreDerivedTextPlan }
pub fn make_core_derived_debug_plan(
    plan: CoreDerivedTextPlan
) -> CoreDerivedDebugPlan { CoreDerivedDebugPlan { plan: plan } }
pub fn make_core_derived_json_plan(
    plan: CoreDerivedTextPlan
) -> CoreDerivedJsonPlan { CoreDerivedJsonPlan { plan: plan } }
pub fn elaborate_core_derived_debug_body(
    plan: CoreDerivedDebugPlan
) -> CoreBody { elaborate_text_body(plan.plan) }
pub fn elaborate_core_derived_json_body(
    plan: CoreDerivedJsonPlan
) -> CoreBody { elaborate_text_body(plan.plan) }

// Clone is the same exact deep constructor elaboration audited in
// core_elaborate; no resource Clone or alternate implementation exists here.
pub fn elaborate_core_derived_struct_clone_body(
    plan: CoreStructClonePlan
) -> CoreBody { core_elaborated_body(elaborate_core_struct_deep_clone(plan)) }
pub fn elaborate_core_derived_enum_clone_body(
    plan: CoreEnumClonePlan
) -> CoreBody { core_elaborated_body(elaborate_core_enum_deep_clone(plan)) }
