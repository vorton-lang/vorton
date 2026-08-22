// F0: inert resource-model representation.
//
// This file intentionally has no compiler-pipeline imports or consumers.  It
// defines typed identities, immutable manifest stages, finite lattice joins,
// and slot-flow transitions only.  Later stages may consume these values, but
// F0 neither walks executable trees nor plans reference-count operations.

// ============================================================
// Typed identity tags
// ============================================================

const NAMESPACE_VALUE: Int = 0
const NAMESPACE_NOMINAL: Int = 1
const NAMESPACE_TRAIT: Int = 2
const NAMESPACE_EFFECT: Int = 3
const NAMESPACE_SIGNATURE: Int = 4
const NAMESPACE_MEMBER: Int = 5

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

pub fn namespace_signature() -> NamespaceKind {
    NamespaceKind { tag: NAMESPACE_SIGNATURE }
}

pub fn namespace_member() -> NamespaceKind {
    NamespaceKind { tag: NAMESPACE_MEMBER }
}

pub fn namespace_kind_from_tag(tag: Int) -> NamespaceKind {
    if tag < NAMESPACE_VALUE || tag > NAMESPACE_MEMBER {
        panic("resource model: invalid namespace kind")
    }
    NamespaceKind { tag: tag }
}

pub fn namespace_kind_tag(value: NamespaceKind) -> Int {
    value.tag
}

pub fn namespace_kind_same(left: NamespaceKind, right: NamespaceKind) -> Bool {
    left.tag == right.tag
}

const PATH_ROLE_DECL_BODY: Int = 0
const PATH_ROLE_PARAMETER: Int = 1
const PATH_ROLE_RESULT: Int = 2
const PATH_ROLE_CAPTURE: Int = 3
const PATH_ROLE_HANDLER: Int = 4
const PATH_ROLE_PATTERN: Int = 5
const PATH_ROLE_SYNTHETIC: Int = 6

pub struct PathRole {
    tag: Int
}

pub fn path_role_decl_body() -> PathRole {
    PathRole { tag: PATH_ROLE_DECL_BODY }
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

pub fn path_role_pattern() -> PathRole {
    PathRole { tag: PATH_ROLE_PATTERN }
}

pub fn path_role_synthetic() -> PathRole {
    PathRole { tag: PATH_ROLE_SYNTHETIC }
}

pub fn path_role_from_tag(tag: Int) -> PathRole {
    if tag < PATH_ROLE_DECL_BODY || tag > PATH_ROLE_SYNTHETIC {
        panic("resource model: invalid path role")
    }
    PathRole { tag: tag }
}

pub fn path_role_tag(value: PathRole) -> Int {
    value.tag
}

pub fn path_role_same(left: PathRole, right: PathRole) -> Bool {
    left.tag == right.tag
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
        panic("resource model: invalid slot domain")
    }
    SlotDomain { tag: tag }
}

pub fn slot_domain_tag(value: SlotDomain) -> Int {
    value.tag
}

pub fn slot_domain_same(left: SlotDomain, right: SlotDomain) -> Bool {
    left.tag == right.tag
}

fn slot_domain_is_lexical(value: SlotDomain) -> Bool {
    value.tag == SLOT_DOMAIN_LEXICAL
}

// ============================================================
// Typed identities
// ============================================================

pub struct SymbolRef {
    pub origin_module_key: Str,
    pub namespace_kind: NamespaceKind,
    pub canonical_payload: Str,
    pub declaration_site_path: Str
}

pub struct ModuleBodyRef {
    pub origin_module_key: Str,
    pub declaration_site_path: Str
}

pub enum PathOwnerRef {
    SymbolOwner(SymbolRef),
    ModuleBodyOwner(ModuleBodyRef)
}

pub struct PathRef {
    pub owner: PathOwnerRef,
    pub normalized_child_path: List<Str>,
    pub role: PathRole
}

pub enum SlotRef {
    Source { origin_module_key: Str, domain: SlotDomain, def_id: Int },
    Synthetic(PathRef)
}

pub enum CalleeRef {
    Named(SymbolRef),
    Local(SlotRef),
    Dynamic(PathRef)
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
        panic("resource model: invalid nominal kind")
    }
    NominalKind { tag: tag }
}

pub struct GlobalNominalRef {
    pub symbol: SymbolRef,
    pub kind: NominalKind
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

pub fn symbol_ref_same(left: SymbolRef, right: SymbolRef) -> Bool {
    left.origin_module_key == right.origin_module_key &&
        namespace_kind_same(left.namespace_kind, right.namespace_kind) &&
        left.canonical_payload == right.canonical_payload &&
        left.declaration_site_path == right.declaration_site_path
}

pub fn module_body_ref_same(left: ModuleBodyRef, right: ModuleBodyRef) -> Bool {
    left.origin_module_key == right.origin_module_key &&
        left.declaration_site_path == right.declaration_site_path
}

pub fn path_owner_ref_same(left: PathOwnerRef, right: PathOwnerRef) -> Bool {
    match (left, right) {
        (PathOwnerRef::SymbolOwner(a), PathOwnerRef::SymbolOwner(b)) =>
            symbol_ref_same(a, b),
        (PathOwnerRef::ModuleBodyOwner(a),
         PathOwnerRef::ModuleBodyOwner(b)) => module_body_ref_same(a, b),
        _ => false
    }
}

pub fn path_ref_same(left: PathRef, right: PathRef) -> Bool {
    path_owner_ref_same(left.owner, right.owner) &&
        string_list_same(
            left.normalized_child_path, right.normalized_child_path) &&
        path_role_same(left.role, right.role)
}

pub fn slot_ref_same(left: SlotRef, right: SlotRef) -> Bool {
    match (left, right) {
        (SlotRef::Source { origin_module_key: am, domain: ad,
                           def_id: ai },
         SlotRef::Source { origin_module_key: bm, domain: bd,
                           def_id: bi }) =>
            am == bm && slot_domain_same(ad, bd) && ai == bi,
        (SlotRef::Synthetic(a), SlotRef::Synthetic(b)) =>
            path_ref_same(a, b),
        _ => false
    }
}

pub fn callee_ref_same(left: CalleeRef, right: CalleeRef) -> Bool {
    match (left, right) {
        (CalleeRef::Named(a), CalleeRef::Named(b)) => symbol_ref_same(a, b),
        (CalleeRef::Local(a), CalleeRef::Local(b)) => slot_ref_same(a, b),
        (CalleeRef::Dynamic(a), CalleeRef::Dynamic(b)) => path_ref_same(a, b),
        _ => false
    }
}

pub fn global_nominal_ref_same(
    left: GlobalNominalRef, right: GlobalNominalRef
) -> Bool {
    symbol_ref_same(left.symbol, right.symbol) &&
        left.kind.tag == right.kind.tag
}

fn validate_normalized_child_path(path: List<Str>) {
    if path.len() == 0 {
        panic("resource model: anonymous path is empty")
    }
    for component in path {
        if component == "" || component == "." || component == ".." {
            panic("resource model: child path is not normalized")
        }
    }
}

pub fn validate_symbol_ref(value: SymbolRef) {
    if value.origin_module_key == "" || value.canonical_payload == "" ||
       value.declaration_site_path == "" {
        panic("resource model: named symbol identity is incomplete")
    }
    let _ = namespace_kind_from_tag(namespace_kind_tag(value.namespace_kind))
}

pub fn validate_module_body_ref(value: ModuleBodyRef) {
    if value.origin_module_key == "" || value.declaration_site_path == "" {
        panic("resource model: module body identity is incomplete")
    }
}

pub fn validate_path_ref(value: PathRef) {
    match value.owner {
        PathOwnerRef::SymbolOwner(symbol) => validate_symbol_ref(symbol),
        PathOwnerRef::ModuleBodyOwner(body) => validate_module_body_ref(body)
    }
    validate_normalized_child_path(value.normalized_child_path)
    let _ = path_role_from_tag(path_role_tag(value.role))
}

pub fn validate_slot_ref(value: SlotRef) {
    match value {
        SlotRef::Source { origin_module_key, domain, def_id } => {
            if origin_module_key == "" {
                panic("resource model: source slot has no module")
            }
            let checked = slot_domain_from_tag(slot_domain_tag(domain))
            if slot_domain_is_lexical(checked) {
                if def_id < 0 {
                    panic("resource model: lexical slot has synthetic DefId")
                }
            } else if def_id >= 0 {
                panic("resource model: synthetic-domain slot has lexical DefId")
            }
        },
        SlotRef::Synthetic(path) => validate_path_ref(path)
    }
}

pub fn require_same_slot(left: SlotRef, right: SlotRef) {
    validate_slot_ref(left)
    validate_slot_ref(right)
    if !slot_ref_same(left, right) {
        panic("resource model: slot identity/domain mismatch")
    }
}

// ============================================================
// Immutable manifest stages
// ============================================================

pub struct IdentityManifest {
    pub source_snapshot_hash: Str,
    pub resolver_input_hash: Str,
    pub normalized_input_hash: Str,
    pub symbols: List<SymbolRef>,
    pub paths: List<PathRef>,
    pub slots: List<SlotRef>
}

pub struct NormalizedResourceModel {
    pub manifest: IdentityManifest
}

pub struct FinalFrozenResourceModel {
    pub manifest: IdentityManifest
}

pub struct PlannedResourceModel {
    pub manifest: IdentityManifest
}

pub struct VerifiedResourceModel {
    pub manifest: IdentityManifest
}

const MODEL_STAGE_NORMALIZED: Int = 0
const MODEL_STAGE_FINAL_FROZEN: Int = 1
const MODEL_STAGE_PLANNED: Int = 2
const MODEL_STAGE_VERIFIED: Int = 3
const MODEL_STAGE_COUNT: Int = 4
const MODEL_STAGE_NEXT_TAGS: List<Int> = [1, 2, 3, 4]

pub struct ModelStage {
    tag: Int
}

pub fn model_stage_from_tag(tag: Int) -> ModelStage {
    if tag < MODEL_STAGE_NORMALIZED || tag >= MODEL_STAGE_COUNT {
        panic("resource model: invalid model stage")
    }
    ModelStage { tag: tag }
}

pub fn model_stage_normalized() -> ModelStage {
    model_stage_from_tag(MODEL_STAGE_NORMALIZED)
}

pub fn model_stage_final_frozen() -> ModelStage {
    model_stage_from_tag(MODEL_STAGE_FINAL_FROZEN)
}

pub fn model_stage_planned() -> ModelStage {
    model_stage_from_tag(MODEL_STAGE_PLANNED)
}

pub fn model_stage_verified() -> ModelStage {
    model_stage_from_tag(MODEL_STAGE_VERIFIED)
}

pub fn model_stage_rank(stage: ModelStage) -> Int {
    model_stage_from_tag(stage.tag).tag
}

pub fn model_stage_can_advance(from: ModelStage, to: ModelStage) -> Bool {
    let from_tag = model_stage_rank(from)
    let to_tag = model_stage_rank(to)
    match MODEL_STAGE_NEXT_TAGS.get(from_tag) {
        some(expected) => expected < MODEL_STAGE_COUNT && expected == to_tag,
        none => panic("resource model: stage transition table is incomplete")
    }
}

pub fn require_model_stage_advance(from: ModelStage, to: ModelStage) {
    if !model_stage_can_advance(from, to) {
        panic("resource model: illegal stage transition")
    }
}

pub fn validate_identity_manifest(manifest: IdentityManifest) {
    if manifest.source_snapshot_hash == "" ||
       manifest.resolver_input_hash == "" ||
       manifest.normalized_input_hash == "" {
        panic("resource model: manifest input identity is incomplete")
    }
    for symbol in manifest.symbols { validate_symbol_ref(symbol) }
    for path in manifest.paths { validate_path_ref(path) }
    for slot in manifest.slots { validate_slot_ref(slot) }
}

pub fn normalize_resource_model(
    manifest: IdentityManifest
) -> NormalizedResourceModel {
    validate_identity_manifest(manifest)
    NormalizedResourceModel { manifest: manifest }
}

pub fn freeze_resource_model(
    model: NormalizedResourceModel
) -> FinalFrozenResourceModel {
    require_model_stage_advance(
        model_stage_normalized(), model_stage_final_frozen())
    FinalFrozenResourceModel { manifest: model.manifest }
}

pub fn advance_final_frozen_to_planned(
    model: FinalFrozenResourceModel
) -> PlannedResourceModel {
    require_model_stage_advance(
        model_stage_final_frozen(), model_stage_planned())
    PlannedResourceModel { manifest: model.manifest }
}

pub fn advance_planned_to_verified(
    model: PlannedResourceModel
) -> VerifiedResourceModel {
    require_model_stage_advance(
        model_stage_planned(), model_stage_verified())
    VerifiedResourceModel { manifest: model.manifest }
}

// ============================================================
// ParamMode lattice and independent FORCE bit
// ============================================================

const PARAM_MODE_BOTTOM: Int = 0
const PARAM_MODE_BORROW: Int = 1
const PARAM_MODE_MUT_BORROW: Int = 2
const PARAM_MODE_OWN: Int = 3
const PARAM_MODE_CONFLICT: Int = 4
const PARAM_MODE_COUNT: Int = 5

const PARAM_MODE_JOIN_TAGS: List<Int> = [
    0, 1, 2, 3, 4,
    1, 1, 4, 4, 4,
    2, 4, 2, 4, 4,
    3, 4, 4, 3, 4,
    4, 4, 4, 4, 4
]
const PARAM_MODE_RANKS: List<Int> = [0, 1, 1, 1, 2]

pub struct ParamMode {
    tag: Int
}

pub fn param_mode_from_tag(tag: Int) -> ParamMode {
    if tag < PARAM_MODE_BOTTOM || tag >= PARAM_MODE_COUNT {
        panic("resource model: invalid ParamMode tag")
    }
    ParamMode { tag: tag }
}

pub fn param_mode_bottom() -> ParamMode {
    param_mode_from_tag(PARAM_MODE_BOTTOM)
}

pub fn param_mode_borrow() -> ParamMode {
    param_mode_from_tag(PARAM_MODE_BORROW)
}

pub fn param_mode_mut_borrow() -> ParamMode {
    param_mode_from_tag(PARAM_MODE_MUT_BORROW)
}

pub fn param_mode_own() -> ParamMode {
    param_mode_from_tag(PARAM_MODE_OWN)
}

pub fn param_mode_conflict() -> ParamMode {
    param_mode_from_tag(PARAM_MODE_CONFLICT)
}

pub fn param_mode_tag(mode: ParamMode) -> Int {
    param_mode_from_tag(mode.tag).tag
}

pub fn param_mode_same(left: ParamMode, right: ParamMode) -> Bool {
    param_mode_tag(left) == param_mode_tag(right)
}

pub fn param_mode_join(left: ParamMode, right: ParamMode) -> ParamMode {
    let left_tag = param_mode_tag(left)
    let right_tag = param_mode_tag(right)
    let index = left_tag * PARAM_MODE_COUNT + right_tag
    match PARAM_MODE_JOIN_TAGS.get(index) {
        some(tag) => param_mode_from_tag(tag),
        none => panic("resource model: ParamMode join table is incomplete")
    }
}

pub fn param_mode_leq(left: ParamMode, right: ParamMode) -> Bool {
    param_mode_same(param_mode_join(left, right), right)
}

pub fn param_mode_rank(mode: ParamMode) -> Int {
    match PARAM_MODE_RANKS.get(param_mode_tag(mode)) {
        some(rank) => rank,
        none => panic("resource model: ParamMode rank table is incomplete")
    }
}

pub struct TransferDemand {
    pub mode: ParamMode,
    pub force: Bool
}

pub fn transfer_demand_join(
    left: TransferDemand, right: TransferDemand
) -> TransferDemand {
    TransferDemand {
        mode: param_mode_join(left.mode, right.mode),
        force: left.force || right.force
    }
}

// ============================================================
// Logical and physical shape lattices
// ============================================================

pub struct LogicalOwnershipShape {
    pub direct_drop: Bool,
    pub may_unique: Bool,
    pub param_deps: List<Bool>
}

pub struct PhysicalRcShape {
    pub physical_rc: Bool,
    pub boxing: Bool,
    pub drop_glue: Bool,
    pub foreign_containment: Bool,
    pub param_deps: List<Bool>
}

fn bool_list_join(left: List<Bool>, right: List<Bool>) -> List<Bool> {
    if left.len() != right.len() {
        panic("resource model: shape dependency arity mismatch")
    }
    let mut result: List<Bool> = []
    let mut index = 0
    while index < left.len() {
        match (left.get(index), right.get(index)) {
            (some(a), some(b)) => result.push(a || b),
            _ => panic("resource model: shape dependency list is incomplete")
        }
        index = index + 1
    }
    result
}

fn bool_list_same(left: List<Bool>, right: List<Bool>) -> Bool {
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

fn bool_list_rank(values: List<Bool>) -> Int {
    let mut rank = 0
    for value in values { if value { rank = rank + 1 } }
    rank
}

pub fn validate_logical_ownership_shape(shape: LogicalOwnershipShape) {
    if shape.direct_drop && !shape.may_unique {
        panic("resource model: direct-drop logical shape is not unique-capable")
    }
}

pub fn logical_ownership_shape_join(
    left: LogicalOwnershipShape, right: LogicalOwnershipShape
) -> LogicalOwnershipShape {
    validate_logical_ownership_shape(left)
    validate_logical_ownership_shape(right)
    LogicalOwnershipShape {
        direct_drop: left.direct_drop || right.direct_drop,
        may_unique: left.may_unique || right.may_unique,
        param_deps: bool_list_join(left.param_deps, right.param_deps)
    }
}

pub fn logical_ownership_shape_same(
    left: LogicalOwnershipShape, right: LogicalOwnershipShape
) -> Bool {
    left.direct_drop == right.direct_drop &&
        left.may_unique == right.may_unique &&
        bool_list_same(left.param_deps, right.param_deps)
}

pub fn logical_ownership_shape_leq(
    left: LogicalOwnershipShape, right: LogicalOwnershipShape
) -> Bool {
    logical_ownership_shape_same(
        logical_ownership_shape_join(left, right), right)
}

pub fn logical_ownership_shape_rank(shape: LogicalOwnershipShape) -> Int {
    validate_logical_ownership_shape(shape)
    let direct = if shape.direct_drop { 1 } else { 0 }
    let unique = if shape.may_unique { 1 } else { 0 }
    direct + unique + bool_list_rank(shape.param_deps)
}

pub fn physical_rc_shape_join(
    left: PhysicalRcShape, right: PhysicalRcShape
) -> PhysicalRcShape {
    PhysicalRcShape {
        physical_rc: left.physical_rc || right.physical_rc,
        boxing: left.boxing || right.boxing,
        drop_glue: left.drop_glue || right.drop_glue,
        foreign_containment:
            left.foreign_containment || right.foreign_containment,
        param_deps: bool_list_join(left.param_deps, right.param_deps)
    }
}

pub fn physical_rc_shape_same(
    left: PhysicalRcShape, right: PhysicalRcShape
) -> Bool {
    left.physical_rc == right.physical_rc &&
        left.boxing == right.boxing &&
        left.drop_glue == right.drop_glue &&
        left.foreign_containment == right.foreign_containment &&
        bool_list_same(left.param_deps, right.param_deps)
}

pub fn physical_rc_shape_leq(
    left: PhysicalRcShape, right: PhysicalRcShape
) -> Bool {
    physical_rc_shape_same(physical_rc_shape_join(left, right), right)
}

pub fn physical_rc_shape_rank(shape: PhysicalRcShape) -> Int {
    let rc = if shape.physical_rc { 1 } else { 0 }
    let boxed = if shape.boxing { 1 } else { 0 }
    let glue = if shape.drop_glue { 1 } else { 0 }
    let foreign = if shape.foreign_containment { 1 } else { 0 }
    rc + boxed + glue + foreign + bool_list_rank(shape.param_deps)
}

// ============================================================
// SlotFlow lattice and transitions
// ============================================================

const SLOT_FLOW_EMPTY: Int = 0
const SLOT_FLOW_LIVE: Int = 1
const SLOT_FLOW_MOVED: Int = 2
const SLOT_FLOW_MAYBE_MOVED: Int = 3
const SLOT_FLOW_COUNT: Int = 4

const SLOT_FLOW_JOIN_TAGS: List<Int> = [
    0, 1, 2, 3,
    1, 1, 3, 3,
    2, 3, 2, 3,
    3, 3, 3, 3
]
const SLOT_FLOW_RANKS: List<Int> = [0, 1, 1, 2]
const SLOT_FLOW_ASSIGNMENT_TAGS: List<Int> = [1, 1, 1, 1]
const SLOT_FLOW_TAKE_TAGS: List<Int> = [0, 2, 2, 3]
const SLOT_FLOW_TAKE_FINDINGS: List<Bool> = [true, false, true, true]

pub struct SlotFlow {
    tag: Int
}

pub struct SlotFlowTransition {
    pub flow: SlotFlow,
    pub requires_finding: Bool
}

pub fn slot_flow_from_tag(tag: Int) -> SlotFlow {
    if tag < SLOT_FLOW_EMPTY || tag >= SLOT_FLOW_COUNT {
        panic("resource model: invalid SlotFlow tag")
    }
    SlotFlow { tag: tag }
}

pub fn slot_flow_empty() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_EMPTY)
}

pub fn slot_flow_live() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_LIVE)
}

pub fn slot_flow_moved() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_MOVED)
}

pub fn slot_flow_maybe_moved() -> SlotFlow {
    slot_flow_from_tag(SLOT_FLOW_MAYBE_MOVED)
}

pub fn slot_flow_tag(flow: SlotFlow) -> Int {
    slot_flow_from_tag(flow.tag).tag
}

pub fn slot_flow_same(left: SlotFlow, right: SlotFlow) -> Bool {
    slot_flow_tag(left) == slot_flow_tag(right)
}

pub fn slot_flow_join(left: SlotFlow, right: SlotFlow) -> SlotFlow {
    let left_tag = slot_flow_tag(left)
    let right_tag = slot_flow_tag(right)
    let index = left_tag * SLOT_FLOW_COUNT + right_tag
    match SLOT_FLOW_JOIN_TAGS.get(index) {
        some(tag) => slot_flow_from_tag(tag),
        none => panic("resource model: SlotFlow join table is incomplete")
    }
}

pub fn slot_flow_leq(left: SlotFlow, right: SlotFlow) -> Bool {
    slot_flow_same(slot_flow_join(left, right), right)
}

pub fn slot_flow_rank(flow: SlotFlow) -> Int {
    match SLOT_FLOW_RANKS.get(slot_flow_tag(flow)) {
        some(rank) => rank,
        none => panic("resource model: SlotFlow rank table is incomplete")
    }
}

pub fn slot_flow_after_assignment(flow: SlotFlow) -> SlotFlow {
    match SLOT_FLOW_ASSIGNMENT_TAGS.get(slot_flow_tag(flow)) {
        some(tag) => slot_flow_from_tag(tag),
        none => panic("resource model: assignment transition table is incomplete")
    }
}

pub fn slot_flow_take(flow: SlotFlow) -> SlotFlowTransition {
    let tag = slot_flow_tag(flow)
    match (SLOT_FLOW_TAKE_TAGS.get(tag),
           SLOT_FLOW_TAKE_FINDINGS.get(tag)) {
        (some(next), some(finding)) => SlotFlowTransition {
            flow: slot_flow_from_tag(next),
            requires_finding: finding
        },
        _ => panic("resource model: Take transition table is incomplete")
    }
}
