// CoreHIR structured semantic language for Ring 0.1.
//
// CoreHIR is the last language-semantic representation.  Every callee,
// method, evidence edge, nominal/member projection, generated executable and
// body-local slot is supplied as an exact typed reference by the upstream
// elaborator.  The representation has no source names/spans and deliberately
// has no Clone/Take/Drop/Cleanup, layout, ABI, or backend variant.

use ir_identity::{
    SymbolRef, RegisteredNominalRef, NominalFieldRef,
    PathRef, PathOwnerRef, SlotRef, CalleeRef,
    OriginRef,
    symbol_ref_same, symbol_ref_origin_module_key,
    symbol_ref_namespace_kind,
    namespace_kind_same, namespace_effect, namespace_member,
    registered_nominal_ref_symbol, registered_nominal_ref_same,
    nominal_field_ref_same, nominal_field_ref_owner,
    path_ref_same, path_ref_owner,
    path_owner_ref_is_symbol, path_owner_ref_symbol,
    path_owner_ref_module_body,
    module_body_ref_origin_module_key,
    slot_ref_same,
    make_named_callee_ref, make_local_callee_ref, make_dynamic_callee_ref,
    callee_ref_same,
    origin_ref_is_symbol, origin_ref_symbol, origin_ref_path
}
use ir_inventory::{
    ExecutableRef, BinderManifest,
    executable_ref_same, executable_ref_is_named,
    executable_ref_named_symbol, executable_ref_origin_module_key,
    binder_manifest_owner, binder_manifest_entries,
    binder_entry_slot, make_binder_manifest
}
use hir::{MethodCallRef}

// ============================================================
// Exact typed/effect references
// ============================================================

pub struct CoreTypeRef { index: Int }

pub fn make_core_type_ref(index: Int) -> CoreTypeRef {
    if index < 0 { panic("CoreHIR: negative type reference") }
    CoreTypeRef { index: index }
}
pub fn core_type_ref_index(value: CoreTypeRef) -> Int { value.index }
pub fn core_type_ref_same(left: CoreTypeRef, right: CoreTypeRef) -> Bool {
    left.index == right.index
}

enum CoreEffectAtomValue {
    FailEffectValue(CoreTypeRef),
    MutEffectValue(CoreTypeRef),
    UnsafeEffectValue,
    HandledEffectValue(SymbolRef),
    SystemEffectValue(SymbolRef)
}

pub struct CoreEffectAtom { value: CoreEffectAtomValue }

pub fn make_core_fail_effect(error_type: CoreTypeRef) -> CoreEffectAtom {
    CoreEffectAtom { value: CoreEffectAtomValue::FailEffectValue(error_type) }
}
pub fn make_core_mut_effect(state_type: CoreTypeRef) -> CoreEffectAtom {
    CoreEffectAtom { value: CoreEffectAtomValue::MutEffectValue(state_type) }
}
pub fn make_core_unsafe_effect() -> CoreEffectAtom {
    CoreEffectAtom { value: CoreEffectAtomValue::UnsafeEffectValue }
}
pub fn make_core_handled_effect(effect_symbol: SymbolRef) -> CoreEffectAtom {
    if !namespace_kind_same(
            symbol_ref_namespace_kind(effect_symbol), namespace_effect()) {
        panic("CoreHIR: handled effect is not an exact effect symbol")
    }
    CoreEffectAtom {
        value: CoreEffectAtomValue::HandledEffectValue(effect_symbol)
    }
}
pub fn make_core_system_effect(effect_symbol: SymbolRef) -> CoreEffectAtom {
    if !namespace_kind_same(
            symbol_ref_namespace_kind(effect_symbol), namespace_effect()) {
        panic("CoreHIR: system effect is not an exact effect symbol")
    }
    CoreEffectAtom {
        value: CoreEffectAtomValue::SystemEffectValue(effect_symbol)
    }
}

pub fn core_effect_atom_kind_tag(value: CoreEffectAtom) -> Int {
    match value.value {
        CoreEffectAtomValue::FailEffectValue(_) => 0,
        CoreEffectAtomValue::MutEffectValue(_) => 1,
        CoreEffectAtomValue::UnsafeEffectValue => 2,
        CoreEffectAtomValue::HandledEffectValue(_) => 3,
        CoreEffectAtomValue::SystemEffectValue(_) => 4
    }
}
pub fn core_effect_atom_type(value: CoreEffectAtom) -> CoreTypeRef {
    match value.value {
        CoreEffectAtomValue::FailEffectValue(ty) |
        CoreEffectAtomValue::MutEffectValue(ty) => ty,
        _ => panic("CoreHIR: effect atom has no type argument")
    }
}
pub fn core_effect_atom_symbol(value: CoreEffectAtom) -> SymbolRef {
    match value.value {
        CoreEffectAtomValue::HandledEffectValue(symbol) |
        CoreEffectAtomValue::SystemEffectValue(symbol) => symbol,
        _ => panic("CoreHIR: effect atom has no effect symbol")
    }
}

fn core_effect_atom_same(left: CoreEffectAtom, right: CoreEffectAtom) -> Bool {
    match (left.value, right.value) {
        (CoreEffectAtomValue::FailEffectValue(a),
         CoreEffectAtomValue::FailEffectValue(b)) => core_type_ref_same(a, b),
        (CoreEffectAtomValue::MutEffectValue(a),
         CoreEffectAtomValue::MutEffectValue(b)) => core_type_ref_same(a, b),
        (CoreEffectAtomValue::UnsafeEffectValue,
         CoreEffectAtomValue::UnsafeEffectValue) => true,
        (CoreEffectAtomValue::HandledEffectValue(a),
         CoreEffectAtomValue::HandledEffectValue(b)) => symbol_ref_same(a, b),
        (CoreEffectAtomValue::SystemEffectValue(a),
         CoreEffectAtomValue::SystemEffectValue(b)) => symbol_ref_same(a, b),
        _ => false
    }
}

fn copy_effect_atoms(values: List<CoreEffectAtom>) -> List<CoreEffectAtom> {
    let mut result: List<CoreEffectAtom> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreEffectSet { atoms: List<CoreEffectAtom> }

pub fn make_core_effect_set(atoms: List<CoreEffectAtom>) -> CoreEffectSet {
    let mut left_index = 0
    while left_index < atoms.len() {
        let mut right_index = left_index + 1
        while right_index < atoms.len() {
            if core_effect_atom_same(
                    atoms.get(left_index).unwrap(),
                    atoms.get(right_index).unwrap()) {
                panic("CoreHIR: effect set repeats an exact atom")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    CoreEffectSet { atoms: copy_effect_atoms(atoms) }
}
pub fn core_effect_set_atoms(value: CoreEffectSet) -> List<CoreEffectAtom> {
    copy_effect_atoms(value.atoms)
}

// ============================================================
// Exact callable/evidence/member identities
// ============================================================

const CORE_CALLEE_DIRECT: Int = 0
const CORE_CALLEE_LOCAL: Int = 1
const CORE_CALLEE_DYNAMIC: Int = 2

pub struct CoreCalleeRef {
    callee: CalleeRef,
    kind: Int,
    direct: ExecutableRef?,
    local: SlotRef?,
    dynamic: PathRef?
}

pub fn make_core_direct_callee(value: ExecutableRef) -> CoreCalleeRef {
    if !executable_ref_is_named(value) {
        panic("CoreHIR: direct callee is not a named executable")
    }
    let callee = make_named_callee_ref(executable_ref_named_symbol(value))
    CoreCalleeRef {
        callee: callee, kind: CORE_CALLEE_DIRECT,
        direct: some(value), local: none, dynamic: none
    }
}
pub fn make_core_local_callee(value: SlotRef) -> CoreCalleeRef {
    CoreCalleeRef {
        callee: make_local_callee_ref(value), kind: CORE_CALLEE_LOCAL,
        direct: none, local: some(value), dynamic: none
    }
}
pub fn make_core_dynamic_callee(value: PathRef) -> CoreCalleeRef {
    CoreCalleeRef {
        callee: make_dynamic_callee_ref(value), kind: CORE_CALLEE_DYNAMIC,
        direct: none, local: none, dynamic: some(value)
    }
}
pub fn core_callee_ref(value: CoreCalleeRef) -> CalleeRef { value.callee }
pub fn core_callee_kind_tag(value: CoreCalleeRef) -> Int { value.kind }
pub fn core_callee_direct(value: CoreCalleeRef) -> ExecutableRef {
    match value.direct {
        some(executable) => executable,
        none => panic("CoreHIR: non-direct callee has no ExecutableRef")
    }
}
pub fn core_callee_local(value: CoreCalleeRef) -> SlotRef {
    match value.local {
        some(slot) => slot,
        none => panic("CoreHIR: non-local callee has no SlotRef")
    }
}
pub fn core_callee_dynamic(value: CoreCalleeRef) -> PathRef {
    match value.dynamic {
        some(path) => path,
        none => panic("CoreHIR: non-dynamic callee has no PathRef")
    }
}

enum CoreEvidenceRefValue {
    LocalEvidenceValue(SlotRef),
    CallableEvidenceValue(ExecutableRef)
}

pub struct CoreEvidenceRef { value: CoreEvidenceRefValue }

pub fn make_core_local_evidence(value: SlotRef) -> CoreEvidenceRef {
    CoreEvidenceRef { value: CoreEvidenceRefValue::LocalEvidenceValue(value) }
}
pub fn make_core_callable_evidence(value: ExecutableRef) -> CoreEvidenceRef {
    CoreEvidenceRef { value: CoreEvidenceRefValue::CallableEvidenceValue(value) }
}
pub fn core_evidence_is_local(value: CoreEvidenceRef) -> Bool {
    match value.value {
        CoreEvidenceRefValue::LocalEvidenceValue(_) => true,
        CoreEvidenceRefValue::CallableEvidenceValue(_) => false
    }
}
pub fn core_evidence_local(value: CoreEvidenceRef) -> SlotRef {
    match value.value {
        CoreEvidenceRefValue::LocalEvidenceValue(slot) => slot,
        _ => panic("CoreHIR: callable evidence has no local slot")
    }
}
pub fn core_evidence_callable(value: CoreEvidenceRef) -> ExecutableRef {
    match value.value {
        CoreEvidenceRefValue::CallableEvidenceValue(executable) => executable,
        _ => panic("CoreHIR: local evidence has no executable")
    }
}
fn copy_evidence(values: List<CoreEvidenceRef>) -> List<CoreEvidenceRef> {
    let mut result: List<CoreEvidenceRef> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreVariantRef {
    owner: RegisteredNominalRef,
    member: SymbolRef,
    index: Int
}

pub fn make_core_variant_ref(
    owner: RegisteredNominalRef, member: SymbolRef, index: Int
) -> CoreVariantRef {
    if index < 0 ||
       !namespace_kind_same(
            symbol_ref_namespace_kind(member), namespace_member()) ||
       symbol_ref_origin_module_key(member) !=
            symbol_ref_origin_module_key(registered_nominal_ref_symbol(owner)) {
        panic("CoreHIR: invalid exact variant identity")
    }
    CoreVariantRef { owner: owner, member: member, index: index }
}
pub fn core_variant_owner(value: CoreVariantRef) -> RegisteredNominalRef {
    value.owner
}
pub fn core_variant_member(value: CoreVariantRef) -> SymbolRef { value.member }
pub fn core_variant_index(value: CoreVariantRef) -> Int { value.index }
pub fn core_variant_ref_same(left: CoreVariantRef, right: CoreVariantRef) -> Bool {
    registered_nominal_ref_same(left.owner, right.owner) &&
        symbol_ref_same(left.member, right.member) && left.index == right.index
}

pub struct CoreEffectOperationRef {
    effect_symbol: SymbolRef,
    operation: SymbolRef,
    callable: ExecutableRef
}

pub fn make_core_effect_operation_ref(
    effect_symbol: SymbolRef, operation: SymbolRef, callable: ExecutableRef
) -> CoreEffectOperationRef {
    if !namespace_kind_same(
            symbol_ref_namespace_kind(effect_symbol), namespace_effect()) ||
       !namespace_kind_same(
            symbol_ref_namespace_kind(operation), namespace_member()) ||
       symbol_ref_origin_module_key(effect_symbol) !=
            symbol_ref_origin_module_key(operation) ||
       !executable_ref_is_named(callable) ||
       !symbol_ref_same(executable_ref_named_symbol(callable), operation) {
        panic("CoreHIR: effect operation identity/callable differs")
    }
    CoreEffectOperationRef {
        effect_symbol: effect_symbol, operation: operation, callable: callable
    }
}
pub fn core_effect_operation_effect(value: CoreEffectOperationRef) -> SymbolRef {
    value.effect_symbol
}
pub fn core_effect_operation_member(value: CoreEffectOperationRef) -> SymbolRef {
    value.operation
}
pub fn core_effect_operation_callable(
    value: CoreEffectOperationRef
) -> ExecutableRef { value.callable }

enum CoreFieldRefValue {
    NominalFieldValue(NominalFieldRef),
    TupleFieldValue(Int),
    RecordFieldValue(PathRef)
}

pub struct CoreFieldRef { value: CoreFieldRefValue }

pub fn make_core_nominal_field(value: NominalFieldRef) -> CoreFieldRef {
    CoreFieldRef { value: CoreFieldRefValue::NominalFieldValue(value) }
}
pub fn make_core_tuple_field(index: Int) -> CoreFieldRef {
    if index < 0 { panic("CoreHIR: negative tuple field index") }
    CoreFieldRef { value: CoreFieldRefValue::TupleFieldValue(index) }
}
pub fn make_core_record_field(value: PathRef) -> CoreFieldRef {
    CoreFieldRef { value: CoreFieldRefValue::RecordFieldValue(value) }
}
pub fn core_field_ref_kind_tag(value: CoreFieldRef) -> Int {
    match value.value {
        CoreFieldRefValue::NominalFieldValue(_) => 0,
        CoreFieldRefValue::TupleFieldValue(_) => 1,
        CoreFieldRefValue::RecordFieldValue(_) => 2
    }
}
pub fn core_field_ref_nominal(value: CoreFieldRef) -> NominalFieldRef {
    match value.value {
        CoreFieldRefValue::NominalFieldValue(field) => field,
        _ => panic("CoreHIR: non-nominal field has no NominalFieldRef")
    }
}
pub fn core_field_ref_tuple_index(value: CoreFieldRef) -> Int {
    match value.value {
        CoreFieldRefValue::TupleFieldValue(index) => index,
        _ => panic("CoreHIR: non-tuple field has no index")
    }
}
pub fn core_field_ref_record_path(value: CoreFieldRef) -> PathRef {
    match value.value {
        CoreFieldRefValue::RecordFieldValue(path) => path,
        _ => panic("CoreHIR: non-record field has no path")
    }
}

pub fn core_field_ref_same(left: CoreFieldRef, right: CoreFieldRef) -> Bool {
    match (left.value, right.value) {
        (CoreFieldRefValue::NominalFieldValue(a),
         CoreFieldRefValue::NominalFieldValue(b)) => nominal_field_ref_same(a, b),
        (CoreFieldRefValue::TupleFieldValue(a),
         CoreFieldRefValue::TupleFieldValue(b)) => a == b,
        (CoreFieldRefValue::RecordFieldValue(a),
         CoreFieldRefValue::RecordFieldValue(b)) => path_ref_same(a, b),
        _ => false
    }
}

enum CoreConstructorRefValue {
    StructConstructorValue(RegisteredNominalRef),
    VariantConstructorValue(CoreVariantRef),
    TupleConstructorValue(Int),
    RecordConstructorValue(Int)
}

pub struct CoreConstructorRef { value: CoreConstructorRefValue }

pub fn make_core_struct_constructor(
    owner: RegisteredNominalRef
) -> CoreConstructorRef {
    CoreConstructorRef { value: CoreConstructorRefValue::StructConstructorValue(owner) }
}
pub fn make_core_variant_constructor(variant: CoreVariantRef) -> CoreConstructorRef {
    CoreConstructorRef { value: CoreConstructorRefValue::VariantConstructorValue(variant) }
}
pub fn make_core_tuple_constructor(arity: Int) -> CoreConstructorRef {
    if arity < 0 { panic("CoreHIR: negative tuple constructor arity") }
    CoreConstructorRef { value: CoreConstructorRefValue::TupleConstructorValue(arity) }
}
pub fn make_core_record_constructor(arity: Int) -> CoreConstructorRef {
    if arity < 0 { panic("CoreHIR: negative record constructor arity") }
    CoreConstructorRef { value: CoreConstructorRefValue::RecordConstructorValue(arity) }
}
pub fn core_constructor_kind_tag(value: CoreConstructorRef) -> Int {
    match value.value {
        CoreConstructorRefValue::StructConstructorValue(_) => 0,
        CoreConstructorRefValue::VariantConstructorValue(_) => 1,
        CoreConstructorRefValue::TupleConstructorValue(_) => 2,
        CoreConstructorRefValue::RecordConstructorValue(_) => 3
    }
}
pub fn core_constructor_struct_owner(
    value: CoreConstructorRef
) -> RegisteredNominalRef {
    match value.value {
        CoreConstructorRefValue::StructConstructorValue(owner) => owner,
        _ => panic("CoreHIR: constructor is not a struct")
    }
}
pub fn core_constructor_variant(value: CoreConstructorRef) -> CoreVariantRef {
    match value.value {
        CoreConstructorRefValue::VariantConstructorValue(variant) => variant,
        _ => panic("CoreHIR: constructor is not a variant")
    }
}
pub fn core_constructor_arity(value: CoreConstructorRef) -> Int {
    match value.value {
        CoreConstructorRefValue::TupleConstructorValue(arity) |
        CoreConstructorRefValue::RecordConstructorValue(arity) => arity,
        _ => panic("CoreHIR: nominal constructor has no structural arity")
    }
}

pub struct CoreFieldValue {
    field: CoreFieldRef,
    value: SlotRef
}

pub fn make_core_field_value(
    field: CoreFieldRef, value: SlotRef
) -> CoreFieldValue { CoreFieldValue { field: field, value: value } }
pub fn core_field_value_field(value: CoreFieldValue) -> CoreFieldRef { value.field }
pub fn core_field_value_slot(value: CoreFieldValue) -> SlotRef { value.value }
fn copy_field_values(values: List<CoreFieldValue>) -> List<CoreFieldValue> {
    let mut result: List<CoreFieldValue> = []
    for value in values { result.push(value) }
    result
}

// ============================================================
// 0.1 literals, primitive operations, and patterns
// ============================================================

enum CoreLiteralValue {
    IntLiteralValue(Int),
    FloatLiteralValue(Float),
    StrLiteralValue(Str),
    BoolLiteralValue(Bool),
    UnitLiteralValue
}

pub struct CoreLiteral { value: CoreLiteralValue }

pub fn make_core_int_literal(value: Int) -> CoreLiteral {
    CoreLiteral { value: CoreLiteralValue::IntLiteralValue(value) }
}
pub fn make_core_float_literal(value: Float) -> CoreLiteral {
    CoreLiteral { value: CoreLiteralValue::FloatLiteralValue(value) }
}
pub fn make_core_str_literal(value: Str) -> CoreLiteral {
    CoreLiteral { value: CoreLiteralValue::StrLiteralValue(value) }
}
pub fn make_core_bool_literal(value: Bool) -> CoreLiteral {
    CoreLiteral { value: CoreLiteralValue::BoolLiteralValue(value) }
}
pub fn make_core_unit_literal() -> CoreLiteral {
    CoreLiteral { value: CoreLiteralValue::UnitLiteralValue }
}
pub fn core_literal_kind_tag(value: CoreLiteral) -> Int {
    match value.value {
        CoreLiteralValue::IntLiteralValue(_) => 0,
        CoreLiteralValue::FloatLiteralValue(_) => 1,
        CoreLiteralValue::StrLiteralValue(_) => 2,
        CoreLiteralValue::BoolLiteralValue(_) => 3,
        CoreLiteralValue::UnitLiteralValue => 4
    }
}
pub fn core_literal_int(value: CoreLiteral) -> Int {
    match value.value {
        CoreLiteralValue::IntLiteralValue(literal) => literal,
        _ => panic("CoreHIR: literal is not Int")
    }
}
pub fn core_literal_float(value: CoreLiteral) -> Float {
    match value.value {
        CoreLiteralValue::FloatLiteralValue(literal) => literal,
        _ => panic("CoreHIR: literal is not Float")
    }
}
pub fn core_literal_str(value: CoreLiteral) -> Str {
    match value.value {
        CoreLiteralValue::StrLiteralValue(literal) => literal,
        _ => panic("CoreHIR: literal is not Str")
    }
}
pub fn core_literal_bool(value: CoreLiteral) -> Bool {
    match value.value {
        CoreLiteralValue::BoolLiteralValue(literal) => literal,
        _ => panic("CoreHIR: literal is not Bool")
    }
}

const CORE_PRIMITIVE_ADD: Int = 0
const CORE_PRIMITIVE_SUB: Int = 1
const CORE_PRIMITIVE_MUL: Int = 2
const CORE_PRIMITIVE_DIV: Int = 3
const CORE_PRIMITIVE_MOD: Int = 4
const CORE_PRIMITIVE_NEGATE: Int = 5
const CORE_PRIMITIVE_NOT: Int = 6
const CORE_PRIMITIVE_LT: Int = 7
const CORE_PRIMITIVE_LE: Int = 8
const CORE_PRIMITIVE_GT: Int = 9
const CORE_PRIMITIVE_GE: Int = 10

pub struct CorePrimitiveOp { tag: Int }

pub fn make_core_primitive_op(tag: Int) -> CorePrimitiveOp {
    if tag < CORE_PRIMITIVE_ADD || tag > CORE_PRIMITIVE_GE {
        panic("CoreHIR: invalid 0.1 primitive operation")
    }
    CorePrimitiveOp { tag: tag }
}
pub fn core_primitive_op_tag(value: CorePrimitiveOp) -> Int {
    make_core_primitive_op(value.tag).tag
}

enum CorePatternValue {
    WildcardPatternValue,
    BindingPatternValue(SlotRef),
    LiteralPatternValue(CoreLiteral),
    TuplePatternValue(List<CorePattern>),
    StructPatternValue {
        owner: RegisteredNominalRef,
        fields: List<CorePatternField>
    },
    VariantPatternValue {
        variant: CoreVariantRef,
        fields: List<CorePatternField>
    }
}

pub struct CorePattern { value: CorePatternValue }

pub struct CorePatternField {
    field: CoreFieldRef,
    pattern: CorePattern
}

fn copy_patterns(values: List<CorePattern>) -> List<CorePattern> {
    let mut result: List<CorePattern> = []
    for value in values { result.push(value) }
    result
}
fn copy_pattern_fields(values: List<CorePatternField>) -> List<CorePatternField> {
    let mut result: List<CorePatternField> = []
    for value in values { result.push(value) }
    result
}

pub fn make_core_wildcard_pattern() -> CorePattern {
    CorePattern { value: CorePatternValue::WildcardPatternValue }
}
pub fn make_core_binding_pattern(slot: SlotRef) -> CorePattern {
    CorePattern { value: CorePatternValue::BindingPatternValue(slot) }
}
pub fn make_core_literal_pattern(literal: CoreLiteral) -> CorePattern {
    CorePattern { value: CorePatternValue::LiteralPatternValue(literal) }
}
pub fn make_core_tuple_pattern(elements: List<CorePattern>) -> CorePattern {
    CorePattern { value: CorePatternValue::TuplePatternValue(
        copy_patterns(elements)) }
}
pub fn make_core_pattern_field(
    field: CoreFieldRef, pattern: CorePattern
) -> CorePatternField { CorePatternField { field: field, pattern: pattern } }
pub fn make_core_struct_pattern(
    owner: RegisteredNominalRef, fields: List<CorePatternField>
) -> CorePattern {
    CorePattern { value: CorePatternValue::StructPatternValue {
        owner: owner, fields: copy_pattern_fields(fields)
    } }
}
pub fn make_core_variant_pattern(
    variant: CoreVariantRef, fields: List<CorePatternField>
) -> CorePattern {
    CorePattern { value: CorePatternValue::VariantPatternValue {
        variant: variant, fields: copy_pattern_fields(fields)
    } }
}
pub fn core_pattern_kind_tag(value: CorePattern) -> Int {
    match value.value {
        CorePatternValue::WildcardPatternValue => 0,
        CorePatternValue::BindingPatternValue(_) => 1,
        CorePatternValue::LiteralPatternValue(_) => 2,
        CorePatternValue::TuplePatternValue(_) => 3,
        CorePatternValue::StructPatternValue { .. } => 4,
        CorePatternValue::VariantPatternValue { .. } => 5
    }
}
pub fn core_pattern_binding(value: CorePattern) -> SlotRef {
    match value.value {
        CorePatternValue::BindingPatternValue(slot) => slot,
        _ => panic("CoreHIR: pattern is not a binding")
    }
}
pub fn core_pattern_literal(value: CorePattern) -> CoreLiteral {
    match value.value {
        CorePatternValue::LiteralPatternValue(literal) => literal,
        _ => panic("CoreHIR: pattern is not a literal")
    }
}
pub fn core_pattern_elements(value: CorePattern) -> List<CorePattern> {
    match value.value {
        CorePatternValue::TuplePatternValue(elements) => copy_patterns(elements),
        _ => panic("CoreHIR: pattern is not a tuple")
    }
}
pub fn core_pattern_fields(value: CorePattern) -> List<CorePatternField> {
    match value.value {
        CorePatternValue::StructPatternValue { fields, .. } |
        CorePatternValue::VariantPatternValue { fields, .. } =>
            copy_pattern_fields(fields),
        _ => panic("CoreHIR: pattern has no fields")
    }
}
pub fn core_pattern_struct_owner(value: CorePattern) -> RegisteredNominalRef {
    match value.value {
        CorePatternValue::StructPatternValue { owner, .. } => owner,
        _ => panic("CoreHIR: pattern is not a struct")
    }
}
pub fn core_pattern_variant(value: CorePattern) -> CoreVariantRef {
    match value.value {
        CorePatternValue::VariantPatternValue { variant, .. } => variant,
        _ => panic("CoreHIR: pattern is not a variant")
    }
}
pub fn core_pattern_field_ref(value: CorePatternField) -> CoreFieldRef {
    value.field
}
pub fn core_pattern_field_pattern(value: CorePatternField) -> CorePattern {
    value.pattern
}

// ============================================================
// Immutable structured Core expressions and statements
// ============================================================

pub struct CoreCapture {
    source: SlotRef,
    target: SlotRef
}
pub fn make_core_capture(source: SlotRef, target: SlotRef) -> CoreCapture {
    if slot_ref_same(source, target) {
        panic("CoreHIR: capture aliases its source")
    }
    CoreCapture { source: source, target: target }
}
pub fn core_capture_source(value: CoreCapture) -> SlotRef { value.source }
pub fn core_capture_target(value: CoreCapture) -> SlotRef { value.target }
fn copy_captures(values: List<CoreCapture>) -> List<CoreCapture> {
    let mut result: List<CoreCapture> = []
    for value in values { result.push(value) }
    result
}

enum CoreExprValue {
    LiteralExprValue(CoreLiteral),
    ReadExprValue(SlotRef),
    PrimitiveExprValue { operation: CorePrimitiveOp, operands: List<SlotRef> },
    CallExprValue {
        callee: CoreCalleeRef,
        arguments: List<SlotRef>,
        evidence: List<CoreEvidenceRef>
    },
    MethodCallExprValue {
        callee: CoreCalleeRef,
        method: MethodCallRef,
        receiver: SlotRef,
        arguments: List<SlotRef>,
        evidence: List<CoreEvidenceRef>
    },
    EffectCallExprValue {
        operation: CoreEffectOperationRef,
        arguments: List<SlotRef>,
        evidence: List<CoreEvidenceRef>
    },
    DictConstructExprValue {
        constructor: ExecutableRef,
        evidence: List<CoreEvidenceRef>
    },
    DictProjectExprValue {
        dictionary: SlotRef,
        method: ExecutableRef
    },
    ProjectExprValue {
        base: SlotRef,
        field: CoreFieldRef,
        partial: Bool
    },
    ConstructExprValue {
        constructor: CoreConstructorRef,
        fields: List<CoreFieldValue>
    },
    LambdaExprValue {
        executable: ExecutableRef,
        manifest: BinderManifest,
        captures: List<CoreCapture>
    },
    BlockExprValue(CoreBlock),
    IfExprValue {
        condition: SlotRef,
        then_block: CoreBlock,
        else_block: CoreBlock
    },
    MatchExprValue {
        scrutinee: SlotRef,
        arms: List<CoreMatchArm>
    },
    TryCatchExprValue {
        body: CoreBlock,
        error_slot: SlotRef,
        arms: List<CoreMatchArm>
    },
    HandleExprValue {
        body: CoreBlock,
        handlers: List<CoreHandlerEntry>
    }
}

pub struct CoreExpr {
    result: SlotRef,
    ty: CoreTypeRef,
    effects: CoreEffectSet,
    origin: OriginRef,
    value: CoreExprValue
}

enum CoreStmtValue {
    Initialize {
        target: SlotRef, value: CoreExpr, origin: OriginRef
    },
    Assign {
        target: SlotRef, value: CoreExpr, origin: OriginRef
    },
    ExprStmt { value: CoreExpr, origin: OriginRef },
    While {
        condition: CoreExpr, body: CoreBlock, origin: OriginRef
    },
    Break { origin: OriginRef },
    Continue { origin: OriginRef },
    Return { value: CoreExpr?, origin: OriginRef }
}

pub struct CoreStmt { value: CoreStmtValue }

pub struct CoreBlock {
    statements: List<CoreStmt>,
    tail: CoreExpr?,
    origin: OriginRef
}

pub struct CoreMatchArm {
    pattern: CorePattern,
    guard: CoreExpr?,
    body: CoreBlock,
    origin: OriginRef
}

pub struct CoreHandlerEntry {
    operation: CoreEffectOperationRef,
    executable: ExecutableRef,
    manifest: BinderManifest,
    parameter_slots: List<SlotRef>,
    resume_slot: SlotRef?,
    origin: OriginRef
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
fn copy_match_arms(values: List<CoreMatchArm>) -> List<CoreMatchArm> {
    let mut result: List<CoreMatchArm> = []
    for value in values { result.push(value) }
    result
}
fn copy_handler_entries(values: List<CoreHandlerEntry>) -> List<CoreHandlerEntry> {
    let mut result: List<CoreHandlerEntry> = []
    for value in values { result.push(value) }
    result
}
fn copy_manifest(value: BinderManifest) -> BinderManifest {
    make_binder_manifest(
        binder_manifest_owner(value), binder_manifest_entries(value))
}

fn make_core_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, value: CoreExprValue
) -> CoreExpr {
    CoreExpr {
        result: result, ty: ty,
        effects: make_core_effect_set(effects.atoms),
        origin: origin, value: value
    }
}

pub fn make_core_literal_expr(
    result: SlotRef, ty: CoreTypeRef, origin: OriginRef, literal: CoreLiteral
) -> CoreExpr {
    make_core_expr(
        result, ty, make_core_effect_set([]), origin,
        CoreExprValue::LiteralExprValue(literal))
}
pub fn make_core_read_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, source: SlotRef
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::ReadExprValue(source))
}
pub fn make_core_primitive_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, operation: CorePrimitiveOp,
    operands: List<SlotRef>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::PrimitiveExprValue {
            operation: operation, operands: copy_slot_refs(operands)
        })
}
pub fn make_core_call_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, callee: CoreCalleeRef,
    arguments: List<SlotRef>, evidence: List<CoreEvidenceRef>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::CallExprValue {
            callee: callee, arguments: copy_slot_refs(arguments),
            evidence: copy_evidence(evidence)
        })
}
pub fn make_core_method_call_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, callee: CoreCalleeRef, method: MethodCallRef,
    receiver: SlotRef, arguments: List<SlotRef>,
    evidence: List<CoreEvidenceRef>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::MethodCallExprValue {
            callee: callee, method: method, receiver: receiver,
            arguments: copy_slot_refs(arguments),
            evidence: copy_evidence(evidence)
        })
}
pub fn make_core_effect_call_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, operation: CoreEffectOperationRef,
    arguments: List<SlotRef>, evidence: List<CoreEvidenceRef>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::EffectCallExprValue {
            operation: operation, arguments: copy_slot_refs(arguments),
            evidence: copy_evidence(evidence)
        })
}
pub fn make_core_dict_construct_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, constructor: ExecutableRef,
    evidence: List<CoreEvidenceRef>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::DictConstructExprValue {
            constructor: constructor, evidence: copy_evidence(evidence)
        })
}
pub fn make_core_dict_project_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, dictionary: SlotRef, method: ExecutableRef
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::DictProjectExprValue {
            dictionary: dictionary, method: method
        })
}
pub fn make_core_project_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, base: SlotRef, field: CoreFieldRef, partial: Bool
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::ProjectExprValue {
            base: base, field: field, partial: partial
        })
}
pub fn make_core_construct_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, constructor: CoreConstructorRef,
    fields: List<CoreFieldValue>
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::ConstructExprValue {
            constructor: constructor, fields: copy_field_values(fields)
        })
}
pub fn make_core_lambda_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, executable: ExecutableRef,
    manifest: BinderManifest, captures: List<CoreCapture>
) -> CoreExpr {
    if !executable_ref_same(executable, binder_manifest_owner(manifest)) {
        panic("CoreHIR: lambda executable/manifest identity differs")
    }
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::LambdaExprValue {
            executable: executable, manifest: copy_manifest(manifest),
            captures: copy_captures(captures)
        })
}

pub fn make_core_block(
    statements: List<CoreStmt>, tail: CoreExpr?, origin: OriginRef
) -> CoreBlock {
    CoreBlock {
        statements: copy_statements(statements), tail: tail, origin: origin
    }
}
pub fn make_core_match_arm(
    pattern: CorePattern, guard: CoreExpr?, body: CoreBlock,
    origin: OriginRef
) -> CoreMatchArm {
    CoreMatchArm {
        pattern: pattern, guard: guard, body: body, origin: origin
    }
}
pub fn make_core_handler_entry(
    operation: CoreEffectOperationRef, executable: ExecutableRef,
    manifest: BinderManifest, parameter_slots: List<SlotRef>,
    resume_slot: SlotRef?, origin: OriginRef
) -> CoreHandlerEntry {
    if !executable_ref_same(executable, binder_manifest_owner(manifest)) {
        panic("CoreHIR: handler executable/manifest identity differs")
    }
    CoreHandlerEntry {
        operation: operation, executable: executable,
        manifest: copy_manifest(manifest),
        parameter_slots: copy_slot_refs(parameter_slots),
        resume_slot: resume_slot, origin: origin
    }
}
pub fn make_core_block_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, block: CoreBlock
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::BlockExprValue(block))
}
pub fn make_core_if_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, condition: SlotRef,
    then_block: CoreBlock, else_block: CoreBlock
) -> CoreExpr {
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::IfExprValue {
            condition: condition,
            then_block: then_block, else_block: else_block
        })
}
pub fn make_core_match_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, scrutinee: SlotRef, arms: List<CoreMatchArm>
) -> CoreExpr {
    if arms.len() == 0 { panic("CoreHIR: match has no arms") }
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::MatchExprValue {
            scrutinee: scrutinee, arms: copy_match_arms(arms)
        })
}
pub fn make_core_try_catch_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, body: CoreBlock, error_slot: SlotRef,
    arms: List<CoreMatchArm>
) -> CoreExpr {
    if arms.len() == 0 { panic("CoreHIR: catch has no arms") }
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::TryCatchExprValue {
            body: body, error_slot: error_slot,
            arms: copy_match_arms(arms)
        })
}
pub fn make_core_handle_expr(
    result: SlotRef, ty: CoreTypeRef, effects: CoreEffectSet,
    origin: OriginRef, body: CoreBlock,
    handlers: List<CoreHandlerEntry>
) -> CoreExpr {
    if handlers.len() == 0 { panic("CoreHIR: handle has no handlers") }
    make_core_expr(result, ty, effects, origin,
        CoreExprValue::HandleExprValue {
            body: body, handlers: copy_handler_entries(handlers)
        })
}

pub fn make_core_initialize_stmt(
    target: SlotRef, value: CoreExpr, origin: OriginRef
) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::Initialize {
        target: target, value: value, origin: origin
    } }
}
pub fn make_core_assign_stmt(
    target: SlotRef, value: CoreExpr, origin: OriginRef
) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::Assign {
        target: target, value: value, origin: origin
    } }
}
pub fn make_core_expr_stmt(value: CoreExpr, origin: OriginRef) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::ExprStmt {
        value: value, origin: origin
    } }
}
pub fn make_core_while_stmt(
    condition: CoreExpr, body: CoreBlock, origin: OriginRef
) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::While {
        condition: condition, body: body, origin: origin
    } }
}
pub fn make_core_break_stmt(origin: OriginRef) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::Break { origin: origin } }
}
pub fn make_core_continue_stmt(origin: OriginRef) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::Continue { origin: origin } }
}
pub fn make_core_return_stmt(value: CoreExpr?, origin: OriginRef) -> CoreStmt {
    CoreStmt { value: CoreStmtValue::Return {
        value: value, origin: origin
    } }
}

pub fn core_stmt_kind_tag(value: CoreStmt) -> Int {
    match value.value {
        CoreStmtValue::Initialize { .. } => 0,
        CoreStmtValue::Assign { .. } => 1,
        CoreStmtValue::ExprStmt { .. } => 2,
        CoreStmtValue::While { .. } => 3,
        CoreStmtValue::Break { .. } => 4,
        CoreStmtValue::Continue { .. } => 5,
        CoreStmtValue::Return { .. } => 6
    }
}
pub fn core_stmt_origin(value: CoreStmt) -> OriginRef {
    match value.value {
        CoreStmtValue::Initialize { origin, .. } |
        CoreStmtValue::Assign { origin, .. } |
        CoreStmtValue::ExprStmt { origin, .. } |
        CoreStmtValue::While { origin, .. } |
        CoreStmtValue::Break { origin } |
        CoreStmtValue::Continue { origin } |
        CoreStmtValue::Return { origin, .. } => origin
    }
}
pub fn core_stmt_target(value: CoreStmt) -> SlotRef {
    match value.value {
        CoreStmtValue::Initialize { target, .. } |
        CoreStmtValue::Assign { target, .. } => target,
        _ => panic("CoreHIR: statement has no target")
    }
}
pub fn core_stmt_value(value: CoreStmt) -> CoreExpr {
    match value.value {
        CoreStmtValue::Initialize { value: expr, .. } |
        CoreStmtValue::Assign { value: expr, .. } |
        CoreStmtValue::ExprStmt { value: expr, .. } => expr,
        _ => panic("CoreHIR: statement has no required expression")
    }
}
pub fn core_stmt_while_condition(value: CoreStmt) -> CoreExpr {
    match value.value {
        CoreStmtValue::While { condition, .. } => condition,
        _ => panic("CoreHIR: statement is not While")
    }
}
pub fn core_stmt_while_body(value: CoreStmt) -> CoreBlock {
    match value.value {
        CoreStmtValue::While { body, .. } => body,
        _ => panic("CoreHIR: statement is not While")
    }
}
pub fn core_stmt_return_value(value: CoreStmt) -> CoreExpr? {
    match value.value {
        CoreStmtValue::Return { value: returned, .. } => returned,
        _ => panic("CoreHIR: statement is not Return")
    }
}

pub fn core_expr_result(value: CoreExpr) -> SlotRef { value.result }
pub fn core_expr_type(value: CoreExpr) -> CoreTypeRef { value.ty }
pub fn core_expr_effects(value: CoreExpr) -> CoreEffectSet {
    make_core_effect_set(value.effects.atoms)
}
pub fn core_expr_origin(value: CoreExpr) -> OriginRef { value.origin }
pub fn core_expr_kind_tag(value: CoreExpr) -> Int {
    match value.value {
        CoreExprValue::LiteralExprValue(_) => 0,
        CoreExprValue::ReadExprValue(_) => 1,
        CoreExprValue::PrimitiveExprValue { .. } => 2,
        CoreExprValue::CallExprValue { .. } => 3,
        CoreExprValue::MethodCallExprValue { .. } => 4,
        CoreExprValue::EffectCallExprValue { .. } => 5,
        CoreExprValue::DictConstructExprValue { .. } => 6,
        CoreExprValue::DictProjectExprValue { .. } => 7,
        CoreExprValue::ProjectExprValue { .. } => 8,
        CoreExprValue::ConstructExprValue { .. } => 9,
        CoreExprValue::LambdaExprValue { .. } => 10,
        CoreExprValue::BlockExprValue(_) => 11,
        CoreExprValue::IfExprValue { .. } => 12,
        CoreExprValue::MatchExprValue { .. } => 13,
        CoreExprValue::TryCatchExprValue { .. } => 14,
        CoreExprValue::HandleExprValue { .. } => 15
    }
}
pub fn core_expr_literal(value: CoreExpr) -> CoreLiteral {
    match value.value {
        CoreExprValue::LiteralExprValue(literal) => literal,
        _ => panic("CoreHIR: expression is not Literal")
    }
}
pub fn core_expr_read_source(value: CoreExpr) -> SlotRef {
    match value.value {
        CoreExprValue::ReadExprValue(source) => source,
        _ => panic("CoreHIR: expression is not Read")
    }
}
pub fn core_expr_primitive_operation(value: CoreExpr) -> CorePrimitiveOp {
    match value.value {
        CoreExprValue::PrimitiveExprValue { operation, .. } => operation,
        _ => panic("CoreHIR: expression is not Primitive")
    }
}
pub fn core_expr_primitive_operands(value: CoreExpr) -> List<SlotRef> {
    match value.value {
        CoreExprValue::PrimitiveExprValue { operands, .. } =>
            copy_slot_refs(operands),
        _ => panic("CoreHIR: expression is not Primitive")
    }
}
pub fn core_expr_call_callee(value: CoreExpr) -> CoreCalleeRef {
    match value.value {
        CoreExprValue::CallExprValue { callee, .. } |
        CoreExprValue::MethodCallExprValue { callee, .. } => callee,
        _ => panic("CoreHIR: expression has no callee")
    }
}
pub fn core_expr_call_arguments(value: CoreExpr) -> List<SlotRef> {
    match value.value {
        CoreExprValue::CallExprValue { arguments, .. } |
        CoreExprValue::MethodCallExprValue { arguments, .. } |
        CoreExprValue::EffectCallExprValue { arguments, .. } =>
            copy_slot_refs(arguments),
        _ => panic("CoreHIR: expression has no call arguments")
    }
}
pub fn core_expr_call_evidence(value: CoreExpr) -> List<CoreEvidenceRef> {
    match value.value {
        CoreExprValue::CallExprValue { evidence, .. } |
        CoreExprValue::MethodCallExprValue { evidence, .. } |
        CoreExprValue::EffectCallExprValue { evidence, .. } |
        CoreExprValue::DictConstructExprValue { evidence, .. } =>
            copy_evidence(evidence),
        _ => panic("CoreHIR: expression has no evidence list")
    }
}
pub fn core_expr_method_ref(value: CoreExpr) -> MethodCallRef {
    match value.value {
        CoreExprValue::MethodCallExprValue { method, .. } => method,
        _ => panic("CoreHIR: expression is not MethodCall")
    }
}
pub fn core_expr_method_receiver(value: CoreExpr) -> SlotRef {
    match value.value {
        CoreExprValue::MethodCallExprValue { receiver, .. } => receiver,
        _ => panic("CoreHIR: expression is not MethodCall")
    }
}
pub fn core_expr_effect_operation(value: CoreExpr) -> CoreEffectOperationRef {
    match value.value {
        CoreExprValue::EffectCallExprValue { operation, .. } => operation,
        _ => panic("CoreHIR: expression is not EffectCall")
    }
}
pub fn core_expr_dict_constructor(value: CoreExpr) -> ExecutableRef {
    match value.value {
        CoreExprValue::DictConstructExprValue { constructor, .. } => constructor,
        _ => panic("CoreHIR: expression is not DictConstruct")
    }
}
pub fn core_expr_dict_project_dictionary(value: CoreExpr) -> SlotRef {
    match value.value {
        CoreExprValue::DictProjectExprValue { dictionary, .. } => dictionary,
        _ => panic("CoreHIR: expression is not DictProject")
    }
}
pub fn core_expr_dict_project_method(value: CoreExpr) -> ExecutableRef {
    match value.value {
        CoreExprValue::DictProjectExprValue { method, .. } => method,
        _ => panic("CoreHIR: expression is not DictProject")
    }
}
pub fn core_expr_project_base(value: CoreExpr) -> SlotRef {
    match value.value {
        CoreExprValue::ProjectExprValue { base, .. } => base,
        _ => panic("CoreHIR: expression is not Project")
    }
}
pub fn core_expr_project_field(value: CoreExpr) -> CoreFieldRef {
    match value.value {
        CoreExprValue::ProjectExprValue { field, .. } => field,
        _ => panic("CoreHIR: expression is not Project")
    }
}
pub fn core_expr_project_is_partial(value: CoreExpr) -> Bool {
    match value.value {
        CoreExprValue::ProjectExprValue { partial, .. } => partial,
        _ => panic("CoreHIR: expression is not Project")
    }
}
pub fn core_expr_constructor(value: CoreExpr) -> CoreConstructorRef {
    match value.value {
        CoreExprValue::ConstructExprValue { constructor, .. } => constructor,
        _ => panic("CoreHIR: expression is not Construct")
    }
}
pub fn core_expr_constructor_fields(value: CoreExpr) -> List<CoreFieldValue> {
    match value.value {
        CoreExprValue::ConstructExprValue { fields, .. } =>
            copy_field_values(fields),
        _ => panic("CoreHIR: expression is not Construct")
    }
}
pub fn core_expr_lambda_executable(value: CoreExpr) -> ExecutableRef {
    match value.value {
        CoreExprValue::LambdaExprValue { executable, .. } => executable,
        _ => panic("CoreHIR: expression is not Lambda")
    }
}
pub fn core_expr_lambda_manifest(value: CoreExpr) -> BinderManifest {
    match value.value {
        CoreExprValue::LambdaExprValue { manifest, .. } => copy_manifest(manifest),
        _ => panic("CoreHIR: expression is not Lambda")
    }
}
pub fn core_expr_lambda_captures(value: CoreExpr) -> List<CoreCapture> {
    match value.value {
        CoreExprValue::LambdaExprValue { captures, .. } => copy_captures(captures),
        _ => panic("CoreHIR: expression is not Lambda")
    }
}
pub fn core_expr_block(value: CoreExpr) -> CoreBlock {
    match value.value {
        CoreExprValue::BlockExprValue(block) => block,
        _ => panic("CoreHIR: expression is not Block")
    }
}
pub fn core_expr_condition(value: CoreExpr) -> SlotRef {
    match value.value {
        CoreExprValue::IfExprValue { condition, .. } => condition,
        _ => panic("CoreHIR: expression is not If")
    }
}
pub fn core_expr_then_block(value: CoreExpr) -> CoreBlock {
    match value.value {
        CoreExprValue::IfExprValue { then_block, .. } => then_block,
        _ => panic("CoreHIR: expression is not If")
    }
}
pub fn core_expr_else_block(value: CoreExpr) -> CoreBlock {
    match value.value {
        CoreExprValue::IfExprValue { else_block, .. } => else_block,
        _ => panic("CoreHIR: expression is not If")
    }
}
pub fn core_expr_scrutinee(value: CoreExpr) -> SlotRef {
    match value.value {
        CoreExprValue::MatchExprValue { scrutinee, .. } => scrutinee,
        _ => panic("CoreHIR: expression is not Match")
    }
}
pub fn core_expr_match_arms(value: CoreExpr) -> List<CoreMatchArm> {
    match value.value {
        CoreExprValue::MatchExprValue { arms, .. } |
        CoreExprValue::TryCatchExprValue { arms, .. } => copy_match_arms(arms),
        _ => panic("CoreHIR: expression has no match arms")
    }
}
pub fn core_expr_try_body(value: CoreExpr) -> CoreBlock {
    match value.value {
        CoreExprValue::TryCatchExprValue { body, .. } => body,
        _ => panic("CoreHIR: expression is not TryCatch")
    }
}
pub fn core_expr_error_slot(value: CoreExpr) -> SlotRef {
    match value.value {
        CoreExprValue::TryCatchExprValue { error_slot, .. } => error_slot,
        _ => panic("CoreHIR: expression is not TryCatch")
    }
}
pub fn core_expr_handle_body(value: CoreExpr) -> CoreBlock {
    match value.value {
        CoreExprValue::HandleExprValue { body, .. } => body,
        _ => panic("CoreHIR: expression is not Handle")
    }
}
pub fn core_expr_handlers(value: CoreExpr) -> List<CoreHandlerEntry> {
    match value.value {
        CoreExprValue::HandleExprValue { handlers, .. } =>
            copy_handler_entries(handlers),
        _ => panic("CoreHIR: expression is not Handle")
    }
}
pub fn core_block_statements(value: CoreBlock) -> List<CoreStmt> {
    copy_statements(value.statements)
}
pub fn core_block_tail(value: CoreBlock) -> CoreExpr? { value.tail }
pub fn core_block_origin(value: CoreBlock) -> OriginRef { value.origin }
pub fn core_match_arm_pattern(value: CoreMatchArm) -> CorePattern { value.pattern }
pub fn core_match_arm_guard(value: CoreMatchArm) -> CoreExpr? { value.guard }
pub fn core_match_arm_body(value: CoreMatchArm) -> CoreBlock { value.body }
pub fn core_match_arm_origin(value: CoreMatchArm) -> OriginRef { value.origin }
pub fn core_handler_operation(
    value: CoreHandlerEntry
) -> CoreEffectOperationRef { value.operation }
pub fn core_handler_executable(value: CoreHandlerEntry) -> ExecutableRef {
    value.executable
}
pub fn core_handler_manifest(value: CoreHandlerEntry) -> BinderManifest {
    copy_manifest(value.manifest)
}
pub fn core_handler_parameter_slots(value: CoreHandlerEntry) -> List<SlotRef> {
    copy_slot_refs(value.parameter_slots)
}
pub fn core_handler_resume_slot(value: CoreHandlerEntry) -> SlotRef? {
    value.resume_slot
}
pub fn core_handler_origin(value: CoreHandlerEntry) -> OriginRef { value.origin }

// ============================================================
// Closed structured body and recursive validator
// ============================================================

pub struct CoreSlot {
    reference: SlotRef,
    ty: CoreTypeRef
}

pub fn make_core_slot(reference: SlotRef, ty: CoreTypeRef) -> CoreSlot {
    CoreSlot { reference: reference, ty: ty }
}
pub fn core_slot_reference(value: CoreSlot) -> SlotRef { value.reference }
pub fn core_slot_type(value: CoreSlot) -> CoreTypeRef { value.ty }
fn copy_core_slots(values: List<CoreSlot>) -> List<CoreSlot> {
    let mut result: List<CoreSlot> = []
    for value in values { result.push(value) }
    result
}

pub struct CoreBody {
    reference: ExecutableRef,
    origin: OriginRef,
    type_count: Int,
    manifest: BinderManifest,
    slots: List<CoreSlot>,
    parameter_slots: List<SlotRef>,
    result_type: CoreTypeRef,
    body: CoreBlock
}

fn path_module_key(value: PathRef) -> Str {
    let owner = path_ref_owner(value)
    if path_owner_ref_is_symbol(owner) {
        symbol_ref_origin_module_key(path_owner_ref_symbol(owner))
    } else {
        module_body_ref_origin_module_key(path_owner_ref_module_body(owner))
    }
}
fn origin_module_key(value: OriginRef) -> Str {
    if origin_ref_is_symbol(value) {
        symbol_ref_origin_module_key(origin_ref_symbol(value))
    } else {
        path_module_key(origin_ref_path(value))
    }
}
fn validate_origin(value: OriginRef, owner: ExecutableRef) {
    if origin_module_key(value) != executable_ref_origin_module_key(owner) {
        panic("CoreHIR: origin crosses executable module")
    }
}
fn type_ref_valid(value: CoreTypeRef, type_count: Int) -> Bool {
    value.index >= 0 && value.index < type_count
}
fn slot_index(values: List<CoreSlot>, target: SlotRef) -> Int? {
    let mut index = 0
    for value in values {
        if slot_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}
fn require_slot(values: List<CoreSlot>, target: SlotRef) {
    if slot_index(values, target).is_none() {
        panic("CoreHIR: expression references an undeclared slot")
    }
}
fn validate_effect_set(value: CoreEffectSet, type_count: Int) {
    let _ = make_core_effect_set(value.atoms)
    for atom in value.atoms {
        match atom.value {
            CoreEffectAtomValue::FailEffectValue(ty) |
            CoreEffectAtomValue::MutEffectValue(ty) => if !type_ref_valid(
                    ty, type_count) {
                panic("CoreHIR: effect atom has an unresolved type")
            },
            _ => {}
        }
    }
}
fn validate_evidence(values: List<CoreEvidenceRef>, slots: List<CoreSlot>) {
    for value in values {
        if core_evidence_is_local(value) {
            require_slot(slots, core_evidence_local(value))
        }
    }
}

fn manifest_contains_slot(value: BinderManifest, target: SlotRef) -> Bool {
    for binder in binder_manifest_entries(value) {
        if slot_ref_same(binder_entry_slot(binder), target) { return true }
    }
    false
}

fn validate_pattern(
    value: CorePattern, slots: List<CoreSlot>, seen: List<SlotRef>
) -> List<SlotRef> {
    let mut result = copy_slot_refs(seen)
    match value.value {
        CorePatternValue::WildcardPatternValue |
        CorePatternValue::LiteralPatternValue(_) => {},
        CorePatternValue::BindingPatternValue(slot) => {
            require_slot(slots, slot)
            for existing in result {
                if slot_ref_same(existing, slot) {
                    panic("CoreHIR: pattern binds a slot twice")
                }
            }
            result.push(slot)
        },
        CorePatternValue::TuplePatternValue(elements) => {
            for element in elements {
                result = validate_pattern(element, slots, result)
            }
        },
        CorePatternValue::StructPatternValue { owner, fields } => {
            let owner_symbol = registered_nominal_ref_symbol(owner)
            let mut field_index = 0
            while field_index < fields.len() {
                let field = fields.get(field_index).unwrap()
                match field.field.value {
                    CoreFieldRefValue::NominalFieldValue(reference) => {
                        if !symbol_ref_same(
                                nominal_field_ref_owner(reference), owner_symbol) {
                            panic("CoreHIR: struct pattern field crosses owner")
                        }
                    },
                    _ => panic("CoreHIR: struct pattern uses non-nominal field")
                }
                let mut right_index = field_index + 1
                while right_index < fields.len() {
                    if core_field_ref_same(
                            field.field,
                            fields.get(right_index).unwrap().field) {
                        panic("CoreHIR: pattern repeats a field")
                    }
                    right_index = right_index + 1
                }
                result = validate_pattern(field.pattern, slots, result)
                field_index = field_index + 1
            }
        },
        CorePatternValue::VariantPatternValue { variant, fields } => {
            let owner_symbol = registered_nominal_ref_symbol(variant.owner)
            let mut field_index = 0
            while field_index < fields.len() {
                let field = fields.get(field_index).unwrap()
                match field.field.value {
                    CoreFieldRefValue::NominalFieldValue(reference) => {
                        if !symbol_ref_same(
                                nominal_field_ref_owner(reference), owner_symbol) {
                            panic("CoreHIR: variant pattern field crosses owner")
                        }
                    },
                    CoreFieldRefValue::TupleFieldValue(_) => {},
                    CoreFieldRefValue::RecordFieldValue(_) => {}
                }
                let mut right_index = field_index + 1
                while right_index < fields.len() {
                    if core_field_ref_same(
                            field.field,
                            fields.get(right_index).unwrap().field) {
                        panic("CoreHIR: variant pattern repeats a field")
                    }
                    right_index = right_index + 1
                }
                result = validate_pattern(field.pattern, slots, result)
                field_index = field_index + 1
            }
        }
    }
    result
}

fn validate_callee(value: CoreCalleeRef, body: CoreBody) {
    if value.kind == CORE_CALLEE_DIRECT {
        let executable = match value.direct {
            some(item) => item,
            none => panic("CoreHIR: direct callee lacks executable")
        }
        if !callee_ref_same(
                value.callee,
                make_named_callee_ref(executable_ref_named_symbol(executable))) {
            panic("CoreHIR: direct CalleeRef/executable differs")
        }
    } else if value.kind == CORE_CALLEE_LOCAL {
        let slot = match value.local {
            some(item) => item,
            none => panic("CoreHIR: local callee lacks slot")
        }
        require_slot(body.slots, slot)
        if !callee_ref_same(value.callee, make_local_callee_ref(slot)) {
            panic("CoreHIR: local CalleeRef/slot differs")
        }
    } else if value.kind == CORE_CALLEE_DYNAMIC {
        let path = match value.dynamic {
            some(item) => item,
            none => panic("CoreHIR: dynamic callee lacks path")
        }
        if path_module_key(path) != executable_ref_origin_module_key(
                body.reference) ||
           !callee_ref_same(value.callee, make_dynamic_callee_ref(path)) {
            panic("CoreHIR: dynamic CalleeRef/path differs")
        }
    } else {
        panic("CoreHIR: unknown callee form")
    }
}

fn validate_constructor_fields(
    constructor: CoreConstructorRef, fields: List<CoreFieldValue>,
    slots: List<CoreSlot>
) {
    let mut index = 0
    while index < fields.len() {
        let field = fields.get(index).unwrap()
        require_slot(slots, field.value)
        let mut right_index = index + 1
        while right_index < fields.len() {
            if core_field_ref_same(
                    field.field, fields.get(right_index).unwrap().field) {
                panic("CoreHIR: constructor repeats a field")
            }
            right_index = right_index + 1
        }
        index = index + 1
    }
    match constructor.value {
        CoreConstructorRefValue::StructConstructorValue(owner) => {
            let symbol = registered_nominal_ref_symbol(owner)
            for field in fields {
                match field.field.value {
                    CoreFieldRefValue::NominalFieldValue(reference) => if
                        !symbol_ref_same(
                            nominal_field_ref_owner(reference), symbol) {
                        panic("CoreHIR: struct constructor field crosses owner")
                    },
                    _ => panic("CoreHIR: struct constructor uses non-nominal field")
                }
            }
        },
        CoreConstructorRefValue::VariantConstructorValue(variant) => {
            let symbol = registered_nominal_ref_symbol(variant.owner)
            for field in fields {
                match field.field.value {
                    CoreFieldRefValue::NominalFieldValue(reference) => if
                        !symbol_ref_same(
                            nominal_field_ref_owner(reference), symbol) {
                        panic("CoreHIR: variant constructor field crosses owner")
                    },
                    CoreFieldRefValue::TupleFieldValue(_) |
                    CoreFieldRefValue::RecordFieldValue(_) => {}
                }
            }
        },
        CoreConstructorRefValue::TupleConstructorValue(arity) |
        CoreConstructorRefValue::RecordConstructorValue(arity) => {
            if fields.len() != arity {
                panic("CoreHIR: structural constructor arity differs")
            }
        }
    }
}

fn validate_expr_with_loop_depth(
    value: CoreExpr, body: CoreBody, loop_depth: Int
) {
    require_slot(body.slots, value.result)
    if !type_ref_valid(value.ty, body.type_count) {
        panic("CoreHIR: expression has an unresolved type")
    }
    validate_origin(value.origin, body.reference)
    validate_effect_set(value.effects, body.type_count)
    match value.value {
        CoreExprValue::LiteralExprValue(_) => {},
        CoreExprValue::ReadExprValue(source) => require_slot(body.slots, source),
        CoreExprValue::PrimitiveExprValue { operation, operands } => {
            let _ = core_primitive_op_tag(operation)
            for operand in operands { require_slot(body.slots, operand) }
        },
        CoreExprValue::CallExprValue { callee, arguments, evidence } => {
            validate_callee(callee, body)
            for argument in arguments { require_slot(body.slots, argument) }
            validate_evidence(evidence, body.slots)
        },
        CoreExprValue::MethodCallExprValue {
            callee, receiver, arguments, evidence, ..
        } => {
            validate_callee(callee, body)
            require_slot(body.slots, receiver)
            for argument in arguments { require_slot(body.slots, argument) }
            validate_evidence(evidence, body.slots)
        },
        CoreExprValue::EffectCallExprValue {
            arguments, evidence, ..
        } => {
            for argument in arguments { require_slot(body.slots, argument) }
            validate_evidence(evidence, body.slots)
        },
        CoreExprValue::DictConstructExprValue { evidence, .. } =>
            validate_evidence(evidence, body.slots),
        CoreExprValue::DictProjectExprValue { dictionary, .. } =>
            require_slot(body.slots, dictionary),
        CoreExprValue::ProjectExprValue { base, .. } =>
            require_slot(body.slots, base),
        CoreExprValue::ConstructExprValue { constructor, fields } =>
            validate_constructor_fields(constructor, fields, body.slots),
        CoreExprValue::LambdaExprValue {
            executable, manifest, captures
        } => {
            if !executable_ref_same(
                    executable, binder_manifest_owner(manifest)) {
                panic("CoreHIR: lambda manifest drifted")
            }
            for capture in captures {
                require_slot(body.slots, capture.source)
                if !manifest_contains_slot(manifest, capture.target) {
                    panic("CoreHIR: lambda capture target is absent from manifest")
                }
            }
        },
        CoreExprValue::BlockExprValue(block) =>
            validate_block_with_loop_depth(block, body, loop_depth),
        CoreExprValue::IfExprValue {
            condition, then_block, else_block
        } => {
            require_slot(body.slots, condition)
            validate_block_with_loop_depth(then_block, body, loop_depth)
            validate_block_with_loop_depth(else_block, body, loop_depth)
        },
        CoreExprValue::MatchExprValue { scrutinee, arms } => {
            require_slot(body.slots, scrutinee)
            for arm in arms { validate_match_arm(arm, body, loop_depth) }
        },
        CoreExprValue::TryCatchExprValue {
            body: protected, error_slot, arms
        } => {
            require_slot(body.slots, error_slot)
            validate_block_with_loop_depth(protected, body, loop_depth)
            for arm in arms { validate_match_arm(arm, body, loop_depth) }
        },
        CoreExprValue::HandleExprValue { body: handled_body, handlers } => {
            validate_block_with_loop_depth(handled_body, body, loop_depth)
            let mut index = 0
            while index < handlers.len() {
                let handler = handlers.get(index).unwrap()
                validate_origin(handler.origin, body.reference)
                if !executable_ref_same(
                        handler.executable,
                        binder_manifest_owner(handler.manifest)) {
                    panic("CoreHIR: handler manifest drifted")
                }
                for parameter in handler.parameter_slots {
                    if !manifest_contains_slot(handler.manifest, parameter) {
                        panic("CoreHIR: handler parameter is absent from manifest")
                    }
                }
                match handler.resume_slot {
                    some(slot) => if !manifest_contains_slot(
                            handler.manifest, slot) {
                        panic("CoreHIR: handler resume slot is absent from manifest")
                    },
                    none => {}
                }
                let mut right_index = index + 1
                while right_index < handlers.len() {
                    let right = handlers.get(right_index).unwrap()
                    if symbol_ref_same(
                            handler.operation.effect_symbol,
                            right.operation.effect_symbol) &&
                       symbol_ref_same(
                            handler.operation.operation,
                            right.operation.operation) {
                        panic("CoreHIR: handle repeats an exact operation")
                    }
                    right_index = right_index + 1
                }
                index = index + 1
            }
        }
    }
}

fn validate_expr(value: CoreExpr, body: CoreBody) {
    validate_expr_with_loop_depth(value, body, 0)
}

fn validate_match_arm(
    value: CoreMatchArm, body: CoreBody, loop_depth: Int
) {
    validate_origin(value.origin, body.reference)
    let _ = validate_pattern(value.pattern, body.slots, [])
    match value.guard {
        some(guard) => validate_expr_with_loop_depth(
            guard, body, loop_depth),
        none => {}
    }
    validate_block_with_loop_depth(value.body, body, loop_depth)
}

fn validate_statement(value: CoreStmt, body: CoreBody, loop_depth: Int) {
    match value.value {
        CoreStmtValue::Initialize { target, value: expr, origin } |
        CoreStmtValue::Assign { target, value: expr, origin } => {
            validate_origin(origin, body.reference)
            require_slot(body.slots, target)
            validate_expr_with_loop_depth(expr, body, loop_depth)
        },
        CoreStmtValue::ExprStmt { value: expr, origin } => {
            validate_origin(origin, body.reference)
            validate_expr_with_loop_depth(expr, body, loop_depth)
        },
        CoreStmtValue::While { condition, body: loop_body, origin } => {
            validate_origin(origin, body.reference)
            validate_expr_with_loop_depth(condition, body, loop_depth)
            validate_block_with_loop_depth(loop_body, body, loop_depth + 1)
        },
        CoreStmtValue::Break { origin } | CoreStmtValue::Continue { origin } => {
            validate_origin(origin, body.reference)
            if loop_depth <= 0 {
                panic("CoreHIR: loop control appears outside a loop")
            }
        },
        CoreStmtValue::Return { value: returned, origin } => {
            validate_origin(origin, body.reference)
            match returned {
                some(expr) => validate_expr_with_loop_depth(
                    expr, body, loop_depth),
                none => {}
            }
        }
    }
}

fn validate_block_with_loop_depth(
    value: CoreBlock, body: CoreBody, loop_depth: Int
) {
    validate_origin(value.origin, body.reference)
    for statement in value.statements {
        validate_statement(statement, body, loop_depth)
    }
    match value.tail {
        some(expr) => validate_expr_with_loop_depth(expr, body, loop_depth),
        none => {}
    }
}
fn validate_block(value: CoreBlock, body: CoreBody) {
    validate_block_with_loop_depth(value, body, 0)
}

pub fn make_core_body(
    reference: ExecutableRef, origin: OriginRef, type_count: Int,
    manifest: BinderManifest, slots: List<CoreSlot>,
    parameter_slots: List<SlotRef>, result_type: CoreTypeRef,
    body: CoreBlock
) -> CoreBody {
    if type_count <= 0 || !type_ref_valid(result_type, type_count) {
        panic("CoreHIR: body has no closed result type graph")
    }
    if !executable_ref_same(reference, binder_manifest_owner(manifest)) {
        panic("CoreHIR: body executable/manifest identity differs")
    }
    let binders = binder_manifest_entries(manifest)
    if binders.len() != slots.len() {
        panic("CoreHIR: binder/typed-slot census differs")
    }
    let mut index = 0
    while index < slots.len() {
        let slot = slots.get(index).unwrap()
        if !slot_ref_same(
                slot.reference, binder_entry_slot(binders.get(index).unwrap())) ||
           !type_ref_valid(slot.ty, type_count) {
            panic("CoreHIR: typed slot order/type is invalid")
        }
        let mut right_index = index + 1
        while right_index < slots.len() {
            if slot_ref_same(
                    slot.reference, slots.get(right_index).unwrap().reference) {
                panic("CoreHIR: body repeats a slot")
            }
            right_index = right_index + 1
        }
        index = index + 1
    }
    let mut parameter_index = 0
    while parameter_index < parameter_slots.len() {
        let parameter = parameter_slots.get(parameter_index).unwrap()
        require_slot(slots, parameter)
        let mut right_index = parameter_index + 1
        while right_index < parameter_slots.len() {
            if slot_ref_same(
                    parameter, parameter_slots.get(right_index).unwrap()) {
                panic("CoreHIR: body repeats a parameter slot")
            }
            right_index = right_index + 1
        }
        parameter_index = parameter_index + 1
    }
    let result = CoreBody {
        reference: reference, origin: origin, type_count: type_count,
        manifest: copy_manifest(manifest), slots: copy_core_slots(slots),
        parameter_slots: copy_slot_refs(parameter_slots),
        result_type: result_type, body: body
    }
    validate_core_body(result)
    result
}

pub fn validate_core_body(value: CoreBody) {
    validate_origin(value.origin, value.reference)
    if !executable_ref_same(
            value.reference, binder_manifest_owner(value.manifest)) {
        panic("CoreHIR: body manifest identity drifted")
    }
    validate_block(value.body, value)
}

pub fn core_body_reference(value: CoreBody) -> ExecutableRef { value.reference }
pub fn core_body_origin(value: CoreBody) -> OriginRef { value.origin }
pub fn core_body_type_count(value: CoreBody) -> Int { value.type_count }
pub fn core_body_manifest(value: CoreBody) -> BinderManifest {
    copy_manifest(value.manifest)
}
pub fn core_body_slots(value: CoreBody) -> List<CoreSlot> {
    copy_core_slots(value.slots)
}
pub fn core_body_parameter_slots(value: CoreBody) -> List<SlotRef> {
    copy_slot_refs(value.parameter_slots)
}
pub fn core_body_result_type(value: CoreBody) -> CoreTypeRef { value.result_type }
pub fn core_body_block(value: CoreBody) -> CoreBlock { value.body }
