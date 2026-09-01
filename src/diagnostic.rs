use std::cmp::Ordering;

use serde::Serialize;

use crate::source::{SourceFile, Span};

pub const MAX_DIAGNOSTICS: usize = 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Error,
    Warning,
    Info,
    Hint,
}

impl Severity {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Error => "error",
            Self::Warning => "warning",
            Self::Info => "info",
            Self::Hint => "hint",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiagnosticNote {
    pub message: String,
    pub span: Option<Span>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Suggestion {
    pub message: String,
    pub replacement: Option<String>,
    pub span: Option<Span>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DiagnosticContext {
    Parse {
        token: String,
        expected: Vec<String>,
    },
    Other {
        detail: Option<String>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Diagnostic {
    pub severity: Severity,
    pub code: String,
    pub message: String,
    pub span: Span,
    pub notes: Vec<DiagnosticNote>,
    pub context: DiagnosticContext,
    pub suggestions: Vec<Suggestion>,
    pub category: String,
}

impl Diagnostic {
    pub fn parse(
        code: &str,
        message: impl Into<String>,
        span: Span,
        token: impl Into<String>,
    ) -> Self {
        Self {
            severity: Severity::Error,
            code: code.to_owned(),
            message: message.into(),
            span,
            notes: Vec::new(),
            context: DiagnosticContext::Parse {
                token: token.into(),
                expected: Vec::new(),
            },
            suggestions: Vec::new(),
            category: category_for_code(code).to_owned(),
        }
    }

    pub fn with_expected(mut self, expected: impl IntoIterator<Item = impl Into<String>>) -> Self {
        if let DiagnosticContext::Parse {
            expected: values, ..
        } = &mut self.context
        {
            values.extend(expected.into_iter().map(Into::into));
        }
        self
    }

    pub fn with_suggestion(
        mut self,
        message: impl Into<String>,
        replacement: Option<String>,
    ) -> Self {
        self.suggestions.push(Suggestion {
            message: message.into(),
            replacement,
            span: Some(self.span),
        });
        self
    }
}

fn category_for_code(code: &str) -> &'static str {
    if code.starts_with("E01") {
        "parse"
    } else if code.starts_with("E02") {
        "resolution"
    } else if code.starts_with("E03") {
        "type"
    } else if code.starts_with("E04") {
        "effect"
    } else if code.starts_with("E05") {
        "trait"
    } else if code.starts_with("E06") {
        "pattern"
    } else if code.starts_with("E07") {
        "module"
    } else if code.starts_with("E08") {
        "ownership"
    } else if code.starts_with('W') {
        "warning"
    } else {
        "unknown"
    }
}

pub fn push_diagnostic(diagnostics: &mut Vec<Diagnostic>, diagnostic: Diagnostic) {
    if diagnostics.len() < MAX_DIAGNOSTICS {
        diagnostics.push(diagnostic);
    }
}

pub fn sort_diagnostics(diagnostics: &mut [Diagnostic]) {
    diagnostics.sort_by(compare_diagnostic);
}

fn compare_diagnostic(left: &Diagnostic, right: &Diagnostic) -> Ordering {
    (
        left.span.source,
        left.span.start,
        left.span.end,
        left.code.as_str(),
        left.message.as_str(),
    )
        .cmp(&(
            right.span.source,
            right.span.start,
            right.span.end,
            right.code.as_str(),
            right.message.as_str(),
        ))
}

pub fn format_human(source: &SourceFile, diagnostics: &[Diagnostic]) -> String {
    let mut output = String::new();
    for (index, diagnostic) in diagnostics.iter().enumerate() {
        if index > 0 {
            output.push('\n');
        }
        let (line, column) = source.line_column(diagnostic.span.start);
        let (end_line, end_column) = source.line_column(diagnostic.span.end);
        output.push_str(&format!(
            "{}[{}]: {}\n  --> {}:{}:{}\n   |\n",
            diagnostic.severity.as_str(),
            diagnostic.code,
            diagnostic.message,
            source.path(),
            line,
            column
        ));

        if let Some(source_line) = source.line_text(line) {
            let gutter = line.to_string();
            output.push_str(&format!("{gutter:>3} | {source_line}\n"));
            let underline_len = if line == end_line {
                end_column.saturating_sub(column).max(1)
            } else {
                u32::try_from(source_line.chars().count())
                    .unwrap_or(u32::MAX)
                    .saturating_sub(column)
                    .max(1)
            };
            output.push_str("   | ");
            output.push_str(&" ".repeat(column as usize));
            output.push_str(&"^".repeat(underline_len as usize));
            output.push('\n');
        }

        for note in &diagnostic.notes {
            output.push_str("   = note: ");
            output.push_str(&note.message);
            if let Some(span) = note.span {
                let (note_line, note_column) = source.line_column(span.start);
                output.push_str(&format!(" ({}:{note_line}:{note_column})", source.path()));
            }
            output.push('\n');
        }
        for suggestion in &diagnostic.suggestions {
            output.push_str("   = help: ");
            output.push_str(&suggestion.message);
            output.push('\n');
        }
        output.push_str("   |\n");
    }
    output
}

#[derive(Serialize)]
struct LlmEnvelope<'a> {
    version: u8,
    file: &'a str,
    diagnostics: Vec<LlmDiagnostic<'a>>,
}

#[derive(Serialize)]
struct LlmDiagnostic<'a> {
    code: &'a str,
    severity: &'static str,
    message: &'a str,
    span: LlmSpan,
    context: LlmContext<'a>,
    notes: Vec<LlmNote<'a>>,
    suggestions: Vec<LlmSuggestion<'a>>,
    category: &'a str,
}

#[derive(Serialize)]
struct LlmSpan {
    line: u32,
    col: u32,
    end_line: u32,
    end_col: u32,
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum LlmContext<'a> {
    ParseError {
        token: &'a str,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        expected: &'a Vec<String>,
    },
    Other {
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: &'a Option<String>,
    },
}

#[derive(Serialize)]
struct LlmNote<'a> {
    message: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    span: Option<LlmNoteSpan>,
}

#[derive(Serialize)]
struct LlmNoteSpan {
    line: u32,
    col: u32,
}

#[derive(Serialize)]
struct LlmSuggestion<'a> {
    message: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    replacement: &'a Option<String>,
}

pub fn format_llm(source: &SourceFile, diagnostics: &[Diagnostic]) -> String {
    let diagnostics = diagnostics
        .iter()
        .map(|diagnostic| {
            let context = match &diagnostic.context {
                DiagnosticContext::Parse { token, expected } => {
                    LlmContext::ParseError { token, expected }
                }
                DiagnosticContext::Other { detail } => LlmContext::Other { detail },
            };
            LlmDiagnostic {
                code: &diagnostic.code,
                severity: diagnostic.severity.as_str(),
                message: &diagnostic.message,
                span: llm_span(source, diagnostic.span),
                context,
                notes: diagnostic
                    .notes
                    .iter()
                    .map(|note| LlmNote {
                        message: &note.message,
                        span: note.span.map(|span| llm_note_span(source, span)),
                    })
                    .collect(),
                suggestions: diagnostic
                    .suggestions
                    .iter()
                    .map(|suggestion| LlmSuggestion {
                        message: &suggestion.message,
                        replacement: &suggestion.replacement,
                    })
                    .collect(),
                category: &diagnostic.category,
            }
        })
        .collect();

    serde_json::to_string_pretty(&LlmEnvelope {
        version: 1,
        file: source.path(),
        diagnostics,
    })
    .expect("diagnostics are serializable")
}

fn llm_span(source: &SourceFile, span: Span) -> LlmSpan {
    let (line, col) = source.line_column(span.start);
    let (end_line, end_col) = source.line_column(span.end);
    LlmSpan {
        line,
        col,
        end_line,
        end_col,
    }
}

fn llm_note_span(source: &SourceFile, span: Span) -> LlmNoteSpan {
    let (line, col) = source.line_column(span.start);
    LlmNoteSpan { line, col }
}
