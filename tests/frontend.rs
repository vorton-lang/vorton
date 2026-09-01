use std::collections::HashSet;
use std::fs;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use vorton::ast::{
    BinaryOp, Decl, EffectName, Expr, ForBinding, Pattern, PatternLiteral, Program, Stmt, TypeExpr,
    UseKind, VariantFields,
};
use vorton::diagnostic::{Diagnostic, DiagnosticNote, format_human, format_llm};
use vorton::lexer::{Token, TokenKind, lex};
use vorton::source::{SourceFile, SourceId};

fn source(text: &str) -> SourceFile {
    SourceFile::new(SourceId(0), "test.vorton", text).expect("valid test source")
}

struct ValidFrontendOutput {
    tokens: Vec<Token>,
    program: Program,
    diagnostics: Vec<Diagnostic>,
}

struct InvalidFrontendOutput {
    source: SourceFile,
    diagnostics: Vec<Diagnostic>,
}

fn parse(text: &str) -> ValidFrontendOutput {
    let output = vorton::parse_source(source(text));
    match output.syntax {
        Ok(program) => ValidFrontendOutput {
            tokens: output.tokens,
            program,
            diagnostics: Vec::new(),
        },
        Err(diagnostics) => panic!("expected valid syntax: {diagnostics:#?}"),
    }
}

fn parse_error(text: &str) -> InvalidFrontendOutput {
    let output = vorton::parse_source(source(text));
    match output.syntax {
        Ok(program) => panic!("expected syntax error, got: {program:#?}"),
        Err(diagnostics) => InvalidFrontendOutput {
            source: output.source,
            diagnostics,
        },
    }
}

fn tail_expression(text: &str) -> Expr {
    let output = parse(&format!("fn main() {{ {text} }}"));
    assert!(output.diagnostics.is_empty(), "{:#?}", output.diagnostics);
    let Decl::Function(function) = &output.program.declarations[0] else {
        panic!("function")
    };
    let Expr::Block {
        tail: Some(tail), ..
    } = &function.body
    else {
        panic!("tail")
    };
    tail.as_ref().clone()
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

    let lone_cr = lex(&source(
        "fn main() { let a = \"left\rright\" let b = r\"left\rright\" }",
    ));
    assert_eq!(
        values(&lone_cr),
        vec!["left\rright".to_owned(), "left\rright".to_owned()]
    );
}

#[test]
fn ast_spans_are_exact_half_open_byte_ranges() {
    let text = "fn main() {\n    let value = 42\n}\n";
    let output = vorton::parse_source(
        SourceFile::new(SourceId(7), "span.vorton", text).expect("valid source"),
    );
    let program = output.syntax.expect("valid syntax");

    let assert_span = |span: vorton::source::Span, start: u32, end: u32, slice: &str| {
        assert_eq!(span.source, SourceId(7));
        assert_eq!((span.start, span.end), (start, end));
        assert_eq!(&text[start as usize..end as usize], slice);
    };

    assert_span(program.span, 0, 33, text);
    let Decl::Function(function) = &program.declarations[0] else {
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
fn named_type_spans_include_every_closing_angle_bracket() {
    let text = "type Plain = List<Int>\ntype Nested = List<Map<Int, Str>>\n";
    let output = parse(text);
    assert!(output.diagnostics.is_empty(), "{:#?}", output.diagnostics);

    let aliases = output
        .program
        .declarations
        .iter()
        .filter_map(|decl| match decl {
            Decl::TypeAlias(alias) => Some(alias),
            _ => None,
        })
        .collect::<Vec<_>>();

    assert_eq!(
        (aliases[0].ty.span().start, aliases[0].ty.span().end),
        (13, 22)
    );
    assert_eq!(
        &text[aliases[0].ty.span().start as usize..aliases[0].ty.span().end as usize],
        "List<Int>"
    );
    assert_eq!(
        (aliases[1].ty.span().start, aliases[1].ty.span().end),
        (37, 56)
    );
    assert_eq!(
        &text[aliases[1].ty.span().start as usize..aliases[1].ty.span().end as usize],
        "List<Map<Int, Str>>"
    );
    let TypeExpr::Named { type_args, .. } = &aliases[1].ty else {
        panic!("named type")
    };
    assert_eq!(
        (type_args[0].span().start, type_args[0].span().end),
        (42, 55)
    );
    assert_eq!(
        &text[type_args[0].span().start as usize..type_args[0].span().end as usize],
        "Map<Int, Str>"
    );
}

#[test]
fn type_bounds_reject_empty_angles_and_keep_associated_constraints() {
    let invalid = parse_error("fn bad<T: Trait<>>(value: T) {}\n");
    assert_eq!(invalid.diagnostics.len(), 1);
    assert_eq!(invalid.diagnostics[0].code, "E0101");
    assert_eq!(
        invalid.diagnostics[0].message,
        "Type bound arguments cannot be empty"
    );

    let valid = parse("fn good<T: Trait<Item = Int>>(value: T) {}\n");
    assert!(valid.diagnostics.is_empty(), "{:#?}", valid.diagnostics);
    let Decl::Function(function) = &valid.program.declarations[0] else {
        panic!("function")
    };
    let bound = &function.type_params[0].bounds[0];
    assert!(bound.type_args.is_empty());
    assert_eq!(bound.associated.len(), 1);
    assert_eq!(bound.associated[0].name.text, "Item");
    let TypeExpr::Named { path, .. } = &bound.associated[0].ty else {
        panic!("associated type")
    };
    assert_eq!(path.segments[0].text, "Int");
}

#[test]
fn lexer_errors_return_err_without_a_parser_program() {
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

    let frontend = vorton::parse_source(source("& fn valid() {}"));
    assert!(
        frontend
            .tokens
            .iter()
            .any(|token| token.kind == TokenKind::Fn)
    );
    let Err(diagnostics) = frontend.syntax else {
        panic!("lexer error must not expose a Program")
    };
    assert_eq!(diagnostics.len(), 1);
    assert_eq!(diagnostics[0].code, "E0101");
}

#[test]
fn frontend_result_makes_program_and_diagnostics_mutually_exclusive() {
    let valid = vorton::parse_source(source("fn main() {}"));
    assert!(matches!(valid.syntax, Ok(Program { .. })));

    let first = vorton::parse_source(source("fn broken( { @"));
    let Err(first_diagnostics) = &first.syntax else {
        panic!("parser error must not expose a Program")
    };
    assert_eq!(first_diagnostics.len(), 1);
    assert!(
        first
            .tokens
            .iter()
            .all(|token| token.kind != TokenKind::Error)
    );

    let second = vorton::parse_source(source("fn broken( { @"));
    let Err(second_diagnostics) = &second.syntax else {
        panic!("repeated parser error must remain Err")
    };
    assert_eq!(first_diagnostics, second_diagnostics);
    assert_eq!(
        format_human(&first.source, &first_diagnostics),
        format_human(&second.source, &second_diagnostics)
    );
    assert_eq!(
        format_llm(&first.source, &first_diagnostics),
        format_llm(&second.source, &second_diagnostics)
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
fn grouped_use_requires_the_colon_colon_separator() {
    let text = "use parser::{Token}\n";
    let valid = parse(text);
    assert!(valid.diagnostics.is_empty(), "{:#?}", valid.diagnostics);
    assert_eq!(
        (
            valid.program.uses[0].span.start,
            valid.program.uses[0].span.end
        ),
        (0, 19)
    );
    assert_eq!(
        &text[valid.program.uses[0].span.start as usize..valid.program.uses[0].span.end as usize],
        "use parser::{Token}"
    );
    assert_eq!(
        (
            valid.program.uses[0].path.span.start,
            valid.program.uses[0].path.span.end
        ),
        (4, 10)
    );
    let UseKind::NamedItems(items) = &valid.program.uses[0].kind else {
        panic!("named items")
    };
    assert_eq!((items[0].span.start, items[0].span.end), (13, 18));

    let invalid = parse_error("use parser {Token}\n");
    assert_eq!(invalid.diagnostics.len(), 1);
    assert_eq!(invalid.diagnostics[0].code, "E0101");
    assert_eq!(
        invalid.diagnostics[0].message,
        "A grouped use requires '::' before '{'"
    );
}

#[test]
fn prohibited_surfaces_fail_loud_without_ast_carriers() {
    for (text, message) in [
        (
            "requires {unsafe}\n",
            "File-level 'requires' is not part of the canonical 0.1 surface",
        ),
        (
            "@derive(Json) struct Old {}\n",
            "Attribute '@derive' is not part of the canonical 0.1 surface",
        ),
        (
            "struct Old { value: Int where value > 0 }\n",
            "Refinement 'where' clauses are not part of Vorton 0.1",
        ),
        (
            "fn bad(value: Int?) {}\n",
            "Type suffix '?' is not part of Vorton 0.1; use Option<T>",
        ),
        (
            "fn bad(value: Option<Int>) { value? }\n",
            "Postfix '?' is not part of Vorton 0.1",
        ),
    ] {
        let output = parse_error(text);
        assert_eq!(output.diagnostics.len(), 1);
        assert_eq!(output.diagnostics[0].message, message);
    }
}

#[test]
fn raw_string_patterns_fail_without_becoming_string_patterns() {
    let output = parse_error("fn bad(value: Str) { match value { r\"raw\" => 1 } }\n");
    assert_eq!(output.diagnostics.len(), 1);
    assert_eq!(output.diagnostics[0].code, "E0101");
    assert_eq!(
        output.diagnostics[0].message,
        "Raw string literals are not supported in patterns"
    );
}

#[test]
fn return_expression_is_restricted_to_match_and_catch_arms() {
    let invalid = parse_error("fn bad() { let value = return 1 }\n");
    assert_eq!(invalid.diagnostics.len(), 1);
    assert_eq!(
        invalid.diagnostics[0].message,
        "Expected expression, found 'return'"
    );

    let match_return = tail_expression("match 1 { _ => return 1 }");
    let Expr::Match { arms, .. } = match_return else {
        panic!("match")
    };
    assert!(matches!(arms[0].body, Expr::Return { .. }));

    let catch_return = tail_expression("risky() catch { _ => return 2 }");
    let Expr::Catch { arms, .. } = catch_return else {
        panic!("catch")
    };
    assert!(matches!(arms[0].body, Expr::Return { .. }));
}

#[test]
fn removed_syntax_contracts_fail_closed_with_stable_diagnostics() {
    let default_parameter_cases = [
        ("fn", "fn bad(value: Int = 1) {}\n"),
        ("extern", "extern fn bad(value: Int = 1)\n"),
        ("effect", "effect Bad { fn op(value: Int = 1) -> Unit }\n"),
        (
            "handler",
            "fn bad() { handle {} with { Logger.log(value: Int = 1) => () } }\n",
        ),
        ("lambda", "fn bad() { fn(value: Int = 1) { value } }\n"),
        ("trait", "trait Bad { fn method(value: Int = 1) }\n"),
    ];
    for (label, text) in default_parameter_cases {
        let output = parse_error(text);
        assert!(
            output.diagnostics[0].code == "E0101"
                && output.diagnostics[0].message == "Default parameters are not part of Vorton 0.1",
            "missing default-parameter diagnostic for {label}: {:#?}",
            output.diagnostics
        );
    }

    let cases = [
        (
            "trait body",
            "trait Bad { fn bad() { 1 } }\n",
            "E0101",
            "Trait method bodies are not supported in Vorton 0.1",
        ),
        (
            "effect body",
            "effect Bad { fn bad() -> Unit { () } }\n",
            "E0101",
            "Effect operation bodies are not supported in Vorton 0.1",
        ),
        (
            "delegate",
            "struct Box {}\nimpl Box { delegate inner: Show }\n",
            "E0101",
            "'delegate' is not part of Vorton 0.1",
        ),
        (
            "impl extern",
            "struct Box {}\nimpl Box { extern fn raw(value: Int) -> Int }\n",
            "E0101",
            "Impl-member extern functions are not part of Vorton 0.1",
        ),
        (
            "try",
            "fn bad() { try { 1 } }\n",
            "E0101",
            "'try' is reserved; use a catch expression",
        ),
        (
            "empty enum parentheses",
            "enum Bad { empty() }\n",
            "E0104",
            "Empty parentheses on an enum variant are not allowed",
        ),
    ];
    for (label, text, code, message) in cases {
        let output = parse_error(text);
        assert!(
            output.diagnostics[0].code == code && output.diagnostics[0].message == message,
            "missing diagnostic for {label}: {:#?}",
            output.diagnostics
        );
    }
}

#[test]
fn impl_member_extern_fails_closed() {
    let output = parse_error("struct Box {}\nimpl Box { extern fn raw() -> Int }\n");
    assert_eq!(output.diagnostics.len(), 1);
    assert_eq!(output.diagnostics[0].code, "E0101");
    assert_eq!(
        output.diagnostics[0].message,
        "Impl-member extern functions are not part of Vorton 0.1"
    );
}

#[test]
fn impl_trait_and_target_require_named_types() {
    for text in [
        "impl (Trait, Other) for Box {}\n",
        "impl fn(Int) -> Int for Box {}\n",
        "impl {field: Int} for Box {}\n",
        "impl Trait for (Box, Other) {}\n",
        "impl Trait for fn(Int) -> Int {}\n",
        "impl Trait for {field: Int} {}\n",
    ] {
        let output = parse_error(text);
        assert_eq!(output.diagnostics.len(), 1);
        assert_eq!(output.diagnostics[0].code, "E0101");
        assert_eq!(
            output.diagnostics[0].message,
            "Impl trait and target must be named types"
        );
    }

    for text in ["impl Box {}\n", "impl Trait for Box {}\n"] {
        let output = parse(text);
        assert!(matches!(output.program.declarations[0], Decl::Impl(_)));
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
    let output = parse_error("fn broken( { @");
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
fn llm_note_span_keeps_the_version_one_point_shape() {
    let file = source("abc\n");
    let mut diagnostic = Diagnostic::parse("E0101", "bad", file.span(0, 1), "a");
    diagnostic.notes.push(DiagnosticNote {
        message: "detail".to_owned(),
        span: Some(file.span(1, 3)),
    });
    let document: serde_json::Value =
        serde_json::from_str(&format_llm(&file, &[diagnostic])).unwrap();
    let note_span = document["diagnostics"][0]["notes"][0]["span"]
        .as_object()
        .unwrap();
    assert_eq!(
        note_span.keys().map(String::as_str).collect::<HashSet<_>>(),
        HashSet::from(["line", "col"])
    );
    assert_eq!(note_span["line"], 1);
    assert_eq!(note_span["col"], 1);
}

#[test]
fn cli_uses_stable_success_source_error_and_input_error_codes() {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let directory = std::env::temp_dir().join(format!(
        "vorton-frontend-{}-{unique}.vorton",
        std::process::id()
    ));
    fs::create_dir(&directory).unwrap();
    let path = directory.join("case.vorton");
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

    let top_level_help = Command::new(binary).arg("help").output().unwrap();
    assert_eq!(top_level_help.status.code(), Some(0));
    assert!(
        String::from_utf8(top_level_help.stdout)
            .unwrap()
            .contains("Usage:")
    );

    fs::write(directory.join("help"), "fn main() {}").unwrap();
    let help_path = Command::new(binary)
        .current_dir(&directory)
        .args(["parse", "help"])
        .output()
        .unwrap();
    assert_eq!(help_path.status.code(), Some(0));
    assert_eq!(String::from_utf8(help_path.stdout).unwrap().trim(), "OK");

    let nested_help_flag = Command::new(binary)
        .args(["parse", "--help"])
        .output()
        .unwrap();
    assert_eq!(nested_help_flag.status.code(), Some(2));

    fs::remove_file(path).unwrap();
    fs::remove_file(directory.join("help")).unwrap();
    fs::remove_dir(directory).unwrap();
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
fn control_head_named_literals_require_parentheses_for_that_ast_shape() {
    let Expr::If { condition, .. } = tail_expression("if (Point {x: 1}) {}") else {
        panic!("if")
    };
    assert!(matches!(
        condition.as_ref(),
        Expr::Parenthesized { inner, .. } if matches!(inner.as_ref(), Expr::NamedLiteral { .. })
    ));

    let Expr::If { condition, .. } = tail_expression("if Point {}") else {
        panic!("if")
    };
    assert!(matches!(condition.as_ref(), Expr::Path { .. }));

    let output =
        parse("fn main() { if let value = Point {} while Point {} for value in Point {} }\n");
    let Decl::Function(function) = &output.program.declarations[0] else {
        panic!("function")
    };
    let Expr::Block { statements, .. } = &function.body else {
        panic!("block")
    };
    assert!(matches!(
        statements[0],
        Stmt::IfLet {
            value: Expr::Path { .. },
            ..
        }
    ));
    assert!(matches!(
        statements[1],
        Stmt::While {
            condition: Expr::Path { .. },
            ..
        }
    ));
    assert!(matches!(
        statements[2],
        Stmt::For {
            iterable: Expr::Path { .. },
            ..
        }
    ));

    let Expr::Match { scrutinee, .. } = tail_expression("match Value { _ => 0 }") else {
        panic!("match")
    };
    assert!(matches!(scrutinee.as_ref(), Expr::Path { .. }));
}

#[test]
fn remaining_surface_shapes_have_direct_structural_coverage() {
    assert!(matches!(tail_expression("3.5"), Expr::Float { .. }));
    assert!(matches!(tail_expression("()"), Expr::Unit { .. }));

    let for_loop = parse("fn main() { for item in items {} }\n");
    assert!(for_loop.diagnostics.is_empty());
    let Decl::Function(function) = &for_loop.program.declarations[0] else {
        panic!("function")
    };
    let Expr::Block { statements, .. } = &function.body else {
        panic!("block")
    };
    let Stmt::For { binding, .. } = &statements[0] else {
        panic!("for")
    };
    let ForBinding::Name(name) = binding else {
        panic!("name binding")
    };
    assert_eq!(name.text, "item");

    let effects = parse("fn effects() with {mut<Int>, unsafe} {}\n");
    assert!(effects.diagnostics.is_empty(), "{:#?}", effects.diagnostics);
    let Decl::Function(function) = &effects.program.declarations[0] else {
        panic!("function")
    };
    let effect_set = function.effects.as_ref().expect("effect set");
    assert!(matches!(
        effect_set.effects[0].name,
        EffectName::Mutation(_)
    ));
    assert!(matches!(effect_set.effects[1].name, EffectName::Unsafe(_)));

    let patterns = tail_expression("match value { 1.5 => 0, \"x\" => 1, true => 2, _ => 3 }");
    let Expr::Match { arms, .. } = patterns else {
        panic!("match")
    };
    assert!(matches!(
        arms[0].pattern,
        Pattern::Literal {
            literal: PatternLiteral::Float(_),
            ..
        }
    ));
    assert!(matches!(
        arms[1].pattern,
        Pattern::Literal {
            literal: PatternLiteral::String(_),
            ..
        }
    ));
    assert!(matches!(
        arms[2].pattern,
        Pattern::Literal {
            literal: PatternLiteral::Boolean(true),
            ..
        }
    ));
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

    let same_line_method = parse("fn main() { receiver.method(1) }");
    let Decl::Function(function) = &same_line_method.program.declarations[0] else {
        panic!("function")
    };
    let Expr::Block {
        tail: Some(tail), ..
    } = &function.body
    else {
        panic!("tail")
    };
    assert!(matches!(tail.as_ref(), Expr::MethodCall { .. }));

    let next_line_method = parse("fn main() { receiver.method\n(1) }");
    assert!(next_line_method.diagnostics.is_empty());
    let Decl::Function(function) = &next_line_method.program.declarations[0] else {
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
            expression: Expr::FieldAccess { .. },
            ..
        }
    ));
    assert!(matches!(tail.as_ref(), Expr::Parenthesized { .. }));
}

#[test]
fn precedence_and_associativity_are_structural() {
    let multiplied_first = tail_expression("1 + 2 * 3");
    let Expr::Binary {
        op: BinaryOp::Add,
        right,
        ..
    } = multiplied_first
    else {
        panic!("add root")
    };
    assert!(matches!(
        right.as_ref(),
        Expr::Binary {
            op: BinaryOp::Multiply,
            ..
        }
    ));

    let left_associative = tail_expression("1 - 2 - 3");
    let Expr::Binary {
        op: BinaryOp::Subtract,
        left,
        ..
    } = left_associative
    else {
        panic!("subtract root")
    };
    assert!(matches!(
        left.as_ref(),
        Expr::Binary {
            op: BinaryOp::Subtract,
            ..
        }
    ));

    let comparison = parse_error("fn main() { 1 < 2 < 3 }");
    assert_eq!(
        comparison.diagnostics[0].message,
        "Comparison operators are non-associative"
    );

    let range_then_catch = tail_expression("1 + 2..3 catch { _ => 4 }");
    let Expr::Catch { expression, .. } = range_then_catch else {
        panic!("catch root")
    };
    let Expr::Range { start, .. } = expression.as_ref() else {
        panic!("range inside catch")
    };
    assert!(matches!(
        start.as_ref(),
        Expr::Binary {
            op: BinaryOp::Add,
            ..
        }
    ));
}
