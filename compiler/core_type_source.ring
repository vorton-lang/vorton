// Unique neutral transport from the checker's canonical Type graph to one
// module-local Core type fact.  It is consumed by Core assembly and legacy
// projection; neither consumer may rebuild the relation.

use types::{Type, types_equal}
use ir_identity::{
    CoreTypeRef, CoreTypeFactRef,
    make_core_type_ref, make_module_core_type_ref,
    core_type_ref_index, core_type_ref_module_key, core_type_ref_same,
    make_core_type_fact_ref,
    core_type_fact_module_key, core_type_fact_same,
    SymbolRef, PathRef, PathOwnerRef,
    NominalFieldRef, VariantRef, VariantFieldRef,
    HandledEffectRef, SystemEffectRef,
    handled_effect_ref_same, system_effect_ref_same,
    symbol_ref_same, symbol_ref_origin_module_key,
    symbol_ref_namespace_kind,
    namespace_kind_same, namespace_nominal, namespace_trait,
    path_ref_same, path_ref_owner,
    path_owner_ref_is_symbol, path_owner_ref_symbol,
    path_owner_ref_module_body, module_body_ref_origin_module_key,
    nominal_field_ref_same, nominal_field_ref_owner, nominal_field_ref_name,
    variant_ref_owner, variant_field_ref_same, variant_field_ref_variant,
    registered_nominal_ref_symbol
}
use ir_inventory::{
    ExecutableRef, executable_ref_same,
    EffectOperationRef, effect_operation_ref_effect,
    effect_operation_ref_source_index, effect_operation_ref_same
}
use effect_contract::{
    effect_param_ref_same,
    CoreEffectAtom, CoreEffectContract,
    make_core_fail_effect, make_core_mut_effect, make_core_unsafe_effect,
    make_core_handled_effect, make_core_system_effect,
    core_effect_atom_kind_tag, core_effect_atom_type,
    core_effect_atom_handled_ref, core_effect_atom_type_arguments,
    core_effect_atom_system_ref,
    make_core_effect_set, core_effect_set_atoms,
    make_core_effect_contract, core_effect_contract_exact,
    core_effect_contract_parameter, core_effect_contract_same,
    core_effect_contract_actual_satisfies_formal,
    copy_core_effect_contract
}
use resource_model::{
    FlowTypeSemanticSeed,
    flow_type_seed_scalar, flow_type_seed_ptr,
    flow_type_seed_unique, flow_type_seed_shareable,
    flow_type_seed_extern, flow_type_seed_parametric,
    flow_type_semantic_seed_tag,
    FlowCallContract, make_flow_call_contract, make_module_flow_call_contract,
    flow_call_contract_module_key,
    flow_call_contract_parameter_types,
    flow_call_contract_parameter_roles,
    flow_call_contract_result_type,
    flow_call_contract_result_role,
    flow_call_contract_result_origin
}
pub struct CoreTypeFactAllocator { module_key: Str, next_ordinal: Int }
pub fn new_core_type_fact_allocator(
    module_key: Str
) -> CoreTypeFactAllocator {
    if module_key == "" { panic("Core type source: empty recorder domain") }
    CoreTypeFactAllocator { module_key: module_key, next_ordinal: 0 }
}
pub fn reserve_core_type_fact_ref(
    mut allocator: CoreTypeFactAllocator
) -> CoreTypeFactRef {
    let result = make_core_type_fact_ref(
        allocator.module_key, allocator.next_ordinal)
    allocator.next_ordinal = allocator.next_ordinal + 1
    result
}

pub struct CoreTypeSourceFact {
    source_type: Type,
    type_fact: CoreTypeFactRef
}

pub fn make_core_type_source_fact(
    source_type: Type, type_fact: CoreTypeFactRef
) -> CoreTypeSourceFact {
    CoreTypeSourceFact { source_type: source_type, type_fact: type_fact }
}
pub fn core_type_source_type(value: CoreTypeSourceFact) -> Type {
    value.source_type
}
pub fn core_type_source_fact(value: CoreTypeSourceFact) -> CoreTypeFactRef {
    value.type_fact
}
pub fn core_type_source_same(
    left: CoreTypeSourceFact, right: CoreTypeSourceFact
) -> Bool {
    types_equal(left.source_type, right.source_type) &&
        core_type_fact_same(left.type_fact, right.type_fact)
}

// The handler evidence aggregate has no source spelling or source Type.  The
// checker records its one Core type fact beside the exact declaration-order
// operation signatures; Core assembly consumes this relation directly rather
// than inventing an opaque Ptr/record or replaying effect lookup by name.
pub struct CoreHandledEvidenceOperationTypeSource {
    operation: EffectOperationRef,
    signature_fact: CoreTypeFactRef
}

pub fn make_core_handled_evidence_operation_type_source(
    operation: EffectOperationRef, signature_fact: CoreTypeFactRef
) -> CoreHandledEvidenceOperationTypeSource {
    CoreHandledEvidenceOperationTypeSource {
        operation: operation, signature_fact: signature_fact
    }
}
pub fn core_handled_operation_source_operation(
    value: CoreHandledEvidenceOperationTypeSource
) -> EffectOperationRef { value.operation }
pub fn core_handled_operation_source_signature_fact(
    value: CoreHandledEvidenceOperationTypeSource
) -> CoreTypeFactRef { value.signature_fact }

fn copy_handled_operation_sources(
    values: List<CoreHandledEvidenceOperationTypeSource>
) -> List<CoreHandledEvidenceOperationTypeSource> {
    values.map(fn(value) {
        make_core_handled_evidence_operation_type_source(
            value.operation, value.signature_fact)
    })
}

pub struct CoreHandledEvidenceTypeSource {
    requirement: HandledEffectRef,
    aggregate_fact: CoreTypeFactRef,
    operations: List<CoreHandledEvidenceOperationTypeSource>
}

pub fn make_core_handled_evidence_type_source(
    requirement: HandledEffectRef, aggregate_fact: CoreTypeFactRef,
    operations: List<CoreHandledEvidenceOperationTypeSource>
) -> CoreHandledEvidenceTypeSource {
    // An imported handled effect receives one recorder-local aggregate
    // prototype in every consumer module. The requirement/operation identities
    // remain anchored at the exporter; only Core type-fact ordinals are local.
    let module_key = core_type_fact_module_key(aggregate_fact)
    let mut index = 0
    while index < operations.len() {
        let operation = operations.get(index).unwrap()
        if !handled_effect_ref_same(
                effect_operation_ref_effect(operation.operation),
                requirement) ||
           effect_operation_ref_source_index(operation.operation) != index ||
           core_type_fact_module_key(operation.signature_fact) != module_key ||
           core_type_fact_same(operation.signature_fact, aggregate_fact) {
            panic("Core type source: handled operation contract differs")
        }
        let mut right = index + 1
        while right < operations.len() {
            if effect_operation_ref_same(
                    operation.operation,
                    operations.get(right).unwrap().operation) {
                panic("Core type source: handled operation repeats")
            }
            right = right + 1
        }
        index = index + 1
    }
    CoreHandledEvidenceTypeSource {
        requirement: requirement, aggregate_fact: aggregate_fact,
        operations: copy_handled_operation_sources(operations)
    }
}
pub fn core_handled_evidence_source_requirement(
    value: CoreHandledEvidenceTypeSource
) -> HandledEffectRef { value.requirement }
pub fn core_handled_evidence_source_aggregate_fact(
    value: CoreHandledEvidenceTypeSource
) -> CoreTypeFactRef { value.aggregate_fact }
pub fn core_handled_evidence_source_operations(
    value: CoreHandledEvidenceTypeSource
) -> List<CoreHandledEvidenceOperationTypeSource> {
    copy_handled_operation_sources(value.operations)
}
pub fn core_handled_evidence_type_source_same(
    left: CoreHandledEvidenceTypeSource,
    right: CoreHandledEvidenceTypeSource
) -> Bool {
    if !handled_effect_ref_same(left.requirement, right.requirement) ||
       !core_type_fact_same(left.aggregate_fact, right.aggregate_fact) ||
       left.operations.len() != right.operations.len() {
        return false
    }
    let mut index = 0
    while index < left.operations.len() {
        let a = left.operations.get(index).unwrap()
        let b = right.operations.get(index).unwrap()
        if !effect_operation_ref_same(a.operation, b.operation) ||
           !core_type_fact_same(a.signature_fact, b.signature_fact) {
            return false
        }
        index = index + 1
    }
    true
}

// ============================================================
// Core-frozen exact type graph shared unchanged with Flow
// ============================================================

fn core_type_path_module_key(value: PathRef) -> Str {
    let owner = path_ref_owner(value)
    if path_owner_ref_is_symbol(owner) {
        symbol_ref_origin_module_key(path_owner_ref_symbol(owner))
    } else {
        module_body_ref_origin_module_key(path_owner_ref_module_body(owner))
    }
}

pub const FLOW_TYPE_INT: Int = 0
pub const FLOW_TYPE_FLOAT: Int = 1
pub const FLOW_TYPE_STR: Int = 2
pub const FLOW_TYPE_BOOL: Int = 3
pub const FLOW_TYPE_UNIT: Int = 4
pub const FLOW_TYPE_NEVER: Int = 5
pub const FLOW_TYPE_STRUCT: Int = 6
pub const FLOW_TYPE_ENUM: Int = 7
pub const FLOW_TYPE_TUPLE: Int = 8
pub const FLOW_TYPE_RECORD: Int = 9
pub const FLOW_TYPE_CALLABLE: Int = 10
pub const FLOW_TYPE_PTR: Int = 11
pub const FLOW_TYPE_PARAMETER: Int = 12
pub const FLOW_TYPE_EXTERN: Int = 13
const FLOW_TYPE_KIND_COUNT: Int = 14

pub struct FlowTypeKind { tag: Int }

fn flow_type_kind_from_tag(tag: Int) -> FlowTypeKind {
    if tag < FLOW_TYPE_INT || tag >= FLOW_TYPE_KIND_COUNT {
        panic("FlowIR: unknown type kind crossed CoreHIR boundary")
    }
    FlowTypeKind { tag: tag }
}

pub fn flow_type_kind_tag(value: FlowTypeKind) -> Int {
    flow_type_kind_from_tag(value.tag).tag
}

pub fn flow_type_kind_int() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_INT) }
pub fn flow_type_kind_float() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_FLOAT) }
pub fn flow_type_kind_str() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_STR) }
pub fn flow_type_kind_bool() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_BOOL) }
pub fn flow_type_kind_unit() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_UNIT) }
pub fn flow_type_kind_never() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_NEVER) }
pub fn flow_type_kind_struct() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_STRUCT) }
pub fn flow_type_kind_enum() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_ENUM) }
pub fn flow_type_kind_tuple() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_TUPLE) }
pub fn flow_type_kind_record() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_RECORD) }
pub fn flow_type_kind_callable() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_CALLABLE) }
pub fn flow_type_kind_ptr() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_PTR) }
pub fn flow_type_kind_parameter() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_PARAMETER) }
pub fn flow_type_kind_extern() -> FlowTypeKind { flow_type_kind_from_tag(FLOW_TYPE_EXTERN) }

pub fn flow_type_kind_same(left: FlowTypeKind, right: FlowTypeKind) -> Bool {
    flow_type_kind_tag(left) == flow_type_kind_tag(right)
}

pub struct FlowDropContract { provider: ExecutableRef }

pub fn make_flow_drop_contract(provider: ExecutableRef) -> FlowDropContract {
    FlowDropContract { provider: provider }
}
pub fn flow_drop_contract_provider(value: FlowDropContract) -> ExecutableRef {
    value.provider
}

pub struct FlowGenericParamFact {
    owner: SymbolRef,
    index: Int,
    arity: Int,
    bounds: List<SymbolRef>
}

fn copy_symbols(values: List<SymbolRef>) -> List<SymbolRef> {
    let mut result: List<SymbolRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_flow_generic_param_fact(
    owner: SymbolRef, index: Int, arity: Int, bounds: List<SymbolRef>
) -> FlowGenericParamFact {
    if arity <= 0 || index < 0 || index >= arity {
        panic("FlowIR: generic parameter index/arity is invalid")
    }
    let mut left_index = 0
    while left_index < bounds.len() {
        let left = bounds.get(left_index).unwrap()
        if !namespace_kind_same(
                symbol_ref_namespace_kind(left), namespace_trait()) {
            panic("FlowIR: generic bound is not an exact trait symbol")
        }
        let mut right_index = left_index + 1
        while right_index < bounds.len() {
            if symbol_ref_same(left, bounds.get(right_index).unwrap()) {
                panic("FlowIR: generic parameter repeats a bound")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    FlowGenericParamFact {
        owner: owner, index: index, arity: arity,
        bounds: copy_symbols(bounds)
    }
}
pub fn flow_generic_param_owner(value: FlowGenericParamFact) -> SymbolRef {
    value.owner
}
pub fn flow_generic_param_index(value: FlowGenericParamFact) -> Int { value.index }
pub fn flow_generic_param_arity(value: FlowGenericParamFact) -> Int { value.arity }
pub fn flow_generic_param_bounds(value: FlowGenericParamFact) -> List<SymbolRef> {
    copy_symbols(value.bounds)
}
fn copy_generic_param_fact(value: FlowGenericParamFact) -> FlowGenericParamFact {
    FlowGenericParamFact {
        owner: value.owner, index: value.index, arity: value.arity,
        bounds: copy_symbols(value.bounds)
    }
}
pub fn flow_generic_param_fact_same(
    left: FlowGenericParamFact, right: FlowGenericParamFact
) -> Bool {
    if !symbol_ref_same(left.owner, right.owner) ||
       left.index != right.index || left.arity != right.arity ||
       left.bounds.len() != right.bounds.len() {
        return false
    }
    let mut index = 0
    while index < left.bounds.len() {
        if !symbol_ref_same(
                left.bounds.get(index).unwrap(),
                right.bounds.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}
pub fn flow_generic_param_identity_same(
    left: FlowGenericParamFact, right: FlowGenericParamFact
) -> Bool {
    symbol_ref_same(left.owner, right.owner) &&
        left.index == right.index && left.arity == right.arity
}

pub struct FlowTypeSubstitution {
    parameter: FlowGenericParamFact,
    replacement: CoreTypeRef
}

pub fn make_flow_type_substitution(
    parameter: FlowGenericParamFact, replacement: CoreTypeRef
) -> FlowTypeSubstitution {
    if core_type_ref_index(replacement) < 0 {
        panic("CoreHIR: generic substitution has invalid replacement")
    }
    FlowTypeSubstitution {
        parameter: copy_generic_param_fact(parameter),
        replacement: replacement
    }
}
pub fn flow_type_substitution_parameter(
    value: FlowTypeSubstitution
) -> FlowGenericParamFact { copy_generic_param_fact(value.parameter) }
pub fn flow_type_substitution_replacement(
    value: FlowTypeSubstitution
) -> CoreTypeRef { value.replacement }
pub fn copy_flow_type_substitutions(
    values: List<FlowTypeSubstitution>
) -> List<FlowTypeSubstitution> {
    values.map(fn(value) {
        make_flow_type_substitution(value.parameter, value.replacement)
    })
}

enum FlowFieldIdentityValue {
    NominalFieldIdentityValue(NominalFieldRef),
    VariantFieldIdentityValue(VariantFieldRef),
    PathFieldIdentityValue(PathRef)
}

pub struct FlowFieldIdentity { value: FlowFieldIdentityValue }

pub fn make_nominal_flow_field_identity(
    value: NominalFieldRef
) -> FlowFieldIdentity {
    FlowFieldIdentity { value: FlowFieldIdentityValue::NominalFieldIdentityValue(value) }
}
pub fn make_path_flow_field_identity(value: PathRef) -> FlowFieldIdentity {
    FlowFieldIdentity { value: FlowFieldIdentityValue::PathFieldIdentityValue(value) }
}
pub fn make_variant_flow_field_identity(
    value: VariantFieldRef
) -> FlowFieldIdentity {
    FlowFieldIdentity {
        value: FlowFieldIdentityValue::VariantFieldIdentityValue(value)
    }
}
pub fn flow_field_identity_is_nominal(value: FlowFieldIdentity) -> Bool {
    match value.value {
        FlowFieldIdentityValue::NominalFieldIdentityValue(_) => true,
        FlowFieldIdentityValue::VariantFieldIdentityValue(_) => false,
        FlowFieldIdentityValue::PathFieldIdentityValue(_) => false
    }
}
pub fn flow_field_identity_is_variant(value: FlowFieldIdentity) -> Bool {
    match value.value {
        FlowFieldIdentityValue::VariantFieldIdentityValue(_) => true,
        _ => false
    }
}
pub fn flow_field_identity_variant(value: FlowFieldIdentity) -> VariantFieldRef {
    match value.value {
        FlowFieldIdentityValue::VariantFieldIdentityValue(field) => field,
        _ => panic("FlowIR: non-variant field has no VariantFieldRef")
    }
}
pub fn flow_field_identity_nominal(value: FlowFieldIdentity) -> NominalFieldRef {
    match value.value {
        FlowFieldIdentityValue::NominalFieldIdentityValue(field) => field,
        _ => panic("FlowIR: path field has no NominalFieldRef")
    }
}
pub fn flow_field_identity_path(value: FlowFieldIdentity) -> PathRef {
    match value.value {
        FlowFieldIdentityValue::PathFieldIdentityValue(path) => path,
        _ => panic("FlowIR: nominal field has no PathRef")
    }
}
pub fn flow_field_identity_same(
    left: FlowFieldIdentity, right: FlowFieldIdentity
) -> Bool {
    match (left.value, right.value) {
        (FlowFieldIdentityValue::NominalFieldIdentityValue(a),
         FlowFieldIdentityValue::NominalFieldIdentityValue(b)) =>
            nominal_field_ref_same(a, b),
        (FlowFieldIdentityValue::VariantFieldIdentityValue(a),
         FlowFieldIdentityValue::VariantFieldIdentityValue(b)) =>
            variant_field_ref_same(a, b),
        (FlowFieldIdentityValue::PathFieldIdentityValue(a),
         FlowFieldIdentityValue::PathFieldIdentityValue(b)) => path_ref_same(a, b),
        _ => false
    }
}

pub struct FlowNominalFieldFact {
    identity: FlowFieldIdentity,
    ty: CoreTypeRef,
    record_name: Str?
}

pub fn make_flow_nominal_field_fact(
    identity: FlowFieldIdentity, ty: CoreTypeRef
) -> FlowNominalFieldFact {
    FlowNominalFieldFact { identity: identity, ty: ty, record_name: none }
}
pub fn make_flow_record_field_fact(
    identity: FlowFieldIdentity, name: Str, ty: CoreTypeRef
) -> FlowNominalFieldFact {
    if name == "" || flow_field_identity_is_nominal(identity) ||
       flow_field_identity_is_variant(identity) {
        panic("FlowIR: record field fact is not structural/named")
    }
    FlowNominalFieldFact {
        identity: identity, ty: ty, record_name: some(name)
    }
}
pub fn flow_nominal_field_identity(
    value: FlowNominalFieldFact
) -> FlowFieldIdentity { value.identity }
pub fn flow_nominal_field_type(value: FlowNominalFieldFact) -> CoreTypeRef {
    value.ty
}
pub fn flow_nominal_field_record_name(value: FlowNominalFieldFact) -> Str {
    match value.record_name {
        some(name) => name,
        none => panic("FlowIR: non-record field has no structural name")
    }
}
fn optional_record_names_same(left: Str?, right: Str?) -> Bool {
    match (left, right) {
        (some(a), some(b)) => a == b,
        (none, none) => true,
        _ => false
    }
}
fn copy_nominal_fields(values: List<FlowNominalFieldFact>) -> List<FlowNominalFieldFact> {
    let mut result: List<FlowNominalFieldFact> = []
    for value in values { result.push(value) }
    result
}

fn nominal_field_types(
    values: List<FlowNominalFieldFact>
) -> List<CoreTypeRef> {
    let mut result: List<CoreTypeRef> = []
    for value in values { result.push(value.ty) }
    result
}

pub struct FlowTypeNode {
    reference: CoreTypeRef,
    kind: FlowTypeKind,
    nominal: SymbolRef?,
    children: List<CoreTypeRef>,
    generic_arguments: List<CoreTypeRef>,
    nominal_fields: List<FlowNominalFieldFact>,
    parameter_count: Int,
    callable_effects: CoreEffectContract?,
    generic_param: FlowGenericParamFact?,
    semantic_seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?,
    resource_storage_parameter_ordinals: List<Int>
}

fn copy_type_refs(values: List<CoreTypeRef>) -> List<CoreTypeRef> {
    let mut result: List<CoreTypeRef> = []
    for value in values { result.push(value) }
    result
}

fn copy_ints(values: List<Int>) -> List<Int> {
    let mut result: List<Int> = []
    for value in values { result.push(value) }
    result
}

fn make_atomic_flow_type_node(
    reference: CoreTypeRef, kind: FlowTypeKind
) -> FlowTypeNode {
    let tag = flow_type_kind_tag(kind)
    if tag < FLOW_TYPE_INT || tag > FLOW_TYPE_NEVER {
        panic("FlowIR: non-atomic type used atomic constructor")
    }
    let seed = if tag == FLOW_TYPE_STR {
        flow_type_seed_shareable()
    } else {
        flow_type_seed_scalar()
    }
    FlowTypeNode {
        reference: reference, kind: kind, nominal: none, children: [],
        generic_arguments: [], nominal_fields: [], parameter_count: 0,
        callable_effects: none,
        generic_param: none, semantic_seed: seed,
        drop_contract: none,
        resource_storage_parameter_ordinals: []
    }
}

pub fn make_flow_int_type_node(reference: CoreTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_int())
}
pub fn make_flow_float_type_node(reference: CoreTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_float())
}
pub fn make_flow_str_type_node(reference: CoreTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_str())
}
pub fn make_flow_bool_type_node(reference: CoreTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_bool())
}
pub fn make_flow_unit_type_node(reference: CoreTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_unit())
}
pub fn make_flow_never_type_node(reference: CoreTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_never())
}

fn make_nominal_flow_type_node(
    reference: CoreTypeRef, kind: FlowTypeKind, nominal: SymbolRef,
    arguments: List<CoreTypeRef>, field_values: List<FlowNominalFieldFact>,
    semantic_seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?,
    resource_storage_parameter_ordinals: List<Int>
) -> FlowTypeNode {
    if !flow_type_kind_same(kind, flow_type_kind_struct()) &&
       !flow_type_kind_same(kind, flow_type_kind_enum()) {
        panic("FlowIR: invalid nominal type kind")
    }
    if !namespace_kind_same(
            symbol_ref_namespace_kind(nominal), namespace_nominal()) {
        panic("FlowIR: nominal type has non-nominal symbol")
    }
    FlowTypeNode {
        reference: reference, kind: kind, nominal: some(nominal),
        children: nominal_field_types(field_values),
        generic_arguments: copy_type_refs(arguments),
        nominal_fields: copy_nominal_fields(field_values), parameter_count: 0,
        callable_effects: none,
        generic_param: none,
        semantic_seed: semantic_seed,
        drop_contract: drop_contract,
        resource_storage_parameter_ordinals:
            copy_ints(resource_storage_parameter_ordinals)
    }
}

pub fn make_flow_struct_type_node(
    reference: CoreTypeRef, nominal: SymbolRef,
    arguments: List<CoreTypeRef>, field_values: List<FlowNominalFieldFact>,
    semantic_seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?,
    resource_storage_parameter_ordinals: List<Int>
) -> FlowTypeNode {
    make_nominal_flow_type_node(
        reference, flow_type_kind_struct(), nominal, arguments, field_values,
        semantic_seed, drop_contract, resource_storage_parameter_ordinals)
}

pub fn make_flow_enum_type_node(
    reference: CoreTypeRef, nominal: SymbolRef,
    arguments: List<CoreTypeRef>, field_values: List<FlowNominalFieldFact>,
    semantic_seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?,
    resource_storage_parameter_ordinals: List<Int>
) -> FlowTypeNode {
    make_nominal_flow_type_node(
        reference, flow_type_kind_enum(), nominal, arguments, field_values,
        semantic_seed, drop_contract, resource_storage_parameter_ordinals)
}

pub fn make_flow_extern_type_node(
    reference: CoreTypeRef, nominal: SymbolRef,
    arguments: List<CoreTypeRef>
) -> FlowTypeNode {
    if !namespace_kind_same(
            symbol_ref_namespace_kind(nominal), namespace_nominal()) {
        panic("FlowIR: extern type has non-nominal symbol")
    }
    FlowTypeNode {
        reference: reference, kind: flow_type_kind_extern(),
        nominal: some(nominal), children: [],
        generic_arguments: copy_type_refs(arguments), nominal_fields: [],
        parameter_count: 0, generic_param: none,
        callable_effects: none,
        semantic_seed: flow_type_seed_extern(), drop_contract: none,
        resource_storage_parameter_ordinals: []
    }
}

fn make_structural_flow_type_node(
    reference: CoreTypeRef, kind: FlowTypeKind,
    children: List<CoreTypeRef>, semantic_seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?
) -> FlowTypeNode {
    if !flow_type_kind_same(kind, flow_type_kind_tuple()) &&
       !flow_type_kind_same(kind, flow_type_kind_record()) {
        panic("FlowIR: invalid structural type kind")
    }
    FlowTypeNode {
        reference: reference, kind: kind, nominal: none,
        children: copy_type_refs(children),
        generic_arguments: [], nominal_fields: [], parameter_count: 0,
        callable_effects: none,
        generic_param: none,
        semantic_seed: semantic_seed,
        drop_contract: drop_contract,
        resource_storage_parameter_ordinals: []
    }
}

pub fn make_flow_tuple_type_node(
    reference: CoreTypeRef, elements: List<CoreTypeRef>,
    semantic_seed: FlowTypeSemanticSeed, drop_contract: FlowDropContract?
) -> FlowTypeNode {
    make_structural_flow_type_node(
        reference, flow_type_kind_tuple(), elements,
        semantic_seed, drop_contract)
}

pub fn make_flow_record_type_node(
    reference: CoreTypeRef, field_values: List<FlowNominalFieldFact>,
    semantic_seed: FlowTypeSemanticSeed, drop_contract: FlowDropContract?
) -> FlowTypeNode {
    let mut node = make_structural_flow_type_node(
        reference, flow_type_kind_record(),
        nominal_field_types(field_values),
        semantic_seed, drop_contract)
    node.nominal_fields = copy_nominal_fields(field_values)
    node
}

pub fn make_flow_callable_type_node(
    reference: CoreTypeRef, parameters: List<CoreTypeRef>,
    result: CoreTypeRef, effects: CoreEffectContract
) -> FlowTypeNode {
    let mut children = copy_type_refs(parameters)
    children.push(result)
    FlowTypeNode {
        reference: reference, kind: flow_type_kind_callable(), nominal: none,
        children: children, parameter_count: parameters.len(),
        generic_arguments: [], nominal_fields: [], generic_param: none,
        callable_effects: some(copy_core_effect_contract(effects)),
        semantic_seed: flow_type_seed_shareable(), drop_contract: none,
        resource_storage_parameter_ordinals: []
    }
}

pub fn make_flow_ptr_type_node(
    reference: CoreTypeRef, pointee: CoreTypeRef
) -> FlowTypeNode {
    FlowTypeNode {
        reference: reference, kind: flow_type_kind_ptr(), nominal: none,
        children: [pointee], generic_arguments: [], nominal_fields: [],
        parameter_count: 0, generic_param: none,
        callable_effects: none,
        semantic_seed: flow_type_seed_ptr(), drop_contract: none,
        resource_storage_parameter_ordinals: []
    }
}

pub fn make_flow_parameter_type_node(
    reference: CoreTypeRef, generic_param: FlowGenericParamFact
) -> FlowTypeNode {
    FlowTypeNode {
        reference: reference, kind: flow_type_kind_parameter(), nominal: none,
        children: [], generic_arguments: [], nominal_fields: [],
        parameter_count: 0,
        callable_effects: none,
        generic_param: some(copy_generic_param_fact(generic_param)),
        semantic_seed: flow_type_seed_parametric(), drop_contract: none,
        resource_storage_parameter_ordinals: []
    }
}

pub fn flow_type_node_reference(value: FlowTypeNode) -> CoreTypeRef { value.reference }
pub fn flow_type_node_kind(value: FlowTypeNode) -> FlowTypeKind { value.kind }
pub fn flow_type_node_children(value: FlowTypeNode) -> List<CoreTypeRef> {
    copy_type_refs(value.children)
}
pub fn flow_type_node_generic_arguments(value: FlowTypeNode) -> List<CoreTypeRef> {
    copy_type_refs(value.generic_arguments)
}
pub fn flow_type_node_nominal_fields(
    value: FlowTypeNode
) -> List<FlowNominalFieldFact> { copy_nominal_fields(value.nominal_fields) }
pub fn flow_type_node_nominal(value: FlowTypeNode) -> SymbolRef {
    match value.nominal {
        some(symbol) => symbol,
        none => panic("FlowIR: non-nominal type has no nominal symbol")
    }
}
pub fn flow_type_node_parameter_count(value: FlowTypeNode) -> Int {
    if !flow_type_kind_same(value.kind, flow_type_kind_callable()) {
        panic("FlowIR: non-callable type has no parameter count")
    }
    value.parameter_count
}
pub fn flow_type_node_callable_effects(
    value: FlowTypeNode
) -> CoreEffectContract {
    if !flow_type_kind_same(value.kind, flow_type_kind_callable()) {
        panic("FlowIR: non-callable type has no effect contract")
    }
    match value.callable_effects {
        some(effects) => copy_core_effect_contract(effects),
        none => panic("FlowIR: callable type has no effect contract")
    }
}
pub fn flow_type_node_parameter_index(value: FlowTypeNode) -> Int {
    if !flow_type_kind_same(value.kind, flow_type_kind_parameter()) {
        panic("FlowIR: non-parameter type has no parameter index")
    }
    match value.generic_param {
        some(fact) => fact.index,
        none => panic("FlowIR: parameter type has no generic fact")
    }
}
pub fn flow_type_node_generic_param(value: FlowTypeNode) -> FlowGenericParamFact {
    match value.generic_param {
        some(fact) => copy_generic_param_fact(fact),
        none => panic("FlowIR: non-parameter type has no generic fact")
    }
}
pub fn flow_type_node_semantic_seed(value: FlowTypeNode) -> FlowTypeSemanticSeed {
    value.semantic_seed
}
pub fn flow_type_node_drop_contract(value: FlowTypeNode) -> FlowDropContract? {
    value.drop_contract
}
pub fn flow_type_node_resource_storage_parameter_ordinals(
    value: FlowTypeNode
) -> List<Int> {
    copy_ints(value.resource_storage_parameter_ordinals)
}

fn flow_satisfaction_field_name(
    field: FlowNominalFieldFact, kind_tag: Int
) -> Str? {
    if kind_tag == FLOW_TYPE_STRUCT &&
       flow_field_identity_is_nominal(field.identity) {
        return some(nominal_field_ref_name(
            flow_field_identity_nominal(field.identity)))
    }
    if kind_tag == FLOW_TYPE_RECORD &&
       !flow_field_identity_is_nominal(field.identity) &&
       !flow_field_identity_is_variant(field.identity) {
        return some(flow_nominal_field_record_name(field))
    }
    none
}

fn flow_satisfaction_type_node(
    nodes: List<FlowTypeNode>, reference: CoreTypeRef
) -> FlowTypeNode {
    for node in nodes {
        if core_type_ref_same(node.reference, reference) { return node }
    }
    panic("CoreHIR: type compatibility references an absent type")
}

fn flow_satisfaction_pair_active(
    actual: CoreTypeRef, formal: CoreTypeRef,
    actual_path: List<CoreTypeRef>, formal_path: List<CoreTypeRef>
) -> Bool {
    if actual_path.len() != formal_path.len() {
        panic("CoreHIR: type compatibility path is malformed")
    }
    let mut index = 0
    while index < actual_path.len() {
        if core_type_ref_same(actual_path.get(index).unwrap(), actual) &&
           core_type_ref_same(formal_path.get(index).unwrap(), formal) {
            return true
        }
        index = index + 1
    }
    false
}

fn flow_type_actual_satisfies_formal_inner(
    nodes: List<FlowTypeNode>, actual: FlowTypeNode, formal: FlowTypeNode,
    mut actual_path: List<CoreTypeRef>, mut formal_path: List<CoreTypeRef>
) -> Bool {
    if core_type_ref_same(actual.reference, formal.reference) { return true }
    let formal_kind = flow_type_kind_tag(formal.kind)
    let actual_kind = flow_type_kind_tag(actual.kind)

    if formal_kind == FLOW_TYPE_CALLABLE &&
       actual_kind == FLOW_TYPE_CALLABLE {
        if actual.parameter_count != formal.parameter_count ||
           actual.children.len() != formal.children.len() ||
           !core_effect_contract_actual_satisfies_formal(
                actual.callable_effects.unwrap(),
                formal.callable_effects.unwrap()) {
            return false
        }
        let mut index = 0
        while index < actual.children.len() {
            if !core_type_ref_same(
                    actual.children.get(index).unwrap(),
                    formal.children.get(index).unwrap()) {
                return false
            }
            index = index + 1
        }
        return true
    }

    if formal_kind != FLOW_TYPE_RECORD ||
       (actual_kind != FLOW_TYPE_STRUCT && actual_kind != FLOW_TYPE_RECORD) {
        return false
    }
    if flow_satisfaction_pair_active(
            actual.reference, formal.reference, actual_path, formal_path) {
        return true
    }

    actual_path.push(actual.reference)
    formal_path.push(formal.reference)
    let mut satisfied = true
    for required in formal.nominal_fields {
        let required_name = flow_nominal_field_record_name(required)
        let required_type = flow_satisfaction_type_node(nodes, required.ty)
        let mut found = false
        for candidate in actual.nominal_fields {
            match flow_satisfaction_field_name(candidate, actual_kind) {
                some(name) => if name == required_name &&
                        flow_type_actual_satisfies_formal_inner(
                            nodes,
                            flow_satisfaction_type_node(nodes, candidate.ty),
                            required_type, actual_path, formal_path) {
                    found = true
                },
                none => {}
            }
        }
        if !found { satisfied = false }
    }
    let _ = actual_path.pop()
    let _ = formal_path.pop()
    satisfied
}

// The sole directional compatibility relation.  Record rows are already
// frozen to required-field logical contracts.  Callable parameter/result
// references stay exact; only their formal effect contract may admit the one
// explicit instantiation above.  This is not function variance or general
// function subtyping.  Satisfaction never creates a value/view or changes the
// actual slot's physical type.
pub fn flow_type_actual_satisfies_formal(
    nodes: List<FlowTypeNode>, actual: FlowTypeNode, formal: FlowTypeNode
) -> Bool {
    flow_type_actual_satisfies_formal_inner(nodes, actual, formal, [], [])
}

fn substituted_parameter_replacement(
    substitutions: List<FlowTypeSubstitution>, parameter: FlowGenericParamFact
) -> CoreTypeRef? {
    let mut found: CoreTypeRef? = none
    for substitution in substitutions {
        if flow_generic_param_identity_same(
                substitution.parameter, parameter) {
            if found.is_some() {
                panic("CoreHIR: generic call repeats a type substitution")
            }
            found = some(substitution.replacement)
        }
    }
    found
}

fn substituted_effect_atom_matches(
    nodes: List<FlowTypeNode>, actual: CoreEffectAtom,
    formal: CoreEffectAtom, substitutions: List<FlowTypeSubstitution>,
    actual_path: List<CoreTypeRef>, formal_path: List<CoreTypeRef>
) -> Bool {
    let kind = core_effect_atom_kind_tag(formal)
    if core_effect_atom_kind_tag(actual) != kind { return false }
    if kind == 0 || kind == 1 {
        return flow_type_actual_satisfies_substituted_formal_inner(
            nodes,
            flow_satisfaction_type_node(nodes, core_effect_atom_type(actual)),
            flow_satisfaction_type_node(nodes, core_effect_atom_type(formal)),
            substitutions, actual_path, formal_path)
    }
    if kind == 2 { return true }
    if kind == 3 {
        if !handled_effect_ref_same(
                core_effect_atom_handled_ref(actual),
                core_effect_atom_handled_ref(formal)) ||
           core_effect_atom_type_arguments(actual).len() !=
                core_effect_atom_type_arguments(formal).len() {
            return false
        }
        let actual_args = core_effect_atom_type_arguments(actual)
        let formal_args = core_effect_atom_type_arguments(formal)
        let mut index = 0
        while index < actual_args.len() {
            if !flow_type_actual_satisfies_substituted_formal_inner(
                    nodes,
                    flow_satisfaction_type_node(
                        nodes, actual_args.get(index).unwrap()),
                    flow_satisfaction_type_node(
                        nodes, formal_args.get(index).unwrap()),
                    substitutions, actual_path, formal_path) {
                return false
            }
            index = index + 1
        }
        return true
    }
    system_effect_ref_same(
        core_effect_atom_system_ref(actual),
        core_effect_atom_system_ref(formal))
}

fn substituted_effect_contract_satisfies(
    nodes: List<FlowTypeNode>, actual: CoreEffectContract,
    formal: CoreEffectContract, substitutions: List<FlowTypeSubstitution>,
    actual_path: List<CoreTypeRef>, formal_path: List<CoreTypeRef>
) -> Bool {
    let actual_atoms = core_effect_set_atoms(core_effect_contract_exact(actual))
    let formal_atoms = core_effect_set_atoms(core_effect_contract_exact(formal))
    if core_effect_contract_parameter(formal).is_none() &&
       (core_effect_contract_parameter(actual).is_some() ||
        actual_atoms.len() != formal_atoms.len()) {
        return false
    }
    for required in formal_atoms {
        let mut matches = 0
        for candidate in actual_atoms {
            if substituted_effect_atom_matches(
                    nodes, candidate, required, substitutions,
                    actual_path, formal_path) {
                matches = matches + 1
            }
        }
        if matches != 1 { return false }
    }
    true
}

fn flow_type_actual_satisfies_substituted_formal_inner(
    nodes: List<FlowTypeNode>, actual: FlowTypeNode, formal: FlowTypeNode,
    substitutions: List<FlowTypeSubstitution>,
    mut actual_path: List<CoreTypeRef>, mut formal_path: List<CoreTypeRef>
) -> Bool {
    if core_type_ref_same(actual.reference, formal.reference) { return true }
    let actual_kind = flow_type_kind_tag(actual.kind)
    let formal_kind = flow_type_kind_tag(formal.kind)
    if formal_kind == FLOW_TYPE_PARAMETER {
        return match substituted_parameter_replacement(
                substitutions, formal.generic_param.unwrap()) {
            some(replacement) => core_type_ref_same(
                actual.reference, replacement),
            none => false
        }
    }
    if formal_kind == FLOW_TYPE_RECORD &&
       (actual_kind == FLOW_TYPE_STRUCT || actual_kind == FLOW_TYPE_RECORD) {
        if flow_satisfaction_pair_active(
                actual.reference, formal.reference,
                actual_path, formal_path) { return true }
        actual_path.push(actual.reference)
        formal_path.push(formal.reference)
        for required in formal.nominal_fields {
            let required_name = flow_nominal_field_record_name(required)
            let mut found = false
            for candidate in actual.nominal_fields {
                match flow_satisfaction_field_name(candidate, actual_kind) {
                    some(name) => if name == required_name &&
                            flow_type_actual_satisfies_substituted_formal_inner(
                                nodes,
                                flow_satisfaction_type_node(nodes, candidate.ty),
                                flow_satisfaction_type_node(nodes, required.ty),
                                substitutions, actual_path, formal_path) {
                        found = true
                    },
                    none => {}
                }
            }
            if !found { return false }
        }
        return true
    }
    if actual_kind != formal_kind { return false }
    if formal_kind == FLOW_TYPE_CALLABLE {
        if actual.parameter_count != formal.parameter_count ||
           actual.children.len() != formal.children.len() ||
           !substituted_effect_contract_satisfies(
                nodes,
                actual.callable_effects.unwrap(),
                formal.callable_effects.unwrap(), substitutions,
                actual_path, formal_path) {
            return false
        }
    } else if formal_kind == FLOW_TYPE_STRUCT ||
              formal_kind == FLOW_TYPE_ENUM ||
              formal_kind == FLOW_TYPE_EXTERN {
        if !symbol_ref_same(actual.nominal.unwrap(), formal.nominal.unwrap()) ||
           actual.generic_arguments.len() != formal.generic_arguments.len() {
            return false
        }
        let mut argument = 0
        while argument < actual.generic_arguments.len() {
            if !flow_type_actual_satisfies_substituted_formal_inner(
                    nodes,
                    flow_satisfaction_type_node(
                        nodes, actual.generic_arguments.get(argument).unwrap()),
                    flow_satisfaction_type_node(
                        nodes, formal.generic_arguments.get(argument).unwrap()),
                    substitutions, actual_path, formal_path) {
                return false
            }
            argument = argument + 1
        }
        return true
    } else if formal_kind != FLOW_TYPE_TUPLE &&
              formal_kind != FLOW_TYPE_PTR {
        return false
    }
    if actual.children.len() != formal.children.len() { return false }
    let mut child = 0
    while child < actual.children.len() {
        if !flow_type_actual_satisfies_substituted_formal_inner(
                nodes,
                flow_satisfaction_type_node(
                    nodes, actual.children.get(child).unwrap()),
                flow_satisfaction_type_node(
                    nodes, formal.children.get(child).unwrap()),
                substitutions, actual_path, formal_path) {
            return false
        }
        child = child + 1
    }
    true
}

// Direct generic calls carry an explicit declared-formal -> actual map.  This
// relation only checks that one already-frozen substitution against the
// declaration contract; it never infers a type argument or widens the normal
// actual-satisfies-formal relation.
pub fn flow_type_actual_satisfies_substituted_formal(
    nodes: List<FlowTypeNode>, actual: CoreTypeRef, formal: CoreTypeRef,
    substitutions: List<FlowTypeSubstitution>
) -> Bool {
    flow_type_actual_satisfies_substituted_formal_inner(
        nodes, flow_satisfaction_type_node(nodes, actual),
        flow_satisfaction_type_node(nodes, formal),
        substitutions, [], [])
}

fn copy_type_nodes(values: List<FlowTypeNode>) -> List<FlowTypeNode> {
    let mut result: List<FlowTypeNode> = []
    for value in values {
        result.push(FlowTypeNode {
            reference: value.reference, kind: value.kind,
            nominal: value.nominal, children: copy_type_refs(value.children),
            generic_arguments: copy_type_refs(value.generic_arguments),
            nominal_fields: copy_nominal_fields(value.nominal_fields),
            parameter_count: value.parameter_count,
            callable_effects: value.callable_effects.map(fn(effects) {
                copy_core_effect_contract(effects)
            }),
            generic_param: match value.generic_param {
                some(fact) => some(copy_generic_param_fact(fact)),
                none => none
            },
            semantic_seed: value.semantic_seed,
            drop_contract: value.drop_contract,
            resource_storage_parameter_ordinals:
                copy_ints(value.resource_storage_parameter_ordinals)
        })
    }
    result
}

// A module recorder owns only module-local type ordinals.  Project assembly
// uses these helpers to intern the structural graph once, then rewrites every
// local edge to the resulting project-global ordinal.  Keeping this logic in
// FlowIR avoids exposing the private node payload or making checker modules
// coordinate offsets/side maps.
fn mapped_type_index(mapping: List<Int?>, reference: CoreTypeRef) -> Int? {
    match mapping.get(core_type_ref_index(reference)) {
        some(value) => value,
        none => panic("FlowIR: module-local type reference is out of range")
    }
}

fn mapped_type_ref(mapping: List<Int>, reference: CoreTypeRef) -> CoreTypeRef {
    match mapping.get(core_type_ref_index(reference)) {
        some(index) => make_core_type_ref(index),
        none => panic("FlowIR: module-local type reference is out of range")
    }
}

fn all_type_refs_mapped(
    references: List<CoreTypeRef>, mapping: List<Int?>
) -> Bool {
    for reference in references {
        if mapped_type_index(mapping, reference).is_none() { return false }
    }
    true
}

fn flow_effect_type_refs(value: CoreEffectContract) -> List<CoreTypeRef> {
    let mut result: List<CoreTypeRef> = []
    for atom in core_effect_set_atoms(core_effect_contract_exact(value)) {
        let kind = core_effect_atom_kind_tag(atom)
        if kind == 0 || kind == 1 {
            result.push(core_effect_atom_type(atom))
        } else if kind == 3 {
            for ty in core_effect_atom_type_arguments(atom) { result.push(ty) }
        }
    }
    result
}

// Nominal field recursion is deliberately excluded from readiness: exact
// nominal identity plus mapped generic arguments reserves the canonical node,
// after which the full remapped payload is checked for equality.  Structural
// nodes require every child first, so the worklist is finite and deterministic.
pub fn flow_type_node_intern_ready(
    value: FlowTypeNode, mapping: List<Int?>
) -> Bool {
    let tag = flow_type_kind_tag(value.kind)
    if tag == FLOW_TYPE_STRUCT || tag == FLOW_TYPE_ENUM ||
       tag == FLOW_TYPE_EXTERN {
        return all_type_refs_mapped(value.generic_arguments, mapping)
    }
    if tag == FLOW_TYPE_TUPLE || tag == FLOW_TYPE_RECORD ||
       tag == FLOW_TYPE_CALLABLE || tag == FLOW_TYPE_PTR {
        if !all_type_refs_mapped(value.children, mapping) { return false }
        if tag == FLOW_TYPE_CALLABLE {
            return match value.callable_effects {
                some(effects) => all_type_refs_mapped(
                    flow_effect_type_refs(effects), mapping),
                none => false
            }
        }
        return true
    }
    true
}

fn mapped_reference_lists_same(
    left: List<CoreTypeRef>, left_mapping: List<Int?>,
    right: List<CoreTypeRef>, right_mapping: List<Int?>
) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        if mapped_type_index(
                left_mapping, left.get(index).unwrap()) !=
           mapped_type_index(
                right_mapping, right.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}

fn optional_symbols_same(left: SymbolRef?, right: SymbolRef?) -> Bool {
    match (left, right) {
        (some(a), some(b)) => symbol_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
}

fn mapped_effect_atom_same(
    left: CoreEffectAtom, left_mapping: List<Int?>,
    right: CoreEffectAtom, right_mapping: List<Int?>
) -> Bool {
    if core_effect_atom_kind_tag(left) != core_effect_atom_kind_tag(right) {
        return false
    }
    let kind = core_effect_atom_kind_tag(left)
    if kind == 0 || kind == 1 {
        return mapped_type_index(left_mapping, core_effect_atom_type(left)) ==
            mapped_type_index(right_mapping, core_effect_atom_type(right))
    }
    if kind == 2 { return true }
    if kind == 3 {
        return handled_effect_ref_same(
                core_effect_atom_handled_ref(left),
                core_effect_atom_handled_ref(right)) &&
            mapped_reference_lists_same(
                core_effect_atom_type_arguments(left), left_mapping,
                core_effect_atom_type_arguments(right), right_mapping)
    }
    system_effect_ref_same(
        core_effect_atom_system_ref(left), core_effect_atom_system_ref(right))
}

fn mapped_effect_contract_same(
    left: CoreEffectContract, left_mapping: List<Int?>,
    right: CoreEffectContract, right_mapping: List<Int?>
) -> Bool {
    let left_atoms = core_effect_set_atoms(core_effect_contract_exact(left))
    let right_atoms = core_effect_set_atoms(core_effect_contract_exact(right))
    if left_atoms.len() != right_atoms.len() { return false }
    for atom in left_atoms {
        let mut matches = 0
        for candidate in right_atoms {
            if mapped_effect_atom_same(
                    atom, left_mapping, candidate, right_mapping) {
                matches = matches + 1
            }
        }
        if matches != 1 { return false }
    }
    match (core_effect_contract_parameter(left),
           core_effect_contract_parameter(right)) {
        (some(a), some(b)) => effect_param_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
}

// Equality of the allocation key, not of the complete contract.  Complete
// equality is checked after all edges have been remapped.  A repeated exact
// nominal identity with a different field/resource contract is therefore a
// hard producer disagreement, never a second type.
pub fn flow_type_node_intern_key_same(
    left: FlowTypeNode, left_mapping: List<Int?>,
    right: FlowTypeNode, right_mapping: List<Int?>
) -> Bool {
    let tag = flow_type_kind_tag(left.kind)
    if tag != flow_type_kind_tag(right.kind) { return false }
    if tag >= FLOW_TYPE_INT && tag <= FLOW_TYPE_NEVER { return true }
    if tag == FLOW_TYPE_PARAMETER {
        return match (left.generic_param, right.generic_param) {
            (some(a), some(b)) => flow_generic_param_fact_same(a, b),
            _ => false
        }
    }
    if tag == FLOW_TYPE_STRUCT || tag == FLOW_TYPE_ENUM ||
       tag == FLOW_TYPE_EXTERN {
        return optional_symbols_same(left.nominal, right.nominal) &&
            mapped_reference_lists_same(
                left.generic_arguments, left_mapping,
                right.generic_arguments, right_mapping)
    }
    if tag == FLOW_TYPE_TUPLE || tag == FLOW_TYPE_CALLABLE ||
       tag == FLOW_TYPE_PTR {
        if left.parameter_count != right.parameter_count ||
           !mapped_reference_lists_same(
                left.children, left_mapping, right.children, right_mapping) {
            return false
        }
        if tag == FLOW_TYPE_CALLABLE {
            return match (left.callable_effects, right.callable_effects) {
                (some(a), some(b)) => mapped_effect_contract_same(
                        a, left_mapping, b, right_mapping),
                _ => false
            }
        }
        return true
    }
    if tag == FLOW_TYPE_RECORD {
        if left.nominal_fields.len() != right.nominal_fields.len() ||
           !mapped_reference_lists_same(
                left.children, left_mapping, right.children, right_mapping) {
            return false
        }
        let mut index = 0
        while index < left.nominal_fields.len() {
            if !flow_field_identity_same(
                    left.nominal_fields.get(index).unwrap().identity,
                    right.nominal_fields.get(index).unwrap().identity) ||
               !optional_record_names_same(
                    left.nominal_fields.get(index).unwrap().record_name,
                    right.nominal_fields.get(index).unwrap().record_name) {
                return false
            }
            index = index + 1
        }
        return true
    }
    false
}

fn remap_flow_effect_contract(
    value: CoreEffectContract, mapping: List<Int>
) -> CoreEffectContract {
    let atoms = core_effect_set_atoms(core_effect_contract_exact(value)).map(
        fn(atom) {
            let kind = core_effect_atom_kind_tag(atom)
            if kind == 0 {
                make_core_fail_effect(mapped_type_ref(
                    mapping, core_effect_atom_type(atom)))
            } else if kind == 1 {
                make_core_mut_effect(mapped_type_ref(
                    mapping, core_effect_atom_type(atom)))
            } else if kind == 2 {
                make_core_unsafe_effect()
            } else if kind == 3 {
                make_core_handled_effect(
                    core_effect_atom_handled_ref(atom),
                    core_effect_atom_type_arguments(atom).map(fn(ty) {
                        mapped_type_ref(mapping, ty)
                    }))
            } else if kind == 4 {
                make_core_system_effect(core_effect_atom_system_ref(atom))
            } else {
                panic("FlowIR: unknown exact effect atom")
            }
        })
    make_core_effect_contract(
        make_core_effect_set(atoms), core_effect_contract_parameter(value))
}

pub fn remap_flow_type_node(
    value: FlowTypeNode, project_index: Int, mapping: List<Int>
) -> FlowTypeNode {
    let mut remapped_fields: List<FlowNominalFieldFact> = []
    for field in value.nominal_fields {
        remapped_fields.push(match field.record_name {
            some(name) => make_flow_record_field_fact(
                field.identity, name, mapped_type_ref(mapping, field.ty)),
            none => make_flow_nominal_field_fact(
                field.identity, mapped_type_ref(mapping, field.ty))
        })
    }
    FlowTypeNode {
        reference: make_core_type_ref(project_index), kind: value.kind,
        nominal: value.nominal,
        children: value.children.map(fn(reference) {
            mapped_type_ref(mapping, reference)
        }),
        generic_arguments: value.generic_arguments.map(fn(reference) {
            mapped_type_ref(mapping, reference)
        }),
        nominal_fields: remapped_fields, parameter_count: value.parameter_count,
        callable_effects: value.callable_effects.map(fn(effects) {
            remap_flow_effect_contract(effects, mapping)
        }),
        generic_param: match value.generic_param {
            some(parameter) => some(copy_generic_param_fact(parameter)),
            none => none
        },
        semantic_seed: value.semantic_seed,
        drop_contract: value.drop_contract,
        resource_storage_parameter_ordinals:
            copy_ints(value.resource_storage_parameter_ordinals)
    }
}

fn optional_drop_contracts_same(
    left: FlowDropContract?, right: FlowDropContract?
) -> Bool {
    match (left, right) {
        (some(a), some(b)) => executable_ref_same(a.provider, b.provider),
        (none, none) => true,
        _ => false
    }
}

fn optional_flow_effect_contracts_same(
    left: CoreEffectContract?, right: CoreEffectContract?
) -> Bool {
    match (left, right) {
        (some(a), some(b)) => core_effect_contract_same(a, b),
        (none, none) => true,
        _ => false
    }
}

pub fn flow_type_node_contract_same(
    left: FlowTypeNode, right: FlowTypeNode
) -> Bool {
    if !flow_type_kind_same(left.kind, right.kind) ||
       !optional_symbols_same(left.nominal, right.nominal) ||
       left.parameter_count != right.parameter_count ||
       !optional_flow_effect_contracts_same(
            left.callable_effects, right.callable_effects) ||
       flow_type_semantic_seed_tag(left.semantic_seed) !=
            flow_type_semantic_seed_tag(right.semantic_seed) ||
       !optional_drop_contracts_same(left.drop_contract, right.drop_contract) ||
       left.children.len() != right.children.len() ||
       left.generic_arguments.len() != right.generic_arguments.len() ||
       left.nominal_fields.len() != right.nominal_fields.len() ||
       left.resource_storage_parameter_ordinals.len() !=
            right.resource_storage_parameter_ordinals.len() {
        return false
    }
    let mut index = 0
    while index < left.children.len() {
        if !core_type_ref_same(
                left.children.get(index).unwrap(),
                right.children.get(index).unwrap()) { return false }
        index = index + 1
    }
    index = 0
    while index < left.generic_arguments.len() {
        if !core_type_ref_same(
                left.generic_arguments.get(index).unwrap(),
                right.generic_arguments.get(index).unwrap()) { return false }
        index = index + 1
    }
    index = 0
    while index < left.nominal_fields.len() {
        let a = left.nominal_fields.get(index).unwrap()
        let b = right.nominal_fields.get(index).unwrap()
        if !flow_field_identity_same(a.identity, b.identity) ||
           !core_type_ref_same(a.ty, b.ty) ||
           !optional_record_names_same(a.record_name, b.record_name) {
            return false
        }
        index = index + 1
    }
    match (left.generic_param, right.generic_param) {
        (some(a), some(b)) => if !flow_generic_param_fact_same(a, b) {
            return false
        },
        (none, none) => {},
        _ => return false
    }
    index = 0
    while index < left.resource_storage_parameter_ordinals.len() {
        if left.resource_storage_parameter_ordinals.get(index).unwrap() !=
           right.resource_storage_parameter_ordinals.get(index).unwrap() {
            return false
        }
        index = index + 1
    }
    true
}

pub fn remap_flow_call_contract(
    value: FlowCallContract, mapping: List<Int>, module_key: Str
) -> FlowCallContract {
    if flow_call_contract_module_key(value) != some(module_key) {
        panic("FlowIR: call contract belongs to another type domain")
    }
    make_flow_call_contract(
        flow_call_contract_parameter_types(value).map(fn(reference) {
            mapped_type_ref(mapping, reference)
        }),
        flow_call_contract_parameter_roles(value),
        mapped_type_ref(mapping, flow_call_contract_result_type(value)),
        flow_call_contract_result_role(value),
        flow_call_contract_result_origin(value))
}

fn validate_type_nodes(values: List<FlowTypeNode>) {
    let mut ordinal = 0
    for value in values {
        if core_type_ref_index(value.reference) != ordinal {
            panic("FlowIR: type nodes are not in stable ordinal order")
        }
        let tag = flow_type_kind_tag(value.kind)
        for child in value.children {
            if core_type_ref_index(child) < 0 ||
               core_type_ref_index(child) >= values.len() {
                panic("FlowIR: type node has an unresolved child")
            }
        }
        for argument in value.generic_arguments {
            if core_type_ref_index(argument) < 0 ||
               core_type_ref_index(argument) >= values.len() {
                panic("FlowIR: type node has an unresolved generic argument")
            }
        }
        let seed = flow_type_semantic_seed_tag(value.semantic_seed)
        if tag != FLOW_TYPE_CALLABLE && value.callable_effects.is_some() {
            panic("FlowIR: non-callable type carries an effect contract")
        }
        if tag != FLOW_TYPE_STRUCT &&
           value.resource_storage_parameter_ordinals.len() != 0 {
            panic("FlowIR: non-struct type carries storage parameter ordinals")
        }
        let mut storage_index = 0
        while storage_index <
              value.resource_storage_parameter_ordinals.len() {
            let storage_ordinal =
                value.resource_storage_parameter_ordinals.get(
                    storage_index).unwrap()
            if storage_ordinal < 0 ||
               storage_ordinal >= value.generic_arguments.len() ||
               (storage_index > 0 &&
                value.resource_storage_parameter_ordinals.get(
                    storage_index - 1).unwrap() >= storage_ordinal) {
                panic("FlowIR: storage parameter ordinals are not canonical")
            }
            storage_index = storage_index + 1
        }
        if tag >= FLOW_TYPE_INT && tag <= FLOW_TYPE_NEVER {
            if value.nominal.is_some() || value.children.len() != 0 ||
               value.generic_arguments.len() != 0 ||
               value.nominal_fields.len() != 0 || value.parameter_count != 0 ||
               value.generic_param.is_some() || value.drop_contract.is_some() ||
               value.resource_storage_parameter_ordinals.len() != 0 ||
               (tag == FLOW_TYPE_STR && seed != flow_type_semantic_seed_tag(flow_type_seed_shareable())) ||
               (tag != FLOW_TYPE_STR && seed != flow_type_semantic_seed_tag(flow_type_seed_scalar())) {
                panic("FlowIR: atomic type payload is invalid")
            }
        } else if tag == FLOW_TYPE_STRUCT || tag == FLOW_TYPE_ENUM {
            if value.nominal.is_none() || value.parameter_count != 0 ||
               value.generic_param.is_some() ||
               (seed != flow_type_semantic_seed_tag(flow_type_seed_unique()) &&
                seed != flow_type_semantic_seed_tag(flow_type_seed_shareable())) ||
               value.children.len() != value.nominal_fields.len() {
                panic("FlowIR: nominal type payload is invalid")
            }
            let nominal = value.nominal.unwrap()
            let mut field_index = 0
            while field_index < value.nominal_fields.len() {
                let field = value.nominal_fields.get(field_index).unwrap()
                if field.record_name.is_some() || !core_type_ref_same(
                        field.ty, value.children.get(field_index).unwrap()) {
                    panic("FlowIR: nominal field/type child order differs")
                }
                match field.identity.value {
                    FlowFieldIdentityValue::NominalFieldIdentityValue(reference) => {
                        if !symbol_ref_same(
                                nominal_field_ref_owner(reference), nominal) {
                            panic("FlowIR: nominal field crosses type owner")
                        }
                    },
                    FlowFieldIdentityValue::VariantFieldIdentityValue(reference) => {
                        if !symbol_ref_same(
                                registered_nominal_ref_symbol(
                                    variant_ref_owner(
                                        variant_field_ref_variant(reference))),
                                nominal) {
                            panic("FlowIR: variant field crosses nominal owner")
                        }
                    },
                    FlowFieldIdentityValue::PathFieldIdentityValue(path) => {
                        if core_type_path_module_key(path) !=
                           symbol_ref_origin_module_key(nominal) {
                            panic("FlowIR: path field crosses nominal module")
                        }
                    }
                }
                let mut right_index = field_index + 1
                while right_index < value.nominal_fields.len() {
                    if flow_field_identity_same(
                            field.identity,
                            value.nominal_fields.get(right_index).unwrap().identity) {
                        panic("FlowIR: nominal type repeats a field identity")
                    }
                    right_index = right_index + 1
                }
                field_index = field_index + 1
            }
        } else if tag == FLOW_TYPE_TUPLE || tag == FLOW_TYPE_RECORD {
            if value.nominal.is_some() || value.parameter_count != 0 ||
               value.generic_param.is_some() ||
               value.generic_arguments.len() != 0 ||
               (tag == FLOW_TYPE_TUPLE && value.nominal_fields.len() != 0) ||
               (tag == FLOW_TYPE_RECORD &&
                value.nominal_fields.len() != value.children.len()) ||
               (seed != flow_type_semantic_seed_tag(flow_type_seed_unique()) &&
                seed != flow_type_semantic_seed_tag(flow_type_seed_shareable())) ||
               value.resource_storage_parameter_ordinals.len() != 0 {
                panic("FlowIR: structural type payload is invalid")
            }
            if tag == FLOW_TYPE_RECORD {
                let mut field_index = 0
                while field_index < value.nominal_fields.len() {
                    let field = value.nominal_fields.get(field_index).unwrap()
                    if flow_field_identity_is_nominal(field.identity) ||
                       flow_field_identity_is_variant(field.identity) ||
                       field.record_name.is_none() ||
                       !core_type_ref_same(
                            field.ty, value.children.get(field_index).unwrap()) {
                        panic("FlowIR: record field identity/type differs")
                    }
                    let mut right_index = field_index + 1
                    while right_index < value.nominal_fields.len() {
                        if flow_field_identity_same(
                                field.identity,
                                value.nominal_fields.get(right_index).unwrap()
                                    .identity) ||
                           flow_nominal_field_record_name(field) ==
                                flow_nominal_field_record_name(
                                    value.nominal_fields.get(
                                        right_index).unwrap()) {
                            panic("FlowIR: record repeats a field identity/name")
                        }
                        right_index = right_index + 1
                    }
                    field_index = field_index + 1
                }
            }
        } else if tag == FLOW_TYPE_CALLABLE {
            if value.nominal.is_some() || value.parameter_count < 0 ||
               value.children.len() != value.parameter_count + 1 ||
               value.generic_param.is_some() ||
               value.generic_arguments.len() != 0 ||
               value.nominal_fields.len() != 0 ||
               seed != flow_type_semantic_seed_tag(flow_type_seed_shareable()) ||
               value.drop_contract.is_some() ||
               value.callable_effects.is_none() ||
               value.resource_storage_parameter_ordinals.len() != 0 {
                panic("FlowIR: callable type payload is invalid")
            }
            let effects = value.callable_effects.unwrap()
            for atom in core_effect_set_atoms(
                    core_effect_contract_exact(effects)) {
                let effect_kind = core_effect_atom_kind_tag(atom)
                if effect_kind == 0 || effect_kind == 1 {
                    let ty = core_effect_atom_type(atom)
                    if core_type_ref_index(ty) < 0 ||
                       core_type_ref_index(ty) >= values.len() {
                        panic("FlowIR: callable effect type is unresolved")
                    }
                } else if effect_kind == 3 {
                    for ty in core_effect_atom_type_arguments(atom) {
                        if core_type_ref_index(ty) < 0 ||
                           core_type_ref_index(ty) >= values.len() {
                            panic("FlowIR: handled effect argument is unresolved")
                        }
                    }
                }
            }
        } else if tag == FLOW_TYPE_PTR {
            if value.nominal.is_some() || value.children.len() != 1 ||
               value.parameter_count != 0 || value.generic_param.is_some() ||
               value.generic_arguments.len() != 0 ||
               value.nominal_fields.len() != 0 || seed != flow_type_semantic_seed_tag(flow_type_seed_ptr()) ||
               value.drop_contract.is_some() ||
               value.resource_storage_parameter_ordinals.len() != 0 {
                panic("FlowIR: Ptr type payload is invalid")
            }
        } else if tag == FLOW_TYPE_PARAMETER {
            if value.nominal.is_some() || value.children.len() != 0 ||
               value.parameter_count != 0 || value.generic_param.is_none() ||
               value.generic_arguments.len() != 0 ||
               value.nominal_fields.len() != 0 ||
               seed != flow_type_semantic_seed_tag(flow_type_seed_parametric()) ||
               value.drop_contract.is_some() ||
               value.resource_storage_parameter_ordinals.len() != 0 {
                panic("FlowIR: type parameter payload is invalid")
            }
        } else if tag == FLOW_TYPE_EXTERN {
            if value.nominal.is_none() || value.children.len() != 0 ||
               value.parameter_count != 0 || value.generic_param.is_some() ||
               value.nominal_fields.len() != 0 || seed != flow_type_semantic_seed_tag(flow_type_seed_extern()) ||
               value.drop_contract.is_some() ||
               value.resource_storage_parameter_ordinals.len() != 0 {
                panic("FlowIR: extern type payload is invalid")
            }
        } else {
            panic("FlowIR: unknown type kind crossed freeze")
        }
        ordinal = ordinal + 1
    }
}

pub fn validate_flow_type_graph_nodes(values: List<FlowTypeNode>) {
    validate_type_nodes(values)
}

pub fn copy_flow_type_graph_nodes(
    values: List<FlowTypeNode>
) -> List<FlowTypeNode> {
    validate_type_nodes(values)
    copy_type_nodes(values)
}

// Opaque Core graph domain wrapper; Flow transports its nodes unchanged.
pub struct CoreTypeGraph { nodes: List<FlowTypeNode>, module_key: Str? }

pub fn make_core_type_graph(nodes: List<FlowTypeNode>) -> CoreTypeGraph {
    validate_flow_type_graph_nodes(nodes)
    CoreTypeGraph { nodes: copy_flow_type_graph_nodes(nodes), module_key: none }
}
pub fn make_module_core_type_graph(
    module_key: Str, nodes: List<FlowTypeNode>
) -> CoreTypeGraph {
    if module_key == "" { panic("CoreHIR: empty module type graph key") }
    validate_flow_type_graph_nodes(nodes)
    CoreTypeGraph {
        nodes: copy_flow_type_graph_nodes(nodes), module_key: some(module_key)
    }
}
pub fn copy_core_type_graph(value: CoreTypeGraph) -> CoreTypeGraph {
    CoreTypeGraph {
        nodes: copy_flow_type_graph_nodes(value.nodes),
        module_key: value.module_key
    }
}
pub fn core_type_graph_count(value: CoreTypeGraph) -> Int {
    value.nodes.len()
}
pub fn core_type_graph_nodes(value: CoreTypeGraph) -> List<FlowTypeNode> {
    copy_flow_type_graph_nodes(value.nodes)
}
pub fn core_type_graph_node(
    value: CoreTypeGraph, reference: CoreTypeRef
) -> FlowTypeNode {
    if value.module_key != core_type_ref_module_key(reference) {
        panic("CoreHIR: type reference belongs to another graph domain")
    }
    match value.nodes.get(core_type_ref_index(reference)) {
        some(node) => node,
        none => panic("CoreHIR: type reference is absent from CoreTypeGraph")
    }
}
pub fn core_type_graph_ref_from_flow(
    value: CoreTypeGraph, reference: CoreTypeRef
) -> CoreTypeRef {
    match value.module_key {
        some(module_key) => make_module_core_type_ref(
            module_key, core_type_ref_index(reference)),
        none => make_core_type_ref(core_type_ref_index(reference))
    }
}
