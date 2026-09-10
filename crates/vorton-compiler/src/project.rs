//! Pure in-memory project input and structured resolver output.

use std::collections::BTreeMap;
use std::fmt;

use crate::ast::{
    AssignmentOperator, BinaryOperator, BindingMode, CallAssertionMode, CaptureMode, ParameterMode,
    RawStringDelimiter, Span, StatementTerminator, UnaryOperator,
};
use crate::diagnostic::FrontendDiagnosticKind;

/// A validated abstract source key for a non-root file module.
///
/// Segments are platform-independent and never interpreted as filesystem paths.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FileModulePath(Vec<String>);

impl FileModulePath {
    /// Builds a source key from one or more logical module segments.
    pub fn new<I, S>(segments: I) -> Result<Self, FileModulePathError>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let segments = segments.into_iter().map(Into::into).collect::<Vec<_>>();
        validate_file_module_segments(&segments)?;
        Ok(Self(segments))
    }

    pub(crate) fn segments(&self) -> &[String] {
        &self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileModulePathError {
    pub segment_index: Option<usize>,
    pub segment: Option<String>,
    pub kind: FileModulePathErrorKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileModulePathErrorKind {
    EmptyPath,
    InvalidIdentifier,
    ReservedSegment,
}

fn validate_file_module_segments(segments: &[String]) -> Result<(), FileModulePathError> {
    if segments.is_empty() {
        return Err(FileModulePathError {
            segment_index: None,
            segment: None,
            kind: FileModulePathErrorKind::EmptyPath,
        });
    }

    for (index, segment) in segments.iter().enumerate() {
        let kind = if !is_module_identifier(segment) {
            Some(FileModulePathErrorKind::InvalidIdentifier)
        } else if is_reserved_module_segment(segment) {
            Some(FileModulePathErrorKind::ReservedSegment)
        } else {
            None
        };
        if let Some(kind) = kind {
            return Err(FileModulePathError {
                segment_index: Some(index),
                segment: Some(segment.clone()),
                kind,
            });
        }
    }
    Ok(())
}

pub(crate) fn is_reserved_module_segment(segment: &str) -> bool {
    crate::lexer::is_keyword(segment) || matches!(segment, "self" | "root")
}

pub(crate) fn is_valid_dependency_alias(alias: &str) -> bool {
    is_module_identifier(alias) && !is_reserved_module_segment(alias)
}

fn is_module_identifier(value: &str) -> bool {
    value
        .as_bytes()
        .first()
        .is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'_')
        && value
            .as_bytes()
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_')
}

/// The host-assigned identity of one library instance in a project input.
///
/// The value is local to that input. It is not a package name, version, path,
/// dependency alias, or compiler-assigned traversal ordinal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LibraryId(pub u32);

/// All source text and direct dependency aliases for one library.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibrarySources {
    /// The library's always-reachable root source.
    pub root: String,
    /// File sources addressed by library-local logical module paths.
    pub modules: BTreeMap<FileModulePath, String>,
    /// Root-scoped source aliases pointing to direct library identities.
    pub dependencies: BTreeMap<String, LibraryId>,
}

/// A closed, pure in-memory library graph supplied to [`crate::resolve_project`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectSources {
    /// The library whose dependency closure forms this resolution input.
    pub entry: LibraryId,
    /// The host-selected official core library for this resolution input.
    ///
    /// This must name a real `libraries` key. Every reachable non-core library
    /// must directly depend on the same identity.
    pub core: LibraryId,
    /// Every library referenced by the explicit input graph, reachable or not.
    pub libraries: BTreeMap<LibraryId, LibrarySources>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum SourceRef {
    /// The root source of the library carried by the surrounding origin.
    Root,
    /// A file source addressed within the library carried by the origin.
    File(FileModulePath),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct OriginRef {
    /// The source's owning library in the current project input.
    pub library: LibraryId,
    /// The address of the source within `library`.
    pub source: SourceRef,
    /// The half-open UTF-8 byte range within `source`.
    pub span: Span,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum NameNamespace {
    Type,
    Value,
    Effect,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectDiagnostic {
    pub kind: ProjectDiagnosticKind,
    pub primary: Option<OriginRef>,
    pub related: Vec<OriginRef>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProjectDiagnosticKind {
    /// `entry` is not a key in the supplied library graph.
    MissingEntryLibrary {
        entry: LibraryId,
    },
    /// `core` is not a key in the supplied library graph.
    MissingCoreLibrary {
        core: LibraryId,
    },
    /// A direct dependency alias is not one legal source identifier.
    InvalidDependencyAlias {
        owner: LibraryId,
        alias: String,
    },
    /// A direct dependency edge names a library absent from the graph.
    MissingDependencyTarget {
        owner: LibraryId,
        alias: String,
        target: LibraryId,
    },
    /// The repeated first/last element closes an actual dependency cycle.
    LibraryDependencyCycle {
        cycle: Vec<LibraryId>,
    },
    /// A reachable non-core library does not directly depend on `core`.
    MissingDirectCoreDependency {
        owner: LibraryId,
        core: LibraryId,
    },
    Frontend(FrontendDiagnosticKind),
    /// A reachable `generate` item requires the later generation stage.
    GenerateUnsupported,
    InvalidModuleName {
        name: String,
    },
    ModuleBodyConflict {
        module: Vec<String>,
    },
    PathEscapesRoot,
    InvalidPath,
    NameConflict {
        library: LibraryId,
        namespace: NameNamespace,
        name: String,
    },
    MemberConflict {
        name: String,
    },
    ReservedLanguageBinding {
        library: LibraryId,
        namespace: NameNamespace,
        name: String,
    },
    UnresolvedImport {
        path: String,
    },
    AmbiguousImport {
        path: String,
    },
    InaccessibleImport {
        path: String,
    },
    ImportCycle {
        path: String,
    },
    PrivateReExport {
        name: String,
    },
    MissingConstructorOwner {
        constructor: String,
    },
    UnresolvedName {
        namespace: NameNamespace,
        name: String,
    },
    AmbiguousName {
        name: String,
    },
    InaccessibleName {
        name: String,
    },
    DuplicateBinding {
        name: String,
    },
    PatternBindingMismatch,
    InvalidSelf {
        library: LibraryId,
    },
    /// The official core root does not declare one required semantic role.
    MissingCoreRole {
        core: LibraryId,
        role: String,
    },
    /// A declared core role does not match the required bootstrap profile.
    InvalidCoreRole(Box<CoreRoleDiagnostic>),
}

/// Source-backed detail for an invalid official core role.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreRoleDiagnostic {
    pub core: LibraryId,
    pub role: String,
    pub member: Option<String>,
    pub issue: CoreRoleIssue,
}

/// The finite declaration-profile mismatch detected for one official core role.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoreRoleIssue {
    DeclarationKind,
    Visibility,
    GenericArity {
        expected: usize,
        actual: usize,
    },
    GenericBounds,
    VariantSet,
    VariantPayload,
    Supertraits,
    MemberSet,
    MemberKind,
    MethodGenericArity {
        expected_types: usize,
        actual_types: usize,
        expected_effects: usize,
        actual_effects: usize,
    },
    ParameterCount {
        expected: usize,
        actual: usize,
    },
    Receiver,
    ParameterMode {
        index: usize,
        expected: ParameterMode,
        actual: Option<ParameterMode>,
    },
    ParameterEscape {
        index: usize,
    },
    ParameterType {
        index: usize,
    },
    ReturnType,
    EffectProfile,
    AssociatedTypeBounds,
    AssociatedTypeDefault,
}

/// An owned project whose lexical and nominal names have been resolved.
///
/// Its carrier is intentionally opaque until the Checker API is introduced.
#[derive(Clone, PartialEq, Eq)]
pub struct ResolvedProject {
    pub(crate) entry: LibraryId,
    pub(crate) core: LibraryId,
    pub(crate) dependencies: BTreeMap<LibraryId, BTreeMap<String, LibraryId>>,
    pub(crate) modules: BTreeMap<ModuleRef, ResolvedModule>,
    pub(crate) entities: BTreeMap<EntityId, Entity>,
    pub(crate) core_roles: CoreRoles,
}

impl fmt::Debug for ResolvedProject {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ResolvedProject")
            .field("entry", &self.entry)
            .field("core", &self.core)
            .field("library_count", &self.dependencies.len())
            .field("module_count", &self.modules.len())
            .field("entity_count", &self.entities.len())
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) enum ModuleRef {
    Language,
    Source {
        library: LibraryId,
        path: Vec<String>,
    },
}

impl ModuleRef {
    pub(crate) fn root(library: LibraryId) -> Self {
        Self::Source {
            library,
            path: Vec::new(),
        }
    }

    pub(crate) fn language_root() -> Self {
        Self::Language
    }

    pub(crate) fn library(&self) -> LibraryId {
        match self {
            Self::Source { library, .. } => *library,
            Self::Language => panic!("Language origin has no source library"),
        }
    }

    pub(crate) fn source_library(&self) -> Option<LibraryId> {
        match self {
            Self::Source { library, .. } => Some(*library),
            Self::Language => None,
        }
    }

    pub(crate) fn is_language(&self) -> bool {
        matches!(self, Self::Language)
    }

    pub(crate) fn path(&self) -> &[String] {
        match self {
            Self::Source { path, .. } => path,
            Self::Language => &[],
        }
    }

    pub(crate) fn is_root(&self) -> bool {
        matches!(self, Self::Source { path, .. } if path.is_empty())
    }

    pub(crate) fn child(&self, name: &str) -> Self {
        let mut path = self.path().to_vec();
        path.push(name.to_owned());
        Self::Source {
            library: self.library(),
            path,
        }
    }

    pub(crate) fn parent(&self) -> Option<Self> {
        let path = self.path();
        (!path.is_empty()).then(|| Self::Source {
            library: self.library(),
            path: path[..path.len() - 1].to_vec(),
        })
    }

    pub(crate) fn is_descendant_of(&self, ancestor: &Self) -> bool {
        match (self, ancestor) {
            (
                Self::Source { library, path },
                Self::Source {
                    library: ancestor_library,
                    path: ancestor_path,
                },
            ) => library == ancestor_library && path.starts_with(ancestor_path),
            _ => false,
        }
    }

    pub(crate) fn from_file(library: LibraryId, path: &FileModulePath) -> Self {
        Self::Source {
            library,
            path: path.0.clone(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) enum Namespace {
    Type,
    Value,
    Effect,
    Member,
}

impl Namespace {
    pub(crate) fn public(self) -> Option<NameNamespace> {
        match self {
            Self::Type => Some(NameNamespace::Type),
            Self::Value => Some(NameNamespace::Value),
            Self::Effect => Some(NameNamespace::Effect),
            Self::Member => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) enum EntityKind {
    Module,
    Struct,
    Enum,
    TypeAlias,
    ExternType,
    Trait,
    TypeParameter,
    EffectParameter,
    SelfType,
    Function,
    Const,
    ExternFunction,
    EnumConstructor,
    Parameter,
    Local,
    PatternBinding,
    Effect,
    EffectAlias,
    Field,
    Method,
    AssociatedType,
    EffectOperation,
    LanguageType,
    LanguageEffect,
    InherentImpl,
    TraitImpl,
    Closure,
    Handler,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) enum EntitySite {
    Language,
    Module(ModuleRef),
    Source(OriginRef),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct OwnerKey {
    pub(crate) module: ModuleRef,
    pub(crate) source: SourceRef,
    pub(crate) span: Span,
    pub(crate) kind: EntityKind,
    pub(crate) name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct EntityId {
    pub(crate) module: ModuleRef,
    pub(crate) namespace: Namespace,
    pub(crate) kind: EntityKind,
    pub(crate) name: String,
    pub(crate) site: EntitySite,
    pub(crate) owner: Option<OwnerKey>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Entity {
    pub(crate) declared_at: Option<OriginRef>,
    pub(crate) public: bool,
    pub(crate) owner: Option<EntityId>,
    pub(crate) members: BTreeMap<String, Vec<EntityId>>,
    pub(crate) shape: EntityShape,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CoreRoles {
    pub(crate) option: CoreOptionRole,
    pub(crate) ordering: CoreOrderingRole,
    pub(crate) partial_eq: CoreMethodRole,
    pub(crate) eq: EntityId,
    pub(crate) partial_ord: CoreMethodRole,
    pub(crate) ord: CoreMethodRole,
    pub(crate) clone: CoreMethodRole,
    pub(crate) copy: EntityId,
    pub(crate) drop: CoreMethodRole,
    pub(crate) display: CoreMethodRole,
    pub(crate) debug: CoreMethodRole,
    pub(crate) hash: CoreMethodRole,
    pub(crate) fn_once: EntityId,
    pub(crate) fn_mut: EntityId,
    pub(crate) function: EntityId,
    pub(crate) iterator: CoreIteratorRole,
    pub(crate) iterable: CoreIterableRole,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CoreOptionRole {
    pub(crate) declaration: EntityId,
    pub(crate) some: EntityId,
    pub(crate) none: EntityId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CoreOrderingRole {
    pub(crate) declaration: EntityId,
    pub(crate) less: EntityId,
    pub(crate) equal: EntityId,
    pub(crate) greater: EntityId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CoreMethodRole {
    pub(crate) declaration: EntityId,
    pub(crate) method: EntityId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CoreIteratorRole {
    pub(crate) declaration: EntityId,
    pub(crate) item: EntityId,
    pub(crate) next: EntityId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CoreIterableRole {
    pub(crate) declaration: EntityId,
    pub(crate) item: EntityId,
    pub(crate) iter_type: EntityId,
    pub(crate) iter: EntityId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EntityShape {
    Plain,
    ConstructorUnit,
    ConstructorPositional,
    ConstructorNamed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedModule {
    pub(crate) body: Option<ResolvedModuleBody>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedModuleBody {
    pub(crate) origin: OriginRef,
    pub(crate) requires: Option<ResolvedEffectSet>,
    pub(crate) imports: Vec<ResolvedImport>,
    pub(crate) declarations: Vec<ResolvedDeclaration>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedImport {
    pub(crate) origin: OriginRef,
    pub(crate) public: bool,
    pub(crate) local_name: String,
    pub(crate) target: EntityId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedDeclaration {
    pub(crate) origin: OriginRef,
    pub(crate) identity: Option<EntityId>,
    pub(crate) public: bool,
    pub(crate) kind: ResolvedDeclarationKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedDeclarationKind {
    Function(ResolvedFunction),
    Struct {
        type_parameters: Vec<ResolvedTypeParameter>,
        fields: Vec<ResolvedField>,
    },
    Enum {
        type_parameters: Vec<ResolvedTypeParameter>,
        variants: Vec<ResolvedVariant>,
    },
    InherentImpl(ResolvedImpl),
    TraitImpl {
        implementation: Box<ResolvedImpl>,
        trait_type: ResolvedNamedType,
        where_clause: Option<ResolvedWhereClause>,
    },
    Trait {
        type_parameters: Vec<ResolvedTypeParameter>,
        supertraits: Vec<ResolvedNamedType>,
        members: Vec<ResolvedTraitMember>,
    },
    Effect {
        type_parameters: Vec<ResolvedTypeParameter>,
        operations: Vec<ResolvedEffectOperation>,
    },
    EffectAlias {
        type_parameters: Vec<ResolvedTypeParameter>,
        effects: ResolvedEffectSet,
    },
    ExternFunction(ResolvedFunctionSignature),
    ExternType {
        type_parameters: Vec<ResolvedTypeParameter>,
    },
    TypeAlias {
        type_parameters: Vec<ResolvedTypeParameter>,
        value: ResolvedType,
    },
    Const {
        annotation: Option<ResolvedType>,
        value: ResolvedExpr,
    },
    Module(ModuleRef),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedFunction {
    pub(crate) const_span: Option<Span>,
    pub(crate) type_parameters: Vec<ResolvedTypeParameter>,
    pub(crate) effect_parameters: Vec<ResolvedEffectParameter>,
    pub(crate) parameters: Vec<ResolvedParameter>,
    pub(crate) return_type: Option<Box<ResolvedReturnAnnotation>>,
    pub(crate) effects: Option<ResolvedEffectSet>,
    pub(crate) body: ResolvedBlock,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedFunctionSignature {
    pub(crate) identity: EntityId,
    pub(crate) type_parameters: Vec<ResolvedTypeParameter>,
    pub(crate) effect_parameters: Vec<ResolvedEffectParameter>,
    pub(crate) parameters: Vec<ResolvedParameter>,
    pub(crate) return_type: Option<ResolvedType>,
    pub(crate) effects: Option<ResolvedEffectSet>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedParameter {
    pub(crate) span: Span,
    pub(crate) binding: ResolvedBinding,
    pub(crate) escape: Option<Span>,
    pub(crate) mode: Option<(Span, ParameterMode)>,
    pub(crate) annotation: Option<ResolvedParameterAnnotation>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedParameterAnnotation {
    Type(ResolvedType),
    Shape(ResolvedShape),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedReturnAnnotation {
    Type(ResolvedType),
    Shape(ResolvedShape),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedTypeParameter {
    pub(crate) span: Span,
    pub(crate) binding: ResolvedBinding,
    pub(crate) bounds: Vec<ResolvedGenericBound>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedGenericBound {
    Named(Box<ResolvedNamedType>),
    Shape(ResolvedShape),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedEffectParameter {
    pub(crate) span: Span,
    pub(crate) binding: ResolvedBinding,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedField {
    pub(crate) identity: EntityId,
    pub(crate) public: bool,
    pub(crate) ty: ResolvedType,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedVariant {
    pub(crate) identity: EntityId,
    pub(crate) fields: ResolvedVariantFields,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedVariantFields {
    Unit,
    Positional(Vec<ResolvedType>),
    Named(Vec<ResolvedNamedField>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedNamedField {
    pub(crate) identity: EntityId,
    pub(crate) ty: ResolvedType,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedImpl {
    pub(crate) type_parameters: Vec<ResolvedTypeParameter>,
    pub(crate) target: ResolvedNamedType,
    pub(crate) members: Vec<ResolvedImplMember>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedWhereClause {
    pub(crate) span: Span,
    pub(crate) keyword_span: Span,
    pub(crate) predicates: Vec<ResolvedWherePredicate>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedWherePredicate {
    pub(crate) span: Span,
    pub(crate) subject: ResolvedType,
    pub(crate) bounds: Vec<ResolvedNamedType>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedImplMember {
    pub(crate) identity: EntityId,
    pub(crate) public: bool,
    pub(crate) kind: ResolvedImplMemberKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedImplMemberKind {
    Function(ResolvedFunction),
    AssociatedType(ResolvedType),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedTraitMember {
    pub(crate) identity: EntityId,
    pub(crate) kind: ResolvedTraitMemberKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedTraitMemberKind {
    Method(Box<ResolvedFunctionSignature>),
    AssociatedType {
        bounds: Vec<ResolvedNamedType>,
        default: Option<ResolvedType>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedEffectOperation {
    pub(crate) identity: EntityId,
    pub(crate) parameters: Vec<ResolvedParameter>,
    pub(crate) return_type: ResolvedType,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedBinding {
    pub(crate) origin: OriginRef,
    pub(crate) identity: EntityId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedReference {
    Exact {
        occurrence: OriginRef,
        target: EntityId,
        self_reference: Option<Box<ResolvedSelfReference>>,
    },
    Selection {
        occurrence: OriginRef,
        base: EntityId,
        namespace: Namespace,
        members: Vec<ResolvedSelection>,
        self_reference: Option<Box<ResolvedSelfReference>>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedSelfReference {
    pub(crate) origin: OriginRef,
    pub(crate) identity: EntityId,
    pub(crate) target: Option<Box<ResolvedNamedType>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedSelection {
    pub(crate) origin: OriginRef,
    pub(crate) name: String,
    pub(crate) declaration: Option<EntityId>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedNamedType {
    pub(crate) span: Span,
    pub(crate) reference: ResolvedReference,
    pub(crate) arguments: Vec<ResolvedTypeArgument>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedTypeArgument {
    Type(Box<ResolvedType>),
    AssociatedType {
        member: Box<ResolvedSelection>,
        value: Box<ResolvedType>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedType {
    pub(crate) span: Span,
    pub(crate) kind: ResolvedTypeKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedTypeKind {
    Named(Box<ResolvedNamedType>),
    Grouped(Box<ResolvedType>),
    Tuple(Vec<ResolvedType>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedShape {
    pub(crate) span: Span,
    pub(crate) kind: ResolvedShapeKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedShapeKind {
    Callable {
        parameters: Vec<ResolvedShapeParameter>,
        return_type: Box<ResolvedType>,
        effects: Option<ResolvedEffectSet>,
    },
    Grouped(Box<ResolvedShape>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedShapeParameter {
    pub(crate) span: Span,
    pub(crate) escape: Option<Span>,
    pub(crate) mode: Option<(Span, ParameterMode)>,
    pub(crate) ty: ResolvedType,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedEffectSet {
    pub(crate) span: Span,
    pub(crate) effects: Vec<ResolvedEffect>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedEffect {
    pub(crate) span: Span,
    pub(crate) reference: ResolvedReference,
    pub(crate) arguments: Vec<ResolvedType>,
    pub(crate) effect_arguments: Vec<ResolvedEffectRowArgument>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedEffectRowArgument {
    pub(crate) span: Span,
    pub(crate) effects: ResolvedEffectSet,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedBlock {
    pub(crate) span: Span,
    pub(crate) statements: Vec<ResolvedStatement>,
    pub(crate) tail: Option<Box<ResolvedExpr>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedStatement {
    pub(crate) span: Span,
    pub(crate) kind: ResolvedStatementKind,
    pub(crate) terminator: StatementTerminator,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedStatementKind {
    Let {
        bindings: Vec<ResolvedBinding>,
        annotation: Option<ResolvedType>,
        value: ResolvedExpr,
    },
    Return(Option<ResolvedExpr>),
    Break,
    Continue,
    Assignment {
        target: ResolvedPlace,
        operator: (Span, AssignmentOperator),
        value: ResolvedExpr,
    },
    Expression(ResolvedExpr),
    IfLet {
        pattern: ResolvedPattern,
        value: ResolvedExpr,
        then_branch: ResolvedBlock,
        else_branch: Option<ResolvedBlock>,
    },
    While {
        condition: ResolvedExpr,
        body: ResolvedBlock,
    },
    For {
        bindings: Vec<ResolvedBinding>,
        iterable: ResolvedExpr,
        body: ResolvedBlock,
    },
    Loop(ResolvedBlock),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedPlace {
    pub(crate) span: Span,
    pub(crate) root: ResolvedReference,
    pub(crate) fields: Vec<ResolvedSelection>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedExpr {
    pub(crate) span: Span,
    pub(crate) kind: ResolvedExprKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedExprKind {
    Integer(String),
    Float(String),
    String(String),
    RawString {
        value: String,
        delimiter: RawStringDelimiter,
    },
    InterpolatedString(Vec<ResolvedInterpolationPart>),
    Boolean(bool),
    Path(ResolvedReference),
    NamedConstruct {
        target: ResolvedReference,
        entries: Vec<ResolvedConstructEntry>,
    },
    List(Vec<ResolvedExpr>),
    Unit,
    Parenthesized(Box<ResolvedExpr>),
    Tuple(Vec<ResolvedExpr>),
    Block(ResolvedBlock),
    If {
        condition: Box<ResolvedExpr>,
        then_branch: ResolvedBlock,
        else_branch: Option<Box<ResolvedExpr>>,
    },
    Match {
        scrutinee: Box<ResolvedExpr>,
        arms: Vec<ResolvedMatchArm>,
    },
    Handle {
        body: ResolvedBlock,
        handlers: Vec<ResolvedHandler>,
    },
    Closure(ResolvedClosure),
    Unsafe(ResolvedBlock),
    Catch {
        expression: Box<ResolvedExpr>,
        arms: Vec<ResolvedMatchArm>,
    },
    Unary {
        operator: (Span, UnaryOperator),
        operand: Box<ResolvedExpr>,
    },
    Binary {
        left: Box<ResolvedExpr>,
        operator: (Span, BinaryOperator),
        right: Box<ResolvedExpr>,
    },
    Propagate(Box<ResolvedExpr>),
    Call {
        callee: Box<ResolvedExpr>,
        arguments: Vec<ResolvedCallArgument>,
    },
    Index {
        receiver: Box<ResolvedExpr>,
        index: Box<ResolvedExpr>,
    },
    TupleField {
        receiver: Box<ResolvedExpr>,
        index: String,
        origin: OriginRef,
    },
    Field {
        receiver: Box<ResolvedExpr>,
        field: ResolvedSelection,
    },
    MethodCall {
        receiver: Box<ResolvedExpr>,
        method: ResolvedSelection,
        arguments: Vec<ResolvedCallArgument>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedInterpolationPart {
    String { origin: OriginRef, value: String },
    Expression(Box<ResolvedExpr>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedConstructEntry {
    Spread(ResolvedExpr),
    Field {
        member: ResolvedSelection,
        value: Option<Box<ResolvedExpr>>,
        shorthand: Option<Box<ResolvedReference>>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedCallArgument {
    Expression(ResolvedExpr),
    Mode {
        span: Span,
        mode: (Span, CallAssertionMode),
        place: ResolvedPlace,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedMatchArm {
    pub(crate) span: Span,
    pub(crate) pattern: ResolvedPattern,
    pub(crate) guard: Option<ResolvedExpr>,
    pub(crate) body: ResolvedExpr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedPattern {
    pub(crate) span: Span,
    pub(crate) kind: ResolvedPatternKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedPatternKind {
    Wildcard,
    Integer(String),
    Float(String),
    String(String),
    Boolean(bool),
    Binding(ResolvedPatternBinding),
    Constructor {
        target: ResolvedReference,
        fields: Option<ResolvedPatternFields>,
    },
    Tuple(Vec<ResolvedPattern>),
    Or(Vec<ResolvedPattern>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedPatternBinding {
    pub(crate) binding: ResolvedBinding,
    pub(crate) qualifier: Option<(Span, BindingMode)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResolvedPatternFields {
    Positional(Vec<ResolvedPattern>),
    Named {
        fields: Vec<ResolvedNamedPatternField>,
        rest: Option<Span>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedNamedPatternField {
    pub(crate) member: ResolvedSelection,
    pub(crate) pattern: ResolvedPattern,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedHandler {
    pub(crate) span: Span,
    pub(crate) effect: ResolvedReference,
    pub(crate) operation: ResolvedSelection,
    pub(crate) parameters: Vec<ResolvedParameter>,
    pub(crate) body: ResolvedExpr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedClosure {
    pub(crate) captures: Vec<ResolvedCapture>,
    pub(crate) parameters: Vec<ResolvedParameter>,
    pub(crate) return_type: Option<Box<ResolvedReturnAnnotation>>,
    pub(crate) effects: Option<ResolvedEffectSet>,
    pub(crate) body: ResolvedBlock,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedCapture {
    pub(crate) span: Span,
    pub(crate) mode: Option<(Span, CaptureMode)>,
    pub(crate) reference: ResolvedReference,
    pub(crate) annotation: Option<ResolvedType>,
}
