use std::collections::HashSet;
use std::fs;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use vorton::ast::{Decl, Expr, Pattern, Stmt, TypeExpr, UseKind, VariantFields};
use vorton::diagnostic::{format_human, format_llm};
use vorton::lexer::{TokenKind, lex};
use vorton::source::{SourceFile, SourceId};

fn source(text: &str) -> SourceFile {
    SourceFile::new(SourceId(0), "test.vorton", text).expect("valid test source")
}

fn parse(text: &str) -> vorton::FrontendOutput {
    vorton::parse_source(source(text))
}

#[test]
fn lexer_covers_the_canonical_token_surface() {
    let text = r#"
fn let mut const struct enum match impl effect handle with if else catch test return
for in pub where true false trait try while break continue loop use as extern mod super requires unsafe
name 12 3.5 "plain" r"raw\n" "a ${x} b ${y} c"
+ - * / % == != < > <= >= && || | ! = += -= *= /= %= ( ) { } [ ] , : :: . .. ..= => -> ? @ ;
"#;
    let output = lex(&source(text));
    assert!(output.diagnostics.is_empty(), "{:#?}", output.diagnostics);
    let actual: HashSet<_> = output.tokens.iter().map(|token| token.kind).collect();
    let expected = [
        TokenKind::Fn,
        TokenKind::Let,
        TokenKind::Mut,
        TokenKind::Const,
        TokenKind::Struct,
        TokenKind::Enum,
        TokenKind::Match,
        TokenKind::Impl,
        TokenKind::Effect,
        TokenKind::Handle,
        TokenKind::With,
        TokenKind::If,
        TokenKind::Else,
        TokenKind::Catch,
        TokenKind::Test,
        TokenKind::Return,
        TokenKind::For,
        TokenKind::In,
        TokenKind::Pub,
        TokenKind::Where,
        TokenKind::True,
        TokenKind::False,
        TokenKind::Trait,
        TokenKind::Try,
        TokenKind::While,
        TokenKind::Break,
        TokenKind::Continue,
        TokenKind::Loop,
        TokenKind::Use,
        TokenKind::As,
        TokenKind::Extern,
        TokenKind::Mod,
        TokenKind::Super,
        TokenKind::Requires,
        TokenKind::Unsafe,
        TokenKind::Identifier,
        TokenKind::Integer,
        TokenKind::Float,
        TokenKind::String,
        TokenKind::RawString,
        TokenKind::InterpolationStart,
        TokenKind::InterpolationMiddle,
        TokenKind::InterpolationEnd,
        TokenKind::Plus,
        TokenKind::Minus,
        TokenKind::Star,
        TokenKind::Slash,
        TokenKind::Percent,
        TokenKind::EqualEqual,
        TokenKind::BangEqual,
        TokenKind::Less,
        TokenKind::Greater,
        TokenKind::LessEqual,
        TokenKind::GreaterEqual,
        TokenKind::AmpAmp,
        TokenKind::PipePipe,
        TokenKind::Pipe,
        TokenKind::Bang,
        TokenKind::Equal,
        TokenKind::PlusEqual,
        TokenKind::MinusEqual,
        TokenKind::StarEqual,
        TokenKind::SlashEqual,
        TokenKind::PercentEqual,
        TokenKind::LeftParen,
        TokenKind::RightParen,
        TokenKind::LeftBrace,
        TokenKind::RightBrace,
        TokenKind::LeftBracket,
        TokenKind::RightBracket,
        TokenKind::Comma,
        TokenKind::Colon,
        TokenKind::ColonColon,
        TokenKind::Dot,
        TokenKind::DotDot,
        TokenKind::DotDotEqual,
        TokenKind::FatArrow,
        TokenKind::Arrow,
        TokenKind::Question,
        TokenKind::At,
        TokenKind::Semicolon,
        TokenKind::Eof,
    ];
    for kind in expected {
        assert!(actual.contains(&kind), "missing token kind {kind:?}");
    }
    let eof = output.tokens.last().unwrap();
    assert_eq!(eof.kind, TokenKind::Eof);
    assert_eq!(eof.span.start, text.len() as u32);
    assert_eq!(eof.span.end, text.len() as u32);
}

#[test]
fn lexer_uses_byte_spans_and_derives_unicode_columns() {
    let file = source("fn main() {\r\n    let text = \"雪\"\r\n}\r\n");
    let output = lex(&file);
    assert!(output.diagnostics.is_empty());
    let string = output
        .tokens
        .iter()
        .find(|token| token.kind == TokenKind::String)
        .unwrap();
    assert_eq!(
        &file.text()[string.span.start as usize..string.span.end as usize],
        "\"雪\""
    );
    assert_eq!(string.span.end - string.span.start, 5);
    assert_eq!(file.line_column(string.span.start), (2, 15));
    assert_eq!(file.line_column(string.span.end), (2, 18));

    let lf = lex(&source(
        "fn main() { let a = \"left\nright\" let b = r\"left\nright\" }",
    ));
    let crlf = lex(&source(
        "fn main() {\r\n let a = \"left\r\nright\" let b = r\"left\r\nright\"\r\n}",
    ));
    let values = |output: &vorton::lexer::LexOutput| {
        output
            .tokens
            .iter()
            .filter(|token| matches!(token.kind, TokenKind::String | TokenKind::RawString))
            .map(|token| token.value.clone())
            .collect::<Vec<_>>()
    };
    assert_eq!(values(&lf), values(&crlf));
}

#[test]
fn ast_spans_are_exact_half_open_byte_ranges() {
    let text = "fn main() {\n    let value = 42\n}\n";
    let output = vorton::parse_source(
        SourceFile::new(SourceId(7), "span.vorton", text).expect("valid source"),
    );
    assert!(output.diagnostics.is_empty());

    let assert_span = |span: vorton::source::Span, start: u32, end: u32, slice: &str| {
        assert_eq!(span.source, SourceId(7));
        assert_eq!((span.start, span.end), (start, end));
        assert_eq!(&text[start as usize..end as usize], slice);
    };

    assert_span(output.program.span, 0, 33, text);
    let Decl::Function(function) = &output.program.declarations[0] else {
        panic!("function")
    };
    assert_span(function.span, 0, 32, "fn main() {\n    let value = 42\n}");
    assert_span(function.name.span, 3, 7, "main");
    assert_span(function.body.span(), 10, 32, "{\n    let value = 42\n}");

    let Expr::Block { statements, .. } = &function.body else {
        panic!("block")
    };
    let Stmt::Let {
        pattern,
        value,
        span,
        ..
    } = &statements[0]
    else {
        panic!("let")
    };
    assert_span(*span, 16, 30, "let value = 42");
    let Pattern::Name { name, .. } = pattern else {
        panic!("binding")
    };
    assert_span(name.span, 20, 25, "value");
    assert_span(value.span(), 28, 30, "42");
}

#[test]
fn lexer_recovers_after_invalid_input_and_reports_unterminated_forms() {
    let invalid = lex(&source("& # fn valid() {}"));
    assert_eq!(invalid.diagnostics.len(), 2);
    assert_eq!(
        invalid
            .tokens
            .iter()
            .filter(|token| token.kind == TokenKind::Error)
            .count(),
        2
    );
    assert!(
        invalid
            .tokens
            .iter()
            .any(|token| token.kind == TokenKind::Fn)
    );

    let string = lex(&source("\"unterminated"));
    assert!(
        string
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == "E0102")
    );

    let interpolation_source = source("\"prefix ${value");
    let interpolation = lex(&interpolation_source);
    let diagnostic = interpolation
        .diagnostics
        .iter()
        .find(|diagnostic| diagnostic.message.contains("interpolation"))
        .expect("dedicated interpolation diagnostic");
    assert_eq!(
        &interpolation_source.text()[diagnostic.span.start as usize..diagnostic.span.end as usize],
        "${"
    );

    let many_errors = parse(&format!("{} fn valid() {{}}", "# ".repeat(40)));
    assert_eq!(many_errors.diagnostics.len(), 20);
    assert!(
        many_errors.program.declarations.iter().any(|decl| {
            matches!(decl, Decl::Function(function) if function.name.text == "valid")
        })
    );
}

#[test]
fn nested_string_interpolation_and_raw_strings_remain_distinct() {
    let output =
        parse(r#"fn main() { let text = "outer ${"inner ${value}"}" let raw = r"${value}\n" }"#);
    assert!(output.diagnostics.is_empty(), "{:#?}", output.diagnostics);
    let json = serde_json::to_string(&output.program).unwrap();
    assert!(json.contains("InterpolatedString"));
    assert!(json.contains("RawString"));
}

#[test]
fn parser_covers_declarations_types_statements_expressions_and_patterns() {
    let output = parse(include_str!("frontend/fixtures/full_surface.vorton"));
    assert!(output.diagnostics.is_empty(), "{:#?}", output.diagnostics);
    assert!(matches!(output.program.uses[0].kind, UseKind::Bare));
    assert!(matches!(output.program.uses[1].kind, UseKind::PathAlias(_)));
    assert!(matches!(
        output.program.uses[2].kind,
        UseKind::NamedItems(_)
    ));

    let json = serde_json::to_string(&output.program).unwrap();
    for declaration in [
        "Function",
        "Struct",
        "Enum",
        "Trait",
        "Impl",
        "Effect",
        "EffectAlias",
        "ExternFunction",
        "ExternType",
        "TypeAlias",
        "Test",
        "Const",
        "Module",
    ] {
        assert!(
            json.contains(&format!("\"{declaration}\"")),
            "missing declaration {declaration}"
        );
    }
    for ty in ["Named", "Function", "Tuple", "Parenthesized", "Record"] {
        assert!(
            json.contains(&format!("\"{ty}\"")),
            "missing type shape {ty}"
        );
    }
    for expression in [
        "Integer",
        "String",
        "RawString",
        "InterpolatedString",
        "Boolean",
        "Path",
        "Unary",
        "Binary",
        "Range",
        "Call",
        "MethodCall",
        "FieldAccess",
        "TupleFieldAccess",
        "Index",
        "NamedLiteral",
        "List",
        "Tuple",
        "Unit",
        "Parenthesized",
        "Block",
        "If",
        "Match",
        "Handle",
        "Lambda",
        "Catch",
        "Unsafe",
        "Return",
    ] {
        assert!(
            json.contains(&format!("\"{expression}\"")),
            "missing expression {expression}"
        );
    }
    for statement in [
        "Let",
        "IfLet",
        "Return",
        "While",
        "Loop",
        "For",
        "Break",
        "Continue",
        "Assign",
        "Expression",
    ] {
        assert!(
            json.contains(&format!("\"{statement}\"")),
            "missing statement {statement}"
        );
    }
    for pattern in [
        "Wildcard",
        "Name",
        "Literal",
        "Constructor",
        "NamedConstructor",
        "Tuple",
        "Or",
    ] {
        assert!(
            json.contains(&format!("\"{pattern}\"")),
            "missing pattern {pattern}"
        );
    }

    let enum_decl = output
        .program
        .declarations
        .iter()
        .find_map(|decl| match decl {
            Decl::Enum(value) => Some(value),
            _ => None,
        })
        .unwrap();
    assert!(matches!(enum_decl.variants[0].fields, VariantFields::Unit));
    assert!(matches!(
        enum_decl.variants[1].fields,
        VariantFields::Positional(_)
    ));
    assert!(matches!(
        enum_decl.variants[2].fields,
        VariantFields::Named(_)
    ));
}

#[test]
fn prohibited_surfaces_fail_loud_without_ast_carriers() {
    let output = parse(
        r#"
requires {unsafe}
@derive(Json)
struct Old { value: Int where value > 0 }
fn bad(value: Int?) -> Option<Int> { value? }
"#,
    );
    let messages = output
        .diagnostics
        .iter()
        .map(|diagnostic| diagnostic.message.as_str())
        .collect::<Vec<_>>();
    assert!(
        messages
            .iter()
            .any(|message| message.contains("File-level 'requires'"))
    );
    assert!(messages.iter().any(|message| message.contains("@derive")));
    assert!(messages.iter().any(|message| message.contains("where")));
    assert!(
        messages
            .iter()
            .any(|message| message.contains("Type suffix '?'"))
    );
    assert!(
        messages
            .iter()
            .any(|message| message.contains("Postfix '?'"))
    );
    let json = serde_json::to_string(&output.program).unwrap();
    assert!(!json.contains("Derive"));
    assert!(!json.contains("OptionType"));
}

#[test]
fn delimiter_aware_recovery_keeps_following_declarations() {
    for (fixture, expected_name) in [
        (
            include_str!("frontend/fixtures/recovery_match.vorton"),
            "after_match",
        ),
        (
            include_str!("frontend/fixtures/recovery_handle.vorton"),
            "after_handle",
        ),
        (
            include_str!("frontend/fixtures/recovery_if.vorton"),
            "after_if",
        ),
    ] {
        let output = parse(fixture);
        assert!(!output.diagnostics.is_empty());
        let names = output
            .program
            .declarations
            .iter()
            .filter_map(|decl| match decl {
                Decl::Function(value) => Some(value.name.text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert!(
            names.contains(&expected_name),
            "recovered declarations: {names:?}"
        );
    }
}

#[test]
fn repeated_frontend_runs_are_identical() {
    let text = include_str!("frontend/fixtures/full_surface.vorton");
    let first = parse(text);
    let second = parse(text);
    assert_eq!(first.tokens, second.tokens);
    assert_eq!(first.program, second.program);
    assert_eq!(first.diagnostics, second.diagnostics);
}

#[test]
fn human_and_llm_renderers_share_the_ordered_diagnostic_list() {
    let output = parse("fn broken( { @");
    assert!(!output.diagnostics.is_empty());
    let human = format_human(&output.source, &output.diagnostics);
    let llm = format_llm(&output.source, &output.diagnostics);
    let document: serde_json::Value = serde_json::from_str(&llm).unwrap();
    let envelope_keys = document
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect::<HashSet<_>>();
    assert_eq!(
        envelope_keys,
        HashSet::from(["version", "file", "diagnostics"])
    );
    assert_eq!(document["version"], 1);
    assert_eq!(document["file"], "test.vorton");
    assert_eq!(
        document["diagnostics"].as_array().unwrap().len(),
        output.diagnostics.len()
    );
    let diagnostic = document["diagnostics"][0].as_object().unwrap();
    let diagnostic_keys = diagnostic
        .keys()
        .map(String::as_str)
        .collect::<HashSet<_>>();
    assert_eq!(
        diagnostic_keys,
        HashSet::from([
            "code",
            "severity",
            "message",
            "span",
            "context",
            "notes",
            "suggestions",
            "category",
        ])
    );
    let span_keys = diagnostic["span"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect::<HashSet<_>>();
    assert_eq!(
        span_keys,
        HashSet::from(["line", "col", "end_line", "end_col"])
    );
    for diagnostic in &output.diagnostics {
        assert!(human.contains(&diagnostic.code));
    }
}

#[test]
fn cli_uses_stable_success_source_error_and_input_error_codes() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "vorton-frontend-{}-{unique}.vorton",
        std::process::id()
    ));
    fs::write(&path, "fn main() { 1 }").unwrap();
    let binary = env!("CARGO_BIN_EXE_vorton");

    let success = Command::new(binary)
        .args(["parse", path.to_str().unwrap()])
        .output()
        .unwrap();
    assert_eq!(success.status.code(), Some(0));
    assert_eq!(String::from_utf8(success.stdout).unwrap().trim(), "OK");

    fs::write(&path, "fn main( {").unwrap();
    let source_error = Command::new(binary)
        .args(["parse", path.to_str().unwrap(), "--error-format=llm"])
        .output()
        .unwrap();
    assert_eq!(source_error.status.code(), Some(1));
    let document: serde_json::Value = serde_json::from_slice(&source_error.stdout).unwrap();
    assert_eq!(document["version"], 1);

    let input_error = Command::new(binary).arg("unknown").output().unwrap();
    assert_eq!(input_error.status.code(), Some(2));
    fs::remove_file(path).unwrap();
}

#[test]
fn selected_ast_nodes_keep_surface_shapes() {
    let output = parse("fn main() { loop { break } let value = (1) value += 2 }");
    assert!(output.diagnostics.is_empty());
    let function = output
        .program
        .declarations
        .iter()
        .find_map(|decl| match decl {
            Decl::Function(value) => Some(value),
            _ => None,
        })
        .unwrap();
    let Expr::Block { statements, .. } = &function.body else {
        panic!("function body")
    };
    assert!(matches!(statements[0], Stmt::Loop { .. }));
    let Stmt::Let { value, .. } = &statements[1] else {
        panic!("let")
    };
    assert!(matches!(value, Expr::Parenthesized { .. }));
    assert!(matches!(
        statements[2],
        Stmt::Assign {
            op: vorton::ast::AssignOp::AddAssign,
            ..
        }
    ));

    let output = parse("type Wrapped = (Int)");
    let Decl::TypeAlias(alias) = &output.program.declarations[0] else {
        panic!("alias")
    };
    assert!(matches!(alias.ty, TypeExpr::Parenthesized { .. }));

    let output = parse("fn f(value: Point) { match value { Point { x, .. } => x } }");
    let Decl::Function(function) = &output.program.declarations[0] else {
        panic!("function")
    };
    let Expr::Block {
        tail: Some(tail), ..
    } = &function.body
    else {
        panic!("tail")
    };
    let Expr::Match { arms, .. } = tail.as_ref() else {
        panic!("match")
    };
    assert!(matches!(arms[0].pattern, Pattern::NamedConstructor { .. }));
}

#[test]
fn call_parentheses_must_start_on_the_callee_line() {
    let same_line = parse("fn main() { call(1) }");
    let Decl::Function(function) = &same_line.program.declarations[0] else {
        panic!("function")
    };
    let Expr::Block {
        tail: Some(tail), ..
    } = &function.body
    else {
        panic!("tail")
    };
    assert!(matches!(tail.as_ref(), Expr::Call { .. }));

    let next_line = parse("fn main() { call\n(1) }");
    assert!(next_line.diagnostics.is_empty());
    let Decl::Function(function) = &next_line.program.declarations[0] else {
        panic!("function")
    };
    let Expr::Block {
        statements,
        tail: Some(tail),
        ..
    } = &function.body
    else {
        panic!("body")
    };
    assert!(matches!(
        statements[0],
        Stmt::Expression {
            expression: Expr::Path { .. },
            ..
        }
    ));
    assert!(matches!(tail.as_ref(), Expr::Parenthesized { .. }));
}
