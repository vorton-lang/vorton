// Exact 0.1 derived-trait elaboration into ordinary structured Core bodies.
//
// This module owns no resolver, type, layout, field-name, or backend policy.
// Every method, projection, constructor, evidence value, binder, literal
// segment, and variant discriminator is supplied by the typed producer. The
// elaborator only assembles those closed facts into ordinary CoreExpr trees.

use ir_identity::{
    CoreTypeRef, core_type_ref_same,
    SlotRef, OriginRef, RegisteredNominalRef, VariantRef,
    VariantFieldRef,
    slot_ref_same, variant_ref_same, variant_field_ref_variant,
    registered_nominal_ref_same
}
use ir_inventory::{ExecutableRef, ExactMethodRef}
use effect_contract::{
    CoreEffectSet, make_core_effect_set, core_effect_set_atoms
}
use core_expr::{
    CoreCalleeRef, CoreEvidenceRef, CoreEffectCtxArgument,
    CoreFieldRef, CoreFieldValue, CoreConstructorRef,
    CoreBinder, CoreBody, CoreBlock, CoreStmt, CoreExpr,
    CorePattern, CorePatternField, CoreMatchArm,
    make_core_read_expr, make_core_project_expr,
    make_core_call_expr, make_core_method_call_expr,
    make_core_construct_expr, make_core_variant_constructor,
    make_core_if_expr, make_core_match_expr,
    make_core_primitive_expr, make_core_primitive_op,
    make_core_literal_expr, make_core_int_literal,
    make_core_str_literal, make_core_bool_literal,
    make_core_binding_pattern, make_core_wildcard_pattern,
    make_core_pattern_field, make_core_variant_pattern,
    make_core_field_value, make_core_match_arm,
    make_core_block, make_core_bind_stmt, make_core_expr_stmt,
    make_core_body, validate_core_body,
    core_binder_reference, core_binder_type,
    core_field_ref_kind_tag, core_field_ref_same,
    core_field_ref_tuple_index, core_field_ref_variant,
    core_constructor_kind_tag, core_constructor_struct_owner,
    core_constructor_arity
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
    method: ExactMethodRef?,
    result_type: CoreTypeRef,
    effects: CoreEffectSet,
    evidence: List<CoreEvidenceRef>,
    effect_ctx: CoreEffectCtxArgument,
    origin: OriginRef
}

pub fn make_core_derived_call_plan(
    callee: CoreCalleeRef, method: ExactMethodRef?,
    result_type: CoreTypeRef, effects: CoreEffectSet,
    evidence: List<CoreEvidenceRef>,
    effect_ctx: CoreEffectCtxArgument, origin: OriginRef
) -> CoreDerivedCallPlan {
    CoreDerivedCallPlan {
        callee: callee, method: method, result_type: result_type,
        effects: make_core_effect_set(core_effect_set_atoms(effects)),
        evidence: copy_evidence(evidence),
        effect_ctx: effect_ctx,
        origin: origin
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
                plan.callee, method, receiver, params, plan.evidence,
                plan.effect_ctx)
        },
        none => make_core_call_expr(
            plan.result_type, plan.effects, plan.origin,
            plan.callee, arguments, plan.evidence, plan.effect_ctx)
    }
}

enum CoreDerivedFieldPlanValue {
    DerivedLeaf {
        operation: CoreDerivedCallPlan,
        result_slot: SlotRef?
    },
    DerivedTuple {
        constructor: CoreConstructorRef?,
        fields: List<CoreFieldRef>,
        field_types: List<CoreTypeRef>,
        children: List<CoreDerivedFieldPlan>,
        effects: CoreEffectSet,
        origin: OriginRef
    }
}
pub struct CoreDerivedFieldPlan {
    field: CoreFieldRef,
    ty: CoreTypeRef,
    left: CoreDerivedValueRef,
    right: CoreDerivedValueRef?,
    value: CoreDerivedFieldPlanValue
}

pub fn make_core_derived_field_plan(
    field: CoreFieldRef, ty: CoreTypeRef,
    left: CoreDerivedValueRef, right: CoreDerivedValueRef?,
    operation: CoreDerivedCallPlan, result_slot: SlotRef?
) -> CoreDerivedFieldPlan {
    if !core_type_ref_same(left.ty, ty) ||
       match right {
            some(value) => !core_type_ref_same(value.ty, ty),
            none => false
       } {
        panic("Core derive: field operand type differs")
    }
    if operation.method.is_none() {
        panic("Core derive: field operation lacks exact method identity")
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
        value: CoreDerivedFieldPlanValue::DerivedLeaf {
            operation: operation, result_slot: result_slot
        }
    }
}

fn copy_derived_fields(
    values: List<CoreDerivedFieldPlan>
) -> List<CoreDerivedFieldPlan> {
    let mut result: List<CoreDerivedFieldPlan> = []
    for value in values { result.push(value) }
    result
}

fn require_derived_child_projection(
    parent: CoreDerivedValueRef, child: CoreDerivedValueRef,
    field: CoreFieldRef, field_type: CoreTypeRef, ordinal: Int
) {
    if !slot_ref_same(parent.root, child.root) ||
       !core_type_ref_same(parent.root_type, child.root_type) ||
       child.projections.len() != parent.projections.len() + 1 ||
       child.projection_types.len() != parent.projection_types.len() + 1 ||
       !core_field_ref_same(
            child.projections.get(child.projections.len() - 1).unwrap(), field) ||
       !core_type_ref_same(child.ty, field_type) ||
       core_field_ref_kind_tag(field) != 1 ||
       core_field_ref_tuple_index(field) != ordinal {
        panic("Core derive: tuple child projection/order differs")
    }
    let mut index = 0
    while index < parent.projections.len() {
        if !core_field_ref_same(
                parent.projections.get(index).unwrap(),
                child.projections.get(index).unwrap()) ||
           !core_type_ref_same(
                parent.projection_types.get(index).unwrap(),
                child.projection_types.get(index).unwrap()) {
            panic("Core derive: tuple child path prefix differs")
        }
        index = index + 1
    }
}

pub fn make_core_derived_tuple_field_plan(
    field: CoreFieldRef, ty: CoreTypeRef,
    left: CoreDerivedValueRef, right: CoreDerivedValueRef?,
    constructor: CoreConstructorRef?,
    fields: List<CoreFieldRef>, field_types: List<CoreTypeRef>,
    children: List<CoreDerivedFieldPlan>,
    effects: CoreEffectSet, origin: OriginRef
) -> CoreDerivedFieldPlan {
    if !core_type_ref_same(left.ty, ty) ||
       match right {
            some(value) => !core_type_ref_same(value.ty, ty),
            none => false
       } || fields.len() != field_types.len() ||
       fields.len() != children.len() {
        panic("Core derive: tuple field shape/type differs")
    }
    match constructor {
        some(exact) => if core_constructor_kind_tag(exact) != 2 ||
                core_constructor_arity(exact) != fields.len() {
            panic("Core derive: tuple constructor arity differs")
        },
        none => {}
    }
    let mut index = 0
    while index < children.len() {
        let child = children.get(index).unwrap()
        require_derived_child_projection(
            left, child.left, fields.get(index).unwrap(),
            field_types.get(index).unwrap(), index)
        match right {
            some(right_value) => match child.right {
                some(child_right) => require_derived_child_projection(
                    right_value, child_right, fields.get(index).unwrap(),
                    field_types.get(index).unwrap(), index),
                none => panic("Core derive: binary tuple child lacks right value")
            },
            none => if child.right.is_some() {
                panic("Core derive: unary tuple child has right value")
            }
        }
        if !core_type_ref_same(child.ty, field_types.get(index).unwrap()) {
            panic("Core derive: tuple child result type differs")
        }
        index = index + 1
    }
    CoreDerivedFieldPlan {
        field: field, ty: ty, left: left, right: right,
        value: CoreDerivedFieldPlanValue::DerivedTuple {
            constructor: constructor, fields: copy_fields(fields),
            field_types: copy_types(field_types),
            children: copy_derived_fields(children),
            effects: make_core_effect_set(core_effect_set_atoms(effects)),
            origin: origin
        }
    }
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
// Eq — exact field calls with lexical short-circuiting
// ============================================================

pub struct CoreDerivedEqPlan {
    header: CoreDerivedHeader,
    shape: CoreDerivedShape,
    bool_type: CoreTypeRef
}

fn validate_eq_field(value: CoreDerivedFieldPlan, bool_type: CoreTypeRef) {
    if value.right.is_none() {
        panic("Core derive Eq: field lacks right operand")
    }
    match value.value {
        CoreDerivedFieldPlanValue::DerivedLeaf { operation, result_slot } => {
            if result_slot.is_some() ||
               !core_type_ref_same(operation.result_type, bool_type) {
                panic("Core derive Eq: leaf result is not Bool")
            }
        },
        CoreDerivedFieldPlanValue::DerivedTuple {
            constructor, children, ..
        } => {
            if constructor.is_some() {
                panic("Core derive Eq: tuple comparison carries constructor")
            }
            for child in children { validate_eq_field(child, bool_type) }
        }
    }
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
            for field in fields { validate_eq_field(field, bool_type) }
        },
        CoreDerivedShapeValue::EnumShape(variants) => {
            for variant in variants {
                for field in variant.fields {
                    validate_eq_field(field, bool_type)
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
    match value.value {
        CoreDerivedFieldPlanValue::DerivedLeaf { operation, .. } =>
            derived_call(operation, [
                derived_value_expr(value.left), derived_value_expr(right)
            ]),
        _ => panic("Core derive: tuple field is not one binary leaf")
    }
}

fn eq_field(
    value: CoreDerivedFieldPlan,
    bool_type: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef
) -> CoreExpr with {} {
    match value.value {
        CoreDerivedFieldPlanValue::DerivedLeaf { .. } =>
            field_binary_call(value),
        CoreDerivedFieldPlanValue::DerivedTuple { children, .. } =>
            eq_fields(children, 0, bool_type, effects, origin)
    }
}

fn eq_fields(
    fields: List<CoreDerivedFieldPlan>, index: Int,
    bool_type: CoreTypeRef, effects: CoreEffectSet, origin: OriginRef
) -> CoreExpr with {} {
    if index >= fields.len() { return bool_literal(bool_type, true, origin) }
    let condition = eq_field(
        fields.get(index).unwrap(), bool_type, effects, origin)
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

fn validate_hash_field(
    value: CoreDerivedFieldPlan, int_type: CoreTypeRef
) with {} {
    if value.right.is_some() {
        panic("Core derive Hash: field unexpectedly has right operand")
    }
    match value.value {
        CoreDerivedFieldPlanValue::DerivedLeaf { operation, result_slot } => {
            if result_slot.is_some() ||
               !core_type_ref_same(operation.result_type, int_type) {
                panic("Core derive Hash: leaf result is not Int")
            }
        },
        CoreDerivedFieldPlanValue::DerivedTuple {
            constructor, children, ..
        } => {
            if constructor.is_some() {
                panic("Core derive Hash: tuple fold carries constructor")
            }
            for child in children { validate_hash_field(child, int_type) }
        }
    }
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
            for field in fields { validate_hash_field(field, int_type) }
        },
        CoreDerivedShapeValue::EnumShape(variants) => {
            for variant in variants {
                for field in variant.fields {
                    validate_hash_field(field, int_type)
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
) -> CoreExpr with {mut<CoreExpr>} {
    for field in fields {
        match field.value {
            CoreDerivedFieldPlanValue::DerivedLeaf { operation, .. } => {
                let hashed = derived_call(
                    operation, [derived_value_expr(field.left)])
                accumulator = derived_call(mix, [accumulator, hashed])
            },
            CoreDerivedFieldPlanValue::DerivedTuple { children, .. } => {
                accumulator = hash_fields(children, accumulator, mix)
            }
        }
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

pub struct CoreDerivedOrdVariantPlan {
    variant: CoreDerivedVariantPlan,
    fields: List<CoreDerivedFieldPlan>
}
pub fn make_core_derived_ord_variant_plan(
    variant: CoreDerivedVariantPlan,
    fields: List<CoreDerivedFieldPlan>
) -> CoreDerivedOrdVariantPlan {
    if variant.fields.len() != fields.len() {
        panic("Core derive Ord: variant field census differs")
    }
    let mut index = 0
    while index < fields.len() {
        if !core_field_ref_same(
                variant.fields.get(index).unwrap().field,
                fields.get(index).unwrap().field) {
            panic("Core derive Ord: variant field order differs")
        }
        index = index + 1
    }
    CoreDerivedOrdVariantPlan {
        variant: variant, fields: copy_derived_fields(fields)
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
    StructOrd(List<CoreDerivedFieldPlan>),
    EnumOrd(List<CoreDerivedOrdVariantPlan>)
}
pub struct CoreDerivedOrdPlan {
    header: CoreDerivedHeader,
    owner: RegisteredNominalRef,
    target_type: CoreTypeRef,
    int_type: CoreTypeRef,
    bool_type: CoreTypeRef,
    value: CoreDerivedOrdShapeValue
}

fn validate_ord_field(
    value: CoreDerivedFieldPlan,
    header: CoreDerivedHeader, int_type: CoreTypeRef
) with {} {
    if value.right.is_none() {
        panic("Core derive Ord: field lacks right operand")
    }
    match value.value {
        CoreDerivedFieldPlanValue::DerivedLeaf {
            operation, result_slot
        } => {
            let slot = match result_slot {
                some(exact) => exact,
                none => panic("Core derive Ord: leaf cmp binder is absent")
            }
            if !core_type_ref_same(
                    binder_type(header.binders, slot), int_type) ||
               !core_type_ref_same(operation.result_type, int_type) {
                panic("Core derive Ord: cmp binder/result is not Int")
            }
        },
        CoreDerivedFieldPlanValue::DerivedTuple {
            constructor, children, ..
        } => {
            if constructor.is_some() {
                panic("Core derive Ord: tuple comparison carries constructor")
            }
            for child in children {
                validate_ord_field(child, header, int_type)
            }
        }
    }
}

pub fn make_core_derived_struct_ord_plan(
    header: CoreDerivedHeader, owner: RegisteredNominalRef,
    target_type: CoreTypeRef, int_type: CoreTypeRef, bool_type: CoreTypeRef,
    fields: List<CoreDerivedFieldPlan>
) -> CoreDerivedOrdPlan {
    if header.other_slot.is_none() ||
       !core_type_ref_same(header.result_type, int_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.self_slot), target_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.other_slot.unwrap()), target_type) {
        panic("Core derive Ord: header/call result type differs")
    }
    for field in fields { validate_ord_field(field, header, int_type) }
    CoreDerivedOrdPlan {
        header: header, owner: owner, target_type: target_type,
        int_type: int_type, bool_type: bool_type,
        value: CoreDerivedOrdShapeValue::StructOrd(copy_derived_fields(fields))
    }
}

pub fn make_core_derived_enum_ord_plan(
    header: CoreDerivedHeader, owner: RegisteredNominalRef,
    target_type: CoreTypeRef, int_type: CoreTypeRef, bool_type: CoreTypeRef,
    variants: List<CoreDerivedOrdVariantPlan>
) -> CoreDerivedOrdPlan {
    if variants.len() == 0 || header.other_slot.is_none() ||
       !core_type_ref_same(header.result_type, int_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.self_slot), target_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.other_slot.unwrap()), target_type) {
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
            validate_ord_field(field, header, int_type)
        }
    }
    CoreDerivedOrdPlan {
        header: header, owner: owner, target_type: target_type,
        int_type: int_type, bool_type: bool_type,
        value: CoreDerivedOrdShapeValue::EnumOrd(copy_ord_variants(variants))
    }
}

fn flatten_ord_fields(
    values: List<CoreDerivedFieldPlan>,
    mut result: List<CoreDerivedFieldPlan>
) -> List<CoreDerivedFieldPlan> with {mut<List<CoreDerivedFieldPlan>>} {
    for value in values {
        match value.value {
            CoreDerivedFieldPlanValue::DerivedLeaf { .. } =>
                result.push(value),
            CoreDerivedFieldPlanValue::DerivedTuple { children, .. } => {
                result = flatten_ord_fields(children, result)
            }
        }
    }
    result
}

fn flattened_ord_fields(
    values: List<CoreDerivedFieldPlan>
) -> List<CoreDerivedFieldPlan> with {} {
    let result: List<CoreDerivedFieldPlan> = []
    flatten_ord_fields(values, result)
}

fn ord_fields(
    fields: List<CoreDerivedFieldPlan>, index: Int,
    plan: CoreDerivedOrdPlan, origin: OriginRef
) -> CoreExpr with {} {
    if index >= fields.len() {
        return int_literal(plan.int_type, 0, origin)
    }
    let field = fields.get(index).unwrap()
    let (operation, result_slot) = match field.value {
        CoreDerivedFieldPlanValue::DerivedLeaf {
            operation, result_slot
        } => (operation, result_slot.unwrap()),
        _ => panic("Core derive Ord: unflattened tuple reached leaf fold")
    }
    let compared = field_binary_call(field)
    let read_for_lt = make_core_read_expr(
        plan.int_type, make_core_effect_set([]), origin, result_slot)
    let is_negative = make_core_primitive_expr(
        plan.bool_type, make_core_effect_set([]), origin,
        make_core_primitive_op(7), [
            read_for_lt, int_literal(plan.int_type, 0, origin)
        ])
    let read_for_gt = make_core_read_expr(
        plan.int_type, make_core_effect_set([]), origin, result_slot)
    let is_positive = make_core_primitive_expr(
        plan.bool_type, make_core_effect_set([]), origin,
        make_core_primitive_op(9), [
            read_for_gt, int_literal(plan.int_type, 0, origin)
        ])
    let next = ord_fields(fields, index + 1, plan, origin)
    let negative_value = make_core_read_expr(
        plan.int_type, make_core_effect_set([]), origin, result_slot)
    let positive_value = make_core_read_expr(
        plan.int_type, make_core_effect_set([]), origin, result_slot)
    let non_negative = make_core_if_expr(
        plan.int_type, plan.header.result_effects, origin, is_positive,
        make_core_block([], some(positive_value), origin),
        make_core_block([], some(next), origin))
    let selected = make_core_if_expr(
        plan.int_type, plan.header.result_effects, origin, is_negative,
        make_core_block([], some(negative_value), origin),
        make_core_block([], some(non_negative), origin))
    make_core_match_expr(
        plan.int_type, plan.header.result_effects, origin, compared, [
            make_core_match_arm(
                make_core_binding_pattern(plan.int_type, result_slot), none,
                make_core_block([], some(selected), operation.origin),
                operation.origin)
        ])
}

fn discriminator_compare(
    left: Int, right: Int, plan: CoreDerivedOrdPlan,
    origin: OriginRef
) -> CoreExpr {
    let is_less = make_core_primitive_expr(
        plan.bool_type, make_core_effect_set([]), origin,
        make_core_primitive_op(7), [
            int_literal(plan.int_type, left, origin),
            int_literal(plan.int_type, right, origin)
        ])
    let is_greater = make_core_primitive_expr(
        plan.bool_type, make_core_effect_set([]), origin,
        make_core_primitive_op(9), [
            int_literal(plan.int_type, left, origin),
            int_literal(plan.int_type, right, origin)
        ])
    let non_less = make_core_if_expr(
        plan.int_type, plan.header.result_effects, origin, is_greater,
        make_core_block([], some(
            int_literal(plan.int_type, 1, origin)), origin),
        make_core_block([], some(
            int_literal(plan.int_type, 0, origin)), origin))
    make_core_if_expr(
        plan.int_type, plan.header.result_effects, origin, is_less,
        make_core_block([], some(
            int_literal(plan.int_type, 0 - 1, origin)), origin),
        make_core_block([], some(non_less), origin))
}

fn derived_ord_expr(plan: CoreDerivedOrdPlan) -> CoreExpr {
    match plan.value {
        CoreDerivedOrdShapeValue::StructOrd(fields) =>
            ord_fields(
                flattened_ord_fields(fields), 0,
                plan, plan.header.body_origin),
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
                            flattened_ord_fields(left_variant.fields),
                            0, plan,
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

enum CoreDerivedTextRenderPlanValue {
    RenderLeaf(CoreDerivedCallPlan),
    RenderTuple {
        fields: List<CoreFieldRef>,
        field_types: List<CoreTypeRef>,
        pieces: List<CoreDerivedTextPiece>
    },
    RenderLiteralOnly { pieces: List<CoreDerivedTextPiece> }
}
pub struct CoreDerivedTextRenderPlan {
    field: CoreFieldRef,
    ty: CoreTypeRef,
    value: CoreDerivedValueRef?,
    value_kind: CoreDerivedTextRenderPlanValue
}

pub fn make_core_derived_text_render_leaf(
    field: CoreFieldRef, ty: CoreTypeRef,
    value: CoreDerivedValueRef, render: CoreDerivedCallPlan
) -> CoreDerivedTextRenderPlan {
    if render.method.is_none() || !core_type_ref_same(value.ty, ty) ||
       (value.projections.len() > 0 && !core_field_ref_same(
            value.projections.get(value.projections.len() - 1).unwrap(),
            field)) {
        panic("Core derive text: render leaf lacks exact method identity")
    }
    CoreDerivedTextRenderPlan {
        field: field, ty: ty, value: some(value),
        value_kind: CoreDerivedTextRenderPlanValue::RenderLeaf(render)
    }
}

enum CoreDerivedTextPieceValue {
    LiteralText {
        value: Str, ty: CoreTypeRef, append: CoreDerivedCallPlan
    },
    RenderedValue {
        render: CoreDerivedTextRenderPlan,
        append: CoreDerivedCallPlan?
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
    render: CoreDerivedTextRenderPlan,
    append: CoreDerivedCallPlan?
) -> CoreDerivedTextPiece {
    match render.value_kind {
        CoreDerivedTextRenderPlanValue::RenderLeaf(_) => if append.is_none() {
            panic("Core derive text: leaf render lacks append call")
        },
        CoreDerivedTextRenderPlanValue::RenderTuple { .. } => if
                append.is_some() {
            panic("Core derive text: tuple render has redundant append call")
        },
        CoreDerivedTextRenderPlanValue::RenderLiteralOnly { .. } => if
                append.is_some() {
            panic("Core derive text: literal-only render has append call")
        }
    }
    CoreDerivedTextPiece { value: CoreDerivedTextPieceValue::RenderedValue {
        render: render, append: append
    } }
}
fn copy_text_pieces(values: List<CoreDerivedTextPiece>) -> List<CoreDerivedTextPiece> {
    let mut result: List<CoreDerivedTextPiece> = []
    for value in values { result.push(value) }
    result
}

pub fn make_core_derived_text_render_tuple(
    field: CoreFieldRef, ty: CoreTypeRef, value: CoreDerivedValueRef,
    fields: List<CoreFieldRef>, field_types: List<CoreTypeRef>,
    pieces: List<CoreDerivedTextPiece>
) -> CoreDerivedTextRenderPlan {
    if !core_type_ref_same(value.ty, ty) ||
       (value.projections.len() > 0 && !core_field_ref_same(
            value.projections.get(value.projections.len() - 1).unwrap(),
            field)) || fields.len() != field_types.len() {
        panic("Core derive text: tuple render field/type arity differs")
    }
    let mut render_index = 0
    for piece in pieces {
        match piece.value {
            CoreDerivedTextPieceValue::RenderedValue { render, .. } => {
                if render_index >= fields.len() {
                    panic("Core derive text: tuple render has extra value")
                }
                if !core_field_ref_same(
                        render.field, fields.get(render_index).unwrap()) ||
                   !core_type_ref_same(
                        render.ty, field_types.get(render_index).unwrap()) {
                    panic("Core derive text: tuple child field/type order differs")
                }
                match render.value {
                    some(child_value) => require_derived_child_projection(
                        value, child_value, fields.get(render_index).unwrap(),
                        field_types.get(render_index).unwrap(), render_index),
                    none => match render.value_kind {
                        CoreDerivedTextRenderPlanValue::RenderLiteralOnly { .. } => {},
                        _ => panic("Core derive text: tuple child source is absent")
                    }
                }
                render_index = render_index + 1
            },
            _ => {}
        }
    }
    if render_index != fields.len() {
        panic("Core derive text: tuple render omits an element")
    }
    CoreDerivedTextRenderPlan {
        field: field, ty: ty, value: some(value),
        value_kind: CoreDerivedTextRenderPlanValue::RenderTuple {
            fields: copy_fields(fields), field_types: copy_types(field_types),
            pieces: copy_text_pieces(pieces)
        }
    }
}

pub fn make_core_derived_text_render_literal_only(
    field: CoreFieldRef, ty: CoreTypeRef,
    pieces: List<CoreDerivedTextPiece>
) -> CoreDerivedTextRenderPlan {
    if pieces.len() == 0 {
        panic("Core derive text: literal-only field has no literal")
    }
    for piece in pieces {
        match piece.value {
            CoreDerivedTextPieceValue::LiteralText { .. } => {},
            _ => panic("Core derive text: literal-only field has operation")
        }
    }
    CoreDerivedTextRenderPlan {
        field: field, ty: ty, value: none,
        value_kind: CoreDerivedTextRenderPlanValue::RenderLiteralOnly {
            pieces: copy_text_pieces(pieces)
        }
    }
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

pub struct CoreDerivedTextPatternField {
    field: CoreFieldRef,
    ty: CoreTypeRef,
    binding: SlotRef?,
    rendered: Bool
}
pub fn make_core_derived_text_pattern_field(
    field: CoreFieldRef, ty: CoreTypeRef,
    binding: SlotRef?, rendered: Bool
) -> CoreDerivedTextPatternField {
    if core_field_ref_kind_tag(field) != 3 ||
       rendered != binding.is_some() {
        panic("Core derive text: variant pattern field contract differs")
    }
    CoreDerivedTextPatternField {
        field: field, ty: ty, binding: binding, rendered: rendered
    }
}
fn copy_text_pattern_fields(
    values: List<CoreDerivedTextPatternField>
) -> List<CoreDerivedTextPatternField> {
    let mut result: List<CoreDerivedTextPatternField> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreDerivedTextVariantPlan {
    variant: VariantRef,
    fields: List<CoreDerivedTextPatternField>,
    sequence: CoreDerivedTextSequence,
    origin: OriginRef
}
pub fn make_core_derived_text_variant_plan(
    variant: VariantRef, fields: List<CoreDerivedTextPatternField>,
    sequence: CoreDerivedTextSequence, origin: OriginRef
) -> CoreDerivedTextVariantPlan {
    let mut field_index = 0
    while field_index < fields.len() {
        let field = fields.get(field_index).unwrap()
        if !variant_ref_same(
                variant_field_ref_variant(core_field_ref_variant(field.field)),
                variant) {
            panic("Core derive text: pattern field crosses variant")
        }
        let mut right = field_index + 1
        while right < fields.len() {
            if core_field_ref_same(
                    field.field, fields.get(right).unwrap().field) {
                panic("Core derive text: pattern field is duplicated")
            }
            right = right + 1
        }
        let mut coverage_count = 0
        let mut render_count = 0
        for piece in sequence.pieces {
            match piece.value {
                CoreDerivedTextPieceValue::RenderedValue { render, .. } => if
                        core_field_ref_same(render.field, field.field) &&
                        core_type_ref_same(render.ty, field.ty) {
                    coverage_count = coverage_count + 1
                    match (field.binding, render.value) {
                        (some(slot), some(source)) => if
                                slot_ref_same(source.root, slot) &&
                                core_type_ref_same(source.root_type, field.ty) &&
                                source.projections.len() == 0 {
                            render_count = render_count + 1
                        },
                        (none, none) => {},
                        _ => panic(
                            "Core derive text: pattern/source presence differs")
                    }
                },
                _ => {}
            }
        }
        if coverage_count != 1 ||
           (field.rendered && render_count != 1) ||
           (!field.rendered && render_count != 0) {
            panic("Core derive text: pattern binding/render use differs")
        }
        field_index = field_index + 1
    }
    for piece in sequence.pieces {
        match piece.value {
            CoreDerivedTextPieceValue::RenderedValue { render, .. } => {
                let mut found = false
                for field in fields {
                    if core_field_ref_same(render.field, field.field) &&
                       core_type_ref_same(render.ty, field.ty) {
                        match (field.binding, render.value) {
                            (some(slot), some(source)) => if
                                    slot_ref_same(source.root, slot) &&
                                    source.projections.len() == 0 {
                                found = true
                            },
                            (none, none) => { found = true },
                            _ => {}
                        }
                    }
                }
                if !found {
                    panic("Core derive text: rendered value lacks pattern binding")
                }
            },
            _ => {}
        }
    }
    CoreDerivedTextVariantPlan {
        variant: variant, fields: copy_text_pattern_fields(fields),
        sequence: sequence, origin: origin
    }
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

fn validate_text_pieces(
    pieces: List<CoreDerivedTextPiece>,
    string_type: CoreTypeRef, unit_type: CoreTypeRef
) with {} {
    for piece in pieces {
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
                match render.value_kind {
                    CoreDerivedTextRenderPlanValue::RenderLeaf(call) => {
                        let exact_append = match append {
                            some(value) => value,
                            none => panic(
                                "Core derive text: leaf append is absent")
                        }
                        if !core_type_ref_same(call.result_type, string_type) ||
                           !core_type_ref_same(
                                exact_append.result_type, unit_type) {
                            panic("Core derive text: leaf render/append type differs")
                        }
                    },
                    CoreDerivedTextRenderPlanValue::RenderTuple {
                        pieces: nested, ..
                    } => {
                        if append.is_some() {
                            panic("Core derive text: tuple has append call")
                        }
                        validate_text_pieces(nested, string_type, unit_type)
                    },
                    CoreDerivedTextRenderPlanValue::RenderLiteralOnly {
                        pieces: literals
                    } => {
                        if append.is_some() {
                            panic("Core derive text: literal-only has append call")
                        }
                        validate_text_pieces(
                            literals, string_type, unit_type)
                    }
                }
            }
        }
    }
}

fn validate_text_sequence(
    value: CoreDerivedTextSequence,
    string_type: CoreTypeRef, unit_type: CoreTypeRef
) {
    validate_text_pieces(value.pieces, string_type, unit_type)
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
    let mut left = 0
    while left < variants.len() {
        let mut right = left + 1
        while right < variants.len() {
            if variant_ref_same(
                    variants.get(left).unwrap().variant,
                    variants.get(right).unwrap().variant) {
                panic("Core derive text: enum variant is duplicated")
            }
            right = right + 1
        }
        left = left + 1
    }
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

fn append_text_pieces(
    plan: CoreDerivedTextPlan, pieces: List<CoreDerivedTextPiece>,
    origin: OriginRef, mut statements: List<CoreStmt>
) -> List<CoreStmt> with {mut<List<CoreStmt>>} {
    for piece in pieces {
        match piece.value {
            CoreDerivedTextPieceValue::LiteralText { value, ty, append } => {
                let text = make_core_literal_expr(
                    ty, origin, make_core_str_literal(value))
                let builder_read = make_core_read_expr(
                    plan.builder_type, make_core_effect_set([]),
                    origin, plan.builder_slot)
                statements.push(make_core_expr_stmt(
                    derived_call(append, [builder_read, text]), origin))
            },
            CoreDerivedTextPieceValue::RenderedValue { render, append } =>
                match render.value_kind {
                    CoreDerivedTextRenderPlanValue::RenderLeaf(call) => {
                        let exact_append = append.unwrap()
                        let text = derived_call(
                            call, [derived_value_expr(render.value.unwrap())])
                        let builder_read = make_core_read_expr(
                            plan.builder_type, make_core_effect_set([]),
                            origin, plan.builder_slot)
                        statements.push(make_core_expr_stmt(
                            derived_call(
                                exact_append, [builder_read, text]), origin))
                    },
                    CoreDerivedTextRenderPlanValue::RenderTuple {
                        pieces: nested, ..
                    } => {
                        if append.is_some() {
                            panic("Core derive text: tuple render append drifted")
                        }
                        statements = append_text_pieces(
                            plan, nested, origin, statements)
                    },
                    CoreDerivedTextRenderPlanValue::RenderLiteralOnly {
                        pieces: literals
                    } => {
                        if append.is_some() {
                            panic("Core derive text: literal-only append drifted")
                        }
                        statements = append_text_pieces(
                            plan, literals, origin, statements)
                    }
                }
        }
    }
    statements
}

fn text_sequence_block(
    plan: CoreDerivedTextPlan, sequence: CoreDerivedTextSequence,
    origin: OriginRef
) -> CoreBlock {
    let builder_value = derived_call(plan.builder, [])
    let mut statements: List<CoreStmt> = [make_core_bind_stmt(
        plan.builder_slot, builder_value, true, origin)]
    statements = append_text_pieces(
        plan, sequence.pieces, origin, statements)
    let finish_receiver = make_core_read_expr(
        plan.builder_type, make_core_effect_set([]), origin,
        plan.builder_slot)
    let finished = derived_call(plan.finish, [finish_receiver])
    make_core_block(statements, some(finished), origin)
}

fn text_pattern_for_variant(
    target_type: CoreTypeRef, value: CoreDerivedTextVariantPlan
) -> CorePattern {
    let mut fields: List<CorePatternField> = []
    for field in value.fields {
        let pattern = match field.binding {
            some(slot) => make_core_binding_pattern(field.ty, slot),
            none => make_core_wildcard_pattern(field.ty)
        }
        fields.push(make_core_pattern_field(field.field, pattern))
    }
    make_core_variant_pattern(target_type, value.variant, fields)
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
                    plan, variant.sequence, variant.origin)
                arms.push(make_core_match_arm(
                    text_pattern_for_variant(plan.target_type, variant),
                    none, body, variant.origin))
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

// ============================================================
// Clone — recursive typed tuple reconstruction and outer nominal construct
// ============================================================

fn validate_clone_field(value: CoreDerivedFieldPlan) {
    if value.right.is_some() {
        panic("Core derive Clone: field unexpectedly has right operand")
    }
    match value.value {
        CoreDerivedFieldPlanValue::DerivedLeaf {
            operation, result_slot
        } => {
            if result_slot.is_some() ||
               !core_type_ref_same(operation.result_type, value.ty) {
                panic("Core derive Clone: leaf result/binder differs")
            }
        },
        CoreDerivedFieldPlanValue::DerivedTuple {
            constructor, children, ..
        } => {
            if constructor.is_none() {
                panic("Core derive Clone: tuple constructor is absent")
            }
            for child in children { validate_clone_field(child) }
        }
    }
}

fn clone_field_expr(value: CoreDerivedFieldPlan) -> CoreExpr {
    if value.right.is_some() {
        panic("Core derive Clone: field unexpectedly has right operand")
    }
    match value.value {
        CoreDerivedFieldPlanValue::DerivedLeaf {
            operation, result_slot
        } => {
            if result_slot.is_some() ||
               !core_type_ref_same(operation.result_type, value.ty) {
                panic("Core derive Clone: leaf result/binder differs")
            }
            derived_call(operation, [derived_value_expr(value.left)])
        },
        CoreDerivedFieldPlanValue::DerivedTuple {
            constructor, fields, field_types, children, effects, origin
        } => {
            let exact = match constructor {
                some(item) => item,
                none => panic("Core derive Clone: tuple constructor is absent")
            }
            let mut values: List<CoreFieldValue> = []
            let mut index = 0
            while index < children.len() {
                let child = children.get(index).unwrap()
                if !core_type_ref_same(
                        child.ty, field_types.get(index).unwrap()) {
                    panic("Core derive Clone: tuple child type drifted")
                }
                values.push(make_core_field_value(
                    fields.get(index).unwrap(), clone_field_expr(child)))
                index = index + 1
            }
            make_core_construct_expr(
                value.ty, effects, origin, exact, values)
        }
    }
}

pub struct CoreDerivedCloneVariantPlan {
    variant: VariantRef,
    pattern_slots: List<SlotRef>,
    fields: List<CoreDerivedFieldPlan>,
    origin: OriginRef
}
pub fn make_core_derived_clone_variant_plan(
    variant: VariantRef, pattern_slots: List<SlotRef>,
    fields: List<CoreDerivedFieldPlan>, origin: OriginRef
) -> CoreDerivedCloneVariantPlan {
    if pattern_slots.len() != fields.len() {
        panic("Core derive Clone: variant pattern census differs")
    }
    CoreDerivedCloneVariantPlan {
        variant: variant,
        pattern_slots: copy_slots(pattern_slots),
        fields: copy_derived_fields(fields), origin: origin
    }
}
fn copy_clone_variants(
    values: List<CoreDerivedCloneVariantPlan>
) -> List<CoreDerivedCloneVariantPlan> {
    let mut result: List<CoreDerivedCloneVariantPlan> = []
    for value in values { result.push(value) }
    result
}

enum CoreDerivedClonePlanValue {
    StructClone {
        constructor: CoreConstructorRef,
        fields: List<CoreDerivedFieldPlan>
    },
    EnumClone(List<CoreDerivedCloneVariantPlan>)
}
pub struct CoreDerivedClonePlan {
    header: CoreDerivedHeader,
    owner: RegisteredNominalRef,
    target_type: CoreTypeRef,
    value: CoreDerivedClonePlanValue
}

pub fn make_core_derived_struct_clone_plan(
    header: CoreDerivedHeader, owner: RegisteredNominalRef,
    target_type: CoreTypeRef, constructor: CoreConstructorRef,
    fields: List<CoreDerivedFieldPlan>
) -> CoreDerivedClonePlan {
    if header.other_slot.is_some() ||
       !core_type_ref_same(header.result_type, target_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.self_slot), target_type) ||
       core_constructor_kind_tag(constructor) != 0 ||
       !registered_nominal_ref_same(
            core_constructor_struct_owner(constructor), owner) {
        panic("Core derive Clone: struct header/constructor differs")
    }
    let mut exact_fields: List<CoreFieldRef> = []
    for field in fields {
        validate_clone_field(field)
        if field.right.is_some() ||
           !slot_ref_same(field.left.root, header.self_slot) ||
           !core_type_ref_same(field.left.root_type, target_type) {
            panic("Core derive Clone: struct field source is not self")
        }
        exact_fields.push(field.field)
    }
    let mut left = 0
    while left < exact_fields.len() {
        let mut right = left + 1
        while right < exact_fields.len() {
            if core_field_ref_same(
                    exact_fields.get(left).unwrap(),
                    exact_fields.get(right).unwrap()) {
                panic("Core derive Clone: struct field is duplicated")
            }
            right = right + 1
        }
        left = left + 1
    }
    CoreDerivedClonePlan {
        header: header, owner: owner, target_type: target_type,
        value: CoreDerivedClonePlanValue::StructClone {
            constructor: constructor, fields: copy_derived_fields(fields)
        }
    }
}

pub fn make_core_derived_enum_clone_plan(
    header: CoreDerivedHeader, owner: RegisteredNominalRef,
    target_type: CoreTypeRef,
    variants: List<CoreDerivedCloneVariantPlan>
) -> CoreDerivedClonePlan {
    if variants.len() == 0 || header.other_slot.is_some() ||
       !core_type_ref_same(header.result_type, target_type) ||
       !core_type_ref_same(
            binder_type(header.binders, header.self_slot), target_type) {
        panic("Core derive Clone: enum header/type differs")
    }
    let mut left = 0
    while left < variants.len() {
        let current = variants.get(left).unwrap()
        let mut field_index = 0
        while field_index < current.fields.len() {
            let field = current.fields.get(field_index).unwrap()
            validate_clone_field(field)
            let slot = current.pattern_slots.get(field_index).unwrap()
            if field.right.is_some() ||
               !slot_ref_same(field.left.root, slot) ||
               !core_type_ref_same(field.left.root_type, field.ty) ||
               !core_type_ref_same(
                    binder_type(header.binders, slot), field.ty) {
                panic("Core derive Clone: enum payload source/binder differs")
            }
            field_index = field_index + 1
        }
        let mut right = left + 1
        while right < variants.len() {
            if variant_ref_same(
                    variants.get(left).unwrap().variant,
                    variants.get(right).unwrap().variant) {
                panic("Core derive Clone: enum variant is duplicated")
            }
            right = right + 1
        }
        left = left + 1
    }
    CoreDerivedClonePlan {
        header: header, owner: owner, target_type: target_type,
        value: CoreDerivedClonePlanValue::EnumClone(
            copy_clone_variants(variants))
    }
}

fn clone_variant_pattern(
    target_type: CoreTypeRef, value: CoreDerivedCloneVariantPlan
) -> CorePattern {
    let mut fields: List<CorePatternField> = []
    let mut index = 0
    while index < value.fields.len() {
        let field = value.fields.get(index).unwrap()
        fields.push(make_core_pattern_field(
            field.field, make_core_binding_pattern(
                field.ty, value.pattern_slots.get(index).unwrap())))
        index = index + 1
    }
    make_core_variant_pattern(target_type, value.variant, fields)
}

pub fn elaborate_core_derived_clone_body(
    plan: CoreDerivedClonePlan
) -> CoreBody {
    let tail = match plan.value {
        CoreDerivedClonePlanValue::StructClone { constructor, fields } => {
            let mut values: List<CoreFieldValue> = []
            for field in fields {
                values.push(make_core_field_value(
                    field.field, clone_field_expr(field)))
            }
            make_core_construct_expr(
                plan.target_type, plan.header.result_effects,
                plan.header.body_origin, constructor, values)
        },
        CoreDerivedClonePlanValue::EnumClone(variants) => {
            let scrutinee = make_core_read_expr(
                plan.target_type, make_core_effect_set([]),
                plan.header.body_origin, plan.header.self_slot)
            let mut arms: List<CoreMatchArm> = []
            for variant in variants {
                let mut values: List<CoreFieldValue> = []
                for field in variant.fields {
                    values.push(make_core_field_value(
                        field.field, clone_field_expr(field)))
                }
                let constructed = make_core_construct_expr(
                    plan.target_type, plan.header.result_effects,
                    variant.origin,
                    make_core_variant_constructor(variant.variant), values)
                arms.push(make_core_match_arm(
                    clone_variant_pattern(plan.target_type, variant), none,
                    make_core_block([], some(constructed), variant.origin),
                    variant.origin))
            }
            make_core_match_expr(
                plan.target_type, plan.header.result_effects,
                plan.header.body_origin, scrutinee, arms)
        }
    }
    finalize_body(plan.header, tail)
}
