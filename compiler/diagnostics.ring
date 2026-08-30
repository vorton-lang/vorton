use ast::{Span, Position}
use codes::{error_category}

// ============================================================
// Severity
// ============================================================

pub enum Severity {
    SevError,
    SevWarning,
    SevInfo,
    SevHint
}

pub fn severity_to_str(s: Severity) -> Str {
    match s {
        SevError => "error",
        SevWarning => "warning",
        SevInfo => "info",
        SevHint => "hint"
    }
}

// ============================================================
// Diagnostic data types
// ============================================================

pub struct DiagnosticNote {
    pub message: Str,
    pub span: Span?
}

pub enum DiagnosticContext {
    TypeMismatch { expected: Str, actual: Str, expression: Str? },
    UndefinedVariable { name: Str, scope_locals: List<Str>? },
    MissingField { field: Str, ty: Str, available: List<Str>? },
    EffectUnhandled { eff: Str, in_function: Str? },
    ParseError { token: Str, expected: List<Str>? },
    PatternError { detail: Str },
    TraitError { detail: Str },
    OtherContext { detail: Str? }
}

pub struct Suggestion {
    pub message: Str,
    pub replacement: Str?,
    pub span: Span?
}

pub struct Diagnostic {
    pub severity: Severity,
    pub code: Str,
    pub message: Str,
    pub span: Span,
    pub notes: List<DiagnosticNote>,
    pub context: DiagnosticContext,
    pub suggestions: List<Suggestion>,
    pub category: Str?
}

fn dummy_span() -> Span {
    Span {
        file: "",
        start: Position { line: 0, column: 0, offset: 0 },
        end: Position { line: 0, column: 0, offset: 0 }
    }
}

// ============================================================
// DiagnosticSink trait
// ============================================================

pub trait DiagnosticSink {
    fn report(mut self, d: Diagnostic) -> Unit
    fn has_errors(self) -> Bool
    fn get_diagnostics(self) -> List<Diagnostic>
}

// ============================================================
// CollectingSink
// ============================================================

pub struct CollectingSink {
    pub items: List<Diagnostic>,
    seen: Map<Str, Bool>
}

fn diag_key(d: Diagnostic) -> Str {
    "${d.code}@${d.span.file}:${d.span.start.offset}"
}

pub fn new_collecting_sink() -> CollectingSink {
    CollectingSink { items: [], seen: map_new() }
}

impl CollectingSink {
    pub fn diagnostics(self) -> List<Diagnostic> {
        self.items
    }

    pub fn clear(mut self) {
        self.items.clear()
        self.seen.clear()
    }

    pub fn save(self) -> Int {
        self.items.len()
    }

    pub fn restore(mut self, checkpoint: Int) {
        self.items = self.items.slice(0, checkpoint)
        self.seen = map_new()
        for d in self.items {
            self.seen.insert(diag_key(d), true)
        }
    }
}

impl DiagnosticSink for CollectingSink {
    fn report(mut self, d: Diagnostic) {
        let key = diag_key(d)
        if !self.seen.contains_key(key) {
            self.seen.insert(key, true)
            self.items.push(d)
        }
    }

    fn has_errors(self) -> Bool {
        self.items.any(fn(d: Diagnostic) -> Bool {
            match d.severity {
                SevError => true,
                _ => false
            }
        })
    }

    fn get_diagnostics(self) -> List<Diagnostic> {
        self.items
    }
}

// ============================================================
// make_diagnostic helper
// ============================================================

pub fn make_diagnostic(
    code: Str,
    severity: Severity,
    message: Str,
    span: Span,
    context: DiagnosticContext,
    notes: List<DiagnosticNote>
) -> Diagnostic {
    Diagnostic {
        severity: severity,
        code: code,
        message: message,
        span: span,
        notes: notes,
        context: context,
        suggestions: [],
        category: some(error_category(code))
    }
}

pub fn make_diag(
    code: Str,
    severity: Severity,
    message: Str,
    span: Span,
    context: DiagnosticContext
) -> Diagnostic {
    make_diagnostic(code, severity, message, span, context, [])
}
