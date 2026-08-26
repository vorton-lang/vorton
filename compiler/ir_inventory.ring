// F1 inert compiler-wide executable and binder inventory.
//
// The current pipeline does not consume this module. All identities are typed
// inputs supplied by an upstream IR layer. F1 validates schema and local
// referential closure only; it does not claim that a current program was
// discovered, normalized, frozen, resource-planned, or verified.

use ir_identity::{
    SymbolRef, ModuleBodyRef, PathRef, PathOwnerRef, SlotRef,
    IntrinsicRef, ImplOwnerRef, ImplMethodRef, TraitMethodRef,
    HandledEffectRef, SystemEffectRef,
    PathRole, symbol_ref_same, symbol_ref_origin_module_key,
    origin_module_key_is_prelude,
    symbol_ref_namespace_kind, namespace_kind_from_tag, namespace_kind_same,
    namespace_member,
    handled_effect_ref_symbol, handled_effect_ref_same,
    system_effect_ref_same,
    module_body_ref_same, module_body_ref_origin_module_key,
    path_ref_same, path_ref_owner, path_ref_normalized_child_path,
    path_ref_role, path_owner_ref_same, path_owner_ref_is_symbol,
    path_owner_ref_symbol, path_owner_ref_module_body,
    make_path_ref, path_owner_for_symbol, path_role_parameter,
    make_source_slot_ref, make_synthetic_slot_ref, slot_domain_dictionary,
    slot_ref_same, slot_ref_is_source, slot_ref_synthetic_path,
    intrinsic_ref_same, impl_owner_ref_same,
    impl_method_ref_same, trait_method_ref_same,
    slot_ref_source_origin_module_key, slot_ref_source_domain,
    slot_ref_source_def_id, slot_domain_same, slot_domain_lexical,
    path_role_same, path_role_child,
    path_role_declaration, path_role_parameter, path_role_result, path_role_capture,
    path_role_handler, path_role_synthetic, path_role_from_tag
}

// ============================================================
// Executable identity
// ============================================================

enum ExecutableRefValue {
    NamedExecutableValue(SymbolRef),
    AnonymousExecutableValue(PathRef)
}

pub struct ExecutableRef {
    value: ExecutableRefValue
}

enum ExecutableParentValue {
    ModuleBodyParentValue(ModuleBodyRef),
    ExecutableParentValue(ExecutableRef)
}

pub struct ExecutableParentRef {
    value: ExecutableParentValue
}

pub fn make_module_body_parent(value: ModuleBodyRef) -> ExecutableParentRef {
    ExecutableParentRef {
        value: ExecutableParentValue::ModuleBodyParentValue(value)
    }
}

pub fn make_executable_parent(value: ExecutableRef) -> ExecutableParentRef {
    ExecutableParentRef {
        value: ExecutableParentValue::ExecutableParentValue(value)
    }
}

pub fn executable_parent_is_module_body(value: ExecutableParentRef) -> Bool {
    match value.value {
        ExecutableParentValue::ModuleBodyParentValue(_) => true,
        ExecutableParentValue::ExecutableParentValue(_) => false
    }
}

pub fn executable_parent_module_body(value: ExecutableParentRef) -> ModuleBodyRef {
    match value.value {
        ExecutableParentValue::ModuleBodyParentValue(body) => body,
        ExecutableParentValue::ExecutableParentValue(_) =>
            panic("IR inventory: executable parent has no ModuleBodyRef")
    }
}

pub fn executable_parent_executable(value: ExecutableParentRef) -> ExecutableRef {
    match value.value {
        ExecutableParentValue::ExecutableParentValue(executable) => executable,
        ExecutableParentValue::ModuleBodyParentValue(_) =>
            panic("IR inventory: module-body parent has no ExecutableRef")
    }
}

pub fn make_named_executable_ref(symbol: SymbolRef) -> ExecutableRef {
    ExecutableRef { value: ExecutableRefValue::NamedExecutableValue(symbol) }
}

pub fn make_anonymous_executable_ref(path: PathRef) -> ExecutableRef {
    ExecutableRef { value: ExecutableRefValue::AnonymousExecutableValue(path) }
}

pub fn make_module_body_executable_ref(
    module_body: ModuleBodyRef, path: PathRef
) -> ExecutableRef {
    let owner = path_ref_owner(path)
    if path_owner_ref_is_symbol(owner) ||
       !module_body_ref_same(path_owner_ref_module_body(owner), module_body) {
        panic("IR inventory: module body executable path has the wrong owner")
    }
    make_anonymous_executable_ref(path)
}

pub fn executable_ref_is_named(value: ExecutableRef) -> Bool {
    match value.value {
        ExecutableRefValue::NamedExecutableValue(_) => true,
        ExecutableRefValue::AnonymousExecutableValue(_) => false
    }
}

pub fn executable_ref_named_symbol(value: ExecutableRef) -> SymbolRef {
    match value.value {
        ExecutableRefValue::NamedExecutableValue(symbol) => symbol,
        ExecutableRefValue::AnonymousExecutableValue(_) =>
            panic("IR inventory: anonymous executable has no SymbolRef")
    }
}

pub fn executable_ref_anonymous_path(value: ExecutableRef) -> PathRef {
    match value.value {
        ExecutableRefValue::AnonymousExecutableValue(path) => path,
        ExecutableRefValue::NamedExecutableValue(_) =>
            panic("IR inventory: named executable has no PathRef")
    }
}

pub fn executable_ref_same(left: ExecutableRef, right: ExecutableRef) -> Bool {
    match (left.value, right.value) {
        (ExecutableRefValue::NamedExecutableValue(a),
         ExecutableRefValue::NamedExecutableValue(b)) => symbol_ref_same(a, b),
        (ExecutableRefValue::AnonymousExecutableValue(a),
         ExecutableRefValue::AnonymousExecutableValue(b)) => path_ref_same(a, b),
        _ => false
    }
}

// ============================================================
// Exact dictionary-evidence identity
// ============================================================

// TypedHIR may retain source spellings for diagnostics.  This is the sole
// spelling-free identity that may cross the Core freeze barrier: locals name
// their exact binder slot, static dictionaries name their exact value symbol,
// and a residual wrapper recursively names its exact base/trait/inputs.
enum ExactDictRefValue {
    LocalDictValue(SlotRef),
    StaticDictValue(ImplOwnerRef),
    WrappedDictValue {
        base: ImplOwnerRef,
        inner: List<ExactDictRef>
    }
}

pub struct ExactDictRef { value: ExactDictRefValue }

pub fn make_exact_local_dict_ref(slot: SlotRef) -> ExactDictRef {
    ExactDictRef { value: ExactDictRefValue::LocalDictValue(slot) }
}

pub fn make_parameter_dict_ref(
    owner: ExecutableRef, ordinal: Int
) -> ExactDictRef {
    if ordinal < 0 {
        panic("IR inventory: negative dictionary parameter ordinal")
    }
    let (path_owner, prefix) = match owner.value {
        ExecutableRefValue::NamedExecutableValue(symbol) =>
            (path_owner_for_symbol(symbol), []),
        ExecutableRefValue::AnonymousExecutableValue(path) =>
            (path_ref_owner(path), path_ref_normalized_child_path(path))
    }
    let mut child = prefix.map(fn(item) { item })
    child.push("dictionary-evidence:${ordinal.to_str()}")
    make_exact_local_dict_ref(make_synthetic_slot_ref(make_path_ref(
        path_owner, child, path_role_parameter())))
}

pub fn make_dictionary_local_dict_ref(
    module_key: Str, def_id: Int
) -> ExactDictRef {
    if def_id >= 0 {
        panic("IR inventory: dictionary local lacks synthetic DefId")
    }
    make_exact_local_dict_ref(make_source_slot_ref(
        module_key, slot_domain_dictionary(), def_id))
}

pub fn make_exact_static_dict_ref(reference: ImplOwnerRef) -> ExactDictRef {
    ExactDictRef { value: ExactDictRefValue::StaticDictValue(reference) }
}

pub fn make_exact_wrapped_dict_ref(
    base: ImplOwnerRef, inner: List<ExactDictRef>
) -> ExactDictRef {
    ExactDictRef { value: ExactDictRefValue::WrappedDictValue {
        base: base,
        inner: inner.map(fn(value) { copy_exact_dict_ref(value) })
    } }
}

fn copy_exact_dict_ref(value: ExactDictRef) -> ExactDictRef {
    match value.value {
        ExactDictRefValue::LocalDictValue(slot) => make_exact_local_dict_ref(slot),
        ExactDictRefValue::StaticDictValue(reference) =>
            make_exact_static_dict_ref(reference),
        ExactDictRefValue::WrappedDictValue { base, inner } =>
            make_exact_wrapped_dict_ref(base, inner)
    }
}

pub fn dict_ref_is_local(value: ExactDictRef) -> Bool {
    match value.value {
        ExactDictRefValue::LocalDictValue(_) => true,
        _ => false
    }
}

pub fn dict_ref_is_static(value: ExactDictRef) -> Bool {
    match value.value {
        ExactDictRefValue::StaticDictValue(_) => true,
        _ => false
    }
}

pub fn dict_ref_is_wrapped(value: ExactDictRef) -> Bool {
    match value.value {
        ExactDictRefValue::WrappedDictValue { .. } => true,
        _ => false
    }
}

pub fn dict_ref_local(value: ExactDictRef) -> SlotRef {
    match value.value {
        ExactDictRefValue::LocalDictValue(slot) => slot,
        _ => panic("IR inventory: dictionary evidence is not local")
    }
}

pub fn dict_ref_static(value: ExactDictRef) -> ImplOwnerRef {
    match value.value {
        ExactDictRefValue::StaticDictValue(reference) => reference,
        _ => panic("IR inventory: dictionary evidence is not static")
    }
}

pub fn dict_ref_wrapped_base(value: ExactDictRef) -> ImplOwnerRef {
    match value.value {
        ExactDictRefValue::WrappedDictValue { base, .. } => base,
        _ => panic("IR inventory: dictionary evidence is not wrapped")
    }
}

pub fn dict_ref_wrapped_inner(value: ExactDictRef) -> List<ExactDictRef> {
    match value.value {
        ExactDictRefValue::WrappedDictValue { inner, .. } =>
            inner.map(fn(item) { copy_exact_dict_ref(item) }),
        _ => panic("IR inventory: dictionary evidence is not wrapped")
    }
}

pub fn dict_ref_same(left: ExactDictRef, right: ExactDictRef) -> Bool {
    match (left.value, right.value) {
        (ExactDictRefValue::LocalDictValue(a),
         ExactDictRefValue::LocalDictValue(b)) => slot_ref_same(a, b),
        (ExactDictRefValue::StaticDictValue(a),
         ExactDictRefValue::StaticDictValue(b)) => impl_owner_ref_same(a, b),
        (ExactDictRefValue::WrappedDictValue {
            base: left_base, inner: left_inner
         }, ExactDictRefValue::WrappedDictValue {
            base: right_base, inner: right_inner
         }) => {
            if !impl_owner_ref_same(left_base, right_base) ||
               left_inner.len() != right_inner.len() {
                return false
            }
            let mut index = 0
            while index < left_inner.len() {
                if !dict_ref_same(
                        left_inner.get(index).unwrap(),
                        right_inner.get(index).unwrap()) {
                    return false
                }
                index = index + 1
            }
            true
        },
        _ => false
    }
}

// Exact method selection deliberately carries no callable signature.  The
// single canonical call contract owns parameter/result/effect information.
enum ExactMethodRefValue {
    IntrinsicMethodValue(IntrinsicRef),
    ImplMethodValue(ImplMethodRef),
    TraitMethodValue(TraitMethodRef)
}

pub struct ExactMethodRef { value: ExactMethodRefValue }

pub fn make_exact_intrinsic_method_ref(value: IntrinsicRef) -> ExactMethodRef {
    ExactMethodRef { value: ExactMethodRefValue::IntrinsicMethodValue(value) }
}

pub fn make_exact_impl_method_ref(value: ImplMethodRef) -> ExactMethodRef {
    ExactMethodRef { value: ExactMethodRefValue::ImplMethodValue(value) }
}

pub fn make_exact_trait_method_ref(value: TraitMethodRef) -> ExactMethodRef {
    ExactMethodRef { value: ExactMethodRefValue::TraitMethodValue(value) }
}

pub fn exact_method_ref_is_intrinsic(value: ExactMethodRef) -> Bool {
    match value.value {
        ExactMethodRefValue::IntrinsicMethodValue(_) => true,
        _ => false
    }
}

pub fn exact_method_ref_is_impl(value: ExactMethodRef) -> Bool {
    match value.value {
        ExactMethodRefValue::ImplMethodValue(_) => true,
        _ => false
    }
}

pub fn exact_method_ref_is_trait(value: ExactMethodRef) -> Bool {
    match value.value {
        ExactMethodRefValue::TraitMethodValue(_) => true,
        _ => false
    }
}

pub fn exact_method_ref_intrinsic(value: ExactMethodRef) -> IntrinsicRef {
    match value.value {
        ExactMethodRefValue::IntrinsicMethodValue(reference) => reference,
        _ => panic("IR inventory: method selection is not intrinsic")
    }
}

pub fn exact_method_ref_impl(value: ExactMethodRef) -> ImplMethodRef {
    match value.value {
        ExactMethodRefValue::ImplMethodValue(reference) => reference,
        _ => panic("IR inventory: method selection is not an impl method")
    }
}

pub fn exact_method_ref_trait(value: ExactMethodRef) -> TraitMethodRef {
    match value.value {
        ExactMethodRefValue::TraitMethodValue(reference) => reference,
        _ => panic("IR inventory: method selection is not a trait method")
    }
}

pub fn exact_method_ref_same(left: ExactMethodRef, right: ExactMethodRef) -> Bool {
    match (left.value, right.value) {
        (ExactMethodRefValue::IntrinsicMethodValue(a),
         ExactMethodRefValue::IntrinsicMethodValue(b)) =>
            intrinsic_ref_same(a, b),
        (ExactMethodRefValue::ImplMethodValue(a),
         ExactMethodRefValue::ImplMethodValue(b)) =>
            impl_method_ref_same(a, b),
        (ExactMethodRefValue::TraitMethodValue(a),
         ExactMethodRefValue::TraitMethodValue(b)) =>
            trait_method_ref_same(a, b),
        _ => false
    }
}

fn path_owner_origin_module_key(owner: PathOwnerRef) -> Str {
    if path_owner_ref_is_symbol(owner) {
        symbol_ref_origin_module_key(path_owner_ref_symbol(owner))
    } else {
        module_body_ref_origin_module_key(path_owner_ref_module_body(owner))
    }
}

pub fn executable_ref_origin_module_key(value: ExecutableRef) -> Str {
    match value.value {
        ExecutableRefValue::NamedExecutableValue(symbol) =>
            symbol_ref_origin_module_key(symbol),
        ExecutableRefValue::AnonymousExecutableValue(path) =>
            path_owner_origin_module_key(path_ref_owner(path))
    }
}

pub fn executable_ref_is_prelude(value: ExecutableRef) -> Bool {
    origin_module_key_is_prelude(executable_ref_origin_module_key(value))
}

// Ownership-neutral callable ABI facts. The producer fixes these at the same
// point as an intrinsic/extern identity; Flow maps them to its semantic roles
// without consulting a runtime name or replaying backend policy.
const RESOURCE_ROLE_READ: Int = 0
const RESOURCE_ROLE_MUTATE: Int = 1
const RESOURCE_ROLE_CONSUME: Int = 2
const RESOURCE_ROLE_FORCE: Int = 3

pub struct CallableResourceRoleFact { tag: Int }
pub fn callable_resource_role_from_tag(tag: Int) -> CallableResourceRoleFact {
    if tag < RESOURCE_ROLE_READ || tag > RESOURCE_ROLE_FORCE {
        panic("IR inventory: invalid callable resource role")
    }
    CallableResourceRoleFact { tag: tag }
}
pub fn callable_resource_role_read() -> CallableResourceRoleFact {
    callable_resource_role_from_tag(RESOURCE_ROLE_READ)
}
pub fn callable_resource_role_mutate() -> CallableResourceRoleFact {
    callable_resource_role_from_tag(RESOURCE_ROLE_MUTATE)
}
pub fn callable_resource_role_consume() -> CallableResourceRoleFact {
    callable_resource_role_from_tag(RESOURCE_ROLE_CONSUME)
}
pub fn callable_resource_role_force() -> CallableResourceRoleFact {
    callable_resource_role_from_tag(RESOURCE_ROLE_FORCE)
}
pub fn callable_resource_role_tag(value: CallableResourceRoleFact) -> Int {
    callable_resource_role_from_tag(value.tag).tag
}

pub struct CallableResourceContractFact {
    parameter_roles: List<CallableResourceRoleFact>,
    result_role: CallableResourceRoleFact,
    result_alias_ordinals: List<Int>
}
pub fn make_callable_resource_contract_fact(
    parameter_roles: List<CallableResourceRoleFact>,
    result_role: CallableResourceRoleFact,
    result_alias_ordinals: List<Int>
) -> CallableResourceContractFact {
    let mut roles: List<CallableResourceRoleFact> = []
    for role in parameter_roles {
        roles.push(callable_resource_role_from_tag(
            callable_resource_role_tag(role)))
    }
    let mut aliases: List<Int> = []
    for ordinal in result_alias_ordinals {
        if ordinal < 0 || ordinal >= roles.len() || aliases.contains(ordinal) {
            panic("IR inventory: callable result alias set is invalid")
        }
        aliases.push(ordinal)
    }
    CallableResourceContractFact {
        parameter_roles: roles,
        result_role: callable_resource_role_from_tag(
            callable_resource_role_tag(result_role)),
        result_alias_ordinals: aliases
    }
}
pub fn callable_resource_contract_parameter_roles(
    value: CallableResourceContractFact
) -> List<CallableResourceRoleFact> {
    value.parameter_roles.map(fn(role) {
        callable_resource_role_from_tag(callable_resource_role_tag(role))
    })
}
pub fn callable_resource_contract_result_role(
    value: CallableResourceContractFact
) -> CallableResourceRoleFact { value.result_role }
pub fn callable_resource_contract_result_alias_ordinals(
    value: CallableResourceContractFact
) -> List<Int> { value.result_alias_ordinals.map(fn(value) { value }) }

pub fn callable_resource_contract_same(
    left: CallableResourceContractFact,
    right: CallableResourceContractFact
) -> Bool {
    let left_roles = callable_resource_contract_parameter_roles(left)
    let right_roles = callable_resource_contract_parameter_roles(right)
    let left_aliases = left.result_alias_ordinals
    let right_aliases = right.result_alias_ordinals
    if left_roles.len() != right_roles.len() ||
       callable_resource_role_tag(left.result_role) !=
           callable_resource_role_tag(right.result_role) ||
       left_aliases.len() != right_aliases.len() {
        return false
    }
    let mut index = 0
    while index < left_roles.len() {
        if callable_resource_role_tag(left_roles.get(index).unwrap()) !=
           callable_resource_role_tag(right_roles.get(index).unwrap()) {
            return false
        }
        index = index + 1
    }
    index = 0
    while index < left_aliases.len() {
        if left_aliases.get(index).unwrap() !=
           right_aliases.get(index).unwrap() { return false }
        index = index + 1
    }
    true
}

pub struct EffectOperationRef {
    handled_effect: HandledEffectRef,
    member: SymbolRef,
    source_op_index: Int,
    callable: ExecutableRef
}

pub fn make_effect_operation_ref(
    handled_effect: HandledEffectRef, member: SymbolRef,
    source_op_index: Int, callable: ExecutableRef
) -> EffectOperationRef {
    let effect_symbol = handled_effect_ref_symbol(handled_effect)
    if source_op_index < 0 || !namespace_kind_same(
            symbol_ref_namespace_kind(member), namespace_member()) ||
       symbol_ref_origin_module_key(member) !=
            symbol_ref_origin_module_key(effect_symbol) ||
       !executable_ref_is_named(callable) ||
       !symbol_ref_same(executable_ref_named_symbol(callable), member) {
        panic("IR inventory: invalid handled effect operation relation")
    }
    EffectOperationRef {
        handled_effect: handled_effect, member: member,
        source_op_index: source_op_index, callable: callable
    }
}
pub fn effect_operation_ref_effect(
    value: EffectOperationRef
) -> HandledEffectRef { value.handled_effect }
pub fn effect_operation_ref_member(value: EffectOperationRef) -> SymbolRef {
    value.member
}
pub fn effect_operation_ref_source_index(value: EffectOperationRef) -> Int {
    value.source_op_index
}
pub fn effect_operation_ref_callable(
    value: EffectOperationRef
) -> ExecutableRef { value.callable }
pub fn effect_operation_ref_same(
    left: EffectOperationRef, right: EffectOperationRef
) -> Bool {
    handled_effect_ref_same(left.handled_effect, right.handled_effect) &&
        symbol_ref_same(left.member, right.member) &&
        left.source_op_index == right.source_op_index &&
        executable_ref_same(left.callable, right.callable)
}

// Host capability calls are a disjoint AbiIR-bound relation.  They can never
// be constructed as a handled effect operation or enter evidence.
pub struct SystemHostCallableRef {
    system_effect: SystemEffectRef,
    callable: ExecutableRef
}
pub fn make_system_host_callable_ref(
    system_effect: SystemEffectRef, callable: ExecutableRef
) -> SystemHostCallableRef {
    if !executable_ref_is_named(callable) {
        panic("IR inventory: system host callable is not named")
    }
    SystemHostCallableRef {
        system_effect: system_effect, callable: callable
    }
}
pub fn system_host_callable_effect(
    value: SystemHostCallableRef
) -> SystemEffectRef { value.system_effect }
pub fn system_host_callable_executable(
    value: SystemHostCallableRef
) -> ExecutableRef { value.callable }
pub fn system_host_callable_same(
    left: SystemHostCallableRef, right: SystemHostCallableRef
) -> Bool {
    system_effect_ref_same(left.system_effect, right.system_effect) &&
        executable_ref_same(left.callable, right.callable)
}

fn string_path_has_prefix(path: List<Str>, prefix: List<Str>) -> Bool {
    if path.len() < prefix.len() { return false }
    let mut index = 0
    while index < prefix.len() {
        match (path.get(index), prefix.get(index)) {
            (some(actual), some(expected)) => if actual != expected {
                return false
            },
            _ => return false
        }
        index = index + 1
    }
    true
}

fn path_is_direct_child_of_executable(
    executable: ExecutableRef, path: PathRef
) -> Bool {
    match executable.value {
        ExecutableRefValue::NamedExecutableValue(symbol) => {
            let owner = path_ref_owner(path)
            path_owner_ref_is_symbol(owner) &&
                symbol_ref_same(path_owner_ref_symbol(owner), symbol) &&
                path_ref_normalized_child_path(path).len() == 1
        },
        ExecutableRefValue::AnonymousExecutableValue(root) => {
            let root_path = path_ref_normalized_child_path(root)
            let child_path = path_ref_normalized_child_path(path)
            path_owner_ref_same(path_ref_owner(root), path_ref_owner(path)) &&
                child_path.len() == root_path.len() + 1 &&
                string_path_has_prefix(child_path, root_path)
        }
    }
}

fn executable_ref_contains_path(
    executable: ExecutableRef, path: PathRef
) -> Bool {
    match executable.value {
        ExecutableRefValue::NamedExecutableValue(symbol) => {
            let owner = path_ref_owner(path)
            path_owner_ref_is_symbol(owner) &&
                symbol_ref_same(path_owner_ref_symbol(owner), symbol) &&
                path_ref_normalized_child_path(path).len() > 0
        },
        ExecutableRefValue::AnonymousExecutableValue(root) => {
            let root_path = path_ref_normalized_child_path(root)
            let child_path = path_ref_normalized_child_path(path)
            path_owner_ref_same(path_ref_owner(root), path_ref_owner(path)) &&
                child_path.len() > root_path.len() &&
                string_path_has_prefix(child_path, root_path)
        }
    }
}

// ============================================================
// Exhaustive executable kind and two-mode contract
// ============================================================

const EXECUTABLE_FN: Int = 0
const EXECUTABLE_IMPL_METHOD: Int = 1
const EXECUTABLE_TRAIT_DEFAULT: Int = 2
const EXECUTABLE_TEST: Int = 3
const EXECUTABLE_CONST_INITIALIZER: Int = 4
const EXECUTABLE_MODULE_BODY: Int = 5
const EXECUTABLE_LAMBDA: Int = 6
const EXECUTABLE_HANDLER: Int = 7
const EXECUTABLE_DEFAULT_SPECIALIZATION: Int = 8
const EXECUTABLE_DERIVED_IMPL: Int = 9
const EXECUTABLE_CONSTRUCTOR: Int = 10
const EXECUTABLE_DICT_HELPER: Int = 11
const EXECUTABLE_CONST_GETTER: Int = 12
const EXECUTABLE_DROP_GLUE: Int = 13
const EXECUTABLE_BODYLESS_TRAIT_MEMBER: Int = 14
const EXECUTABLE_BODYLESS_EFFECT_OPERATION: Int = 15
const EXECUTABLE_BODYLESS_INTERFACE_MEMBER: Int = 16
const EXECUTABLE_EXTERN_FN: Int = 17
const EXECUTABLE_EXTERN_BRIDGE: Int = 18
const EXECUTABLE_BUILTIN_INTRINSIC: Int = 19
const EXECUTABLE_KIND_COUNT: Int = 20

const CONTRACT_CONCRETE_BODY: Int = 0
const CONTRACT_ONLY: Int = 1
const CONTRACT_MODE_COUNT: Int = 2

// 0 permits ConcreteBody, 1 permits ContractOnly, and 2 permits both.
// Generated origins permit both because CoreHIR may elaborate a real body.
const EXECUTABLE_KIND_ALLOWED_MODE_TAGS: List<Int> = [
    0, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 0, 2, 2,
    1, 1, 1, 1,
    2, 2
]

const REF_FORM_NAMED: Int = 0
const REF_FORM_ANONYMOUS: Int = 1
const EXECUTABLE_KIND_REF_FORM_TAGS: List<Int> = [
    0, 0, 0, 1, 0, 1, 1, 1, 1,
    0, 0, 1, 0, 0,
    0, 0, 0, 0,
    0, 0
]

// Namespace tag 5 and path-role tag 7 are table-local sentinels for the
// opposite ref form; they are never converted to a typed identity tag.
const EXECUTABLE_KIND_NAMESPACE_TAGS: List<Int> = [
    0, 4, 4, 5, 0, 5, 5, 5, 5,
    4, 0, 5, 0, 4,
    4, 4, 4, 0,
    0, 0
]
const EXECUTABLE_KIND_PATH_ROLE_TAGS: List<Int> = [
    7, 7, 7, 0, 7, 0, 1, 5, 1,
    7, 7, 6, 7, 7,
    7, 7, 7, 7,
    7, 7
]
const EXECUTABLE_KIND_PARENT_FORM_TAGS: List<Int> = [
    0, 0, 0, 0, 0, 0, 1, 1, 1,
    0, 0, 2, 0, 0,
    0, 0, 0, 0,
    0, 0
]

pub struct ExecutableKind { tag: Int }

pub fn executable_kind_from_tag(tag: Int) -> ExecutableKind {
    if tag < EXECUTABLE_FN || tag >= EXECUTABLE_KIND_COUNT {
        panic("IR inventory: invalid executable kind")
    }
    ExecutableKind { tag: tag }
}

pub fn executable_kind_tag(value: ExecutableKind) -> Int {
    executable_kind_from_tag(value.tag).tag
}

pub fn executable_kind_same(
    left: ExecutableKind, right: ExecutableKind
) -> Bool {
    executable_kind_tag(left) == executable_kind_tag(right)
}

pub fn executable_kind_fn() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_FN) }
pub fn executable_kind_impl_method() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_IMPL_METHOD) }
pub fn executable_kind_trait_default() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_TRAIT_DEFAULT) }
pub fn executable_kind_test() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_TEST) }
pub fn executable_kind_const_initializer() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_CONST_INITIALIZER) }
pub fn executable_kind_module_body() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_MODULE_BODY) }
pub fn executable_kind_lambda() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_LAMBDA) }
pub fn executable_kind_handler() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_HANDLER) }
pub fn executable_kind_default_specialization() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_DEFAULT_SPECIALIZATION) }
pub fn executable_kind_derived_impl() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_DERIVED_IMPL) }
pub fn executable_kind_constructor() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_CONSTRUCTOR) }
pub fn executable_kind_dict_helper() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_DICT_HELPER) }
pub fn executable_kind_const_getter() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_CONST_GETTER) }
pub fn executable_kind_drop_glue() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_DROP_GLUE) }
pub fn executable_kind_bodyless_trait_member() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_BODYLESS_TRAIT_MEMBER) }
pub fn executable_kind_bodyless_effect_operation() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_BODYLESS_EFFECT_OPERATION) }
pub fn executable_kind_bodyless_interface_member() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_BODYLESS_INTERFACE_MEMBER) }
pub fn executable_kind_extern_fn() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_EXTERN_FN) }
pub fn executable_kind_extern_bridge() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_EXTERN_BRIDGE) }
pub fn executable_kind_builtin_intrinsic() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_BUILTIN_INTRINSIC) }

pub struct ExecutableContractMode { tag: Int }

fn executable_contract_mode_from_tag(tag: Int) -> ExecutableContractMode {
    if tag < CONTRACT_CONCRETE_BODY || tag >= CONTRACT_MODE_COUNT {
        panic("IR inventory: invalid executable contract mode")
    }
    ExecutableContractMode { tag: tag }
}

pub fn executable_contract_mode_concrete_body() -> ExecutableContractMode {
    executable_contract_mode_from_tag(CONTRACT_CONCRETE_BODY)
}

pub fn executable_contract_mode_contract_only() -> ExecutableContractMode {
    executable_contract_mode_from_tag(CONTRACT_ONLY)
}

pub fn executable_contract_mode_same(
    left: ExecutableContractMode, right: ExecutableContractMode
) -> Bool { left.tag == right.tag }

enum ExecutableContractValue {
    ConcreteBodyValue(PathRef),
    ContractOnlyValue
}

pub struct ExecutableContract { value: ExecutableContractValue }

pub fn make_concrete_body_contract(body_path: PathRef) -> ExecutableContract {
    ExecutableContract { value: ExecutableContractValue::ConcreteBodyValue(body_path) }
}

pub fn make_contract_only() -> ExecutableContract {
    ExecutableContract { value: ExecutableContractValue::ContractOnlyValue }
}

pub fn executable_contract_mode(value: ExecutableContract) -> ExecutableContractMode {
    match value.value {
        ExecutableContractValue::ConcreteBodyValue(_) =>
            executable_contract_mode_concrete_body(),
        ExecutableContractValue::ContractOnlyValue =>
            executable_contract_mode_contract_only()
    }
}

pub fn executable_contract_body_path(value: ExecutableContract) -> PathRef {
    match value.value {
        ExecutableContractValue::ConcreteBodyValue(path) => path,
        ExecutableContractValue::ContractOnlyValue =>
            panic("IR inventory: ContractOnly has no body PathRef")
    }
}

fn executable_kind_allows_mode(
    kind: ExecutableKind, mode: ExecutableContractMode
) -> Bool {
    let tag = executable_kind_tag(kind)
    match EXECUTABLE_KIND_ALLOWED_MODE_TAGS.get(tag) {
        some(allowed) => allowed == 2 || allowed == mode.tag,
        none => panic("IR inventory: executable kind mode table is incomplete")
    }
}

fn executable_kind_expected_ref_form(kind: ExecutableKind) -> Int {
    match EXECUTABLE_KIND_REF_FORM_TAGS.get(executable_kind_tag(kind)) {
        some(form) => form,
        none => panic("IR inventory: executable kind ref table is incomplete")
    }
}

fn executable_kind_expected_namespace(kind: ExecutableKind) -> Int {
    match EXECUTABLE_KIND_NAMESPACE_TAGS.get(executable_kind_tag(kind)) {
        some(tag) => tag,
        none => panic("IR inventory: executable kind namespace table is incomplete")
    }
}

fn executable_kind_expected_path_role(kind: ExecutableKind) -> PathRole {
    match EXECUTABLE_KIND_PATH_ROLE_TAGS.get(executable_kind_tag(kind)) {
        some(tag) => if tag < 7 { path_role_from_tag(tag) } else {
            panic("IR inventory: named executable has no anonymous path role")
        },
        none => panic("IR inventory: executable kind path-role table is incomplete")
    }
}

fn executable_kind_allows_parent_form(
    kind: ExecutableKind, parent: ExecutableParentRef
) -> Bool {
    let actual = if executable_parent_is_module_body(parent) { 0 } else { 1 }
    match EXECUTABLE_KIND_PARENT_FORM_TAGS.get(executable_kind_tag(kind)) {
        some(expected) => expected == 2 || expected == actual,
        none => panic("IR inventory: executable parent-form table is incomplete")
    }
}


pub struct ExecutableEntry {
    reference: ExecutableRef,
    parent: ExecutableParentRef,
    kind: ExecutableKind,
    contract: ExecutableContract
}

fn executable_parent_matches_reference(
    reference: ExecutableRef, parent: ExecutableParentRef
) -> Bool {
    if executable_parent_is_module_body(parent) {
        let module_body = executable_parent_module_body(parent)
        if executable_ref_origin_module_key(reference) !=
           module_body_ref_origin_module_key(module_body) {
            return false
        }
        if executable_ref_is_named(reference) { return true }
        let path = executable_ref_anonymous_path(reference)
        let owner = path_ref_owner(path)
        return !path_owner_ref_is_symbol(owner) &&
            module_body_ref_same(
                path_owner_ref_module_body(owner), module_body) &&
            path_ref_normalized_child_path(path).len() == 1
    }
    let executable_parent = executable_parent_executable(parent)
    !executable_ref_is_named(reference) &&
        path_is_direct_child_of_executable(
            executable_parent, executable_ref_anonymous_path(reference))
}

pub fn make_executable_entry(
    reference: ExecutableRef, parent: ExecutableParentRef,
    kind: ExecutableKind,
    contract: ExecutableContract
) -> ExecutableEntry {
    let mode = executable_contract_mode(contract)
    if !executable_kind_allows_mode(kind, mode) {
        panic("IR inventory: executable kind/body contract mismatch")
    }
    let expected_form = executable_kind_expected_ref_form(kind)
    let actual_form = if executable_ref_is_named(reference) {
        REF_FORM_NAMED
    } else {
        REF_FORM_ANONYMOUS
    }
    if expected_form != actual_form {
        panic("IR inventory: executable kind/ref form mismatch")
    }
    if !executable_kind_allows_parent_form(kind, parent) {
        panic("IR inventory: executable kind/parent form mismatch")
    }
    if !executable_parent_matches_reference(reference, parent) {
        panic("IR inventory: executable immediate parent mismatch")
    }
    if executable_ref_is_named(reference) {
        let expected_namespace = namespace_kind_from_tag(
            executable_kind_expected_namespace(kind))
        if !namespace_kind_same(
                symbol_ref_namespace_kind(executable_ref_named_symbol(reference)),
                expected_namespace) {
            panic("IR inventory: executable kind/namespace mismatch")
        }
    } else {
        let path = executable_ref_anonymous_path(reference)
        if !path_role_same(
                path_ref_role(path), executable_kind_expected_path_role(kind)) {
            panic("IR inventory: executable kind/path role mismatch")
        }
    }
    if executable_kind_same(kind, executable_kind_module_body()) {
        if !executable_parent_is_module_body(parent) {
            panic("IR inventory: ModuleBody kind has a non-module parent")
        }
        let path = executable_ref_anonymous_path(reference)
        if path_owner_ref_is_symbol(path_ref_owner(path)) {
            panic("IR inventory: ModuleBody kind has a symbol-owned path")
        }
    }
    if executable_kind_same(kind, executable_kind_test()) &&
       !executable_parent_is_module_body(parent) {
        panic("IR inventory: Test kind has a non-module parent")
    }
    if executable_contract_mode_same(
            mode, executable_contract_mode_concrete_body()) {
        let body_path = executable_contract_body_path(contract)
        if !path_role_same(path_ref_role(body_path), path_role_child()) ||
           !path_is_direct_child_of_executable(reference, body_path) {
            panic("IR inventory: ConcreteBody is not an exact direct child")
        }
    }
    if executable_contract_mode_same(
            mode, executable_contract_mode_contract_only()) &&
       !executable_ref_is_named(reference) {
        panic("IR inventory: anonymous executable cannot be ContractOnly")
    }
    ExecutableEntry {
        reference: reference, parent: parent, kind: kind, contract: contract
    }
}

pub fn executable_entry_reference(value: ExecutableEntry) -> ExecutableRef { value.reference }
pub fn executable_entry_parent(value: ExecutableEntry) -> ExecutableParentRef { value.parent }
pub fn executable_entry_kind(value: ExecutableEntry) -> ExecutableKind { value.kind }
pub fn executable_entry_contract(value: ExecutableEntry) -> ExecutableContract { value.contract }

fn copy_executable_entries(values: List<ExecutableEntry>) -> List<ExecutableEntry> {
    let mut result: List<ExecutableEntry> = []
    for value in values { result.push(value) }
    result
}

pub struct ExecutableInventory { entries: List<ExecutableEntry> }

pub fn make_executable_inventory(entries: List<ExecutableEntry>) -> ExecutableInventory {
    let mut left_index = 0
    while left_index < entries.len() {
        let left = entries.get(left_index).unwrap()
        let mut right_index = left_index + 1
        while right_index < entries.len() {
            let right = entries.get(right_index).unwrap()
            if executable_ref_same(left.reference, right.reference) {
                panic("IR inventory: duplicate executable reference")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    ExecutableInventory { entries: copy_executable_entries(entries) }
}

pub fn executable_inventory_count(value: ExecutableInventory) -> Int {
    value.entries.len()
}

pub fn executable_inventory_entries(value: ExecutableInventory) -> List<ExecutableEntry> {
    copy_executable_entries(value.entries)
}

// ============================================================
// Exhaustive binder manifest
// ============================================================

const BINDER_SOURCE_PARAM: Int = 0
const BINDER_LET: Int = 1
const BINDER_VAR: Int = 2
const BINDER_FOR: Int = 3
const BINDER_DESTRUCTURE: Int = 4
const BINDER_MATCH_PATTERN: Int = 5
const BINDER_IF_LET_PATTERN: Int = 6
const BINDER_CATCH_PATTERN: Int = 7
const BINDER_LAMBDA_PARAM: Int = 8
const BINDER_HANDLER_PARAM: Int = 9
const BINDER_HANDLER_RESUME: Int = 10
const BINDER_LAMBDA_CAPTURE: Int = 11
const BINDER_DICTIONARY_EVIDENCE_LOCAL: Int = 12
const BINDER_GENERATED_SYNTHETIC_PARAMETER: Int = 13
const BINDER_LAMBDA_VALUE: Int = 14
const BINDER_CALL_RESULT: Int = 15
const BINDER_PRE_ANF: Int = 16
const BINDER_PATTERN_PROJECTION: Int = 17
const BINDER_SCOPE_RESULT: Int = 18
const BINDER_CONTROL_RESULT: Int = 19
const BINDER_ASSIGN_TEMP: Int = 20
const BINDER_HANDLED_EVIDENCE_PARAM: Int = 21
const BINDER_HANDLED_EVIDENCE_LOCAL: Int = 22
const BINDER_HANDLED_EVIDENCE_CAPTURE: Int = 23
const BINDER_DICTIONARY_EVIDENCE_PARAM: Int = 24
const BINDER_KIND_COUNT: Int = 25

const BINDER_KIND_PATH_ROLE_TAGS: List<Int> = [
    2, 0, 0, 0, 0, 0, 0, 0, 2, 5, 5,
    4, 0, 2, 1, 3, 6, 1, 3, 3, 6,
    2, 5, 4, 2
]

pub struct BinderKind { tag: Int }

pub fn binder_kind_from_tag(tag: Int) -> BinderKind {
    if tag < BINDER_SOURCE_PARAM || tag >= BINDER_KIND_COUNT {
        panic("IR inventory: invalid binder kind")
    }
    BinderKind { tag: tag }
}

pub fn binder_kind_tag(value: BinderKind) -> Int {
    binder_kind_from_tag(value.tag).tag
}

pub fn binder_kind_source_param() -> BinderKind { binder_kind_from_tag(BINDER_SOURCE_PARAM) }
pub fn binder_kind_let() -> BinderKind { binder_kind_from_tag(BINDER_LET) }
pub fn binder_kind_var() -> BinderKind { binder_kind_from_tag(BINDER_VAR) }
pub fn binder_kind_for() -> BinderKind { binder_kind_from_tag(BINDER_FOR) }
pub fn binder_kind_destructure() -> BinderKind { binder_kind_from_tag(BINDER_DESTRUCTURE) }
pub fn binder_kind_match_pattern() -> BinderKind { binder_kind_from_tag(BINDER_MATCH_PATTERN) }
pub fn binder_kind_if_let_pattern() -> BinderKind { binder_kind_from_tag(BINDER_IF_LET_PATTERN) }
pub fn binder_kind_catch_pattern() -> BinderKind { binder_kind_from_tag(BINDER_CATCH_PATTERN) }
pub fn binder_kind_lambda_param() -> BinderKind { binder_kind_from_tag(BINDER_LAMBDA_PARAM) }
pub fn binder_kind_handler_param() -> BinderKind { binder_kind_from_tag(BINDER_HANDLER_PARAM) }
pub fn binder_kind_handler_resume() -> BinderKind { binder_kind_from_tag(BINDER_HANDLER_RESUME) }
pub fn binder_kind_lambda_capture() -> BinderKind { binder_kind_from_tag(BINDER_LAMBDA_CAPTURE) }
pub fn binder_kind_dictionary_evidence_local() -> BinderKind { binder_kind_from_tag(BINDER_DICTIONARY_EVIDENCE_LOCAL) }
pub fn binder_kind_generated_synthetic_parameter() -> BinderKind { binder_kind_from_tag(BINDER_GENERATED_SYNTHETIC_PARAMETER) }
pub fn binder_kind_lambda_value() -> BinderKind { binder_kind_from_tag(BINDER_LAMBDA_VALUE) }
pub fn binder_kind_call_result() -> BinderKind { binder_kind_from_tag(BINDER_CALL_RESULT) }
pub fn binder_kind_pre_anf() -> BinderKind { binder_kind_from_tag(BINDER_PRE_ANF) }
pub fn binder_kind_pattern_projection() -> BinderKind { binder_kind_from_tag(BINDER_PATTERN_PROJECTION) }
pub fn binder_kind_scope_result() -> BinderKind { binder_kind_from_tag(BINDER_SCOPE_RESULT) }
pub fn binder_kind_control_result() -> BinderKind { binder_kind_from_tag(BINDER_CONTROL_RESULT) }
pub fn binder_kind_assign_temp() -> BinderKind { binder_kind_from_tag(BINDER_ASSIGN_TEMP) }
pub fn binder_kind_handled_evidence_param() -> BinderKind {
    binder_kind_from_tag(BINDER_HANDLED_EVIDENCE_PARAM)
}
pub fn binder_kind_handled_evidence_local() -> BinderKind {
    binder_kind_from_tag(BINDER_HANDLED_EVIDENCE_LOCAL)
}
pub fn binder_kind_handled_evidence_capture() -> BinderKind {
    binder_kind_from_tag(BINDER_HANDLED_EVIDENCE_CAPTURE)
}
pub fn binder_kind_dictionary_evidence_param() -> BinderKind {
    binder_kind_from_tag(BINDER_DICTIONARY_EVIDENCE_PARAM)
}

fn binder_kind_is_handled_evidence(kind: BinderKind) -> Bool {
    let tag = binder_kind_tag(kind)
    tag == BINDER_HANDLED_EVIDENCE_PARAM ||
        tag == BINDER_HANDLED_EVIDENCE_LOCAL ||
        tag == BINDER_HANDLED_EVIDENCE_CAPTURE
}

fn binder_kind_is_source(kind: BinderKind) -> Bool {
    let tag = binder_kind_tag(kind)
    tag <= BINDER_HANDLER_RESUME || tag == BINDER_DICTIONARY_EVIDENCE_LOCAL
}

fn binder_kind_expected_path_role(kind: BinderKind) -> PathRole {
    match BINDER_KIND_PATH_ROLE_TAGS.get(binder_kind_tag(kind)) {
        some(0) => path_role_declaration(),
        some(1) => path_role_child(),
        some(2) => path_role_parameter(),
        some(3) => path_role_result(),
        some(4) => path_role_capture(),
        some(5) => path_role_handler(),
        some(6) => path_role_synthetic(),
        some(_) => panic("IR inventory: binder has an invalid site role"),
        none => panic("IR inventory: binder role table is incomplete")
    }
}

pub struct BinderEntry {
    slot: SlotRef,
    owner: ExecutableRef,
    kind: BinderKind,
    site: PathRef
}

// Source binders are emitted by the typed semantic producer before FlowIR
// allocates administrative slots.  Ordinary declarations use a non-negative
// lexical DefId; dictionary-lowering locals use a negative DefId in the
// dedicated dictionary domain.  Both forms must agree with the exact
// executable owner and structural site; neither names nor spans can recover
// this relation later.
pub fn make_source_binder_entry(
    slot: SlotRef, owner: ExecutableRef, kind: BinderKind, site: PathRef
) -> BinderEntry {
    if !binder_kind_is_source(kind) {
        panic("IR inventory: source binder uses synthetic/admin kind")
    }
    if !slot_ref_is_source(slot) {
        panic("IR inventory: source binder lacks source SlotRef")
    }
    let lexical = slot_ref_source_def_id(slot) >= 0 &&
        slot_domain_same(slot_ref_source_domain(slot), slot_domain_lexical())
    let dictionary = slot_ref_source_def_id(slot) < 0 &&
        slot_domain_same(slot_ref_source_domain(slot), slot_domain_dictionary()) &&
        binder_kind_tag(kind) ==
            binder_kind_tag(binder_kind_dictionary_evidence_local())
    if !lexical && !dictionary {
        panic("IR inventory: source binder has invalid lexical/dictionary SlotRef")
    }
    if slot_ref_source_origin_module_key(slot) !=
           executable_ref_origin_module_key(owner) ||
       slot_ref_source_origin_module_key(slot) !=
           path_owner_origin_module_key(path_ref_owner(site)) ||
       !executable_ref_contains_path(owner, site) {
        panic("IR inventory: source binder site crosses executable/module")
    }
    if !path_role_same(
            path_ref_role(site), binder_kind_expected_path_role(kind)) {
        panic("IR inventory: source binder site role mismatch")
    }
    BinderEntry { slot: slot, owner: owner, kind: kind, site: site }
}

// Flow lowering alone creates normalized synthetic/admin binders.
pub fn make_synthetic_binder_entry(
    slot: SlotRef, owner: ExecutableRef, kind: BinderKind, site: PathRef
) -> BinderEntry {
    if binder_kind_is_handled_evidence(kind) {
        panic("IR inventory: handled evidence requires semantic binder constructor")
    }
    if binder_kind_is_source(kind) {
        panic("IR inventory: source BinderEntry activation is deferred")
    }
    if slot_ref_is_source(slot) {
        panic("IR inventory: synthetic binder uses source SlotRef")
    }
    if !executable_ref_contains_path(owner, site) {
        panic("IR inventory: binder site crosses executable owner")
    }
    if !path_role_same(
            path_ref_role(site), binder_kind_expected_path_role(kind)) {
        panic("IR inventory: binder site role mismatch")
    }
    if !path_ref_same(slot_ref_synthetic_path(slot), site) {
        panic("IR inventory: synthetic binder slot/site mismatch")
    }
    BinderEntry { slot: slot, owner: owner, kind: kind, site: site }
}

// Hidden handled evidence is semantic Core input but has no source spelling
// or source DefId.  This narrow constructor is the only pre-Flow authority
// allowed to pair a deterministic synthetic SlotRef with the three evidence
// binder domains.
pub fn make_semantic_evidence_binder(
    slot: SlotRef, owner: ExecutableRef, kind: BinderKind, site: PathRef
) -> BinderEntry {
    if !binder_kind_is_handled_evidence(kind) || slot_ref_is_source(slot) ||
       !executable_ref_contains_path(owner, site) ||
       !path_role_same(
            path_ref_role(site), binder_kind_expected_path_role(kind)) ||
       !path_ref_same(slot_ref_synthetic_path(slot), site) {
        panic("IR inventory: invalid semantic handled-evidence binder")
    }
    BinderEntry { slot: slot, owner: owner, kind: kind, site: site }
}

pub fn binder_entry_slot(value: BinderEntry) -> SlotRef { value.slot }
pub fn binder_entry_owner(value: BinderEntry) -> ExecutableRef { value.owner }
pub fn binder_entry_kind(value: BinderEntry) -> BinderKind { value.kind }
pub fn binder_entry_site(value: BinderEntry) -> PathRef { value.site }

pub struct HandledEvidenceRef {
    requirement: HandledEffectRef,
    binding: BinderEntry,
    contract_owner: ExecutableRef,
    ordinal: Int
}

pub fn make_handled_evidence_ref(
    requirement: HandledEffectRef, binding: BinderEntry,
    contract_owner: ExecutableRef, ordinal: Int
) -> HandledEvidenceRef {
    if ordinal < 0 || !binder_kind_is_handled_evidence(binding.kind) ||
       !executable_ref_same(binding.owner, contract_owner) {
        panic("IR inventory: invalid handled evidence contract binding")
    }
    HandledEvidenceRef {
        requirement: requirement, binding: binding,
        contract_owner: contract_owner, ordinal: ordinal
    }
}

pub fn handled_evidence_requirement(
    value: HandledEvidenceRef
) -> HandledEffectRef { value.requirement }
pub fn handled_evidence_binding(
    value: HandledEvidenceRef
) -> BinderEntry { value.binding }
pub fn handled_evidence_slot(value: HandledEvidenceRef) -> SlotRef {
    value.binding.slot
}
pub fn handled_evidence_contract_owner(
    value: HandledEvidenceRef
) -> ExecutableRef { value.contract_owner }
pub fn handled_evidence_ordinal(value: HandledEvidenceRef) -> Int {
    value.ordinal
}
pub fn handled_evidence_ref_same(
    left: HandledEvidenceRef, right: HandledEvidenceRef
) -> Bool {
    handled_effect_ref_same(left.requirement, right.requirement) &&
        slot_ref_same(left.binding.slot, right.binding.slot) &&
        executable_ref_same(left.contract_owner, right.contract_owner) &&
        left.ordinal == right.ordinal &&
        path_ref_same(left.binding.site, right.binding.site)
}

pub struct HandledEvidenceCapture {
    requirement: HandledEffectRef,
    source: HandledEvidenceRef,
    target: HandledEvidenceRef
}

pub fn make_handled_evidence_capture(
    requirement: HandledEffectRef,
    source: HandledEvidenceRef, target: HandledEvidenceRef
) -> HandledEvidenceCapture {
    if !handled_effect_ref_same(
            requirement, source.requirement) ||
       !handled_effect_ref_same(requirement, target.requirement) ||
       binder_kind_tag(target.binding.kind) !=
            BINDER_HANDLED_EVIDENCE_CAPTURE ||
       slot_ref_same(source.binding.slot, target.binding.slot) {
        panic("IR inventory: invalid handled evidence capture")
    }
    HandledEvidenceCapture {
        requirement: requirement, source: source, target: target }
}

pub fn handled_evidence_capture_requirement(
    value: HandledEvidenceCapture
) -> HandledEffectRef { value.requirement }
pub fn handled_evidence_capture_source(
    value: HandledEvidenceCapture
) -> HandledEvidenceRef { value.source }
pub fn handled_evidence_capture_target(
    value: HandledEvidenceCapture
) -> HandledEvidenceRef { value.target }

fn copy_binder_entries(values: List<BinderEntry>) -> List<BinderEntry> {
    let mut result: List<BinderEntry> = []
    for value in values { result.push(value) }
    result
}

pub struct BinderManifest {
    owner: ExecutableRef,
    entries: List<BinderEntry>
}

pub fn make_binder_manifest(
    owner: ExecutableRef, entries: List<BinderEntry>
) -> BinderManifest {
    let mut left_index = 0
    while left_index < entries.len() {
        let left = entries.get(left_index).unwrap()
        if !executable_ref_same(left.owner, owner) {
            panic("IR inventory: binder manifest entry crosses owner")
        }
        let mut right_index = left_index + 1
        while right_index < entries.len() {
            let right = entries.get(right_index).unwrap()
            if slot_ref_same(left.slot, right.slot) {
                panic("IR inventory: duplicate binder slot")
            }
            right_index = right_index + 1
        }
        left_index = left_index + 1
    }
    BinderManifest { owner: owner, entries: copy_binder_entries(entries) }
}

pub fn binder_manifest_owner(value: BinderManifest) -> ExecutableRef { value.owner }
pub fn binder_manifest_entries(value: BinderManifest) -> List<BinderEntry> {
    copy_binder_entries(value.entries)
}
pub fn binder_manifest_count(value: BinderManifest) -> Int { value.entries.len() }

fn copy_binder_manifests(values: List<BinderManifest>) -> List<BinderManifest> {
    let mut result: List<BinderManifest> = []
    for value in values { result.push(value) }
    result
}

// ============================================================
// Collection-complete local referential closure
// ============================================================

pub struct IrInventoryClosure {
    inventory: ExecutableInventory,
    manifests: List<BinderManifest>
}

fn inventory_contains_ref(
    inventory: ExecutableInventory, target: ExecutableRef
) -> Bool {
    for entry in inventory.entries {
        if executable_ref_same(entry.reference, target) { return true }
    }
    false
}

fn manifest_count_for_owner(
    manifests: List<BinderManifest>, owner: ExecutableRef
) -> Int {
    let mut count = 0
    for manifest in manifests {
        if executable_ref_same(manifest.owner, owner) { count = count + 1 }
    }
    count
}

fn manifest_for_owner(
    manifests: List<BinderManifest>, owner: ExecutableRef
) -> BinderManifest {
    for manifest in manifests {
        if executable_ref_same(manifest.owner, owner) { return manifest }
    }
    panic("IR inventory: required binder manifest is missing")
}

fn manifests_have_duplicate_slot(manifests: List<BinderManifest>) -> Bool {
    let mut seen: List<SlotRef> = []
    for manifest in manifests {
        for entry in manifest.entries {
            for existing in seen {
                if slot_ref_same(existing, entry.slot) { return true }
            }
            seen.push(entry.slot)
        }
    }
    false
}

fn executable_parent_is_registered(
    inventory: ExecutableInventory, entry: ExecutableEntry
) -> Bool {
    if executable_parent_is_module_body(entry.parent) { return true }
    let parent_ref = executable_parent_executable(entry.parent)
    for candidate in inventory.entries {
        if executable_ref_same(candidate.reference, parent_ref) {
            return executable_contract_mode_same(
                executable_contract_mode(candidate.contract),
                executable_contract_mode_concrete_body())
        }
    }
    false
}

fn executable_ref_depth(value: ExecutableRef) -> Int {
    if executable_ref_is_named(value) { return 0 }
    path_ref_normalized_child_path(executable_ref_anonymous_path(value)).len()
}

fn binder_site_has_nearest_registered_owner(
    inventory: ExecutableInventory, binder: BinderEntry
) -> Bool {
    if !inventory_contains_ref(inventory, binder.owner) ||
       !executable_ref_contains_path(binder.owner, binder.site) {
        return false
    }
    let owner_depth = executable_ref_depth(binder.owner)
    for candidate in inventory.entries {
        if executable_ref_contains_path(candidate.reference, binder.site) &&
           executable_ref_depth(candidate.reference) > owner_depth {
            return false
        }
    }
    true
}

pub fn close_ir_inventory(
    inventory: ExecutableInventory, manifests: List<BinderManifest>
) -> IrInventoryClosure {
    if manifests.len() != inventory.entries.len() {
        panic("IR inventory: executable/manifest census differs")
    }
    if manifests_have_duplicate_slot(manifests) {
        panic("IR inventory: binder slot is shared across manifests")
    }
    for entry in inventory.entries {
        if !executable_parent_is_registered(inventory, entry) {
            panic("IR inventory: executable immediate parent is absent or bodyless")
        }
        if manifest_count_for_owner(manifests, entry.reference) != 1 {
            panic("IR inventory: executable lacks one unique binder manifest")
        }
        let manifest = manifest_for_owner(manifests, entry.reference)
        for binder in manifest.entries {
            if !binder_site_has_nearest_registered_owner(inventory, binder) {
                panic("IR inventory: binder site owner is not nearest registered executable")
            }
        }
        if executable_contract_mode_same(
                executable_contract_mode(entry.contract),
                executable_contract_mode_contract_only()) &&
           manifest.entries.len() != 0 {
            panic("IR inventory: ContractOnly executable has body-local binders")
        }
    }
    for manifest in manifests {
        if !inventory_contains_ref(inventory, manifest.owner) {
            panic("IR inventory: binder manifest owner is absent")
        }
    }
    IrInventoryClosure {
        inventory: make_executable_inventory(inventory.entries),
        manifests: copy_binder_manifests(manifests)
    }
}

pub fn ir_inventory_closure_inventory(
    value: IrInventoryClosure
) -> ExecutableInventory {
    make_executable_inventory(value.inventory.entries)
}

pub fn ir_inventory_closure_manifests(
    value: IrInventoryClosure
) -> List<BinderManifest> {
    copy_binder_manifests(value.manifests)
}
