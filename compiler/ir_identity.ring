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

// Resolver-issued enum variant identity.  The member payload is site-derived;
// no downstream stage may reconstruct it from a variant spelling.
pub struct VariantRef {
    owner: RegisteredNominalRef,
    member: SymbolRef,
    source_variant_index: Int
}

pub fn make_variant_ref(
    owner: RegisteredNominalRef, member: SymbolRef,
    source_variant_index: Int
) -> VariantRef {
    let owner_symbol = registered_nominal_ref_symbol(owner)
    if source_variant_index < 0 ||
       !namespace_kind_same(
            symbol_ref_namespace_kind(member), namespace_member()) ||
       symbol_ref_origin_module_key(member) !=
            symbol_ref_origin_module_key(owner_symbol) ||
       symbol_ref_declaration_site_path(member) !=
            "${symbol_ref_declaration_site_path(owner_symbol)}|variant:${source_variant_index}" {
        panic("IR identity: invalid enum variant relation")
    }
    VariantRef {
        owner: owner, member: member,
        source_variant_index: source_variant_index
    }
}

pub fn variant_ref_owner(value: VariantRef) -> RegisteredNominalRef {
    value.owner
}
pub fn variant_ref_member(value: VariantRef) -> SymbolRef { value.member }
pub fn variant_ref_source_index(value: VariantRef) -> Int {
    value.source_variant_index
}
pub fn variant_ref_same(left: VariantRef, right: VariantRef) -> Bool {
    registered_nominal_ref_same(left.owner, right.owner) &&
        symbol_ref_same(left.member, right.member) &&
        left.source_variant_index == right.source_variant_index
}

pub struct VariantFieldRef {
    variant: VariantRef,
    member: SymbolRef,
    field_index: Int
}

pub fn make_variant_field_ref(
    variant: VariantRef, member: SymbolRef, field_index: Int
) -> VariantFieldRef {
    let variant_member = variant_ref_member(variant)
    if field_index < 0 || !namespace_kind_same(
            symbol_ref_namespace_kind(member), namespace_member()) ||
       symbol_ref_origin_module_key(member) !=
            symbol_ref_origin_module_key(variant_member) ||
       symbol_ref_declaration_site_path(member) !=
            "${symbol_ref_declaration_site_path(variant_member)}|field:${field_index}" {
        panic("IR identity: invalid enum payload field relation")
    }
    VariantFieldRef {
        variant: variant, member: member, field_index: field_index
    }
}

pub fn variant_field_ref_variant(value: VariantFieldRef) -> VariantRef {
    value.variant
}
pub fn variant_field_ref_member(value: VariantFieldRef) -> SymbolRef {
    value.member
}
pub fn variant_field_ref_index(value: VariantFieldRef) -> Int {
    value.field_index
}
pub fn variant_field_ref_same(
    left: VariantFieldRef, right: VariantFieldRef
) -> Bool {
    variant_ref_same(left.variant, right.variant) &&
        symbol_ref_same(left.member, right.member) &&
        left.field_index == right.field_index
}

pub struct HandledEffectRef { effect_symbol: SymbolRef }

pub fn make_handled_effect_ref(effect_symbol: SymbolRef) -> HandledEffectRef {
    if !namespace_kind_same(
            symbol_ref_namespace_kind(effect_symbol), namespace_effect()) ||
       symbol_ref_origin_module_key(effect_symbol) == "$system" {
        panic("IR identity: invalid handled effect domain")
    }
    HandledEffectRef { effect_symbol: effect_symbol }
}
pub fn handled_effect_ref_symbol(value: HandledEffectRef) -> SymbolRef {
    value.effect_symbol
}
pub fn handled_effect_ref_same(
    left: HandledEffectRef, right: HandledEffectRef
) -> Bool { symbol_ref_same(left.effect_symbol, right.effect_symbol) }

const SYSTEM_EFFECT_CONSOLE: Int = 0
const SYSTEM_EFFECT_FS: Int = 1
const SYSTEM_EFFECT_PROCESS: Int = 2
const SYSTEM_EFFECT_COUNT: Int = 3

pub struct SystemEffectRef { tag: Int }

fn system_effect_ref_from_tag(tag: Int) -> SystemEffectRef {
    if tag < SYSTEM_EFFECT_CONSOLE || tag >= SYSTEM_EFFECT_COUNT {
        panic("IR identity: invalid system effect")
    }
    SystemEffectRef { tag: tag }
}
pub fn system_effect_console() -> SystemEffectRef {
    system_effect_ref_from_tag(SYSTEM_EFFECT_CONSOLE)
}
pub fn system_effect_fs() -> SystemEffectRef {
    system_effect_ref_from_tag(SYSTEM_EFFECT_FS)
}
pub fn system_effect_process() -> SystemEffectRef {
    system_effect_ref_from_tag(SYSTEM_EFFECT_PROCESS)
}
pub fn system_effect_ref_tag(value: SystemEffectRef) -> Int {
    system_effect_ref_from_tag(value.tag).tag
}
pub fn system_effect_ref_same(
    left: SystemEffectRef, right: SystemEffectRef
) -> Bool { system_effect_ref_tag(left) == system_effect_ref_tag(right) }

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

// One exact source or elaboration origin.  Representation stays opaque so a
// downstream stage can compare/copy the chosen origin but cannot reconstruct
// it from a display spelling, source position, or backend symbol.
enum OriginRefValue {
    SymbolOriginValue(SymbolRef),
    PathOriginValue(PathRef)
}

pub struct OriginRef {
    value: OriginRefValue
}

pub fn make_symbol_origin_ref(value: SymbolRef) -> OriginRef {
    // SymbolRef is already opaque and validated by its unique producer.
    // OriginRef wraps that exact value; it must never reconstruct it.
    OriginRef { value: OriginRefValue::SymbolOriginValue(value) }
}

pub fn make_path_origin_ref(value: PathRef) -> OriginRef {
    // PathRef has the same opaque-construction contract.
    OriginRef { value: OriginRefValue::PathOriginValue(value) }
}

pub fn origin_ref_is_symbol(value: OriginRef) -> Bool {
    match value.value {
        OriginRefValue::SymbolOriginValue(_) => true,
        OriginRefValue::PathOriginValue(_) => false
    }
}

pub fn origin_ref_symbol(value: OriginRef) -> SymbolRef {
    match value.value {
        OriginRefValue::SymbolOriginValue(symbol) => symbol,
        OriginRefValue::PathOriginValue(_) =>
            panic("IR identity: path OriginRef has no SymbolRef")
    }
}

pub fn origin_ref_path(value: OriginRef) -> PathRef {
    match value.value {
        OriginRefValue::PathOriginValue(path) => path,
        OriginRefValue::SymbolOriginValue(_) =>
            panic("IR identity: symbol OriginRef has no PathRef")
    }
}

pub fn origin_ref_same(left: OriginRef, right: OriginRef) -> Bool {
    match (left.value, right.value) {
        (OriginRefValue::SymbolOriginValue(a),
         OriginRefValue::SymbolOriginValue(b)) => symbol_ref_same(a, b),
        (OriginRefValue::PathOriginValue(a),
         OriginRefValue::PathOriginValue(b)) => path_ref_same(a, b),
        _ => false
    }
}

// Fixed 0.1 builtin method intrinsic sites.  These tags are semantic compiler
// identities, not runtime symbol ordinals.  Builtins is the sole producer;
// HIR and Abi/C lowering may only copy and exhaustively consume them.
pub const BUILTIN_METHOD_STR_LEN: Int = 0
pub const BUILTIN_METHOD_STR_CONTAINS: Int = 1
pub const BUILTIN_METHOD_STR_STARTS_WITH: Int = 2
pub const BUILTIN_METHOD_STR_ENDS_WITH: Int = 3
pub const BUILTIN_METHOD_STR_SLICE: Int = 4
pub const BUILTIN_METHOD_STR_TRIM: Int = 5
pub const BUILTIN_METHOD_STR_TO_UPPER: Int = 6
pub const BUILTIN_METHOD_STR_TO_LOWER: Int = 7
pub const BUILTIN_METHOD_STR_REPLACE: Int = 8
pub const BUILTIN_METHOD_STR_SPLIT: Int = 9
pub const BUILTIN_METHOD_STR_CHAR_AT: Int = 10
pub const BUILTIN_METHOD_STR_INDEX_OF: Int = 11
pub const BUILTIN_METHOD_STR_PAD_START: Int = 12
pub const BUILTIN_METHOD_STR_PAD_END: Int = 13
pub const BUILTIN_METHOD_STR_REPEAT: Int = 14
pub const BUILTIN_METHOD_STR_CHAR_CODE_AT: Int = 15
pub const BUILTIN_METHOD_STR_TRIM_START: Int = 16
pub const BUILTIN_METHOD_STR_TRIM_END: Int = 17
pub const BUILTIN_METHOD_STR_IS_EMPTY: Int = 18
pub const BUILTIN_METHOD_STR_LAST_INDEX_OF: Int = 19
pub const BUILTIN_METHOD_INT_TO_STR: Int = 20
pub const BUILTIN_METHOD_FLOAT_TO_STR: Int = 21
pub const BUILTIN_METHOD_OPTION_UNWRAP_OR: Int = 22
pub const BUILTIN_METHOD_OPTION_UNWRAP: Int = 23
pub const BUILTIN_METHOD_OPTION_IS_SOME: Int = 24
pub const BUILTIN_METHOD_OPTION_IS_NONE: Int = 25
pub const BUILTIN_METHOD_OPTION_MAP: Int = 26
pub const BUILTIN_METHOD_OPTION_AND_THEN: Int = 27
pub const BUILTIN_METHOD_OPTION_UNWRAP_OR_ELSE: Int = 28
pub const BUILTIN_METHOD_OPTION_TO_FAIL: Int = 29
pub const BUILTIN_METHOD_CELL_GET: Int = 30
pub const BUILTIN_METHOD_CELL_SET: Int = 31
pub const BUILTIN_METHOD_CELL_UPDATE: Int = 32
pub const BUILTIN_METHOD_SITE_COUNT: Int = 33

pub struct BuiltinMethodSite {
    tag: Int
}

pub fn builtin_method_site_from_tag(tag: Int) -> BuiltinMethodSite {
    if tag < 0 || tag >= BUILTIN_METHOD_SITE_COUNT {
        panic("IR identity: invalid builtin method site")
    }
    BuiltinMethodSite { tag: tag }
}

pub fn builtin_method_site_tag(value: BuiltinMethodSite) -> Int {
    builtin_method_site_from_tag(value.tag).tag
}

pub fn builtin_method_site_same(
    left: BuiltinMethodSite, right: BuiltinMethodSite
) -> Bool {
    builtin_method_site_tag(left) == builtin_method_site_tag(right)
}

pub struct IntrinsicRef {
    site: BuiltinMethodSite,
    symbol: SymbolRef
}

pub fn make_builtin_method_intrinsic_ref(
    site: BuiltinMethodSite, symbol: SymbolRef
) -> IntrinsicRef {
    let tag = builtin_method_site_tag(site)
    if symbol_ref_origin_module_key(symbol) != "$builtin" ||
       !namespace_kind_same(
            symbol_ref_namespace_kind(symbol), namespace_value()) ||
       symbol_ref_canonical_payload(symbol) !=
            "builtin-method:${tag.to_str()}" ||
       symbol_ref_declaration_site_path(symbol) !=
            "builtin:method-site:${tag.to_str()}" {
        panic("IR identity: builtin method intrinsic relation drifted")
    }
    IntrinsicRef { site: site, symbol: symbol }
}

pub fn intrinsic_ref_site(value: IntrinsicRef) -> BuiltinMethodSite {
    value.site
}

pub fn intrinsic_ref_symbol(value: IntrinsicRef) -> SymbolRef {
    value.symbol
}

pub fn intrinsic_ref_same(left: IntrinsicRef, right: IntrinsicRef) -> Bool {
    builtin_method_site_same(left.site, right.site) &&
        symbol_ref_same(left.symbol, right.symbol)
}

const IMPL_PROVIDER_SOURCE: Int = 0
const IMPL_PROVIDER_BUILTIN: Int = 1
const IMPL_PROVIDER_DERIVED: Int = 2
const IMPL_PROVIDER_DELEGATE: Int = 3

pub struct ImplProviderKind {
    tag: Int
}

pub fn impl_provider_kind_from_tag(tag: Int) -> ImplProviderKind {
    if tag < IMPL_PROVIDER_SOURCE || tag > IMPL_PROVIDER_DELEGATE {
        panic("IR identity: invalid impl provider kind")
    }
    ImplProviderKind { tag: tag }
}

pub fn impl_provider_kind_tag(value: ImplProviderKind) -> Int {
    impl_provider_kind_from_tag(value.tag).tag
}

pub fn impl_provider_kind_source() -> ImplProviderKind {
    impl_provider_kind_from_tag(IMPL_PROVIDER_SOURCE)
}

pub fn impl_provider_kind_builtin() -> ImplProviderKind {
    impl_provider_kind_from_tag(IMPL_PROVIDER_BUILTIN)
}

pub fn impl_provider_kind_derived() -> ImplProviderKind {
    impl_provider_kind_from_tag(IMPL_PROVIDER_DERIVED)
}

pub fn impl_provider_kind_delegate() -> ImplProviderKind {
    impl_provider_kind_from_tag(IMPL_PROVIDER_DELEGATE)
}

pub fn impl_provider_kind_same(
    left: ImplProviderKind, right: ImplProviderKind
) -> Bool {
    impl_provider_kind_tag(left) == impl_provider_kind_tag(right)
}

// An impl provider identifies only the exact producer site. Target and trait
// identity remain independent typed components of the registry owner key.
pub struct ImplProviderRef {
    site: PathRef,
    kind: ImplProviderKind
}

pub fn make_impl_provider_ref(
    site: PathRef, kind: ImplProviderKind
) -> ImplProviderRef {
    let owner = path_ref_owner(site)
    if path_owner_ref_is_symbol(owner) {
        panic("IR identity: impl provider is not module-body owned")
    }
    let checked_kind = impl_provider_kind_from_tag(
        impl_provider_kind_tag(kind))
    let role = path_ref_role(site)
    if impl_provider_kind_same(checked_kind, impl_provider_kind_source()) {
        if !path_role_same(role, path_role_declaration()) {
            panic("IR identity: source impl provider is not a declaration")
        }
    } else if !path_role_same(role, path_role_synthetic()) {
        panic("IR identity: generated impl provider is not synthetic")
    }
    ImplProviderRef { site: site, kind: checked_kind }
}

pub fn impl_provider_ref_site(value: ImplProviderRef) -> PathRef {
    value.site
}

pub fn impl_provider_ref_kind(value: ImplProviderRef) -> ImplProviderKind {
    value.kind
}

pub fn impl_provider_ref_same(
    left: ImplProviderRef, right: ImplProviderRef
) -> Bool {
    path_ref_same(left.site, right.site) &&
        impl_provider_kind_same(left.kind, right.kind)
}

// The exact registry owner key.  Target and trait are typed identities rather
// than strings, and the provider remains the sole producer-site authority.
pub struct ImplOwnerRef {
    target: SymbolRef,
    provider: ImplProviderRef,
    trait_ref: SymbolRef?
}

pub fn make_impl_owner_ref(
    target: SymbolRef, provider: ImplProviderRef, trait_ref: SymbolRef?
) -> ImplOwnerRef {
    if !namespace_kind_same(
            symbol_ref_namespace_kind(target), namespace_nominal()) {
        panic("IR identity: impl target is not nominal")
    }
    match trait_ref {
        some(trait_symbol) => if !namespace_kind_same(
                symbol_ref_namespace_kind(trait_symbol), namespace_trait()) {
            panic("IR identity: impl trait ref is not a trait")
        },
        none => {}
    }
    // Revalidate the provider form at the typed owner boundary.
    let checked_provider = make_impl_provider_ref(
        impl_provider_ref_site(provider), impl_provider_ref_kind(provider))
    ImplOwnerRef {
        target: target, provider: checked_provider, trait_ref: trait_ref
    }
}

pub fn impl_owner_ref_target(value: ImplOwnerRef) -> SymbolRef {
    value.target
}
pub fn impl_owner_ref_provider(value: ImplOwnerRef) -> ImplProviderRef {
    value.provider
}
pub fn impl_owner_ref_trait(value: ImplOwnerRef) -> SymbolRef? {
    value.trait_ref
}
pub fn impl_owner_ref_same(left: ImplOwnerRef, right: ImplOwnerRef) -> Bool {
    if !symbol_ref_same(left.target, right.target) ||
       !impl_provider_ref_same(left.provider, right.provider) {
        return false
    }
    match (left.trait_ref, right.trait_ref) {
        (some(a), some(b)) => symbol_ref_same(a, b),
        (none, none) => true,
        _ => false
    }
}

// One exact executable member produced by an ImplOwnerRef.  The raw source
// index includes associated/delegate members; callable_slot_index counts only
// executable members.  This preserves source order without a name scan.
pub struct ImplMethodRef {
    owner: ImplOwnerRef,
    member: SymbolRef,
    source_member_index: Int,
    callable_slot_index: Int,
    name: Str
}

pub fn make_impl_method_ref(
    owner: ImplOwnerRef, member: SymbolRef,
    source_member_index: Int, callable_slot_index: Int, name: Str
) -> ImplMethodRef {
    if !namespace_kind_same(
            symbol_ref_namespace_kind(member), namespace_member()) ||
       source_member_index < 0 || callable_slot_index < 0 ||
       source_member_index < callable_slot_index || name == "" {
        panic("IR identity: invalid impl method relation")
    }
    let provider_site = impl_provider_ref_site(
        impl_owner_ref_provider(owner))
    let provider_module = module_body_ref_origin_module_key(
        path_owner_ref_module_body(path_ref_owner(provider_site)))
    if symbol_ref_origin_module_key(member) != provider_module {
        panic("IR identity: impl method crosses provider module")
    }
    ImplMethodRef {
        owner: owner, member: member,
        source_member_index: source_member_index,
        callable_slot_index: callable_slot_index, name: name
    }
}

pub fn impl_method_ref_owner(value: ImplMethodRef) -> ImplOwnerRef {
    value.owner
}
pub fn impl_method_ref_member(value: ImplMethodRef) -> SymbolRef {
    value.member
}
pub fn impl_method_ref_source_member_index(value: ImplMethodRef) -> Int {
    value.source_member_index
}
pub fn impl_method_ref_callable_slot_index(value: ImplMethodRef) -> Int {
    value.callable_slot_index
}
pub fn impl_method_ref_name(value: ImplMethodRef) -> Str { value.name }
pub fn impl_method_ref_same(
    left: ImplMethodRef, right: ImplMethodRef
) -> Bool {
    impl_owner_ref_same(left.owner, right.owner) &&
        symbol_ref_same(left.member, right.member) &&
        left.source_member_index == right.source_member_index &&
        left.callable_slot_index == right.callable_slot_index &&
        left.name == right.name
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
