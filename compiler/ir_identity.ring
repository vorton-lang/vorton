// F0 compiler-wide typed identities.
//
// This module is a neutral carrier for future staged IR cutovers.  It has no
// resource lattice, compiler pass, identity allocator, or resolution logic.
// Public references have private representation and can only be created by
// fail-closed constructors below.

// ============================================================
// Validated tag types
// ============================================================

const NAMESPACE_VALUE: Int = 0
const NAMESPACE_NOMINAL: Int = 1
const NAMESPACE_TRAIT: Int = 2
const NAMESPACE_EFFECT: Int = 3
const NAMESPACE_MEMBER: Int = 4

pub struct NamespaceKind {
    tag: Int
}

pub fn namespace_value() -> NamespaceKind {
    NamespaceKind { tag: NAMESPACE_VALUE }
}

pub fn namespace_nominal() -> NamespaceKind {
    NamespaceKind { tag: NAMESPACE_NOMINAL }
}

pub fn namespace_trait() -> NamespaceKind {
    NamespaceKind { tag: NAMESPACE_TRAIT }
}

pub fn namespace_effect() -> NamespaceKind {
    NamespaceKind { tag: NAMESPACE_EFFECT }
}

pub fn namespace_member() -> NamespaceKind {
    NamespaceKind { tag: NAMESPACE_MEMBER }
}

pub fn namespace_kind_from_tag(tag: Int) -> NamespaceKind {
    if tag < NAMESPACE_VALUE || tag > NAMESPACE_MEMBER {
        panic("IR identity: invalid namespace kind")
    }
    NamespaceKind { tag: tag }
}

pub fn namespace_kind_tag(value: NamespaceKind) -> Int {
    namespace_kind_from_tag(value.tag).tag
}

pub fn namespace_kind_same(left: NamespaceKind, right: NamespaceKind) -> Bool {
    namespace_kind_tag(left) == namespace_kind_tag(right)
}

const PATH_ROLE_DECLARATION: Int = 0
const PATH_ROLE_CHILD: Int = 1
const PATH_ROLE_PARAMETER: Int = 2
const PATH_ROLE_RESULT: Int = 3
const PATH_ROLE_CAPTURE: Int = 4
const PATH_ROLE_HANDLER: Int = 5
const PATH_ROLE_SYNTHETIC: Int = 6

pub struct PathRole {
    tag: Int
}

pub fn path_role_declaration() -> PathRole {
    PathRole { tag: PATH_ROLE_DECLARATION }
}

pub fn path_role_child() -> PathRole {
    PathRole { tag: PATH_ROLE_CHILD }
}

pub fn path_role_parameter() -> PathRole {
    PathRole { tag: PATH_ROLE_PARAMETER }
}

pub fn path_role_result() -> PathRole {
    PathRole { tag: PATH_ROLE_RESULT }
}

pub fn path_role_capture() -> PathRole {
    PathRole { tag: PATH_ROLE_CAPTURE }
}

pub fn path_role_handler() -> PathRole {
    PathRole { tag: PATH_ROLE_HANDLER }
}

pub fn path_role_synthetic() -> PathRole {
    PathRole { tag: PATH_ROLE_SYNTHETIC }
}

pub fn path_role_from_tag(tag: Int) -> PathRole {
    if tag < PATH_ROLE_DECLARATION || tag > PATH_ROLE_SYNTHETIC {
        panic("IR identity: invalid path role")
    }
    PathRole { tag: tag }
}

pub fn path_role_tag(value: PathRole) -> Int {
    path_role_from_tag(value.tag).tag
}

pub fn path_role_same(left: PathRole, right: PathRole) -> Bool {
    path_role_tag(left) == path_role_tag(right)
}

const SLOT_DOMAIN_LEXICAL: Int = 0
const SLOT_DOMAIN_MEMBER: Int = 1
const SLOT_DOMAIN_CALLABLE: Int = 2
const SLOT_DOMAIN_DICTIONARY: Int = 3
const SLOT_DOMAIN_ANF: Int = 4
const SLOT_DOMAIN_RC: Int = 5

pub struct SlotDomain {
    tag: Int
}

pub fn slot_domain_lexical() -> SlotDomain {
    SlotDomain { tag: SLOT_DOMAIN_LEXICAL }
}

pub fn slot_domain_member() -> SlotDomain {
    SlotDomain { tag: SLOT_DOMAIN_MEMBER }
}

pub fn slot_domain_callable() -> SlotDomain {
    SlotDomain { tag: SLOT_DOMAIN_CALLABLE }
}

pub fn slot_domain_dictionary() -> SlotDomain {
    SlotDomain { tag: SLOT_DOMAIN_DICTIONARY }
}

pub fn slot_domain_anf() -> SlotDomain {
    SlotDomain { tag: SLOT_DOMAIN_ANF }
}

pub fn slot_domain_rc() -> SlotDomain {
    SlotDomain { tag: SLOT_DOMAIN_RC }
}

pub fn slot_domain_from_tag(tag: Int) -> SlotDomain {
    if tag < SLOT_DOMAIN_LEXICAL || tag > SLOT_DOMAIN_RC {
        panic("IR identity: invalid slot domain")
    }
    SlotDomain { tag: tag }
}

pub fn slot_domain_tag(value: SlotDomain) -> Int {
    slot_domain_from_tag(value.tag).tag
}

pub fn slot_domain_same(left: SlotDomain, right: SlotDomain) -> Bool {
    slot_domain_tag(left) == slot_domain_tag(right)
}

fn slot_domain_is_lexical(value: SlotDomain) -> Bool {
    slot_domain_tag(value) == SLOT_DOMAIN_LEXICAL
}

const NOMINAL_STRUCT: Int = 0
const NOMINAL_ENUM: Int = 1
const NOMINAL_EXTERN: Int = 2

pub struct NominalKind {
    tag: Int
}

pub fn nominal_struct() -> NominalKind {
    NominalKind { tag: NOMINAL_STRUCT }
}

pub fn nominal_enum() -> NominalKind {
    NominalKind { tag: NOMINAL_ENUM }
}

pub fn nominal_extern() -> NominalKind {
    NominalKind { tag: NOMINAL_EXTERN }
}

pub fn nominal_kind_from_tag(tag: Int) -> NominalKind {
    if tag < NOMINAL_STRUCT || tag > NOMINAL_EXTERN {
        panic("IR identity: invalid nominal kind")
    }
    NominalKind { tag: tag }
}

pub fn nominal_kind_tag(value: NominalKind) -> Int {
    nominal_kind_from_tag(value.tag).tag
}

pub fn nominal_kind_same(left: NominalKind, right: NominalKind) -> Bool {
    nominal_kind_tag(left) == nominal_kind_tag(right)
}

// ============================================================
// Named and anonymous typed references
// ============================================================

pub struct SymbolRef {
    origin_module_key: Str,
    namespace_kind: NamespaceKind,
    canonical_payload: Str,
    declaration_site_path: Str
}

pub fn make_symbol_ref(
    origin_module_key: Str, namespace_kind: NamespaceKind,
    canonical_payload: Str, declaration_site_path: Str
) -> SymbolRef {
    if origin_module_key == "" || canonical_payload == "" ||
       declaration_site_path == "" {
        panic("IR identity: incomplete SymbolRef")
    }
    let checked_namespace = namespace_kind_from_tag(
        namespace_kind_tag(namespace_kind))
    SymbolRef {
        origin_module_key: origin_module_key,
        namespace_kind: checked_namespace,
        canonical_payload: canonical_payload,
        declaration_site_path: declaration_site_path
    }
}

pub fn symbol_ref_origin_module_key(value: SymbolRef) -> Str {
    value.origin_module_key
}

pub fn symbol_ref_namespace_kind(value: SymbolRef) -> NamespaceKind {
    value.namespace_kind
}

pub fn symbol_ref_canonical_payload(value: SymbolRef) -> Str {
    value.canonical_payload
}

pub fn symbol_ref_declaration_site_path(value: SymbolRef) -> Str {
    value.declaration_site_path
}

pub fn symbol_ref_same(left: SymbolRef, right: SymbolRef) -> Bool {
    left.origin_module_key == right.origin_module_key &&
        namespace_kind_same(left.namespace_kind, right.namespace_kind) &&
        left.canonical_payload == right.canonical_payload &&
        left.declaration_site_path == right.declaration_site_path
}

// Registration gives a resolver-produced nominal a local typed display name
// without changing or reconstructing its source identity.
pub struct RegisteredNominalRef {
    symbol: SymbolRef,
    display_name: Str
}

pub fn make_registered_nominal_ref(
    symbol: SymbolRef, display_name: Str
) -> RegisteredNominalRef {
    if display_name == "" || !namespace_kind_same(
            symbol_ref_namespace_kind(symbol), namespace_nominal()) {
        panic("IR identity: invalid registered nominal relation")
    }
    RegisteredNominalRef {
        symbol: symbol,
        display_name: display_name
    }
}

pub fn registered_nominal_ref_symbol(
    value: RegisteredNominalRef
) -> SymbolRef {
    value.symbol
}

pub fn registered_nominal_ref_display_name(
    value: RegisteredNominalRef
) -> Str {
    value.display_name
}

pub fn registered_nominal_ref_same(
    left: RegisteredNominalRef, right: RegisteredNominalRef
) -> Bool {
    symbol_ref_same(left.symbol, right.symbol) &&
        left.display_name == right.display_name
}

// Registration gives a source trait its local typed display name without
// changing the resolver-owned source identity.  Single-file compilation uses
// an unspellable source module key while retaining the source spelling here.
pub struct RegisteredTraitRef {
    symbol: SymbolRef,
    display_name: Str
}

pub fn make_registered_trait_ref(
    symbol: SymbolRef, display_name: Str
) -> RegisteredTraitRef {
    if display_name == "" || !namespace_kind_same(
            symbol_ref_namespace_kind(symbol), namespace_trait()) {
        panic("IR identity: invalid registered trait relation")
    }
    RegisteredTraitRef { symbol: symbol, display_name: display_name }
}

pub fn registered_trait_ref_symbol(value: RegisteredTraitRef) -> SymbolRef {
    value.symbol
}

pub fn registered_trait_ref_display_name(value: RegisteredTraitRef) -> Str {
    value.display_name
}

pub fn registered_trait_ref_same(
    left: RegisteredTraitRef, right: RegisteredTraitRef
) -> Bool {
    symbol_ref_same(left.symbol, right.symbol) &&
        left.display_name == right.display_name
}

// A nominal field is one atomic typed relation: downstream stages may copy
// it, but cannot pair an arbitrary member with an unrelated nominal owner.
pub struct NominalFieldRef {
    owner: SymbolRef,
    member: SymbolRef,
    field_index: Int,
    field_name: Str
}

pub fn make_nominal_field_ref(
    owner: SymbolRef, member: SymbolRef,
    field_index: Int, field_name: Str
) -> NominalFieldRef {
    if field_index < 0 || field_name == "" ||
       !namespace_kind_same(
            symbol_ref_namespace_kind(owner), namespace_nominal()) ||
       !namespace_kind_same(
            symbol_ref_namespace_kind(member), namespace_member()) ||
       symbol_ref_origin_module_key(owner) !=
            symbol_ref_origin_module_key(member) ||
       symbol_ref_canonical_payload(member) !=
            "${symbol_ref_canonical_payload(owner)}::${field_name}" ||
       symbol_ref_declaration_site_path(member) !=
            "${symbol_ref_declaration_site_path(owner)}|field:${field_index}|kind:struct-field" {
        panic("IR identity: invalid nominal field relation")
    }
    NominalFieldRef {
        owner: owner,
        member: member,
        field_index: field_index,
        field_name: field_name
    }
}

pub fn nominal_field_ref_owner(value: NominalFieldRef) -> SymbolRef {
    value.owner
}

pub fn nominal_field_ref_member(value: NominalFieldRef) -> SymbolRef {
    value.member
}

pub fn nominal_field_ref_index(value: NominalFieldRef) -> Int {
    value.field_index
}

pub fn nominal_field_ref_name(value: NominalFieldRef) -> Str {
    value.field_name
}

pub fn nominal_field_ref_same(
    left: NominalFieldRef, right: NominalFieldRef
) -> Bool {
    symbol_ref_same(left.owner, right.owner) &&
        symbol_ref_same(left.member, right.member) &&
        left.field_index == right.field_index &&
        left.field_name == right.field_name
}

// One source trait method is a closed relation between its exact trait
// declaration, exact member declaration, raw AST member site, and callable
// dictionary slot.  Source-member and callable-slot indexes are intentionally
// separate: associated-type declarations may occupy source positions without
// becoming callable dictionary slots.
pub struct TraitMethodRef {
    trait_symbol: SymbolRef,
    member_symbol: SymbolRef,
    source_member_index: Int,
    callable_slot_index: Int,
    method_name: Str
}

pub fn make_trait_method_ref(
    trait_symbol: SymbolRef, source_member_index: Int,
    callable_slot_index: Int, method_name: Str
) -> TraitMethodRef {
    if source_member_index < 0 || callable_slot_index < 0 ||
       source_member_index < callable_slot_index ||
       method_name == "" || !namespace_kind_same(
            symbol_ref_namespace_kind(trait_symbol), namespace_trait()) {
        panic("IR identity: invalid trait method owner/site")
    }
    let member_symbol = make_symbol_ref(
        symbol_ref_origin_module_key(trait_symbol), namespace_member(),
        "${symbol_ref_canonical_payload(trait_symbol)}::${method_name}",
        "${symbol_ref_declaration_site_path(trait_symbol)}|member:${source_member_index}|slot:${callable_slot_index}|kind:trait-method")
    if symbol_ref_origin_module_key(trait_symbol) !=
           symbol_ref_origin_module_key(member_symbol) ||
       !namespace_kind_same(
            symbol_ref_namespace_kind(member_symbol), namespace_member()) ||
       symbol_ref_canonical_payload(member_symbol) !=
            "${symbol_ref_canonical_payload(trait_symbol)}::${method_name}" ||
       symbol_ref_declaration_site_path(member_symbol) !=
            "${symbol_ref_declaration_site_path(trait_symbol)}|member:${source_member_index}|slot:${callable_slot_index}|kind:trait-method" {
        panic("IR identity: invalid trait method relation")
    }
    TraitMethodRef {
        trait_symbol: trait_symbol,
        member_symbol: member_symbol,
        source_member_index: source_member_index,
        callable_slot_index: callable_slot_index,
        method_name: method_name
    }
}

pub fn trait_method_ref_trait(value: TraitMethodRef) -> SymbolRef {
    value.trait_symbol
}

pub fn trait_method_ref_member(value: TraitMethodRef) -> SymbolRef {
    value.member_symbol
}

pub fn trait_method_ref_source_member_index(value: TraitMethodRef) -> Int {
    value.source_member_index
}

pub fn trait_method_ref_callable_slot_index(value: TraitMethodRef) -> Int {
    value.callable_slot_index
}

pub fn trait_method_ref_name(value: TraitMethodRef) -> Str {
    value.method_name
}

pub fn trait_method_ref_same(
    left: TraitMethodRef, right: TraitMethodRef
) -> Bool {
    symbol_ref_same(left.trait_symbol, right.trait_symbol) &&
        symbol_ref_same(left.member_symbol, right.member_symbol) &&
        left.source_member_index == right.source_member_index &&
        left.callable_slot_index == right.callable_slot_index &&
        left.method_name == right.method_name
}

pub struct ModuleBodyRef {
    origin_module_key: Str,
    declaration_site_path: Str
}

pub fn make_module_body_ref(
    origin_module_key: Str, declaration_site_path: Str
) -> ModuleBodyRef {
    if origin_module_key == "" || declaration_site_path == "" {
        panic("IR identity: incomplete ModuleBodyRef")
    }
    ModuleBodyRef {
        origin_module_key: origin_module_key,
        declaration_site_path: declaration_site_path
    }
}

pub fn module_body_ref_origin_module_key(value: ModuleBodyRef) -> Str {
    value.origin_module_key
}

pub fn module_body_ref_declaration_site_path(value: ModuleBodyRef) -> Str {
    value.declaration_site_path
}

pub fn module_body_ref_same(left: ModuleBodyRef, right: ModuleBodyRef) -> Bool {
    left.origin_module_key == right.origin_module_key &&
        left.declaration_site_path == right.declaration_site_path
}

enum PathOwnerValue {
    SymbolOwnerValue(SymbolRef),
    ModuleBodyOwnerValue(ModuleBodyRef)
}

pub struct PathOwnerRef {
    value: PathOwnerValue
}

pub fn path_owner_for_symbol(symbol: SymbolRef) -> PathOwnerRef {
    PathOwnerRef { value: PathOwnerValue::SymbolOwnerValue(symbol) }
}

pub fn path_owner_for_module_body(body: ModuleBodyRef) -> PathOwnerRef {
    PathOwnerRef { value: PathOwnerValue::ModuleBodyOwnerValue(body) }
}

pub fn path_owner_ref_is_symbol(value: PathOwnerRef) -> Bool {
    match value.value {
        PathOwnerValue::SymbolOwnerValue(_) => true,
        PathOwnerValue::ModuleBodyOwnerValue(_) => false
    }
}

pub fn path_owner_ref_symbol(value: PathOwnerRef) -> SymbolRef {
    match value.value {
        PathOwnerValue::SymbolOwnerValue(symbol) => symbol,
        PathOwnerValue::ModuleBodyOwnerValue(_) =>
            panic("IR identity: module-body owner has no SymbolRef")
    }
}

pub fn path_owner_ref_module_body(value: PathOwnerRef) -> ModuleBodyRef {
    match value.value {
        PathOwnerValue::ModuleBodyOwnerValue(body) => body,
        PathOwnerValue::SymbolOwnerValue(_) =>
            panic("IR identity: symbol owner has no ModuleBodyRef")
    }
}

pub fn path_owner_ref_same(left: PathOwnerRef, right: PathOwnerRef) -> Bool {
    match (left.value, right.value) {
        (PathOwnerValue::SymbolOwnerValue(a),
         PathOwnerValue::SymbolOwnerValue(b)) => symbol_ref_same(a, b),
        (PathOwnerValue::ModuleBodyOwnerValue(a),
         PathOwnerValue::ModuleBodyOwnerValue(b)) =>
            module_body_ref_same(a, b),
        _ => false
    }
}

fn validate_normalized_child_path(path: List<Str>) {
    if path.len() == 0 {
        panic("IR identity: anonymous path is empty")
    }
    for component in path {
        if component == "" || component == "." || component == ".." {
            panic("IR identity: child path is not normalized")
        }
    }
}

fn copy_string_list(values: List<Str>) -> List<Str> {
    let mut result: List<Str> = []
    for value in values { result.push(value) }
    result
}

fn string_list_same(left: List<Str>, right: List<Str>) -> Bool {
    if left.len() != right.len() { return false }
    let mut index = 0
    while index < left.len() {
        match (left.get(index), right.get(index)) {
            (some(a), some(b)) => if a != b { return false },
            _ => return false
        }
        index = index + 1
    }
    true
}

pub struct PathRef {
    owner: PathOwnerRef,
    normalized_child_path: List<Str>,
    role: PathRole
}

pub fn make_path_ref(
    owner: PathOwnerRef, normalized_child_path: List<Str>, role: PathRole
) -> PathRef {
    validate_normalized_child_path(normalized_child_path)
    let checked_role = path_role_from_tag(path_role_tag(role))
    PathRef {
        owner: owner,
        normalized_child_path: copy_string_list(normalized_child_path),
        role: checked_role
    }
}

pub fn path_ref_owner(value: PathRef) -> PathOwnerRef {
    value.owner
}

pub fn path_ref_normalized_child_path(value: PathRef) -> List<Str> {
    copy_string_list(value.normalized_child_path)
}

pub fn path_ref_role(value: PathRef) -> PathRole {
    value.role
}

pub fn path_ref_same(left: PathRef, right: PathRef) -> Bool {
    path_owner_ref_same(left.owner, right.owner) &&
        string_list_same(
            left.normalized_child_path, right.normalized_child_path) &&
        path_role_same(left.role, right.role)
}

enum SlotRefValue {
    SourceSlotValue {
        origin_module_key: Str,
        domain: SlotDomain,
        def_id: Int
    },
    SyntheticSlotValue(PathRef)
}

pub struct SlotRef {
    value: SlotRefValue
}

pub fn make_source_slot_ref(
    origin_module_key: Str, domain: SlotDomain, def_id: Int
) -> SlotRef {
    if origin_module_key == "" {
        panic("IR identity: source SlotRef has no module")
    }
    let checked_domain = slot_domain_from_tag(slot_domain_tag(domain))
    if slot_domain_is_lexical(checked_domain) {
        if def_id < 0 {
            panic("IR identity: lexical slot has synthetic DefId")
        }
    } else if def_id >= 0 {
        panic("IR identity: synthetic-domain slot has lexical DefId")
    }
    SlotRef { value: SlotRefValue::SourceSlotValue {
        origin_module_key: origin_module_key,
        domain: checked_domain,
        def_id: def_id
    } }
}

pub fn make_synthetic_slot_ref(path: PathRef) -> SlotRef {
    SlotRef { value: SlotRefValue::SyntheticSlotValue(path) }
}

pub fn slot_ref_is_source(value: SlotRef) -> Bool {
    match value.value {
        SlotRefValue::SourceSlotValue { .. } => true,
        SlotRefValue::SyntheticSlotValue(_) => false
    }
}

pub fn slot_ref_source_origin_module_key(value: SlotRef) -> Str {
    match value.value {
        SlotRefValue::SourceSlotValue { origin_module_key, .. } =>
            origin_module_key,
        SlotRefValue::SyntheticSlotValue(_) =>
            panic("IR identity: synthetic SlotRef has no source module")
    }
}

pub fn slot_ref_source_domain(value: SlotRef) -> SlotDomain {
    match value.value {
        SlotRefValue::SourceSlotValue { domain, .. } => domain,
        SlotRefValue::SyntheticSlotValue(_) =>
            panic("IR identity: synthetic SlotRef has no source domain")
    }
}

pub fn slot_ref_source_def_id(value: SlotRef) -> Int {
    match value.value {
        SlotRefValue::SourceSlotValue { def_id, .. } => def_id,
        SlotRefValue::SyntheticSlotValue(_) =>
            panic("IR identity: synthetic SlotRef has no source DefId")
    }
}

pub fn slot_ref_synthetic_path(value: SlotRef) -> PathRef {
    match value.value {
        SlotRefValue::SyntheticSlotValue(path) => path,
        SlotRefValue::SourceSlotValue { .. } =>
            panic("IR identity: source SlotRef has no synthetic path")
    }
}

pub fn slot_ref_same(left: SlotRef, right: SlotRef) -> Bool {
    match (left.value, right.value) {
        (SlotRefValue::SourceSlotValue {
             origin_module_key: am, domain: ad, def_id: ai },
         SlotRefValue::SourceSlotValue {
             origin_module_key: bm, domain: bd, def_id: bi }) =>
            am == bm && slot_domain_same(ad, bd) && ai == bi,
        (SlotRefValue::SyntheticSlotValue(a),
         SlotRefValue::SyntheticSlotValue(b)) => path_ref_same(a, b),
        _ => false
    }
}

pub fn require_same_slot(left: SlotRef, right: SlotRef) {
    if !slot_ref_same(left, right) {
        panic("IR identity: slot identity/domain mismatch")
    }
}

enum CalleeRefValue {
    NamedCalleeValue(SymbolRef),
    LocalCalleeValue(SlotRef),
    DynamicCalleeValue(PathRef)
}

pub struct CalleeRef {
    value: CalleeRefValue
}

pub fn make_named_callee_ref(symbol: SymbolRef) -> CalleeRef {
    CalleeRef { value: CalleeRefValue::NamedCalleeValue(symbol) }
}

pub fn make_local_callee_ref(slot: SlotRef) -> CalleeRef {
    CalleeRef { value: CalleeRefValue::LocalCalleeValue(slot) }
}

pub fn make_dynamic_callee_ref(path: PathRef) -> CalleeRef {
    CalleeRef { value: CalleeRefValue::DynamicCalleeValue(path) }
}

pub fn callee_ref_is_named(value: CalleeRef) -> Bool {
    match value.value {
        CalleeRefValue::NamedCalleeValue(_) => true,
        _ => false
    }
}

pub fn callee_ref_named_symbol(value: CalleeRef) -> SymbolRef {
    match value.value {
        CalleeRefValue::NamedCalleeValue(symbol) => symbol,
        _ => panic("IR identity: non-named CalleeRef has no SymbolRef")
    }
}

pub fn callee_ref_local_slot(value: CalleeRef) -> SlotRef {
    match value.value {
        CalleeRefValue::LocalCalleeValue(slot) => slot,
        _ => panic("IR identity: non-local CalleeRef has no SlotRef")
    }
}

pub fn callee_ref_dynamic_path(value: CalleeRef) -> PathRef {
    match value.value {
        CalleeRefValue::DynamicCalleeValue(path) => path,
        _ => panic("IR identity: non-dynamic CalleeRef has no PathRef")
    }
}

pub fn callee_ref_same(left: CalleeRef, right: CalleeRef) -> Bool {
    match (left.value, right.value) {
        (CalleeRefValue::NamedCalleeValue(a),
         CalleeRefValue::NamedCalleeValue(b)) => symbol_ref_same(a, b),
        (CalleeRefValue::LocalCalleeValue(a),
         CalleeRefValue::LocalCalleeValue(b)) => slot_ref_same(a, b),
        (CalleeRefValue::DynamicCalleeValue(a),
         CalleeRefValue::DynamicCalleeValue(b)) => path_ref_same(a, b),
        _ => false
    }
}

pub struct GlobalNominalRef {
    symbol: SymbolRef,
    kind: NominalKind
}

pub fn make_global_nominal_ref(
    symbol: SymbolRef, kind: NominalKind
) -> GlobalNominalRef {
    if !namespace_kind_same(
            symbol_ref_namespace_kind(symbol), namespace_nominal()) {
        panic("IR identity: GlobalNominalRef symbol is not nominal")
    }
    GlobalNominalRef {
        symbol: symbol,
        kind: nominal_kind_from_tag(nominal_kind_tag(kind))
    }
}

pub fn global_nominal_ref_symbol(value: GlobalNominalRef) -> SymbolRef {
    value.symbol
}

pub fn global_nominal_ref_kind(value: GlobalNominalRef) -> NominalKind {
    value.kind
}

pub fn global_nominal_ref_same(
    left: GlobalNominalRef, right: GlobalNominalRef
) -> Bool {
    symbol_ref_same(left.symbol, right.symbol) &&
        nominal_kind_same(left.kind, right.kind)
}
