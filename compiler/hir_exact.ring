// Exact typed HIR carriers with no HExpr dependency.  Keeping these nominal
// contracts in their own module prevents recursive HIR type-graph expansion
// while HExpr/HStmt/HDecl retain the sole embedded payloads.

use types::{Type, EffectRow, types_equal}
use ir_identity::{SymbolRef, NominalFieldRef, TraitMethodRef, ImplProviderRef,
    ImplOwnerRef, OriginRef, VariantRef, VariantFieldRef, HandledEffectRef,
    ImplMethodRef, IntrinsicRef, CalleeRef, SlotRef, PathRef,
    callee_ref_is_named, callee_ref_named_symbol,
    intrinsic_ref_same, impl_method_ref_same, trait_method_ref_same,
    intrinsic_ref_symbol, make_named_callee_ref,
    RegisteredNominalRef, symbol_ref_same, registered_trait_ref_symbol,
    handled_effect_ref_same,
    nominal_field_ref_owner, nominal_field_ref_same,
    trait_method_ref_trait, trait_method_ref_member,
    impl_owner_ref_provider, impl_owner_ref_trait, impl_owner_ref_target,
    impl_owner_ref_same, impl_method_ref_member, impl_method_ref_owner,
    variant_ref_member, impl_provider_ref_same}
use ir_inventory::{ExecutableRef, BinderEntry, HandledEvidenceRef,
    executable_ref_is_named, executable_ref_named_symbol,
    handled_evidence_ref_same, handled_evidence_requirement}
use env::{RegisteredTraitContract,
    registered_trait_contract_owner,
    registered_trait_contract_methods,
    registered_trait_contract_assoc_items,
    registered_trait_contract_handled_effects,
    registered_trait_contract_dict_obligations,
    registered_trait_method_ref, registered_trait_assoc_member}

// B-104 D4 (#151): dict evidence is FIRST-CLASS in HIR.  Three reference forms:
//   Simple(name)  — a SCOPE reference: a dict PARAM (`__ring_T_Eq`, from
//                   trait_bound_param_name) or a dict LOCAL synthesised by the
//                   dict-lowering pass (`__ring_dictlocal_N`).  Borrow — the
//                   referenced binding owns the dict.
//   Static(name)  — a MODULE-LEVEL STATIC dict singleton reference (borrow):
//                   either a plain dict (`__Type_Trait` impl dict / builtin
//                   primitive dict) or a fully-static wrapped INSTANCE
//                   (dict_instance_name).  Singletons live for the program
//                   lifetime — never Clone'd, never Drop'ed, never owned.
//                   Produced by infer (plain) / dict_lower (instances).
//   Wrapped{..}   — the infer-side RESOLUTION form for a parameterized type's
//                   dict (base dict + inner dicts).  dict_lower rewrites every
//                   use site: all-static → Static(instance); any dynamic inner
//                   → a local `let __ring_dictlocal_N = HExpr::DictConstruct`
//                   + Simple(local).  After dict_lower, Wrapped survives in
//                   BinOp eq/ord_dispatch extra_dicts and in dynamic derived
//                   FieldAction evidence, whose synthetic methods construct
//                   and reclaim the wrapper directly.
pub enum DictRef {
    Simple(Str),
    Wrapped { dict: Str, trait_ref: SymbolRef,
              inner_dicts: List<DictRef> },
    Static(Str)
}

fn dict_ref_same(left: DictRef, right: DictRef) -> Bool {
    match (left, right) {
        (DictRef::Simple(a), DictRef::Simple(b)) => a == b,
        (DictRef::Static(a), DictRef::Static(b)) => a == b,
        (DictRef::Wrapped {
            dict: left_dict, trait_ref: left_trait,
            inner_dicts: left_inner
         }, DictRef::Wrapped {
            dict: right_dict, trait_ref: right_trait,
            inner_dicts: right_inner
         }) => {
            if left_dict != right_dict ||
               !symbol_ref_same(left_trait, right_trait) ||
               left_inner.len() != right_inner.len() {
                return false
            }
            for index in 0..left_inner.len() {
                if !dict_ref_same(
                        left_inner.get(index).unwrap(),
                        right_inner.get(index).unwrap()) {
                    return false
                }
            }
            true
        },
        _ => false
    }
}
// Exact 0.1 method selection.  Concrete, bound and runtime-intrinsic calls
// share one carrier so CoreHIR and every operational pass receive the selected
// identity and instantiated signature without replaying method lookup.
enum MethodCallRefValue {
    IntrinsicMethodValue(IntrinsicRef),
    ConcreteMethodValue(ImplMethodRef),
    BoundMethodValue { method: TraitMethodRef, evidence: DictRef }
}

pub struct MethodCallRef {
    value: MethodCallRefValue,
    signature: Type,
    receiver_mutable: Bool
}

pub fn make_intrinsic_method_call_ref(
    intrinsic: IntrinsicRef, signature: Type
) -> MethodCallRef {
    match signature {
        Type::FnType { .. } => MethodCallRef {
            value: MethodCallRefValue::IntrinsicMethodValue(intrinsic),
            signature: signature, receiver_mutable: false
        },
        _ => panic("HIR method call: intrinsic signature is not callable")
    }
}

pub fn method_call_ref_intrinsic(value: MethodCallRef) -> IntrinsicRef {
    match value.value {
        MethodCallRefValue::IntrinsicMethodValue(intrinsic) => intrinsic,
        _ => panic("HIR method call: non-intrinsic has no IntrinsicRef")
    }
}

pub fn make_concrete_method_call_ref(
    method: ImplMethodRef, signature: Type, receiver_mutable: Bool
) -> MethodCallRef {
    match signature {
        Type::FnType { .. } => MethodCallRef {
            value: MethodCallRefValue::ConcreteMethodValue(method),
            signature: signature, receiver_mutable: receiver_mutable
        },
        _ => panic("HIR method call: concrete signature is not callable")
    }
}

pub fn make_bound_method_call_ref(
    method: TraitMethodRef, evidence: DictRef,
    signature: Type, receiver_mutable: Bool
) -> MethodCallRef {
    match signature {
        Type::FnType { .. } => MethodCallRef {
            value: MethodCallRefValue::BoundMethodValue {
                method: method, evidence: evidence
            },
            signature: signature, receiver_mutable: receiver_mutable
        },
        _ => panic("HIR method call: bound signature is not callable")
    }
}

pub fn method_call_ref_is_intrinsic(value: MethodCallRef) -> Bool {
    match value.value {
        MethodCallRefValue::IntrinsicMethodValue(_) => true,
        _ => false
    }
}

pub fn method_call_ref_is_concrete(value: MethodCallRef) -> Bool {
    match value.value {
        MethodCallRefValue::ConcreteMethodValue(_) => true,
        _ => false
    }
}

pub fn method_call_ref_is_bound(value: MethodCallRef) -> Bool {
    match value.value {
        MethodCallRefValue::BoundMethodValue { .. } => true,
        _ => false
    }
}

pub fn method_call_ref_impl(value: MethodCallRef) -> ImplMethodRef {
    match value.value {
        MethodCallRefValue::ConcreteMethodValue(method) => method,
        _ => panic("HIR method call: non-concrete has no ImplMethodRef")
    }
}

pub fn method_call_ref_bound(value: MethodCallRef) -> TraitMethodRef {
    match value.value {
        MethodCallRefValue::BoundMethodValue { method, .. } => method,
        _ => panic("HIR method call: non-bound has no TraitMethodRef")
    }
}

pub fn method_call_ref_bound_evidence(value: MethodCallRef) -> DictRef {
    match value.value {
        MethodCallRefValue::BoundMethodValue { evidence, .. } => evidence,
        _ => panic("HIR method call: non-bound has no dictionary evidence")
    }
}

pub fn method_call_ref_signature(value: MethodCallRef) -> Type {
    value.signature
}

pub fn method_call_ref_receiver_mutable(value: MethodCallRef) -> Bool {
    value.receiver_mutable
}

pub fn method_call_ref_same(
    left: MethodCallRef, right: MethodCallRef
) -> Bool {
    let identity_same = match (left.value, right.value) {
        (MethodCallRefValue::IntrinsicMethodValue(a),
         MethodCallRefValue::IntrinsicMethodValue(b)) =>
            intrinsic_ref_same(a, b),
        (MethodCallRefValue::ConcreteMethodValue(a),
         MethodCallRefValue::ConcreteMethodValue(b)) =>
            impl_method_ref_same(a, b),
        (MethodCallRefValue::BoundMethodValue {
            method: left_method, evidence: left_evidence
         }, MethodCallRefValue::BoundMethodValue {
            method: right_method, evidence: right_evidence
         }) => trait_method_ref_same(left_method, right_method) &&
            dict_ref_same(left_evidence, right_evidence),
        _ => false
    }
    identity_same && types_equal(left.signature, right.signature) &&
        left.receiver_mutable == right.receiver_mutable
}

pub fn method_call_ref_named_symbol(value: MethodCallRef) -> SymbolRef {
    match value.value {
        MethodCallRefValue::IntrinsicMethodValue(intrinsic) =>
            intrinsic_ref_symbol(intrinsic),
        MethodCallRefValue::ConcreteMethodValue(method) =>
            impl_method_ref_member(method),
        MethodCallRefValue::BoundMethodValue { method, .. } =>
            trait_method_ref_member(method)
    }
}

pub fn method_call_ref_callee_identity(value: MethodCallRef) -> CalleeRef {
    make_named_callee_ref(method_call_ref_named_symbol(value))
}
// Pattern AST preserves source shape.  This parallel transport is the exact
// lexical slot contract consumed by RC verification and native lowering.
pub struct HPatternBinding {
    pub name: Str,
    pub def_id: Int,
    pub slot: SlotRef,
    pub ty: Type
}

enum HProjectionRefValue {
    NominalProjection(NominalFieldRef),
    VariantProjection(VariantFieldRef),
    StructuralProjection { path: PathRef, field_name: Str },
    TupleProjection(Int),
    IntrinsicProjection(IntrinsicRef)
}
pub struct HProjectionRef { value: HProjectionRefValue }
pub fn h_nominal_projection(value: NominalFieldRef) -> HProjectionRef {
    HProjectionRef { value: HProjectionRefValue::NominalProjection(value) }
}
pub fn h_variant_projection(value: VariantFieldRef) -> HProjectionRef {
    HProjectionRef { value: HProjectionRefValue::VariantProjection(value) }
}
pub fn h_structural_projection(
    value: PathRef, field_name: Str
) -> HProjectionRef {
    if field_name.len() == 0 {
        panic("HIR projection: structural field name is empty")
    }
    HProjectionRef { value: HProjectionRefValue::StructuralProjection {
        path: value, field_name: field_name } }
}
pub fn h_tuple_projection(index: Int) -> HProjectionRef {
    if index < 0 { panic("HIR projection: negative tuple index") }
    HProjectionRef { value: HProjectionRefValue::TupleProjection(index) }
}
pub fn h_intrinsic_projection(value: IntrinsicRef) -> HProjectionRef {
    HProjectionRef { value: HProjectionRefValue::IntrinsicProjection(value) }
}
pub fn h_projection_kind(value: HProjectionRef) -> Int {
    match value.value {
        HProjectionRefValue::NominalProjection(_) => 0,
        HProjectionRefValue::VariantProjection(_) => 1,
        HProjectionRefValue::StructuralProjection { .. } => 2,
        HProjectionRefValue::TupleProjection(_) => 3,
        HProjectionRefValue::IntrinsicProjection(_) => 4
    }
}
pub fn h_projection_nominal(value: HProjectionRef) -> NominalFieldRef {
    match value.value { HProjectionRefValue::NominalProjection(field) => field,
        _ => panic("HIR projection: not nominal") }
}
pub fn h_projection_variant(value: HProjectionRef) -> VariantFieldRef {
    match value.value { HProjectionRefValue::VariantProjection(field) => field,
        _ => panic("HIR projection: not variant") }
}
pub fn h_projection_structural(value: HProjectionRef) -> PathRef {
    match value.value { HProjectionRefValue::StructuralProjection { path, .. } => path,
        _ => panic("HIR projection: not structural") }
}
pub fn h_projection_structural_name(value: HProjectionRef) -> Str {
    match value.value {
        HProjectionRefValue::StructuralProjection { field_name, .. } =>
            field_name,
        _ => panic("HIR projection: not structural")
    }
}
pub fn h_projection_tuple_index(value: HProjectionRef) -> Int {
    match value.value { HProjectionRefValue::TupleProjection(index) => index,
        _ => panic("HIR projection: not tuple") }
}
pub fn h_projection_intrinsic(value: HProjectionRef) -> IntrinsicRef {
    match value.value { HProjectionRefValue::IntrinsicProjection(intrinsic) => intrinsic,
        _ => panic("HIR projection: not intrinsic") }
}

pub struct HExactCallPlan {
    callee: CalleeRef,
    method: MethodCallRef?,
    evidence: List<DictRef>,
    handled_evidence: List<HandledEvidenceRef>
}
pub fn make_h_exact_call_plan(
    callee: CalleeRef, method: MethodCallRef?, evidence: List<DictRef>,
    handled_evidence: List<HandledEvidenceRef>
) -> HExactCallPlan {
    match method {
        some(exact) => {
            if !callee_ref_is_named(callee) ||
               !symbol_ref_same(
                    callee_ref_named_symbol(callee),
                    method_call_ref_named_symbol(exact)) {
                panic("HIR exact call plan: method/callee identity differs")
            }
        },
        none => {}
    }
    HExactCallPlan { callee: callee, method: method,
        evidence: evidence.map(fn(value) { value }),
        handled_evidence: handled_evidence.map(fn(value) { value }) }
}
pub fn h_exact_call_callee(value: HExactCallPlan) -> CalleeRef {
    value.callee
}
pub fn h_exact_call_method(value: HExactCallPlan) -> MethodCallRef? {
    value.method
}
pub fn h_exact_call_evidence(value: HExactCallPlan) -> List<DictRef> {
    value.evidence.map(fn(item) { item })
}
pub fn h_exact_call_handled_evidence(
    value: HExactCallPlan
) -> List<HandledEvidenceRef> {
    value.handled_evidence.map(fn(item) { item })
}

pub fn remap_h_handled_evidence_ref(
    value: HandledEvidenceRef, sources: List<HandledEvidenceRef>,
    targets: List<HandledEvidenceRef>
) -> HandledEvidenceRef {
    if sources.len() != targets.len() {
        panic("HIR handled evidence remap: mapping arity differs")
    }
    for index in 0..sources.len() {
        let source = sources.get(index).unwrap()
        let target = targets.get(index).unwrap()
        if !handled_effect_ref_same(
                handled_evidence_requirement(source),
                handled_evidence_requirement(target)) {
            panic("HIR handled evidence remap: requirement differs")
        }
        if handled_evidence_ref_same(value, source) { return target }
    }
    value
}

pub fn remap_h_handled_evidence_refs(
    values: List<HandledEvidenceRef>, sources: List<HandledEvidenceRef>,
    targets: List<HandledEvidenceRef>
) -> List<HandledEvidenceRef> {
    let mut result: List<HandledEvidenceRef> = []
    for value in values {
        result.push(remap_h_handled_evidence_ref(value, sources, targets))
    }
    result
}

pub fn remap_h_exact_call_handled_evidence(
    value: HExactCallPlan, sources: List<HandledEvidenceRef>,
    targets: List<HandledEvidenceRef>
) -> HExactCallPlan {
    make_h_exact_call_plan(
        value.callee, value.method, value.evidence,
        remap_h_handled_evidence_refs(
            value.handled_evidence, sources, targets))
}

enum HOperatorPlanValue {
    OperatorMethod(MethodCallRef),
    TupleOperator(List<HOperatorPlan>)
}
pub struct HOperatorPlan { value: HOperatorPlanValue }
fn copy_h_operator_plans(values: List<HOperatorPlan>) -> List<HOperatorPlan> {
    let mut result: List<HOperatorPlan> = []
    for value in values { result.push(value) }
    result
}
pub fn h_operator_method(value: MethodCallRef) -> HOperatorPlan {
    HOperatorPlan { value: HOperatorPlanValue::OperatorMethod(value) }
}
pub fn h_operator_tuple(values: List<HOperatorPlan>) -> HOperatorPlan {
    HOperatorPlan { value: HOperatorPlanValue::TupleOperator(
        copy_h_operator_plans(values)) }
}
pub fn h_operator_is_tuple(value: HOperatorPlan) -> Bool {
    match value.value { HOperatorPlanValue::TupleOperator(_) => true,
        _ => false }
}
pub fn h_operator_method_ref(value: HOperatorPlan) -> MethodCallRef {
    match value.value { HOperatorPlanValue::OperatorMethod(method) => method,
        _ => panic("HIR operator plan: tuple has no single MethodCallRef") }
}
pub fn h_operator_elements(value: HOperatorPlan) -> List<HOperatorPlan> {
    match value.value { HOperatorPlanValue::TupleOperator(values) =>
        copy_h_operator_plans(values),
        _ => panic("HIR operator plan: method has no tuple elements") }
}

enum HConstructorPlanValue {
    ExecutableConstructor { executable: ExecutableRef,
                            fields: List<HProjectionRef> },
    TupleStructural { arity: Int },
    RecordStructural { fields: List<HProjectionRef> }
}
pub struct HConstructorPlan { value: HConstructorPlanValue }
pub fn make_h_executable_constructor_plan(
    executable: ExecutableRef, fields: List<HProjectionRef>
) -> HConstructorPlan {
    HConstructorPlan { value: HConstructorPlanValue::ExecutableConstructor {
        executable: executable, fields: fields.map(fn(value) { value }) } }
}
pub fn make_h_tuple_constructor_plan(arity: Int) -> HConstructorPlan {
    if arity < 0 { panic("HIR constructor: negative tuple arity") }
    HConstructorPlan { value: HConstructorPlanValue::TupleStructural {
        arity: arity } }
}
pub fn make_h_record_constructor_plan(
    fields: List<HProjectionRef>
) -> HConstructorPlan {
    HConstructorPlan { value: HConstructorPlanValue::RecordStructural {
        fields: fields.map(fn(value) { value }) } }
}
pub fn h_constructor_kind(value: HConstructorPlan) -> Int {
    match value.value {
        HConstructorPlanValue::ExecutableConstructor { .. } => 0,
        HConstructorPlanValue::TupleStructural { .. } => 1,
        HConstructorPlanValue::RecordStructural { .. } => 2
    }
}
pub fn h_constructor_executable(value: HConstructorPlan) -> ExecutableRef {
    match value.value {
        HConstructorPlanValue::ExecutableConstructor { executable, .. } =>
            executable,
        _ => panic("HIR constructor: structural plan has no executable")
    }
}
pub fn h_constructor_fields(value: HConstructorPlan) -> List<HProjectionRef> {
    match value.value {
        HConstructorPlanValue::ExecutableConstructor { fields, .. } |
        HConstructorPlanValue::RecordStructural { fields } =>
            fields.map(fn(item) { item }),
        HConstructorPlanValue::TupleStructural { .. } =>
            panic("HIR constructor: tuple plan has no stored fields")
    }
}
pub fn h_constructor_tuple_arity(value: HConstructorPlan) -> Int {
    match value.value {
        HConstructorPlanValue::TupleStructural { arity } => arity,
        _ => panic("HIR constructor: executable/record plan has no tuple arity")
    }
}

pub struct HStringInterpPlan {
    builder_binder: BinderEntry,
    builder: HExactCallPlan,
    append_literal: HExactCallPlan,
    append_value: HExactCallPlan,
    finish: HExactCallPlan,
    value_to_string: List<HExactCallPlan>
}
pub fn make_h_string_interp_plan(
    builder_binder: BinderEntry, builder: HExactCallPlan,
    append_literal: HExactCallPlan,
    append_value: HExactCallPlan, finish: HExactCallPlan,
    value_to_string: List<HExactCallPlan>
) -> HStringInterpPlan {
    HStringInterpPlan { builder_binder: builder_binder, builder: builder,
        append_literal: append_literal, append_value: append_value,
        finish: finish,
        value_to_string: value_to_string.map(fn(value) { value }) }
}
pub fn h_string_interp_builder_binder(
    value: HStringInterpPlan
) -> BinderEntry { value.builder_binder }
pub fn h_string_interp_builder(value: HStringInterpPlan) -> HExactCallPlan {
    value.builder
}
pub fn h_string_interp_append_literal(value: HStringInterpPlan) -> HExactCallPlan {
    value.append_literal
}
pub fn h_string_interp_append_value(value: HStringInterpPlan) -> HExactCallPlan {
    value.append_value
}
pub fn h_string_interp_finish(value: HStringInterpPlan) -> HExactCallPlan {
    value.finish
}
pub fn h_string_interp_value_to_string(
    value: HStringInterpPlan
) -> List<HExactCallPlan> { value.value_to_string.map(fn(item) { item }) }

pub fn remap_h_string_interp_handled_evidence(
    value: HStringInterpPlan, sources: List<HandledEvidenceRef>,
    targets: List<HandledEvidenceRef>
) -> HStringInterpPlan {
    let mut value_to_string: List<HExactCallPlan> = []
    for call in value.value_to_string {
        value_to_string.push(remap_h_exact_call_handled_evidence(
            call, sources, targets))
    }
    make_h_string_interp_plan(
        value.builder_binder,
        remap_h_exact_call_handled_evidence(
            value.builder, sources, targets),
        remap_h_exact_call_handled_evidence(
            value.append_literal, sources, targets),
        remap_h_exact_call_handled_evidence(
            value.append_value, sources, targets),
        remap_h_exact_call_handled_evidence(
            value.finish, sources, targets),
        value_to_string)
}

pub struct HDictConstructPlan {
    constructor: ExecutableRef,
    trait_ref: SymbolRef
}
pub fn make_h_dict_construct_plan(
    constructor: ExecutableRef, trait_ref: SymbolRef
) -> HDictConstructPlan {
    HDictConstructPlan { constructor: constructor, trait_ref: trait_ref }
}
pub fn h_dict_construct_executable(value: HDictConstructPlan) -> ExecutableRef {
    value.constructor
}
pub fn h_dict_construct_trait(value: HDictConstructPlan) -> SymbolRef {
    value.trait_ref
}

pub struct HDelegateMethodPlan {
    required_method: TraitMethodRef,
    generated_method: ImplMethodRef,
    executable: ExecutableRef,
    origin: OriginRef,
    child_call: MethodCallRef,
    child_callee: CalleeRef,
    binders: List<BinderEntry>,
    parameter_types: List<Type>,
    result_type: Type,
    effects: EffectRow,
    evidence: List<DictRef>,
    handled_evidence_bindings: List<HandledEvidenceRef>,
    handled_evidence_uses: List<HandledEvidenceRef>
}
pub fn make_h_delegate_method_plan(
    required_method: TraitMethodRef, generated_method: ImplMethodRef,
    executable: ExecutableRef, origin: OriginRef,
    child_call: MethodCallRef, child_callee: CalleeRef,
    binders: List<BinderEntry>, parameter_types: List<Type>,
    result_type: Type, effects: EffectRow, evidence: List<DictRef>,
    handled_evidence_bindings: List<HandledEvidenceRef>,
    handled_evidence_uses: List<HandledEvidenceRef>
) -> HDelegateMethodPlan {
    if !executable_ref_is_named(executable) ||
       !symbol_ref_same(executable_ref_named_symbol(executable),
            impl_method_ref_member(generated_method)) {
        panic("HIR delegate plan: generated method/executable differs")
    }
    HDelegateMethodPlan {
        required_method: required_method, generated_method: generated_method,
        executable: executable, origin: origin,
        child_call: child_call, child_callee: child_callee,
        binders: binders.map(fn(value) { value }),
        parameter_types: parameter_types.map(fn(value) { value }),
        result_type: result_type,
        effects: EffectRow { effects: effects.effects, tail: effects.tail },
        evidence: evidence.map(fn(value) { value }),
        handled_evidence_bindings:
            handled_evidence_bindings.map(fn(value) { value }),
        handled_evidence_uses:
            handled_evidence_uses.map(fn(value) { value })
    }
}
pub fn h_delegate_method_required(value: HDelegateMethodPlan) -> TraitMethodRef {
    value.required_method
}
pub fn h_delegate_method_generated(value: HDelegateMethodPlan) -> ImplMethodRef {
    value.generated_method
}
pub fn h_delegate_method_executable(value: HDelegateMethodPlan) -> ExecutableRef {
    value.executable
}
pub fn h_delegate_method_origin(value: HDelegateMethodPlan) -> OriginRef {
    value.origin
}
pub fn h_delegate_method_child_call(value: HDelegateMethodPlan) -> MethodCallRef {
    value.child_call
}
pub fn h_delegate_method_child_callee(value: HDelegateMethodPlan) -> CalleeRef {
    value.child_callee
}
pub fn h_delegate_method_binders(value: HDelegateMethodPlan) -> List<BinderEntry> {
    value.binders.map(fn(item) { item })
}
pub fn h_delegate_method_parameter_types(value: HDelegateMethodPlan) -> List<Type> {
    value.parameter_types.map(fn(item) { item })
}
pub fn h_delegate_method_result_type(value: HDelegateMethodPlan) -> Type {
    value.result_type
}
pub fn h_delegate_method_effects(value: HDelegateMethodPlan) -> EffectRow {
    EffectRow { effects: value.effects.effects, tail: value.effects.tail }
}
pub fn h_delegate_method_evidence(value: HDelegateMethodPlan) -> List<DictRef> {
    value.evidence.map(fn(item) { item })
}
pub fn h_delegate_method_handled_bindings(
    value: HDelegateMethodPlan
) -> List<HandledEvidenceRef> {
    value.handled_evidence_bindings.map(fn(item) { item })
}
pub fn h_delegate_method_handled_uses(
    value: HDelegateMethodPlan
) -> List<HandledEvidenceRef> {
    value.handled_evidence_uses.map(fn(item) { item })
}

pub struct HDelegateAssocPlan { member: SymbolRef, ty: Type }
pub fn make_h_delegate_assoc_plan(
    member: SymbolRef, ty: Type
) -> HDelegateAssocPlan { HDelegateAssocPlan { member: member, ty: ty } }
pub fn h_delegate_assoc_member(value: HDelegateAssocPlan) -> SymbolRef {
    value.member
}
pub fn h_delegate_assoc_type(value: HDelegateAssocPlan) -> Type { value.ty }

pub struct HDelegateTypedPlan {
    contract: RegisteredTraitContract,
    outer_owner: ImplOwnerRef,
    child_owner: ImplOwnerRef,
    child_provider: ImplProviderRef,
    field_owner: ImplOwnerRef,
    field_provider: ImplProviderRef,
    field_target: SymbolRef,
    field: NominalFieldRef,
    trait_ref: SymbolRef,
    source_member_index: Int,
    methods: List<HDelegateMethodPlan>,
    assoc_bindings: List<HDelegateAssocPlan>,
    handled_evidence: List<HandledEffectRef>,
    dict_evidence: List<DictRef>
}
pub fn make_h_delegate_typed_plan(
    contract: RegisteredTraitContract,
    outer_owner: ImplOwnerRef, child_owner: ImplOwnerRef,
    child_provider: ImplProviderRef, field_owner: ImplOwnerRef,
    field_provider: ImplProviderRef, field_target: SymbolRef,
    field: NominalFieldRef, trait_ref: SymbolRef,
    source_member_index: Int, methods: List<HDelegateMethodPlan>,
    assoc_bindings: List<HDelegateAssocPlan>,
    handled_evidence: List<HandledEffectRef>, dict_evidence: List<DictRef>
) -> HDelegateTypedPlan {
    if !symbol_ref_same(
            registered_trait_ref_symbol(
                registered_trait_contract_owner(contract)),
            trait_ref) {
        panic("HIR delegate plan: frozen contract trait differs")
    }
    if source_member_index < 0 ||
       !impl_provider_ref_same(
            impl_owner_ref_provider(child_owner), child_provider) ||
       !impl_provider_ref_same(
            impl_owner_ref_provider(field_owner), field_provider) {
        panic("HIR delegate plan: provider/owner relation differs")
    }
    if !symbol_ref_same(impl_owner_ref_target(field_owner), field_target) ||
       !symbol_ref_same(nominal_field_ref_owner(field),
            impl_owner_ref_target(outer_owner)) {
        panic("HIR delegate plan: field owner/target relation differs")
    }
    match impl_owner_ref_trait(child_owner) {
        some(exact_trait) => if !symbol_ref_same(exact_trait, trait_ref) {
            panic("HIR delegate plan: child trait differs")
        },
        none => panic("HIR delegate plan: child owner is inherent")
    }
    for method in methods {
        if !impl_owner_ref_same(
                impl_method_ref_owner(method.generated_method), child_owner) ||
           !symbol_ref_same(
                trait_method_ref_trait(method.required_method), trait_ref) {
            panic("HIR delegate plan: method owner/trait relation differs")
        }
    }
    let contract_methods = registered_trait_contract_methods(contract)
    if contract_methods.len() != methods.len() {
        panic("HIR delegate plan: frozen method census differs")
    }
    for index in 0..contract_methods.len() {
        if !trait_method_ref_same(
                registered_trait_method_ref(
                    contract_methods.get(index).unwrap()),
                methods.get(index).unwrap().required_method) {
            panic("HIR delegate plan: frozen method order differs")
        }
    }
    let contract_assoc = registered_trait_contract_assoc_items(contract)
    if contract_assoc.len() != assoc_bindings.len() {
        panic("HIR delegate plan: frozen assoc census differs")
    }
    for index in 0..contract_assoc.len() {
        if !symbol_ref_same(
                registered_trait_assoc_member(
                    contract_assoc.get(index).unwrap()),
                assoc_bindings.get(index).unwrap().member) {
            panic("HIR delegate plan: frozen assoc order differs")
        }
    }
    let contract_effects = registered_trait_contract_handled_effects(contract)
    if contract_effects.len() != handled_evidence.len() {
        panic("HIR delegate plan: frozen handled census differs")
    }
    for index in 0..contract_effects.len() {
        if !handled_effect_ref_same(
                contract_effects.get(index).unwrap(),
                handled_evidence.get(index).unwrap()) {
            panic("HIR delegate plan: frozen handled order differs")
        }
    }
    if registered_trait_contract_dict_obligations(contract).len() !=
           dict_evidence.len() {
        panic("HIR delegate plan: frozen dictionary census differs")
    }
    HDelegateTypedPlan {
        contract: contract,
        outer_owner: outer_owner, child_owner: child_owner,
        child_provider: child_provider, field_owner: field_owner,
        field_provider: field_provider, field_target: field_target,
        field: field, trait_ref: trait_ref,
        source_member_index: source_member_index,
        methods: methods.map(fn(value) { value }),
        assoc_bindings: assoc_bindings.map(fn(value) { value }),
        handled_evidence: handled_evidence.map(fn(value) { value }),
        dict_evidence: dict_evidence.map(fn(value) { value })
    }
}
pub fn h_delegate_contract(
    value: HDelegateTypedPlan
) -> RegisteredTraitContract { value.contract }
pub fn h_delegate_outer_owner(value: HDelegateTypedPlan) -> ImplOwnerRef { value.outer_owner }
pub fn h_delegate_child_owner(value: HDelegateTypedPlan) -> ImplOwnerRef { value.child_owner }
pub fn h_delegate_child_provider(value: HDelegateTypedPlan) -> ImplProviderRef { value.child_provider }
pub fn h_delegate_field_owner(value: HDelegateTypedPlan) -> ImplOwnerRef { value.field_owner }
pub fn h_delegate_field_provider(value: HDelegateTypedPlan) -> ImplProviderRef { value.field_provider }
pub fn h_delegate_field_target(value: HDelegateTypedPlan) -> SymbolRef { value.field_target }
pub fn h_delegate_field(value: HDelegateTypedPlan) -> NominalFieldRef { value.field }
pub fn h_delegate_trait(value: HDelegateTypedPlan) -> SymbolRef { value.trait_ref }
pub fn h_delegate_source_member_index(value: HDelegateTypedPlan) -> Int { value.source_member_index }
pub fn h_delegate_methods(value: HDelegateTypedPlan) -> List<HDelegateMethodPlan> {
    value.methods.map(fn(item) { item })
}
pub fn h_delegate_assoc_bindings(value: HDelegateTypedPlan) -> List<HDelegateAssocPlan> {
    value.assoc_bindings.map(fn(item) { item })
}
pub fn h_delegate_handled_evidence(value: HDelegateTypedPlan) -> List<HandledEffectRef> {
    value.handled_evidence.map(fn(item) { item })
}
pub fn h_delegate_dict_evidence(value: HDelegateTypedPlan) -> List<DictRef> {
    value.dict_evidence.map(fn(item) { item })
}

pub struct HDefaultSpecializationPlan {
    owner: ImplOwnerRef,
    generated_method: ImplMethodRef,
    generated_executable: ExecutableRef,
    source_method: TraitMethodRef,
    default_executable: ExecutableRef,
    parameter_types: List<Type>,
    parameter_mutabilities: List<Bool>,
    binders: List<BinderEntry>,
    result_type: Type,
    effects: EffectRow,
    forward_call: HExactCallPlan
}

pub fn make_h_default_specialization_plan(
    owner: ImplOwnerRef, generated_method: ImplMethodRef,
    generated_executable: ExecutableRef,
    source_method: TraitMethodRef, default_executable: ExecutableRef,
    parameter_types: List<Type>, parameter_mutabilities: List<Bool>,
    binders: List<BinderEntry>,
    result_type: Type, effects: EffectRow,
    forward_call: HExactCallPlan
) -> HDefaultSpecializationPlan {
    if !impl_owner_ref_same(
            impl_method_ref_owner(generated_method), owner) ||
       !executable_ref_is_named(generated_executable) ||
       !symbol_ref_same(
            executable_ref_named_symbol(generated_executable),
            impl_method_ref_member(generated_method)) ||
       !executable_ref_is_named(default_executable) ||
       !symbol_ref_same(
            executable_ref_named_symbol(default_executable),
            trait_method_ref_member(source_method)) ||
       parameter_types.len() != parameter_mutabilities.len() ||
       parameter_types.len() != binders.len() ||
       !symbol_ref_same(
            trait_method_ref_trait(source_method),
            impl_owner_ref_trait(owner).unwrap_or_else(fn() {
                panic("default specialization: owner is inherent")
            })) {
        panic("default specialization: exact owner/method relation differs")
    }
    HDefaultSpecializationPlan {
        owner: owner, generated_method: generated_method,
        generated_executable: generated_executable,
        source_method: source_method,
        default_executable: default_executable,
        parameter_types: parameter_types.map(fn(value) { value }),
        parameter_mutabilities:
            parameter_mutabilities.map(fn(value) { value }),
        binders: binders.map(fn(value) { value }),
        result_type: result_type,
        effects: EffectRow { effects: effects.effects, tail: effects.tail },
        forward_call: forward_call
    }
}
pub fn h_default_specialization_owner(
    value: HDefaultSpecializationPlan
) -> ImplOwnerRef { value.owner }
pub fn h_default_specialization_generated_method(
    value: HDefaultSpecializationPlan
) -> ImplMethodRef { value.generated_method }
pub fn h_default_specialization_generated_executable(
    value: HDefaultSpecializationPlan
) -> ExecutableRef { value.generated_executable }
pub fn h_default_specialization_source_method(
    value: HDefaultSpecializationPlan
) -> TraitMethodRef { value.source_method }
pub fn h_default_specialization_default_executable(
    value: HDefaultSpecializationPlan
) -> ExecutableRef { value.default_executable }
pub fn h_default_specialization_parameter_types(
    value: HDefaultSpecializationPlan
) -> List<Type> { value.parameter_types.map(fn(item) { item }) }
pub fn h_default_specialization_parameter_mutabilities(
    value: HDefaultSpecializationPlan
) -> List<Bool> { value.parameter_mutabilities.map(fn(item) { item }) }
pub fn h_default_specialization_binders(
    value: HDefaultSpecializationPlan
) -> List<BinderEntry> { value.binders.map(fn(item) { item }) }
pub fn h_default_specialization_result_type(
    value: HDefaultSpecializationPlan
) -> Type { value.result_type }
pub fn h_default_specialization_effects(
    value: HDefaultSpecializationPlan
) -> EffectRow { value.effects }
pub fn h_default_specialization_forward_call(
    value: HDefaultSpecializationPlan
) -> HExactCallPlan { value.forward_call }

enum HPatternPlanValue {
    WildcardPattern,
    BindingPattern(HPatternBinding),
    LiteralPattern,
    TuplePattern(List<HPatternPlan>),
    StructPattern { owner: RegisteredNominalRef,
                    fields: List<HPatternFieldPlan> },
    VariantPattern { variant: VariantRef,
                     fields: List<HPatternFieldPlan> },
    OrPattern(List<HPatternPlan>)
}
pub struct HPatternPlan { value: HPatternPlanValue }
pub struct HPatternFieldPlan {
    projection: HProjectionRef,
    pattern: HPatternPlan
}
fn copy_h_pattern_plans(values: List<HPatternPlan>) -> List<HPatternPlan> {
    let mut result: List<HPatternPlan> = []
    for value in values { result.push(value) }
    result
}
fn copy_h_pattern_field_plans(
    values: List<HPatternFieldPlan>
) -> List<HPatternFieldPlan> {
    let mut result: List<HPatternFieldPlan> = []
    for value in values { result.push(value) }
    result
}
pub fn make_h_pattern_field_plan(
    projection: HProjectionRef, pattern: HPatternPlan
) -> HPatternFieldPlan {
    HPatternFieldPlan { projection: projection, pattern: pattern }
}
pub fn h_pattern_field_projection(value: HPatternFieldPlan) -> HProjectionRef {
    value.projection
}
pub fn h_pattern_field_pattern(value: HPatternFieldPlan) -> HPatternPlan {
    value.pattern
}
pub fn h_pattern_wildcard() -> HPatternPlan {
    HPatternPlan { value: HPatternPlanValue::WildcardPattern }
}
pub fn h_pattern_binding(value: HPatternBinding) -> HPatternPlan {
    HPatternPlan { value: HPatternPlanValue::BindingPattern(value) }
}
pub fn h_pattern_literal() -> HPatternPlan {
    HPatternPlan { value: HPatternPlanValue::LiteralPattern }
}
pub fn h_pattern_tuple(values: List<HPatternPlan>) -> HPatternPlan {
    HPatternPlan { value: HPatternPlanValue::TuplePattern(
        copy_h_pattern_plans(values)) }
}
pub fn h_pattern_struct(
    owner: RegisteredNominalRef, fields: List<HPatternFieldPlan>
) -> HPatternPlan {
    HPatternPlan { value: HPatternPlanValue::StructPattern {
        owner: owner, fields: copy_h_pattern_field_plans(fields) } }
}
pub fn h_pattern_variant(
    variant: VariantRef, fields: List<HPatternFieldPlan>
) -> HPatternPlan {
    HPatternPlan { value: HPatternPlanValue::VariantPattern {
        variant: variant, fields: copy_h_pattern_field_plans(fields) } }
}
pub fn h_pattern_or(values: List<HPatternPlan>) -> HPatternPlan {
    if values.len() < 2 {
        panic("HIR pattern plan: OrPattern has fewer than two alternatives")
    }
    HPatternPlan { value: HPatternPlanValue::OrPattern(
        copy_h_pattern_plans(values)) }
}
pub fn h_pattern_kind(value: HPatternPlan) -> Int {
    match value.value {
        HPatternPlanValue::WildcardPattern => 0,
        HPatternPlanValue::BindingPattern(_) => 1,
        HPatternPlanValue::LiteralPattern => 2,
        HPatternPlanValue::TuplePattern(_) => 3,
        HPatternPlanValue::StructPattern { .. } => 4,
        HPatternPlanValue::VariantPattern { .. } => 5,
        HPatternPlanValue::OrPattern(_) => 6
    }
}
pub fn h_pattern_plan_binding(value: HPatternPlan) -> HPatternBinding {
    match value.value { HPatternPlanValue::BindingPattern(binding) => binding,
        _ => panic("HIR pattern plan: not binding") }
}
pub fn h_pattern_plan_children(value: HPatternPlan) -> List<HPatternPlan> {
    match value.value {
        HPatternPlanValue::TuplePattern(values) |
        HPatternPlanValue::OrPattern(values) => copy_h_pattern_plans(values),
        _ => panic("HIR pattern plan: no positional children")
    }
}
pub fn h_pattern_plan_fields(value: HPatternPlan) -> List<HPatternFieldPlan> {
    match value.value {
        HPatternPlanValue::StructPattern { fields, .. } |
        HPatternPlanValue::VariantPattern { fields, .. } =>
            copy_h_pattern_field_plans(fields),
        _ => panic("HIR pattern plan: no projected fields")
    }
}
pub fn h_pattern_plan_struct_owner(value: HPatternPlan) -> RegisteredNominalRef {
    match value.value { HPatternPlanValue::StructPattern { owner, .. } => owner,
        _ => panic("HIR pattern plan: not struct") }
}
pub fn h_pattern_plan_variant(value: HPatternPlan) -> VariantRef {
    match value.value { HPatternPlanValue::VariantPattern { variant, .. } => variant,
        _ => panic("HIR pattern plan: not variant") }
}

pub struct HForInPlan {
    iter: HExactCallPlan,
    has_next: HExactCallPlan,
    next: HExactCallPlan,
    iterator_binder: BinderEntry,
    item_binder: BinderEntry,
    binding_binder: BinderEntry,
    destructure_binders: List<BinderEntry>
}
pub fn make_h_for_in_plan(
    iter: HExactCallPlan, has_next: HExactCallPlan,
    next: HExactCallPlan, iterator_binder: BinderEntry,
    item_binder: BinderEntry, binding_binder: BinderEntry,
    destructure_binders: List<BinderEntry>
) -> HForInPlan {
    HForInPlan { iter: iter, has_next: has_next, next: next,
        iterator_binder: iterator_binder, item_binder: item_binder,
        binding_binder: binding_binder,
        destructure_binders: destructure_binders.map(fn(value) { value }) }
}
pub fn h_for_in_iter(value: HForInPlan) -> HExactCallPlan { value.iter }
pub fn h_for_in_has_next(value: HForInPlan) -> HExactCallPlan { value.has_next }
pub fn h_for_in_next(value: HForInPlan) -> HExactCallPlan { value.next }
pub fn h_for_in_iterator_binder(value: HForInPlan) -> BinderEntry {
    value.iterator_binder
}
pub fn h_for_in_item_binder(value: HForInPlan) -> BinderEntry {
    value.item_binder
}
pub fn h_for_in_binding_binder(value: HForInPlan) -> BinderEntry {
    value.binding_binder
}
pub fn h_for_in_destructure_binders(value: HForInPlan) -> List<BinderEntry> {
    value.destructure_binders.map(fn(item) { item })
}
pub fn remap_h_for_in_handled_evidence(
    value: HForInPlan, sources: List<HandledEvidenceRef>,
    targets: List<HandledEvidenceRef>
) -> HForInPlan {
    make_h_for_in_plan(
        remap_h_exact_call_handled_evidence(value.iter, sources, targets),
        remap_h_exact_call_handled_evidence(
            value.has_next, sources, targets),
        remap_h_exact_call_handled_evidence(value.next, sources, targets),
        value.iterator_binder, value.item_binder, value.binding_binder,
        value.destructure_binders)
}
pub struct HFailOperationRef { tag: Int }
pub fn h_fail_raise_ref() -> HFailOperationRef {
    HFailOperationRef { tag: 0 }
}
pub fn h_fail_operation_tag(value: HFailOperationRef) -> Int {
    if value.tag != 0 { panic("HIR fail operation: invalid tag") }
    value.tag
}
