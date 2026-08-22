// Ring-lang AST node definitions
// Transliterated from compiler/src/ast/index.ts

// ============================================================
// Span
// ============================================================

pub struct Position {
    pub line: Int,
    pub column: Int,
    pub offset: Int
}

pub struct Span {
    pub file: Str,
    pub start: Position,
    pub end: Position
}

pub fn span_zero() -> Span {
    Span {
        file: "<unknown>",
        start: Position { line: 1, column: 0, offset: 0 },
        end: Position { line: 1, column: 0, offset: 0 }
    }
}

// An explicit derive request retains the source attribute range.  Derive-time
// diagnostics are emitted after registration, so the declaration's ordinary
// span alone is not precise enough to identify the opt-in that failed.
pub struct DeriveAttribute {
    pub trait_name: Str,
    pub span: Span
}

// ============================================================
// Type Expressions (syntactic — before type inference)
// ============================================================

pub struct RecordTypeField {
    pub name: Str,
    pub ty: TypeExpr,
    pub span: Span
}

pub enum TypeExpr {
    Named { name: Str, qualifier: Str?, type_args: List<TypeExpr>, span: Span },
    FnType { params: List<TypeExpr>, return_type: TypeExpr, effects: List<EffectExpr>, span: Span },
    OptionType { inner: TypeExpr, span: Span },
    RecordType { fields: List<RecordTypeField>, rest: Str?, span: Span },
    TupleType { elements: List<TypeExpr>, span: Span }
}

// ============================================================
// Effect Expressions (syntactic — for effect annotations)
// ============================================================

pub struct EffectExpr {
    pub name: Str,
    pub type_args: List<TypeExpr>,
    pub span: Span
}

// ============================================================
// Literal values
// ============================================================

pub enum LiteralValue {
    IntVal(Int),
    FloatVal(Float),
    StrVal(Str),
    BoolVal(Bool)
}

// ============================================================
// Patterns
// ============================================================

pub struct NamedPatternField {
    pub name: Str,
    pub pattern: Pattern,
    pub span: Span
}

pub enum Pattern {
    Wildcard { span: Span },
    Binding { name: Str, span: Span },
    Constructor { name: Str, qualifier: Str?, fields: List<Pattern>, span: Span },
    NamedConstructor { name: Str, qualifier: Str?, fields: List<NamedPatternField>, rest: Bool, span: Span },
    Literal { value: LiteralValue, span: Span },
    TuplePattern { elements: List<Pattern>, span: Span },
    OrPattern { patterns: List<Pattern>, span: Span }
}

// ============================================================
// Operators
// ============================================================

pub enum BinOp {
    Add, Sub, Mul, Div, Mod,
    Eq, Neq, Lt, Lte, Gt, Gte,
    And, Or
}

pub enum UnaryOp { Neg, Not }

// ============================================================
// Shared sub-structures
// ============================================================

pub struct Param {
    pub name: Str,
    pub is_mutable: Bool,
    pub type_annotation: TypeExpr?,
    pub span: Span
}

pub struct MatchArm {
    pub pattern: Pattern,
    pub guard: Expr?,
    pub body: Expr,
    pub span: Span
}

pub struct StructFieldInit {
    pub name: Str,
    pub value: Expr,
    pub span: Span
}

pub struct EffectHandler {
    pub effect_name: Str,
    pub op_name: Str,
    pub params: List<Param>,
    pub resume_name: Str?,
    pub body: Expr,
    pub span: Span
}

pub enum StringInterpPart {
    LitPart(Str),
    ExprPart(Expr)
}

// ============================================================
// Expressions
// ============================================================

pub enum Expr {
    IntLit { value: Int, span: Span },
    FloatLit { value: Float, span: Span },
    StrLit { value: Str, span: Span },
    BoolLit { value: Bool, span: Span },
    Ident { name: Str, qualifier: Str?, span: Span },
    BinOp { op: BinOp, left: Expr, right: Expr, span: Span },
    UnaryOp { op: UnaryOp, operand: Expr, span: Span },
    Call { callee: Expr, args: List<Expr>, type_args: List<TypeExpr>, span: Span },
    MethodCall { receiver: Expr, method: Str, args: List<Expr>, type_args: List<TypeExpr>, span: Span },
    FieldAccess { receiver: Expr, field: Str, span: Span },
    StructLit { name: Str, qualifier: Str?, type_args: List<TypeExpr>, fields: List<StructFieldInit>, spread: Expr?, span: Span },
    MatchExpr { scrutinee: Expr, arms: List<MatchArm>, span: Span },
    Block { stmts: List<Stmt>, tail: Expr?, span: Span },
    IfExpr { condition: Expr, then_branch: Expr, else_branch: Expr?, span: Span },
    StringInterp { parts: List<StringInterpPart>, span: Span },
    CatchExpr { expr: Expr, arms: List<MatchArm>, span: Span },
    HandleExpr { body: Expr, handlers: List<EffectHandler>, span: Span },
    Lambda { params: List<Param>, return_type: TypeExpr?, body: Expr, span: Span },
    Range { start: Expr, end: Expr, inclusive: Bool, span: Span },
    ListLit { elements: List<Expr>, span: Span },
    TupleLit { elements: List<Expr>, span: Span },
    IndexExpr { receiver: Expr, index: Expr, span: Span },
    ReturnExpr { value: Expr?, span: Span },
    UnsafeBlock { body: Expr, span: Span }
}

// ============================================================
// Statements
// ============================================================

pub struct DestructureBinding {
    pub names: List<Str>,
    pub spans: List<Span>
}

pub enum Stmt {
    Let { name: Str, name_span: Span, type_annotation: TypeExpr?, init: Expr, span: Span },
    Var { name: Str, name_span: Span, type_annotation: TypeExpr?, init: Expr, span: Span },
    Assign { target: Expr, value: Expr, span: Span },
    ExprStmt { expr: Expr, has_semi: Bool, span: Span },
    Return { value: Expr?, span: Span },
    While { condition: Expr, body: Expr, span: Span },
    ForIn { binding: Str, binding_span: Span, destructure: DestructureBinding?, iterable: Expr, body: Expr, span: Span },
    Break { span: Span },
    Continue { span: Span },
    LetDestructure { pattern: Pattern, init: Expr, span: Span },
    IfLet { pattern: Pattern, expr: Expr, then_block: Expr, else_block: Expr?, span: Span }
}

// ============================================================
// Use declarations (imports)
// ============================================================

pub struct UsePath {
    pub segments: List<Str>,
    pub span: Span
}

pub struct NamedImport {
    pub name: Str,
    pub alias: Str?,
    pub span: Span
}

pub enum UseImport {
    NamedItems { names: List<NamedImport> },
    Module
}

pub struct UseDecl {
    pub path: UsePath,
    pub imports: UseImport,
    pub alias: Str?,
    pub is_pub: Bool,
    pub span: Span
}

// ============================================================
// Declarations
// ============================================================

pub struct AssocConstraint {
    pub name: Str,       // "Item"
    pub ty: TypeExpr,    // Int
    pub span: Span
}

pub struct TypeBound {
    pub trait_name: Str,
    pub type_args: List<TypeExpr>,
    pub assoc_constraints: List<AssocConstraint>,
    pub span: Span
}

pub struct TypeParam {
    pub name: Str,
    pub bounds: List<TypeBound>,
    pub span: Span
}

pub struct StructFieldDecl {
    pub name: Str,
    pub type_annotation: TypeExpr,
    pub is_pub: Bool,
    pub span: Span
}

pub struct NamedEnumField {
    pub name: Str,
    pub type_expr: TypeExpr,
    pub span: Span
}

pub struct EnumVariantDecl {
    pub name: Str,
    pub fields: List<TypeExpr>,
    pub named_fields: List<NamedEnumField>?,
    pub span: Span
}

pub struct EffectOpDecl {
    pub name: Str,
    pub params: List<Param>,
    pub return_type: TypeExpr,
    pub body: Expr?,
    pub span: Span
}

pub enum Decl {
    Fn { name: Str, type_params: List<TypeParam>, params: List<Param>, return_type: TypeExpr?, declared_effects: List<EffectExpr>?, body: Expr, is_pub: Bool, is_abstract: Bool, span: Span },
    Struct { name: Str, type_params: List<TypeParam>, fields: List<StructFieldDecl>, derive_attrs: List<DeriveAttribute>, is_pub: Bool, span: Span },
    Enum { name: Str, type_params: List<TypeParam>, variants: List<EnumVariantDecl>, derive_attrs: List<DeriveAttribute>, is_pub: Bool, span: Span },
    Impl { target_type: Str, type_params: List<TypeParam>, trait_name: Str?, methods: List<Decl>, span: Span },
    Effect { name: Str, type_params: List<TypeParam>, ops: List<EffectOpDecl>, is_pub: Bool, span: Span },
    Test { description: Str, body: Expr, span: Span },
    Trait { name: Str, type_params: List<TypeParam>, supertraits: List<TypeBound>, methods: List<Decl>, is_pub: Bool, span: Span },
    ExternFn { name: Str, type_params: List<TypeParam>, params: List<Param>, return_type: TypeExpr?, declared_effects: List<EffectExpr>?, is_pub: Bool, span: Span },
    ExternType { name: Str, type_params: List<TypeParam>, is_pub: Bool, span: Span },
    TypeAlias { name: Str, type_params: List<TypeParam>, type_expr: TypeExpr, is_pub: Bool, span: Span },
    Const { name: Str, type_annotation: TypeExpr?, init: Expr, is_pub: Bool, span: Span },
    ModBlock { name: Str, uses: List<UseDecl>, decls: List<Decl>, required_effects: List<EffectExpr>?, is_pub: Bool, span: Span },
    EffectAlias { name: Str, type_params: List<TypeParam>, effects: List<EffectExpr>, is_pub: Bool, span: Span },
    Delegate { field: Str, trait_names: List<Str>, span: Span },
    AssocType { name: Str, bounds: List<TypeBound>, value: TypeExpr?, is_pub: Bool, span: Span }
}

// ============================================================
// Program (top-level)
// ============================================================

pub struct Program {
    pub uses: List<UseDecl>,
    pub decls: List<Decl>,
    pub span: Span
}
