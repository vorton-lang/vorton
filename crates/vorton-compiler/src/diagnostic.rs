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
