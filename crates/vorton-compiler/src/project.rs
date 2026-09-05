//! Pure in-memory project input and structured resolver output.

use std::collections::BTreeMap;
use std::fmt;

use crate::ast::{
    AssignmentOperator, BinaryOperator, ParameterMode, RawStringDelimiter, Span,
    StatementTerminator, UnaryOperator,
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
        let valid_identifier = segment
            .as_bytes()
            .first()
            .is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'_')
            && segment
                .as_bytes()
                .iter()
                .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_');
        let kind = if !valid_identifier {
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

/// All source text supplied to [`crate::resolve_project`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectSources {
    pub root: String,
    pub modules: BTreeMap<FileModulePath, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum SourceRef {
    Root,
    File(FileModulePath),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct OriginRef {
    pub source: SourceRef,
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
    Frontend(FrontendDiagnosticKind),
    InvalidModuleName {
        name: String,
    },
    ModuleBodyConflict {
        module: Vec<String>,
    },
    PathEscapesRoot,
    InvalidPath,
    NameConflict {
        namespace: NameNamespace,
        name: String,
    },
    MemberConflict {
        name: String,
    },
    ReservedLanguageBinding {
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
    InvalidSelf,
}

/// An owned project whose lexical and nominal names have been resolved.
///
/// Its carrier is intentionally opaque until the Checker API is introduced.
#[derive(Clone, PartialEq, Eq)]
pub struct ResolvedProject {
    pub(crate) modules: BTreeMap<ModuleRef, ResolvedModule>,
    pub(crate) entities: BTreeMap<EntityId, Entity>,
}

impl fmt::Debug for ResolvedProject {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ResolvedProject")
            .field("module_count", &self.modules.len())
            .field("entity_count", &self.entities.len())
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct ModuleRef(pub(crate) Vec<String>);

impl ModuleRef {
    pub(crate) fn root() -> Self {
        Self(Vec::new())
    }

    pub(crate) fn child(&self, name: &str) -> Self {
        let mut segments = self.0.clone();
        segments.push(name.to_owned());
        Self(segments)
    }

    pub(crate) fn parent(&self) -> Option<Self> {
        (!self.0.is_empty()).then(|| Self(self.0[..self.0.len() - 1].to_vec()))
    }

    pub(crate) fn is_descendant_of(&self, ancestor: &Self) -> bool {
        self.0.starts_with(&ancestor.0)
    }
}

impl From<&FileModulePath> for ModuleRef {
    fn from(path: &FileModulePath) -> Self {
        Self(path.0.clone())
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
    LanguageTrait,
    LanguageEffect,
    LanguageConstructor,
    InherentImpl,
    TraitImpl,
    Closure,
    Handler,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) enum DeclarationOrigin {
    Language,
    Source(ModuleRef),
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
    pub(crate) origin: DeclarationOrigin,
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
    pub(crate) origin: SourceRef,
    pub(crate) span: Span,
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
    pub(crate) type_parameters: Vec<ResolvedTypeParameter>,
    pub(crate) parameters: Vec<ResolvedParameter>,
    pub(crate) return_type: Option<ResolvedType>,
    pub(crate) effects: Option<ResolvedEffectSet>,
    pub(crate) body: ResolvedBlock,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedFunctionSignature {
    pub(crate) identity: EntityId,
    pub(crate) type_parameters: Vec<ResolvedTypeParameter>,
    pub(crate) parameters: Vec<ResolvedParameter>,
    pub(crate) return_type: Option<ResolvedType>,
    pub(crate) effects: Option<ResolvedEffectSet>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedParameter {
    pub(crate) span: Span,
    pub(crate) binding: ResolvedBinding,
    pub(crate) mode: Option<(Span, ParameterMode)>,
    pub(crate) annotation: Option<ResolvedType>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedTypeParameter {
    pub(crate) span: Span,
    pub(crate) binding: ResolvedBinding,
    pub(crate) bounds: Vec<ResolvedNamedType>,
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
    Function {
        parameters: Vec<ResolvedFunctionTypeParameter>,
        return_type: Box<ResolvedType>,
        effects: Option<ResolvedEffectSet>,
    },
    Tuple(Vec<ResolvedType>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedFunctionTypeParameter {
    pub(crate) span: Span,
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
        mode: (Span, ParameterMode),
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
    Binding(ResolvedBinding),
    Constructor {
        target: ResolvedReference,
        fields: Option<ResolvedPatternFields>,
    },
    Tuple(Vec<ResolvedPattern>),
    Or(Vec<ResolvedPattern>),
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
    pub(crate) return_type: Option<ResolvedType>,
    pub(crate) effects: Option<ResolvedEffectSet>,
    pub(crate) body: ResolvedBlock,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResolvedCapture {
    pub(crate) span: Span,
    pub(crate) mode: Option<(Span, ParameterMode)>,
    pub(crate) reference: ResolvedReference,
    pub(crate) annotation: Option<ResolvedType>,
}
