// Exact typed HIR carriers with no HExpr dependency.  Keeping these nominal
// contracts in their own module prevents recursive HIR type-graph expansion
// while HExpr/HStmt/HDecl retain the sole embedded payloads.

use types::{Type, EffectRow, types_equal}
use ir_identity::{SymbolRef, NominalFieldRef, TraitMethodRef,
    ImplOwnerRef, VariantRef, VariantFieldRef,
    ImplMethodRef, IntrinsicRef, CalleeRef, SlotRef, PathRef,
    callee_ref_is_named, callee_ref_named_symbol,
    intrinsic_ref_same, impl_method_ref_same, trait_method_ref_same,
    intrinsic_ref_symbol, make_named_callee_ref,
    RegisteredNominalRef, symbol_ref_same, registered_nominal_ref_symbol,
    nominal_field_ref_owner, nominal_field_ref_index,
    nominal_field_ref_same,
    variant_field_ref_same,
    trait_method_ref_member,
    impl_owner_ref_trait,
    impl_owner_ref_stable_key,
    impl_method_ref_member,
    slot_ref_is_source, slot_ref_source_domain, slot_ref_stable_key,
    slot_domain_dictionary, slot_domain_same}
use ir_inventory::{ExecutableRef, BinderEntry, EffectCtxRef,
    ExactDictRef, dict_ref_same, dict_ref_is_local, dict_ref_is_static,
    dict_ref_is_wrapped, dict_ref_local, dict_ref_static,
    dict_ref_wrapped_base, dict_ref_wrapped_inner,
    executable_ref_is_named, executable_ref_named_symbol,
    effect_ctx_ref_same}
use effect_contract::{
    TypedEffectCtxSource,
    typed_effect_ctx_source_is_empty, typed_effect_ctx_source_context,
    make_empty_effect_ctx_source, make_borrowed_effect_ctx_source}

// B-104 D4 (#151): dict evidence is FIRST-CLASS in HIR.  Three reference forms:
//   Simple(name)  — a SCOPE reference: a dict PARAM (`__ring_T_Eq`, from
//                   trait_bound_param_name) or a dict LOCAL synthesised by the
//                   dict-lowering pass (`__ring_dictlocal_N`).  Borrow — the
//                   referenced binding owns the dict.
//   Static(name)  — a MODULE-LEVEL STATIC dict singleton reference (borrow):
//                   either a plain dict (`__Type_Trait` impl dict / builtin
//                   primitive dict) or a fully-static wrapped INSTANCE
//                   (exact_dict_physical_key).  Singletons live for the program
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
enum PhysicalDictRefValue {
    SimplePhysicalValue(Str),
    WrappedPhysicalValue {
        dict: Str, trait_ref: SymbolRef, inner_dicts: List<DictRef>
    },
    StaticPhysicalValue(Str)
}

// Source spellings survive only as physical/diagnostic provenance.  Exact
// identity is mandatory and is the sole equality/Core authority.
pub struct DictRef {
    physical: PhysicalDictRefValue,
    exact: ExactDictRef
}

pub fn make_simple_dict_ref(name: Str, exact: ExactDictRef) -> DictRef {
    if name == "" || !dict_ref_is_local(exact) {
        panic("HIR dictionary: simple evidence lacks exact local identity")
    }
    DictRef {
        physical: PhysicalDictRefValue::SimplePhysicalValue(name), exact: exact
    }
}

pub fn make_static_dict_ref(name: Str, exact: ExactDictRef) -> DictRef {
    if name == "" || (!dict_ref_is_static(exact) && !dict_ref_is_wrapped(exact)) {
        panic("HIR dictionary: static evidence lacks exact static identity")
    }
    DictRef {
        physical: PhysicalDictRefValue::StaticPhysicalValue(name), exact: exact
    }
}

pub fn make_wrapped_dict_ref(
    dict: Str, trait_ref: SymbolRef, inner_dicts: List<DictRef>,
    exact: ExactDictRef
) -> DictRef {
    if dict == "" || !dict_ref_is_wrapped(exact) {
        panic("HIR dictionary: wrapped evidence lacks exact identity")
    }
    let exact_inner = dict_ref_wrapped_inner(exact)
    if exact_inner.len() != inner_dicts.len() {
        panic("HIR dictionary: wrapped evidence arity differs")
    }
    let mut index = 0
    while index < inner_dicts.len() {
        if !dict_ref_same(
                exact_inner.get(index).unwrap(),
                inner_dicts.get(index).unwrap().exact) {
            panic("HIR dictionary: wrapped evidence order differs")
        }
        index = index + 1
    }
    DictRef { physical: PhysicalDictRefValue::WrappedPhysicalValue {
        dict: dict, trait_ref: trait_ref,
        inner_dicts: inner_dicts.map(fn(value) { value })
    }, exact: exact }
}

pub fn dict_ref_exact(value: DictRef) -> ExactDictRef { value.exact }

fn exact_dict_key_atom(value: Str) -> Str {
    "${value.len().to_str()}:${value}"
}

// Complete physical adapter key for one exact dictionary tree. Every node
// records its tag and arity; owner/slot identities and recursively ordered
// children are length-prefixed before composition. Physical backends may
// encode this key, but must not reconstruct it from HIR spellings.
pub fn exact_dict_physical_key(value: ExactDictRef) -> Str with {} {
    if dict_ref_is_local(value) {
        return [
            exact_dict_key_atom("local-dict-v1"),
            exact_dict_key_atom("0"),
            exact_dict_key_atom(slot_ref_stable_key(dict_ref_local(value)))
        ].join("/")
    }
    if dict_ref_is_static(value) {
        return [
            exact_dict_key_atom("static-dict-v1"),
            exact_dict_key_atom("0"),
            exact_dict_key_atom(impl_owner_ref_stable_key(
                dict_ref_static(value)))
        ].join("/")
    }
    if !dict_ref_is_wrapped(value) {
        panic("HIR dictionary key: unknown exact dictionary evidence")
    }
    let inner = dict_ref_wrapped_inner(value)
    let mut parts = [
        exact_dict_key_atom("wrapped-dict-v1"),
        exact_dict_key_atom(inner.len().to_str()),
        exact_dict_key_atom(impl_owner_ref_stable_key(
            dict_ref_wrapped_base(value)))
    ]
    let mut child_index = 0
    for child in inner {
        parts.push(exact_dict_key_atom(child_index.to_str()))
        parts.push(exact_dict_key_atom(exact_dict_physical_key(child)))
        child_index = child_index + 1
    }
    parts.join("/")
}

pub fn dict_ref_is_simple_physical(value: DictRef) -> Bool {
    match value.physical {
        PhysicalDictRefValue::SimplePhysicalValue(_) => true,
        _ => false
    }
}
pub fn dict_ref_is_static_physical(value: DictRef) -> Bool {
    match value.physical {
        PhysicalDictRefValue::StaticPhysicalValue(_) => true,
        _ => false
    }
}
pub fn dict_ref_is_wrapped_physical(value: DictRef) -> Bool {
    match value.physical {
        PhysicalDictRefValue::WrappedPhysicalValue { .. } => true,
        _ => false
    }
}
pub fn dict_ref_simple_name(value: DictRef) -> Str {
    match value.physical {
        PhysicalDictRefValue::SimplePhysicalValue(name) => name,
        _ => panic("HIR dictionary: evidence is not physically simple")
    }
}
pub fn dict_ref_static_name(value: DictRef) -> Str {
    match value.physical {
        PhysicalDictRefValue::StaticPhysicalValue(name) => name,
        _ => panic("HIR dictionary: evidence is not physically static")
    }
}
pub fn dict_ref_wrapped_name(value: DictRef) -> Str {
    match value.physical {
        PhysicalDictRefValue::WrappedPhysicalValue { dict, .. } => dict,
        _ => panic("HIR dictionary: evidence is not physically wrapped")
    }
}
pub fn dict_ref_wrapped_trait(value: DictRef) -> SymbolRef {
    match value.physical {
        PhysicalDictRefValue::WrappedPhysicalValue { trait_ref, .. } => trait_ref,
        _ => panic("HIR dictionary: evidence is not physically wrapped")
    }
}
pub fn dict_ref_wrapped_physical_inner(value: DictRef) -> List<DictRef> {
    match value.physical {
        PhysicalDictRefValue::WrappedPhysicalValue { inner_dicts, .. } =>
            inner_dicts.map(fn(item) { item }),
        _ => panic("HIR dictionary: evidence is not physically wrapped")
    }
}
pub fn dict_ref_physical_same(left: DictRef, right: DictRef) -> Bool {
    match (left.physical, right.physical) {
        (PhysicalDictRefValue::SimplePhysicalValue(a),
         PhysicalDictRefValue::SimplePhysicalValue(b)) => a == b,
        (PhysicalDictRefValue::StaticPhysicalValue(a),
         PhysicalDictRefValue::StaticPhysicalValue(b)) => a == b,
        (PhysicalDictRefValue::WrappedPhysicalValue {
            dict: ad, trait_ref: at, inner_dicts: ai
         }, PhysicalDictRefValue::WrappedPhysicalValue {
            dict: bd, trait_ref: bt, inner_dicts: bi
         }) => {
            if ad != bd || !symbol_ref_same(at, bt) || ai.len() != bi.len() {
                return false
            }
            let mut index = 0
            while index < ai.len() {
                if !dict_ref_physical_same(
                        ai.get(index).unwrap(), bi.get(index).unwrap()) {
                    return false
                }
                index = index + 1
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
            dict_ref_same(
                dict_ref_exact(left_evidence), dict_ref_exact(right_evidence)),
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

pub struct HCallableTypeActual {
    pub owner: SymbolRef,
    pub ordinal: Int,
    pub arity: Int,
    pub actual: Type
}

pub struct HExactCallPlan {
    callee: CalleeRef,
    signature: Type,
    type_args: List<HCallableTypeActual>,
    method: MethodCallRef?,
    evidence: List<DictRef>,
    effect_ctx: TypedEffectCtxSource
}
pub fn make_h_exact_call_plan(
    callee: CalleeRef, signature: Type, method: MethodCallRef?,
    evidence: List<DictRef>, effect_ctx: TypedEffectCtxSource
) -> HExactCallPlan {
    make_h_exact_call_plan_with_type_args(
        callee, signature, [], method, evidence, effect_ctx)
}
pub fn make_h_exact_call_plan_with_type_args(
    callee: CalleeRef, signature: Type,
    type_args: List<HCallableTypeActual>, method: MethodCallRef?,
    evidence: List<DictRef>, effect_ctx: TypedEffectCtxSource
) -> HExactCallPlan {
    match signature {
        Type::FnType { .. } => {},
        _ => panic("HIR exact call plan: signature is not callable")
    }
    match method {
        some(exact) => {
            if !callee_ref_is_named(callee) ||
               !symbol_ref_same(
                    callee_ref_named_symbol(callee),
                    method_call_ref_named_symbol(exact)) ||
               !types_equal(signature, method_call_ref_signature(exact)) {
                panic("HIR exact call plan: method contract differs")
            }
        },
        none => {}
    }
    HExactCallPlan { callee: callee, signature: signature,
        type_args: type_args.map(fn(value) { value }), method: method,
        evidence: evidence.map(fn(value) { value }),
        effect_ctx: effect_ctx }
}
pub fn h_exact_call_callee(value: HExactCallPlan) -> CalleeRef {
    value.callee
}
pub fn h_exact_call_signature(value: HExactCallPlan) -> Type {
    value.signature
}
pub fn h_exact_call_type_args(
    value: HExactCallPlan
) -> List<HCallableTypeActual> { value.type_args.map(fn(item) { item }) }
pub fn h_exact_call_method(value: HExactCallPlan) -> MethodCallRef? {
    value.method
}
pub fn h_exact_call_evidence(value: HExactCallPlan) -> List<DictRef> {
    value.evidence.map(fn(item) { item })
}
pub fn h_exact_call_effect_ctx(
    value: HExactCallPlan
) -> TypedEffectCtxSource { value.effect_ctx }

pub fn remap_h_effect_ctx_ref(
    value: EffectCtxRef, sources: List<EffectCtxRef>,
    targets: List<EffectCtxRef>
) -> EffectCtxRef {
    if sources.len() != targets.len() {
        panic("HIR effect context remap: mapping arity differs")
    }
    for index in 0..sources.len() {
        let source = sources.get(index).unwrap()
        let target = targets.get(index).unwrap()
        if effect_ctx_ref_same(value, source) { return target }
    }
    value
}

pub fn remap_h_effect_ctx_source(
    value: TypedEffectCtxSource, sources: List<EffectCtxRef>,
    targets: List<EffectCtxRef>
) -> TypedEffectCtxSource {
    if typed_effect_ctx_source_is_empty(value) {
        make_empty_effect_ctx_source()
    } else {
        make_borrowed_effect_ctx_source(remap_h_effect_ctx_ref(
            typed_effect_ctx_source_context(value), sources, targets))
    }
}

pub fn remap_h_exact_call_effect_ctx(
    value: HExactCallPlan, sources: List<EffectCtxRef>,
    targets: List<EffectCtxRef>
) -> HExactCallPlan {
    make_h_exact_call_plan_with_type_args(
        value.callee, value.signature, value.type_args,
        value.method, value.evidence,
        remap_h_effect_ctx_source(value.effect_ctx, sources, targets))
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
    VariantConstruction { fields: List<HProjectionRef> },
    TupleStructural { arity: Int },
    RecordStructural { fields: List<HProjectionRef> }
}
pub struct HConstructorPlan { value: HConstructorPlanValue }
pub fn make_h_variant_constructor_plan(
    fields: List<HProjectionRef>
) -> HConstructorPlan {
    let mut index = 0
    while index < fields.len() {
        let field = fields.get(index).unwrap()
        if h_projection_kind(field) != 1 {
            panic("HIR constructor: variant plan has a non-variant field")
        }
        let mut right = index + 1
        while right < fields.len() {
            let candidate = fields.get(right).unwrap()
            if h_projection_kind(candidate) != 1 ||
               variant_field_ref_same(
                    h_projection_variant(field),
                    h_projection_variant(candidate)) {
                panic("HIR constructor: variant field plan differs")
            }
            right = right + 1
        }
        index = index + 1
    }
    HConstructorPlan { value: HConstructorPlanValue::VariantConstruction {
        fields: fields.map(fn(value) { value }) } }
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
        HConstructorPlanValue::VariantConstruction { .. } => 0,
        HConstructorPlanValue::TupleStructural { .. } => 1,
        HConstructorPlanValue::RecordStructural { .. } => 2
    }
}
pub fn h_constructor_fields(value: HConstructorPlan) -> List<HProjectionRef> {
    match value.value {
        HConstructorPlanValue::VariantConstruction { fields } =>
            fields.map(fn(item) { item }),
        HConstructorPlanValue::RecordStructural { fields } =>
            fields.map(fn(item) { item }),
        HConstructorPlanValue::TupleStructural { .. } =>
            panic("HIR constructor: tuple plan has no stored fields")
    }
}
pub fn h_constructor_tuple_arity(value: HConstructorPlan) -> Int {
    match value.value {
        HConstructorPlanValue::TupleStructural { arity } => arity,
        _ => panic("HIR constructor: variant/record plan has no tuple arity")
    }
}

// Exact one-shot elaboration plan for a 0.1 list literal.  The plan exists
// only through TypedHIR; PreCore consumes it into a normal nominal construct
// followed by ordinary exact List.push calls.
pub struct HListLiteralPlan {
    builder: BinderEntry,
    owner: RegisteredNominalRef,
    constructor: HConstructorPlan,
    allocator: HExactCallPlan,
    push: HExactCallPlan
}
pub fn make_h_list_literal_plan(
    builder: BinderEntry, owner: RegisteredNominalRef,
    constructor: HConstructorPlan, allocator: HExactCallPlan,
    push: HExactCallPlan
) -> HListLiteralPlan {
    let fields = h_constructor_fields(constructor)
    if h_constructor_kind(constructor) != 2 || fields.len() != 3 {
        panic("HIR list plan: nominal field census differs")
    }
    let mut field_index = 0
    for field in fields {
        if h_projection_kind(field) != 0 || !symbol_ref_same(
                nominal_field_ref_owner(h_projection_nominal(field)),
                registered_nominal_ref_symbol(owner)) ||
           nominal_field_ref_index(h_projection_nominal(field)) !=
                field_index {
            panic("HIR list plan: field owner/order differs")
        }
        field_index = field_index + 1
    }
    if h_exact_call_method(allocator).is_some() {
        panic("HIR list plan: allocator is a method")
    }
    let push_method = match h_exact_call_method(push) {
        some(value) => value,
        none => panic("HIR list plan: push method is absent")
    }
    if !method_call_ref_is_concrete(push_method) ||
       !method_call_ref_receiver_mutable(push_method) {
        panic("HIR list plan: push is not an exact mutable inherent method")
    }
    HListLiteralPlan {
        builder: builder, owner: owner, constructor: constructor,
        allocator: allocator, push: push
    }
}
pub fn h_list_literal_builder(value: HListLiteralPlan) -> BinderEntry {
    value.builder
}
pub fn h_list_literal_owner(
    value: HListLiteralPlan
) -> RegisteredNominalRef { value.owner }
pub fn h_list_literal_constructor(
    value: HListLiteralPlan
) -> HConstructorPlan { value.constructor }
pub fn h_list_literal_allocator(
    value: HListLiteralPlan
) -> HExactCallPlan { value.allocator }
pub fn h_list_literal_push(value: HListLiteralPlan) -> HExactCallPlan {
    value.push
}
pub fn remap_h_list_literal_effect_ctx(
    value: HListLiteralPlan, sources: List<EffectCtxRef>,
    targets: List<EffectCtxRef>
) -> HListLiteralPlan {
    make_h_list_literal_plan(
        value.builder, value.owner, value.constructor,
        remap_h_exact_call_effect_ctx(
            value.allocator, sources, targets),
        remap_h_exact_call_effect_ctx(value.push, sources, targets))
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

pub fn remap_h_string_interp_effect_ctx(
    value: HStringInterpPlan, sources: List<EffectCtxRef>,
    targets: List<EffectCtxRef>
) -> HStringInterpPlan {
    let mut value_to_string: List<HExactCallPlan> = []
    for call in value.value_to_string {
        value_to_string.push(remap_h_exact_call_effect_ctx(
            call, sources, targets))
    }
    make_h_string_interp_plan(
        value.builder_binder,
        remap_h_exact_call_effect_ctx(
            value.builder, sources, targets),
        remap_h_exact_call_effect_ctx(
            value.append_literal, sources, targets),
        remap_h_exact_call_effect_ctx(
            value.append_value, sources, targets),
        remap_h_exact_call_effect_ctx(
            value.finish, sources, targets),
        value_to_string)
}

pub struct HDictConstructPlan {
    constructor: ExecutableRef,
    base: ImplOwnerRef,
    inner: List<ExactDictRef>,
    result: SlotRef,
    effect_ctx: TypedEffectCtxSource
}
pub fn make_h_dict_construct_plan(
    constructor: ExecutableRef, base: ImplOwnerRef,
    inner: List<ExactDictRef>, result: SlotRef,
    effect_ctx: TypedEffectCtxSource
) -> HDictConstructPlan {
    if impl_owner_ref_trait(base).is_none() {
        panic("HIR dictionary construct: base is not a trait impl")
    }
    if !slot_ref_is_source(result) ||
       !slot_domain_same(
            slot_ref_source_domain(result), slot_domain_dictionary()) {
        panic("HIR dictionary construct: result is not a dictionary local")
    }
    HDictConstructPlan {
        constructor: constructor, base: base,
        inner: inner.map(fn(item) { item }), result: result,
        effect_ctx: effect_ctx
    }
}
pub fn h_dict_construct_executable(value: HDictConstructPlan) -> ExecutableRef {
    value.constructor
}
pub fn h_dict_construct_base(value: HDictConstructPlan) -> ImplOwnerRef {
    value.base
}
pub fn h_dict_construct_inner(
    value: HDictConstructPlan
) -> List<ExactDictRef> {
    value.inner.map(fn(item) { item })
}
pub fn h_dict_construct_result(value: HDictConstructPlan) -> SlotRef {
    value.result
}
pub fn h_dict_construct_effect_ctx(
    value: HDictConstructPlan
) -> TypedEffectCtxSource { value.effect_ctx }
pub fn h_dict_construct_trait(value: HDictConstructPlan) -> SymbolRef {
    match impl_owner_ref_trait(value.base) {
        some(trait_ref) => trait_ref,
        none => panic("HIR dictionary construct: base is not a trait impl")
    }
}

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
        HPatternPlanValue::TuplePattern(values) => copy_h_pattern_plans(values),
        HPatternPlanValue::OrPattern(values) => copy_h_pattern_plans(values),
        _ => panic("HIR pattern plan: no positional children")
    }
}
pub fn h_pattern_plan_fields(value: HPatternPlan) -> List<HPatternFieldPlan> {
    match value.value {
        HPatternPlanValue::StructPattern { fields, .. } =>
            copy_h_pattern_field_plans(fields),
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
    owner: RegisteredNominalRef,
    start: NominalFieldRef,
    end: NominalFieldRef,
    inclusive: NominalFieldRef,
    order: HOperatorPlan,
    equality: HOperatorPlan,
    range_binder: BinderEntry,
    counter_binder: BinderEntry,
    finished_binder: BinderEntry,
    binding_binder: BinderEntry
}
pub fn make_h_range_for_in_plan(
    owner: RegisteredNominalRef,
    start: NominalFieldRef, end: NominalFieldRef,
    inclusive: NominalFieldRef, order: HOperatorPlan,
    equality: HOperatorPlan,
    range_binder: BinderEntry, counter_binder: BinderEntry,
    finished_binder: BinderEntry,
    binding_binder: BinderEntry
) -> HForInPlan {
    let owner_symbol = registered_nominal_ref_symbol(owner)
    if !symbol_ref_same(nominal_field_ref_owner(start), owner_symbol) ||
       !symbol_ref_same(nominal_field_ref_owner(end), owner_symbol) ||
       !symbol_ref_same(nominal_field_ref_owner(inclusive), owner_symbol) ||
       nominal_field_ref_index(start) != 0 ||
       nominal_field_ref_index(end) != 1 ||
       nominal_field_ref_index(inclusive) != 2 ||
       h_operator_is_tuple(order) || h_operator_is_tuple(equality) {
        panic("HIR Range for-in: exact field/operator plan differs")
    }
    HForInPlan {
        owner: owner, start: start, end: end, inclusive: inclusive,
        order: order, equality: equality, range_binder: range_binder,
        counter_binder: counter_binder, finished_binder: finished_binder,
        binding_binder: binding_binder }
}
pub fn h_for_in_binding_binder(value: HForInPlan) -> BinderEntry {
    value.binding_binder
}
pub fn h_range_for_in_owner(value: HForInPlan) -> RegisteredNominalRef {
    value.owner
}
pub fn h_range_for_in_start(value: HForInPlan) -> NominalFieldRef {
    value.start
}
pub fn h_range_for_in_end(value: HForInPlan) -> NominalFieldRef {
    value.end
}
pub fn h_range_for_in_inclusive(value: HForInPlan) -> NominalFieldRef {
    value.inclusive
}
pub fn h_range_for_in_order(value: HForInPlan) -> HOperatorPlan {
    value.order
}
pub fn h_range_for_in_equality(value: HForInPlan) -> HOperatorPlan {
    value.equality
}
pub fn h_range_for_in_range_binder(value: HForInPlan) -> BinderEntry {
    value.range_binder
}
pub fn h_range_for_in_counter_binder(value: HForInPlan) -> BinderEntry {
    value.counter_binder
}
pub fn h_range_for_in_finished_binder(value: HForInPlan) -> BinderEntry {
    value.finished_binder
}
pub fn remap_h_for_in_effect_ctx(
    value: HForInPlan, sources: List<EffectCtxRef>,
    targets: List<EffectCtxRef>
) -> HForInPlan {
    let _ = sources
    let _ = targets
    make_h_range_for_in_plan(
        value.owner, value.start, value.end, value.inclusive,
        value.order, value.equality,
        value.range_binder, value.counter_binder, value.finished_binder,
        value.binding_binder)
}
pub struct HFailOperationRef { tag: Int }
pub fn h_fail_raise_ref() -> HFailOperationRef {
    HFailOperationRef { tag: 0 }
}
pub fn h_fail_operation_tag(value: HFailOperationRef) -> Int {
    if value.tag != 0 { panic("HIR fail operation: invalid tag") }
    value.tag
}
