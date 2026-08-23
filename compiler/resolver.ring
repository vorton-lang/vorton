use ast::{Program, Decl, UseDecl, UseImport, StructFieldDecl, DeriveAttribute,
    Span, Position}
use parser::{parse}
use diagnostics::{CollectingSink, Diagnostic, DiagnosticNote, Severity, DiagnosticContext,
    new_collecting_sink, make_diag}
use formatter::{format_human, format_llm}
use hir::{compare_by_first, module_item_identity, variant_ctor_name}
use codes::{E0207, E0702, E0704, E0705}
use ir_identity::{
    SymbolRef, NominalFieldRef, TraitMethodRef, ImplProviderRef,
    make_symbol_ref, make_nominal_field_ref, make_trait_method_ref,
    make_module_body_ref, path_owner_for_module_body, make_path_ref,
    path_role_declaration, path_role_synthetic,
    make_impl_provider_ref, impl_provider_kind_source,
    impl_provider_kind_derived, impl_provider_kind_delegate,
    namespace_value, namespace_nominal, namespace_trait, namespace_effect,
    namespace_member,
    namespace_kind_same,
    symbol_ref_origin_module_key, symbol_ref_namespace_kind,
    symbol_ref_canonical_payload, symbol_ref_declaration_site_path,
    symbol_ref_same}

// ============================================================
// Types
// ============================================================

pub struct ModuleId {
    pub path_segments: List<Str>,
    pub file_path: Str
}

pub struct ModuleGraph {
    pub entry: ModuleId,
    pub modules: Map<Str, ModuleId>,
    pub dependencies: Map<Str, List<Str>>,
    pub topo_order: List<Str>,
    pub asts: Map<Str, Program>,
    pub namespace_plan: ResolvedNamespacePlan
}

pub struct GraphError {
    pub message: Str,
    pub cycle: List<Str>?
}

// This plan is deliberately portable: it contains no source spans, inference
// state, HIR, or checker identities.  AstSite is the only bridge back to the
// parsed program, and build_module_graph owns that adapter.
pub enum NamespaceKind {
    Value,
    Struct,
    Enum,
    TypeAlias,
    Effect,
    EffectAlias,
    Trait
}

pub enum ImportSelection {
    Named,
    Wildcard
}

pub enum ImportIssueKind {
    RelativeOutOfScope,
    SourceFrameMissing,
    SourceNameMissing,
    AmbiguousBinding,
    UnresolvedImportCycle
}

pub struct AstSite {
    pub file_key: Str,
    pub frame_index: Int,
    pub use_index: Int,
    // -1 denotes a module/wildcard import rather than one named item.
    pub item_index: Int
}

pub struct ModuleFramePlan {
    pub file_key: Str,
    pub frame_index: Int,
    pub parent_frame_index: Int,
    pub decl_index: Int,
    pub owner: Str,
    pub root_owner: Str,
    pub inline_prefix: Str,
    pub is_public: Bool
}

// The census owns this semantic distinction.  Later collision handling must
// never guess it from an exposed spelling, payload, or AstSite: eager
// projections retain their source role even though their target spelling is
// qualified.
pub enum NamespaceSeedRole {
    DirectDecl,
    EnumLeaf,
    EnumQualifiedMember
}

pub struct NamespaceSeed {
    pub file_key: Str,
    pub frame_index: Int,
    pub decl_index: Int,
    // Exact declaration origin.  Eager projections change the target frame
    // and owner, but never rewrite this portable source identity.
    pub origin_site: AstSite,
    pub owner: Str,
    pub exposed_name: Str,
    pub namespace: NamespaceKind,
    pub symbol: SymbolRef,
    pub is_public: Bool,
    pub role: NamespaceSeedRole,
    pub is_projection: Bool
}

// Source declaration cardinality is decided once, before registration and
// before project namespace construction.  This namespace is intentionally
// finer than IR identity's nominal/effect axes because it mirrors the current
// resolver lookup tables exactly.
pub enum DirectDeclarationNamespace {
    Value,
    Struct,
    Enum,
    TypeAlias,
    Effect,
    EffectAlias,
    Trait,
    Module
}

struct DirectDeclarationSite {
    namespace: DirectDeclarationNamespace,
    name: Str,
    span: Span
}

pub struct DuplicateDirectDeclaration {
    pub namespace: DirectDeclarationNamespace,
    pub name: Str,
    pub first_span: Span,
    pub duplicate_span: Span
}

fn direct_declaration_namespace_key(
    namespace: DirectDeclarationNamespace
) -> Str {
    match namespace {
        DirectDeclarationNamespace::Value => "value",
        DirectDeclarationNamespace::Struct => "struct",
        DirectDeclarationNamespace::Enum => "enum",
        DirectDeclarationNamespace::TypeAlias => "type-alias",
        DirectDeclarationNamespace::Effect => "effect",
        DirectDeclarationNamespace::EffectAlias => "effect-alias",
        DirectDeclarationNamespace::Trait => "trait",
        DirectDeclarationNamespace::Module => "module"
    }
}

fn direct_declaration_site(decl: Decl) -> DirectDeclarationSite? {
    match decl {
        Decl::Fn { name, span, .. } => some(DirectDeclarationSite {
            namespace: DirectDeclarationNamespace::Value,
            name: name, span: span
        }),
        Decl::ExternFn { name, span, .. } => some(DirectDeclarationSite {
            namespace: DirectDeclarationNamespace::Value,
            name: name, span: span
        }),
        Decl::Const { name, span, .. } => some(DirectDeclarationSite {
            namespace: DirectDeclarationNamespace::Value,
            name: name, span: span
        }),
        Decl::Struct { name, span, .. } => some(DirectDeclarationSite {
            namespace: DirectDeclarationNamespace::Struct,
            name: name, span: span
        }),
        Decl::ExternType { name, span, .. } => some(DirectDeclarationSite {
            namespace: DirectDeclarationNamespace::Struct,
            name: name, span: span
        }),
        Decl::Enum { name, span, .. } => some(DirectDeclarationSite {
            namespace: DirectDeclarationNamespace::Enum,
            name: name, span: span
        }),
        Decl::TypeAlias { name, span, .. } => some(DirectDeclarationSite {
            namespace: DirectDeclarationNamespace::TypeAlias,
            name: name, span: span
        }),
        Decl::Effect { name, span, .. } => some(DirectDeclarationSite {
            namespace: DirectDeclarationNamespace::Effect,
            name: name, span: span
        }),
        Decl::EffectAlias { name, span, .. } => some(DirectDeclarationSite {
            namespace: DirectDeclarationNamespace::EffectAlias,
            name: name, span: span
        }),
        Decl::Trait { name, span, .. } => some(DirectDeclarationSite {
            namespace: DirectDeclarationNamespace::Trait,
            name: name, span: span
        }),
        Decl::ModBlock { name, span, .. } => some(DirectDeclarationSite {
            namespace: DirectDeclarationNamespace::Module,
            name: name, span: span
        }),
        // Impl/Test are not named source declarations. Delegate/AssocType are
        // member forms, not direct module bindings.
        _ => none
    }
}

fn first_duplicate_direct_declaration_in_scope(
    decls: List<Decl>
) -> DuplicateDirectDeclaration? {
    // The census is deliberately fresh for every direct declaration list:
    // same-leaf declarations under different parents are independent.
    let mut seen: Map<Str, DirectDeclarationSite> = map_new()
    for decl in decls {
        match direct_declaration_site(decl) {
            some(site) => {
                let key = "${direct_declaration_namespace_key(
                    site.namespace)}|${site.name}"
                match seen.get(key) {
                    some(existing) => return some(
                        DuplicateDirectDeclaration {
                            namespace: site.namespace,
                            name: site.name,
                            first_span: existing.span,
                            duplicate_span: site.span
                        }),
                    none => { seen.insert(key, site) }
                }
            },
            none => {}
        }
        match decl {
            Decl::ModBlock { decls: nested, .. } => {
                match first_duplicate_direct_declaration_in_scope(nested) {
                    some(duplicate) => return some(duplicate),
                    none => {}
                }
            },
            _ => {}
        }
    }
    none
}

pub fn first_duplicate_direct_declaration(
    program: Program
) -> DuplicateDirectDeclaration? {
    first_duplicate_direct_declaration_in_scope(program.decls)
}

fn direct_declaration_namespace_is_module(
    namespace: DirectDeclarationNamespace
) -> Bool {
    match namespace {
        DirectDeclarationNamespace::Module => true,
        _ => false
    }
}

fn direct_declaration_namespace_is_effect_alias(
    namespace: DirectDeclarationNamespace
) -> Bool {
    match namespace {
        DirectDeclarationNamespace::EffectAlias => true,
        _ => false
    }
}

pub fn duplicate_direct_declaration_diagnostic(
    duplicate: DuplicateDirectDeclaration
) -> Diagnostic {
    let is_module = direct_declaration_namespace_is_module(
        duplicate.namespace)
    let message = if is_module {
        "Duplicate definition: module '${duplicate.name}' is already defined"
    } else if direct_declaration_namespace_is_effect_alias(
            duplicate.namespace) {
        "Duplicate definition: effect alias '${duplicate.name}' is already defined"
    } else {
        "Duplicate definition: '${duplicate.name}' is already defined"
    }
    let mut diagnostic = make_diag(
        E0207, Severity::SevError,
        message,
        duplicate.duplicate_span,
        DiagnosticContext::OtherContext {
            detail: some("duplicate direct source declaration")
        })
    diagnostic.notes.push(DiagnosticNote {
        message: if is_module {
            "first module declaration is here"
        } else {
            "first declaration is here"
        },
        span: some(duplicate.first_span)
    })
    diagnostic
}

pub struct EnumVariantFactGroup {
    pub enum_symbol: SymbolRef,
    pub constructors: List<NamespaceSeed>
}

pub struct StructFieldIdentityFact {
    pub field_index: Int,
    pub field_ref: NominalFieldRef
}

pub struct StructIdentityFact {
    pub file_key: Str,
    pub frame_index: Int,
    pub decl_index: Int,
    pub owner_ref: SymbolRef,
    pub fields: List<StructFieldIdentityFact>,
    pub is_extern: Bool
}

pub struct TraitIdentityFact {
    pub file_key: Str,
    pub frame_index: Int,
    pub decl_index: Int,
    pub owner_ref: SymbolRef,
    pub methods: List<TraitMethodRef>
}

pub struct SourceImplProviderFact {
    pub file_key: Str,
    pub frame_index: Int,
    pub decl_index: Int,
    pub provider_ref: ImplProviderRef
}

pub struct DelegateProviderFact {
    pub file_key: Str,
    pub frame_index: Int,
    pub parent_decl_index: Int,
    pub source_member_index: Int,
    pub parent_provider_ref: ImplProviderRef,
    pub provider_ref: ImplProviderRef
}

pub struct ExplicitDerivedProviderFact {
    pub attr_index: Int,
    pub provider_ref: ImplProviderRef
}

pub struct NominalDerivedProviderPlanFact {
    pub file_key: Str,
    pub frame_index: Int,
    pub decl_index: Int,
    pub implicit_provider_ref: ImplProviderRef,
    pub explicit_providers: List<ExplicitDerivedProviderFact>
}

// Kept parallel to the worklist fact table so later consumers never have to
// infer declaration-vs-import identity from a payload, owner, or AstSite.
enum NamespaceFactProvenance {
    Seed,
    NamedImport,
    WildcardImport,
    // Bare leaves copied from a named enum import have legacy source-order
    // overwrite semantics.  Keep both the logical source and the exact
    // obligation identity so ordinary named imports and duplicate-source
    // deliveries never inherit that exception.
    NamedEnumRelation {
        source_owner: Str,
        obligation_index: Int
    }
}

struct NamespaceFactOccurrence {
    provenance: NamespaceFactProvenance,
    // Diagnostic origin and propagation target are independent.  In
    // particular, an eager projection targets frame zero while retaining the
    // exact nested declaration AstSite.
    site: AstSite,
    // Canonical enum-constructor declaration origin for relation-derived
    // leaves.  Import site above remains the diagnostic and overwrite-order
    // identity; eager projection preserves both.
    leaf_origin_site: AstSite?,
    target_file_key: Str,
    target_frame_index: Int,
    seed_role: NamespaceSeedRole?,
    is_projection: Bool
}

enum NamespaceDeliveryLane {
    Local,
    Publication
}

struct NamespaceQueueEvent {
    binding_index: Int,
    lane: NamespaceDeliveryLane
}

struct NamespaceImportCandidate {
    binding: ResolvedNamespaceBinding,
    occurrence: NamespaceFactOccurrence
}

struct PendingNamedEnumRelationFact {
    binding: ResolvedNamespaceBinding,
    occurrence: NamespaceFactOccurrence
}

struct ValueProducerId {
    key: Str
}

struct ValueContribution {
    producer: ValueProducerId,
    binding: ResolvedNamespaceBinding,
    occurrence: NamespaceFactOccurrence
}

struct NamedEnumRelationExpansion {
    obligation_index: Int,
    enum_symbol: SymbolRef
}

struct ValueBindingTarget {
    file_key: Str,
    frame_index: Int,
    owner: Str,
    exposed_name: Str,
    is_public: Bool
}

enum ValueStructuralProducerSource {
    TerminalValue(SymbolRef),
    ImportCopyValue {
        source_slot_index: Int,
        source_lane: NamespaceDeliveryLane,
        obligation_index: Int
    },
    ProjectionCopyValue {
        source_slot_index: Int
    }
}

struct ValueStructuralProducer {
    producer: ValueProducerId,
    target: ValueBindingTarget,
    occurrence: NamespaceFactOccurrence,
    source: ValueStructuralProducerSource
}

struct ValueStructuralSlot {
    target: ValueBindingTarget,
    producers: List<ValueStructuralProducer>,
    local_announced: Bool,
    publication_announced: Bool,
    projection_registered: Bool,
    has_public_seed_terminal: Bool,
    local_winner_index: Int,
    publication_winner_index: Int
}

struct ValueLaneAnnouncement {
    slot_index: Int,
    lane: NamespaceDeliveryLane
}

struct ValueLaneNode {
    slot_index: Int,
    lane: NamespaceDeliveryLane,
    winner_index: Int
}

struct NamespaceGrowthSchemaEdge {
    source_node: Str,
    target_node: Str,
    obligation_index: Int,
    source_file_key: Str,
    source_frame_index: Int,
    source_lane: NamespaceDeliveryLane,
    is_prefix: Bool
}

struct NamespaceGrowthGuard {
    dangerous_edges: Map<Str, List<Int>>,
    component_first_obligation: Map<Int, Int>,
    component_obligations: Map<Int, List<Int>>,
    component_nodes: Map<Int, List<Str>>
}

pub struct ImportObligation {
    pub file_key: Str,
    pub target_frame_index: Int,
    pub target_owner: Str,
    pub source_owner: Str,
    pub source_name: Str,
    pub local_name: Str,
    pub selection: ImportSelection,
    pub is_public: Bool,
    pub site: AstSite
}

pub struct PhysicalDependencyObligation {
    pub file_key: Str,
    pub module_key: Str,
    pub module_segments: List<Str>,
    pub site: AstSite
}

pub struct ResolvedNamespaceBinding {
    pub file_key: Str,
    pub frame_index: Int,
    pub owner: Str,
    pub exposed_name: Str,
    pub namespace: NamespaceKind,
    pub symbol: SymbolRef,
    pub is_public: Bool
}

pub struct ImportIssue {
    pub kind: ImportIssueKind,
    pub site: AstSite,
    pub source_owner: Str,
    pub source_name: Str,
    pub local_name: Str,
    pub namespace: NamespaceKind,
    pub related_owners: List<Str>
}

pub struct ModuleNamespaceCensus {
    pub file_key: Str,
    pub file_segments: List<Str>,
    pub frames: List<ModuleFramePlan>,
    pub seeds: List<NamespaceSeed>,
    // Exact enum declaration origin -> its constructor Value facts.  Relation
    // lookup is by SymbolRef; canonical payload strings are compatibility
    // projections only and never decide identity.
    pub enum_variant_facts: List<EnumVariantFactGroup>,
    pub struct_identities: List<StructIdentityFact>,
    pub trait_identities: List<TraitIdentityFact>,
    pub source_impl_providers: List<SourceImplProviderFact>,
    pub delegate_providers: List<DelegateProviderFact>,
    pub nominal_derived_providers: List<NominalDerivedProviderPlanFact>,
    pub imports: List<ImportObligation>,
    pub physical_dependencies: List<PhysicalDependencyObligation>,
    pub issues: List<ImportIssue>
}

pub struct ResolvedNamespacePlan {
    pub frames: List<ModuleFramePlan>,
    pub bindings: List<ResolvedNamespaceBinding>,
    pub enum_variant_facts: List<EnumVariantFactGroup>,
    pub struct_identities: List<StructIdentityFact>,
    pub trait_identities: List<TraitIdentityFact>,
    pub source_impl_providers: List<SourceImplProviderFact>,
    pub delegate_providers: List<DelegateProviderFact>,
    pub nominal_derived_providers: List<NominalDerivedProviderPlanFact>,
    pub imports: List<ImportObligation>,
    pub physical_dependencies: List<PhysicalDependencyObligation>,
    pub issues: List<ImportIssue>
}

// ============================================================
// Utility functions
// ============================================================

pub fn module_key(segments: List<Str>) -> Str {
    segments.join("::")
}

pub fn module_prefix(segments: List<Str>) -> Str {
    segments.join("$")
}

pub fn resolve_module_file(use_path_segments: List<Str>, project_root: Str) -> Str? {
    let mut path_part = ""
    for i in 0..use_path_segments.len() {
        match use_path_segments.get(i) {
            some(seg) => {
                if i == 0 { path_part = seg }
                else { path_part = path_join(path_part, seg) }
            },
            none => {},
        }
    }
    let ring_file = "${path_part}.ring"
    let absolute = path_resolve(path_join(project_root, ring_file))
    if file_exists(absolute) { some(absolute) } else { none }
}

// ============================================================
// Portable namespace census
// ============================================================

fn namespace_issue(
    kind: ImportIssueKind, site: AstSite, source_owner: Str,
    source_name: Str, local_name: Str, namespace: NamespaceKind
) -> ImportIssue {
    ImportIssue {
        kind: kind,
        site: site,
        source_owner: source_owner,
        source_name: source_name,
        local_name: local_name,
        namespace: namespace,
        related_owners: []
    }
}

fn collect_inline_frame_headers(
    file_key: Str,
    root_owner: Str,
    parent_inline_prefix: Str,
    parent_frame_index: Int,
    parent_is_public: Bool,
    decls: List<Decl>,
    mut frames: List<ModuleFramePlan>
) {
    for decl_index in 0..decls.len() {
        match decls.get(decl_index) {
            some(decl) => match decl {
                Decl::ModBlock { name, decls: nested, is_pub, .. } => {
                    let inline_prefix = if parent_inline_prefix == "" {
                        name
                    } else {
                        "${parent_inline_prefix}::${name}"
                    }
                    let frame_index = frames.len()
                    let owner = module_item_identity(root_owner, inline_prefix)
                    let effective_public = parent_is_public && is_pub
                    frames.push(ModuleFramePlan {
                        file_key: file_key,
                        frame_index: frame_index,
                        parent_frame_index: parent_frame_index,
                        decl_index: decl_index,
                        owner: owner,
                        root_owner: root_owner,
                        inline_prefix: inline_prefix,
                        is_public: effective_public
                    })
                    collect_inline_frame_headers(
                        file_key, root_owner, inline_prefix, frame_index,
                        effective_public, nested, frames)
                },
                _ => {}
            },
            none => {}
        }
    }
}

fn declaration_payload(frame: ModuleFramePlan, name: Str, is_extern_type: Bool) -> Str {
    if is_extern_type { return name }
    if frame.frame_index == 0 {
        module_item_identity(frame.owner, name)
    } else {
        "${frame.owner}::${name}"
    }
}

fn effective_frame_public(frame: ModuleFramePlan, declared_public: Bool) -> Bool {
    declared_public && (frame.frame_index == 0 || frame.is_public)
}

fn source_declaration_site_path(site: AstSite) -> Str {
    if site.use_index != -1 || site.frame_index < 0 || site.item_index < 0 {
        panic("namespace invariant violated: source declaration AstSite is invalid")
    }
    "frame:${site.frame_index}|item:${site.item_index}"
}

fn source_struct_field_site_path(site: AstSite, field_index: Int) -> Str {
    if field_index < 0 {
        panic("namespace invariant violated: negative struct field index")
    }
    "${source_declaration_site_path(site)}|field:${field_index}|kind:struct-field"
}

// This is the only resolver authority allowed to construct a SymbolRef.
// Imports, projections, enum relations, diamonds, and cycles transport the
// exact value returned here instead of replaying identity from a spelling.
fn source_seed_symbol(
    file_key: Str,
    frame_index: Int,
    decl_index: Int,
    origin_site: AstSite,
    namespace: NamespaceKind,
    canonical_payload: Str,
    existing: Option<SymbolRef>,
    field_index: Int
) -> SymbolRef {
    if origin_site.use_index != -1 ||
       origin_site.frame_index < 0 || origin_site.item_index < 0 ||
       file_key != origin_site.file_key ||
       frame_index != origin_site.frame_index ||
       decl_index != origin_site.item_index {
        panic("namespace invariant violated: source seed/site mismatch")
    }
    let declaration_site_path = if field_index >= 0 {
        source_struct_field_site_path(origin_site, field_index)
    } else {
        source_declaration_site_path(origin_site)
    }
    let identity_namespace = if field_index >= 0 {
        namespace_member()
    } else {
        match namespace {
            NamespaceKind::Value => namespace_value(),
            NamespaceKind::Struct => namespace_nominal(),
            NamespaceKind::Enum => namespace_nominal(),
            NamespaceKind::TypeAlias => namespace_nominal(),
            NamespaceKind::Effect => namespace_effect(),
            NamespaceKind::EffectAlias => namespace_effect(),
            NamespaceKind::Trait => namespace_trait()
        }
    }
    match existing {
        none => make_symbol_ref(
            origin_site.file_key, identity_namespace,
            canonical_payload, declaration_site_path),
        some(symbol) => {
            if symbol_ref_origin_module_key(symbol) != origin_site.file_key ||
               !namespace_kind_same(
                    symbol_ref_namespace_kind(symbol), identity_namespace) ||
               symbol_ref_canonical_payload(symbol) != canonical_payload ||
               symbol_ref_declaration_site_path(symbol) !=
                    declaration_site_path {
                panic("namespace invariant violated: reused source SymbolRef drifted")
            }
            symbol
        }
    }
}

fn append_namespace_seed(
    frame: ModuleFramePlan,
    decl_index: Int,
    exposed_name: Str,
    namespace: NamespaceKind,
    canonical_payload: Str,
    existing_symbol: Option<SymbolRef>,
    is_public: Bool,
    role: NamespaceSeedRole,
    mut seeds: List<NamespaceSeed>
) -> SymbolRef {
    let effective_public = effective_frame_public(frame, is_public)
    let origin_site = AstSite {
        file_key: frame.file_key,
        frame_index: frame.frame_index,
        use_index: -1,
        item_index: decl_index
    }
    let symbol = source_seed_symbol(
        frame.file_key, frame.frame_index, decl_index, origin_site,
        namespace, canonical_payload, existing_symbol, -1)
    seeds.push(NamespaceSeed {
        file_key: frame.file_key,
        frame_index: frame.frame_index,
        decl_index: decl_index,
        origin_site: origin_site,
        owner: frame.owner,
        exposed_name: exposed_name,
        namespace: namespace,
        symbol: symbol,
        is_public: effective_public,
        role: role,
        is_projection: false
    })

    // A public declaration below a fully-public inline path is also a fact in
    // the file-root namespace.  Exact source identity stays unchanged; only
    // the exposed spelling changes.
    if frame.frame_index != 0 && effective_public {
        seeds.push(NamespaceSeed {
            file_key: frame.file_key,
            frame_index: 0,
            decl_index: decl_index,
            origin_site: origin_site,
            owner: frame.root_owner,
            exposed_name: "${frame.inline_prefix}::${exposed_name}",
            namespace: namespace,
            symbol: symbol,
            is_public: true,
            role: role,
            is_projection: true
        })
    }
    symbol
}

fn append_enum_variant_fact_group(
    enum_symbol: SymbolRef,
    constructors: List<NamespaceSeed>,
    mut groups: List<EnumVariantFactGroup>
) {
    for group_index in 0..groups.len() {
        match groups.get(group_index) {
            some(group) => {
                if symbol_ref_same(group.enum_symbol, enum_symbol) {
                    let mut merged = list_clone(group.constructors)
                    merged.extend(constructors)
                    groups.set(group_index, EnumVariantFactGroup {
                        enum_symbol: group.enum_symbol,
                        constructors: merged
                    })
                    return
                }
            },
            none => {}
        }
    }
    groups.push(EnumVariantFactGroup {
        enum_symbol: enum_symbol,
        constructors: constructors
    })
}

fn append_struct_identity_fact(
    fact: StructIdentityFact, mut facts: List<StructIdentityFact>
) {
    for existing in facts {
        if existing.file_key == fact.file_key &&
           existing.frame_index == fact.frame_index &&
           existing.decl_index == fact.decl_index {
            panic("namespace invariant violated: duplicate struct identity site")
        }
    }
    facts.push(fact)
}

fn collect_struct_identity_fact(
    frame: ModuleFramePlan, decl_index: Int,
    owner_ref: SymbolRef, canonical_payload: Str,
    fields: List<StructFieldDecl>, is_extern: Bool,
    mut facts: List<StructIdentityFact>
) {
    let origin_site = AstSite {
        file_key: frame.file_key,
        frame_index: frame.frame_index,
        use_index: -1,
        item_index: decl_index
    }
    let mut field_facts: List<StructFieldIdentityFact> = []
    for field_index in 0..fields.len() {
        match fields.get(field_index) {
            some(field) => {
                let member = source_seed_symbol(
                    frame.file_key, frame.frame_index, decl_index, origin_site,
                    NamespaceKind::Struct,
                    "${canonical_payload}::${field.name}", none, field_index)
                field_facts.push(StructFieldIdentityFact {
                    field_index: field_index,
                    field_ref: make_nominal_field_ref(
                        owner_ref, member, field_index, field.name)
                })
            },
            none => {}
        }
    }
    append_struct_identity_fact(StructIdentityFact {
        file_key: frame.file_key,
        frame_index: frame.frame_index,
        decl_index: decl_index,
        owner_ref: owner_ref,
        fields: field_facts,
        is_extern: is_extern
    }, facts)
}

fn append_trait_identity_fact(
    fact: TraitIdentityFact, mut facts: List<TraitIdentityFact>
) {
    for existing in facts {
        if existing.file_key == fact.file_key &&
           existing.frame_index == fact.frame_index &&
           existing.decl_index == fact.decl_index {
            panic("namespace invariant violated: duplicate trait identity site")
        }
    }
    facts.push(fact)
}

fn collect_trait_identity_fact(
    frame: ModuleFramePlan, decl_index: Int,
    owner_ref: SymbolRef, methods: List<Decl>,
    mut facts: List<TraitIdentityFact>
) {
    let mut method_refs: List<TraitMethodRef> = []
    let mut callable_slot_index = 0
    for source_member_index in 0..methods.len() {
        match methods.get(source_member_index) {
            some(Decl::Fn { name, .. }) => {
                method_refs.push(make_trait_method_ref(
                    owner_ref, source_member_index,
                    callable_slot_index, name))
                callable_slot_index = callable_slot_index + 1
            },
            _ => {}
        }
    }
    append_trait_identity_fact(TraitIdentityFact {
        file_key: frame.file_key,
        frame_index: frame.frame_index,
        decl_index: decl_index,
        owner_ref: owner_ref,
        methods: method_refs
    }, facts)
}

fn source_provider_ref(
    frame: ModuleFramePlan, child_path: List<Str>, source: Bool
) -> ImplProviderRef {
    let module_body = make_module_body_ref(
        frame.file_key, "frame:${frame.frame_index}")
    let role = if source {
        path_role_declaration()
    } else {
        path_role_synthetic()
    }
    let kind = if source {
        impl_provider_kind_source()
    } else {
        impl_provider_kind_derived()
    }
    make_impl_provider_ref(
        make_path_ref(
            path_owner_for_module_body(module_body), child_path, role),
        kind)
}

fn source_delegate_provider_ref(
    frame: ModuleFramePlan, decl_index: Int, source_member_index: Int
) -> ImplProviderRef {
    let module_body = make_module_body_ref(
        frame.file_key, "frame:${frame.frame_index}")
    make_impl_provider_ref(
        make_path_ref(
            path_owner_for_module_body(module_body),
            ["decl:${decl_index}", "delegate:${source_member_index}"],
            path_role_synthetic()),
        impl_provider_kind_delegate())
}

fn append_source_impl_provider_fact(
    fact: SourceImplProviderFact, mut facts: List<SourceImplProviderFact>
) {
    for existing in facts {
        if existing.file_key == fact.file_key &&
           existing.frame_index == fact.frame_index &&
           existing.decl_index == fact.decl_index {
            panic("namespace invariant violated: duplicate source impl provider site")
        }
    }
    facts.push(fact)
}

fn append_delegate_provider_fact(
    fact: DelegateProviderFact, mut facts: List<DelegateProviderFact>
) {
    for existing in facts {
        if existing.file_key == fact.file_key &&
           existing.frame_index == fact.frame_index &&
           existing.parent_decl_index == fact.parent_decl_index &&
           existing.source_member_index == fact.source_member_index {
            panic("namespace invariant violated: duplicate delegate provider site")
        }
    }
    facts.push(fact)
}

fn append_nominal_derived_provider_fact(
    fact: NominalDerivedProviderPlanFact,
    mut facts: List<NominalDerivedProviderPlanFact>
) {
    for existing in facts {
        if existing.file_key == fact.file_key &&
           existing.frame_index == fact.frame_index &&
           existing.decl_index == fact.decl_index {
            panic("namespace invariant violated: duplicate nominal derive provider site")
        }
    }
    facts.push(fact)
}

fn collect_nominal_derived_provider_fact(
    frame: ModuleFramePlan, decl_index: Int,
    derive_attrs: List<DeriveAttribute>,
    mut facts: List<NominalDerivedProviderPlanFact>
) {
    let implicit_provider_ref = source_provider_ref(
        frame, ["decl:${decl_index}", "derive:implicit"], false)
    let mut explicit_providers: List<ExplicitDerivedProviderFact> = []
    for attr_index in 0..derive_attrs.len() {
        explicit_providers.push(ExplicitDerivedProviderFact {
            attr_index: attr_index,
            provider_ref: source_provider_ref(
                frame,
                ["decl:${decl_index}", "derive:attr:${attr_index}"],
                false)
        })
    }
    append_nominal_derived_provider_fact(
        NominalDerivedProviderPlanFact {
            file_key: frame.file_key,
            frame_index: frame.frame_index,
            decl_index: decl_index,
            implicit_provider_ref: implicit_provider_ref,
            explicit_providers: explicit_providers
        }, facts)
}

fn collect_impl_provider_facts(
    frame: ModuleFramePlan, decl_index: Int, methods: List<Decl>,
    mut source_facts: List<SourceImplProviderFact>,
    mut delegate_facts: List<DelegateProviderFact>
) {
    let source = source_provider_ref(
        frame, ["decl:${decl_index}", "impl"], true)
    append_source_impl_provider_fact(SourceImplProviderFact {
        file_key: frame.file_key,
        frame_index: frame.frame_index,
        decl_index: decl_index,
        provider_ref: source
    }, source_facts)
    for source_member_index in 0..methods.len() {
        match methods.get(source_member_index) {
            some(Decl::Delegate { .. }) => append_delegate_provider_fact(
                DelegateProviderFact {
                    file_key: frame.file_key,
                    frame_index: frame.frame_index,
                    parent_decl_index: decl_index,
                    source_member_index: source_member_index,
                    parent_provider_ref: source,
                    provider_ref: source_delegate_provider_ref(
                        frame, decl_index, source_member_index)
                }, delegate_facts),
            _ => {}
        }
    }
}

fn enum_variant_constructors(
    groups: List<EnumVariantFactGroup>, enum_symbol: SymbolRef
) -> Option<List<NamespaceSeed>> {
    for group in groups {
        if symbol_ref_same(group.enum_symbol, enum_symbol) {
            return some(group.constructors)
        }
    }
    none
}

fn collect_decl_seed(
    frame: ModuleFramePlan,
    decl_index: Int,
    decl: Decl,
    mut seeds: List<NamespaceSeed>,
    mut enum_variant_facts: List<EnumVariantFactGroup>,
    mut struct_identities: List<StructIdentityFact>,
    mut trait_identities: List<TraitIdentityFact>,
    mut source_impl_providers: List<SourceImplProviderFact>,
    mut delegate_providers: List<DelegateProviderFact>,
    mut nominal_derived_providers: List<NominalDerivedProviderPlanFact>
) {
    match decl {
        Decl::Fn { name, is_pub, .. } => {
            let _ = append_namespace_seed(frame, decl_index, name, NamespaceKind::Value,
                declaration_payload(frame, name, false), none, is_pub,
                NamespaceSeedRole::DirectDecl, seeds)
        },
        Decl::ExternFn { name, is_pub, .. } => {
            let _ = append_namespace_seed(frame, decl_index, name, NamespaceKind::Value,
                declaration_payload(frame, name, false), none, is_pub,
                NamespaceSeedRole::DirectDecl, seeds)
        },
        Decl::Const { name, is_pub, .. } => {
            let _ = append_namespace_seed(frame, decl_index, name, NamespaceKind::Value,
                declaration_payload(frame, name, false), none, is_pub,
                NamespaceSeedRole::DirectDecl, seeds)
        },
        Decl::Struct { name, fields, derive_attrs, is_pub, .. } => {
            let payload = declaration_payload(frame, name, false)
            let owner_ref = append_namespace_seed(frame, decl_index, name, NamespaceKind::Struct,
                payload, none, is_pub,
                NamespaceSeedRole::DirectDecl, seeds)
            collect_struct_identity_fact(
                frame, decl_index, owner_ref, payload,
                fields, false, struct_identities)
            collect_nominal_derived_provider_fact(
                frame, decl_index, derive_attrs,
                nominal_derived_providers)
        },
        Decl::ExternType { name, is_pub, .. } => {
            // Extern types intentionally retain their raw ABI spelling.
            let payload = declaration_payload(frame, name, true)
            let owner_ref = append_namespace_seed(frame, decl_index, name, NamespaceKind::Struct,
                payload, none, is_pub,
                NamespaceSeedRole::DirectDecl, seeds)
            collect_struct_identity_fact(
                frame, decl_index, owner_ref, payload,
                [], true, struct_identities)
        },
        Decl::Enum { name, variants, derive_attrs, is_pub, .. } => {
            let enum_payload = declaration_payload(frame, name, false)
            let enum_symbol = append_namespace_seed(
                frame, decl_index, name, NamespaceKind::Enum,
                enum_payload, none, is_pub,
                NamespaceSeedRole::DirectDecl, seeds)
            let mut ctor_facts: List<NamespaceSeed> = []
            for variant in variants {
                let ctor_payload = variant_ctor_name(enum_payload, variant.name)
                let ctor_symbol = append_namespace_seed(
                    frame, decl_index, variant.name,
                    NamespaceKind::Value, ctor_payload, none, is_pub,
                    NamespaceSeedRole::EnumLeaf, seeds)
                ctor_facts.push(NamespaceSeed {
                    file_key: frame.file_key,
                    frame_index: frame.frame_index,
                    decl_index: decl_index,
                    origin_site: AstSite {
                        file_key: frame.file_key,
                        frame_index: frame.frame_index,
                        use_index: -1,
                        item_index: decl_index
                    },
                    owner: frame.owner,
                    exposed_name: variant.name,
                    namespace: NamespaceKind::Value,
                    symbol: ctor_symbol,
                    is_public: effective_frame_public(frame, is_pub),
                    role: NamespaceSeedRole::EnumLeaf,
                    is_projection: false
                })
                // Qualified enum-member lookup is an ordinary visible Value
                // fact, not a consumer-side fallback from the Enum relation.
                // Keeping it in the plan makes direct E::V collisions obey
                // the same exact-frame Seed/import ledger as every other name.
                let _ = append_namespace_seed(
                    frame, decl_index, "${name}::${variant.name}",
                    NamespaceKind::Value, ctor_payload, some(ctor_symbol), is_pub,
                    NamespaceSeedRole::EnumQualifiedMember, seeds)
            }
            append_enum_variant_fact_group(
                enum_symbol, ctor_facts, enum_variant_facts)
            collect_nominal_derived_provider_fact(
                frame, decl_index, derive_attrs,
                nominal_derived_providers)
        },
        Decl::TypeAlias { name, is_pub, .. } => {
            let _ = append_namespace_seed(frame, decl_index, name, NamespaceKind::TypeAlias,
                declaration_payload(frame, name, false), none, is_pub,
                NamespaceSeedRole::DirectDecl, seeds)
        },
        Decl::Effect { name, is_pub, .. } => {
            let _ = append_namespace_seed(frame, decl_index, name, NamespaceKind::Effect,
                declaration_payload(frame, name, false), none, is_pub,
                NamespaceSeedRole::DirectDecl, seeds)
        },
        Decl::EffectAlias { name, is_pub, .. } => {
            let _ = append_namespace_seed(frame, decl_index, name, NamespaceKind::EffectAlias,
                declaration_payload(frame, name, false), none, is_pub,
                NamespaceSeedRole::DirectDecl, seeds)
        },
        Decl::Trait { name, methods, is_pub, .. } => {
            let owner_ref = append_namespace_seed(
                frame, decl_index, name, NamespaceKind::Trait,
                declaration_payload(frame, name, false), none, is_pub,
                NamespaceSeedRole::DirectDecl, seeds)
            collect_trait_identity_fact(
                frame, decl_index, owner_ref, methods, trait_identities)
        },
        Decl::Impl { methods, .. } => collect_impl_provider_facts(
            frame, decl_index, methods,
            source_impl_providers, delegate_providers),
        // Impl/Test/Delegate/AssocType do not introduce namespace seeds.
        // ModBlock introduces a frame in pass one and is traversed separately.
        _ => {}
    }
}

fn owner_from_inline_parts(root_owner: Str, inline_parts: List<Str>) -> Str {
    if inline_parts.len() == 0 {
        root_owner
    } else {
        module_item_identity(root_owner, inline_parts.join("::"))
    }
}

pub fn frame_decl_site_key(
    file_key: Str, parent_frame_index: Int, decl_index: Int
) -> Str {
    "${file_key}|frame-decl|${parent_frame_index}|${decl_index}"
}

fn exact_frame_key(file_key: Str, frame_index: Int) -> Str {
    "${file_key}|frame|${frame_index}"
}

fn append_named_obligations(
    frame: ModuleFramePlan,
    source_owner: Str,
    use_index: Int,
    use_decl: UseDecl,
    mut imports: List<ImportObligation>
) {
    match use_decl.imports {
        UseImport::NamedItems { names } => {
            for item_index in 0..names.len() {
                match names.get(item_index) {
                    some(item) => {
                        let local_name = match item.alias {
                            some(alias) => alias,
                            none => item.name
                        }
                        imports.push(ImportObligation {
                            file_key: frame.file_key,
                            target_frame_index: frame.frame_index,
                            target_owner: frame.owner,
                            source_owner: source_owner,
                            source_name: item.name,
                            local_name: local_name,
                            selection: ImportSelection::Named,
                            is_public: effective_frame_public(
                                frame, use_decl.is_pub),
                            site: AstSite {
                                file_key: frame.file_key,
                                frame_index: frame.frame_index,
                                use_index: use_index,
                                item_index: item_index
                            }
                        })
                    },
                    none => {}
                }
            }
        },
        UseImport::Module => {}
    }
}

fn collect_root_use(
    frame: ModuleFramePlan,
    use_index: Int,
    use_decl: UseDecl,
    mut imports: List<ImportObligation>,
    mut physical_dependencies: List<PhysicalDependencyObligation>,
    mut issues: List<ImportIssue>
) {
    let segments = use_decl.path.segments
    let first = segments.get(0).unwrap_or("")
    let use_site = AstSite {
        file_key: frame.file_key,
        frame_index: frame.frame_index,
        use_index: use_index,
        item_index: -1
    }
    if first == "self" || first == "super" {
        issues.push(namespace_issue(
            ImportIssueKind::RelativeOutOfScope, use_site, frame.owner,
            first, "", NamespaceKind::Value))
        return
    }

    // Every root UseDecl is retained, including a NamedItems declaration with
    // an empty item list.  Graph construction performs the only deduplication.
    let dep_key = module_key(segments)
    physical_dependencies.push(PhysicalDependencyObligation {
        file_key: frame.file_key,
        module_key: dep_key,
        module_segments: list_clone(segments),
        site: use_site
    })

    let source_owner = module_prefix(segments)
    match use_decl.imports {
        UseImport::NamedItems { .. } => {
            append_named_obligations(frame, source_owner, use_index, use_decl, imports)
        },
        UseImport::Module => {
            imports.push(ImportObligation {
                file_key: frame.file_key,
                target_frame_index: frame.frame_index,
                target_owner: frame.owner,
                source_owner: source_owner,
                source_name: "",
                local_name: "",
                selection: ImportSelection::Wildcard,
                is_public: effective_frame_public(frame, use_decl.is_pub),
                site: use_site
            })
        }
    }
}

fn relative_inline_base(
    frame: ModuleFramePlan,
    segments: List<Str>,
    site: AstSite,
    mut issues: List<ImportIssue>
) -> List<Str>? {
    let first = segments.get(0).unwrap_or("")
    let mut inline_parts: List<Str> = if frame.inline_prefix == "" {
        []
    } else {
        frame.inline_prefix.split("::")
    }
    let mut index = 1
    if first == "super" {
        if inline_parts.len() == 0 {
            issues.push(namespace_issue(
                ImportIssueKind::RelativeOutOfScope, site, frame.root_owner,
                "super", "", NamespaceKind::Value))
            return none
        }
        inline_parts.pop()
        while index < segments.len() && segments.get(index).unwrap_or("") == "super" {
            if inline_parts.len() == 0 {
                issues.push(namespace_issue(
                    ImportIssueKind::RelativeOutOfScope, site, frame.root_owner,
                    "super", "", NamespaceKind::Value))
                return none
            }
            inline_parts.pop()
            index = index + 1
        }
    }
    while index < segments.len() {
        inline_parts.push(segments.get(index).unwrap_or(""))
        index = index + 1
    }
    some(inline_parts)
}

fn collect_inline_relative_use(
    frame: ModuleFramePlan,
    use_index: Int,
    use_decl: UseDecl,
    mut imports: List<ImportObligation>,
    mut issues: List<ImportIssue>
) {
    let segments = use_decl.path.segments
    let site = AstSite {
        file_key: frame.file_key,
        frame_index: frame.frame_index,
        use_index: use_index,
        item_index: -1
    }
    match use_decl.imports {
        UseImport::NamedItems { .. } => {
            match relative_inline_base(frame, segments, site, issues) {
                some(source_parts) => {
                    let source_owner = owner_from_inline_parts(frame.root_owner, source_parts)
                    append_named_obligations(frame, source_owner, use_index, use_decl, imports)
                },
                none => {}
            }
        },
        UseImport::Module => {
            match relative_inline_base(frame, segments, site, issues) {
                some(source_parts_) => {
                    let mut source_parts = source_parts_
                    if source_parts.len() == 0 {
                        issues.push(namespace_issue(
                            ImportIssueKind::SourceNameMissing, site, frame.owner,
                            "", "", NamespaceKind::Value))
                        return
                    }
                    let source_name = source_parts.pop().unwrap_or("")
                    let source_owner = owner_from_inline_parts(frame.root_owner, source_parts)
                    let local_name = match use_decl.alias {
                        some(alias) => alias,
                        none => source_name
                    }
                    imports.push(ImportObligation {
                        file_key: frame.file_key,
                        target_frame_index: frame.frame_index,
                        target_owner: frame.owner,
                        source_owner: source_owner,
                        source_name: source_name,
                        local_name: local_name,
                        selection: ImportSelection::Named,
                        is_public: effective_frame_public(
                            frame, use_decl.is_pub),
                        site: site
                    })
                },
                none => {}
            }
        }
    }
}

fn collect_inline_nonrelative_use(
    frame: ModuleFramePlan,
    use_index: Int,
    use_decl: UseDecl,
    mut imports: List<ImportObligation>
) {
    let source_owner = module_prefix(use_decl.path.segments)
    match use_decl.imports {
        UseImport::NamedItems { .. } => {
            append_named_obligations(frame, source_owner, use_index, use_decl, imports)
        },
        UseImport::Module => {
            imports.push(ImportObligation {
                file_key: frame.file_key,
                target_frame_index: frame.frame_index,
                target_owner: frame.owner,
                source_owner: source_owner,
                source_name: "",
                local_name: "",
                selection: ImportSelection::Wildcard,
                is_public: effective_frame_public(frame, use_decl.is_pub),
                site: AstSite {
                    file_key: frame.file_key,
                    frame_index: frame.frame_index,
                    use_index: use_index,
                    item_index: -1
                }
            })
        }
    }
}

fn collect_frame_contents(
    frame: ModuleFramePlan,
    uses: List<UseDecl>,
    decls: List<Decl>,
    frames: List<ModuleFramePlan>,
    frame_site_indices: Map<Str, Int>,
    mut seeds: List<NamespaceSeed>,
    mut enum_variant_facts: List<EnumVariantFactGroup>,
    mut struct_identities: List<StructIdentityFact>,
    mut trait_identities: List<TraitIdentityFact>,
    mut source_impl_providers: List<SourceImplProviderFact>,
    mut delegate_providers: List<DelegateProviderFact>,
    mut nominal_derived_providers: List<NominalDerivedProviderPlanFact>,
    mut imports: List<ImportObligation>,
    mut physical_dependencies: List<PhysicalDependencyObligation>,
    mut issues: List<ImportIssue>
) {
    for use_index in 0..uses.len() {
        match uses.get(use_index) {
            some(use_decl) => {
                if frame.frame_index == 0 {
                    collect_root_use(frame, use_index, use_decl,
                        imports, physical_dependencies, issues)
                } else {
                    let first = use_decl.path.segments.get(0).unwrap_or("")
                    if first == "self" || first == "super" {
                        collect_inline_relative_use(
                            frame, use_index, use_decl, imports, issues)
                    } else {
                        // Inline absolute imports participate in the portable
                        // plan but never expand the physical BFS frontier.
                        collect_inline_nonrelative_use(
                            frame, use_index, use_decl, imports)
                    }
                }
            },
            none => {}
        }
    }

    for decl_index in 0..decls.len() {
        match decls.get(decl_index) {
            some(decl) => {
                collect_decl_seed(
                    frame, decl_index, decl, seeds, enum_variant_facts,
                    struct_identities, trait_identities,
                    source_impl_providers, delegate_providers,
                    nominal_derived_providers)
                match decl {
                    Decl::ModBlock { name, uses: nested_uses, decls: nested_decls, .. } => {
                        // Duplicate inline ModBlocks intentionally share a
                        // canonical owner.  Their AST frames do not: recover
                        // the exact pass-one header by its stable parent/decl
                        // site rather than owner.
                        let child_site = frame_decl_site_key(
                            frame.file_key, frame.frame_index, decl_index)
                        match frame_site_indices.get(child_site) {
                            some(child_index) => match frames.get(child_index) {
                                some(child_frame) => {
                                    collect_frame_contents(
                                        child_frame, nested_uses, nested_decls,
                                        frames, frame_site_indices, seeds,
                                        enum_variant_facts, struct_identities,
                                        trait_identities, source_impl_providers,
                                        delegate_providers,
                                        nominal_derived_providers, imports,
                                        physical_dependencies, issues)
                                },
                                none => {}
                            },
                            none => {}
                        }
                    },
                    _ => {}
                }
            },
            none => {}
        }
    }
}

pub fn census_module_namespaces(
    file_segments: List<Str>, program: Program
) -> ModuleNamespaceCensus {
    let file_key = module_key(file_segments)
    let root_owner = module_prefix(file_segments)
    let mut frames: List<ModuleFramePlan> = [ModuleFramePlan {
        file_key: file_key,
        frame_index: 0,
        parent_frame_index: -1,
        decl_index: -1,
        owner: root_owner,
        root_owner: root_owner,
        inline_prefix: "",
        is_public: true
    }]

    // Pass one fixes every frame index before any seed or import is emitted.
    collect_inline_frame_headers(
        file_key, root_owner, "", 0, true, program.decls, frames)

    let mut frame_site_indices: Map<Str, Int> = map_new()
    for frame in frames {
        if frame.parent_frame_index >= 0 {
            frame_site_indices.insert(
                frame_decl_site_key(
                    frame.file_key, frame.parent_frame_index, frame.decl_index),
                frame.frame_index)
        }
    }
    let mut seeds: List<NamespaceSeed> = []
    let mut enum_variant_facts: List<EnumVariantFactGroup> = []
    let mut struct_identities: List<StructIdentityFact> = []
    let mut trait_identities: List<TraitIdentityFact> = []
    let mut source_impl_providers: List<SourceImplProviderFact> = []
    let mut delegate_providers: List<DelegateProviderFact> = []
    let mut nominal_derived_providers:
        List<NominalDerivedProviderPlanFact> = []
    let mut imports: List<ImportObligation> = []
    let mut physical_dependencies: List<PhysicalDependencyObligation> = []
    let mut issues: List<ImportIssue> = []

    // Pass two is preorder over the already-indexed frame tree.
    match frames.get(0) {
        some(root_frame) => {
            collect_frame_contents(
                root_frame, program.uses, program.decls,
                frames, frame_site_indices,
                seeds, enum_variant_facts, struct_identities,
                trait_identities, source_impl_providers,
                delegate_providers, nominal_derived_providers, imports,
                physical_dependencies, issues)
        },
        none => {}
    }

    ModuleNamespaceCensus {
        file_key: file_key,
        file_segments: list_clone(file_segments),
        frames: frames,
        seeds: seeds,
        enum_variant_facts: enum_variant_facts,
        struct_identities: struct_identities,
        trait_identities: trait_identities,
        source_impl_providers: source_impl_providers,
        delegate_providers: delegate_providers,
        nominal_derived_providers: nominal_derived_providers,
        imports: imports,
        physical_dependencies: physical_dependencies,
        issues: issues
    }
}

fn stable_source_basename(file: Str, fallback: Str) -> Str {
    if file == "" || file == "<unknown>" || file == "<memory>" {
        return fallback
    }
    let basename = path_basename(file).replace(".ring", "")
    if basename == "" || basename == "." || basename == "<unknown>" {
        fallback
    } else {
        basename
    }
}

pub fn single_namespace_file_key(program: Program) -> Str {
    module_key([
        "$single$", stable_source_basename(
            program.span.file, "$virtual-source$")
    ])
}

pub fn resolve_single_namespace_plan(program: Program) -> ResolvedNamespacePlan {
    resolve_namespace_plan([census_module_namespaces([
        "$single$", stable_source_basename(
            program.span.file, "$virtual-source$")
    ], program)])
}

pub fn prelude_namespace_file_key(file: Str) -> Str {
    module_key([
        "$prelude$", stable_source_basename(file, "$invalid-prelude$")
    ])
}

pub fn resolve_prelude_namespace_plan(
    file: Str, program: Program
) -> ResolvedNamespacePlan {
    if file == "" {
        panic("namespace invariant violated: prelude file key is empty")
    }
    resolve_namespace_plan([census_module_namespaces([
        "$prelude$", stable_source_basename(file, "$invalid-prelude$")
    ], program)])
}

// ============================================================
// Portable namespace worklist
// ============================================================

fn namespace_tag(namespace: NamespaceKind) -> Str {
    match namespace {
        NamespaceKind::Value => "value",
        NamespaceKind::Struct => "struct",
        NamespaceKind::Enum => "enum",
        NamespaceKind::TypeAlias => "type-alias",
        NamespaceKind::Effect => "effect",
        NamespaceKind::EffectAlias => "effect-alias",
        NamespaceKind::Trait => "trait"
    }
}

fn import_issue_kind_rank(kind: ImportIssueKind) -> Int {
    match kind {
        ImportIssueKind::RelativeOutOfScope => 0,
        ImportIssueKind::SourceFrameMissing => 1,
        ImportIssueKind::SourceNameMissing => 2,
        ImportIssueKind::AmbiguousBinding => 3,
        ImportIssueKind::UnresolvedImportCycle => 4
    }
}

fn namespace_registration_rank(namespace: NamespaceKind) -> Int {
    match namespace {
        NamespaceKind::Value => 0,
        NamespaceKind::Struct => 1,
        NamespaceKind::Enum => 2,
        NamespaceKind::TypeAlias => 3,
        NamespaceKind::Effect => 4,
        NamespaceKind::EffectAlias => 5,
        NamespaceKind::Trait => 6
    }
}

fn compare_import_issues(left: ImportIssue, right: ImportIssue) -> Int {
    if left.site.file_key < right.site.file_key { return -1 }
    if left.site.file_key > right.site.file_key { return 1 }
    if left.site.frame_index < right.site.frame_index { return -1 }
    if left.site.frame_index > right.site.frame_index { return 1 }
    if left.site.use_index < right.site.use_index { return -1 }
    if left.site.use_index > right.site.use_index { return 1 }
    if left.site.item_index < right.site.item_index { return -1 }
    if left.site.item_index > right.site.item_index { return 1 }

    let left_kind = import_issue_kind_rank(left.kind)
    let right_kind = import_issue_kind_rank(right.kind)
    if left_kind < right_kind { return -1 }
    if left_kind > right_kind { return 1 }

    let left_namespace = namespace_registration_rank(left.namespace)
    let right_namespace = namespace_registration_rank(right.namespace)
    if left_namespace < right_namespace { return -1 }
    if left_namespace > right_namespace { return 1 }

    if left.source_owner < right.source_owner { return -1 }
    if left.source_owner > right.source_owner { return 1 }
    if left.source_name < right.source_name { return -1 }
    if left.source_name > right.source_name { return 1 }
    if left.local_name < right.local_name { return -1 }
    if left.local_name > right.local_name { return 1 }

    let shared_related_len =
        if left.related_owners.len() < right.related_owners.len() {
            left.related_owners.len()
        } else {
            right.related_owners.len()
        }
    for index in 0..shared_related_len {
        let left_related =
            left.related_owners.get(index).unwrap_or("")
        let right_related =
            right.related_owners.get(index).unwrap_or("")
        if left_related < right_related { return -1 }
        if left_related > right_related { return 1 }
    }
    if left.related_owners.len() < right.related_owners.len() {
        return -1
    }
    if left.related_owners.len() > right.related_owners.len() {
        return 1
    }
    0
}

fn named_subscription_key(owner: Str, name: Str) -> Str {
    "${owner}|name|${name}"
}

fn wildcard_subscription_key(owner: Str) -> Str {
    "${owner}|wildcard"
}

fn claim_named_enum_relation_expansion(
    obligation_index: Int, enum_symbol: SymbolRef,
    mut expanded_named_enum_relations: List<NamedEnumRelationExpansion>
) -> Bool {
    for expanded in expanded_named_enum_relations {
        if expanded.obligation_index == obligation_index &&
           symbol_ref_same(expanded.enum_symbol, enum_symbol) {
            return false
        }
    }
    expanded_named_enum_relations.push(NamedEnumRelationExpansion {
        obligation_index: obligation_index,
        enum_symbol: enum_symbol
    })
    true
}

fn namespace_binding_key(
    file_key: Str, target_frame_index: Int,
    name: Str, namespace: NamespaceKind
) -> Str {
    "${file_key}|frame|${target_frame_index}|binding|${name}|${namespace_tag(namespace)}"
}

fn append_subscription(
    key: Str, obligation_index: Int,
    mut subscriptions: Map<Str, List<Int>>
) {
    match subscriptions.get(key) {
        some(existing) => existing.push(obligation_index),
        none => { subscriptions.insert(key, [obligation_index]) }
    }
}

fn site_is_before(left: AstSite, right: AstSite) -> Bool {
    if left.file_key < right.file_key { return true }
    if left.file_key > right.file_key { return false }
    if left.frame_index < right.frame_index { return true }
    if left.frame_index > right.frame_index { return false }
    if left.use_index < right.use_index { return true }
    if left.use_index > right.use_index { return false }
    left.item_index < right.item_index
}

fn provenance_is_seed(provenance: NamespaceFactProvenance) -> Bool {
    match provenance {
        NamespaceFactProvenance::Seed => true,
        NamespaceFactProvenance::NamedImport => false,
        NamespaceFactProvenance::WildcardImport => false,
        NamespaceFactProvenance::NamedEnumRelation { .. } => false
    }
}

fn import_provenance(selection: ImportSelection) -> NamespaceFactProvenance {
    match selection {
        ImportSelection::Named => NamespaceFactProvenance::NamedImport,
        ImportSelection::Wildcard => NamespaceFactProvenance::WildcardImport
    }
}

fn binding_with_public(
    binding: ResolvedNamespaceBinding, is_public: Bool
) -> ResolvedNamespaceBinding {
    ResolvedNamespaceBinding {
        file_key: binding.file_key,
        frame_index: binding.frame_index,
        owner: binding.owner,
        exposed_name: binding.exposed_name,
        namespace: binding.namespace,
        symbol: binding.symbol,
        is_public: is_public
    }
}

fn seed_role_is_direct(role: NamespaceSeedRole?) -> Bool {
    match role {
        some(NamespaceSeedRole::DirectDecl) => true,
        _ => false
    }
}

fn seed_role_is_enum_leaf(role: NamespaceSeedRole?) -> Bool {
    match role {
        some(NamespaceSeedRole::EnumLeaf) => true,
        _ => false
    }
}

fn namespace_is_value(namespace: NamespaceKind) -> Bool {
    match namespace {
        NamespaceKind::Value => true,
        _ => false
    }
}

// A private direct Value declaration owns the local leaf after enum
// registration, while a public enum constructor independently remains the
// publication for cross-file imports.  Both facts must be direct facts in one
// exact source frame; qualified members and eager projections never qualify.
fn private_direct_enum_leaf_shadow(
    left_is_public: Bool,
    left_occurrence: NamespaceFactOccurrence,
    right_is_public: Bool,
    right_occurrence: NamespaceFactOccurrence
) -> Bool {
    if !provenance_is_seed(left_occurrence.provenance) ||
       !provenance_is_seed(right_occurrence.provenance) ||
       left_occurrence.is_projection ||
       right_occurrence.is_projection {
        return false
    }
    if left_occurrence.site.file_key != right_occurrence.site.file_key ||
       left_occurrence.site.frame_index != right_occurrence.site.frame_index ||
       left_occurrence.site.file_key != left_occurrence.target_file_key ||
       left_occurrence.site.frame_index != left_occurrence.target_frame_index ||
       right_occurrence.site.file_key != right_occurrence.target_file_key ||
       right_occurrence.site.frame_index != right_occurrence.target_frame_index {
        return false
    }
    let left_direct = seed_role_is_direct(left_occurrence.seed_role)
    let right_direct = seed_role_is_direct(right_occurrence.seed_role)
    let left_leaf = seed_role_is_enum_leaf(left_occurrence.seed_role)
    let right_leaf = seed_role_is_enum_leaf(right_occurrence.seed_role)
    if left_direct && right_leaf { return !left_is_public }
    if right_direct && left_leaf { return !right_is_public }
    false
}

// Enum variant leaves are historical compatibility aliases.  Different enum
// types in one exact source frame may reuse a variant spelling; registration
// order makes the later leaf the local winner, while exact Enum::Variant
// members remain independently addressable.  Eager projections mirror that
// same winner only when both facts came from the same exact origin frame.
// Duplicate logical module frames have distinct origins and still collide.
fn same_frame_seed_enum_leaf_shadow(
    left_occurrence: NamespaceFactOccurrence,
    right_occurrence: NamespaceFactOccurrence
) -> Bool {
    if !provenance_is_seed(left_occurrence.provenance) ||
       !provenance_is_seed(right_occurrence.provenance) ||
       !seed_role_is_enum_leaf(left_occurrence.seed_role) ||
       !seed_role_is_enum_leaf(right_occurrence.seed_role) ||
       left_occurrence.is_projection != right_occurrence.is_projection {
        return false
    }
    if left_occurrence.site.file_key != right_occurrence.site.file_key ||
       left_occurrence.site.frame_index != right_occurrence.site.frame_index ||
       left_occurrence.target_file_key != right_occurrence.target_file_key ||
       left_occurrence.target_frame_index != right_occurrence.target_frame_index {
        return false
    }
    if !left_occurrence.is_projection {
        return
            left_occurrence.site.file_key ==
                left_occurrence.target_file_key &&
            left_occurrence.site.frame_index ==
                left_occurrence.target_frame_index &&
            right_occurrence.site.file_key ==
                right_occurrence.target_file_key &&
            right_occurrence.site.frame_index ==
                right_occurrence.target_frame_index
    }
    true
}

fn provenance_is_named_enum_relation(
    provenance: NamespaceFactProvenance
) -> Bool {
    match provenance {
        NamespaceFactProvenance::NamedEnumRelation { .. } => true,
        _ => false
    }
}

fn provenance_is_strong_import(
    provenance: NamespaceFactProvenance
) -> Bool {
    match provenance {
        NamespaceFactProvenance::NamedImport => true,
        NamespaceFactProvenance::WildcardImport => true,
        _ => false
    }
}

fn occurrence_is_compat_enum_leaf(
    occurrence: NamespaceFactOccurrence
) -> Bool {
    provenance_is_named_enum_relation(occurrence.provenance) &&
    seed_role_is_enum_leaf(occurrence.seed_role) &&
    !occurrence.is_projection
}

// Legacy named-enum leaves are compatibility contributions, not strong
// imports.  Within one exact target frame they and explicit Named/Wildcard
// contributions reduce by target use/item source order.  Strong-vs-strong
// ambiguity remains a separate ledger property.  Projection happens only
// after this direct target lane has selected its Publication winner.
fn same_frame_compat_import_shadow(
    left_occurrence: NamespaceFactOccurrence,
    right_occurrence: NamespaceFactOccurrence
) -> Bool {
    if left_occurrence.is_projection ||
       right_occurrence.is_projection ||
       left_occurrence.site.file_key != right_occurrence.site.file_key ||
       left_occurrence.site.frame_index != right_occurrence.site.frame_index ||
       left_occurrence.target_file_key != right_occurrence.target_file_key ||
       left_occurrence.target_frame_index != right_occurrence.target_frame_index {
        return false
    }
    if left_occurrence.site.file_key !=
           left_occurrence.target_file_key ||
       left_occurrence.site.frame_index !=
           left_occurrence.target_frame_index ||
       right_occurrence.site.file_key !=
           right_occurrence.target_file_key ||
       right_occurrence.site.frame_index !=
           right_occurrence.target_frame_index {
        return false
    }
    let left_compat = occurrence_is_compat_enum_leaf(left_occurrence)
    let right_compat = occurrence_is_compat_enum_leaf(right_occurrence)
    let left_strong =
        provenance_is_strong_import(left_occurrence.provenance)
    let right_strong =
        provenance_is_strong_import(right_occurrence.provenance)
    (left_compat && (right_compat || right_strong)) ||
    (right_compat && (left_compat || left_strong))
}

fn same_frame_ordered_value_shadow(
    left_occurrence: NamespaceFactOccurrence,
    right_occurrence: NamespaceFactOccurrence
) -> Bool {
    same_frame_seed_enum_leaf_shadow(
        left_occurrence, right_occurrence) ||
    same_frame_compat_import_shadow(
        left_occurrence, right_occurrence)
}

fn append_binding_ambiguity(
    key: Str,
    existing_symbol: SymbolRef,
    candidate: ResolvedNamespaceBinding,
    occurrence: NamespaceFactOccurrence,
    mut ambiguous_keys: Set<Str>,
    mut issues: List<ImportIssue>
) {
    if ambiguous_keys.contains(key) { return }
    ambiguous_keys.insert(key)
    issues.push(ImportIssue {
        kind: ImportIssueKind::AmbiguousBinding,
        site: occurrence.site,
        source_owner: candidate.owner,
        source_name: candidate.exposed_name,
        local_name: candidate.exposed_name,
        namespace: candidate.namespace,
        related_owners: [
            symbol_ref_canonical_payload(existing_symbol),
            symbol_ref_canonical_payload(candidate.symbol)]
    })
}

fn record_import_candidate(
    key: Str,
    candidate: ResolvedNamespaceBinding,
    occurrence: NamespaceFactOccurrence,
    mut import_ledger: Map<Str, List<NamespaceImportCandidate>>
) {
    if provenance_is_seed(occurrence.provenance) ||
       provenance_is_named_enum_relation(occurrence.provenance) {
        return
    }

    let recorded = NamespaceImportCandidate {
        binding: candidate,
        occurrence: occurrence
    }
    match import_ledger.get(key) {
        some(existing_candidates) => {
            // Keep every import-derived candidate even when a Seed owns the
            // winner.  Ambiguity is classified after relation-leaf batches
            // have reduced to their active source-order representatives.
            existing_candidates.push(recorded)
        },
        none => {
            import_ledger.insert(key, [recorded])
        }
    }
}

fn append_import_ledger_ambiguities(
    import_ledger: Map<Str, List<NamespaceImportCandidate>>,
    mut ambiguous_keys: Set<Str>,
    mut issues: List<ImportIssue>
) {
    let mut entries = import_ledger.entries()
    entries.sort_by(compare_by_first)
    for entry in entries {
        let (key, candidates) = entry
        if !ambiguous_keys.contains(key) {
            match candidates.get(0) {
                some(first) => {
                    for index in 1..candidates.len() {
                        match candidates.get(index) {
                            some(candidate) => {
                                if !symbol_ref_same(
                                        candidate.binding.symbol,
                                        first.binding.symbol) {
                                    append_binding_ambiguity(
                                        key, first.binding.symbol,
                                        candidate.binding,
                                        candidate.occurrence,
                                        ambiguous_keys, issues)
                                    break
                                }
                            },
                            none => {}
                        }
                    }
                },
                none => {}
            }
        }
    }
}

fn add_namespace_fact(
    candidate: ResolvedNamespaceBinding,
    occurrence: NamespaceFactOccurrence,
    preloading_seeds: Bool,
    mut bindings: List<ResolvedNamespaceBinding>,
    mut winner_occurrences: List<NamespaceFactOccurrence>,
    mut publication_bindings: List<ResolvedNamespaceBinding?>,
    mut publication_occurrences: List<NamespaceFactOccurrence?>,
    mut binding_indices: Map<Str, Int>,
    mut queue: List<NamespaceQueueEvent>,
    mut import_ledger: Map<Str, List<NamespaceImportCandidate>>,
    mut ambiguous_keys: Set<Str>,
    mut issues: List<ImportIssue>
) {
    if candidate.file_key != occurrence.target_file_key ||
       candidate.frame_index != occurrence.target_frame_index {
        panic(
            "namespace invariant violated: fact candidate and occurrence targets differ")
    }
    let key = namespace_binding_key(
        candidate.file_key, candidate.frame_index,
        candidate.exposed_name, candidate.namespace)
    record_import_candidate(key, candidate, occurrence, import_ledger)

    match binding_indices.get(key) {
        some(existing_index) => match (
            bindings.get(existing_index),
            winner_occurrences.get(existing_index),
            publication_bindings.get(existing_index),
            publication_occurrences.get(existing_index)
        ) {
            (
                some(existing), some(existing_occurrence),
                some(publication_binding), some(publication_occurrence)
            ) => {
                let existing_is_seed =
                    provenance_is_seed(existing_occurrence.provenance)
                let candidate_is_seed =
                    provenance_is_seed(occurrence.provenance)
                let direct_shadow_pair = private_direct_enum_leaf_shadow(
                    existing.is_public, existing_occurrence,
                    candidate.is_public, occurrence)
                let ordered_value_shadow_pair =
                    same_frame_ordered_value_shadow(
                    existing_occurrence, occurrence)
                let candidate_is_compat_enum_leaf =
                    occurrence_is_compat_enum_leaf(occurrence)
                let candidate_ordered_value_is_later =
                    ordered_value_shadow_pair &&
                    site_is_before(existing_occurrence.site, occurrence.site)
                // Publication has its own winner.  Local may currently be a
                // private DirectDecl between two public enum leaves, so its
                // occurrence cannot determine public leaf source order.
                let candidate_publication_value_is_later = match (
                    publication_binding, publication_occurrence
                ) {
                    (some(current_publication),
                     some(current_publication_occurrence)) =>
                        same_frame_ordered_value_shadow(
                            current_publication_occurrence,
                            occurrence) &&
                        site_is_before(
                            current_publication_occurrence.site,
                            occurrence.site),
                    _ => false
                }
                let mut next_local = existing
                let mut next_local_occurrence = existing_occurrence
                let mut local_replaced = false

                if symbol_ref_same(existing.symbol, candidate.symbol) {
                    if candidate_is_seed && !existing_is_seed {
                        if !preloading_seeds {
                            panic(
                                "namespace invariant violated: Seed would replace an installed Import lane")
                        }
                        next_local = candidate
                        next_local_occurrence = occurrence
                        local_replaced = true
                    } else if candidate_ordered_value_is_later {
                        if !preloading_seeds &&
                           !candidate_is_compat_enum_leaf {
                            panic(
                                "namespace invariant violated: consumed Local lane occurrence cannot be replaced")
                        }
                        // The declaration origin is exact-identical, but later
                        // relation comparisons must still see the active
                        // source-order occurrence.
                        next_local = candidate
                        next_local_occurrence = occurrence
                        local_replaced = true
                    }
                } else {
                    if direct_shadow_pair || ordered_value_shadow_pair {
                        if seed_role_is_direct(occurrence.seed_role) ||
                           candidate_ordered_value_is_later {
                            if !preloading_seeds &&
                               !candidate_is_compat_enum_leaf {
                                panic(
                                    "namespace invariant violated: consumed Local lane cannot be replaced")
                            }
                            next_local = candidate
                            next_local_occurrence = occurrence
                            local_replaced = true
                        }
                    } else {
                        match (existing_is_seed, candidate_is_seed) {
                            (true, false) => {
                                // Seed owns Local.  The losing Import was
                                // recorded above so Import-vs-Import ambiguity
                                // remains independent from this precedence.
                            },
                            (false, false) => {
                                // The first Import owns Local; the ledger owns
                                // every distinct Import-vs-Import diagnostic.
                            },
                            (true, true) => {
                                if !preloading_seeds {
                                    panic(
                                        "namespace invariant violated: distinct Seed arrived after preload")
                                }
                                append_binding_ambiguity(
                                    key, existing.symbol, candidate, occurrence,
                                    ambiguous_keys, issues)
                            },
                            (false, true) => {
                                panic(
                                    "namespace invariant violated: distinct Seed arrived after Import")
                            }
                        }
                    }
                }

                let mut next_publication = publication_binding
                let mut next_publication_occurrence = publication_occurrence
                let mut publication_created = false
                if candidate.is_public {
                    if candidate_publication_value_is_later {
                        if !preloading_seeds &&
                           !candidate_is_compat_enum_leaf {
                            panic(
                                "namespace invariant violated: consumed Publication lane cannot be replaced")
                        }
                        publication_created = match publication_binding {
                            none => true,
                            some(_) => false
                        }
                        next_publication = some(
                            binding_with_public(candidate, true))
                        next_publication_occurrence = some(occurrence)
                    } else {
                        match publication_binding {
                            none => {
                                // A public candidate may publish the Local
                                // exact origin, the enum side of the legal private
                                // DirectDecl/EnumLeaf split, or the sole public
                                // contribution below a later private
                                // compat/strong Local winner.
                                if symbol_ref_same(
                                       candidate.symbol, next_local.symbol) ||
                                   direct_shadow_pair ||
                                   ordered_value_shadow_pair {
                                    if candidate_is_seed && !preloading_seeds {
                                        panic(
                                            "namespace invariant violated: late Seed would create Publication lane")
                                    }
                                    next_publication = some(
                                        binding_with_public(candidate, true))
                                    next_publication_occurrence = some(occurrence)
                                    publication_created = true
                                }
                            },
                            some(existing_publication) => {
                                if !symbol_ref_same(
                                       existing_publication.symbol,
                                       candidate.symbol) &&
                                   candidate_is_seed && !preloading_seeds {
                                    panic(
                                        "namespace invariant violated: late distinct Seed reached Publication lane")
                                }
                                // Distinct publication collisions have already
                                // been classified by Local precedence or the
                                // Import ledger.  The first publication remains
                                // stable; same-origin candidates need no update.
                            }
                        }
                    }
                }

                let local_is_public = match next_publication {
                    some(publication) => symbol_ref_same(
                        publication.symbol, next_local.symbol),
                    none => false
                }
                bindings.set(
                    existing_index,
                    binding_with_public(next_local, local_is_public))
                winner_occurrences.set(
                    existing_index, next_local_occurrence)
                publication_bindings.set(
                    existing_index, next_publication)
                publication_occurrences.set(
                    existing_index, next_publication_occurrence)

                if local_replaced && !preloading_seeds &&
                   !candidate_is_compat_enum_leaf {
                    panic(
                        "namespace invariant violated: consumed Local lane was replaced")
                }
                if publication_created && !preloading_seeds {
                    queue.push(NamespaceQueueEvent {
                        binding_index: existing_index,
                        lane: NamespaceDeliveryLane::Publication
                    })
                }
            },
            _ => {}
        },
        none => {
            if provenance_is_seed(occurrence.provenance) &&
               !preloading_seeds {
                panic(
                    "namespace invariant violated: new Seed arrived after preload")
            }
            let index = bindings.len()
            bindings.push(binding_with_public(
                candidate, candidate.is_public))
            winner_occurrences.push(occurrence)
            let publication_binding = if candidate.is_public {
                some(binding_with_public(candidate, true))
            } else {
                none
            }
            let publication_occurrence = if candidate.is_public {
                some(occurrence)
            } else {
                none
            }
            publication_bindings.push(publication_binding)
            publication_occurrences.push(publication_occurrence)
            binding_indices.insert(key, index)
            if !preloading_seeds {
                queue.push(NamespaceQueueEvent {
                    binding_index: index,
                    lane: NamespaceDeliveryLane::Local
                })
                if candidate.is_public {
                    queue.push(NamespaceQueueEvent {
                        binding_index: index,
                        lane: NamespaceDeliveryLane::Publication
                    })
                }
            }
        }
    }
}

fn seed_role_tag(role: NamespaceSeedRole?) -> Str {
    match role {
        some(NamespaceSeedRole::DirectDecl) => "direct",
        some(NamespaceSeedRole::EnumLeaf) => "enum-leaf",
        some(NamespaceSeedRole::EnumQualifiedMember) => "enum-qualified",
        none => "none"
    }
}

fn delivery_lane_tag(lane: NamespaceDeliveryLane) -> Str {
    match lane {
        NamespaceDeliveryLane::Local => "local",
        NamespaceDeliveryLane::Publication => "publication"
    }
}

fn value_seed_producer(seed: NamespaceSeed) -> ValueProducerId {
    ValueProducerId {
        key: "seed|${seed.file_key}|${seed.frame_index}|${seed.exposed_name}|${seed.origin_site.file_key}|${seed.origin_site.frame_index}|${seed.origin_site.item_index}|${seed_role_tag(some(seed.role))}|${seed.is_projection}"
    }
}

fn value_relation_producer(
    binding: ResolvedNamespaceBinding,
    occurrence: NamespaceFactOccurrence
) -> ValueProducerId {
    let origin = match occurrence.leaf_origin_site {
        some(site) =>
            "${site.file_key}|${site.frame_index}|${site.item_index}",
        none => "missing-origin"
    }
    match occurrence.provenance {
        NamespaceFactProvenance::NamedEnumRelation {
            source_owner, obligation_index
        } => ValueProducerId {
            key: "relation|${obligation_index}|${source_owner}|${origin}|${binding.exposed_name}|${seed_role_tag(occurrence.seed_role)}"
        },
        _ => panic(
            "namespace invariant violated: relation producer lacks relation provenance")
    }
}

fn value_projection_producer(
    source: ValueBindingTarget
) -> ValueProducerId {
    ValueProducerId {
        key: "projection|${source.file_key}|${source.frame_index}|${source.exposed_name}|publication"
    }
}

fn structural_value_import_producer(
    obligation_index: Int,
    source_slot: ValueStructuralSlot,
    lane: NamespaceDeliveryLane
) -> ValueProducerId {
    ValueProducerId {
        key: "import|${obligation_index}|${source_slot.target.file_key}|${source_slot.target.frame_index}|${source_slot.target.exposed_name}|${delivery_lane_tag(lane)}"
    }
}

fn value_binding_target(
    file_key: Str, frame_index: Int, owner: Str,
    exposed_name: Str, is_public: Bool
) -> ValueBindingTarget {
    ValueBindingTarget {
        file_key: file_key,
        frame_index: frame_index,
        owner: owner,
        exposed_name: exposed_name,
        is_public: is_public
    }
}

fn value_target_from_binding(
    binding: ResolvedNamespaceBinding
) -> ValueBindingTarget {
    if !namespace_is_value(binding.namespace) {
        panic("namespace invariant violated: non-Value structural target")
    }
    value_binding_target(
        binding.file_key, binding.frame_index, binding.owner,
        binding.exposed_name, binding.is_public)
}

fn materialize_value_binding(
    target: ValueBindingTarget, symbol: SymbolRef
) -> ResolvedNamespaceBinding {
    ResolvedNamespaceBinding {
        file_key: target.file_key,
        frame_index: target.frame_index,
        owner: target.owner,
        exposed_name: target.exposed_name,
        namespace: NamespaceKind::Value,
        symbol: symbol,
        is_public: target.is_public
    }
}

fn structural_producer_source_slot_index(
    producer: ValueStructuralProducer
) -> Int {
    match producer.source {
        ValueStructuralProducerSource::ImportCopyValue {
            source_slot_index, ..
        } => source_slot_index,
        ValueStructuralProducerSource::ProjectionCopyValue {
            source_slot_index
        } => source_slot_index,
        ValueStructuralProducerSource::TerminalValue(_) => panic(
            "namespace invariant violated: terminal Value has no source slot")
    }
}

fn structural_producer_source_lane(
    producer: ValueStructuralProducer
) -> NamespaceDeliveryLane {
    match producer.source {
        ValueStructuralProducerSource::ImportCopyValue {
            source_lane, ..
        } => source_lane,
        ValueStructuralProducerSource::ProjectionCopyValue { .. } =>
            NamespaceDeliveryLane::Publication,
        ValueStructuralProducerSource::TerminalValue(_) => panic(
            "namespace invariant violated: terminal Value has no source lane")
    }
}

fn structural_producer_obligation_index(
    producer: ValueStructuralProducer
) -> Int {
    match producer.source {
        ValueStructuralProducerSource::ImportCopyValue {
            obligation_index, ..
        } => obligation_index,
        _ => panic(
            "namespace invariant violated: non-import Value has no obligation")
    }
}

fn structural_producer_is_seed(
    producer: ValueStructuralProducer
) -> Bool {
    match producer.source {
        ValueStructuralProducerSource::TerminalValue(_) =>
            provenance_is_seed(producer.occurrence.provenance),
        _ => false
    }
}

fn structural_slot_has_public_producer(
    slot: ValueStructuralSlot
) -> Bool {
    for producer in slot.producers {
        if producer.target.is_public { return true }
    }
    false
}

fn register_value_structural_producer(
    producer: ValueStructuralProducer,
    announce: Bool,
    mut slots: List<ValueStructuralSlot>,
    mut slot_indices: Map<Str, Int>,
    mut announcements: List<ValueLaneAnnouncement>
) -> Int {
    let key = namespace_binding_key(
        producer.target.file_key,
        producer.target.frame_index,
        producer.target.exposed_name,
        NamespaceKind::Value)
    match slot_indices.get(key) {
        some(slot_index) => {
            match slots.get(slot_index) {
                some(slot) => {
                    for existing in slot.producers {
                        if existing.producer.key == producer.producer.key {
                            return slot_index
                        }
                    }
                    let had_public =
                        structural_slot_has_public_producer(slot)
                    let mut producers = list_clone(slot.producers)
                    producers.push(producer)
                    let has_public_seed_terminal =
                        slot.has_public_seed_terminal ||
                        (producer.target.is_public &&
                         structural_producer_is_seed(producer))
                    let mut local_announced = slot.local_announced
                    let mut publication_announced =
                        slot.publication_announced
                    if announce && !local_announced {
                        local_announced = true
                        announcements.push(ValueLaneAnnouncement {
                            slot_index: slot_index,
                            lane: NamespaceDeliveryLane::Local
                        })
                    }
                    if announce && producer.target.is_public &&
                       !had_public && !publication_announced {
                        publication_announced = true
                        announcements.push(ValueLaneAnnouncement {
                            slot_index: slot_index,
                            lane: NamespaceDeliveryLane::Publication
                        })
                    }
                    slots.set(slot_index, ValueStructuralSlot {
                        target: slot.target,
                        producers: producers,
                        local_announced: local_announced,
                        publication_announced: publication_announced,
                        projection_registered:
                            slot.projection_registered,
                        has_public_seed_terminal:
                            has_public_seed_terminal,
                        local_winner_index: slot.local_winner_index,
                        publication_winner_index:
                            slot.publication_winner_index
                    })
                    slot_index
                },
                none => panic(
                    "namespace invariant violated: Value structural slot index missing")
            }
        },
        none => {
            let slot_index = slots.len()
            let local_announced = announce
            let publication_announced =
                announce && producer.target.is_public
            let has_public_seed_terminal =
                producer.target.is_public &&
                structural_producer_is_seed(producer)
            slots.push(ValueStructuralSlot {
                target: value_binding_target(
                    producer.target.file_key,
                    producer.target.frame_index,
                    producer.target.owner,
                    producer.target.exposed_name,
                    false),
                producers: [producer],
                local_announced: local_announced,
                publication_announced: publication_announced,
                projection_registered: false,
                has_public_seed_terminal: has_public_seed_terminal,
                local_winner_index: -1,
                publication_winner_index: -1
            })
            slot_indices.insert(key, slot_index)
            if local_announced {
                announcements.push(ValueLaneAnnouncement {
                    slot_index: slot_index,
                    lane: NamespaceDeliveryLane::Local
                })
            }
            if publication_announced {
                announcements.push(ValueLaneAnnouncement {
                    slot_index: slot_index,
                    lane: NamespaceDeliveryLane::Publication
                })
            }
            slot_index
        }
    }
}

fn announce_preloaded_value_lanes(
    mut slots: List<ValueStructuralSlot>,
    mut announcements: List<ValueLaneAnnouncement>
) {
    for slot_index in 0..slots.len() {
        match slots.get(slot_index) {
            some(slot) => {
                let publication_available =
                    structural_slot_has_public_producer(slot)
                if !slot.local_announced {
                    announcements.push(ValueLaneAnnouncement {
                        slot_index: slot_index,
                        lane: NamespaceDeliveryLane::Local
                    })
                }
                if publication_available &&
                   !slot.publication_announced {
                    announcements.push(ValueLaneAnnouncement {
                        slot_index: slot_index,
                        lane: NamespaceDeliveryLane::Publication
                    })
                }
                slots.set(slot_index, ValueStructuralSlot {
                    target: slot.target,
                    producers: slot.producers,
                    local_announced: true,
                    publication_announced:
                        slot.publication_announced ||
                        publication_available,
                    projection_registered:
                        slot.projection_registered,
                    has_public_seed_terminal:
                        slot.has_public_seed_terminal,
                    local_winner_index: slot.local_winner_index,
                    publication_winner_index:
                        slot.publication_winner_index
                })
            },
            none => {}
        }
    }
}

fn static_value_winner_index(
    producers: List<ValueStructuralProducer>,
    public_only: Bool
) -> Int {
    let mut winner_index = -1
    for candidate_index in 0..producers.len() {
        match producers.get(candidate_index) {
            some(candidate) => {
                if !public_only || candidate.target.is_public {
                    if winner_index < 0 {
                        winner_index = candidate_index
                    } else {
                        match producers.get(winner_index) {
                            some(existing) => {
                                let existing_is_seed =
                                    structural_producer_is_seed(existing)
                                let candidate_is_seed =
                                    structural_producer_is_seed(candidate)
                                let direct_shadow_pair =
                                    private_direct_enum_leaf_shadow(
                                        existing.target.is_public,
                                        existing.occurrence,
                                        candidate.target.is_public,
                                        candidate.occurrence)
                                let ordered_shadow_pair =
                                    same_frame_ordered_value_shadow(
                                        existing.occurrence,
                                        candidate.occurrence)
                                let candidate_is_later =
                                    ordered_shadow_pair &&
                                    site_is_before(
                                        existing.occurrence.site,
                                        candidate.occurrence.site)
                                let replace =
                                    if candidate_is_seed &&
                                       !existing_is_seed {
                                        true
                                    } else if existing_is_seed &&
                                              !candidate_is_seed {
                                        false
                                    } else if direct_shadow_pair ||
                                              ordered_shadow_pair {
                                        seed_role_is_direct(
                                            candidate.occurrence.seed_role) ||
                                        candidate_is_later
                                    } else {
                                        false
                                    }
                                if replace {
                                    winner_index = candidate_index
                                }
                            },
                            none => {}
                        }
                    }
                }
            },
            none => {}
        }
    }
    winner_index
}

fn compare_value_structural_producers(
    left: ValueStructuralProducer,
    right: ValueStructuralProducer
) -> Int {
    if left.occurrence.site.file_key <
       right.occurrence.site.file_key { return -1 }
    if left.occurrence.site.file_key >
       right.occurrence.site.file_key { return 1 }
    if left.occurrence.site.frame_index <
       right.occurrence.site.frame_index { return -1 }
    if left.occurrence.site.frame_index >
       right.occurrence.site.frame_index { return 1 }
    if left.occurrence.site.use_index <
       right.occurrence.site.use_index { return -1 }
    if left.occurrence.site.use_index >
       right.occurrence.site.use_index { return 1 }
    if left.occurrence.site.item_index <
       right.occurrence.site.item_index { return -1 }
    if left.occurrence.site.item_index >
       right.occurrence.site.item_index { return 1 }
    if left.producer.key < right.producer.key { return -1 }
    if left.producer.key > right.producer.key { return 1 }
    0
}

fn canonicalize_value_structural_producers(
    mut slots: List<ValueStructuralSlot>
) {
    for slot_index in 0..slots.len() {
        match slots.get(slot_index) {
            some(slot) => {
                let mut producers = list_clone(slot.producers)
                producers.sort_by(
                    compare_value_structural_producers)
                slots.set(slot_index, ValueStructuralSlot {
                    target: slot.target,
                    producers: producers,
                    local_announced: slot.local_announced,
                    publication_announced:
                        slot.publication_announced,
                    projection_registered:
                        slot.projection_registered,
                    has_public_seed_terminal:
                        slot.has_public_seed_terminal,
                    local_winner_index: -1,
                    publication_winner_index: -1
                })
            },
            none => {}
        }
    }
}

fn select_static_value_winners(
    mut slots: List<ValueStructuralSlot>
) {
    for slot_index in 0..slots.len() {
        match slots.get(slot_index) {
            some(slot) => {
                slots.set(slot_index, ValueStructuralSlot {
                    target: slot.target,
                    producers: slot.producers,
                    local_announced: slot.local_announced,
                    publication_announced:
                        slot.publication_announced,
                    projection_registered:
                        slot.projection_registered,
                    has_public_seed_terminal:
                        slot.has_public_seed_terminal,
                    local_winner_index:
                        static_value_winner_index(
                            slot.producers, false),
                    publication_winner_index:
                        static_value_winner_index(
                            slot.producers, true)
                })
            },
            none => {}
        }
    }
}

fn refine_structural_projection_occurrences(
    mut slots: List<ValueStructuralSlot>
) {
    for slot_index in 0..slots.len() {
        match slots.get(slot_index) {
            some(slot) => {
                let mut producers = list_clone(slot.producers)
                for producer_index in 0..producers.len() {
                    match producers.get(producer_index) {
                        some(producer) => match producer.source {
                            ValueStructuralProducerSource::ProjectionCopyValue {
                                source_slot_index
                            } => {
                                match slots.get(source_slot_index) {
                                    some(source_slot) => {
                                        if source_slot.publication_winner_index <
                                           0 {
                                            panic(
                                                "namespace invariant violated: projection source lacks static Publication winner")
                                        }
                                        match source_slot.producers.get(
                                            source_slot.publication_winner_index
                                        ) {
                                            some(source_winner) => {
                                                if structural_producer_is_seed(
                                                    source_winner) {
                                                    panic(
                                                        "namespace invariant violated: dynamic projection selected a Seed source")
                                                }
                                                producers.set(
                                                    producer_index,
                                                    ValueStructuralProducer {
                                                        producer:
                                                            producer.producer,
                                                        target:
                                                            producer.target,
                                                        occurrence:
                                                            NamespaceFactOccurrence {
                                                                provenance:
                                                                    source_winner.occurrence.provenance,
                                                                site:
                                                                    source_winner.occurrence.site,
                                                                leaf_origin_site:
                                                                    source_winner.occurrence.leaf_origin_site,
                                                                target_file_key:
                                                                    producer.target.file_key,
                                                                target_frame_index:
                                                                    producer.target.frame_index,
                                                                seed_role:
                                                                    source_winner.occurrence.seed_role,
                                                                is_projection:
                                                                    true
                                                            },
                                                        source:
                                                            producer.source
                                                    })
                                            },
                                            none => {}
                                        }
                                    },
                                    none => {}
                                }
                            },
                            _ => {}
                        },
                        none => {}
                    }
                }
                slots.set(slot_index, ValueStructuralSlot {
                    target: slot.target,
                    producers: producers,
                    local_announced: slot.local_announced,
                    publication_announced:
                        slot.publication_announced,
                    projection_registered:
                        slot.projection_registered,
                    has_public_seed_terminal:
                        slot.has_public_seed_terminal,
                    local_winner_index: slot.local_winner_index,
                    publication_winner_index:
                        slot.publication_winner_index
                })
            },
            none => {}
        }
    }
}

fn value_contribution_is_seed(
    contribution: ValueContribution
) -> Bool {
    provenance_is_seed(contribution.occurrence.provenance)
}

fn value_contribution_is_strong(
    contribution: ValueContribution
) -> Bool {
    !value_contribution_is_seed(contribution) &&
    !occurrence_is_compat_enum_leaf(contribution.occurrence)
}

fn reduce_value_lane(
    contributions: List<ValueContribution>,
    public_only: Bool,
    report_seed_collisions: Bool,
    key: Str,
    mut ambiguous_keys: Set<Str>,
    mut issues: List<ImportIssue>
) -> ValueContribution? {
    let mut winner: ValueContribution? = none
    for candidate in contributions {
        if !public_only || candidate.binding.is_public {
            match winner {
                none => { winner = some(candidate) },
                some(existing) => {
                    let existing_is_seed =
                        value_contribution_is_seed(existing)
                    let candidate_is_seed =
                        value_contribution_is_seed(candidate)
                    let direct_shadow_pair =
                        private_direct_enum_leaf_shadow(
                            existing.binding.is_public, existing.occurrence,
                            candidate.binding.is_public, candidate.occurrence)
                    let ordered_shadow_pair =
                        same_frame_ordered_value_shadow(
                            existing.occurrence, candidate.occurrence)
                    let candidate_is_later =
                        ordered_shadow_pair &&
                        site_is_before(
                            existing.occurrence.site,
                            candidate.occurrence.site)
                    let mut replace = false

                    if symbol_ref_same(
                           existing.binding.symbol,
                           candidate.binding.symbol) {
                        if candidate_is_seed && !existing_is_seed {
                            replace = true
                        } else if candidate_is_later {
                            // Preserve the active source-order occurrence even
                            // when both producers share one exact origin.
                            replace = true
                        }
                    } else if direct_shadow_pair || ordered_shadow_pair {
                        if seed_role_is_direct(
                               candidate.occurrence.seed_role) ||
                           candidate_is_later {
                            replace = true
                        }
                    } else {
                        match (existing_is_seed, candidate_is_seed) {
                            (true, false) => {},
                            (false, false) => {},
                            (false, true) => { replace = true },
                            (true, true) => {
                                if report_seed_collisions {
                                    append_binding_ambiguity(
                                        key, existing.binding.symbol,
                                        candidate.binding,
                                        candidate.occurrence,
                                        ambiguous_keys, issues)
                                }
                            }
                        }
                    }
                    if replace { winner = some(candidate) }
                }
            }
        }
    }
    winner
}

fn import_can_see(source: ResolvedNamespaceBinding, obligation: ImportObligation) -> Bool {
    source.file_key == obligation.file_key || source.is_public
}

fn project_public_inline_fact(
    fact: ResolvedNamespaceBinding,
    occurrence: NamespaceFactOccurrence,
    exact_frames: Map<Str, ModuleFramePlan>,
    mut bindings: List<ResolvedNamespaceBinding>,
    mut winner_occurrences: List<NamespaceFactOccurrence>,
    mut publication_bindings: List<ResolvedNamespaceBinding?>,
    mut publication_occurrences: List<NamespaceFactOccurrence?>,
    mut binding_indices: Map<Str, Int>,
    mut queue: List<NamespaceQueueEvent>,
    mut import_ledger: Map<Str, List<NamespaceImportCandidate>>,
    mut ambiguous_keys: Set<Str>,
    mut issues: List<ImportIssue>
) {
    if !fact.is_public { return }
    // Every public Seed projection was eagerly installed during census and
    // coalesced before this queue started.  Re-emitting one here would be a
    // forbidden late Seed (and would revisit already-classified structural
    // collisions).  Import-derived publications are the only dynamic case.
    if provenance_is_seed(occurrence.provenance) { return }
    // Duplicate logical owners have distinct exact target rows.  Publication
    // occurrence selects the precise row that published this event while its
    // AstSite independently preserves diagnostic origin.
    match exact_frames.get(exact_frame_key(
        occurrence.target_file_key, occurrence.target_frame_index)) {
        some(frame) => {
            if frame.frame_index == 0 || !frame.is_public { return }
            match exact_frames.get(exact_frame_key(frame.file_key, 0)) {
                some(root_frame) => {
                    add_namespace_fact(ResolvedNamespaceBinding {
                        file_key: root_frame.file_key,
                        frame_index: root_frame.frame_index,
                        owner: root_frame.owner,
                        exposed_name: "${frame.inline_prefix}::${fact.exposed_name}",
                        namespace: fact.namespace,
                        symbol: fact.symbol,
                        is_public: true
                    }, NamespaceFactOccurrence {
                        provenance: occurrence.provenance,
                        site: occurrence.site,
                        leaf_origin_site: occurrence.leaf_origin_site,
                        target_file_key: root_frame.file_key,
                        target_frame_index: root_frame.frame_index,
                        seed_role: occurrence.seed_role,
                        is_projection: true
                    }, false, bindings, winner_occurrences,
                    publication_bindings, publication_occurrences,
                    binding_indices, queue,
                    import_ledger, ambiguous_keys, issues)
                },
                none => {}
            }
        },
        none => {}
    }
}

fn deliver_namespace_fact(
    fact: ResolvedNamespaceBinding,
    fact_occurrence: NamespaceFactOccurrence,
    lane: NamespaceDeliveryLane,
    obligation_indices: List<Int>,
    imports: List<ImportObligation>,
    growth_guard: NamespaceGrowthGuard,
    mut blocked_growth_components: Set<Int>,
    enum_variant_facts: List<EnumVariantFactGroup>,
    mut resolved_obligations: Set<Int>,
    mut expanded_named_enum_relations: List<NamedEnumRelationExpansion>,
    mut pending_named_enum_relation_facts:
        List<PendingNamedEnumRelationFact>,
    mut bindings: List<ResolvedNamespaceBinding>,
    mut winner_occurrences: List<NamespaceFactOccurrence>,
    mut publication_bindings: List<ResolvedNamespaceBinding?>,
    mut publication_occurrences: List<NamespaceFactOccurrence?>,
    mut binding_indices: Map<Str, Int>,
    mut queue: List<NamespaceQueueEvent>,
    mut import_ledger: Map<Str, List<NamespaceImportCandidate>>,
    mut ambiguous_keys: Set<Str>,
    mut issues: List<ImportIssue>
) {
    for obligation_index in obligation_indices {
        match imports.get(obligation_index) {
            some(obligation) => {
                let lane_matches = match lane {
                    NamespaceDeliveryLane::Local =>
                        fact.file_key == obligation.file_key,
                    NamespaceDeliveryLane::Publication =>
                        fact.file_key != obligation.file_key
                }
                if lane_matches && import_can_see(fact, obligation) {
                    if block_namespace_growth_delivery(
                        obligation_index, fact.file_key, fact.frame_index,
                        fact.exposed_name, fact.namespace, lane, imports,
                        growth_guard, blocked_growth_components,
                        resolved_obligations, issues) {
                        continue
                    }
                    resolved_obligations.insert(obligation_index)
                    let local_name = match obligation.selection {
                        ImportSelection::Named => obligation.local_name,
                        ImportSelection::Wildcard => fact.exposed_name
                    }
                    add_namespace_fact(ResolvedNamespaceBinding {
                        file_key: obligation.file_key,
                        frame_index: obligation.target_frame_index,
                        owner: obligation.target_owner,
                        exposed_name: local_name,
                        namespace: fact.namespace,
                        symbol: fact.symbol,
                        is_public: obligation.is_public
                    }, NamespaceFactOccurrence {
                        provenance: import_provenance(obligation.selection),
                        site: obligation.site,
                        leaf_origin_site: none,
                        target_file_key: obligation.file_key,
                        target_frame_index: obligation.target_frame_index,
                        seed_role: none,
                        is_projection: false
                    }, false, bindings, winner_occurrences,
                    publication_bindings, publication_occurrences,
                    binding_indices, queue, import_ledger,
                    ambiguous_keys, issues)

                    // Named enum aliases import constructor leaves explicitly.
                    // This is distinct from source closure: the target owner
                    // intentionally differs from each canonical relation fact.
                    // Claim the relation once per obligation and exact enum
                    // declaration origin.  Canonical payload strings never
                    // merge distinct source sites.
                    match (obligation.selection, fact.namespace) {
                        (ImportSelection::Named, NamespaceKind::Enum) => {
                            if claim_named_enum_relation_expansion(
                                obligation_index, fact.symbol,
                                expanded_named_enum_relations) {
                                match enum_variant_constructors(
                                    enum_variant_facts, fact.symbol) {
                                    some(ctor_facts) => {
                                        for ctor in ctor_facts {
                                            let relation_provenance =
                                                NamespaceFactProvenance::NamedEnumRelation {
                                                    source_owner:
                                                        obligation.source_owner,
                                                    obligation_index:
                                                        obligation_index
                                                }
                                            pending_named_enum_relation_facts.push(
                                                PendingNamedEnumRelationFact {
                                                binding: ResolvedNamespaceBinding {
                                                    file_key: obligation.file_key,
                                                    frame_index: obligation.target_frame_index,
                                                    owner: obligation.target_owner,
                                                    exposed_name: ctor.exposed_name,
                                                    namespace: NamespaceKind::Value,
                                                    symbol: ctor.symbol,
                                                    is_public: obligation.is_public
                                                },
                                                occurrence: NamespaceFactOccurrence {
                                                    provenance:
                                                        relation_provenance,
                                                    site: obligation.site,
                                                    leaf_origin_site: some(
                                                        ctor.origin_site),
                                                    target_file_key:
                                                        obligation.file_key,
                                                    target_frame_index:
                                                        obligation.target_frame_index,
                                                    seed_role: some(
                                                        NamespaceSeedRole::EnumLeaf),
                                                    is_projection: false
                                                }
                                            })
                                            // Preserve the legacy explicit
                                            // leaf while also materialising
                                            // the exact alias::Variant member
                                            // spelling as a first-class plan
                                            // Value.  Public projection and
                                            // wildcard propagation then carry
                                            // both through the same worklist.
                                            pending_named_enum_relation_facts.push(
                                                PendingNamedEnumRelationFact {
                                                binding: ResolvedNamespaceBinding {
                                                    file_key: obligation.file_key,
                                                    frame_index: obligation.target_frame_index,
                                                    owner: obligation.target_owner,
                                                    exposed_name:
                                                        "${obligation.local_name}::${ctor.exposed_name}",
                                                    namespace: NamespaceKind::Value,
                                                    symbol: ctor.symbol,
                                                    is_public: obligation.is_public
                                                },
                                                occurrence: NamespaceFactOccurrence {
                                                    provenance:
                                                        relation_provenance,
                                                    site: obligation.site,
                                                    leaf_origin_site: some(
                                                        ctor.origin_site),
                                                    target_file_key:
                                                        obligation.file_key,
                                                    target_frame_index:
                                                        obligation.target_frame_index,
                                                    seed_role: some(
                                                        NamespaceSeedRole::EnumQualifiedMember),
                                                    is_projection: false
                                                }
                                            })
                                        }
                                    },
                                    none => {}
                                }
                            }
                        },
                        _ => {}
                    }
                }
            },
            none => {}
        }
    }
}

fn propagate_namespace_event(
    fact: ResolvedNamespaceBinding,
    fact_occurrence: NamespaceFactOccurrence,
    lane: NamespaceDeliveryLane,
    exact_frames: Map<Str, ModuleFramePlan>,
    named_subscriptions: Map<Str, List<Int>>,
    wildcard_subscriptions: Map<Str, List<Int>>,
    imports: List<ImportObligation>,
    growth_guard: NamespaceGrowthGuard,
    mut blocked_growth_components: Set<Int>,
    enum_variant_facts: List<EnumVariantFactGroup>,
    mut resolved_obligations: Set<Int>,
    mut expanded_named_enum_relations: List<NamedEnumRelationExpansion>,
    mut pending_named_enum_relation_facts:
        List<PendingNamedEnumRelationFact>,
    mut bindings: List<ResolvedNamespaceBinding>,
    mut winner_occurrences: List<NamespaceFactOccurrence>,
    mut publication_bindings: List<ResolvedNamespaceBinding?>,
    mut publication_occurrences: List<NamespaceFactOccurrence?>,
    mut binding_indices: Map<Str, Int>,
    mut queue: List<NamespaceQueueEvent>,
    mut import_ledger: Map<Str, List<NamespaceImportCandidate>>,
    mut ambiguous_keys: Set<Str>,
    mut issues: List<ImportIssue>
) {
    match lane {
        NamespaceDeliveryLane::Publication => {
            project_public_inline_fact(
                fact, fact_occurrence, exact_frames, bindings,
                winner_occurrences, publication_bindings,
                publication_occurrences, binding_indices, queue,
                import_ledger, ambiguous_keys, issues)
        },
        NamespaceDeliveryLane::Local => {}
    }

    match named_subscriptions.get(
        named_subscription_key(fact.owner, fact.exposed_name)) {
        some(obligation_indices) => {
            deliver_namespace_fact(
                fact, fact_occurrence, lane, obligation_indices, imports,
                growth_guard, blocked_growth_components,
                enum_variant_facts, resolved_obligations,
                expanded_named_enum_relations,
                pending_named_enum_relation_facts, bindings,
                winner_occurrences, publication_bindings,
                publication_occurrences, binding_indices, queue,
                import_ledger, ambiguous_keys, issues)
        },
        none => {}
    }
    match wildcard_subscriptions.get(
        wildcard_subscription_key(fact.owner)) {
        some(obligation_indices) => {
            deliver_namespace_fact(
                fact, fact_occurrence, lane, obligation_indices, imports,
                growth_guard, blocked_growth_components,
                enum_variant_facts, resolved_obligations,
                expanded_named_enum_relations,
                pending_named_enum_relation_facts, bindings,
                winner_occurrences, publication_bindings,
                publication_occurrences, binding_indices, queue,
                import_ledger, ambiguous_keys, issues)
        },
        none => {}
    }
}

fn structural_projection_template_occurrence(
    source_slot: ValueStructuralSlot
) -> NamespaceFactOccurrence {
    match source_slot.producers.get(0) {
        some(first) => NamespaceFactOccurrence {
            // Dynamic projection is non-Seed by construction.  Its final
            // provenance/site are transferred from the solved source lane.
            provenance: NamespaceFactProvenance::NamedImport,
            site: first.occurrence.site,
            leaf_origin_site: none,
            target_file_key:
                source_slot.target.file_key,
            target_frame_index:
                source_slot.target.frame_index,
            seed_role: none,
            is_projection: true
        },
        none => panic(
            "namespace invariant violated: projection source slot is empty")
    }
}

fn deliver_structural_value_imports(
    source_slot_index: Int,
    source_lane: NamespaceDeliveryLane,
    obligation_indices: List<Int>,
    imports: List<ImportObligation>,
    growth_guard: NamespaceGrowthGuard,
    mut blocked_growth_components: Set<Int>,
    mut resolved_obligations: Set<Int>,
    mut slots: List<ValueStructuralSlot>,
    mut slot_indices: Map<Str, Int>,
    mut announcements: List<ValueLaneAnnouncement>,
    mut issues: List<ImportIssue>
) {
    match slots.get(source_slot_index) {
        some(source_slot) => {
            let source = source_slot.target
            for obligation_index in obligation_indices {
                match imports.get(obligation_index) {
                    some(obligation) => {
                        let lane_matches = match source_lane {
                            NamespaceDeliveryLane::Local =>
                                source.file_key == obligation.file_key,
                            NamespaceDeliveryLane::Publication =>
                                source.file_key != obligation.file_key
                        }
                        if lane_matches {
                            if block_namespace_growth_delivery(
                                obligation_index, source.file_key,
                                source.frame_index, source.exposed_name,
                                NamespaceKind::Value, source_lane,
                                imports, growth_guard,
                                blocked_growth_components,
                                resolved_obligations, issues) {
                                continue
                            }
                            resolved_obligations.insert(obligation_index)
                            let local_name =
                                match obligation.selection {
                                    ImportSelection::Named =>
                                        obligation.local_name,
                                    ImportSelection::Wildcard =>
                                        source.exposed_name
                                }
                            let _ = register_value_structural_producer(
                                ValueStructuralProducer {
                                    producer:
                                        structural_value_import_producer(
                                            obligation_index,
                                            source_slot, source_lane),
                                    target: value_binding_target(
                                        obligation.file_key,
                                        obligation.target_frame_index,
                                        obligation.target_owner,
                                        local_name,
                                        obligation.is_public),
                                    occurrence:
                                        NamespaceFactOccurrence {
                                            provenance:
                                                import_provenance(
                                                    obligation.selection),
                                            site: obligation.site,
                                            leaf_origin_site: none,
                                            target_file_key:
                                                obligation.file_key,
                                            target_frame_index:
                                                obligation.target_frame_index,
                                            seed_role: none,
                                            is_projection: false
                                        },
                                    source:
                                        ValueStructuralProducerSource::ImportCopyValue {
                                            source_slot_index:
                                                source_slot_index,
                                            source_lane: source_lane,
                                            obligation_index:
                                                obligation_index
                                        }
                                },
                                true, slots, slot_indices, announcements)
                        }
                    },
                    none => {}
                }
            }
        },
        none => {}
    }
}

fn register_structural_value_projection(
    source_slot_index: Int,
    exact_frames: Map<Str, ModuleFramePlan>,
    mut slots: List<ValueStructuralSlot>,
    mut slot_indices: Map<Str, Int>,
    mut announcements: List<ValueLaneAnnouncement>
) {
    match slots.get(source_slot_index) {
        some(source_slot) => {
            if source_slot.projection_registered { return }
            slots.set(source_slot_index, ValueStructuralSlot {
                target: source_slot.target,
                producers: source_slot.producers,
                local_announced: source_slot.local_announced,
                publication_announced:
                    source_slot.publication_announced,
                projection_registered: true,
                has_public_seed_terminal:
                    source_slot.has_public_seed_terminal,
                local_winner_index: source_slot.local_winner_index,
                publication_winner_index:
                    source_slot.publication_winner_index
            })
            // Public Seed projection was eagerly registered by census.  Since
            // every later producer is non-Seed, Seed precedence makes this
            // classification final before exact-origin solving.
            if source_slot.has_public_seed_terminal { return }
            match exact_frames.get(exact_frame_key(
                source_slot.target.file_key,
                source_slot.target.frame_index)) {
                some(source_frame) => {
                    if source_frame.frame_index == 0 ||
                       !source_frame.is_public {
                        return
                    }
                    match exact_frames.get(exact_frame_key(
                        source_frame.file_key, 0)) {
                        some(root_frame) => {
                            let _ = register_value_structural_producer(
                                ValueStructuralProducer {
                                    producer:
                                        value_projection_producer(
                                            source_slot.target),
                                    target: value_binding_target(
                                        root_frame.file_key,
                                        root_frame.frame_index,
                                        root_frame.owner,
                                        "${source_frame.inline_prefix}::${source_slot.target.exposed_name}",
                                        true),
                                    occurrence:
                                        structural_projection_template_occurrence(
                                            source_slot),
                                    source:
                                        ValueStructuralProducerSource::ProjectionCopyValue {
                                            source_slot_index:
                                                source_slot_index
                                        }
                                },
                                true, slots, slot_indices, announcements)
                        },
                        none => {}
                    }
                },
                none => {}
            }
        },
        none => {}
    }
}

fn close_structural_value_graph(
    exact_frames: Map<Str, ModuleFramePlan>,
    named_subscriptions: Map<Str, List<Int>>,
    wildcard_subscriptions: Map<Str, List<Int>>,
    imports: List<ImportObligation>,
    growth_guard: NamespaceGrowthGuard,
    mut blocked_growth_components: Set<Int>,
    mut resolved_obligations: Set<Int>,
    mut slots: List<ValueStructuralSlot>,
    mut slot_indices: Map<Str, Int>,
    mut announcements: List<ValueLaneAnnouncement>,
    mut issues: List<ImportIssue>
) {
    announce_preloaded_value_lanes(slots, announcements)
    let mut announcement_index = 0
    while announcement_index < announcements.len() {
        match announcements.get(announcement_index) {
            some(announcement) => {
                match slots.get(announcement.slot_index) {
                    some(source_slot) => {
                        if match announcement.lane {
                            NamespaceDeliveryLane::Publication => true,
                            NamespaceDeliveryLane::Local => false
                        } {
                            register_structural_value_projection(
                                announcement.slot_index, exact_frames,
                                slots, slot_indices, announcements)
                        }
                        match named_subscriptions.get(
                            named_subscription_key(
                                source_slot.target.owner,
                                source_slot.target.exposed_name)) {
                            some(obligation_indices) => {
                                deliver_structural_value_imports(
                                    announcement.slot_index,
                                    announcement.lane,
                                    obligation_indices, imports,
                                    growth_guard,
                                    blocked_growth_components,
                                    resolved_obligations, slots,
                                    slot_indices, announcements, issues)
                            },
                            none => {}
                        }
                        match wildcard_subscriptions.get(
                            wildcard_subscription_key(
                                source_slot.target.owner)) {
                            some(obligation_indices) => {
                                deliver_structural_value_imports(
                                    announcement.slot_index,
                                    announcement.lane,
                                    obligation_indices, imports,
                                    growth_guard,
                                    blocked_growth_components,
                                    resolved_obligations, slots,
                                    slot_indices, announcements, issues)
                            },
                            none => {}
                        }
                    },
                    none => {}
                }
            },
            none => {}
        }
        announcement_index = announcement_index + 1
    }
    // Discovery order is not semantic.  First select exact source
    // Publication winners from a canonical order so dynamic projection
    // occurrences can inherit their real provenance/site, then canonicalize
    // once more for the final target-lane fold and loser ledger.
    canonicalize_value_structural_producers(slots)
    select_static_value_winners(slots)
    refine_structural_projection_occurrences(slots)
    canonicalize_value_structural_producers(slots)
    select_static_value_winners(slots)
}

fn value_lane_node_key(
    slot_index: Int, lane: NamespaceDeliveryLane
) -> Str {
    "${slot_index}|value-lane|${delivery_lane_tag(lane)}"
}

fn structural_producer_is_copy(
    producer: ValueStructuralProducer
) -> Bool {
    match producer.source {
        ValueStructuralProducerSource::TerminalValue(_) => false,
        _ => true
    }
}

fn materialize_structural_producer(
    producer: ValueStructuralProducer,
    source: ValueContribution?
) -> ValueContribution? {
    match producer.source {
        ValueStructuralProducerSource::TerminalValue(symbol) =>
            some(ValueContribution {
                producer: producer.producer,
                binding: materialize_value_binding(
                    producer.target, symbol),
                occurrence: producer.occurrence
            }),
        ValueStructuralProducerSource::ImportCopyValue { .. } => match source {
            some(source_contribution) => some(ValueContribution {
                producer: producer.producer,
                binding: materialize_value_binding(
                    producer.target, source_contribution.binding.symbol),
                // An import is a provenance boundary.  It never leaks the
                // upstream diagnostic site or projected classification.
                occurrence: producer.occurrence
            }),
            none => none
        },
        ValueStructuralProducerSource::ProjectionCopyValue { .. } => match source {
            some(source_contribution) => some(ValueContribution {
                producer: producer.producer,
                binding: materialize_value_binding(
                    producer.target, source_contribution.binding.symbol),
                occurrence: NamespaceFactOccurrence {
                    provenance:
                        source_contribution.occurrence.provenance,
                    site: source_contribution.occurrence.site,
                    leaf_origin_site:
                        source_contribution.occurrence.leaf_origin_site,
                    target_file_key: producer.target.file_key,
                    target_frame_index:
                        producer.target.frame_index,
                    seed_role:
                        source_contribution.occurrence.seed_role,
                    is_projection: true
                }
            }),
            none => none
        }
    }
}

fn materialize_cycle_import_producer(
    producer: ValueStructuralProducer,
    symbol: SymbolRef
) -> ValueContribution {
    if match producer.source {
        ValueStructuralProducerSource::ImportCopyValue { .. } => false,
        _ => true
    } {
        panic(
            "namespace invariant violated: cycle anchor is not an Import copy")
    }
    ValueContribution {
        producer: producer.producer,
        binding: materialize_value_binding(producer.target, symbol),
        occurrence: producer.occurrence
    }
}

fn build_value_lane_nodes(
    slots: List<ValueStructuralSlot>,
    mut nodes: List<ValueLaneNode>,
    mut node_indices: Map<Str, Int>,
    mut graph: Map<Str, List<Str>>,
    mut node_order: List<Str>
) {
    for slot_index in 0..slots.len() {
        match slots.get(slot_index) {
            some(slot) => {
                if slot.local_winner_index >= 0 {
                    let key = value_lane_node_key(
                        slot_index, NamespaceDeliveryLane::Local)
                    let node_index = nodes.len()
                    nodes.push(ValueLaneNode {
                        slot_index: slot_index,
                        lane: NamespaceDeliveryLane::Local,
                        winner_index: slot.local_winner_index
                    })
                    node_indices.insert(key, node_index)
                    node_order.push(key)
                    graph.insert(key, [])
                }
                if slot.publication_winner_index >= 0 {
                    let key = value_lane_node_key(
                        slot_index,
                        NamespaceDeliveryLane::Publication)
                    let node_index = nodes.len()
                    nodes.push(ValueLaneNode {
                        slot_index: slot_index,
                        lane: NamespaceDeliveryLane::Publication,
                        winner_index:
                            slot.publication_winner_index
                    })
                    node_indices.insert(key, node_index)
                    node_order.push(key)
                    graph.insert(key, [])
                }
            },
            none => {}
        }
    }
    for node in nodes {
        match slots.get(node.slot_index) {
            some(slot) => match slot.producers.get(
                node.winner_index) {
                some(producer) => {
                    if structural_producer_is_copy(producer) {
                        let source_key = value_lane_node_key(
                            structural_producer_source_slot_index(producer),
                            structural_producer_source_lane(producer))
                        if !node_indices.contains_key(source_key) {
                            panic(
                                "namespace invariant violated: active Value copy source lane is absent")
                        }
                        let target_key = value_lane_node_key(
                            node.slot_index, node.lane)
                        match graph.get(target_key) {
                            some(edges) => edges.push(source_key),
                            none => { graph.insert(target_key, [source_key]) }
                        }
                    }
                },
                none => {}
            },
            none => {}
        }
    }
}

fn value_lane_source_node_index(
    producer: ValueStructuralProducer,
    node_indices: Map<Str, Int>
) -> Int {
    node_indices.get(value_lane_node_key(
        structural_producer_source_slot_index(producer),
        structural_producer_source_lane(producer))).unwrap_or(-1)
}

fn propagate_acyclic_value_lanes(
    slots: List<ValueStructuralSlot>,
    nodes: List<ValueLaneNode>,
    node_indices: Map<Str, Int>,
    node_components: Map<Str, Int>,
    cyclic_components: Set<Int>,
    mut solutions: List<ValueContribution?>,
    mut failed_nodes: Set<Int>
) -> Bool {
    let mut any_progress = false
    let mut changed = true
    while changed {
        changed = false
        for node_index in 0..nodes.len() {
            if solutions.get(node_index).unwrap_or(none).is_none() &&
               !failed_nodes.contains(node_index) {
                match nodes.get(node_index) {
                    some(node) => {
                        let node_component = node_components.get(
                            value_lane_node_key(
                                node.slot_index, node.lane)).unwrap_or(-1)
                        if !cyclic_components.contains(node_component) {
                            match slots.get(node.slot_index) {
                                some(slot) => match slot.producers.get(
                                    node.winner_index) {
                                    some(producer) => match producer.source {
                                        ValueStructuralProducerSource::TerminalValue(_) => {
                                            solutions.set(
                                                node_index,
                                                materialize_structural_producer(
                                                    producer, none))
                                            changed = true
                                            any_progress = true
                                        },
                                        _ => {
                                            let source_index =
                                                value_lane_source_node_index(
                                                    producer, node_indices)
                                            if source_index < 0 {
                                                panic(
                                                    "namespace invariant violated: Value copy lost source node")
                                            }
                                            match solutions.get(source_index) {
                                                some(some(source)) => {
                                                    solutions.set(
                                                        node_index,
                                                        materialize_structural_producer(
                                                            producer,
                                                            some(source)))
                                                    changed = true
                                                    any_progress = true
                                                },
                                                _ => {
                                                    if failed_nodes.contains(
                                                        source_index) {
                                                        failed_nodes.insert(
                                                            node_index)
                                                        changed = true
                                                        any_progress = true
                                                    }
                                                }
                                            }
                                        }
                                    },
                                    none => {}
                                },
                                none => {}
                            }
                        }
                    },
                    none => {}
                }
            }
        }
    }
    any_progress
}

fn active_cycle_root_component(
    start_node_index: Int,
    slots: List<ValueStructuralSlot>,
    nodes: List<ValueLaneNode>,
    node_indices: Map<Str, Int>,
    node_components: Map<Str, Int>,
    cyclic_components: Set<Int>
) -> Int {
    let mut current = start_node_index
    let mut visited: Set<Int> = set_new()
    while current >= 0 && !visited.contains(current) {
        visited.insert(current)
        match nodes.get(current) {
            some(node) => {
                let component = node_components.get(
                    value_lane_node_key(
                        node.slot_index, node.lane)).unwrap_or(-1)
                if cyclic_components.contains(component) {
                    return component
                }
                match slots.get(node.slot_index) {
                    some(slot) => match slot.producers.get(
                        node.winner_index) {
                        some(producer) => {
                            if !structural_producer_is_copy(producer) {
                                return -1
                            }
                            current = value_lane_source_node_index(
                                producer, node_indices)
                        },
                        none => { return -1 }
                    },
                    none => { return -1 }
                }
            },
            none => { return -1 }
        }
    }
    -1
}

fn producer_eligible_for_lane(
    producer: ValueStructuralProducer,
    lane: NamespaceDeliveryLane
) -> Bool {
    match lane {
        NamespaceDeliveryLane::Local => true,
        NamespaceDeliveryLane::Publication =>
            producer.target.is_public
    }
}

fn append_distinct_symbol_ref(
    symbol: SymbolRef, mut symbols: List<SymbolRef>
) {
    for existing in symbols {
        if symbol_ref_same(existing, symbol) { return }
    }
    symbols.push(symbol)
}

fn resolve_active_cycle_component(
    component: List<Str>,
    symbol: SymbolRef,
    slots: List<ValueStructuralSlot>,
    nodes: List<ValueLaneNode>,
    node_indices: Map<Str, Int>,
    mut solutions: List<ValueContribution?>
) {
    let mut component_node_indices: List<Int> = []
    let mut import_anchor_count = 0
    for node_key in component {
        let node_index = node_indices.get(node_key).unwrap_or(-1)
        if node_index >= 0 {
            component_node_indices.push(node_index)
            match nodes.get(node_index) {
                some(node) => match slots.get(node.slot_index) {
                    some(slot) => match slot.producers.get(
                        node.winner_index) {
                        some(producer) => match producer.source {
                            ValueStructuralProducerSource::ImportCopyValue { .. } => {
                                solutions.set(
                                    node_index,
                                    some(materialize_cycle_import_producer(
                                        producer, symbol)))
                                import_anchor_count =
                                    import_anchor_count + 1
                            },
                            _ => {}
                        },
                        none => {}
                    },
                    none => {}
                },
                none => {}
            }
        }
    }
    if import_anchor_count == 0 {
        panic(
            "namespace invariant violated: active Value copy SCC has no Import edge")
    }
    let mut changed = true
    while changed {
        changed = false
        for node_index in component_node_indices {
            if solutions.get(node_index).unwrap_or(none).is_none() {
                match nodes.get(node_index) {
                    some(node) => match slots.get(node.slot_index) {
                        some(slot) => match slot.producers.get(
                            node.winner_index) {
                            some(producer) => {
                                let source_index =
                                    value_lane_source_node_index(
                                        producer, node_indices)
                                match solutions.get(source_index) {
                                    some(some(source)) => {
                                        solutions.set(
                                            node_index,
                                            materialize_structural_producer(
                                                producer, some(source)))
                                        changed = true
                                    },
                                    _ => {}
                                }
                            },
                            none => {}
                        },
                        none => {}
                    },
                    none => {}
                }
            }
        }
    }
    for node_index in component_node_indices {
        if solutions.get(node_index).unwrap_or(none).is_none() {
            panic(
                "namespace invariant violated: canonical Value SCC did not materialize")
        }
    }
}

fn append_unique_graph_edge(
    source: Str, target: Str,
    mut graph: Map<Str, List<Str>>
) {
    match graph.get(source) {
        some(edges) => {
            if !edges.contains(target) { edges.push(target) }
        },
        none => { graph.insert(source, [target]) }
    }
    if !graph.contains_key(target) { graph.insert(target, []) }
}

fn append_materialized_strong_ambiguity(
    witnesses: List<ValueContribution>,
    mut ambiguous_keys: Set<Str>,
    mut issues: List<ImportIssue>
) -> Bool {
    for left_index in 0..witnesses.len() {
        match witnesses.get(left_index) {
            some(left) => {
                if value_contribution_is_strong(left) {
                    for right_index in (left_index + 1)..witnesses.len() {
                        match witnesses.get(right_index) {
                            some(right) => {
                                if value_contribution_is_strong(right) &&
                                   left.producer.key != right.producer.key &&
                                   left.binding.file_key ==
                                       right.binding.file_key &&
                                   left.binding.frame_index ==
                                       right.binding.frame_index &&
                                   left.binding.exposed_name ==
                                       right.binding.exposed_name &&
                                   !symbol_ref_same(
                                       left.binding.symbol,
                                       right.binding.symbol) {
                                    let key = namespace_binding_key(
                                        left.binding.file_key,
                                        left.binding.frame_index,
                                        left.binding.exposed_name,
                                        NamespaceKind::Value)
                                    if site_is_before(
                                        right.occurrence.site,
                                        left.occurrence.site) {
                                        append_binding_ambiguity(
                                            key, right.binding.symbol,
                                            left.binding,
                                            left.occurrence,
                                            ambiguous_keys, issues)
                                    } else {
                                        append_binding_ambiguity(
                                            key, left.binding.symbol,
                                            right.binding,
                                            right.occurrence,
                                            ambiguous_keys, issues)
                                    }
                                    return true
                                }
                            },
                            none => {}
                        }
                    }
                }
            },
            none => {}
        }
    }
    false
}

fn append_active_value_cycle_issue(
    active_components: List<Int>,
    components: List<List<Str>>,
    slots: List<ValueStructuralSlot>,
    nodes: List<ValueLaneNode>,
    node_indices: Map<Str, Int>,
    imports: List<ImportObligation>,
    mut issues: List<ImportIssue>
) {
    let mut first_producer: ValueStructuralProducer? = none
    let mut related_nodes: List<Str> = []
    for component_index in active_components {
        match components.get(component_index) {
            some(component) => {
                for node_key in component {
                    if !related_nodes.contains(node_key) {
                        related_nodes.push(node_key)
                    }
                    let node_index =
                        node_indices.get(node_key).unwrap_or(-1)
                    match nodes.get(node_index) {
                        some(node) => match slots.get(node.slot_index) {
                            some(slot) => match slot.producers.get(
                                node.winner_index) {
                                some(producer) => match producer.source {
                                    ValueStructuralProducerSource::ImportCopyValue { .. } => {
                                        match first_producer {
                                            none => {
                                                first_producer =
                                                    some(producer)
                                            },
                                            some(existing) => {
                                                if site_is_before(
                                                    producer.occurrence.site,
                                                    existing.occurrence.site) {
                                                    first_producer =
                                                        some(producer)
                                                }
                                            }
                                        }
                                    },
                                    _ => {}
                                },
                                none => {}
                            },
                            none => {}
                        },
                        none => {}
                    }
                }
            },
            none => {}
        }
    }
    match first_producer {
        some(producer) => {
            match imports.get(
                structural_producer_obligation_index(producer)) {
                some(obligation) => {
                    issues.push(ImportIssue {
                        kind: ImportIssueKind::UnresolvedImportCycle,
                        site: obligation.site,
                        source_owner: obligation.source_owner,
                        source_name: obligation.source_name,
                        local_name: producer.target.exposed_name,
                        namespace: NamespaceKind::Value,
                        related_owners: related_nodes
                    })
                },
                none => panic(
                    "namespace invariant violated: active Value SCC Import lacks obligation")
            }
        },
        none => panic(
            "namespace invariant violated: active Value copy SCC has no Import edge")
    }
}

fn solve_structural_value_lanes(
    slots: List<ValueStructuralSlot>,
    imports: List<ImportObligation>,
    mut ambiguous_keys: Set<Str>,
    mut issues: List<ImportIssue>,
    mut nodes: List<ValueLaneNode>,
    mut node_indices: Map<Str, Int>,
    mut solutions: List<ValueContribution?>,
    mut failed_nodes: Set<Int>
) {
    let mut graph: Map<Str, List<Str>> = map_new()
    let mut node_order: List<Str> = []
    build_value_lane_nodes(
        slots, nodes, node_indices, graph, node_order)
    for _ in nodes { solutions.push(none) }

    let components = ordered_import_scc(graph, node_order)
    let mut node_components: Map<Str, Int> = map_new()
    let mut cyclic_components: Set<Int> = set_new()
    for component_index in 0..components.len() {
        match components.get(component_index) {
            some(component) => {
                let is_cycle = component.len() > 1 ||
                    (component.len() == 1 &&
                     graph_has_self_edge(
                         component.get(0).unwrap_or(""), graph))
                if is_cycle {
                    cyclic_components.insert(component_index)
                }
                for node_key in component {
                    node_components.insert(
                        node_key, component_index)
                }
            },
            none => {}
        }
    }

    let _ = propagate_acyclic_value_lanes(
        slots, nodes, node_indices, node_components,
        cyclic_components, solutions, failed_nodes)
    if cyclic_components.len() == 0 { return }

    // A losing copy can witness an exact SymbolRef for an active copy SCC.
    // Collapse those witness dependencies separately so a failed/ambiguous
    // predecessor never exports hypothetical origins into a valid successor.
    let mut witness_graph: Map<Str, List<Str>> = map_new()
    let mut witness_order: List<Str> = []
    let mut component_keys: Map<Int, Str> = map_new()
    let mut key_components: Map<Str, Int> = map_new()
    for component_index in 0..components.len() {
        if cyclic_components.contains(component_index) {
            let key = "active-value-cycle|${component_index}"
            component_keys.insert(component_index, key)
            key_components.insert(key, component_index)
            witness_graph.insert(key, [])
            witness_order.push(key)
        }
    }
    for component_index in 0..components.len() {
        if cyclic_components.contains(component_index) {
            match components.get(component_index) {
                some(component) => {
                    for node_key in component {
                        let node_index =
                            node_indices.get(node_key).unwrap_or(-1)
                        match nodes.get(node_index) {
                            some(node) => match slots.get(node.slot_index) {
                                some(slot) => {
                                    for producer in slot.producers {
                                        if producer_eligible_for_lane(
                                            producer, node.lane) &&
                                           structural_producer_is_copy(
                                               producer) {
                                            let source_index =
                                                value_lane_source_node_index(
                                                    producer,
                                                    node_indices)
                                            let source_cycle =
                                                active_cycle_root_component(
                                                    source_index, slots,
                                                    nodes, node_indices,
                                                    node_components,
                                                    cyclic_components)
                                            if source_cycle >= 0 &&
                                               source_cycle !=
                                                   component_index {
                                                append_unique_graph_edge(
                                                    component_keys.get(
                                                        component_index
                                                    ).unwrap_or(""),
                                                    component_keys.get(
                                                        source_cycle
                                                    ).unwrap_or(""),
                                                    witness_graph)
                                            }
                                        }
                                    }
                                },
                                none => {}
                            },
                            none => {}
                        }
                    }
                },
                none => {}
            }
        }
    }

    let witness_components =
        ordered_import_scc(witness_graph, witness_order)
    let mut active_component_group: Map<Int, Int> = map_new()
    let mut group_active_components: List<List<Int>> = []
    for group_index in 0..witness_components.len() {
        let mut active_components: List<Int> = []
        match witness_components.get(group_index) {
            some(group) => {
                for component_key in group {
                    let active_component =
                        key_components.get(component_key).unwrap_or(-1)
                    if active_component >= 0 {
                        active_components.push(active_component)
                        active_component_group.insert(
                            active_component, group_index)
                    }
                }
            },
            none => {}
        }
        group_active_components.push(active_components)
    }
    let mut group_dependencies: Map<Int, List<Int>> = map_new()
    for group_index in 0..group_active_components.len() {
        group_dependencies.insert(group_index, [])
    }
    for entry in witness_graph.entries() {
        let (source_key, targets) = entry
        let source_component =
            key_components.get(source_key).unwrap_or(-1)
        let source_group =
            active_component_group.get(source_component).unwrap_or(-1)
        for target_key in targets {
            let target_component =
                key_components.get(target_key).unwrap_or(-1)
            let target_group =
                active_component_group.get(
                    target_component).unwrap_or(-1)
            if source_group >= 0 && target_group >= 0 &&
               source_group != target_group {
                match group_dependencies.get(source_group) {
                    some(existing) => {
                        if !existing.contains(target_group) {
                            existing.push(target_group)
                        }
                    },
                    none => {
                        group_dependencies.insert(
                            source_group, [target_group])
                    }
                }
            }
        }
    }

    let mut group_status: List<Int> = []
    for _ in group_active_components { group_status.push(0) }
    let mut remaining_groups = group_status.len()
    while remaining_groups > 0 {
        let mut round_progress = false
        for group_index in 0..group_status.len() {
            if group_status.get(group_index).unwrap_or(0) == 0 {
                let mut dependencies_final = true
                match group_dependencies.get(group_index) {
                    some(dependencies) => {
                        for dependency in dependencies {
                            if group_status.get(
                                dependency).unwrap_or(0) == 0 {
                                dependencies_final = false
                            }
                        }
                    },
                    none => {}
                }
                if dependencies_final {
                    let active_components =
                        group_active_components.get(
                            group_index).unwrap_or([])
                    let mut witnesses: List<ValueContribution> = []
                    let mut symbols: List<SymbolRef> = []
                    for active_component in active_components {
                        match components.get(active_component) {
                            some(component) => {
                                for node_key in component {
                                    let node_index =
                                        node_indices.get(
                                            node_key).unwrap_or(-1)
                                    match nodes.get(node_index) {
                                        some(node) => match slots.get(
                                            node.slot_index) {
                                            some(slot) => {
                                                for producer in
                                                    slot.producers {
                                                    if producer_eligible_for_lane(
                                                        producer,
                                                        node.lane) {
                                                        match producer.source {
                                                            ValueStructuralProducerSource::TerminalValue(_) => {
                                                                match materialize_structural_producer(
                                                                    producer,
                                                                    none) {
                                                                    some(witness) => {
                                                                        append_distinct_symbol_ref(
                                                                            witness.binding.symbol,
                                                                            symbols)
                                                                        witnesses.push(
                                                                            witness)
                                                                    },
                                                                    none => {}
                                                                }
                                                            },
                                                            _ => {
                                                                let source_index =
                                                                    value_lane_source_node_index(
                                                                        producer,
                                                                        node_indices)
                                                                let source_cycle =
                                                                    active_cycle_root_component(
                                                                        source_index,
                                                                        slots,
                                                                        nodes,
                                                                        node_indices,
                                                                        node_components,
                                                                        cyclic_components)
                                                                let source_group =
                                                                    active_component_group.get(
                                                                        source_cycle
                                                                    ).unwrap_or(-1)
                                                                if source_group !=
                                                                   group_index {
                                                                    match solutions.get(
                                                                        source_index) {
                                                                        some(some(source)) => {
                                                                            match materialize_structural_producer(
                                                                                producer,
                                                                                some(source)) {
                                                                                some(witness) => {
                                                                                    append_distinct_symbol_ref(
                                                                                        witness.binding.symbol,
                                                                                        symbols)
                                                                                    witnesses.push(
                                                                                        witness)
                                                                                },
                                                                                none => {}
                                                                            }
                                                                        },
                                                                        _ => {}
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            },
                                            none => {}
                                        },
                                        none => {}
                                    }
                                }
                            },
                            none => {}
                        }
                    }

                    if symbols.len() == 1 {
                        match symbols.get(0) {
                            some(symbol) => {
                                for active_component in active_components {
                                    match components.get(active_component) {
                                        some(component) => {
                                            resolve_active_cycle_component(
                                                component, symbol, slots,
                                                nodes, node_indices, solutions)
                                        },
                                        none => {}
                                    }
                                }
                            },
                            none => panic(
                                "namespace invariant violated: exact Value witness missing")
                        }
                        group_status.set(group_index, 1)
                    } else {
                        let strong_conflict =
                            if symbols.len() > 1 {
                                append_materialized_strong_ambiguity(
                                    witnesses, ambiguous_keys, issues)
                            } else {
                                false
                            }
                        if !strong_conflict {
                            append_active_value_cycle_issue(
                                active_components, components,
                                slots, nodes, node_indices,
                                imports, issues)
                        }
                        for active_component in active_components {
                            match components.get(active_component) {
                                some(component) => {
                                    for node_key in component {
                                        let node_index =
                                            node_indices.get(
                                                node_key).unwrap_or(-1)
                                        if node_index >= 0 {
                                            failed_nodes.insert(
                                                node_index)
                                        }
                                    }
                                },
                                none => {}
                            }
                        }
                        group_status.set(group_index, -1)
                    }
                    remaining_groups = remaining_groups - 1
                    round_progress = true
                    let _ = propagate_acyclic_value_lanes(
                        slots, nodes, node_indices,
                        node_components, cyclic_components,
                        solutions, failed_nodes)
                }
            }
        }
        if !round_progress {
            panic(
                "namespace invariant violated: witness condensation did not make progress")
        }
    }
    let _ = propagate_acyclic_value_lanes(
        slots, nodes, node_indices, node_components,
        cyclic_components, solutions, failed_nodes)
}

fn materialize_structural_value_plan(
    slots: List<ValueStructuralSlot>,
    nodes: List<ValueLaneNode>,
    node_indices: Map<Str, Int>,
    solutions: List<ValueContribution?>,
    mut bindings: List<ResolvedNamespaceBinding>,
    mut ambiguous_keys: Set<Str>,
    mut issues: List<ImportIssue>
) {
    for slot_index in 0..slots.len() {
        match slots.get(slot_index) {
            some(slot) => {
                let mut contributions: List<ValueContribution> = []
                for producer in slot.producers {
                    let source = if structural_producer_is_copy(producer) {
                        let source_index =
                            value_lane_source_node_index(
                                producer, node_indices)
                        if source_index >= 0 {
                            solutions.get(source_index).unwrap_or(none)
                        } else {
                            none
                        }
                    } else {
                        none
                    }
                    match materialize_structural_producer(
                        producer, source) {
                        some(contribution) =>
                            contributions.push(contribution),
                        none => {}
                    }
                }
                if contributions.len() > 0 {
                    let key = namespace_binding_key(
                        slot.target.file_key,
                        slot.target.frame_index,
                        slot.target.exposed_name,
                        NamespaceKind::Value)
                    // Winner selection was origin-free.  Reusing the legacy
                    // reducer only for diagnostics preserves exact Seed
                    // collision reporting without letting identities influence
                    // the already-fixed active graph.
                    let _ = reduce_value_lane(
                        contributions, false, true, key,
                        ambiguous_keys, issues)
                    append_materialized_strong_ambiguity(
                        contributions, ambiguous_keys, issues)
                }

                let local_node_index = node_indices.get(
                    value_lane_node_key(
                        slot_index,
                        NamespaceDeliveryLane::Local)).unwrap_or(-1)
                if local_node_index >= 0 {
                    match solutions.get(local_node_index) {
                        some(some(local)) => {
                            let publication_node_index =
                                node_indices.get(value_lane_node_key(
                                    slot_index,
                                    NamespaceDeliveryLane::Publication
                                )).unwrap_or(-1)
                            let is_public =
                                if publication_node_index >= 0 {
                                    match solutions.get(
                                        publication_node_index) {
                                        some(some(publication)) =>
                                            symbol_ref_same(
                                                publication.binding.symbol,
                                                local.binding.symbol),
                                        _ => false
                                    }
                                } else {
                                    false
                                }
                            bindings.push(binding_with_public(
                                local.binding, is_public))
                        },
                        _ => {}
                    }
                }
            },
            none => {}
        }
    }
}

fn unresolved_target_node(obligation: ImportObligation) -> Str {
    match obligation.selection {
        ImportSelection::Named =>
            "${obligation.target_owner}|node|${obligation.local_name}",
        ImportSelection::Wildcard =>
            "${obligation.target_owner}|node|*"
    }
}

fn unresolved_source_node(obligation: ImportObligation) -> Str {
    match obligation.selection {
        ImportSelection::Named =>
            "${obligation.source_owner}|node|${obligation.source_name}",
        ImportSelection::Wildcard =>
            "${obligation.source_owner}|node|*"
    }
}

fn graph_has_self_edge(node: Str, graph: Map<Str, List<Str>>) -> Bool {
    match graph.get(node) {
        some(edges) => edges.contains(node),
        none => false
    }
}

// Stable linear Tarjan for the portable import plan.  node_order records the
// first target/source occurrence during obligation graph construction, and
// adjacency lists retain insertion order; no map materialisation or sorting is
// needed for deterministic traversal.
fn ordered_import_scc(
    graph: Map<Str, List<Str>>, node_order: List<Str>
) -> List<List<Str>> {
    let mut index_counter: List<Int> = [0]
    let mut stack: List<Str> = []
    let mut on_stack: Set<Str> = set_new()
    let mut indices: Map<Str, Int> = map_new()
    let mut lowlinks: Map<Str, Int> = map_new()
    let mut result: List<List<Str>> = []
    for node in node_order {
        if !indices.contains_key(node) {
            import_scc_connect(
                node, graph, index_counter, stack, on_stack,
                indices, lowlinks, result)
        }
    }
    result
}

fn import_scc_connect(
    node: Str,
    graph: Map<Str, List<Str>>,
    mut index_counter: List<Int>,
    mut stack: List<Str>,
    mut on_stack: Set<Str>,
    mut indices: Map<Str, Int>,
    mut lowlinks: Map<Str, Int>,
    mut result: List<List<Str>>
) {
    let node_index = index_counter[0]
    index_counter.set(0, node_index + 1)
    indices.insert(node, node_index)
    lowlinks.insert(node, node_index)
    stack.push(node)
    on_stack.insert(node)

    let successors = graph.get(node).unwrap_or([])
    for successor in successors {
        if !indices.contains_key(successor) {
            import_scc_connect(
                successor, graph, index_counter, stack, on_stack,
                indices, lowlinks, result)
            let node_low = lowlinks.get(node).unwrap_or(node_index)
            let successor_low = lowlinks.get(successor).unwrap_or(node_low)
            if successor_low < node_low {
                lowlinks.insert(node, successor_low)
            }
        } else if on_stack.contains(successor) {
            let node_low = lowlinks.get(node).unwrap_or(node_index)
            let successor_index = indices.get(successor).unwrap_or(node_low)
            if successor_index < node_low {
                lowlinks.insert(node, successor_index)
            }
        }
    }

    if lowlinks.get(node).unwrap_or(node_index) == node_index {
        let mut component: List<Str> = []
        let mut complete = false
        while !complete {
            match stack.pop() {
                some(member) => {
                    on_stack.remove(member)
                    component.push(member)
                    if member == node { complete = true }
                },
                none => { complete = true }
            }
        }
        result.push(component)
    }
}

fn growth_lane_tag(lane: NamespaceDeliveryLane) -> Str {
    match lane {
        NamespaceDeliveryLane::Local => "local",
        NamespaceDeliveryLane::Publication => "publication"
    }
}

fn growth_lane_node(
    file_key: Str, frame_index: Int, lane: NamespaceDeliveryLane
) -> Str {
    "${file_key}|growth-frame|${frame_index}|${growth_lane_tag(lane)}"
}

fn growth_delivery_edge_key(
    obligation_index: Int,
    source_file_key: Str,
    source_frame_index: Int,
    source_lane: NamespaceDeliveryLane
) -> Str {
    "${obligation_index}|growth-source|${source_file_key}|${source_frame_index}|${growth_lane_tag(source_lane)}"
}

fn append_growth_graph_node(
    node: Str,
    mut graph: Map<Str, List<Str>>,
    mut node_order: List<Str>,
    mut seen_nodes: Set<Str>
) {
    if !seen_nodes.contains(node) {
        seen_nodes.insert(node)
        node_order.push(node)
        graph.insert(node, [])
    }
}

fn append_growth_schema_edge(
    edge: NamespaceGrowthSchemaEdge,
    mut graph: Map<Str, List<Str>>,
    mut node_order: List<Str>,
    mut seen_nodes: Set<Str>,
    mut edges: List<NamespaceGrowthSchemaEdge>
) {
    append_growth_graph_node(
        edge.source_node, graph, node_order, seen_nodes)
    append_growth_graph_node(
        edge.target_node, graph, node_order, seen_nodes)
    match graph.get(edge.source_node) {
        some(successors) => successors.push(edge.target_node),
        none => { graph.insert(edge.source_node, [edge.target_node]) }
    }
    edges.push(edge)
}

// Wildcard delivery preserves an exposed spelling while public inline
// projection prefixes it.  A schema SCC containing both a cycle and a prefix
// can therefore grow names forever (m::x, m::m::x, ...).  Named imports are
// fixed-name resets and deliberately do not enter this graph.
fn build_namespace_growth_guard(
    frames: List<ModuleFramePlan>,
    imports: List<ImportObligation>,
    exact_frames: Map<Str, ModuleFramePlan>
) -> NamespaceGrowthGuard {
    let mut frames_by_owner: Map<Str, List<ModuleFramePlan>> = map_new()
    for frame in frames {
        match frames_by_owner.get(frame.owner) {
            some(existing) => existing.push(frame),
            none => { frames_by_owner.insert(frame.owner, [frame]) }
        }
    }

    let mut graph: Map<Str, List<Str>> = map_new()
    let mut node_order: List<Str> = []
    let mut seen_nodes: Set<Str> = set_new()
    let mut schema_edges: List<NamespaceGrowthSchemaEdge> = []

    for obligation_index in 0..imports.len() {
        match imports.get(obligation_index) {
            some(obligation) => match obligation.selection {
                ImportSelection::Named => {},
                ImportSelection::Wildcard => {
                    match frames_by_owner.get(obligation.source_owner) {
                        some(source_frames) => {
                            for source_frame in source_frames {
                                let source_lane =
                                    if source_frame.file_key ==
                                       obligation.file_key {
                                        NamespaceDeliveryLane::Local
                                    } else {
                                        NamespaceDeliveryLane::Publication
                                    }
                                let source_node = growth_lane_node(
                                    source_frame.file_key,
                                    source_frame.frame_index,
                                    source_lane)
                                append_growth_schema_edge(
                                    NamespaceGrowthSchemaEdge {
                                        source_node: source_node,
                                        target_node: growth_lane_node(
                                            obligation.file_key,
                                            obligation.target_frame_index,
                                            NamespaceDeliveryLane::Local),
                                        obligation_index: obligation_index,
                                        source_file_key:
                                            source_frame.file_key,
                                        source_frame_index:
                                            source_frame.frame_index,
                                        source_lane: source_lane,
                                        is_prefix: false
                                    },
                                    graph, node_order, seen_nodes,
                                    schema_edges)
                                if obligation.is_public {
                                    append_growth_schema_edge(
                                        NamespaceGrowthSchemaEdge {
                                            source_node: source_node,
                                            target_node: growth_lane_node(
                                                obligation.file_key,
                                                obligation.target_frame_index,
                                                NamespaceDeliveryLane::Publication),
                                            obligation_index:
                                                obligation_index,
                                            source_file_key:
                                                source_frame.file_key,
                                            source_frame_index:
                                                source_frame.frame_index,
                                            source_lane: source_lane,
                                            is_prefix: false
                                        },
                                        graph, node_order, seen_nodes,
                                        schema_edges)
                                }
                            }
                        },
                        none => {}
                    }
                }
            },
            none => {}
        }
    }

    for frame in frames {
        if frame.frame_index != 0 && frame.is_public {
            match exact_frames.get(exact_frame_key(frame.file_key, 0)) {
                some(root_frame) => {
                    let source_node = growth_lane_node(
                        frame.file_key, frame.frame_index,
                        NamespaceDeliveryLane::Publication)
                    append_growth_schema_edge(
                        NamespaceGrowthSchemaEdge {
                            source_node: source_node,
                            target_node: growth_lane_node(
                                root_frame.file_key, root_frame.frame_index,
                                NamespaceDeliveryLane::Local),
                            obligation_index: -1,
                            source_file_key: frame.file_key,
                            source_frame_index: frame.frame_index,
                            source_lane:
                                NamespaceDeliveryLane::Publication,
                            is_prefix: true
                        },
                        graph, node_order, seen_nodes, schema_edges)
                    append_growth_schema_edge(
                        NamespaceGrowthSchemaEdge {
                            source_node: source_node,
                            target_node: growth_lane_node(
                                root_frame.file_key, root_frame.frame_index,
                                NamespaceDeliveryLane::Publication),
                            obligation_index: -1,
                            source_file_key: frame.file_key,
                            source_frame_index: frame.frame_index,
                            source_lane:
                                NamespaceDeliveryLane::Publication,
                            is_prefix: true
                        },
                        graph, node_order, seen_nodes, schema_edges)
                },
                none => {}
            }
        }
    }

    let components = ordered_import_scc(graph, node_order)
    let mut node_component: Map<Str, Int> = map_new()
    let mut component_is_cycle: Map<Int, Bool> = map_new()
    let mut component_nodes: Map<Int, List<Str>> = map_new()
    for component_index in 0..components.len() {
        match components.get(component_index) {
            some(component) => {
                let is_cycle = component.len() > 1 ||
                    (component.len() == 1 &&
                     graph_has_self_edge(
                         component.get(0).unwrap_or(""), graph))
                component_is_cycle.insert(component_index, is_cycle)
                component_nodes.insert(component_index, component)
                for node in component {
                    node_component.insert(node, component_index)
                }
            },
            none => {}
        }
    }

    let mut dangerous_components: Set<Int> = set_new()
    for edge in schema_edges {
        let source_component =
            node_component.get(edge.source_node).unwrap_or(-1)
        let target_component =
            node_component.get(edge.target_node).unwrap_or(-2)
        if edge.is_prefix &&
           source_component == target_component &&
           source_component >= 0 &&
           component_is_cycle.get(source_component).unwrap_or(false) {
            dangerous_components.insert(source_component)
        }
    }

    let mut dangerous_edges: Map<Str, List<Int>> = map_new()
    let mut component_first_obligation: Map<Int, Int> = map_new()
    let mut component_obligations: Map<Int, List<Int>> = map_new()
    for edge in schema_edges {
        if edge.obligation_index >= 0 {
            let source_component =
                node_component.get(edge.source_node).unwrap_or(-1)
            let target_component =
                node_component.get(edge.target_node).unwrap_or(-2)
            if source_component == target_component &&
               dangerous_components.contains(source_component) {
                let key = growth_delivery_edge_key(
                    edge.obligation_index,
                    edge.source_file_key,
                    edge.source_frame_index,
                    edge.source_lane)
                match dangerous_edges.get(key) {
                    some(existing) => {
                        if !existing.contains(source_component) {
                            existing.push(source_component)
                        }
                    },
                    none => {
                        dangerous_edges.insert(
                            key, [source_component])
                    }
                }
                match component_obligations.get(source_component) {
                    some(existing) => {
                        if !existing.contains(edge.obligation_index) {
                            existing.push(edge.obligation_index)
                        }
                    },
                    none => {
                        component_obligations.insert(
                            source_component, [edge.obligation_index])
                    }
                }
                match component_first_obligation.get(source_component) {
                    some(previous_index) => match (
                        imports.get(previous_index),
                        imports.get(edge.obligation_index)
                    ) {
                        (some(previous), some(candidate)) => {
                            if site_is_before(
                                candidate.site, previous.site) {
                                component_first_obligation.insert(
                                    source_component,
                                    edge.obligation_index)
                            }
                        },
                        _ => {}
                    },
                    none => {
                        component_first_obligation.insert(
                            source_component, edge.obligation_index)
                    }
                }
            }
        }
    }

    NamespaceGrowthGuard {
        dangerous_edges: dangerous_edges,
        component_first_obligation: component_first_obligation,
        component_obligations: component_obligations,
        component_nodes: component_nodes
    }
}

fn block_namespace_growth_delivery(
    obligation_index: Int,
    source_file_key: Str,
    source_frame_index: Int,
    source_exposed_name: Str,
    source_namespace: NamespaceKind,
    source_lane: NamespaceDeliveryLane,
    imports: List<ImportObligation>,
    guard: NamespaceGrowthGuard,
    mut blocked_components: Set<Int>,
    mut resolved_obligations: Set<Int>,
    mut issues: List<ImportIssue>
) -> Bool {
    let key = growth_delivery_edge_key(
        obligation_index, source_file_key,
        source_frame_index, source_lane)
    match guard.dangerous_edges.get(key) {
        none => false,
        some(components) => {
            for component_index in components {
                if !blocked_components.contains(component_index) {
                    blocked_components.insert(component_index)
                    match guard.component_obligations.get(component_index) {
                        some(obligation_indices) => {
                            for related_index in obligation_indices {
                                resolved_obligations.insert(related_index)
                            }
                        },
                        none => {}
                    }
                    match (
                        guard.component_first_obligation.get(component_index),
                        guard.component_nodes.get(component_index)
                    ) {
                        (some(first_index), some(nodes)) => {
                            match imports.get(first_index) {
                                some(first) => {
                                    issues.push(ImportIssue {
                                        kind:
                                            ImportIssueKind::UnresolvedImportCycle,
                                        site: first.site,
                                        source_owner: first.source_owner,
                                        source_name: source_exposed_name,
                                        local_name: source_exposed_name,
                                        namespace: source_namespace,
                                        related_owners: nodes
                                    })
                                },
                                none => {}
                            }
                        },
                        _ => {}
                    }
                }
            }
            true
        }
    }
}

fn append_unresolved_issues(
    imports: List<ImportObligation>,
    resolved_obligations: Set<Int>,
    source_owners: Set<Str>,
    mut issues: List<ImportIssue>
) {
    let mut graph: Map<Str, List<Str>> = map_new()
    let mut node_order: List<Str> = []
    let mut seen_nodes: Set<Str> = set_new()
    let mut unresolved: List<Int> = []
    for obligation_index in 0..imports.len() {
        if !resolved_obligations.contains(obligation_index) {
            unresolved.push(obligation_index)
            match imports.get(obligation_index) {
                some(obligation) => {
                    // A missing frame cannot participate in an import SCC.
                    if source_owners.contains(obligation.source_owner) {
                        let target = unresolved_target_node(obligation)
                        let source = unresolved_source_node(obligation)
                        if !seen_nodes.contains(target) {
                            seen_nodes.insert(target)
                            node_order.push(target)
                        }
                        if !seen_nodes.contains(source) {
                            seen_nodes.insert(source)
                            node_order.push(source)
                        }
                        match graph.get(target) {
                            // Preserve one edge per obligation.  Tarjan may
                            // visit duplicate targets, but construction stays
                            // linear instead of scanning an adjacency list.
                            some(edges) => edges.push(source),
                            none => { graph.insert(target, [source]) }
                        }
                        if !graph.contains_key(source) {
                            graph.insert(source, [])
                        }
                    }
                },
                none => {}
            }
        }
    }

    let raw_components = ordered_import_scc(graph, node_order)
    let mut components: List<List<Str>> = []
    let mut component_is_cycle: List<Bool> = []
    let mut node_component: Map<Str, Int> = map_new()
    for component_index in 0..raw_components.len() {
        match raw_components.get(component_index) {
            some(component) => {
                let is_cycle = component.len() > 1 ||
                    (component.len() == 1 &&
                     graph_has_self_edge(
                         component.get(0).unwrap_or(""), graph))
                for node in component {
                    node_component.insert(node, component_index)
                }
                components.push(component)
                component_is_cycle.push(is_cycle)
            },
            none => {}
        }
    }

    // One post-Tarjan pass classifies every unresolved obligation and records
    // the minimum AstSite for each cyclic component.  There is no
    // component-by-obligation nested scan.
    let mut cyclic_components: Set<Int> = set_new()
    let mut component_first_obligation: Map<Int, Int> = map_new()
    for obligation_index in unresolved {
        match imports.get(obligation_index) {
            some(obligation) => {
                if !source_owners.contains(obligation.source_owner) {
                    issues.push(namespace_issue(
                        ImportIssueKind::SourceFrameMissing,
                        obligation.site, obligation.source_owner,
                        obligation.source_name, obligation.local_name,
                        NamespaceKind::Value))
                } else {
                    let target = unresolved_target_node(obligation)
                    let source = unresolved_source_node(obligation)
                    let target_component = node_component.get(target).unwrap_or(-1)
                    let source_component = node_component.get(source).unwrap_or(-2)
                    let internal_cycle =
                        target_component == source_component &&
                        target_component >= 0 &&
                        component_is_cycle.get(
                            target_component).unwrap_or(false)
                    if internal_cycle {
                        cyclic_components.insert(target_component)
                        match component_first_obligation.get(target_component) {
                            some(previous_index) => {
                                match imports.get(previous_index) {
                                    some(previous) => {
                                        if site_is_before(
                                            obligation.site, previous.site) {
                                            component_first_obligation.insert(
                                                target_component,
                                                obligation_index)
                                        }
                                    },
                                    none => {}
                                }
                            },
                            none => {
                                component_first_obligation.insert(
                                    target_component, obligation_index)
                            }
                        }
                    } else {
                        issues.push(namespace_issue(
                            ImportIssueKind::SourceNameMissing,
                            obligation.site, obligation.source_owner,
                            obligation.source_name, obligation.local_name,
                            NamespaceKind::Value))
                    }
                }
            },
            none => {}
        }
    }

    // Component ids come from deterministic Tarjan traversal.  Emit at most
    // one issue per cyclic component in that stable order.
    for component_index in 0..components.len() {
        if cyclic_components.contains(component_index) {
            match (component_first_obligation.get(component_index),
                   components.get(component_index)) {
                (some(first_index), some(component)) => {
                    match imports.get(first_index) {
                        some(first) => {
                            issues.push(ImportIssue {
                                kind: ImportIssueKind::UnresolvedImportCycle,
                                site: first.site,
                                source_owner: first.source_owner,
                                source_name: first.source_name,
                                local_name: first.local_name,
                                namespace: NamespaceKind::Value,
                                related_owners: component
                            })
                        },
                        none => {}
                    }
                },
                _ => {}
            }
        }
    }
}

pub fn resolve_namespace_plan(
    censuses: List<ModuleNamespaceCensus>
) -> ResolvedNamespacePlan {
    let mut frames: List<ModuleFramePlan> = []
    let mut imports: List<ImportObligation> = []
    let mut physical_dependencies: List<PhysicalDependencyObligation> = []
    let mut issues: List<ImportIssue> = []
    let mut exact_frames: Map<Str, ModuleFramePlan> = map_new()
    let mut source_owners: Set<Str> = set_new()
    let mut enum_variant_facts: List<EnumVariantFactGroup> = []
    let mut struct_identities: List<StructIdentityFact> = []
    let mut trait_identities: List<TraitIdentityFact> = []
    let mut source_impl_providers: List<SourceImplProviderFact> = []
    let mut delegate_providers: List<DelegateProviderFact> = []
    let mut nominal_derived_providers:
        List<NominalDerivedProviderPlanFact> = []

    for census in censuses {
        for frame in census.frames {
            frames.push(frame)
            exact_frames.insert(
                exact_frame_key(frame.file_key, frame.frame_index), frame)
            source_owners.insert(frame.owner)
        }
        for group in census.enum_variant_facts {
            append_enum_variant_fact_group(
                group.enum_symbol, group.constructors,
                enum_variant_facts)
        }
        for fact in census.struct_identities {
            append_struct_identity_fact(fact, struct_identities)
        }
        for fact in census.trait_identities {
            append_trait_identity_fact(fact, trait_identities)
        }
        for fact in census.source_impl_providers {
            append_source_impl_provider_fact(fact, source_impl_providers)
        }
        for fact in census.delegate_providers {
            append_delegate_provider_fact(fact, delegate_providers)
        }
        for fact in census.nominal_derived_providers {
            append_nominal_derived_provider_fact(
                fact, nominal_derived_providers)
        }
        imports.extend(census.imports)
        physical_dependencies.extend(census.physical_dependencies)
        issues.extend(census.issues)
    }

    // This cross-namespace guard is constructed before either worklist.
    // Named imports reset to a fixed spelling; only wildcard identity plus
    // public-inline prefix edges can form a concrete-name growth cycle.
    let growth_guard = build_namespace_growth_guard(
        frames, imports, exact_frames)
    let mut blocked_growth_components: Set<Int> = set_new()

    // Construct both reverse indexes once.  Subscriptions deliberately retain
    // logical owner identity: duplicate exact frames are distinct targets but
    // are all valid sources for a named/wildcard logical-owner subscription.
    // Source existence and unresolved SCC nodes use that same logical domain.
    // No iteration rescans the complete obligation or fact table.
    let mut named_subscriptions: Map<Str, List<Int>> = map_new()
    let mut wildcard_subscriptions: Map<Str, List<Int>> = map_new()
    let mut resolved_obligations: Set<Int> = set_new()
    let mut expanded_named_enum_relations:
        List<NamedEnumRelationExpansion> = []
    let mut pending_named_enum_relation_facts:
        List<PendingNamedEnumRelationFact> = []
    for obligation_index in 0..imports.len() {
        match imports.get(obligation_index) {
            some(obligation) => match obligation.selection {
                ImportSelection::Named => {
                    append_subscription(
                        named_subscription_key(
                            obligation.source_owner, obligation.source_name),
                        obligation_index, named_subscriptions)
                },
                ImportSelection::Wildcard => {
                    append_subscription(
                        wildcard_subscription_key(obligation.source_owner),
                        obligation_index, wildcard_subscriptions)
                    // Existence of the source frame resolves a wildcard even
                    // when it currently exposes no visible facts.  Keep the
                    // subscription so later queue deliveries still propagate.
                    if source_owners.contains(obligation.source_owner) {
                        resolved_obligations.insert(obligation_index)
                    }
                }
            },
            none => {}
        }
    }

    let mut bindings: List<ResolvedNamespaceBinding> = []
    let mut winner_occurrences: List<NamespaceFactOccurrence> = []
    let mut publication_bindings: List<ResolvedNamespaceBinding?> = []
    let mut publication_occurrences: List<NamespaceFactOccurrence?> = []
    let mut binding_indices: Map<Str, Int> = map_new()
    let mut queue: List<NamespaceQueueEvent> = []
    let mut structural_value_slots: List<ValueStructuralSlot> = []
    let mut structural_value_slot_indices: Map<Str, Int> = map_new()
    let mut value_announcements: List<ValueLaneAnnouncement> = []
    let mut import_ledger: Map<Str, List<NamespaceImportCandidate>> = map_new()
    let mut ambiguous_keys: Set<Str> = set_new()

    // Preload every direct/eager-projected Value Seed without announcing a
    // lane.  NamedEnumRelation terminals join at the Phase-1 barrier before
    // any dynamic import/projection producer can be discovered.
    for census in censuses {
        for seed in census.seeds {
            if namespace_is_value(seed.namespace) {
                let _ = register_value_structural_producer(
                    ValueStructuralProducer {
                    producer: value_seed_producer(seed),
                    target: value_binding_target(
                        seed.file_key, seed.frame_index, seed.owner,
                        seed.exposed_name, seed.is_public),
                    occurrence: NamespaceFactOccurrence {
                        provenance: NamespaceFactProvenance::Seed,
                        site: seed.origin_site,
                        leaf_origin_site: none,
                        target_file_key: seed.file_key,
                        target_frame_index: seed.frame_index,
                        seed_role: some(seed.role),
                        is_projection: seed.is_projection
                    },
                    source:
                        ValueStructuralProducerSource::TerminalValue(
                            seed.symbol)
                }, false, structural_value_slots,
                structural_value_slot_indices, value_announcements)
            } else {
                add_namespace_fact(ResolvedNamespaceBinding {
                    file_key: seed.file_key,
                    frame_index: seed.frame_index,
                    owner: seed.owner,
                    exposed_name: seed.exposed_name,
                    namespace: seed.namespace,
                    symbol: seed.symbol,
                    is_public: seed.is_public
                }, NamespaceFactOccurrence {
                    provenance: NamespaceFactProvenance::Seed,
                    site: seed.origin_site,
                    leaf_origin_site: none,
                    target_file_key: seed.file_key,
                    target_frame_index: seed.frame_index,
                    seed_role: some(seed.role),
                    is_projection: seed.is_projection
                }, true, bindings, winner_occurrences,
                publication_bindings, publication_occurrences,
                binding_indices, queue, import_ledger,
                ambiguous_keys, issues)
            }
        }
    }

    // Value terminals are absent from this generic table, so every queued
    // lane below is non-Value/Enum work needed to discover relation terminals.
    for binding_index in 0..bindings.len() {
        queue.push(NamespaceQueueEvent {
            binding_index: binding_index,
            lane: NamespaceDeliveryLane::Local
        })
        match publication_bindings.get(binding_index) {
            some(some(_)) => queue.push(NamespaceQueueEvent {
                binding_index: binding_index,
                lane: NamespaceDeliveryLane::Publication
            }),
            _ => {}
        }
    }

    // Cursor-based FIFO keeps queue consumption O(events) even when List.shift
    // would otherwise move the remaining suffix.
    let mut queue_index = 0
    while queue_index < queue.len() {
        match queue.get(queue_index) {
            none => {},
            some(event) => match event.lane {
                NamespaceDeliveryLane::Local => match (
                    bindings.get(event.binding_index),
                    winner_occurrences.get(event.binding_index)
                ) {
                    (some(fact), some(occurrence)) => {
                        propagate_namespace_event(
                            fact, occurrence, NamespaceDeliveryLane::Local,
                            exact_frames, named_subscriptions,
                            wildcard_subscriptions, imports,
                            growth_guard, blocked_growth_components,
                            enum_variant_facts, resolved_obligations,
                            expanded_named_enum_relations,
                            pending_named_enum_relation_facts, bindings,
                            winner_occurrences, publication_bindings,
                            publication_occurrences, binding_indices, queue,
                            import_ledger, ambiguous_keys, issues)
                    },
                    _ => {}
                },
                NamespaceDeliveryLane::Publication => match (
                    publication_bindings.get(event.binding_index),
                    publication_occurrences.get(event.binding_index)
                ) {
                    (some(some(fact)), some(some(occurrence))) => {
                        propagate_namespace_event(
                            fact, occurrence,
                            NamespaceDeliveryLane::Publication,
                            exact_frames, named_subscriptions,
                            wildcard_subscriptions, imports,
                            growth_guard, blocked_growth_components,
                            enum_variant_facts, resolved_obligations,
                            expanded_named_enum_relations,
                            pending_named_enum_relation_facts, bindings,
                            winner_occurrences, publication_bindings,
                            publication_occurrences, binding_indices, queue,
                            import_ledger, ambiguous_keys, issues)
                    },
                    _ => panic(
                        "namespace invariant violated: queued Publication lane is missing")
                }
            }
        }
        queue_index = queue_index + 1
    }

    // Barrier: the non-Value/Enum fixed point is complete.  Join every
    // relation-derived bare/exact constructor while all Value lanes remain
    // inert.  Only after this complete terminal preload may structural lane
    // availability be announced.
    for pending in pending_named_enum_relation_facts {
        let _ = register_value_structural_producer(
            ValueStructuralProducer {
            producer:
                value_relation_producer(
                    pending.binding, pending.occurrence),
            target: value_target_from_binding(pending.binding),
            occurrence: pending.occurrence,
            source: ValueStructuralProducerSource::TerminalValue(
                pending.binding.symbol)
        }, false, structural_value_slots,
        structural_value_slot_indices, value_announcements)
    }

    close_structural_value_graph(
        exact_frames, named_subscriptions, wildcard_subscriptions,
        imports, growth_guard, blocked_growth_components,
        resolved_obligations, structural_value_slots,
        structural_value_slot_indices, value_announcements, issues)

    let mut value_lane_nodes: List<ValueLaneNode> = []
    let mut value_lane_node_indices: Map<Str, Int> = map_new()
    let mut value_lane_solutions: List<ValueContribution?> = []
    let mut failed_value_lane_nodes: Set<Int> = set_new()
    solve_structural_value_lanes(
        structural_value_slots, imports, ambiguous_keys, issues,
        value_lane_nodes, value_lane_node_indices,
        value_lane_solutions, failed_value_lane_nodes)
    materialize_structural_value_plan(
        structural_value_slots, value_lane_nodes,
        value_lane_node_indices, value_lane_solutions,
        bindings, ambiguous_keys, issues)

    append_import_ledger_ambiguities(
        import_ledger, ambiguous_keys, issues)
    append_unresolved_issues(
        imports, resolved_obligations, source_owners, issues)
    issues.sort_by(compare_import_issues)

    ResolvedNamespacePlan {
        frames: frames,
        bindings: bindings,
        enum_variant_facts: enum_variant_facts,
        struct_identities: struct_identities,
        trait_identities: trait_identities,
        source_impl_providers: source_impl_providers,
        delegate_providers: delegate_providers,
        nominal_derived_providers: nominal_derived_providers,
        imports: imports,
        physical_dependencies: physical_dependencies,
        issues: issues
    }
}

// AstSite is portable; only this resolver adapter may recover a concrete Span.
// Physical dependencies are root UseDecl sites, while the fallback keeps the
// adapter total if a future plan consumer passes a non-root site.
fn ast_site_span(program: Program, site: AstSite) -> Span {
    if site.frame_index == 0 {
        match program.uses.get(site.use_index) {
            some(use_decl) => {
                if site.item_index >= 0 {
                    match use_decl.imports {
                        UseImport::NamedItems { names } => match names.get(site.item_index) {
                            some(item) => return item.span,
                            none => {}
                        },
                        UseImport::Module => {}
                    }
                }
                return use_decl.span
            },
            none => {}
        }
    }
    program.span
}

fn ast_site_path_span(program: Program, site: AstSite) -> Span {
    if site.frame_index == 0 {
        match program.uses.get(site.use_index) {
            some(use_decl) => return use_decl.path.span,
            none => {}
        }
    }
    program.span
}

// ============================================================
// build_module_graph
// ============================================================

pub fn build_module_graph(entry_file: Str, error_format: Str) -> ModuleGraph? {
    let abs_entry = path_resolve(entry_file)
    let project_root = path_dirname(abs_entry)

    let entry_basename = path_basename(abs_entry).replace(".ring", "")
    let entry_id = ModuleId {
        path_segments: [entry_basename],
        file_path: abs_entry
    }
    let entry_key = module_key(entry_id.path_segments)

    let mut modules: Map<Str, ModuleId> = map_new()
    let mut dependencies: Map<Str, List<Str>> = map_new()
    let mut asts_map: Map<Str, Program> = map_new()
    let mut censuses: List<ModuleNamespaceCensus> = []

    modules.insert(entry_key, entry_id)
    let mut empty_deps: List<Str> = []
    dependencies.insert(entry_key, empty_deps)

    let mut queue: List<Str> = [entry_key]

    while queue.len() > 0 {
        match queue.shift() {
            some(current_key) => {
                match modules.get(current_key) {
                    some(current_mod) => {
                        let source = read_file(current_mod.file_path)
                        let mut resolve_sink = new_collecting_sink()
                        let ast = parse(source, current_mod.file_path, resolve_sink)
                        if resolve_sink.has_errors() {
                            if error_format == "llm" {
                                eprintln(format_llm(resolve_sink.diagnostics(), current_mod.file_path))
                            } else {
                                eprintln(format_human(resolve_sink.diagnostics(), source))
                            }
                            return none
                        }
                        match first_duplicate_direct_declaration(ast) {
                            some(duplicate) => {
                                resolve_sink.report(
                                    duplicate_direct_declaration_diagnostic(
                                        duplicate))
                                if error_format == "llm" {
                                    eprintln(format_llm(
                                        resolve_sink.diagnostics(),
                                        current_mod.file_path))
                                } else {
                                    eprintln(format_human(
                                        resolve_sink.diagnostics(), source))
                                }
                                return none
                            },
                            none => {}
                        }
                        // Surface parse warnings (non-error diagnostics) without failing the build
                        if resolve_sink.items.len() > 0 {
                            if error_format == "llm" {
                                eprintln(format_llm(resolve_sink.diagnostics(), current_mod.file_path))
                            } else {
                                eprintln(format_human(resolve_sink.diagnostics(), source))
                            }
                        }
                        // Exactly one portable census is produced for each
                        // successfully parsed physical module.
                        let census = census_module_namespaces(
                            current_mod.path_segments, ast)
                        asts_map.insert(current_key, ast)
                        censuses.push(census)

                        let mut deps: List<Str> = []
                        // The physical frontier is normalized by census.  Do
                        // not reinterpret UseDecl.path in this adapter.
                        for physical in census.physical_dependencies {
                            let dep_key = physical.module_key
                            if !deps.contains(dep_key) {
                                match resolve_module_file(
                                    physical.module_segments, project_root) {
                                    some(resolved) => {
                                        let abs_resolved = path_resolve(resolved)
                                        match modules.get(dep_key) {
                                            none => {
                                                let dep_id = ModuleId {
                                                    path_segments: list_clone(
                                                        physical.module_segments),
                                                    file_path: abs_resolved
                                                }
                                                modules.insert(dep_key, dep_id)
                                                let mut empty: List<Str> = []
                                                dependencies.insert(dep_key, empty)
                                                queue.push(dep_key)
                                            },
                                            some(_) => {},
                                        }
                                        deps.push(dep_key)
                                    },
                                    none => {
                                        let mod_path = physical.module_segments.join("::")
                                        let diag = make_diag(
                                            E0702,
                                            Severity::SevError,
                                            "Module '${mod_path}' not found",
                                            ast_site_span(ast, physical.site),
                                            DiagnosticContext::OtherContext { detail: some("no file '${mod_path}.ring' in project root") }
                                        )
                                        let mut err_sink = new_collecting_sink()
                                        err_sink.report(diag)
                                        if error_format == "llm" {
                                            eprintln(format_llm(err_sink.diagnostics(), current_mod.file_path))
                                        } else {
                                            eprintln(format_human(err_sink.diagnostics(), source))
                                        }
                                        return none
                                    },
                                }
                            }
                        }
                        dependencies.insert(current_key, deps)
                    },
                    none => {},
                }
            },
            none => {},
        }
    }

    // Namespace resolution is a single finite worklist run after the complete
    // physical AST/census set is known.
    let namespace_plan = resolve_namespace_plan(censuses)

    // Unit3A exposes exactly one namespace-plan diagnostic adapter: the
    // existing file-root relative-path error.  All other plan issues remain
    // portable data for the later checker cutover.
    for issue in namespace_plan.issues {
        match issue.kind {
            ImportIssueKind::RelativeOutOfScope => {
                // Inline over-super is plan data only.  The immediate E0705
                // adapter is intentionally limited to a file-root AstSite.
                if issue.site.frame_index == 0 {
                    match (asts_map.get(issue.site.file_key),
                           modules.get(issue.site.file_key)) {
                        (some(issue_ast), some(issue_module)) => {
                            let diag = make_diag(
                                E0705,
                                Severity::SevError,
                                "Cannot use '${issue.source_name}::' at file level — relative paths are only supported inside mod blocks",
                                ast_site_path_span(issue_ast, issue.site),
                                DiagnosticContext::OtherContext {
                                    detail: some("relative path out of scope")
                                }
                            )
                            let mut err_sink = new_collecting_sink()
                            err_sink.report(diag)
                            if error_format == "llm" {
                                eprintln(format_llm(
                                    err_sink.diagnostics(), issue_module.file_path))
                            } else {
                                eprintln(format_human(
                                    err_sink.diagnostics(),
                                    read_file(issue_module.file_path)))
                            }
                            return none
                        },
                        _ => {}
                    }
                }
            },
            _ => {}
        }
    }

    // Topological sort (Kahn's algorithm)
    let mut dep_count: Map<Str, Int> = map_new()
    let mut sorted_dependencies = dependencies.entries()
    sorted_dependencies.sort_by(compare_by_first)
    for entry in sorted_dependencies {
        let (key, deps) = entry
        dep_count.insert(key, deps.len())
    }

    let mut topo_order: List<Str> = []
    let mut ready: List<Str> = []

    let mut sorted_dep_count = dep_count.entries()
    sorted_dep_count.sort_by(compare_by_first)
    for entry in sorted_dep_count {
        let (key, count) = entry
        if count == 0 { ready.push(key) }
    }

    while ready.len() > 0 {
        match ready.shift() {
            some(node) => {
                topo_order.push(node)
                for entry in sorted_dependencies {
                    let (key, deps) = entry
                    if deps.contains(node) {
                        match dep_count.get(key) {
                            some(c) => {
                                let new_count = c - 1
                                dep_count.insert(key, new_count)
                                if new_count == 0 { ready.push(key) }
                            },
                            none => {},
                        }
                    }
                }
            },
            none => {},
        }
    }

    if topo_order.len() != modules.len() {
        // Cycle detected — find and report the cycle path
        let mut cycle_nodes: List<Str> = []
        let mut sorted_modules = modules.entries()
        sorted_modules.sort_by(compare_by_first)
        for entry in sorted_modules {
            let (key, _) = entry
            if !topo_order.contains(key) {
                cycle_nodes.push(key)
            }
        }
        // Build a human-readable cycle path by following dependencies
        let cycle_path = find_cycle_path(cycle_nodes, dependencies)
        let cycle_desc = cycle_path.join(" -> ")
        let file_span = Span {
            file: abs_entry,
            start: Position { line: 1, column: 0, offset: 0 },
            end: Position { line: 1, column: 0, offset: 0 }
        }
        let diag = make_diag(
            E0704,
            Severity::SevError,
            "Circular dependency detected: ${cycle_desc}",
            file_span,
            DiagnosticContext::OtherContext { detail: some("modules form a dependency cycle") }
        )
        let mut err_sink = new_collecting_sink()
        err_sink.report(diag)
        if error_format == "llm" {
            eprintln(format_llm(err_sink.diagnostics(), abs_entry))
        } else {
            let entry_source = read_file(abs_entry)
            eprintln(format_human(err_sink.diagnostics(), entry_source))
        }
        return none
    }

    some(ModuleGraph {
        entry: ModuleId { path_segments: [entry_basename], file_path: abs_entry },
        modules: modules,
        dependencies: dependencies,
        topo_order: topo_order,
        asts: asts_map,
        namespace_plan: namespace_plan
    })
}

// Find a cycle path among the nodes that weren't topologically sorted.
// Returns a list like ["a", "b", "a"] showing the cycle.
fn find_cycle_path(cycle_nodes: List<Str>, dependencies: Map<Str, List<Str>>) -> List<Str> {
    if cycle_nodes.len() == 0 { return ["(unknown)"] }
    let cycle_set: Set<Str> = set_from(cycle_nodes)

    // Try each cycle node as a potential cycle start.
    // Follow a single path through cycle-member deps; if we return to start, that's the cycle.
    for start_node in cycle_nodes {
        let mut path: List<Str> = [start_node]
        let mut current = start_node
        let mut visited: Set<Str> = set_new()
        visited.insert(current)
        let mut found_cycle = false

        while !found_cycle {
            let maybe_deps = dependencies.get(current)
            if maybe_deps.is_none() { break }
            let deps = maybe_deps.unwrap()
            let mut advanced = false
            for dep in deps {
                if cycle_set.contains(dep) {
                    if dep == start_node {
                        path.push(dep)
                        found_cycle = true
                        advanced = true
                        break
                    }
                    if !visited.contains(dep) {
                        visited.insert(dep)
                        path.push(dep)
                        current = dep
                        advanced = true
                        break
                    }
                }
            }
            if !advanced { break }
        }

        if found_cycle { return path }
    }

    // Fallback: just list the cycle nodes
    let mut fallback: List<Str> = []
    for n in cycle_nodes { fallback.push(n) }
    match cycle_nodes.get(0) {
        some(first) => fallback.push(first),
        none => {},
    }
    fallback
}
