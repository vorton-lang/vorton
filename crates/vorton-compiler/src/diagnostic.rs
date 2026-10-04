//! Structured diagnostics: those of the frontend, and those of checking a
//! resolved project, which every later pass reports.

use crate::ast::Span;
use crate::project::OriginRef;

/// One deterministic failure from checking a resolved project.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckDiagnostic {
    pub kind: CheckDiagnosticKind,
    pub primary: Option<OriginRef>,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckDiagnosticKind {
    /// Valid source outside the constructs the current checker supports.
    Unsupported,
    TypeMismatch,
    ArgumentCount,
    /// An assignment target is not rooted in a `let mut` local or `mut` parameter.
    NotAssignable,
    /// `break` or `continue` appears outside a loop.
    OutsideLoop,
    /// A numeric literal cannot be represented by its type.
    LiteralOutOfRange,
    /// The entry library root has no `fn main()` without parameters that returns `Unit`.
    MissingMain,
    /// A field or tuple element that the type does not have.
    UnknownField,
    /// A construction leaves a field without a value.
    MissingField,
    /// The type arguments of a generic construction cannot be determined.
    CannotInfer,
    /// A `match`, `if let` alternative or destructuring misses possible values.
    NonExhaustive,
    /// A local is used after its entity value may have been moved away.
    UseAfterMove,
    /// An entity is moved out of a field, an element or a borrow.
    CannotMove,
    /// A method that the receiver's type does not have.
    UnknownMethod,
    /// A place is changed while a loop or borrow still reads it.
    BorrowConflict,
    /// A returned borrow names a place that ends when the function returns.
    BorrowOutlives,
    /// Two impls give a type methods of the same name.
    DuplicateMethod,
    /// A struct, enum or tuple contains itself by value and has no finite
    /// size.
    RecursiveType,
    /// A type argument does not satisfy a bound of its type parameter, or a
    /// type lacks the supertrait impls of a trait it implements.
    UnsatisfiedBound,
    /// A trait is implemented twice for one type, or by hand where only the
    /// compiler implements it.
    DuplicateImpl,
    /// A trait impl lacks a method of the trait.
    MissingMethod,
    /// Several traits give the receiver's type a method of the called name.
    AmbiguousMethod,
    /// A private field, method or trait used outside its module.
    InaccessibleMember,
    /// A private type or trait in a public signature, field or payload.
    PrivateInInterface,
    /// A hand-written `drop` that can reach `print`.
    ConsoleInDrop,
    /// A recursive call passes type arguments that could grow without end.
    PolymorphicRecursion,
    /// A bound that no type parameter can have, such as `Drop`.
    InvalidBound,
    /// A change of a `let mut` variable of a value type that is never read
    /// afterwards.
    UnreadChange,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrontendDiagnostic {
    pub span: Span,
    pub kind: FrontendDiagnosticKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrontendDiagnosticKind {
    Lexical(LexicalDiagnosticKind),
    UnexpectedToken {
        found: FoundToken,
        expected: Vec<ExpectedToken>,
    },
    Layout(LayoutDiagnosticKind),
    /// An assignment target or `mut` operand is not a local name followed by
    /// field, tuple-field or index projections.
    ExpectedPlace,
    /// The source nests deeper than the spec allows.
    NestingTooDeep,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayoutDiagnosticKind {
    /// A line break ends the item before this token, which cannot start a new item.
    UnexpectedLineBreak,
    /// Two items of a statement sequence are neither on separate lines nor separated by `;`.
    MissingSeparator,
    /// A `;` or `,` separator ends a line or directly precedes the closing delimiter.
    TrailingSeparator,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LexicalDiagnosticKind {
    UnexpectedCharacter,
    InvalidEscape,
    UnterminatedCookedString,
    UnterminatedRawString,
    UnterminatedInterpolation,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FoundToken {
    Fixed(String),
    Class(TokenClass),
    Eof,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ExpectedToken {
    Fixed(String),
    Class(TokenClass),
    Eof,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum TokenClass {
    Identifier,
    IntegerLiteral,
    FloatLiteral,
    StringLiteral,
    RawStringLiteral,
    InterpolatedStringStart,
    InterpolatedStringMiddle,
    InterpolatedStringEnd,
}

impl FrontendDiagnostic {
    pub(crate) const fn lexical(span: Span, kind: LexicalDiagnosticKind) -> Self {
        Self {
            span,
            kind: FrontendDiagnosticKind::Lexical(kind),
        }
    }

    pub(crate) const fn layout(span: Span, kind: LayoutDiagnosticKind) -> Self {
        Self {
            span,
            kind: FrontendDiagnosticKind::Layout(kind),
        }
    }

    pub(crate) const fn too_deep(span: Span) -> Self {
        Self {
            span,
            kind: FrontendDiagnosticKind::NestingTooDeep,
        }
    }

    pub(crate) const fn expected_place(span: Span) -> Self {
        Self {
            span,
            kind: FrontendDiagnosticKind::ExpectedPlace,
        }
    }

    pub(crate) fn unexpected(
        span: Span,
        found: FoundToken,
        mut expected: Vec<ExpectedToken>,
    ) -> Self {
        expected.sort();
        expected.dedup();
        Self {
            span,
            kind: FrontendDiagnosticKind::UnexpectedToken { found, expected },
        }
    }
}
