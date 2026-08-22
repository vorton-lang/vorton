// F1 inert compiler-wide executable and binder inventory.
//
// The current pipeline does not consume this module. All identities are typed
// inputs supplied by an upstream IR layer. F1 validates schema and local
// referential closure only; it does not claim that a current program was
// discovered, normalized, frozen, resource-planned, or verified.

use ir_identity::{
    SymbolRef, ModuleBodyRef, PathRef, PathOwnerRef, SlotRef,
    PathRole, symbol_ref_same, symbol_ref_origin_module_key,
    symbol_ref_namespace_kind, namespace_kind_from_tag, namespace_kind_same,
    module_body_ref_same, module_body_ref_origin_module_key,
    path_ref_same, path_ref_owner, path_ref_normalized_child_path,
    path_ref_role, path_owner_ref_same, path_owner_ref_is_symbol,
    path_owner_ref_symbol, path_owner_ref_module_body,
    slot_ref_same, slot_ref_is_source, slot_ref_synthetic_path,
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
const EXECUTABLE_EFFECT_DEFAULT: Int = 3
const EXECUTABLE_TEST: Int = 4
const EXECUTABLE_CONST_INITIALIZER: Int = 5
const EXECUTABLE_MODULE_BODY: Int = 6
const EXECUTABLE_LAMBDA: Int = 7
const EXECUTABLE_HANDLER: Int = 8
const EXECUTABLE_DEFAULT_SPECIALIZATION: Int = 9
const EXECUTABLE_DERIVED_IMPL: Int = 10
const EXECUTABLE_CONSTRUCTOR: Int = 11
const EXECUTABLE_DICT_HELPER: Int = 12
const EXECUTABLE_CONST_GETTER: Int = 13
const EXECUTABLE_DROP_GLUE: Int = 14
const EXECUTABLE_BODYLESS_TRAIT_MEMBER: Int = 15
const EXECUTABLE_BODYLESS_EFFECT_OPERATION: Int = 16
const EXECUTABLE_BODYLESS_INTERFACE_MEMBER: Int = 17
const EXECUTABLE_EXTERN_FN: Int = 18
const EXECUTABLE_DELEGATE: Int = 19
const EXECUTABLE_EXTERN_BRIDGE: Int = 20
const EXECUTABLE_BUILTIN_INTRINSIC: Int = 21
const EXECUTABLE_KIND_COUNT: Int = 22

const CONTRACT_CONCRETE_BODY: Int = 0
const CONTRACT_ONLY: Int = 1
const CONTRACT_MODE_COUNT: Int = 2

// 0 permits ConcreteBody, 1 permits ContractOnly, and 2 permits both.
// Generated origins permit both because CoreHIR may elaborate a real body.
const EXECUTABLE_KIND_ALLOWED_MODE_TAGS: List<Int> = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 0, 2, 2,
    1, 1, 1, 1,
    0, 2, 2
]

const REF_FORM_NAMED: Int = 0
const REF_FORM_ANONYMOUS: Int = 1
const EXECUTABLE_KIND_REF_FORM_TAGS: List<Int> = [
    0, 0, 0, 0, 1, 0, 1, 1, 1, 1,
    0, 0, 1, 0, 0,
    0, 0, 0, 0,
    0, 0, 0
]

// Namespace tag 5 and path-role tag 7 are table-local sentinels for the
// opposite ref form; they are never converted to a typed identity tag.
const EXECUTABLE_KIND_NAMESPACE_TAGS: List<Int> = [
    0, 4, 4, 4, 5, 0, 5, 5, 5, 5,
    4, 0, 5, 0, 4,
    4, 4, 4, 0,
    4, 0, 0
]
const EXECUTABLE_KIND_PATH_ROLE_TAGS: List<Int> = [
    7, 7, 7, 7, 0, 7, 0, 1, 5, 1,
    7, 7, 6, 7, 7,
    7, 7, 7, 7,
    7, 7, 7
]
const EXECUTABLE_KIND_PARENT_FORM_TAGS: List<Int> = [
    0, 0, 0, 0, 0, 0, 0, 1, 1, 1,
    0, 0, 2, 0, 0,
    0, 0, 0, 0,
    0, 0, 0
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
pub fn executable_kind_effect_default() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_EFFECT_DEFAULT) }
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
pub fn executable_kind_delegate() -> ExecutableKind { executable_kind_from_tag(EXECUTABLE_DELEGATE) }
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
const BINDER_KIND_COUNT: Int = 21

const BINDER_KIND_PATH_ROLE_TAGS: List<Int> = [
    2, 0, 0, 0, 0, 0, 0, 0, 2, 5, 5,
    4, 0, 2, 1, 3, 6, 1, 3, 3, 6
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

// Source binder kinds remain an exhaustive declarative census, but F1 cannot
// relate a source SlotRef to its structural site and executable owner.  Their
// activation waits for one atomic typed producer in F2.  Consequently the
// only public F1 constructor accepts normalized synthetic binders.
pub fn make_synthetic_binder_entry(
    slot: SlotRef, owner: ExecutableRef, kind: BinderKind, site: PathRef
) -> BinderEntry {
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

pub fn binder_entry_slot(value: BinderEntry) -> SlotRef { value.slot }
pub fn binder_entry_owner(value: BinderEntry) -> ExecutableRef { value.owner }
pub fn binder_entry_kind(value: BinderEntry) -> BinderKind { value.kind }
pub fn binder_entry_site(value: BinderEntry) -> PathRef { value.site }

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
