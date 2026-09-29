//! Structured frontend diagnostics.

use crate::ast::Span;

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
