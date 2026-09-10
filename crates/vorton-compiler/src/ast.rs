//! Public typed surface AST for canonical Vorton 0.1.

/// A UTF-8 byte half-open interval in the source passed to [`crate::parse`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

impl Span {
    pub(crate) const fn new(start: usize, end: usize) -> Self {
        Self { start, end }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Spanned<T> {
    pub span: Span,
    pub kind: T,
}

impl<T> Spanned<T> {
    pub(crate) const fn new(kind: T, span: Span) -> Self {
        Self { span, kind }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identifier {
    pub text: String,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PathSegment {
    Identifier(Identifier),
    Super(Span),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Path {
    pub span: Span,
    pub segments: Vec<PathSegment>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Visibility {
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Program {
    pub span: Span,
    pub requires: Option<FileRequires>,
    pub uses: Vec<UseDeclaration>,
    pub items: Vec<ModuleItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRequires {
    pub span: Span,
    pub effects: EffectSet,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UseDeclaration {
    pub span: Span,
    pub visibility: Option<Visibility>,
    pub path: Path,
    pub suffix: Option<UseSuffix>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UseSuffix {
    Alias(Identifier),
    Items { span: Span, items: Vec<UseItem> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UseItem {
    pub span: Span,
    pub name: Identifier,
    pub alias: Option<Identifier>,
}

pub type Declaration = Spanned<DeclarationKind>;

/// A root or inline-module item in original source order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModuleItem {
    Declaration(Box<Declaration>),
    Generate(GenerateItem),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenerateItem {
    pub span: Span,
    pub keyword_span: Span,
    pub context: Identifier,
    pub body: Block,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Declared<T> {
    pub visibility: Option<Visibility>,
    pub item: T,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeclarationKind {
    Function(Declared<FunctionDeclaration>),
    Struct(Declared<StructDeclaration>),
    Enum(Declared<EnumDeclaration>),
    InherentImpl(InherentImplDeclaration),
    TraitImpl(TraitImplDeclaration),
    Trait(Declared<TraitDeclaration>),
    Effect(Declared<EffectDeclaration>),
    EffectAlias(Declared<EffectAliasDeclaration>),
    Extern(Declared<ExternDeclaration>),
    TypeAlias(Declared<TypeAliasDeclaration>),
    Const(Declared<ConstDeclaration>),
    Module(Declared<ModuleDeclaration>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FunctionDeclaration {
    pub const_span: Option<Span>,
    pub name: Identifier,
    pub type_parameters: Vec<TypeParameter>,
    pub effect_parameters: Vec<EffectParameter>,
    pub parameters: Vec<NamedParameter>,
    pub return_type: Option<Box<ReturnAnnotation>>,
    pub effects: Option<EffectSet>,
    pub body: Block,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FunctionSignature {
    pub name: Identifier,
    pub type_parameters: Vec<TypeParameter>,
    pub effect_parameters: Vec<EffectParameter>,
    pub parameters: Vec<NamedParameter>,
    pub return_type: Option<TypeExpr>,
    pub effects: Option<EffectSet>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NamedParameter {
    pub span: Span,
    pub name: Identifier,
    pub annotation: Option<ParameterType>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParameterType {
    pub span: Span,
    pub escape: Option<EscapeQualifier>,
    pub mode: Option<Spanned<ParameterMode>>,
    pub kind: ParameterTypeKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParameterMode {
    /// A fixed `&T` parameter mode.
    Borrow,
    /// A fixed `&mut T` parameter mode.
    MutBorrow,
    /// A fixed `move T` parameter mode.
    Move,
    /// A `call F` source selection resolved to a fixed mode by the checker.
    Call,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EscapeQualifier {
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParameterTypeKind {
    Type(TypeExpr),
    Shape(ShapeExpr),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReturnAnnotation {
    Type(TypeExpr),
    Shape(ShapeExpr),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StructDeclaration {
    pub name: Identifier,
    pub type_parameters: Vec<TypeParameter>,
    pub fields: Vec<StructField>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StructField {
    pub span: Span,
    pub visibility: Option<Visibility>,
    pub name: Identifier,
    pub ty: TypeExpr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnumDeclaration {
    pub name: Identifier,
    pub type_parameters: Vec<TypeParameter>,
    pub variants: Vec<EnumVariant>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnumVariant {
    pub span: Span,
    pub name: Identifier,
    pub fields: VariantFields,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VariantFields {
    Unit,
    Positional(Vec<TypeExpr>),
    Named(Vec<NamedField>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NamedField {
    pub span: Span,
    pub name: Identifier,
    pub ty: TypeExpr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InherentImplDeclaration {
    pub type_parameters: Vec<TypeParameter>,
    pub target: NamedType,
    pub members: Vec<ImplMember>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraitImplDeclaration {
    pub type_parameters: Vec<TypeParameter>,
    pub trait_type: NamedType,
    pub target: NamedType,
    pub where_clause: Option<WhereClause>,
    pub members: Vec<ImplMember>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WhereClause {
    pub span: Span,
    pub keyword_span: Span,
    pub predicates: Vec<WherePredicate>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WherePredicate {
    pub span: Span,
    pub subject: TypeExpr,
    pub bounds: Vec<NamedType>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImplMember {
    pub span: Span,
    pub visibility: Option<Visibility>,
    pub kind: ImplMemberKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImplMemberKind {
    Function(FunctionDeclaration),
    AssociatedType(AssociatedTypeValue),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssociatedTypeValue {
    pub name: Identifier,
    pub value: TypeExpr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraitDeclaration {
    pub name: Identifier,
    pub type_parameters: Vec<TypeParameter>,
    pub supertraits: Vec<NamedType>,
    pub members: Vec<TraitMember>,
}

pub type TraitMember = Spanned<TraitMemberKind>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TraitMemberKind {
    Method(FunctionSignature),
    AssociatedType(TraitAssociatedType),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraitAssociatedType {
    pub name: Identifier,
    pub bounds: Vec<NamedType>,
    pub default: Option<TypeExpr>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EffectDeclaration {
    pub name: Identifier,
    pub type_parameters: Vec<TypeParameter>,
    pub operations: Vec<EffectOperation>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EffectOperation {
    pub span: Span,
    pub name: Identifier,
    pub parameters: Vec<NamedParameter>,
    pub return_type: TypeExpr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EffectAliasDeclaration {
    pub name: Identifier,
    pub type_parameters: Vec<TypeParameter>,
    pub effects: EffectSet,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExternDeclaration {
    Function(FunctionSignature),
    Type {
        name: Identifier,
        type_parameters: Vec<TypeParameter>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TypeAliasDeclaration {
    pub name: Identifier,
    pub type_parameters: Vec<TypeParameter>,
    pub value: TypeExpr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConstDeclaration {
    pub name: Identifier,
    pub annotation: Option<TypeExpr>,
    pub value: Expr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleDeclaration {
    pub name: Identifier,
    pub requires: Option<EffectSet>,
    pub uses: Vec<UseDeclaration>,
    pub items: Vec<ModuleItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TypeParameter {
    pub span: Span,
    pub name: Identifier,
    pub bounds: Vec<GenericBound>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GenericBound {
    Named(NamedType),
    Shape(ShapeExpr),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EffectParameter {
    pub span: Span,
    pub name: Identifier,
}

pub type NamedType = Spanned<NamedTypeKind>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NamedTypeKind {
    pub path: Path,
    pub arguments: Vec<TypeArgument>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TypeArgument {
    Type(TypeExpr),
    AssociatedType {
        span: Span,
        name: Identifier,
        value: TypeExpr,
    },
}

pub type TypeExpr = Spanned<TypeKind>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TypeKind {
    Named(NamedTypeKind),
    Grouped(Box<TypeExpr>),
    Tuple(Vec<TypeExpr>),
}

/// A direct constraint on an actual callable type, not a storage type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CallableShape {
    pub parameters: Vec<ShapeParameter>,
    pub return_type: TypeExpr,
    pub effects: Option<EffectSet>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShapeParameter {
    pub span: Span,
    pub escape: Option<EscapeQualifier>,
    pub mode: Option<Spanned<ParameterMode>>,
    pub ty: TypeExpr,
}

pub type ShapeExpr = Spanned<ShapeKind>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShapeKind {
    Callable(CallableShape),
    Grouped(Box<ShapeExpr>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EffectSet {
    pub span: Span,
    pub effects: Vec<EffectExpr>,
}

pub type EffectExpr = Spanned<EffectKind>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EffectKind {
    Named {
        path: Path,
        arguments: Vec<TypeExpr>,
        effect_arguments: Vec<EffectRowArgument>,
    },
    Mutation,
    Unsafe,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EffectRowArgument {
    pub span: Span,
    pub effects: EffectSet,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Block {
    pub span: Span,
    pub statements: Vec<Statement>,
    pub tail: Option<Box<Expr>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Statement {
    pub span: Span,
    pub kind: StatementKind,
    pub terminator: StatementTerminator,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StatementTerminator {
    Explicit(Span),
    Implicit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StatementKind {
    Let {
        binding: LetBinding,
        value: Expr,
    },
    Return(Option<Expr>),
    Break,
    Continue,
    Assignment {
        target: PlaceExpr,
        operator: Spanned<AssignmentOperator>,
        value: Expr,
    },
    Expression(Expr),
    IfLet {
        pattern: Pattern,
        value: Expr,
        then_branch: Block,
        else_branch: Option<Block>,
    },
    While {
        condition: Expr,
        body: Block,
    },
    For {
        binding: ForBinding,
        iterable: Expr,
        body: Block,
    },
    Loop(Block),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LetBinding {
    Name {
        name: Identifier,
        mutable: Option<Span>,
        annotation: Option<TypeExpr>,
    },
    Tuple(Pattern),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ForBinding {
    Name(Identifier),
    Tuple { span: Span, names: Vec<Identifier> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaceExpr {
    pub span: Span,
    pub root: Identifier,
    pub fields: Vec<Identifier>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssignmentOperator {
    Assign,
    AddAssign,
    SubtractAssign,
    MultiplyAssign,
    DivideAssign,
    RemainderAssign,
}

pub type Expr = Spanned<ExprKind>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExprKind {
    Integer(String),
    Float(String),
    String(String),
    RawString {
        value: String,
        delimiter: RawStringDelimiter,
    },
    InterpolatedString(Vec<InterpolationPart>),
    Boolean(bool),
    Path(Path),
    NamedConstruct {
        path: Path,
        entries: Vec<ConstructEntry>,
    },
    List(Vec<Expr>),
    Unit,
    Parenthesized(Box<Expr>),
    Tuple(Vec<Expr>),
    Block(Block),
    If {
        condition: Box<Expr>,
        then_branch: Block,
        else_branch: Option<Box<Expr>>,
    },
    Match {
        scrutinee: Box<Expr>,
        arms: Vec<MatchArm>,
    },
    Handle {
        body: Block,
        handlers: Vec<Handler>,
    },
    Closure(ClosureExpression),
    Unsafe(Block),
    Catch {
        expression: Box<Expr>,
        arms: Vec<MatchArm>,
    },
    Unary {
        operator: Spanned<UnaryOperator>,
        operand: Box<Expr>,
    },
    Binary {
        left: Box<Expr>,
        operator: Spanned<BinaryOperator>,
        right: Box<Expr>,
    },
    Propagate(Box<Expr>),
    Call {
        callee: Box<Expr>,
        arguments: Vec<CallArgument>,
    },
    Index {
        receiver: Box<Expr>,
        index: Box<Expr>,
    },
    TupleField {
        receiver: Box<Expr>,
        index: StringValue,
    },
    Field {
        receiver: Box<Expr>,
        name: Identifier,
    },
    MethodCall {
        receiver: Box<Expr>,
        method: Identifier,
        arguments: Vec<CallArgument>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RawStringDelimiter {
    Quote,
    HashQuote,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InterpolationPart {
    String(StringValue),
    Expression(Box<Expr>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StringValue {
    pub span: Span,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConstructEntry {
    pub span: Span,
    pub kind: ConstructEntryKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConstructEntryKind {
    Spread(Expr),
    Field {
        name: Identifier,
        value: Option<Expr>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CallArgument {
    Expression(Expr),
    Mode {
        span: Span,
        mode: Spanned<CallAssertionMode>,
        place: PlaceExpr,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallAssertionMode {
    Mut,
    Move,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnaryOperator {
    Negate,
    Not,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinaryOperator {
    LogicOr,
    LogicAnd,
    Equal,
    NotEqual,
    Less,
    Greater,
    LessEqual,
    GreaterEqual,
    RangeExclusive,
    RangeInclusive,
    Add,
    Subtract,
    Multiply,
    Divide,
    Remainder,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MatchArm {
    pub span: Span,
    pub pattern: OrPattern,
    pub guard: Option<Expr>,
    pub body: Expr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OrPattern {
    pub span: Span,
    pub alternatives: Vec<Pattern>,
}

pub type Pattern = Spanned<PatternKind>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PatternKind {
    Wildcard,
    Integer(String),
    Float(String),
    String(String),
    Boolean(bool),
    Path {
        path: Path,
        fields: Option<PatternFields>,
    },
    QualifiedBinding(QualifiedBinding),
    Tuple(Vec<Pattern>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QualifiedBinding {
    pub name: Identifier,
    pub mode: Spanned<BindingMode>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BindingMode {
    Mut,
    Move,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PatternFields {
    Positional(Vec<Pattern>),
    Named {
        fields: Vec<NamedPatternField>,
        rest: Option<Span>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NamedPatternField {
    pub span: Span,
    pub name: Identifier,
    pub pattern: Option<Pattern>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Handler {
    pub span: Span,
    pub effect: Path,
    pub operation: Identifier,
    pub parameters: Vec<NamedParameter>,
    pub body: Expr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClosureExpression {
    pub captures: Option<CaptureList>,
    pub parameters: Vec<NamedParameter>,
    pub return_type: Option<Box<ReturnAnnotation>>,
    pub effects: Option<EffectSet>,
    pub body: Block,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaptureList {
    pub span: Span,
    pub captures: Vec<CaptureParameter>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaptureParameter {
    pub span: Span,
    pub mode: Option<Spanned<CaptureMode>>,
    pub name: Identifier,
    pub annotation: Option<TypeExpr>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureMode {
    Mut,
    Move,
}
