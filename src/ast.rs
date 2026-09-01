use serde::Serialize;

use crate::source::{SourceId, Span};

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Name {
    pub text: String,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Path {
    pub segments: Vec<Name>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Visibility {
    pub public: bool,
    pub span: Option<Span>,
}

impl Visibility {
    pub fn private() -> Self {
        Self {
            public: false,
            span: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Program {
    pub source: SourceId,
    pub uses: Vec<UseDecl>,
    pub declarations: Vec<Decl>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct UseDecl {
    pub visibility: Visibility,
    pub path: Path,
    pub kind: UseKind,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum UseKind {
    Bare,
    PathAlias(Name),
    NamedItems(Vec<UseItem>),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct UseItem {
    pub name: Name,
    pub alias: Option<Name>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum Decl {
    Function(FunctionDecl),
    Struct(StructDecl),
    Enum(EnumDecl),
    Trait(TraitDecl),
    Impl(ImplDecl),
    Effect(EffectDecl),
    EffectAlias(EffectAliasDecl),
    ExternFunction(ExternFunctionDecl),
    ExternType(ExternTypeDecl),
    TypeAlias(TypeAliasDecl),
    Test(TestDecl),
    Const(ConstDecl),
    Module(ModuleDecl),
}

impl Decl {
    pub fn span(&self) -> Span {
        match self {
            Self::Function(value) => value.span,
            Self::Struct(value) => value.span,
            Self::Enum(value) => value.span,
            Self::Trait(value) => value.span,
            Self::Impl(value) => value.span,
            Self::Effect(value) => value.span,
            Self::EffectAlias(value) => value.span,
            Self::ExternFunction(value) => value.span,
            Self::ExternType(value) => value.span,
            Self::TypeAlias(value) => value.span,
            Self::Test(value) => value.span,
            Self::Const(value) => value.span,
            Self::Module(value) => value.span,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct FunctionDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub type_params: Vec<TypeParam>,
    pub params: Vec<Param>,
    pub return_type: Option<TypeExpr>,
    pub effects: Option<EffectSet>,
    pub body: Expr,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct StructDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub type_params: Vec<TypeParam>,
    pub fields: Vec<StructField>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct StructField {
    pub visibility: Visibility,
    pub name: Name,
    pub ty: TypeExpr,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct EnumDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub type_params: Vec<TypeParam>,
    pub variants: Vec<EnumVariant>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct EnumVariant {
    pub name: Name,
    pub fields: VariantFields,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum VariantFields {
    Unit,
    Positional(Vec<TypeExpr>),
    Named(Vec<NamedTypeField>),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct NamedTypeField {
    pub name: Name,
    pub ty: TypeExpr,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct TraitDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub type_params: Vec<TypeParam>,
    pub supertraits: Vec<TypeBound>,
    pub members: Vec<TraitMember>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum TraitMember {
    Method(FunctionSignature),
    AssociatedType(AssociatedTypeDecl),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct FunctionSignature {
    pub name: Name,
    pub type_params: Vec<TypeParam>,
    pub params: Vec<Param>,
    pub return_type: Option<TypeExpr>,
    pub effects: Option<EffectSet>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct AssociatedTypeDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub bounds: Vec<TypeBound>,
    pub value: Option<TypeExpr>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ImplDecl {
    pub type_params: Vec<TypeParam>,
    pub kind: ImplKind,
    pub members: Vec<ImplMember>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum ImplKind {
    Inherent {
        target: TypeExpr,
    },
    Trait {
        trait_path: TypeExpr,
        target: TypeExpr,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum ImplMember {
    Method(FunctionDecl),
    AssociatedType(AssociatedTypeDecl),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct EffectDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub type_params: Vec<TypeParam>,
    pub operations: Vec<EffectOperation>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct EffectOperation {
    pub name: Name,
    pub params: Vec<Param>,
    pub return_type: TypeExpr,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct EffectAliasDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub type_params: Vec<TypeParam>,
    pub effects: EffectSet,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ExternFunctionDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub type_params: Vec<TypeParam>,
    pub params: Vec<Param>,
    pub return_type: Option<TypeExpr>,
    pub effects: Option<EffectSet>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ExternTypeDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub type_params: Vec<TypeParam>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct TypeAliasDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub type_params: Vec<TypeParam>,
    pub ty: TypeExpr,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct TestDecl {
    pub visibility: Visibility,
    pub description: String,
    pub description_span: Span,
    pub body: Expr,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ConstDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub type_annotation: Option<TypeExpr>,
    pub value: Expr,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ModuleDecl {
    pub visibility: Visibility,
    pub name: Name,
    pub requires: Option<EffectSet>,
    pub uses: Vec<UseDecl>,
    pub declarations: Vec<Decl>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct TypeParam {
    pub name: Name,
    pub bounds: Vec<TypeBound>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct TypeBound {
    pub path: Path,
    pub type_args: Vec<TypeExpr>,
    pub associated: Vec<AssociatedConstraint>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct AssociatedConstraint {
    pub name: Name,
    pub ty: TypeExpr,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Param {
    pub mutable: bool,
    pub name: Name,
    pub type_annotation: Option<TypeExpr>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum TypeExpr {
    Named {
        path: Path,
        type_args: Vec<TypeExpr>,
        span: Span,
    },
    Function {
        params: Vec<TypeExpr>,
        return_type: Box<TypeExpr>,
        effects: Option<EffectSet>,
        span: Span,
    },
    Tuple {
        elements: Vec<TypeExpr>,
        span: Span,
    },
    Parenthesized {
        inner: Box<TypeExpr>,
        span: Span,
    },
    Record {
        fields: Vec<NamedTypeField>,
        rest: Option<Name>,
        span: Span,
    },
}

impl TypeExpr {
    pub fn span(&self) -> Span {
        match self {
            Self::Named { span, .. }
            | Self::Function { span, .. }
            | Self::Tuple { span, .. }
            | Self::Parenthesized { span, .. }
            | Self::Record { span, .. } => *span,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct EffectSet {
    pub effects: Vec<EffectExpr>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct EffectExpr {
    pub name: EffectName,
    pub type_args: Vec<TypeExpr>,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum EffectName {
    Path(Path),
    Mutation(Name),
    Unsafe(Name),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum Stmt {
    Let {
        mutable: bool,
        pattern: Pattern,
        type_annotation: Option<TypeExpr>,
        value: Expr,
        span: Span,
    },
    IfLet {
        pattern: Pattern,
        value: Expr,
        then_block: Expr,
        else_block: Option<Expr>,
        span: Span,
    },
    Return {
        value: Option<Expr>,
        span: Span,
    },
    While {
        condition: Expr,
        body: Expr,
        span: Span,
    },
    Loop {
        body: Expr,
        span: Span,
    },
    For {
        binding: ForBinding,
        iterable: Expr,
        body: Expr,
        span: Span,
    },
    Break {
        span: Span,
    },
    Continue {
        span: Span,
    },
    Assign {
        target: Expr,
        op: AssignOp,
        value: Expr,
        span: Span,
    },
    Expression {
        expression: Expr,
        has_semicolon: bool,
        span: Span,
    },
}

impl Stmt {
    pub fn span(&self) -> Span {
        match self {
            Self::Let { span, .. }
            | Self::IfLet { span, .. }
            | Self::Return { span, .. }
            | Self::While { span, .. }
            | Self::Loop { span, .. }
            | Self::For { span, .. }
            | Self::Break { span }
            | Self::Continue { span }
            | Self::Assign { span, .. }
            | Self::Expression { span, .. } => *span,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum ForBinding {
    Name(Name),
    Tuple(Vec<Name>, Span),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum AssignOp {
    Assign,
    AddAssign,
    SubtractAssign,
    MultiplyAssign,
    DivideAssign,
    RemainderAssign,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum Expr {
    Integer {
        lexeme: String,
        span: Span,
    },
    Float {
        lexeme: String,
        span: Span,
    },
    String {
        value: String,
        span: Span,
    },
    RawString {
        value: String,
        span: Span,
    },
    InterpolatedString {
        parts: Vec<StringPart>,
        span: Span,
    },
    Boolean {
        value: bool,
        span: Span,
    },
    Path {
        path: Path,
        span: Span,
    },
    Unary {
        op: UnaryOp,
        operand: Box<Expr>,
        span: Span,
    },
    Binary {
        op: BinaryOp,
        left: Box<Expr>,
        right: Box<Expr>,
        span: Span,
    },
    Range {
        start: Box<Expr>,
        end: Box<Expr>,
        inclusive: bool,
        span: Span,
    },
    Call {
        callee: Box<Expr>,
        args: Vec<Expr>,
        span: Span,
    },
    MethodCall {
        receiver: Box<Expr>,
        method: Name,
        args: Vec<Expr>,
        span: Span,
    },
    FieldAccess {
        receiver: Box<Expr>,
        field: Name,
        span: Span,
    },
    TupleFieldAccess {
        receiver: Box<Expr>,
        index: String,
        index_span: Span,
        span: Span,
    },
    Index {
        receiver: Box<Expr>,
        index: Box<Expr>,
        span: Span,
    },
    NamedLiteral {
        path: Path,
        spread: Option<Box<Expr>>,
        fields: Vec<FieldInit>,
        span: Span,
    },
    List {
        elements: Vec<Expr>,
        span: Span,
    },
    Tuple {
        elements: Vec<Expr>,
        span: Span,
    },
    Unit {
        span: Span,
    },
    Parenthesized {
        inner: Box<Expr>,
        span: Span,
    },
    Block {
        statements: Vec<Stmt>,
        tail: Option<Box<Expr>>,
        span: Span,
    },
    If {
        condition: Box<Expr>,
        then_branch: Box<Expr>,
        else_branch: Option<Box<Expr>>,
        span: Span,
    },
    Match {
        scrutinee: Box<Expr>,
        arms: Vec<MatchArm>,
        span: Span,
    },
    Handle {
        body: Box<Expr>,
        handlers: Vec<EffectHandler>,
        span: Span,
    },
    Lambda {
        params: Vec<Param>,
        return_type: Option<TypeExpr>,
        body: Box<Expr>,
        span: Span,
    },
    Catch {
        expression: Box<Expr>,
        arms: Vec<MatchArm>,
        span: Span,
    },
    Unsafe {
        body: Box<Expr>,
        span: Span,
    },
    Return {
        value: Option<Box<Expr>>,
        span: Span,
    },
}

impl Expr {
    pub fn span(&self) -> Span {
        match self {
            Self::Integer { span, .. }
            | Self::Float { span, .. }
            | Self::String { span, .. }
            | Self::RawString { span, .. }
            | Self::InterpolatedString { span, .. }
            | Self::Boolean { span, .. }
            | Self::Path { span, .. }
            | Self::Unary { span, .. }
            | Self::Binary { span, .. }
            | Self::Range { span, .. }
            | Self::Call { span, .. }
            | Self::MethodCall { span, .. }
            | Self::FieldAccess { span, .. }
            | Self::TupleFieldAccess { span, .. }
            | Self::Index { span, .. }
            | Self::NamedLiteral { span, .. }
            | Self::List { span, .. }
            | Self::Tuple { span, .. }
            | Self::Unit { span }
            | Self::Parenthesized { span, .. }
            | Self::Block { span, .. }
            | Self::If { span, .. }
            | Self::Match { span, .. }
            | Self::Handle { span, .. }
            | Self::Lambda { span, .. }
            | Self::Catch { span, .. }
            | Self::Unsafe { span, .. }
            | Self::Return { span, .. } => *span,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum StringPart {
    Text { value: String, span: Span },
    Expression(Expr),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct FieldInit {
    pub name: Name,
    pub value: Expr,
    pub shorthand: bool,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct MatchArm {
    pub pattern: Pattern,
    pub guard: Option<Expr>,
    pub body: Expr,
    pub span: Span,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct EffectHandler {
    pub effect: Path,
    pub operation: Name,
    pub params: Vec<Param>,
    pub body: Expr,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum UnaryOp {
    Negate,
    Not,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub enum BinaryOp {
    Add,
    Subtract,
    Multiply,
    Divide,
    Remainder,
    Equal,
    NotEqual,
    Less,
    LessEqual,
    Greater,
    GreaterEqual,
    And,
    Or,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum Pattern {
    Wildcard {
        span: Span,
    },
    Name {
        name: Name,
        span: Span,
    },
    Literal {
        literal: PatternLiteral,
        span: Span,
    },
    Constructor {
        path: Path,
        fields: Vec<Pattern>,
        span: Span,
    },
    NamedConstructor {
        path: Path,
        fields: Vec<NamedPatternField>,
        rest: Option<Span>,
        span: Span,
    },
    Tuple {
        elements: Vec<Pattern>,
        span: Span,
    },
    Or {
        alternatives: Vec<Pattern>,
        span: Span,
    },
}

impl Pattern {
    pub fn span(&self) -> Span {
        match self {
            Self::Wildcard { span }
            | Self::Name { span, .. }
            | Self::Literal { span, .. }
            | Self::Constructor { span, .. }
            | Self::NamedConstructor { span, .. }
            | Self::Tuple { span, .. }
            | Self::Or { span, .. } => *span,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub enum PatternLiteral {
    Integer(String),
    Float(String),
    String(String),
    Boolean(bool),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct NamedPatternField {
    pub name: Name,
    pub pattern: Pattern,
    pub shorthand: bool,
    pub span: Span,
}
