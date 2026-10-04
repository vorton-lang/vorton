//! The checked program: typed functions that the checker produces and
//! lowering turns into the IR.
//!
//! Types are resolved, names are local indices or function indices, and the
//! checker's decisions are explicit: where a borrow begins, which built-in
//! method or intrinsic runs, and which callee a call names. A local, or a
//! part of one, read for its value is moved or copied by its type, which
//! lowering decides where the value is used. What happens in what order,
//! and whether moves and borrows are valid, is the IR's business.

use crate::ast::{AssignmentOperator, BinaryOperator, BorrowKind, Span, UnaryOperator};
use std::collections::BTreeMap;

use crate::project::OriginRef;
use crate::types::{Type, Types};

/// A checked program: every function with its types resolved, before it is
/// lowered to the IR.
pub(crate) struct Program {
    pub(crate) types: Types,
    pub(crate) functions: Vec<Function>,
    /// Where each function is declared.
    pub(crate) origins: Vec<OriginRef>,
    /// Whether each function has type parameters.
    pub(crate) generic: Vec<bool>,
    /// The entry library's `main`.
    pub(crate) main: usize,
    pub(crate) impls: Impls,
    /// The core `Display` trait, which built-in types implement without an
    /// impl.
    pub(crate) display: usize,
}

/// The impl of each trait for each type: the function of each trait
/// method, in the trait's order.
pub(crate) type Impls = BTreeMap<(usize, Type), Vec<usize>>;
#[derive(Clone)]
pub(crate) struct Function {
    pub(crate) name: String,
    pub(crate) parameters: Vec<usize>,
    pub(crate) locals: Vec<Local>,
    pub(crate) result: Type,
    /// A borrowed result is a pointer to a place of type `result`.
    pub(crate) result_borrow: Option<BorrowKind>,
    pub(crate) body: Block,
}

#[derive(Clone)]
pub(crate) struct Local {
    pub(crate) name: String,
    pub(crate) ty: Type,
    /// A borrowed local holds a pointer to a place of type `ty`.
    pub(crate) borrow: Option<BorrowKind>,
}

#[derive(Clone)]
pub(crate) struct Block {
    pub(crate) statements: Vec<Statement>,
    pub(crate) tail: Option<Box<Expr>>,
    pub(crate) ty: Type,
}

#[derive(Clone)]
pub(crate) enum Statement {
    Let {
        local: usize,
        value: Expr,
    },
    /// An irrefutable destructuring `let`.
    LetPattern {
        pattern: Pattern,
        value: Expr,
    },
    Assign {
        place: Place,
        operator: AssignmentOperator,
        value: Expr,
    },
    Expr(Expr),
    Return(Option<Expr>),
    Break,
    Continue,
    While {
        condition: Expr,
        body: Block,
    },
    Loop(Block),
    For {
        binding: Pattern,
        source: ForSource,
        body: Block,
    },
}

#[derive(Clone)]
pub(crate) enum ForSource {
    /// `start..end` or `start..=end` over `Int`.
    Range {
        start: Expr,
        end: Expr,
        inclusive: bool,
    },
    /// Counts through a `Range<Int>` value.
    RangeValue(Expr),
    /// Takes the list, set or map and yields its elements of type `element`:
    /// a map's entries as `(key, value)` tuples.
    Taken { container: Expr, element: Type },
    /// Borrows the container at a place with `&` or `&mut`, and yields
    /// borrows of its elements: a map's values.
    Borrowed(Place, BorrowKind),
}

/// A local and a path of parts inside it.
#[derive(Clone)]
pub(crate) struct Place {
    pub(crate) local: usize,
    pub(crate) span: Span,
    /// A call that returns a borrow, made first; the borrowed `local` then
    /// points at what it returns.
    pub(crate) call: Option<Box<Expr>>,
    pub(crate) projections: Vec<Projection>,
}

#[derive(Clone)]
pub(crate) enum Projection {
    /// A struct field or tuple element, by index.
    Field(usize),
    /// A list element at a checked index.
    Index(Box<Expr>),
}

/// The receiver of a built-in method: a place it reads or changes, or a
/// value it reads and then releases.
#[derive(Clone)]
pub(crate) enum Receiver {
    Place(Place),
    Value(Box<Expr>),
}

/// A method the compiler provides; the spec lists their signatures.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Builtin {
    List(ListMethod),
    Map(MapMethod),
    Set(SetMethod),
    Str(StrMethod),
    /// `clone(&self)` of any type that can be cloned.
    Clone,
}

impl Builtin {
    /// Whether the method changes its receiver, which it then borrows with
    /// `&mut`.
    pub(crate) const fn changes_receiver(self) -> bool {
        match self {
            Self::List(method) => match method {
                ListMethod::Push
                | ListMethod::Pop
                | ListMethod::Insert
                | ListMethod::Remove
                | ListMethod::Clear => true,
                ListMethod::Len | ListMethod::IsEmpty | ListMethod::Contains | ListMethod::Get => {
                    false
                }
            },
            Self::Map(method) => match method {
                MapMethod::Insert | MapMethod::Remove | MapMethod::Clear => true,
                MapMethod::Get
                | MapMethod::ContainsKey
                | MapMethod::Keys
                | MapMethod::Len
                | MapMethod::IsEmpty => false,
            },
            Self::Set(method) => match method {
                SetMethod::Insert | SetMethod::Remove | SetMethod::Clear => true,
                SetMethod::Contains | SetMethod::Len | SetMethod::IsEmpty => false,
            },
            Self::Str(_) | Self::Clone => false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ListMethod {
    Push,
    Pop,
    Len,
    IsEmpty,
    Insert,
    Remove,
    Clear,
    Contains,
    Get,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MapMethod {
    Insert,
    Remove,
    Get,
    ContainsKey,
    Keys,
    Len,
    IsEmpty,
    Clear,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SetMethod {
    Insert,
    Remove,
    Contains,
    Len,
    IsEmpty,
    Clear,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StrMethod {
    Len,
    IsEmpty,
    Contains,
    StartsWith,
    EndsWith,
    Find,
    Slice,
    Split,
    Trim,
    Replace,
    Repeat,
    Chars,
    ToUpper,
    ToLower,
    ParseInt,
}

#[derive(Clone)]
pub(crate) struct Expr {
    pub(crate) ty: Type,
    pub(crate) span: Span,
    pub(crate) kind: ExprKind,
}

#[derive(Clone)]
pub(crate) enum ExprKind {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(String),
    Unit,
    /// A place: a local, or a call that returns a borrow, and a part of
    /// either reached through fields and indices. Where its value is used,
    /// lowering moves an entity out of it or copies a value.
    Place(Place),
    Call {
        callee: Callee,
        /// The type arguments of a generic function; instantiation replaces
        /// the callee with the instance and leaves this empty.
        type_arguments: Vec<Type>,
        arguments: Vec<Expr>,
        /// A call that returns a borrow names the place it points at.
        borrow: Option<BorrowKind>,
    },
    Intrinsic {
        intrinsic: Intrinsic,
        arguments: Vec<Expr>,
    },
    Unary {
        operator: UnaryOperator,
        operand: Box<Expr>,
    },
    Binary {
        operator: BinaryOperator,
        left: Box<Expr>,
        right: Box<Expr>,
    },
    If {
        condition: Box<Expr>,
        then_branch: Block,
        else_branch: Option<Box<Expr>>,
    },
    Block(Block),
    /// String interpolation; each part is `Int`, `Float`, `Bool` or `Str`.
    Interpolate(Vec<Expr>),
    Tuple(Vec<Expr>),
    /// A struct (variant 0) or enum variant. `base` is evaluated first, then
    /// `fields` in source order; each field is named by its declaration index.
    /// Fields missing from `fields` come from `base`.
    Construct {
        variant: usize,
        base: Option<Box<Expr>>,
        fields: Vec<(usize, Expr)>,
    },
    /// A struct field or tuple element, by declaration or position index,
    /// of a value that is not a place, such as the result of a call.
    Field {
        base: Box<Expr>,
        index: usize,
    },
    Match {
        scrutinee: Box<Expr>,
        arms: Vec<Arm>,
    },
    List(Vec<Expr>),
    /// `Map::new()` or `Set::new()`.
    EmptyMap,
    /// `start..end` or `start..=end` as a `Range<Int>` value.
    Range {
        start: Box<Expr>,
        end: Box<Expr>,
        inclusive: bool,
    },
    /// An element of a list, or the value of a key in a map, that is not a
    /// place, such as one of a list that a call returns.
    Index {
        base: Box<Expr>,
        index: Box<Expr>,
    },
    Builtin {
        builtin: Builtin,
        receiver: Box<Receiver>,
        arguments: Vec<Expr>,
    },
    /// `&x` or `&mut x` as a call argument, `match` subject, `let` value or
    /// returned result: a pointer to a place, or to a temporary that lives
    /// until the end of the enclosing statement.
    Borrow(BorrowKind, Box<BorrowTarget>),
}

/// The function a call runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Callee {
    Function(usize),
    /// A method of a trait that bounds a type parameter. Instantiation
    /// replaces it with the method of the impl for the type argument.
    Trait {
        trait_index: usize,
        method: usize,
        self_type: Type,
    },
}

#[derive(Clone)]
pub(crate) enum BorrowTarget {
    Place(Place),
    Value(Expr),
}

#[derive(Clone)]
pub(crate) struct Arm {
    pub(crate) pattern: Pattern,
    pub(crate) guard: Option<Expr>,
    pub(crate) body: Expr,
}

#[derive(Debug, Clone)]
pub(crate) enum Pattern {
    Wildcard,
    /// A local, and where the pattern names it.
    Binding(usize, Span),
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    Tuple(Vec<Pattern>),
    /// An enum variant with patterns for some of its fields, by index.
    Variant {
        variant: usize,
        fields: Vec<(usize, Pattern)>,
    },
    /// Alternatives that bind the same locals.
    Or(Vec<Pattern>),
}

impl Pattern {
    /// The binding locals; the alternatives of an or-pattern bind the same
    /// locals, so only the first is read.
    pub(crate) fn bindings(&self) -> Vec<usize> {
        fn collect(pattern: &Pattern, locals: &mut Vec<usize>) {
            match pattern {
                Pattern::Binding(local, _) => locals.push(*local),
                Pattern::Tuple(elements) => {
                    for element in elements {
                        collect(element, locals);
                    }
                }
                Pattern::Variant { fields, .. } => {
                    for (_, field) in fields {
                        collect(field, locals);
                    }
                }
                Pattern::Or(alternatives) => {
                    if let Some(first) = alternatives.first() {
                        collect(first, locals);
                    }
                }
                Pattern::Wildcard
                | Pattern::Int(_)
                | Pattern::Float(_)
                | Pattern::Bool(_)
                | Pattern::Str(_) => {}
            }
        }
        let mut locals = Vec::new();
        collect(self, &mut locals);
        locals
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Intrinsic {
    Print,
    Assert,
    Panic,
    /// `replace(place: &mut T, value: T) -> T`.
    Replace,
    /// `swap(a: &mut T, b: &mut T)`.
    Swap,
}
