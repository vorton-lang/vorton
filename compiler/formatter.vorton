use ast::{Span}
use diagnostics::{Diagnostic, DiagnosticNote, DiagnosticContext, Suggestion, Severity, severity_to_str}

// ============================================================
// format_human — Rustc-style human-readable diagnostic output
// ============================================================

pub fn format_human(diagnostics: List<Diagnostic>, source: Str) -> Str {
    let lines = source.split("\n")
    let mut parts: List<Str> = []

    for d in diagnostics {
        parts.push("${severity_to_str(d.severity)}[${d.code}]: ${d.message}")
        parts.push("  --> ${d.span.file}:${d.span.start.line.to_str()}:${d.span.start.column.to_str()}")
        parts.push("   |")

        let line_num = d.span.start.line
        let source_line = lines.get(line_num - 1)
        match source_line {
            some(sl) => {
                let gutter = line_num.to_str().pad_start(3, " ")
                parts.push("${gutter} | ${sl}")

                let underline_start = d.span.start.column
                let mut underline_len = 1
                if d.span.start.line == d.span.end.line {
                    let diff = d.span.end.column - d.span.start.column
                    if diff > 1 { underline_len = diff }
                } else {
                    let diff = sl.len() - underline_start
                    if diff > 1 { underline_len = diff }
                }
                let padding = " ".repeat(underline_start)
                let carets = "^".repeat(underline_len)

                let hint = format_hint(d)
                if hint.len() > 0 {
                    parts.push("   | ${padding}${carets} ${hint}")
                } else {
                    parts.push("   | ${padding}${carets}")
                }
            },
            none => {}
        }

        for n in d.notes {
            match n.span {
                some(note_span) => {
                    parts.push("   = note: ${n.message} (${note_span.file}:${note_span.start.line.to_str()}:${note_span.start.column.to_str()})")
                },
                none => {
                    parts.push("   = note: ${n.message}")
                }
            }
        }
        for s in d.suggestions {
            parts.push("   = help: ${s.message}")
        }
        parts.push("   |")
        parts.push("")
    }

    parts.join("\n")
}

fn format_hint(d: Diagnostic) -> Str {
    match d.context {
        TypeMismatch { expected, actual, .. } => "expected ${expected}, got ${actual}",
        UndefinedVariable { .. } => "not found in this scope",
        MissingField { field, .. } => "field '${field}' not found",
        EffectUnhandled { eff, .. } => "effect '${eff}' must be handled",
        ParseError { expected, .. } => {
            match expected {
                some(exp) => "expected ${exp.join(" or ")}",
                none => ""
            }
        },
        PatternError { detail } => detail,
        TraitError { detail } => detail,
        OtherContext { .. } => ""
    }
}

// ============================================================
// format_llm — Machine-readable JSON diagnostic output
// ============================================================

pub fn format_llm(diagnostics: List<Diagnostic>, file: Str) -> Str {
    let mut parts: List<Str> = []
    parts.push("{\n")
    parts.push("  \"version\": 1,\n")
    parts.push("  \"file\": ${jq(file)},\n")
    parts.push("  \"diagnostics\": [")

    for i in 0..diagnostics.len() {
        let d = diagnostics.get(i)
        match d {
            some(diag) => {
                if i > 0 { parts.push(",") }
                parts.push("\n    {\n")
                parts.push("      \"code\": ${jq(diag.code)},\n")
                parts.push("      \"severity\": ${jq(severity_to_str(diag.severity))},\n")
                parts.push("      \"message\": ${jq(diag.message)},\n")
                parts.push("      \"span\": {\n")
                parts.push("        \"line\": ${diag.span.start.line.to_str()},\n")
                parts.push("        \"col\": ${diag.span.start.column.to_str()},\n")
                parts.push("        \"end_line\": ${diag.span.end.line.to_str()},\n")
                parts.push("        \"end_col\": ${diag.span.end.column.to_str()}\n")
                parts.push("      },\n")
                parts.push("      \"context\": ${context_to_json(diag.context)},\n")
                parts.push("      \"notes\": ${notes_to_json(diag.notes)},\n")
                parts.push("      \"suggestions\": ${suggestions_to_json(diag.suggestions)},\n")
                match diag.category {
                    some(cat) => parts.push("      \"category\": ${jq(cat)}\n"),
                    none => parts.push("      \"category\": null\n")
                }
                parts.push("    }")
            },
            none => {}
        }
    }

    parts.push("\n  ]\n")
    parts.push("}")
    parts.join("")
}

// ============================================================
// JSON helpers
// ============================================================

fn jq(s: Str) -> Str {
    let escaped = s.replace("\\", "\\\\")
                   .replace("\"", "\\\"")
                   .replace("\n", "\\n")
                   .replace("\t", "\\t")
                   .replace("\r", "\\r")
    "\"${escaped}\""
}

fn context_to_json(ctx: DiagnosticContext) -> Str {
    match ctx {
        TypeMismatch { expected, actual, expression } => {
            let mut parts: List<Str> = []
            parts.push("\"kind\": \"type_mismatch\"")
            parts.push("\"expected\": ${jq(expected)}")
            parts.push("\"actual\": ${jq(actual)}")
            match expression {
                some(e) => parts.push("\"expression\": ${jq(e)}"),
                none => {}
            }
            "{ ${parts.join(", ")} }"
        },
        UndefinedVariable { name, scope_locals } => {
            let mut parts: List<Str> = []
            parts.push("\"kind\": \"undefined_variable\"")
            parts.push("\"name\": ${jq(name)}")
            match scope_locals {
                some(locals) => {
                    let items = locals.map(fn(s: Str) -> Str { jq(s) })
                    parts.push("\"scope_locals\": [${items.join(", ")}]")
                },
                none => {}
            }
            "{ ${parts.join(", ")} }"
        },
        MissingField { field, ty, available } => {
            let mut parts: List<Str> = []
            parts.push("\"kind\": \"missing_field\"")
            parts.push("\"field\": ${jq(field)}")
            parts.push("\"type\": ${jq(ty)}")
            match available {
                some(avail) => {
                    let items = avail.map(fn(s: Str) -> Str { jq(s) })
                    parts.push("\"available\": [${items.join(", ")}]")
                },
                none => {}
            }
            "{ ${parts.join(", ")} }"
        },
        EffectUnhandled { eff, in_function } => {
            let mut parts: List<Str> = []
            parts.push("\"kind\": \"effect_unhandled\"")
            parts.push("\"effect\": ${jq(eff)}")
            match in_function {
                some(f) => parts.push("\"in_function\": ${jq(f)}"),
                none => {}
            }
            "{ ${parts.join(", ")} }"
        },
        ParseError { token, expected } => {
            let mut parts: List<Str> = []
            parts.push("\"kind\": \"parse_error\"")
            parts.push("\"token\": ${jq(token)}")
            match expected {
                some(exp) => {
                    let items = exp.map(fn(s: Str) -> Str { jq(s) })
                    parts.push("\"expected\": [${items.join(", ")}]")
                },
                none => {}
            }
            "{ ${parts.join(", ")} }"
        },
        PatternError { detail } => {
            "{ \"kind\": \"pattern_error\", \"detail\": ${jq(detail)} }"
        },
        TraitError { detail } => {
            "{ \"kind\": \"trait_error\", \"detail\": ${jq(detail)} }"
        },
        OtherContext { detail } => {
            match detail {
                some(d) => "{ \"kind\": \"other\", \"detail\": ${jq(d)} }",
                none => "{ \"kind\": \"other\" }"
            }
        }
    }
}

fn notes_to_json(notes: List<DiagnosticNote>) -> Str {
    if notes.is_empty() { return "[]" }
    let mut items: List<Str> = []
    for n in notes {
        match n.span {
            some(sp) => items.push("{ \"message\": ${jq(n.message)}, \"span\": { \"line\": ${sp.start.line.to_str()}, \"col\": ${sp.start.column.to_str()} } }"),
            none => items.push("{ \"message\": ${jq(n.message)} }")
        }
    }
    "[${items.join(", ")}]"
}

fn suggestions_to_json(suggestions: List<Suggestion>) -> Str {
    if suggestions.is_empty() { return "[]" }
    let mut items: List<Str> = []
    for s in suggestions {
        match s.replacement {
            some(r) => items.push("{ \"message\": ${jq(s.message)}, \"replacement\": ${jq(r)} }"),
            none => items.push("{ \"message\": ${jq(s.message)} }")
        }
    }
    "[${items.join(", ")}]"
}
