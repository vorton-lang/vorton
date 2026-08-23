// FlowIR: the first ownership-neutral, fixed-topology compiler IR.
//
// Every public value has a private representation.  Construction accepts only
// exact typed references already selected by CoreHIR.  This module never reads
// HProgram/HExpr, resolves a spelling, generates a semantic executable, inserts
// a resource operation, or chooses an ABI/layout.  `make_flow_program` is the
// single freeze barrier: after it returns, the ordered type/callable/body/slot/
// block topology is immutable and can be consumed mechanically by the resource
// planner.

use ir_identity::{
    SymbolRef, PathRef, PathOwnerRef, SlotRef,
    NominalFieldRef, IntrinsicRef,
    symbol_ref_same, symbol_ref_origin_module_key,
    symbol_ref_namespace_kind, symbol_ref_canonical_payload,
    symbol_ref_declaration_site_path,
    namespace_kind_tag, namespace_kind_same, namespace_nominal,
    namespace_trait,
    path_ref_same, path_ref_owner, path_ref_normalized_child_path,
    path_ref_role, path_role_tag,
    path_owner_ref_is_symbol, path_owner_ref_symbol,
    path_owner_ref_module_body,
    module_body_ref_origin_module_key,
    module_body_ref_declaration_site_path,
    slot_ref_same, slot_ref_is_source,
    slot_ref_source_origin_module_key, slot_ref_source_domain,
    slot_ref_source_def_id, slot_ref_synthetic_path,
    slot_domain_tag,
    nominal_field_ref_same, nominal_field_ref_owner,
    nominal_field_ref_member, nominal_field_ref_index,
    intrinsic_ref_same, intrinsic_ref_symbol, intrinsic_ref_site,
    builtin_method_site_tag,
    OriginRef, origin_ref_is_symbol, origin_ref_symbol, origin_ref_path,
    origin_ref_same
}
use ir_inventory::{
    ExecutableRef, executable_ref_same, executable_ref_is_named,
    executable_ref_named_symbol, executable_ref_anonymous_path,
    executable_ref_origin_module_key,
    BinderManifest, BinderEntry,
    binder_manifest_owner, binder_manifest_entries,
    binder_entry_slot, make_binder_manifest
}

// ============================================================
// Finite, exact type graph
// ============================================================

const FLOW_TYPE_INT: Int = 0
const FLOW_TYPE_FLOAT: Int = 1
const FLOW_TYPE_STR: Int = 2
const FLOW_TYPE_BOOL: Int = 3
const FLOW_TYPE_UNIT: Int = 4
const FLOW_TYPE_NEVER: Int = 5
const FLOW_TYPE_STRUCT: Int = 6
const FLOW_TYPE_ENUM: Int = 7
const FLOW_TYPE_TUPLE: Int = 8
const FLOW_TYPE_RECORD: Int = 9
const FLOW_TYPE_CALLABLE: Int = 10
const FLOW_TYPE_PTR: Int = 11
const FLOW_TYPE_PARAMETER: Int = 12
const FLOW_TYPE_EXTERN: Int = 13
const FLOW_TYPE_KIND_COUNT: Int = 14

pub struct FlowTypeRef { index: Int }

pub fn make_flow_type_ref(index: Int) -> FlowTypeRef {
    if index < 0 { panic("FlowIR: negative type reference") }
    FlowTypeRef { index: index }
}

pub fn flow_type_ref_index(value: FlowTypeRef) -> Int { value.index }

pub fn flow_type_ref_same(left: FlowTypeRef, right: FlowTypeRef) -> Bool {
    left.index == right.index
}

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

fn flow_type_kind_same(left: FlowTypeKind, right: FlowTypeKind) -> Bool {
    flow_type_kind_tag(left) == flow_type_kind_tag(right)
}

const FLOW_SEED_SCALAR: Int = 0
const FLOW_SEED_PTR: Int = 1
const FLOW_SEED_UNIQUE: Int = 2
const FLOW_SEED_SHAREABLE: Int = 3
const FLOW_SEED_EXTERN: Int = 4
const FLOW_SEED_PARAMETRIC: Int = 5

pub struct FlowTypeSemanticSeed { tag: Int }

fn flow_type_semantic_seed_from_tag(tag: Int) -> FlowTypeSemanticSeed {
    if tag < FLOW_SEED_SCALAR || tag > FLOW_SEED_PARAMETRIC {
        panic("FlowIR: invalid type semantic seed")
    }
    FlowTypeSemanticSeed { tag: tag }
}

pub fn flow_type_seed_scalar() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_SCALAR)
}
pub fn flow_type_seed_ptr() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_PTR)
}
pub fn flow_type_seed_unique() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_UNIQUE)
}
pub fn flow_type_seed_shareable() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_SHAREABLE)
}
pub fn flow_type_seed_extern() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_EXTERN)
}
pub fn flow_type_seed_parametric() -> FlowTypeSemanticSeed {
    flow_type_semantic_seed_from_tag(FLOW_SEED_PARAMETRIC)
}
pub fn flow_type_semantic_seed_tag(value: FlowTypeSemanticSeed) -> Int {
    flow_type_semantic_seed_from_tag(value.tag).tag
}

pub struct FlowDropContract { provider: ExecutableRef }

pub fn make_flow_drop_contract(provider: ExecutableRef) -> FlowDropContract {
    FlowDropContract { provider: provider }
}
pub fn flow_drop_contract_provider(value: FlowDropContract) -> ExecutableRef {
    value.provider
}

enum FlowForeignContractValue {
    BorrowedForeignValue,
    ManagedForeignValue { retain: ExecutableRef, release: ExecutableRef }
}

pub struct FlowForeignContract { value: FlowForeignContractValue }

pub fn make_borrowed_flow_foreign_contract() -> FlowForeignContract {
    FlowForeignContract { value: FlowForeignContractValue::BorrowedForeignValue }
}
pub fn make_managed_flow_foreign_contract(
    retain: ExecutableRef, release: ExecutableRef
) -> FlowForeignContract {
    if executable_ref_same(retain, release) {
        panic("FlowIR: foreign retain/release contracts alias")
    }
    FlowForeignContract { value: FlowForeignContractValue::ManagedForeignValue {
        retain: retain, release: release
    } }
}
pub fn flow_foreign_contract_is_managed(value: FlowForeignContract) -> Bool {
    match value.value {
        FlowForeignContractValue::ManagedForeignValue { .. } => true,
        FlowForeignContractValue::BorrowedForeignValue => false
    }
}
pub fn flow_foreign_contract_retain(value: FlowForeignContract) -> ExecutableRef {
    match value.value {
        FlowForeignContractValue::ManagedForeignValue { retain, .. } => retain,
        FlowForeignContractValue::BorrowedForeignValue =>
            panic("FlowIR: borrowed foreign type has no retain contract")
    }
}
pub fn flow_foreign_contract_release(value: FlowForeignContract) -> ExecutableRef {
    match value.value {
        FlowForeignContractValue::ManagedForeignValue { release, .. } => release,
        FlowForeignContractValue::BorrowedForeignValue =>
            panic("FlowIR: borrowed foreign type has no release contract")
    }
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

enum FlowFieldIdentityValue {
    NominalFieldIdentityValue(NominalFieldRef),
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
pub fn flow_field_identity_is_nominal(value: FlowFieldIdentity) -> Bool {
    match value.value {
        FlowFieldIdentityValue::NominalFieldIdentityValue(_) => true,
        FlowFieldIdentityValue::PathFieldIdentityValue(_) => false
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
fn flow_field_identity_same(
    left: FlowFieldIdentity, right: FlowFieldIdentity
) -> Bool {
    match (left.value, right.value) {
        (FlowFieldIdentityValue::NominalFieldIdentityValue(a),
         FlowFieldIdentityValue::NominalFieldIdentityValue(b)) =>
            nominal_field_ref_same(a, b),
        (FlowFieldIdentityValue::PathFieldIdentityValue(a),
         FlowFieldIdentityValue::PathFieldIdentityValue(b)) => path_ref_same(a, b),
        _ => false
    }
}

pub struct FlowNominalFieldFact {
    identity: FlowFieldIdentity,
    ty: FlowTypeRef
}

pub fn make_flow_nominal_field_fact(
    identity: FlowFieldIdentity, ty: FlowTypeRef
) -> FlowNominalFieldFact {
    FlowNominalFieldFact { identity: identity, ty: ty }
}
pub fn flow_nominal_field_identity(
    value: FlowNominalFieldFact
) -> FlowFieldIdentity { value.identity }
pub fn flow_nominal_field_type(value: FlowNominalFieldFact) -> FlowTypeRef {
    value.ty
}
fn copy_nominal_fields(values: List<FlowNominalFieldFact>) -> List<FlowNominalFieldFact> {
    let mut result: List<FlowNominalFieldFact> = []
    for value in values { result.push(value) }
    result
}

pub struct FlowTypeNode {
    reference: FlowTypeRef,
    kind: FlowTypeKind,
    nominal: SymbolRef?,
    children: List<FlowTypeRef>,
    generic_arguments: List<FlowTypeRef>,
    nominal_fields: List<FlowNominalFieldFact>,
    parameter_count: Int,
    generic_param: FlowGenericParamFact?,
    semantic_seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?,
    foreign_contract: FlowForeignContract?
}

fn copy_type_refs(values: List<FlowTypeRef>) -> List<FlowTypeRef> {
    let mut result: List<FlowTypeRef> = []
    for value in values { result.push(value) }
    result
}

fn make_atomic_flow_type_node(
    reference: FlowTypeRef, kind: FlowTypeKind
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
        generic_param: none, semantic_seed: seed,
        drop_contract: none, foreign_contract: none
    }
}

pub fn make_flow_int_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_int())
}
pub fn make_flow_float_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_float())
}
pub fn make_flow_str_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_str())
}
pub fn make_flow_bool_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_bool())
}
pub fn make_flow_unit_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_unit())
}
pub fn make_flow_never_type_node(reference: FlowTypeRef) -> FlowTypeNode {
    make_atomic_flow_type_node(reference, flow_type_kind_never())
}

fn make_nominal_flow_type_node(
    reference: FlowTypeRef, kind: FlowTypeKind, nominal: SymbolRef,
    arguments: List<FlowTypeRef>, fields: List<FlowNominalFieldFact>,
    semantic_seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?
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
        children: fields.map(fn(field) { field.ty }),
        generic_arguments: copy_type_refs(arguments),
        nominal_fields: copy_nominal_fields(fields), parameter_count: 0,
        generic_param: none,
        semantic_seed: flow_type_semantic_seed_from_tag(semantic_seed.tag),
        drop_contract: drop_contract, foreign_contract: none
    }
}

pub fn make_flow_struct_type_node(
    reference: FlowTypeRef, nominal: SymbolRef,
    arguments: List<FlowTypeRef>, fields: List<FlowNominalFieldFact>,
    semantic_seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?
) -> FlowTypeNode {
    make_nominal_flow_type_node(
        reference, flow_type_kind_struct(), nominal, arguments, fields,
        semantic_seed, drop_contract)
}

pub fn make_flow_enum_type_node(
    reference: FlowTypeRef, nominal: SymbolRef,
    arguments: List<FlowTypeRef>, fields: List<FlowNominalFieldFact>,
    semantic_seed: FlowTypeSemanticSeed,
    drop_contract: FlowDropContract?
) -> FlowTypeNode {
    make_nominal_flow_type_node(
        reference, flow_type_kind_enum(), nominal, arguments, fields,
        semantic_seed, drop_contract)
}

pub fn make_flow_extern_type_node(
    reference: FlowTypeRef, nominal: SymbolRef,
    arguments: List<FlowTypeRef>, contract: FlowForeignContract
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
        semantic_seed: flow_type_seed_extern(), drop_contract: none,
        foreign_contract: some(contract)
    }
}

fn make_structural_flow_type_node(
    reference: FlowTypeRef, kind: FlowTypeKind,
    children: List<FlowTypeRef>, semantic_seed: FlowTypeSemanticSeed,
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
        generic_param: none,
        semantic_seed: flow_type_semantic_seed_from_tag(semantic_seed.tag),
        drop_contract: drop_contract, foreign_contract: none
    }
}

pub fn make_flow_tuple_type_node(
    reference: FlowTypeRef, elements: List<FlowTypeRef>,
    semantic_seed: FlowTypeSemanticSeed, drop_contract: FlowDropContract?
) -> FlowTypeNode {
    make_structural_flow_type_node(
        reference, flow_type_kind_tuple(), elements,
        semantic_seed, drop_contract)
}

pub fn make_flow_record_type_node(
    reference: FlowTypeRef, fields: List<FlowTypeRef>,
    semantic_seed: FlowTypeSemanticSeed, drop_contract: FlowDropContract?
) -> FlowTypeNode {
    make_structural_flow_type_node(
        reference, flow_type_kind_record(), fields,
        semantic_seed, drop_contract)
}

pub fn make_flow_callable_type_node(
    reference: FlowTypeRef, parameters: List<FlowTypeRef>,
    result: FlowTypeRef
) -> FlowTypeNode {
    let mut children = copy_type_refs(parameters)
    children.push(result)
    FlowTypeNode {
        reference: reference, kind: flow_type_kind_callable(), nominal: none,
        children: children, parameter_count: parameters.len(),
        generic_arguments: [], nominal_fields: [], generic_param: none,
        semantic_seed: flow_type_seed_shareable(), drop_contract: none,
        foreign_contract: none
    }
}

pub fn make_flow_ptr_type_node(
    reference: FlowTypeRef, pointee: FlowTypeRef
) -> FlowTypeNode {
    FlowTypeNode {
        reference: reference, kind: flow_type_kind_ptr(), nominal: none,
        children: [pointee], generic_arguments: [], nominal_fields: [],
        parameter_count: 0, generic_param: none,
        semantic_seed: flow_type_seed_ptr(), drop_contract: none,
        foreign_contract: none
    }
}

pub fn make_flow_parameter_type_node(
    reference: FlowTypeRef, generic_param: FlowGenericParamFact
) -> FlowTypeNode {
    FlowTypeNode {
        reference: reference, kind: flow_type_kind_parameter(), nominal: none,
        children: [], generic_arguments: [], nominal_fields: [],
        parameter_count: 0,
        generic_param: some(copy_generic_param_fact(generic_param)),
        semantic_seed: flow_type_seed_parametric(), drop_contract: none,
        foreign_contract: none
    }
}

pub fn flow_type_node_reference(value: FlowTypeNode) -> FlowTypeRef { value.reference }
pub fn flow_type_node_kind(value: FlowTypeNode) -> FlowTypeKind { value.kind }
pub fn flow_type_node_children(value: FlowTypeNode) -> List<FlowTypeRef> {
    copy_type_refs(value.children)
}
pub fn flow_type_node_generic_arguments(value: FlowTypeNode) -> List<FlowTypeRef> {
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
pub fn flow_type_node_foreign_contract(value: FlowTypeNode) -> FlowForeignContract? {
    value.foreign_contract
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
            generic_param: match value.generic_param {
                some(fact) => some(copy_generic_param_fact(fact)),
                none => none
            },
            semantic_seed: value.semantic_seed,
            drop_contract: value.drop_contract,
            foreign_contract: value.foreign_contract
        })
    }
    result
}

fn validate_type_nodes(values: List<FlowTypeNode>) {
    let mut ordinal = 0
    for value in values {
        if value.reference.index != ordinal {
            panic("FlowIR: type nodes are not in stable ordinal order")
        }
        let tag = flow_type_kind_tag(value.kind)
        for child in value.children {
            if child.index < 0 || child.index >= values.len() {
                panic("FlowIR: type node has an unresolved child")
            }
        }
        for argument in value.generic_arguments {
            if argument.index < 0 || argument.index >= values.len() {
                panic("FlowIR: type node has an unresolved generic argument")
            }
        }
        let seed = flow_type_semantic_seed_tag(value.semantic_seed)
        if tag >= FLOW_TYPE_INT && tag <= FLOW_TYPE_NEVER {
            if value.nominal.is_some() || value.children.len() != 0 ||
               value.generic_arguments.len() != 0 ||
               value.nominal_fields.len() != 0 || value.parameter_count != 0 ||
               value.generic_param.is_some() || value.drop_contract.is_some() ||
               value.foreign_contract.is_some() ||
               (tag == FLOW_TYPE_STR && seed != FLOW_SEED_SHAREABLE) ||
               (tag != FLOW_TYPE_STR && seed != FLOW_SEED_SCALAR) {
                panic("FlowIR: atomic type payload is invalid")
            }
        } else if tag == FLOW_TYPE_STRUCT || tag == FLOW_TYPE_ENUM {
            if value.nominal.is_none() || value.parameter_count != 0 ||
               value.generic_param.is_some() || value.foreign_contract.is_some() ||
               (seed != FLOW_SEED_UNIQUE &&
                seed != FLOW_SEED_SHAREABLE &&
                seed != FLOW_SEED_PARAMETRIC) ||
               value.children.len() != value.nominal_fields.len() {
                panic("FlowIR: nominal type payload is invalid")
            }
            let nominal = value.nominal.unwrap()
            let mut field_index = 0
            while field_index < value.nominal_fields.len() {
                let field = value.nominal_fields.get(field_index).unwrap()
                if !flow_type_ref_same(
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
                    FlowFieldIdentityValue::PathFieldIdentityValue(path) => {
                        if path_ref_module_key(path) !=
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
               value.nominal_fields.len() != 0 ||
               value.foreign_contract.is_some() ||
               (seed != FLOW_SEED_UNIQUE &&
                seed != FLOW_SEED_SHAREABLE &&
                seed != FLOW_SEED_PARAMETRIC) {
                panic("FlowIR: structural type payload is invalid")
            }
        } else if tag == FLOW_TYPE_CALLABLE {
            if value.nominal.is_some() || value.parameter_count < 0 ||
               value.children.len() != value.parameter_count + 1 ||
               value.generic_param.is_some() ||
               value.generic_arguments.len() != 0 ||
               value.nominal_fields.len() != 0 ||
               seed != FLOW_SEED_SHAREABLE ||
               value.drop_contract.is_some() ||
               value.foreign_contract.is_some() {
                panic("FlowIR: callable type payload is invalid")
            }
        } else if tag == FLOW_TYPE_PTR {
            if value.nominal.is_some() || value.children.len() != 1 ||
               value.parameter_count != 0 || value.generic_param.is_some() ||
               value.generic_arguments.len() != 0 ||
               value.nominal_fields.len() != 0 || seed != FLOW_SEED_PTR ||
               value.drop_contract.is_some() ||
               value.foreign_contract.is_some() {
                panic("FlowIR: Ptr type payload is invalid")
            }
        } else if tag == FLOW_TYPE_PARAMETER {
            if value.nominal.is_some() || value.children.len() != 0 ||
               value.parameter_count != 0 || value.generic_param.is_none() ||
               value.generic_arguments.len() != 0 ||
               value.nominal_fields.len() != 0 ||
               seed != FLOW_SEED_PARAMETRIC ||
               value.drop_contract.is_some() ||
               value.foreign_contract.is_some() {
                panic("FlowIR: type parameter payload is invalid")
            }
        } else if tag == FLOW_TYPE_EXTERN {
            if value.nominal.is_none() || value.children.len() != 0 ||
               value.parameter_count != 0 || value.generic_param.is_some() ||
               value.nominal_fields.len() != 0 || seed != FLOW_SEED_EXTERN ||
               value.drop_contract.is_some() ||
               value.foreign_contract.is_none() {
                panic("FlowIR: extern type payload is invalid")
            }
        } else {
            panic("FlowIR: unknown type kind crossed freeze")
        }
        ordinal = ordinal + 1
    }
}

// ============================================================
// Callable contract (semantic lower bounds only)
// ============================================================

const FLOW_ROLE_READ: Int = 0
const FLOW_ROLE_MUTATE: Int = 1
const FLOW_ROLE_CONSUME: Int = 2
const FLOW_ROLE_FORCE: Int = 3

pub struct FlowSemanticRole { tag: Int }

fn flow_semantic_role_from_tag(tag: Int) -> FlowSemanticRole {
    if tag < FLOW_ROLE_READ || tag > FLOW_ROLE_FORCE {
        panic("FlowIR: invalid semantic role")
    }
    FlowSemanticRole { tag: tag }
}

pub fn flow_semantic_role_read() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_READ)
}
pub fn flow_semantic_role_mutate() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_MUTATE)
}
pub fn flow_semantic_role_consume() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_CONSUME)
}
pub fn flow_semantic_role_force() -> FlowSemanticRole {
    flow_semantic_role_from_tag(FLOW_ROLE_FORCE)
}
pub fn flow_semantic_role_tag(value: FlowSemanticRole) -> Int {
    flow_semantic_role_from_tag(value.tag).tag
}

fn copy_semantic_roles(values: List<FlowSemanticRole>) -> List<FlowSemanticRole> {
    let mut result: List<FlowSemanticRole> = []
    for value in values { result.push(value) }
    result
}

pub struct FlowCallContract {
    parameter_roles: List<FlowSemanticRole>,
    result_role: FlowSemanticRole
}

pub fn make_flow_call_contract(
    parameter_roles: List<FlowSemanticRole>, result_role: FlowSemanticRole
) -> FlowCallContract {
    for role in parameter_roles { let _ = flow_semantic_role_tag(role) }
    let _ = flow_semantic_role_tag(result_role)
    FlowCallContract {
        parameter_roles: copy_semantic_roles(parameter_roles),
        result_role: result_role
    }
}
pub fn flow_call_contract_parameter_roles(
    value: FlowCallContract
) -> List<FlowSemanticRole> { copy_semantic_roles(value.parameter_roles) }
pub fn flow_call_contract_result_role(
    value: FlowCallContract
) -> FlowSemanticRole { value.result_role }
pub fn flow_call_contract_same(
    left: FlowCallContract, right: FlowCallContract
) -> Bool {
    if left.parameter_roles.len() != right.parameter_roles.len() ||
       flow_semantic_role_tag(left.result_role) !=
       flow_semantic_role_tag(right.result_role) {
        return false
    }
    let mut index = 0
    while index < left.parameter_roles.len() {
        if flow_semantic_role_tag(left.parameter_roles.get(index).unwrap()) !=
           flow_semantic_role_tag(right.parameter_roles.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    true
}
fn copy_call_contract(value: FlowCallContract) -> FlowCallContract {
    make_flow_call_contract(value.parameter_roles, value.result_role)
}

const FLOW_CALLABLE_CONCRETE_BODY: Int = 0
const FLOW_CALLABLE_CONTRACT_ONLY: Int = 1

pub struct FlowCallableMode { tag: Int }

fn flow_callable_mode_from_tag(tag: Int) -> FlowCallableMode {
    if tag < FLOW_CALLABLE_CONCRETE_BODY ||
       tag > FLOW_CALLABLE_CONTRACT_ONLY {
        panic("FlowIR: invalid callable mode")
    }
    FlowCallableMode { tag: tag }
}

pub fn flow_callable_mode_concrete_body() -> FlowCallableMode {
    flow_callable_mode_from_tag(FLOW_CALLABLE_CONCRETE_BODY)
}
pub fn flow_callable_mode_contract_only() -> FlowCallableMode {
    flow_callable_mode_from_tag(FLOW_CALLABLE_CONTRACT_ONLY)
}
pub fn flow_callable_mode_same(
    left: FlowCallableMode, right: FlowCallableMode
) -> Bool { left.tag == right.tag }

pub struct FlowCallable {
    reference: ExecutableRef,
    origin: OriginRef,
    parameter_types: List<FlowTypeRef>,
    parameter_slots: List<SlotRef>,
    result_type: FlowTypeRef,
    mode: FlowCallableMode,
    semantic_contract: FlowCallContract,
    call_edges: List<FlowCallEdge>
}

pub fn make_flow_callable(
    reference: ExecutableRef, origin: OriginRef,
    parameter_types: List<FlowTypeRef>, parameter_slots: List<SlotRef>,
    result_type: FlowTypeRef,
    mode: FlowCallableMode,
    semantic_contract: FlowCallContract
) -> FlowCallable {
    if parameter_types.len() != semantic_contract.parameter_roles.len() {
        panic("FlowIR: callable parameter/role arity differs")
    }
    let concrete = flow_callable_mode_same(
        mode, flow_callable_mode_concrete_body())
    if (concrete && parameter_slots.len() != parameter_types.len()) ||
       (!concrete && parameter_slots.len() != 0) {
        panic("FlowIR: callable parameter slot relation is not total")
    }
    let mut left_index = 0
    while left_index < parameter_slots.len() {
        let mut right_index = left_index + 1
        while right_index < parameter_slots.len() {
            if slot_ref_same(
                    parameter_slots.get(left_index).unwrap(),
                    parameter_slots.get(right_index).unwrap()) {
                panic("FlowIR: callable repeats a parameter slot")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    FlowCallable {
        reference: reference, origin: origin,
        parameter_types: copy_type_refs(parameter_types),
        parameter_slots: copy_slot_refs(parameter_slots),
        result_type: result_type,
        mode: flow_callable_mode_from_tag(mode.tag),
        semantic_contract: copy_call_contract(semantic_contract),
        call_edges: []
    }
}

pub fn flow_callable_reference(value: FlowCallable) -> ExecutableRef { value.reference }
pub fn flow_callable_origin(value: FlowCallable) -> OriginRef { value.origin }
pub fn flow_callable_parameter_types(value: FlowCallable) -> List<FlowTypeRef> {
    copy_type_refs(value.parameter_types)
}
pub fn flow_callable_parameter_slots(value: FlowCallable) -> List<SlotRef> {
    copy_slot_refs(value.parameter_slots)
}
pub fn flow_callable_result_type(value: FlowCallable) -> FlowTypeRef {
    value.result_type
}
pub fn flow_callable_mode(value: FlowCallable) -> FlowCallableMode { value.mode }
pub fn flow_callable_parameter_role_lower_bounds(
    value: FlowCallable
) -> List<FlowSemanticRole> {
    copy_semantic_roles(value.semantic_contract.parameter_roles)
}
pub fn flow_callable_semantic_contract(value: FlowCallable) -> FlowCallContract {
    copy_call_contract(value.semantic_contract)
}

// ============================================================
// Body-local frozen identities, scopes, and slots
// ============================================================

pub struct FlowScopeRef {
    owner: ExecutableRef,
    ordinal: Int
}

pub fn make_flow_scope_ref(
    owner: ExecutableRef, ordinal: Int
) -> FlowScopeRef {
    if ordinal < 0 { panic("FlowIR: negative scope ordinal") }
    FlowScopeRef { owner: owner, ordinal: ordinal }
}

pub fn flow_scope_ref_owner(value: FlowScopeRef) -> ExecutableRef { value.owner }
pub fn flow_scope_ref_ordinal(value: FlowScopeRef) -> Int { value.ordinal }
pub fn flow_scope_ref_same(left: FlowScopeRef, right: FlowScopeRef) -> Bool {
    executable_ref_same(left.owner, right.owner) && left.ordinal == right.ordinal
}

pub struct FlowScope {
    reference: FlowScopeRef,
    parent: FlowScopeRef?
}

pub fn make_flow_root_scope(reference: FlowScopeRef) -> FlowScope {
    if reference.ordinal != 0 {
        panic("FlowIR: root scope does not have ordinal zero")
    }
    FlowScope { reference: reference, parent: none }
}

pub fn make_flow_child_scope(
    reference: FlowScopeRef, parent: FlowScopeRef
) -> FlowScope {
    if !executable_ref_same(reference.owner, parent.owner) ||
       reference.ordinal <= parent.ordinal {
        panic("FlowIR: child scope owner/order is invalid")
    }
    FlowScope { reference: reference, parent: some(parent) }
}

pub fn flow_scope_reference(value: FlowScope) -> FlowScopeRef { value.reference }
pub fn flow_scope_has_parent(value: FlowScope) -> Bool { value.parent.is_some() }
pub fn flow_scope_parent(value: FlowScope) -> FlowScopeRef {
    match value.parent {
        some(parent) => parent,
        none => panic("FlowIR: root scope has no parent")
    }
}

fn copy_scopes(values: List<FlowScope>) -> List<FlowScope> {
    let mut result: List<FlowScope> = []
    for value in values {
        result.push(FlowScope {
            reference: value.reference, parent: value.parent
        })
    }
    result
}

const FLOW_SLOT_EMPTY: Int = 0
const FLOW_SLOT_LIVE: Int = 1

pub struct FlowInitialSlotState { tag: Int }

fn flow_initial_slot_state_from_tag(tag: Int) -> FlowInitialSlotState {
    if tag < FLOW_SLOT_EMPTY || tag > FLOW_SLOT_LIVE {
        panic("FlowIR: invalid initial slot state")
    }
    FlowInitialSlotState { tag: tag }
}

pub fn flow_initial_slot_empty() -> FlowInitialSlotState {
    flow_initial_slot_state_from_tag(FLOW_SLOT_EMPTY)
}
pub fn flow_initial_slot_live() -> FlowInitialSlotState {
    flow_initial_slot_state_from_tag(FLOW_SLOT_LIVE)
}
pub fn flow_initial_slot_state_tag(value: FlowInitialSlotState) -> Int {
    flow_initial_slot_state_from_tag(value.tag).tag
}

const FLOW_STORAGE_PARAMETER: Int = 0
const FLOW_STORAGE_LOCAL: Int = 1
const FLOW_STORAGE_TEMP: Int = 2
const FLOW_STORAGE_RESULT: Int = 3
const FLOW_STORAGE_CAPTURE: Int = 4

pub struct FlowStorageClass { tag: Int }

fn flow_storage_class_from_tag(tag: Int) -> FlowStorageClass {
    if tag < FLOW_STORAGE_PARAMETER || tag > FLOW_STORAGE_CAPTURE {
        panic("FlowIR: invalid storage class")
    }
    FlowStorageClass { tag: tag }
}

pub fn flow_storage_parameter() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_PARAMETER)
}
pub fn flow_storage_local() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_LOCAL)
}
pub fn flow_storage_temp() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_TEMP)
}
pub fn flow_storage_result() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_RESULT)
}
pub fn flow_storage_capture() -> FlowStorageClass {
    flow_storage_class_from_tag(FLOW_STORAGE_CAPTURE)
}
pub fn flow_storage_class_tag(value: FlowStorageClass) -> Int {
    flow_storage_class_from_tag(value.tag).tag
}
pub fn flow_storage_class_same(
    left: FlowStorageClass, right: FlowStorageClass
) -> Bool { left.tag == right.tag }

const FLOW_OWN_STORAGE: Int = 0
const FLOW_BORROW_STORAGE: Int = 1

pub struct FlowStorageContract { tag: Int }

fn flow_storage_contract_from_tag(tag: Int) -> FlowStorageContract {
    if tag < FLOW_OWN_STORAGE || tag > FLOW_BORROW_STORAGE {
        panic("FlowIR: invalid source-semantic storage contract")
    }
    FlowStorageContract { tag: tag }
}
pub fn flow_own_storage() -> FlowStorageContract {
    flow_storage_contract_from_tag(FLOW_OWN_STORAGE)
}
pub fn flow_borrow_storage() -> FlowStorageContract {
    flow_storage_contract_from_tag(FLOW_BORROW_STORAGE)
}
pub fn flow_storage_contract_tag(value: FlowStorageContract) -> Int {
    flow_storage_contract_from_tag(value.tag).tag
}

pub struct FlowSlot {
    reference: SlotRef,
    ty: FlowTypeRef,
    scope: FlowScopeRef,
    reverse_ordinal: Int,
    initial_state: FlowInitialSlotState,
    storage: FlowStorageClass,
    storage_contract: FlowStorageContract,
    parameter_ordinal: Int?
}

pub fn make_flow_slot(
    reference: SlotRef, ty: FlowTypeRef, scope: FlowScopeRef,
    reverse_ordinal: Int, initial_state: FlowInitialSlotState,
    storage: FlowStorageClass, storage_contract: FlowStorageContract,
    parameter_ordinal: Int?
) -> FlowSlot {
    if reverse_ordinal < 0 {
        panic("FlowIR: negative reverse lexical slot ordinal")
    }
    if flow_storage_class_same(storage, flow_storage_parameter()) {
        match parameter_ordinal {
            some(ordinal) => if ordinal < 0 {
                panic("FlowIR: negative parameter ordinal")
            },
            none => panic("FlowIR: parameter storage lacks exact ordinal")
        }
    } else if parameter_ordinal.is_some() {
        panic("FlowIR: non-parameter storage carries parameter ordinal")
    }
    FlowSlot {
        reference: reference, ty: ty, scope: scope,
        reverse_ordinal: reverse_ordinal,
        initial_state: flow_initial_slot_state_from_tag(initial_state.tag),
        storage: flow_storage_class_from_tag(storage.tag),
        storage_contract: flow_storage_contract_from_tag(storage_contract.tag),
        parameter_ordinal: parameter_ordinal
    }
}

pub fn flow_slot_reference(value: FlowSlot) -> SlotRef { value.reference }
pub fn flow_slot_type(value: FlowSlot) -> FlowTypeRef { value.ty }
pub fn flow_slot_scope(value: FlowSlot) -> FlowScopeRef { value.scope }
pub fn flow_slot_reverse_ordinal(value: FlowSlot) -> Int { value.reverse_ordinal }
pub fn flow_slot_initial_state(value: FlowSlot) -> FlowInitialSlotState {
    value.initial_state
}
pub fn flow_slot_storage(value: FlowSlot) -> FlowStorageClass { value.storage }
pub fn flow_slot_storage_contract(value: FlowSlot) -> FlowStorageContract {
    value.storage_contract
}
pub fn flow_slot_parameter_ordinal(value: FlowSlot) -> Int {
    match value.parameter_ordinal {
        some(ordinal) => ordinal,
        none => panic("FlowIR: non-parameter slot has no parameter ordinal")
    }
}

fn copy_flow_slots(values: List<FlowSlot>) -> List<FlowSlot> {
    let mut result: List<FlowSlot> = []
    for value in values {
        result.push(FlowSlot {
            reference: value.reference, ty: value.ty, scope: value.scope,
            reverse_ordinal: value.reverse_ordinal,
            initial_state: value.initial_state, storage: value.storage,
            storage_contract: value.storage_contract,
            parameter_ordinal: value.parameter_ordinal
        })
    }
    result
}

pub struct FlowBlockRef {
    owner: ExecutableRef,
    ordinal: Int
}

pub fn make_flow_block_ref(
    owner: ExecutableRef, ordinal: Int
) -> FlowBlockRef {
    if ordinal < 0 { panic("FlowIR: negative block ordinal") }
    FlowBlockRef { owner: owner, ordinal: ordinal }
}

pub fn flow_block_ref_owner(value: FlowBlockRef) -> ExecutableRef { value.owner }
pub fn flow_block_ref_ordinal(value: FlowBlockRef) -> Int { value.ordinal }
pub fn flow_block_ref_same(left: FlowBlockRef, right: FlowBlockRef) -> Bool {
    executable_ref_same(left.owner, right.owner) && left.ordinal == right.ordinal
}

pub struct FlowInstructionRef {
    owner: ExecutableRef,
    block_ordinal: Int,
    instruction_ordinal: Int
}

pub fn make_flow_instruction_ref(
    owner: ExecutableRef, block_ordinal: Int, instruction_ordinal: Int
) -> FlowInstructionRef {
    if block_ordinal < 0 || instruction_ordinal < 0 {
        panic("FlowIR: negative instruction site ordinal")
    }
    FlowInstructionRef {
        owner: owner, block_ordinal: block_ordinal,
        instruction_ordinal: instruction_ordinal
    }
}

pub fn flow_instruction_ref_owner(value: FlowInstructionRef) -> ExecutableRef {
    value.owner
}
pub fn flow_instruction_ref_block_ordinal(value: FlowInstructionRef) -> Int {
    value.block_ordinal
}
pub fn flow_instruction_ref_ordinal(value: FlowInstructionRef) -> Int {
    value.instruction_ordinal
}
pub fn flow_instruction_ref_same(
    left: FlowInstructionRef, right: FlowInstructionRef
) -> Bool {
    executable_ref_same(left.owner, right.owner) &&
        left.block_ordinal == right.block_ordinal &&
        left.instruction_ordinal == right.instruction_ordinal
}

// ============================================================
// Exact call target and ownership-neutral instructions
// ============================================================

enum FlowCallTargetValue {
    DirectTargetValue(ExecutableRef),
    LocalTargetValue(SlotRef),
    DynamicTargetValue(PathRef)
}

fn copy_executable_refs(values: List<ExecutableRef>) -> List<ExecutableRef> {
    let mut result: List<ExecutableRef> = []
    for value in values { result.push(value) }
    result
}

fn validate_callable_candidates(values: List<ExecutableRef>) {
    if values.len() == 0 {
        panic("FlowIR: dynamic callable set is empty")
    }
    let mut left_index = 0
    while left_index < values.len() {
        let left = values.get(left_index).unwrap()
        let mut right_index = left_index + 1
        while right_index < values.len() {
            if executable_ref_same(left, values.get(right_index).unwrap()) {
                panic("FlowIR: dynamic callable set repeats a candidate")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
}

pub struct FlowCallTarget {
    value: FlowCallTargetValue,
    contract: FlowCallContract,
    candidates: List<ExecutableRef>
}

pub fn make_direct_flow_call_target(
    target: ExecutableRef, contract: FlowCallContract
) -> FlowCallTarget {
    FlowCallTarget {
        value: FlowCallTargetValue::DirectTargetValue(target),
        contract: copy_call_contract(contract), candidates: [target]
    }
}

pub fn make_local_flow_call_target(
    target: SlotRef, contract: FlowCallContract,
    candidates: List<ExecutableRef>
) -> FlowCallTarget {
    validate_callable_candidates(candidates)
    FlowCallTarget {
        value: FlowCallTargetValue::LocalTargetValue(target),
        contract: copy_call_contract(contract),
        candidates: copy_executable_refs(candidates)
    }
}

pub fn make_dynamic_flow_call_target(
    target: PathRef, contract: FlowCallContract,
    candidates: List<ExecutableRef>
) -> FlowCallTarget {
    validate_callable_candidates(candidates)
    FlowCallTarget {
        value: FlowCallTargetValue::DynamicTargetValue(target),
        contract: copy_call_contract(contract),
        candidates: copy_executable_refs(candidates)
    }
}

pub fn flow_call_target_is_direct(value: FlowCallTarget) -> Bool {
    match value.value {
        FlowCallTargetValue::DirectTargetValue(_) => true,
        _ => false
    }
}
pub fn flow_call_target_is_local(value: FlowCallTarget) -> Bool {
    match value.value {
        FlowCallTargetValue::LocalTargetValue(_) => true,
        _ => false
    }
}
pub fn flow_call_target_direct(value: FlowCallTarget) -> ExecutableRef {
    match value.value {
        FlowCallTargetValue::DirectTargetValue(target) => target,
        _ => panic("FlowIR: non-direct call target has no ExecutableRef")
    }
}
pub fn flow_call_target_local(value: FlowCallTarget) -> SlotRef {
    match value.value {
        FlowCallTargetValue::LocalTargetValue(target) => target,
        _ => panic("FlowIR: non-local call target has no SlotRef")
    }
}
pub fn flow_call_target_dynamic(value: FlowCallTarget) -> PathRef {
    match value.value {
        FlowCallTargetValue::DynamicTargetValue(target) => target,
        _ => panic("FlowIR: non-dynamic call target has no PathRef")
    }
}
pub fn flow_call_target_contract(value: FlowCallTarget) -> FlowCallContract {
    copy_call_contract(value.contract)
}
pub fn flow_call_target_candidates(value: FlowCallTarget) -> List<ExecutableRef> {
    copy_executable_refs(value.candidates)
}

fn flow_call_target_same(
    left: FlowCallTarget, right: FlowCallTarget
) -> Bool {
    if !flow_call_contract_same(left.contract, right.contract) ||
       left.candidates.len() != right.candidates.len() {
        return false
    }
    let mut candidate_index = 0
    while candidate_index < left.candidates.len() {
        if !executable_ref_same(
                left.candidates.get(candidate_index).unwrap(),
                right.candidates.get(candidate_index).unwrap()) {
            return false
        }
        candidate_index = candidate_index + 1
    }
    match (left.value, right.value) {
        (FlowCallTargetValue::DirectTargetValue(a),
         FlowCallTargetValue::DirectTargetValue(b)) => executable_ref_same(a, b),
        (FlowCallTargetValue::LocalTargetValue(a),
         FlowCallTargetValue::LocalTargetValue(b)) => slot_ref_same(a, b),
        (FlowCallTargetValue::DynamicTargetValue(a),
         FlowCallTargetValue::DynamicTargetValue(b)) => path_ref_same(a, b),
        _ => false
    }
}

fn copy_call_target(value: FlowCallTarget) -> FlowCallTarget {
    FlowCallTarget {
        value: value.value, contract: copy_call_contract(value.contract),
        candidates: copy_executable_refs(value.candidates)
    }
}

const FLOW_PRIMITIVE_ADD: Int = 0
const FLOW_PRIMITIVE_SUB: Int = 1
const FLOW_PRIMITIVE_MUL: Int = 2
const FLOW_PRIMITIVE_DIV: Int = 3
const FLOW_PRIMITIVE_MOD: Int = 4
const FLOW_PRIMITIVE_NEGATE: Int = 5
const FLOW_PRIMITIVE_NOT: Int = 6
const FLOW_PRIMITIVE_LT: Int = 7
const FLOW_PRIMITIVE_LE: Int = 8
const FLOW_PRIMITIVE_GT: Int = 9
const FLOW_PRIMITIVE_GE: Int = 10

pub struct FlowPrimitiveOp { tag: Int }

fn flow_primitive_op_from_tag(tag: Int) -> FlowPrimitiveOp {
    if tag < FLOW_PRIMITIVE_ADD || tag > FLOW_PRIMITIVE_GE {
        panic("FlowIR: invalid 0.1 primitive operation")
    }
    FlowPrimitiveOp { tag: tag }
}
pub fn flow_primitive_add() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_ADD) }
pub fn flow_primitive_sub() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_SUB) }
pub fn flow_primitive_mul() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_MUL) }
pub fn flow_primitive_div() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_DIV) }
pub fn flow_primitive_mod() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_MOD) }
pub fn flow_primitive_negate() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_NEGATE) }
pub fn flow_primitive_not() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_NOT) }
pub fn flow_primitive_lt() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_LT) }
pub fn flow_primitive_le() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_LE) }
pub fn flow_primitive_gt() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_GT) }
pub fn flow_primitive_ge() -> FlowPrimitiveOp { flow_primitive_op_from_tag(FLOW_PRIMITIVE_GE) }
pub fn flow_primitive_op_tag(value: FlowPrimitiveOp) -> Int {
    flow_primitive_op_from_tag(value.tag).tag
}

enum FlowOperationValue {
    IntLiteralOperationValue(Int),
    FloatLiteralOperationValue(Float),
    StrLiteralOperationValue(Str),
    BoolLiteralOperationValue(Bool),
    UnitLiteralOperationValue,
    PrimitiveOperationValue(FlowPrimitiveOp),
    ConstructorOperationValue(ExecutableRef),
    DictionaryOperationValue(ExecutableRef),
    IntrinsicOperationValue(IntrinsicRef)
}

pub struct FlowOperationContract {
    value: FlowOperationValue,
    input_roles: List<FlowSemanticRole>,
    target_role: FlowSemanticRole
}

fn make_flow_operation_contract(
    value: FlowOperationValue, input_roles: List<FlowSemanticRole>,
    target_role: FlowSemanticRole
) -> FlowOperationContract {
    for role in input_roles { let _ = flow_semantic_role_tag(role) }
    let _ = flow_semantic_role_tag(target_role)
    FlowOperationContract {
        value: value, input_roles: copy_semantic_roles(input_roles),
        target_role: target_role
    }
}

pub fn make_flow_int_literal_contract(value: Int) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::IntLiteralOperationValue(value), [],
        flow_semantic_role_read())
}
pub fn make_flow_float_literal_contract(value: Float) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::FloatLiteralOperationValue(value), [],
        flow_semantic_role_read())
}
pub fn make_flow_str_literal_contract(value: Str) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::StrLiteralOperationValue(value), [],
        flow_semantic_role_read())
}
pub fn make_flow_bool_literal_contract(value: Bool) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::BoolLiteralOperationValue(value), [],
        flow_semantic_role_read())
}
pub fn make_flow_unit_literal_contract() -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::UnitLiteralOperationValue, [],
        flow_semantic_role_read())
}
pub fn make_flow_primitive_contract(
    operation: FlowPrimitiveOp, input_roles: List<FlowSemanticRole>,
    target_role: FlowSemanticRole
) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::PrimitiveOperationValue(
            flow_primitive_op_from_tag(operation.tag)),
        input_roles, target_role)
}
pub fn make_flow_constructor_contract(
    constructor: ExecutableRef, input_roles: List<FlowSemanticRole>,
    target_role: FlowSemanticRole
) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::ConstructorOperationValue(constructor),
        input_roles, target_role)
}
pub fn make_flow_dictionary_contract(
    constructor: ExecutableRef, input_roles: List<FlowSemanticRole>,
    target_role: FlowSemanticRole
) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::DictionaryOperationValue(constructor),
        input_roles, target_role)
}
pub fn make_flow_intrinsic_contract(
    intrinsic: IntrinsicRef, input_roles: List<FlowSemanticRole>,
    target_role: FlowSemanticRole
) -> FlowOperationContract {
    make_flow_operation_contract(
        FlowOperationValue::IntrinsicOperationValue(intrinsic),
        input_roles, target_role)
}

pub fn flow_operation_contract_kind_tag(value: FlowOperationContract) -> Int {
    match value.value {
        FlowOperationValue::IntLiteralOperationValue(_) => 0,
        FlowOperationValue::FloatLiteralOperationValue(_) => 1,
        FlowOperationValue::StrLiteralOperationValue(_) => 2,
        FlowOperationValue::BoolLiteralOperationValue(_) => 3,
        FlowOperationValue::UnitLiteralOperationValue => 4,
        FlowOperationValue::PrimitiveOperationValue(_) => 5,
        FlowOperationValue::ConstructorOperationValue(_) => 6,
        FlowOperationValue::DictionaryOperationValue(_) => 7,
        FlowOperationValue::IntrinsicOperationValue(_) => 8
    }
}
pub fn flow_operation_contract_input_roles(
    value: FlowOperationContract
) -> List<FlowSemanticRole> { copy_semantic_roles(value.input_roles) }
pub fn flow_operation_contract_target_role(
    value: FlowOperationContract
) -> FlowSemanticRole { value.target_role }
pub fn flow_operation_contract_primitive(
    value: FlowOperationContract
) -> FlowPrimitiveOp {
    match value.value {
        FlowOperationValue::PrimitiveOperationValue(operation) => operation,
        _ => panic("FlowIR: operation is not primitive")
    }
}
pub fn flow_operation_contract_executable(
    value: FlowOperationContract
) -> ExecutableRef {
    match value.value {
        FlowOperationValue::ConstructorOperationValue(executable) |
        FlowOperationValue::DictionaryOperationValue(executable) => executable,
        _ => panic("FlowIR: operation has no executable contract")
    }
}
pub fn flow_operation_contract_intrinsic(
    value: FlowOperationContract
) -> IntrinsicRef {
    match value.value {
        FlowOperationValue::IntrinsicOperationValue(intrinsic) => intrinsic,
        _ => panic("FlowIR: operation is not intrinsic")
    }
}
pub fn flow_operation_contract_int_literal(value: FlowOperationContract) -> Int {
    match value.value {
        FlowOperationValue::IntLiteralOperationValue(literal) => literal,
        _ => panic("FlowIR: operation is not an Int literal")
    }
}
pub fn flow_operation_contract_float_literal(
    value: FlowOperationContract
) -> Float {
    match value.value {
        FlowOperationValue::FloatLiteralOperationValue(literal) => literal,
        _ => panic("FlowIR: operation is not a Float literal")
    }
}
pub fn flow_operation_contract_str_literal(value: FlowOperationContract) -> Str {
    match value.value {
        FlowOperationValue::StrLiteralOperationValue(literal) => literal,
        _ => panic("FlowIR: operation is not a Str literal")
    }
}
pub fn flow_operation_contract_bool_literal(
    value: FlowOperationContract
) -> Bool {
    match value.value {
        FlowOperationValue::BoolLiteralOperationValue(literal) => literal,
        _ => panic("FlowIR: operation is not a Bool literal")
    }
}

fn copy_operation_contract(value: FlowOperationContract) -> FlowOperationContract {
    make_flow_operation_contract(
        value.value, value.input_roles, value.target_role)
}

enum FlowInstructionValue {
    InitializeValue {
        operation: FlowOperationContract,
        inputs: List<SlotRef>, target: SlotRef
    },
    ReadValue { source: SlotRef, target: SlotRef },
    MutateValue {
        target: SlotRef, value: SlotRef,
        target_role: FlowSemanticRole, value_role: FlowSemanticRole
    },
    ConsumeValue { source: SlotRef },
    DiscardValue { source: SlotRef },
    AssignValue { rhs_temp: SlotRef, target: SlotRef },
    CallValue {
        target: FlowCallTarget, arguments: List<SlotRef>, result: SlotRef?
    },
    ProjectValue {
        projection: PathRef, base: SlotRef, result: SlotRef, partial: Bool
    },
    CaptureValue {
        capture: PathRef, source: SlotRef, target: SlotRef,
        source_role: FlowSemanticRole, target_role: FlowSemanticRole
    },
    ScopeEnterValue { scope: FlowScopeRef },
    ScopeExitValue { scope: FlowScopeRef }
}

pub struct FlowInstruction {
    reference: FlowInstructionRef,
    origin: OriginRef,
    value: FlowInstructionValue
}

fn copy_slot_refs(values: List<SlotRef>) -> List<SlotRef> {
    let mut result: List<SlotRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_flow_initialize(
    reference: FlowInstructionRef, origin: OriginRef,
    operation: FlowOperationContract, inputs: List<SlotRef>, target: SlotRef
) -> FlowInstruction {
    if operation.input_roles.len() != inputs.len() {
        panic("FlowIR: Initialize input semantic roles are not total")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::InitializeValue {
            operation: copy_operation_contract(operation),
            inputs: copy_slot_refs(inputs), target: target
        }
    }
}

pub fn make_flow_read(
    reference: FlowInstructionRef, origin: OriginRef,
    source: SlotRef, target: SlotRef
) -> FlowInstruction {
    if slot_ref_same(source, target) {
        panic("FlowIR: Read source and target are identical")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ReadValue {
            source: source, target: target
        }
    }
}

pub fn make_flow_mutate(
    reference: FlowInstructionRef, origin: OriginRef,
    target: SlotRef, value: SlotRef,
    target_role: FlowSemanticRole, value_role: FlowSemanticRole
) -> FlowInstruction {
    let _ = flow_semantic_role_tag(target_role)
    let _ = flow_semantic_role_tag(value_role)
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::MutateValue {
            target: target, value: value,
            target_role: target_role, value_role: value_role
        }
    }
}

pub fn make_flow_consume(
    reference: FlowInstructionRef, origin: OriginRef, source: SlotRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ConsumeValue { source: source }
    }
}

pub fn make_flow_discard(
    reference: FlowInstructionRef, origin: OriginRef, source: SlotRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::DiscardValue { source: source }
    }
}

pub fn make_flow_assign(
    reference: FlowInstructionRef, origin: OriginRef,
    rhs_temp: SlotRef, target: SlotRef
) -> FlowInstruction {
    if slot_ref_same(rhs_temp, target) {
        panic("FlowIR: Assign RHS temp aliases target")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::AssignValue {
            rhs_temp: rhs_temp, target: target
        }
    }
}

pub fn make_flow_call(
    reference: FlowInstructionRef, origin: OriginRef,
    target: FlowCallTarget, arguments: List<SlotRef>, result: SlotRef?
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::CallValue {
            target: copy_call_target(target),
            arguments: copy_slot_refs(arguments), result: result
        }
    }
}

pub fn make_flow_project(
    reference: FlowInstructionRef, origin: OriginRef,
    projection: PathRef, base: SlotRef, result: SlotRef, partial: Bool
) -> FlowInstruction {
    if slot_ref_same(base, result) {
        panic("FlowIR: projection aliases its base slot")
    }
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ProjectValue {
            projection: projection, base: base, result: result,
            partial: partial
        }
    }
}

pub fn make_flow_capture(
    reference: FlowInstructionRef, origin: OriginRef,
    capture: PathRef, source: SlotRef, target: SlotRef,
    source_role: FlowSemanticRole, target_role: FlowSemanticRole
) -> FlowInstruction {
    if slot_ref_same(source, target) {
        panic("FlowIR: capture source aliases target")
    }
    let _ = flow_semantic_role_tag(source_role)
    let _ = flow_semantic_role_tag(target_role)
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::CaptureValue {
            capture: capture, source: source, target: target,
            source_role: source_role, target_role: target_role
        }
    }
}

pub fn make_flow_scope_enter(
    reference: FlowInstructionRef, origin: OriginRef, scope: FlowScopeRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ScopeEnterValue { scope: scope }
    }
}

pub fn make_flow_scope_exit(
    reference: FlowInstructionRef, origin: OriginRef, scope: FlowScopeRef
) -> FlowInstruction {
    FlowInstruction {
        reference: reference, origin: origin,
        value: FlowInstructionValue::ScopeExitValue { scope: scope }
    }
}

pub fn flow_instruction_reference(
    value: FlowInstruction
) -> FlowInstructionRef { value.reference }
pub fn flow_instruction_origin(value: FlowInstruction) -> OriginRef { value.origin }

pub fn flow_instruction_kind_tag(value: FlowInstruction) -> Int {
    match value.value {
        FlowInstructionValue::InitializeValue { .. } => 0,
        FlowInstructionValue::ReadValue { .. } => 1,
        FlowInstructionValue::MutateValue { .. } => 2,
        FlowInstructionValue::ConsumeValue { .. } => 3,
        FlowInstructionValue::DiscardValue { .. } => 4,
        FlowInstructionValue::AssignValue { .. } => 5,
        FlowInstructionValue::CallValue { .. } => 6,
        FlowInstructionValue::ProjectValue { .. } => 7,
        FlowInstructionValue::CaptureValue { .. } => 8,
        FlowInstructionValue::ScopeEnterValue { .. } => 9,
        FlowInstructionValue::ScopeExitValue { .. } => 10
    }
}

pub fn flow_initialize_operation(value: FlowInstruction) -> FlowOperationContract {
    match value.value {
        FlowInstructionValue::InitializeValue { operation, .. } =>
            copy_operation_contract(operation),
        _ => panic("FlowIR: instruction is not Initialize")
    }
}
pub fn flow_initialize_inputs(value: FlowInstruction) -> List<SlotRef> {
    match value.value {
        FlowInstructionValue::InitializeValue { inputs, .. } =>
            copy_slot_refs(inputs),
        _ => panic("FlowIR: instruction is not Initialize")
    }
}
pub fn flow_initialize_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::InitializeValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Initialize")
    }
}
pub fn flow_read_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ReadValue { source, .. } => source,
        _ => panic("FlowIR: instruction is not Read")
    }
}
pub fn flow_read_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ReadValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Read")
    }
}
pub fn flow_mutate_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::MutateValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Mutate")
    }
}
pub fn flow_mutate_value(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::MutateValue { value: input, .. } => input,
        _ => panic("FlowIR: instruction is not Mutate")
    }
}
pub fn flow_mutate_target_role(value: FlowInstruction) -> FlowSemanticRole {
    match value.value {
        FlowInstructionValue::MutateValue { target_role, .. } => target_role,
        _ => panic("FlowIR: instruction is not Mutate")
    }
}
pub fn flow_mutate_value_role(value: FlowInstruction) -> FlowSemanticRole {
    match value.value {
        FlowInstructionValue::MutateValue { value_role, .. } => value_role,
        _ => panic("FlowIR: instruction is not Mutate")
    }
}
pub fn flow_consume_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ConsumeValue { source } => source,
        _ => panic("FlowIR: instruction is not Consume")
    }
}
pub fn flow_discard_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::DiscardValue { source } => source,
        _ => panic("FlowIR: instruction is not Discard")
    }
}
pub fn flow_assign_rhs_temp(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::AssignValue { rhs_temp, .. } => rhs_temp,
        _ => panic("FlowIR: instruction is not Assign")
    }
}
pub fn flow_assign_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::AssignValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Assign")
    }
}
pub fn flow_call_target(value: FlowInstruction) -> FlowCallTarget {
    match value.value {
        FlowInstructionValue::CallValue { target, .. } => copy_call_target(target),
        _ => panic("FlowIR: instruction is not Call")
    }
}
pub fn flow_call_arguments(value: FlowInstruction) -> List<SlotRef> {
    match value.value {
        FlowInstructionValue::CallValue { arguments, .. } =>
            copy_slot_refs(arguments),
        _ => panic("FlowIR: instruction is not Call")
    }
}
pub fn flow_call_result(value: FlowInstruction) -> SlotRef? {
    match value.value {
        FlowInstructionValue::CallValue { result, .. } => result,
        _ => panic("FlowIR: instruction is not Call")
    }
}
pub fn flow_project_projection(value: FlowInstruction) -> PathRef {
    match value.value {
        FlowInstructionValue::ProjectValue { projection, .. } => projection,
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_project_base(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ProjectValue { base, .. } => base,
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_project_result(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::ProjectValue { result, .. } => result,
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_project_is_partial(value: FlowInstruction) -> Bool {
    match value.value {
        FlowInstructionValue::ProjectValue { partial, .. } => partial,
        _ => panic("FlowIR: instruction is not Project")
    }
}
pub fn flow_capture_path(value: FlowInstruction) -> PathRef {
    match value.value {
        FlowInstructionValue::CaptureValue { capture, .. } => capture,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_capture_source(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::CaptureValue { source, .. } => source,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_capture_target(value: FlowInstruction) -> SlotRef {
    match value.value {
        FlowInstructionValue::CaptureValue { target, .. } => target,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_capture_source_role(value: FlowInstruction) -> FlowSemanticRole {
    match value.value {
        FlowInstructionValue::CaptureValue { source_role, .. } => source_role,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_capture_target_role(value: FlowInstruction) -> FlowSemanticRole {
    match value.value {
        FlowInstructionValue::CaptureValue { target_role, .. } => target_role,
        _ => panic("FlowIR: instruction is not Capture")
    }
}
pub fn flow_scope_instruction_scope(value: FlowInstruction) -> FlowScopeRef {
    match value.value {
        FlowInstructionValue::ScopeEnterValue { scope } |
        FlowInstructionValue::ScopeExitValue { scope } => scope,
        _ => panic("FlowIR: instruction is not a scope operation")
    }
}

// ============================================================
// Fixed control topology
// ============================================================

pub struct FlowSuccessor {
    target: FlowBlockRef,
    exited_scopes: List<FlowScopeRef>
}

fn copy_scope_refs(values: List<FlowScopeRef>) -> List<FlowScopeRef> {
    let mut result: List<FlowScopeRef> = []
    for value in values { result.push(value) }
    result
}

pub fn make_flow_successor(
    target: FlowBlockRef, exited_scopes: List<FlowScopeRef>
) -> FlowSuccessor {
    let mut left_index = 0
    while left_index < exited_scopes.len() {
        let left = exited_scopes.get(left_index).unwrap()
        if !executable_ref_same(left.owner, target.owner) {
            panic("FlowIR: successor exits a cross-body scope")
        }
        let mut right_index = left_index + 1
        while right_index < exited_scopes.len() {
            if flow_scope_ref_same(
                    left, exited_scopes.get(right_index).unwrap()) {
                panic("FlowIR: successor repeats an exited scope")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    FlowSuccessor {
        target: target, exited_scopes: copy_scope_refs(exited_scopes)
    }
}

pub fn flow_successor_target(value: FlowSuccessor) -> FlowBlockRef {
    value.target
}
pub fn flow_successor_exited_scopes(
    value: FlowSuccessor
) -> List<FlowScopeRef> { copy_scope_refs(value.exited_scopes) }

enum FlowTerminatorValue {
    GotoValue(FlowSuccessor),
    BranchValue {
        condition: SlotRef,
        when_true: FlowSuccessor,
        when_false: FlowSuccessor
    },
    LoopValue {
        condition: SlotRef,
        body: FlowSuccessor,
        exit: FlowSuccessor
    },
    ReturnValue { value: SlotRef?, exited_scopes: List<FlowScopeRef> },
    BreakValue(FlowSuccessor),
    ContinueValue(FlowSuccessor),
    CatchValue {
        error: SlotRef,
        handled: FlowSuccessor,
        propagate: FlowSuccessor
    },
    HandlerValue {
        operation: SlotRef,
        handled: FlowSuccessor,
        unhandled: FlowSuccessor
    },
    UnreachableValue { exited_scopes: List<FlowScopeRef> },
    DivergeValue { exited_scopes: List<FlowScopeRef> }
}

pub struct FlowTerminator {
    origin: OriginRef,
    value: FlowTerminatorValue
}

pub fn make_flow_goto(
    origin: OriginRef, successor: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::GotoValue(successor)
    }
}

pub fn make_flow_branch(
    origin: OriginRef, condition: SlotRef,
    when_true: FlowSuccessor, when_false: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::BranchValue {
            condition: condition, when_true: when_true, when_false: when_false
        }
    }
}

pub fn make_flow_loop(
    origin: OriginRef, condition: SlotRef,
    body: FlowSuccessor, exit: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::LoopValue {
            condition: condition, body: body, exit: exit
        }
    }
}

pub fn make_flow_return(
    origin: OriginRef, value: SlotRef?, exited_scopes: List<FlowScopeRef>
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::ReturnValue {
            value: value, exited_scopes: copy_scope_refs(exited_scopes)
        }
    }
}

pub fn make_flow_break(
    origin: OriginRef, successor: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::BreakValue(successor)
    }
}

pub fn make_flow_continue(
    origin: OriginRef, successor: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::ContinueValue(successor)
    }
}

pub fn make_flow_catch(
    origin: OriginRef, error: SlotRef,
    handled: FlowSuccessor, propagate: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::CatchValue {
            error: error, handled: handled, propagate: propagate
        }
    }
}

pub fn make_flow_handler(
    origin: OriginRef, operation: SlotRef,
    handled: FlowSuccessor, unhandled: FlowSuccessor
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::HandlerValue {
            operation: operation, handled: handled, unhandled: unhandled
        }
    }
}

pub fn make_flow_unreachable(
    origin: OriginRef, exited_scopes: List<FlowScopeRef>
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::UnreachableValue {
            exited_scopes: copy_scope_refs(exited_scopes)
        }
    }
}

pub fn make_flow_diverge(
    origin: OriginRef, exited_scopes: List<FlowScopeRef>
) -> FlowTerminator {
    FlowTerminator {
        origin: origin,
        value: FlowTerminatorValue::DivergeValue {
            exited_scopes: copy_scope_refs(exited_scopes)
        }
    }
}

pub fn flow_terminator_origin(value: FlowTerminator) -> OriginRef {
    value.origin
}

pub fn flow_terminator_kind_tag(value: FlowTerminator) -> Int {
    match value.value {
        FlowTerminatorValue::GotoValue(_) => 0,
        FlowTerminatorValue::BranchValue { .. } => 1,
        FlowTerminatorValue::LoopValue { .. } => 2,
        FlowTerminatorValue::ReturnValue { .. } => 3,
        FlowTerminatorValue::BreakValue(_) => 4,
        FlowTerminatorValue::ContinueValue(_) => 5,
        FlowTerminatorValue::CatchValue { .. } => 6,
        FlowTerminatorValue::HandlerValue { .. } => 7,
        FlowTerminatorValue::UnreachableValue { .. } => 8,
        FlowTerminatorValue::DivergeValue { .. } => 9
    }
}

fn terminator_successors(value: FlowTerminator) -> List<FlowSuccessor> {
    match value.value {
        FlowTerminatorValue::GotoValue(edge) => [edge],
        FlowTerminatorValue::BranchValue { when_true, when_false, .. } =>
            [when_true, when_false],
        FlowTerminatorValue::LoopValue { body, exit, .. } => [body, exit],
        FlowTerminatorValue::BreakValue(edge) => [edge],
        FlowTerminatorValue::ContinueValue(edge) => [edge],
        FlowTerminatorValue::CatchValue { handled, propagate, .. } =>
            [handled, propagate],
        FlowTerminatorValue::HandlerValue { handled, unhandled, .. } =>
            [handled, unhandled],
        FlowTerminatorValue::ReturnValue { .. } |
        FlowTerminatorValue::UnreachableValue { .. } |
        FlowTerminatorValue::DivergeValue { .. } => []
    }
}

pub fn flow_terminator_successors(
    value: FlowTerminator
) -> List<FlowSuccessor> {
    let mut result: List<FlowSuccessor> = []
    for edge in terminator_successors(value) {
        result.push(FlowSuccessor {
            target: edge.target,
            exited_scopes: copy_scope_refs(edge.exited_scopes)
        })
    }
    result
}

pub fn flow_terminator_read_slots(value: FlowTerminator) -> List<SlotRef> {
    match value.value {
        FlowTerminatorValue::BranchValue { condition, .. } |
        FlowTerminatorValue::LoopValue { condition, .. } => [condition],
        FlowTerminatorValue::ReturnValue { value: returned, .. } =>
            match returned { some(slot) => [slot], none => [] },
        FlowTerminatorValue::CatchValue { error, .. } => [error],
        FlowTerminatorValue::HandlerValue { operation, .. } => [operation],
        _ => []
    }
}

pub fn flow_terminator_terminal_exited_scopes(
    value: FlowTerminator
) -> List<FlowScopeRef> {
    match terminator_terminal_exited_scopes(value) {
        some(scopes) => scopes,
        none => panic("FlowIR: non-terminal terminator has no terminal exits")
    }
}

fn copy_successor(value: FlowSuccessor) -> FlowSuccessor {
    FlowSuccessor {
        target: value.target,
        exited_scopes: copy_scope_refs(value.exited_scopes)
    }
}

fn copy_terminator(value: FlowTerminator) -> FlowTerminator {
    match value.value {
        FlowTerminatorValue::GotoValue(edge) =>
            make_flow_goto(value.origin, copy_successor(edge)),
        FlowTerminatorValue::BranchValue {
            condition, when_true, when_false
        } => make_flow_branch(
            value.origin, condition,
            copy_successor(when_true), copy_successor(when_false)),
        FlowTerminatorValue::LoopValue { condition, body, exit } =>
            make_flow_loop(
                value.origin, condition,
                copy_successor(body), copy_successor(exit)),
        FlowTerminatorValue::ReturnValue { value: returned, exited_scopes } =>
            make_flow_return(value.origin, returned, exited_scopes),
        FlowTerminatorValue::BreakValue(edge) =>
            make_flow_break(value.origin, copy_successor(edge)),
        FlowTerminatorValue::ContinueValue(edge) =>
            make_flow_continue(value.origin, copy_successor(edge)),
        FlowTerminatorValue::CatchValue { error, handled, propagate } =>
            make_flow_catch(
                value.origin, error,
                copy_successor(handled), copy_successor(propagate)),
        FlowTerminatorValue::HandlerValue {
            operation, handled, unhandled
        } => make_flow_handler(
            value.origin, operation,
            copy_successor(handled), copy_successor(unhandled)),
        FlowTerminatorValue::UnreachableValue { exited_scopes } =>
            make_flow_unreachable(value.origin, exited_scopes),
        FlowTerminatorValue::DivergeValue { exited_scopes } =>
            make_flow_diverge(value.origin, exited_scopes)
    }
}

fn terminator_terminal_exited_scopes(
    value: FlowTerminator
) -> List<FlowScopeRef>? {
    match value.value {
        FlowTerminatorValue::ReturnValue { exited_scopes, .. } =>
            some(copy_scope_refs(exited_scopes)),
        FlowTerminatorValue::UnreachableValue { exited_scopes } =>
            some(copy_scope_refs(exited_scopes)),
        FlowTerminatorValue::DivergeValue { exited_scopes } =>
            some(copy_scope_refs(exited_scopes)),
        _ => none
    }
}

pub struct FlowBlock {
    reference: FlowBlockRef,
    origin: OriginRef,
    scope: FlowScopeRef,
    instructions: List<FlowInstruction>,
    terminator: FlowTerminator
}

fn copy_instructions(values: List<FlowInstruction>) -> List<FlowInstruction> {
    let mut result: List<FlowInstruction> = []
    for value in values {
        result.push(match value.value {
            FlowInstructionValue::InitializeValue {
                operation, inputs, target
            } => make_flow_initialize(
                value.reference, value.origin, operation, inputs, target),
            FlowInstructionValue::ReadValue { source, target } =>
                make_flow_read(value.reference, value.origin, source, target),
            FlowInstructionValue::MutateValue {
                target, value: input, target_role, value_role
            } => make_flow_mutate(
                value.reference, value.origin, target, input,
                target_role, value_role),
            FlowInstructionValue::ConsumeValue { source } =>
                make_flow_consume(value.reference, value.origin, source),
            FlowInstructionValue::DiscardValue { source } =>
                make_flow_discard(value.reference, value.origin, source),
            FlowInstructionValue::AssignValue { rhs_temp, target } =>
                make_flow_assign(
                    value.reference, value.origin, rhs_temp, target),
            FlowInstructionValue::CallValue { target, arguments, result } =>
                make_flow_call(
                    value.reference, value.origin, target, arguments, result),
            FlowInstructionValue::ProjectValue {
                projection, base, result: projected, partial
            } => make_flow_project(
                value.reference, value.origin, projection,
                base, projected, partial),
            FlowInstructionValue::CaptureValue {
                capture, source, target, source_role, target_role
            } => make_flow_capture(
                value.reference, value.origin, capture, source, target,
                source_role, target_role),
            FlowInstructionValue::ScopeEnterValue { scope } =>
                make_flow_scope_enter(value.reference, value.origin, scope),
            FlowInstructionValue::ScopeExitValue { scope } =>
                make_flow_scope_exit(value.reference, value.origin, scope)
        })
    }
    result
}

pub fn make_flow_block(
    reference: FlowBlockRef, origin: OriginRef, scope: FlowScopeRef,
    instructions: List<FlowInstruction>, terminator: FlowTerminator
) -> FlowBlock {
    if !executable_ref_same(reference.owner, scope.owner) {
        panic("FlowIR: block scope crosses executable owner")
    }
    let mut ordinal = 0
    for instruction in instructions {
        let site = instruction.reference
        if !executable_ref_same(site.owner, reference.owner) ||
           site.block_ordinal != reference.ordinal ||
           site.instruction_ordinal != ordinal {
            panic("FlowIR: instruction order/site is not stable")
        }
        ordinal = ordinal + 1
    }
    FlowBlock {
        reference: reference, origin: origin, scope: scope,
        instructions: copy_instructions(instructions),
        terminator: copy_terminator(terminator)
    }
}

pub fn flow_block_reference(value: FlowBlock) -> FlowBlockRef { value.reference }
pub fn flow_block_origin(value: FlowBlock) -> OriginRef { value.origin }
pub fn flow_block_scope(value: FlowBlock) -> FlowScopeRef { value.scope }
pub fn flow_block_instructions(value: FlowBlock) -> List<FlowInstruction> {
    copy_instructions(value.instructions)
}
pub fn flow_block_terminator(value: FlowBlock) -> FlowTerminator {
    copy_terminator(value.terminator)
}
pub fn flow_block_successors(value: FlowBlock) -> List<FlowSuccessor> {
    flow_terminator_successors(value.terminator)
}

fn copy_blocks(values: List<FlowBlock>) -> List<FlowBlock> {
    let mut result: List<FlowBlock> = []
    for value in values {
        result.push(FlowBlock {
            reference: value.reference, origin: value.origin,
            scope: value.scope,
            instructions: copy_instructions(value.instructions),
            terminator: copy_terminator(value.terminator)
        })
    }
    result
}

pub struct FlowBody {
    reference: ExecutableRef,
    origin: OriginRef,
    manifest: BinderManifest,
    scopes: List<FlowScope>,
    slots: List<FlowSlot>,
    entry: FlowBlockRef,
    blocks: List<FlowBlock>
}

fn copy_binder_manifest(value: BinderManifest) -> BinderManifest {
    make_binder_manifest(
        binder_manifest_owner(value), binder_manifest_entries(value))
}

pub fn make_flow_body(
    reference: ExecutableRef, origin: OriginRef,
    manifest: BinderManifest, scopes: List<FlowScope>,
    slots: List<FlowSlot>, entry: FlowBlockRef,
    blocks: List<FlowBlock>
) -> FlowBody {
    if !executable_ref_same(reference, binder_manifest_owner(manifest)) ||
       !executable_ref_same(reference, entry.owner) {
        panic("FlowIR: body identity/manifest/entry differs")
    }
    FlowBody {
        reference: reference, origin: origin,
        manifest: copy_binder_manifest(manifest),
        scopes: copy_scopes(scopes), slots: copy_flow_slots(slots),
        entry: entry, blocks: copy_blocks(blocks)
    }
}

pub fn flow_body_reference(value: FlowBody) -> ExecutableRef { value.reference }
pub fn flow_body_origin(value: FlowBody) -> OriginRef { value.origin }
pub fn flow_body_manifest(value: FlowBody) -> BinderManifest {
    copy_binder_manifest(value.manifest)
}
pub fn flow_body_scopes(value: FlowBody) -> List<FlowScope> {
    copy_scopes(value.scopes)
}
pub fn flow_body_slots(value: FlowBody) -> List<FlowSlot> {
    copy_flow_slots(value.slots)
}
pub fn flow_body_entry(value: FlowBody) -> FlowBlockRef { value.entry }
pub fn flow_body_blocks(value: FlowBody) -> List<FlowBlock> {
    copy_blocks(value.blocks)
}

fn copy_bodies(values: List<FlowBody>) -> List<FlowBody> {
    let mut result: List<FlowBody> = []
    for value in values {
        result.push(FlowBody {
            reference: value.reference, origin: value.origin,
            manifest: copy_binder_manifest(value.manifest),
            scopes: copy_scopes(value.scopes),
            slots: copy_flow_slots(value.slots), entry: value.entry,
            blocks: copy_blocks(value.blocks)
        })
    }
    result
}

// ============================================================
// Derived graph edges (never a second stored authority)
// ============================================================

pub struct FlowCallEdge {
    caller: ExecutableRef,
    site: FlowInstructionRef,
    target: FlowCallTarget,
    arguments: List<SlotRef>,
    result: SlotRef?
}

pub fn flow_call_edge_caller(value: FlowCallEdge) -> ExecutableRef {
    value.caller
}
pub fn flow_call_edge_site(value: FlowCallEdge) -> FlowInstructionRef {
    value.site
}
pub fn flow_call_edge_target(value: FlowCallEdge) -> FlowCallTarget {
    copy_call_target(value.target)
}
pub fn flow_call_edge_arguments(value: FlowCallEdge) -> List<SlotRef> {
    copy_slot_refs(value.arguments)
}
pub fn flow_call_edge_result(value: FlowCallEdge) -> SlotRef? { value.result }

fn copy_call_edges(values: List<FlowCallEdge>) -> List<FlowCallEdge> {
    let mut result: List<FlowCallEdge> = []
    for value in values {
        result.push(FlowCallEdge {
            caller: value.caller, site: value.site,
            target: copy_call_target(value.target),
            // target owns role/candidate lists and must not alias the caller.
            arguments: copy_slot_refs(value.arguments), result: value.result
        })
    }
    result
}

pub fn flow_callable_call_edges(value: FlowCallable) -> List<FlowCallEdge> {
    copy_call_edges(value.call_edges)
}

pub struct FlowProjectionEdge {
    owner: ExecutableRef,
    site: FlowInstructionRef,
    projection: PathRef,
    base: SlotRef,
    result: SlotRef,
    partial: Bool
}

pub fn flow_projection_edge_owner(value: FlowProjectionEdge) -> ExecutableRef {
    value.owner
}
pub fn flow_projection_edge_site(value: FlowProjectionEdge) -> FlowInstructionRef {
    value.site
}
pub fn flow_projection_edge_projection(value: FlowProjectionEdge) -> PathRef {
    value.projection
}
pub fn flow_projection_edge_base(value: FlowProjectionEdge) -> SlotRef {
    value.base
}
pub fn flow_projection_edge_result(value: FlowProjectionEdge) -> SlotRef {
    value.result
}
pub fn flow_projection_edge_is_partial(value: FlowProjectionEdge) -> Bool {
    value.partial
}

pub struct FlowCaptureEdge {
    owner: ExecutableRef,
    site: FlowInstructionRef,
    capture: PathRef,
    source: SlotRef,
    target: SlotRef,
    source_role: FlowSemanticRole,
    target_role: FlowSemanticRole
}

pub fn flow_capture_edge_owner(value: FlowCaptureEdge) -> ExecutableRef {
    value.owner
}
pub fn flow_capture_edge_site(value: FlowCaptureEdge) -> FlowInstructionRef {
    value.site
}
pub fn flow_capture_edge_capture(value: FlowCaptureEdge) -> PathRef {
    value.capture
}
pub fn flow_capture_edge_source(value: FlowCaptureEdge) -> SlotRef {
    value.source
}
pub fn flow_capture_edge_target(value: FlowCaptureEdge) -> SlotRef {
    value.target
}
pub fn flow_capture_edge_source_role(value: FlowCaptureEdge) -> FlowSemanticRole {
    value.source_role
}
pub fn flow_capture_edge_target_role(value: FlowCaptureEdge) -> FlowSemanticRole {
    value.target_role
}

pub struct FlowControlEdge {
    owner: ExecutableRef,
    from: FlowBlockRef,
    to: FlowBlockRef,
    exited_scopes: List<FlowScopeRef>,
    terminator_kind: Int
}

pub fn flow_control_edge_owner(value: FlowControlEdge) -> ExecutableRef {
    value.owner
}
pub fn flow_control_edge_from(value: FlowControlEdge) -> FlowBlockRef {
    value.from
}
pub fn flow_control_edge_to(value: FlowControlEdge) -> FlowBlockRef { value.to }
pub fn flow_control_edge_exited_scopes(
    value: FlowControlEdge
) -> List<FlowScopeRef> { copy_scope_refs(value.exited_scopes) }
pub fn flow_control_edge_terminator_kind(value: FlowControlEdge) -> Int {
    value.terminator_kind
}

const FLOW_EXIT_RETURN: Int = 0
const FLOW_EXIT_UNREACHABLE: Int = 1
const FLOW_EXIT_DIVERGE: Int = 2

pub struct FlowExitKind { tag: Int }

fn flow_exit_kind_from_tag(tag: Int) -> FlowExitKind {
    if tag < FLOW_EXIT_RETURN || tag > FLOW_EXIT_DIVERGE {
        panic("FlowIR: invalid exit kind")
    }
    FlowExitKind { tag: tag }
}

pub fn flow_exit_kind_return() -> FlowExitKind {
    flow_exit_kind_from_tag(FLOW_EXIT_RETURN)
}
pub fn flow_exit_kind_unreachable() -> FlowExitKind {
    flow_exit_kind_from_tag(FLOW_EXIT_UNREACHABLE)
}
pub fn flow_exit_kind_diverge() -> FlowExitKind {
    flow_exit_kind_from_tag(FLOW_EXIT_DIVERGE)
}
pub fn flow_exit_kind_tag(value: FlowExitKind) -> Int {
    flow_exit_kind_from_tag(value.tag).tag
}

pub struct FlowExitEdge {
    owner: ExecutableRef,
    from: FlowBlockRef,
    kind: FlowExitKind,
    value: SlotRef?,
    exited_scopes: List<FlowScopeRef>
}

pub fn flow_exit_edge_owner(value: FlowExitEdge) -> ExecutableRef { value.owner }
pub fn flow_exit_edge_from(value: FlowExitEdge) -> FlowBlockRef { value.from }
pub fn flow_exit_edge_kind(value: FlowExitEdge) -> FlowExitKind { value.kind }
pub fn flow_exit_edge_value(value: FlowExitEdge) -> SlotRef? { value.value }
pub fn flow_exit_edge_exited_scopes(
    value: FlowExitEdge
) -> List<FlowScopeRef> { copy_scope_refs(value.exited_scopes) }

pub fn flow_body_call_edges(value: FlowBody) -> List<FlowCallEdge> {
    let mut result: List<FlowCallEdge> = []
    for block in value.blocks {
        for instruction in block.instructions {
            match instruction.value {
                FlowInstructionValue::CallValue {
                    target, arguments, result: call_result
                } => result.push(FlowCallEdge {
                    caller: value.reference, site: instruction.reference,
                    target: copy_call_target(target),
                    arguments: copy_slot_refs(arguments),
                    result: call_result
                }),
                _ => {}
            }
        }
    }
    result
}

pub fn flow_body_projection_edges(value: FlowBody) -> List<FlowProjectionEdge> {
    let mut result: List<FlowProjectionEdge> = []
    for block in value.blocks {
        for instruction in block.instructions {
            match instruction.value {
                FlowInstructionValue::ProjectValue {
                    projection, base, result: projected, partial
                } => result.push(FlowProjectionEdge {
                    owner: value.reference, site: instruction.reference,
                    projection: projection, base: base, result: projected,
                    partial: partial
                }),
                _ => {}
            }
        }
    }
    result
}

pub fn flow_body_capture_edges(value: FlowBody) -> List<FlowCaptureEdge> {
    let mut result: List<FlowCaptureEdge> = []
    for block in value.blocks {
        for instruction in block.instructions {
            match instruction.value {
                FlowInstructionValue::CaptureValue {
                    capture, source, target, source_role, target_role
                } => result.push(FlowCaptureEdge {
                    owner: value.reference, site: instruction.reference,
                    capture: capture, source: source, target: target,
                    source_role: source_role, target_role: target_role
                }),
                _ => {}
            }
        }
    }
    result
}

pub fn flow_body_control_edges(value: FlowBody) -> List<FlowControlEdge> {
    let mut result: List<FlowControlEdge> = []
    for block in value.blocks {
        let kind = flow_terminator_kind_tag(block.terminator)
        for successor in terminator_successors(block.terminator) {
            result.push(FlowControlEdge {
                owner: value.reference, from: block.reference,
                to: successor.target,
                exited_scopes: copy_scope_refs(successor.exited_scopes),
                terminator_kind: kind
            })
        }
    }
    result
}

pub fn flow_body_exit_edges(value: FlowBody) -> List<FlowExitEdge> {
    let mut result: List<FlowExitEdge> = []
    for block in value.blocks {
        match block.terminator.value {
            FlowTerminatorValue::ReturnValue {
                value: returned, exited_scopes
            } => result.push(FlowExitEdge {
                owner: value.reference, from: block.reference,
                kind: flow_exit_kind_return(), value: returned,
                exited_scopes: copy_scope_refs(exited_scopes)
            }),
            FlowTerminatorValue::UnreachableValue { exited_scopes } =>
                result.push(FlowExitEdge {
                    owner: value.reference, from: block.reference,
                    kind: flow_exit_kind_unreachable(), value: none,
                    exited_scopes: copy_scope_refs(exited_scopes)
                }),
            FlowTerminatorValue::DivergeValue { exited_scopes } =>
                result.push(FlowExitEdge {
                    owner: value.reference, from: block.reference,
                    kind: flow_exit_kind_diverge(), value: none,
                    exited_scopes: copy_scope_refs(exited_scopes)
                }),
            _ => {}
        }
    }
    result
}

// ============================================================
// Freeze validation
// ============================================================

fn path_owner_module_key(value: PathOwnerRef) -> Str {
    if path_owner_ref_is_symbol(value) {
        symbol_ref_origin_module_key(path_owner_ref_symbol(value))
    } else {
        module_body_ref_origin_module_key(path_owner_ref_module_body(value))
    }
}

fn path_ref_module_key(value: PathRef) -> Str {
    path_owner_module_key(path_ref_owner(value))
}

fn origin_ref_module_key(value: OriginRef) -> Str {
    if origin_ref_is_symbol(value) {
        symbol_ref_origin_module_key(origin_ref_symbol(value))
    } else {
        path_ref_module_key(origin_ref_path(value))
    }
}

fn validate_origin_for_executable(
    origin: OriginRef, owner: ExecutableRef
) {
    if origin_ref_module_key(origin) != executable_ref_origin_module_key(owner) {
        panic("FlowIR: origin crosses executable module identity")
    }
}

fn type_ref_exists(values: List<FlowTypeNode>, target: FlowTypeRef) -> Bool {
    target.index >= 0 && target.index < values.len()
}

fn callable_index(
    values: List<FlowCallable>, target: ExecutableRef
) -> Int? {
    let mut index = 0
    for value in values {
        if executable_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn callable_for_ref(
    values: List<FlowCallable>, target: ExecutableRef
) -> FlowCallable {
    match callable_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: exact callable reference is absent")
    }
}

fn validate_callables(
    values: List<FlowCallable>, type_nodes: List<FlowTypeNode>
) {
    let mut left_index = 0
    while left_index < values.len() {
        let left = values.get(left_index).unwrap()
        validate_origin_for_executable(left.origin, left.reference)
        if !type_ref_exists(type_nodes, left.result_type) {
            panic("FlowIR: callable result type is absent")
        }
        if left.parameter_types.len() !=
           left.semantic_contract.parameter_roles.len() {
            panic("FlowIR: callable role vector is not total")
        }
        let concrete = flow_callable_mode_same(
            left.mode, flow_callable_mode_concrete_body())
        if (concrete &&
            left.parameter_slots.len() != left.parameter_types.len()) ||
           (!concrete && left.parameter_slots.len() != 0) {
            panic("FlowIR: callable parameter slot relation drifted")
        }
        let mut parameter_left = 0
        while parameter_left < left.parameter_slots.len() {
            let mut parameter_right = parameter_left + 1
            while parameter_right < left.parameter_slots.len() {
                if slot_ref_same(
                        left.parameter_slots.get(parameter_left).unwrap(),
                        left.parameter_slots.get(parameter_right).unwrap()) {
                    panic("FlowIR: callable parameter slots are not unique")
                }
                parameter_right = parameter_right + 1
            }
            parameter_left = parameter_left + 1
        }
        for ty in left.parameter_types {
            if !type_ref_exists(type_nodes, ty) {
                panic("FlowIR: callable parameter type is absent")
            }
        }
        for role in left.semantic_contract.parameter_roles {
            let _ = flow_semantic_role_tag(role)
        }
        let _ = flow_semantic_role_tag(left.semantic_contract.result_role)
        let _ = flow_callable_mode_from_tag(left.mode.tag)
        let mut right_index = left_index + 1
        while right_index < values.len() {
            if executable_ref_same(
                    left.reference, values.get(right_index).unwrap().reference) {
                panic("FlowIR: duplicate callable reference")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
}

fn scope_index(values: List<FlowScope>, target: FlowScopeRef) -> Int? {
    let mut index = 0
    for value in values {
        if flow_scope_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn scope_for_ref(values: List<FlowScope>, target: FlowScopeRef) -> FlowScope {
    match scope_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: scope reference is absent")
    }
}

fn validate_scopes(owner: ExecutableRef, values: List<FlowScope>) {
    if values.len() == 0 { panic("FlowIR: body has no root scope") }
    let mut ordinal = 0
    for value in values {
        if !executable_ref_same(value.reference.owner, owner) ||
           value.reference.ordinal != ordinal {
            panic("FlowIR: scope order/owner is not frozen")
        }
        if ordinal == 0 {
            if value.parent.is_some() {
                panic("FlowIR: root scope has a parent")
            }
        } else {
            let parent = match value.parent {
                some(parent) => parent,
                none => panic("FlowIR: non-root scope has no parent")
            }
            if !executable_ref_same(parent.owner, owner) ||
               parent.ordinal < 0 || parent.ordinal >= ordinal {
                panic("FlowIR: scope parent is not an earlier local scope")
            }
        }
        ordinal = ordinal + 1
    }
}

fn slot_index(values: List<FlowSlot>, target: SlotRef) -> Int? {
    let mut index = 0
    for value in values {
        if slot_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn slot_for_ref(values: List<FlowSlot>, target: SlotRef) -> FlowSlot {
    match slot_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: instruction references an undeclared slot")
    }
}

fn validate_slots(
    body: FlowBody, type_nodes: List<FlowTypeNode>
) {
    let binders = binder_manifest_entries(body.manifest)
    if binders.len() != body.slots.len() {
        panic("FlowIR: binder manifest/slot census differs")
    }
    let mut index = 0
    while index < body.slots.len() {
        let slot = body.slots.get(index).unwrap()
        let binder = binders.get(index).unwrap()
        if !slot_ref_same(slot.reference, binder_entry_slot(binder)) {
            panic("FlowIR: slot order differs from binder manifest")
        }
        if !type_ref_exists(type_nodes, slot.ty) {
            panic("FlowIR: slot type is absent")
        }
        if !executable_ref_same(slot.scope.owner, body.reference) ||
           scope_index(body.scopes, slot.scope).is_none() {
            panic("FlowIR: slot scope is absent or cross-body")
        }
        let _ = flow_initial_slot_state_from_tag(slot.initial_state.tag)
        let _ = flow_storage_class_from_tag(slot.storage.tag)
        let _ = flow_storage_contract_from_tag(slot.storage_contract.tag)
        if flow_storage_class_same(slot.storage, flow_storage_parameter()) {
            match slot.parameter_ordinal {
                some(parameter_ordinal) => {
                    if parameter_ordinal < 0 ||
                       slot.initial_state.tag != FLOW_SLOT_LIVE {
                        panic("FlowIR: parameter slot ordinal/state is invalid")
                    }
                },
                none => panic("FlowIR: parameter slot has no ordinal")
            }
        } else if slot.parameter_ordinal.is_some() {
            panic("FlowIR: non-parameter slot has an ordinal")
        }
        let mut right_index = index + 1
        while right_index < body.slots.len() {
            let right = body.slots.get(right_index).unwrap()
            if slot_ref_same(slot.reference, right.reference) {
                panic("FlowIR: duplicate frozen slot")
            }
            if flow_scope_ref_same(slot.scope, right.scope) &&
               slot.reverse_ordinal == right.reverse_ordinal {
                panic("FlowIR: duplicate reverse lexical slot ordinal")
            }
            right_index = right_index + 1
        }
        index = index + 1
    }
    // Reverse ordinals are dense per scope.  This makes cleanup order a finite
    // table rather than a backend spelling/order guess.
    for scope in body.scopes {
        let mut count = 0
        for slot in body.slots {
            if flow_scope_ref_same(slot.scope, scope.reference) {
                count = count + 1
            }
        }
        let mut expected = 0
        while expected < count {
            let mut matches = 0
            for slot in body.slots {
                if flow_scope_ref_same(slot.scope, scope.reference) &&
                   slot.reverse_ordinal == expected {
                    matches = matches + 1
                }
            }
            if matches != 1 {
                panic("FlowIR: reverse lexical slot order is not dense")
            }
            expected = expected + 1
        }
    }
}

fn validate_body_callable_parameters(body: FlowBody, callable: FlowCallable) {
    if callable.parameter_slots.len() != callable.parameter_types.len() {
        panic("FlowIR: concrete callable parameter relation is partial")
    }
    let mut ordinal = 0
    while ordinal < callable.parameter_slots.len() {
        let expected_slot = callable.parameter_slots.get(ordinal).unwrap()
        let expected_type = callable.parameter_types.get(ordinal).unwrap()
        let mut matches = 0
        for slot in body.slots {
            if flow_storage_class_same(slot.storage, flow_storage_parameter()) &&
               slot.parameter_ordinal == some(ordinal) {
                if !slot_ref_same(slot.reference, expected_slot) ||
                   !flow_type_ref_same(slot.ty, expected_type) {
                    panic("FlowIR: parameter ordinal slot/type relation drifted")
                }
                matches = matches + 1
            }
        }
        if matches != 1 {
            panic("FlowIR: parameter ordinal is missing or duplicated")
        }
        ordinal = ordinal + 1
    }
    for slot in body.slots {
        if flow_storage_class_same(slot.storage, flow_storage_parameter()) {
            let slot_ordinal = match slot.parameter_ordinal {
                some(value) => value,
                none => panic("FlowIR: parameter ordinal disappeared")
            }
            if slot_ordinal >= callable.parameter_slots.len() {
                panic("FlowIR: body has an extra parameter ordinal")
            }
        }
    }
}

fn block_index(values: List<FlowBlock>, target: FlowBlockRef) -> Int? {
    let mut index = 0
    for value in values {
        if flow_block_ref_same(value.reference, target) { return some(index) }
        index = index + 1
    }
    none
}

fn block_for_ref(values: List<FlowBlock>, target: FlowBlockRef) -> FlowBlock {
    match block_index(values, target) {
        some(index) => values.get(index).unwrap(),
        none => panic("FlowIR: successor block is absent")
    }
}

fn scope_lineage(
    scopes: List<FlowScope>, start: FlowScopeRef
) -> List<FlowScopeRef> {
    let mut result: List<FlowScopeRef> = []
    let mut current: FlowScopeRef? = some(start)
    while current.is_some() {
        let reference = current.unwrap()
        result.push(reference)
        let scope = scope_for_ref(scopes, reference)
        current = scope.parent
    }
    result
}

fn validate_exited_scope_prefix(
    lineage: List<FlowScopeRef>, exited: List<FlowScopeRef>
) {
    if exited.len() > lineage.len() {
        panic("FlowIR: edge exits more scopes than are active")
    }
    let mut index = 0
    while index < exited.len() {
        if !flow_scope_ref_same(
                exited.get(index).unwrap(), lineage.get(index).unwrap()) {
            panic("FlowIR: exited scopes are not inner-to-outer")
        }
        index = index + 1
    }
}

fn validate_successor(
    body: FlowBody, from_scope: FlowScopeRef, successor: FlowSuccessor
) {
    if !executable_ref_same(successor.target.owner, body.reference) {
        panic("FlowIR: successor crosses executable body")
    }
    let target_block = block_for_ref(body.blocks, successor.target)
    let lineage = scope_lineage(body.scopes, from_scope)
    validate_exited_scope_prefix(lineage, successor.exited_scopes)
    if successor.exited_scopes.len() >= lineage.len() {
        panic("FlowIR: non-terminal edge exits the root scope")
    }
    let remaining = lineage.get(successor.exited_scopes.len()).unwrap()
    if !flow_scope_ref_same(target_block.scope, remaining) {
        panic("FlowIR: successor target scope differs after exits")
    }
}

fn validate_terminal_exits(
    body: FlowBody, from_scope: FlowScopeRef, exited: List<FlowScopeRef>
) {
    let lineage = scope_lineage(body.scopes, from_scope)
    validate_exited_scope_prefix(lineage, exited)
    if exited.len() != lineage.len() {
        panic("FlowIR: terminal edge does not exit every active scope")
    }
}

fn validate_instruction_slots(body: FlowBody, instruction: FlowInstruction) {
    validate_origin_for_executable(instruction.origin, body.reference)
    match instruction.value {
        FlowInstructionValue::InitializeValue { inputs, target, .. } => {
            for input in inputs { let _ = slot_for_ref(body.slots, input) }
            let _ = slot_for_ref(body.slots, target)
        },
        FlowInstructionValue::ReadValue { source, target } => {
            let _ = slot_for_ref(body.slots, source)
            let _ = slot_for_ref(body.slots, target)
        },
        FlowInstructionValue::MutateValue {
            target, value, target_role, value_role
        } => {
            let _ = slot_for_ref(body.slots, target)
            let _ = slot_for_ref(body.slots, value)
            let _ = flow_semantic_role_tag(target_role)
            let _ = flow_semantic_role_tag(value_role)
        },
        FlowInstructionValue::ConsumeValue { source } |
        FlowInstructionValue::DiscardValue { source } => {
            let _ = slot_for_ref(body.slots, source)
        },
        FlowInstructionValue::AssignValue { rhs_temp, target } => {
            let rhs = slot_for_ref(body.slots, rhs_temp)
            let _ = slot_for_ref(body.slots, target)
            if !flow_storage_class_same(rhs.storage, flow_storage_temp()) {
                panic("FlowIR: Assign RHS is not an explicit temp slot")
            }
        },
        FlowInstructionValue::CallValue { target, arguments, result } => {
            for argument in arguments {
                let _ = slot_for_ref(body.slots, argument)
            }
            match result {
                some(slot) => { let _ = slot_for_ref(body.slots, slot) },
                none => {}
            }
            if flow_call_target_is_local(target) {
                let _ = slot_for_ref(body.slots, flow_call_target_local(target))
            } else if !flow_call_target_is_direct(target) {
                if path_ref_module_key(flow_call_target_dynamic(target)) !=
                   executable_ref_origin_module_key(body.reference) {
                    panic("FlowIR: dynamic call adapter crosses module")
                }
            }
        },
        FlowInstructionValue::ProjectValue { base, result, .. } => {
            let _ = slot_for_ref(body.slots, base)
            let _ = slot_for_ref(body.slots, result)
        },
        FlowInstructionValue::CaptureValue {
            capture, source, target, source_role, target_role
        } => {
            if path_ref_module_key(capture) !=
               executable_ref_origin_module_key(body.reference) {
                panic("FlowIR: capture path crosses executable module")
            }
            let _ = slot_for_ref(body.slots, source)
            let _ = slot_for_ref(body.slots, target)
            let _ = flow_semantic_role_tag(source_role)
            let _ = flow_semantic_role_tag(target_role)
        },
        FlowInstructionValue::ScopeEnterValue { scope } |
        FlowInstructionValue::ScopeExitValue { scope } => {
            if !executable_ref_same(scope.owner, body.reference) ||
               scope_index(body.scopes, scope).is_none() {
                panic("FlowIR: scope operation references an absent scope")
            }
        }
    }
}

fn advance_instruction_scope(
    body: FlowBody, current: FlowScopeRef, instruction: FlowInstruction
) -> FlowScopeRef {
    match instruction.value {
        FlowInstructionValue::ScopeEnterValue { scope } => {
            let entered = scope_for_ref(body.scopes, scope)
            let parent = match entered.parent {
                some(value) => value,
                none => panic("FlowIR: cannot enter the root scope")
            }
            if !flow_scope_ref_same(parent, current) {
                panic("FlowIR: scope enter is not a direct child")
            }
            scope
        },
        FlowInstructionValue::ScopeExitValue { scope } => {
            if !flow_scope_ref_same(scope, current) {
                panic("FlowIR: scope exit is not the active scope")
            }
            let exited = scope_for_ref(body.scopes, scope)
            match exited.parent {
                some(parent) => parent,
                none => panic("FlowIR: instruction cannot exit root scope")
            }
        },
        _ => current
    }
}

fn validate_terminator_slots(body: FlowBody, terminator: FlowTerminator) {
    validate_origin_for_executable(terminator.origin, body.reference)
    match terminator.value {
        FlowTerminatorValue::BranchValue { condition, .. } |
        FlowTerminatorValue::LoopValue { condition, .. } => {
            let _ = slot_for_ref(body.slots, condition)
        },
        FlowTerminatorValue::ReturnValue { value, .. } => match value {
            some(slot) => { let _ = slot_for_ref(body.slots, slot) },
            none => {}
        },
        FlowTerminatorValue::CatchValue { error, .. } => {
            let _ = slot_for_ref(body.slots, error)
        },
        FlowTerminatorValue::HandlerValue { operation, .. } => {
            let _ = slot_for_ref(body.slots, operation)
        },
        _ => {}
    }
}

fn validate_body_blocks(body: FlowBody) {
    if body.blocks.len() == 0 {
        panic("FlowIR: concrete body has no blocks")
    }
    if !flow_block_ref_same(body.entry, body.blocks.get(0).unwrap().reference) ||
       body.entry.ordinal != 0 {
        panic("FlowIR: entry is not the first stable block")
    }
    let mut ordinal = 0
    for block in body.blocks {
        if !executable_ref_same(block.reference.owner, body.reference) ||
           block.reference.ordinal != ordinal {
            panic("FlowIR: block order/owner is not frozen")
        }
        if scope_index(body.scopes, block.scope).is_none() {
            panic("FlowIR: block scope is absent")
        }
        validate_origin_for_executable(block.origin, body.reference)
        let mut instruction_ordinal = 0
        let mut active_scope = block.scope
        for instruction in block.instructions {
            if !executable_ref_same(
                    instruction.reference.owner, body.reference) ||
               instruction.reference.block_ordinal != ordinal ||
               instruction.reference.instruction_ordinal != instruction_ordinal {
                panic("FlowIR: instruction site/order drifted")
            }
            validate_instruction_slots(body, instruction)
            active_scope = advance_instruction_scope(
                body, active_scope, instruction)
            instruction_ordinal = instruction_ordinal + 1
        }
        validate_terminator_slots(body, block.terminator)
        for successor in terminator_successors(block.terminator) {
            validate_successor(body, active_scope, successor)
        }
        match terminator_terminal_exited_scopes(block.terminator) {
            some(exited) => validate_terminal_exits(body, active_scope, exited),
            none => {}
        }
        ordinal = ordinal + 1
    }
    // Reject dead blocks: the frozen topology is exactly the executable graph,
    // not a bag of future or backend-only alternatives.
    let mut reachable: List<FlowBlockRef> = [body.entry]
    let mut cursor = 0
    while cursor < reachable.len() {
        let current = reachable.get(cursor).unwrap()
        let block = block_for_ref(body.blocks, current)
        for successor in terminator_successors(block.terminator) {
            let mut present = false
            for seen in reachable {
                if flow_block_ref_same(seen, successor.target) {
                    present = true
                }
            }
            if !present { reachable.push(successor.target) }
        }
        cursor = cursor + 1
    }
    if reachable.len() != body.blocks.len() {
        panic("FlowIR: frozen body contains an unreachable block")
    }
}

fn validate_bodies(
    bodies: List<FlowBody>, callables: List<FlowCallable>,
    type_nodes: List<FlowTypeNode>
) {
    let mut expected_body_index = 0
    for callable in callables {
        if flow_callable_mode_same(
                callable.mode, flow_callable_mode_concrete_body()) {
            let body = match bodies.get(expected_body_index) {
                some(value) => value,
                none => panic("FlowIR: concrete callable body is missing")
            }
            if !executable_ref_same(callable.reference, body.reference) ||
               !origin_ref_same(callable.origin, body.origin) {
                panic("FlowIR: body order/identity differs from callable table")
            }
            validate_scopes(body.reference, body.scopes)
            validate_slots(body, type_nodes)
            validate_body_callable_parameters(body, callable)
            validate_body_blocks(body)
            expected_body_index = expected_body_index + 1
        }
    }
    if expected_body_index != bodies.len() {
        panic("FlowIR: body has no concrete callable contract")
    }
}

fn validate_direct_calls(
    bodies: List<FlowBody>, callables: List<FlowCallable>
) {
    for body in bodies {
        for edge in flow_body_call_edges(body) {
            let contract = edge.target.contract
            if edge.arguments.len() != contract.parameter_roles.len() {
                panic("FlowIR: call arguments/semantic contract arity differs")
            }
            for candidate_ref in edge.target.candidates {
                let candidate = callable_for_ref(callables, candidate_ref)
                if candidate.parameter_types.len() != edge.arguments.len() ||
                   !flow_call_contract_same(
                        candidate.semantic_contract, contract) {
                    panic("FlowIR: callable candidate contract differs")
                }
            }
            if flow_call_target_is_direct(edge.target) &&
               (edge.target.candidates.len() != 1 ||
                !executable_ref_same(
                    edge.target.candidates.get(0).unwrap(),
                    flow_call_target_direct(edge.target))) {
                panic("FlowIR: direct call candidate set differs from target")
            }
        }
    }
}

fn callable_contains_symbol(
    callables: List<FlowCallable>, symbol: SymbolRef
) -> Bool {
    for callable in callables {
        if executable_ref_is_named(callable.reference) &&
           symbol_ref_same(
                executable_ref_named_symbol(callable.reference), symbol) {
            return true
        }
    }
    false
}

fn validate_type_provider_contracts(
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>
) {
    for node in type_nodes {
        match node.drop_contract {
            some(contract) => {
                let _ = callable_for_ref(callables, contract.provider)
            },
            none => {}
        }
        match node.foreign_contract {
            some(contract) => match contract.value {
                FlowForeignContractValue::ManagedForeignValue {
                    retain, release
                } => {
                    let _ = callable_for_ref(callables, retain)
                    let _ = callable_for_ref(callables, release)
                },
                FlowForeignContractValue::BorrowedForeignValue => {}
            },
            none => {}
        }
    }
}

fn validate_operation_contracts(
    bodies: List<FlowBody>, callables: List<FlowCallable>
) {
    for body in bodies {
        for block in body.blocks {
            for instruction in block.instructions {
                match instruction.value {
                    FlowInstructionValue::InitializeValue {
                        operation, inputs, ..
                    } => {
                        if operation.input_roles.len() != inputs.len() {
                            panic("FlowIR: Initialize semantic contract is partial")
                        }
                        match operation.value {
                            FlowOperationValue::ConstructorOperationValue(
                                executable) |
                            FlowOperationValue::DictionaryOperationValue(
                                executable) => {
                                let callable = callable_for_ref(
                                    callables, executable)
                                if callable.parameter_types.len() != inputs.len() {
                                    panic("FlowIR: operation producer arity differs")
                                }
                            },
                            FlowOperationValue::IntrinsicOperationValue(intrinsic) => {
                                if !callable_contains_symbol(
                                        callables,
                                        intrinsic_ref_symbol(intrinsic)) {
                                    panic("FlowIR: intrinsic contract has no callable")
                                }
                            },
                            _ => {}
                        }
                    },
                    _ => {}
                }
            }
        }
    }
}

// ============================================================
// Deterministic topology fingerprint and frozen program
// ============================================================

fn encode_atom(value: Str) -> Str { "${value.len()}:${value}" }

fn encode_symbol(value: SymbolRef) -> Str {
    [
        "S",
        encode_atom(symbol_ref_origin_module_key(value)),
        namespace_kind_tag(symbol_ref_namespace_kind(value)).to_str(),
        encode_atom(symbol_ref_canonical_payload(value)),
        encode_atom(symbol_ref_declaration_site_path(value))
    ].join("/")
}

fn encode_path_owner(value: PathOwnerRef) -> Str {
    if path_owner_ref_is_symbol(value) {
        "OS/${encode_symbol(path_owner_ref_symbol(value))}"
    } else {
        let body = path_owner_ref_module_body(value)
        "OM/${encode_atom(module_body_ref_origin_module_key(body))}/${encode_atom(module_body_ref_declaration_site_path(body))}"
    }
}

fn encode_path(value: PathRef) -> Str {
    let mut parts: List<Str> = [
        "P", encode_path_owner(path_ref_owner(value)),
        path_role_tag(path_ref_role(value)).to_str()
    ]
    for component in path_ref_normalized_child_path(value) {
        parts.push(encode_atom(component))
    }
    parts.join("/")
}

fn encode_slot(value: SlotRef) -> Str {
    if slot_ref_is_source(value) {
        [
            "SL", encode_atom(slot_ref_source_origin_module_key(value)),
            slot_domain_tag(slot_ref_source_domain(value)).to_str(),
            slot_ref_source_def_id(value).to_str()
        ].join("/")
    } else {
        "SS/${encode_path(slot_ref_synthetic_path(value))}"
    }
}

fn encode_executable(value: ExecutableRef) -> Str {
    if executable_ref_is_named(value) {
        "EN/${encode_symbol(executable_ref_named_symbol(value))}"
    } else {
        "EA/${encode_path(executable_ref_anonymous_path(value))}"
    }
}

fn encode_origin(value: OriginRef) -> Str {
    if origin_ref_is_symbol(value) {
        "ON/${encode_symbol(origin_ref_symbol(value))}"
    } else {
        "OP/${encode_path(origin_ref_path(value))}"
    }
}

fn encode_type_ref(value: FlowTypeRef) -> Str { "T${value.index.to_str()}" }
fn encode_field_identity(value: FlowFieldIdentity) -> Str {
    match value.value {
        FlowFieldIdentityValue::NominalFieldIdentityValue(field) =>
            [
                "FN", encode_symbol(nominal_field_ref_owner(field)),
                encode_symbol(nominal_field_ref_member(field)),
                nominal_field_ref_index(field).to_str()
            ].join("/"),
        FlowFieldIdentityValue::PathFieldIdentityValue(path) =>
            "FP/${encode_path(path)}"
    }
}
fn encode_scope_ref(value: FlowScopeRef) -> Str {
    "Q/${encode_executable(value.owner)}/${value.ordinal.to_str()}"
}
fn encode_block_ref(value: FlowBlockRef) -> Str {
    "B/${encode_executable(value.owner)}/${value.ordinal.to_str()}"
}
fn encode_instruction_ref(value: FlowInstructionRef) -> Str {
    "I/${encode_executable(value.owner)}/${value.block_ordinal.to_str()}/${value.instruction_ordinal.to_str()}"
}

fn encode_call_target(value: FlowCallTarget) -> Str {
    let base = match value.value {
        FlowCallTargetValue::DirectTargetValue(target) =>
            "CD/${encode_executable(target)}",
        FlowCallTargetValue::LocalTargetValue(target) =>
            "CL/${encode_slot(target)}",
        FlowCallTargetValue::DynamicTargetValue(target) =>
            "CY/${encode_path(target)}"
    }
    let mut parts: List<Str> = [base]
    for role in value.contract.parameter_roles {
        parts.push("P${flow_semantic_role_tag(role).to_str()}")
    }
    parts.push("R${flow_semantic_role_tag(value.contract.result_role).to_str()}")
    for candidate in value.candidates {
        parts.push("C${encode_executable(candidate)}")
    }
    parts.join("/")
}

fn encode_operation(value: FlowOperationContract) -> Str {
    let mut parts: List<Str> = [
        "O${flow_operation_contract_kind_tag(value).to_str()}"
    ]
    match value.value {
        FlowOperationValue::IntLiteralOperationValue(literal) =>
            parts.push(literal.to_str()),
        FlowOperationValue::FloatLiteralOperationValue(literal) =>
            parts.push(literal.to_str()),
        FlowOperationValue::StrLiteralOperationValue(literal) =>
            parts.push(encode_atom(literal)),
        FlowOperationValue::BoolLiteralOperationValue(literal) =>
            parts.push(if literal { "true" } else { "false" }),
        FlowOperationValue::UnitLiteralOperationValue => parts.push("unit"),
        FlowOperationValue::PrimitiveOperationValue(operation) =>
            parts.push(flow_primitive_op_tag(operation).to_str()),
        FlowOperationValue::ConstructorOperationValue(executable) |
        FlowOperationValue::DictionaryOperationValue(executable) =>
            parts.push(encode_executable(executable)),
        FlowOperationValue::IntrinsicOperationValue(intrinsic) => {
            parts.push(builtin_method_site_tag(
                intrinsic_ref_site(intrinsic)).to_str())
            parts.push(encode_symbol(intrinsic_ref_symbol(intrinsic)))
        }
    }
    for role in value.input_roles {
        parts.push("P${flow_semantic_role_tag(role).to_str()}")
    }
    parts.push("R${flow_semantic_role_tag(value.target_role).to_str()}")
    parts.join("/")
}

fn encode_scope_refs(values: List<FlowScopeRef>) -> Str {
    let mut parts: List<Str> = []
    for value in values { parts.push(encode_scope_ref(value)) }
    parts.join(",")
}

fn encode_successor(value: FlowSuccessor) -> Str {
    "${encode_block_ref(value.target)}[${encode_scope_refs(value.exited_scopes)}]"
}

fn encode_instruction(value: FlowInstruction) -> Str {
    let mut parts: List<Str> = [
        encode_instruction_ref(value.reference),
        encode_origin(value.origin),
        flow_instruction_kind_tag(value).to_str()
    ]
    match value.value {
        FlowInstructionValue::InitializeValue { operation, inputs, target } => {
            parts.push(encode_operation(operation))
            for input in inputs { parts.push(encode_slot(input)) }
            parts.push(encode_slot(target))
        },
        FlowInstructionValue::ReadValue { source, target } => {
            parts.push(encode_slot(source)); parts.push(encode_slot(target))
        },
        FlowInstructionValue::MutateValue {
            target, value: input, target_role, value_role
        } => {
            parts.push(encode_slot(target)); parts.push(encode_slot(input))
            parts.push("T${flow_semantic_role_tag(target_role).to_str()}")
            parts.push("V${flow_semantic_role_tag(value_role).to_str()}")
        },
        FlowInstructionValue::ConsumeValue { source } |
        FlowInstructionValue::DiscardValue { source } =>
            parts.push(encode_slot(source)),
        FlowInstructionValue::AssignValue { rhs_temp, target } => {
            parts.push(encode_slot(rhs_temp)); parts.push(encode_slot(target))
        },
        FlowInstructionValue::CallValue { target, arguments, result } => {
            parts.push(encode_call_target(target))
            for argument in arguments { parts.push(encode_slot(argument)) }
            match result {
                some(slot) => parts.push(encode_slot(slot)),
                none => parts.push("void")
            }
        },
        FlowInstructionValue::ProjectValue {
            projection, base, result, partial
        } => {
            parts.push(encode_path(projection)); parts.push(encode_slot(base))
            parts.push(encode_slot(result))
            parts.push(if partial { "partial" } else { "total" })
        },
        FlowInstructionValue::CaptureValue {
            capture, source, target, source_role, target_role
        } => {
            parts.push(encode_path(capture)); parts.push(encode_slot(source))
            parts.push(encode_slot(target))
            parts.push("S${flow_semantic_role_tag(source_role).to_str()}")
            parts.push("T${flow_semantic_role_tag(target_role).to_str()}")
        },
        FlowInstructionValue::ScopeEnterValue { scope } |
        FlowInstructionValue::ScopeExitValue { scope } => {
            parts.push(encode_scope_ref(scope))
        }
    }
    parts.join(";")
}

fn encode_terminator(value: FlowTerminator) -> Str {
    let mut parts: List<Str> = [
        encode_origin(value.origin), flow_terminator_kind_tag(value).to_str()
    ]
    match value.value {
        FlowTerminatorValue::GotoValue(edge) |
        FlowTerminatorValue::BreakValue(edge) |
        FlowTerminatorValue::ContinueValue(edge) =>
            parts.push(encode_successor(edge)),
        FlowTerminatorValue::BranchValue {
            condition, when_true, when_false
        } => {
            parts.push(encode_slot(condition))
            parts.push(encode_successor(when_true))
            parts.push(encode_successor(when_false))
        },
        FlowTerminatorValue::LoopValue { condition, body, exit } => {
            parts.push(encode_slot(condition)); parts.push(encode_successor(body))
            parts.push(encode_successor(exit))
        },
        FlowTerminatorValue::ReturnValue { value: returned, exited_scopes } => {
            match returned {
                some(slot) => parts.push(encode_slot(slot)),
                none => parts.push("void")
            }
            parts.push(encode_scope_refs(exited_scopes))
        },
        FlowTerminatorValue::CatchValue { error, handled, propagate } => {
            parts.push(encode_slot(error)); parts.push(encode_successor(handled))
            parts.push(encode_successor(propagate))
        },
        FlowTerminatorValue::HandlerValue {
            operation, handled, unhandled
        } => {
            parts.push(encode_slot(operation))
            parts.push(encode_successor(handled))
            parts.push(encode_successor(unhandled))
        },
        FlowTerminatorValue::UnreachableValue { exited_scopes } |
        FlowTerminatorValue::DivergeValue { exited_scopes } =>
            parts.push(encode_scope_refs(exited_scopes))
    }
    parts.join(";")
}

fn compute_topology_encoding(
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>,
    bodies: List<FlowBody>
) -> Str {
    let mut parts: List<Str> = ["FlowIR/0.1"]
    for node in type_nodes {
        let mut item: List<Str> = [
            "TY", node.reference.index.to_str(),
            flow_type_kind_tag(node.kind).to_str(),
            node.parameter_count.to_str(),
            match node.generic_param {
                some(fact) => fact.index.to_str(),
                none => (0 - 1).to_str()
            }
        ]
        match node.nominal {
            some(symbol) => item.push(encode_symbol(symbol)),
            none => item.push("none")
        }
        item.push("S${flow_type_semantic_seed_tag(node.semantic_seed).to_str()}")
        for argument in node.generic_arguments {
            item.push("A${encode_type_ref(argument)}")
        }
        for child in node.children { item.push(encode_type_ref(child)) }
        for field in node.nominal_fields {
            item.push("F${encode_field_identity(field.identity)}/${encode_type_ref(field.ty)}")
        }
        match node.generic_param {
            some(fact) => {
                item.push("G${encode_symbol(fact.owner)}/${fact.index.to_str()}/${fact.arity.to_str()}")
                for bound in fact.bounds {
                    item.push("D${encode_symbol(bound)}")
                }
            },
            none => {}
        }
        match node.drop_contract {
            some(contract) => item.push(
                "X${encode_executable(contract.provider)}"),
            none => {}
        }
        match node.foreign_contract {
            some(contract) => match contract.value {
                FlowForeignContractValue::BorrowedForeignValue =>
                    item.push("FB"),
                FlowForeignContractValue::ManagedForeignValue {
                    retain, release
                } => item.push(
                    "FM/${encode_executable(retain)}/${encode_executable(release)}")
            },
            none => {}
        }
        parts.push(item.join(";"))
    }
    for callable in callables {
        let mut item: List<Str> = [
            "CA", encode_executable(callable.reference),
            encode_origin(callable.origin), callable.mode.tag.to_str()
        ]
        for parameter in callable.parameter_types {
            item.push(encode_type_ref(parameter))
        }
        let mut parameter_ordinal = 0
        for parameter_slot in callable.parameter_slots {
            item.push("Q${parameter_ordinal.to_str()}/${encode_slot(parameter_slot)}")
            parameter_ordinal = parameter_ordinal + 1
        }
        item.push("R${encode_type_ref(callable.result_type)}")
        for role in callable.semantic_contract.parameter_roles {
            item.push("L${flow_semantic_role_tag(role).to_str()}")
        }
        item.push("O${flow_semantic_role_tag(callable.semantic_contract.result_role).to_str()}")
        parts.push(item.join(";"))
    }
    for body in bodies {
        parts.push("BO/${encode_executable(body.reference)}/${encode_origin(body.origin)}")
        for scope in body.scopes {
            let parent = match scope.parent {
                some(value) => encode_scope_ref(value),
                none => "root"
            }
            parts.push("SC/${encode_scope_ref(scope.reference)}/${parent}")
        }
        for slot in body.slots {
            parts.push([
                "SL", encode_slot(slot.reference), encode_type_ref(slot.ty),
                encode_scope_ref(slot.scope), slot.reverse_ordinal.to_str(),
                slot.initial_state.tag.to_str(), slot.storage.tag.to_str(),
                slot.storage_contract.tag.to_str(),
                match slot.parameter_ordinal {
                    some(ordinal) => ordinal.to_str(),
                    none => (0 - 1).to_str()
                }
            ].join(";"))
        }
        for block in body.blocks {
            parts.push([
                "BL", encode_block_ref(block.reference),
                encode_origin(block.origin), encode_scope_ref(block.scope)
            ].join(";"))
            for instruction in block.instructions {
                parts.push(encode_instruction(instruction))
            }
            parts.push(encode_terminator(block.terminator))
        }
    }
    parts.join("|")
}

pub struct FlowTopologyFingerprint { canonical: Str }

pub fn flow_topology_fingerprint_same(
    left: FlowTopologyFingerprint, right: FlowTopologyFingerprint
) -> Bool { left.canonical == right.canonical }

pub fn flow_topology_fingerprint_canonical(
    value: FlowTopologyFingerprint
) -> Str { value.canonical }

pub struct FlowProgram {
    type_nodes: List<FlowTypeNode>,
    callables: List<FlowCallable>,
    bodies: List<FlowBody>,
    topology_fingerprint: FlowTopologyFingerprint
}

fn freeze_callables_with_edges(
    callables: List<FlowCallable>, bodies: List<FlowBody>
) -> List<FlowCallable> {
    let mut result: List<FlowCallable> = []
    for callable in callables {
        let edges = if flow_callable_mode_same(
                callable.mode, flow_callable_mode_concrete_body()) {
            let mut found: FlowBody? = none
            for body in bodies {
                if executable_ref_same(body.reference, callable.reference) {
                    found = some(body)
                }
            }
            match found {
                some(body) => flow_body_call_edges(body),
                none => panic("FlowIR: cannot derive concrete callable edges")
            }
        } else {
            []
        }
        result.push(FlowCallable {
            reference: callable.reference, origin: callable.origin,
            parameter_types: copy_type_refs(callable.parameter_types),
            parameter_slots: copy_slot_refs(callable.parameter_slots),
            result_type: callable.result_type, mode: callable.mode,
            semantic_contract: copy_call_contract(callable.semantic_contract),
            call_edges: copy_call_edges(edges)
        })
    }
    result
}

pub fn make_flow_program(
    type_nodes: List<FlowTypeNode>, callables: List<FlowCallable>,
    bodies: List<FlowBody>
) -> FlowProgram {
    validate_type_nodes(type_nodes)
    validate_callables(callables, type_nodes)
    validate_type_provider_contracts(type_nodes, callables)
    validate_bodies(bodies, callables, type_nodes)
    validate_direct_calls(bodies, callables)
    validate_operation_contracts(bodies, callables)
    let frozen_types = copy_type_nodes(type_nodes)
    let frozen_bodies = copy_bodies(bodies)
    let frozen_callables = freeze_callables_with_edges(callables, frozen_bodies)
    let fingerprint = FlowTopologyFingerprint {
        canonical: compute_topology_encoding(
            frozen_types, frozen_callables, frozen_bodies)
    }
    FlowProgram {
        type_nodes: frozen_types, callables: frozen_callables,
        bodies: frozen_bodies, topology_fingerprint: fingerprint
    }
}

pub fn flow_program_type_nodes(value: FlowProgram) -> List<FlowTypeNode> {
    copy_type_nodes(value.type_nodes)
}
pub fn flow_program_callables(value: FlowProgram) -> List<FlowCallable> {
    let mut result: List<FlowCallable> = []
    for callable in value.callables {
        result.push(FlowCallable {
            reference: callable.reference, origin: callable.origin,
            parameter_types: copy_type_refs(callable.parameter_types),
            parameter_slots: copy_slot_refs(callable.parameter_slots),
            result_type: callable.result_type, mode: callable.mode,
            semantic_contract: copy_call_contract(callable.semantic_contract),
            call_edges: copy_call_edges(callable.call_edges)
        })
    }
    result
}
pub fn flow_program_bodies(value: FlowProgram) -> List<FlowBody> {
    copy_bodies(value.bodies)
}
pub fn flow_program_topology_fingerprint(
    value: FlowProgram
) -> FlowTopologyFingerprint { value.topology_fingerprint }

pub fn validate_flow_program(value: FlowProgram) {
    // Reconstructing through the sole freeze barrier rejects any representation
    // drift and recomputes, rather than trusts, the topology fingerprint.
    let rebuilt = make_flow_program(
        value.type_nodes, value.callables.map(fn(callable) {
            make_flow_callable(
                callable.reference, callable.origin,
                callable.parameter_types, callable.parameter_slots,
                callable.result_type,
                callable.mode, callable.semantic_contract)
        }), value.bodies)
    if !flow_topology_fingerprint_same(
            rebuilt.topology_fingerprint, value.topology_fingerprint) {
        panic("FlowIR: frozen topology fingerprint drifted")
    }
}
