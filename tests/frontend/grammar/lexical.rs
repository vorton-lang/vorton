use std::collections::BTreeSet;

use vorton::lexer::{TokenKind, lex};
use vorton::source::{SourceFile, SourceId};

use super::manifest::{CaseMeta, Polarity};

enum LexExpectation {
    Tokens(&'static [TokenKind]),
    BoundaryTokens {
        kinds: &'static [TokenKind],
        code: &'static str,
        found: &'static str,
    },
    Invalid {
        code: &'static str,
        found: &'static str,
    },
}

struct LexCase {
    id: &'static str,
    production: &'static str,
    source: &'static str,
    expectation: LexExpectation,
}

const fn valid(
    id: &'static str,
    production: &'static str,
    source: &'static str,
    kinds: &'static [TokenKind],
) -> LexCase {
    LexCase {
        id,
        production,
        source,
        expectation: LexExpectation::Tokens(kinds),
    }
}

const fn invalid(
    id: &'static str,
    production: &'static str,
    source: &'static str,
    code: &'static str,
    found: &'static str,
) -> LexCase {
    LexCase {
        id,
        production,
        source,
        expectation: LexExpectation::Invalid { code, found },
    }
}

const fn boundary(
    id: &'static str,
    production: &'static str,
    source: &'static str,
    kinds: &'static [TokenKind],
    code: &'static str,
    found: &'static str,
) -> LexCase {
    LexCase {
        id,
        production,
        source,
        expectation: LexExpectation::BoundaryTokens { kinds, code, found },
    }
}

#[rustfmt::skip]
const CASES: &[LexCase] = &[
    valid("V.L.LineComment.empty-lf", "L.LineComment", "//\n", &[TokenKind::Eof]),
    valid("V.L.LineComment.text-lf", "L.LineComment", "// text\n", &[TokenKind::Eof]),
    valid("V.L.LineComment.text-eof", "L.LineComment", "// text", &[TokenKind::Eof]),
    invalid("I.L.LineComment.block-comment-is-not-comment", "L.LineComment", "/* block */", "E0101", "/"),
    valid("V.L.Ident.lower", "L.Ident", "lower", &[TokenKind::Identifier, TokenKind::Eof]),
    valid("V.L.Ident.upper", "L.Ident", "Upper", &[TokenKind::Identifier, TokenKind::Eof]),
    valid("V.L.Ident.underscore", "L.Ident", "_", &[TokenKind::Identifier, TokenKind::Eof]),
    valid("V.L.Ident.mixed", "L.Ident", "a_B9", &[TokenKind::Identifier, TokenKind::Eof]),
    invalid("I.L.Ident.leading-digit", "L.Ident", "1name", "E0101", "1"),
    invalid("I.L.Ident.non-ascii", "L.Ident", "雪", "E0101", "雪"),
    invalid("I.L.Ident.keyword-as-binding", "L.Ident", "fn fn() {}", "E0103", "fn"),
    valid("V.L.IntLit.zero", "L.IntLit", "0", &[TokenKind::Integer, TokenKind::Eof]),
    valid("V.L.IntLit.leading-zero", "L.IntLit", "007", &[TokenKind::Integer, TokenKind::Eof]),
    valid("V.L.IntLit.many-digits", "L.IntLit", "123456", &[TokenKind::Integer, TokenKind::Eof]),
    invalid("I.L.IntLit.hex-prefix", "L.IntLit", "const n = 0x10", "E0101", "x10"),
    invalid("I.L.IntLit.binary-prefix", "L.IntLit", "const n = 0b10", "E0101", "b10"),
    invalid("I.L.IntLit.suffix", "L.IntLit", "const n = 1i", "E0101", "i"),
    valid("V.L.FloatLit.minimal", "L.FloatLit", "0.0", &[TokenKind::Float, TokenKind::Eof]),
    valid("V.L.FloatLit.many-digits", "L.FloatLit", "12.345", &[TokenKind::Float, TokenKind::Eof]),
    invalid("I.L.FloatLit.missing-left", "L.FloatLit", "const n = .5", "E0101", "."),
    invalid("I.L.FloatLit.missing-right", "L.FloatLit", "const n = 5.", "E0103", ""),
    boundary("I.L.FloatLit.multiple-dot", "L.FloatLit", "1.2.3", &[TokenKind::Float, TokenKind::Dot, TokenKind::Integer, TokenKind::Eof], "E0101", "1.2"),
    valid("V.L.BoolLit.true", "L.BoolLit", "true", &[TokenKind::True, TokenKind::Eof]),
    valid("V.L.BoolLit.false", "L.BoolLit", "false", &[TokenKind::False, TokenKind::Eof]),
    invalid("I.L.BoolLit.keyword-boundary", "L.BoolLit", "const b = truefalse true", "E0101", "true"),
    valid("V.L.StringLit.empty", "L.StringLit", "\"\"", &[TokenKind::String, TokenKind::Eof]),
    valid("V.L.StringLit.text", "L.StringLit", "\"text\"", &[TokenKind::String, TokenKind::Eof]),
    valid("V.L.StringLit.all-escapes", "L.StringLit", r#""\\\"\n\t\r\0\$""#, &[TokenKind::String, TokenKind::Eof]),
    valid("V.L.StringLit.escaped-dollar", "L.StringLit", "\"\\${value}\"", &[TokenKind::String, TokenKind::Eof]),
    valid("V.L.StringLit.multiline-lf", "L.StringLit", "\"a\nb\"", &[TokenKind::String, TokenKind::Eof]),
    valid("V.L.StringLit.multiline-crlf", "L.StringLit", "\"a\r\nb\"", &[TokenKind::String, TokenKind::Eof]),
    valid("V.L.StringLit.lone-cr", "L.StringLit", "\"a\rb\"", &[TokenKind::String, TokenKind::Eof]),
    invalid("I.L.StringLit.unknown-escape", "L.StringLit", "\"bad\\q\"", "E0101", "\\q"),
    invalid("I.L.StringLit.dangling-slash", "L.StringLit", "\"bad\\", "E0102", "\"bad\\"),
    invalid("I.L.StringLit.unterminated", "L.StringLit", "\"bad", "E0102", "\"bad"),
    valid("V.L.RawStringLit.plain-empty", "L.RawStringLit", "r\"\"", &[TokenKind::RawString, TokenKind::Eof]),
    valid("V.L.RawStringLit.plain-text", "L.RawStringLit", "r\"text\"", &[TokenKind::RawString, TokenKind::Eof]),
    valid("V.L.RawStringLit.hash-empty", "L.RawStringLit", "r#\"\"#", &[TokenKind::RawString, TokenKind::Eof]),
    valid("V.L.RawStringLit.hash-with-quotes", "L.RawStringLit", "r#\"a \\\"quote\\\"\"#", &[TokenKind::RawString, TokenKind::Eof]),
    valid("V.L.RawStringLit.literal-backslash-dollar", "L.RawStringLit", r#"r"\n ${x}""#, &[TokenKind::RawString, TokenKind::Eof]),
    valid("V.L.RawStringLit.multiline", "L.RawStringLit", "r\"a\nb\"", &[TokenKind::RawString, TokenKind::Eof]),
    invalid("I.L.RawStringLit.plain-quote", "L.RawStringLit", "const x = r\"a\"b\"", "E0102", "\""),
    invalid("I.L.RawStringLit.unterminated", "L.RawStringLit", "r\"bad", "E0102", "r\"bad"),
    invalid("I.L.RawStringLit.more-than-one-hash", "L.RawStringLit", "r##\"bad\"##", "E0101", "#"),
    valid("V.L.InterpString.one", "L.InterpString", "\"a ${x} b\"", &[TokenKind::InterpolationStart, TokenKind::Identifier, TokenKind::InterpolationEnd, TokenKind::Eof]),
    valid("V.L.InterpString.many", "L.InterpString", "\"${x}${y}\"", &[TokenKind::InterpolationStart, TokenKind::Identifier, TokenKind::InterpolationMiddle, TokenKind::Identifier, TokenKind::InterpolationEnd, TokenKind::Eof]),
    valid("V.L.InterpString.empty-text-parts", "L.InterpString", "\"${x}${y}\"", &[TokenKind::InterpolationStart, TokenKind::Identifier, TokenKind::InterpolationMiddle, TokenKind::Identifier, TokenKind::InterpolationEnd, TokenKind::Eof]),
    valid("V.L.InterpString.nested", "L.InterpString", "\"${{x}}\"", &[TokenKind::InterpolationStart, TokenKind::LeftBrace, TokenKind::Identifier, TokenKind::RightBrace, TokenKind::InterpolationEnd, TokenKind::Eof]),
    valid("V.L.InterpString.nested-string", "L.InterpString", "\"${\"${x}\"}\"", &[TokenKind::InterpolationStart, TokenKind::InterpolationStart, TokenKind::Identifier, TokenKind::InterpolationEnd, TokenKind::InterpolationEnd, TokenKind::Eof]),
    valid("V.L.InterpString.expression-block", "L.InterpString", "\"${{x}}\"", &[TokenKind::InterpolationStart, TokenKind::LeftBrace, TokenKind::Identifier, TokenKind::RightBrace, TokenKind::InterpolationEnd, TokenKind::Eof]),
    invalid("I.L.InterpString.empty-expression", "L.InterpString", "fn f() { \"${}\" }", "E0101", "\""),
    invalid("I.L.InterpString.missing-expression-close", "L.InterpString", "\"${x", "E0102", "${"),
    invalid("I.L.InterpString.missing-string-close", "L.InterpString", "\"${x}", "E0102", ""),
];

pub(crate) fn case_meta() -> Vec<CaseMeta> {
    CASES
        .iter()
        .map(|case| CaseMeta {
            id: case.id,
            production: Some(case.production),
            polarity: match case.expectation {
                LexExpectation::Tokens(_) => Polarity::Valid,
                LexExpectation::BoundaryTokens { .. } | LexExpectation::Invalid { .. } => {
                    Polarity::Invalid
                }
            },
        })
        .collect()
}

#[test]
fn lexical_production_cases_are_executable() {
    let mut failures = Vec::new();
    for (index, case) in CASES.iter().enumerate() {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            run_lexical_case(case, index)
        }));
        if result.is_err() {
            failures.push(case.id);
        }
    }
    assert!(
        failures.is_empty(),
        "lexical conformance RED cases:\n{}",
        failures.join("\n")
    );
}

fn run_lexical_case(case: &LexCase, index: usize) {
    let source = SourceFile::new(
        SourceId(u32::try_from(index + 1).expect("case index")),
        format!("{}.vorton", case.id),
        case.source,
    )
    .expect("valid source");
    match case.expectation {
        LexExpectation::Tokens(expected) => {
            let output = lex(&source);
            assert!(
                output.diagnostics.is_empty(),
                "{}: {:#?}",
                case.id,
                output.diagnostics
            );
            let actual: Vec<_> = output.tokens.iter().map(|token| token.kind).collect();
            assert_eq!(actual, expected, "{}", case.id);
        }
        LexExpectation::BoundaryTokens { kinds, code, found } => {
            let output = lex(&source);
            assert!(
                output.diagnostics.is_empty(),
                "{}: {:#?}",
                case.id,
                output.diagnostics
            );
            let actual: Vec<_> = output.tokens.iter().map(|token| token.kind).collect();
            assert_eq!(actual, kinds, "{}", case.id);
            let frontend = vorton::parse_source(source);
            let Err(diagnostics) = frontend.syntax else {
                panic!("{} must fail closed", case.id)
            };
            assert_eq!(diagnostics[0].code, code, "{} code", case.id);
            let actual = &frontend.source.text()
                [diagnostics[0].span.start as usize..diagnostics[0].span.end as usize];
            assert_eq!(actual, found, "{} source slice", case.id);
        }
        LexExpectation::Invalid { code, found } => {
            let output = vorton::parse_source(source);
            let Err(diagnostics) = output.syntax else {
                panic!("{} must fail closed", case.id)
            };
            assert!(!diagnostics.is_empty(), "{} diagnostics", case.id);
            assert_eq!(diagnostics[0].code, code, "{} code", case.id);
            let actual = &output.source.text()
                [diagnostics[0].span.start as usize..diagnostics[0].span.end as usize];
            assert_eq!(actual, found, "{} source slice", case.id);
        }
    }
}

fn token_tag(kind: TokenKind) -> &'static str {
    match kind {
        TokenKind::Fn => "Fn",
        TokenKind::Let => "Let",
        TokenKind::Mut => "Mut",
        TokenKind::Const => "Const",
        TokenKind::Struct => "Struct",
        TokenKind::Enum => "Enum",
        TokenKind::Match => "Match",
        TokenKind::Impl => "Impl",
        TokenKind::Effect => "Effect",
        TokenKind::Handle => "Handle",
        TokenKind::With => "With",
        TokenKind::If => "If",
        TokenKind::Else => "Else",
        TokenKind::Catch => "Catch",
        TokenKind::Test => "Test",
        TokenKind::Return => "Return",
        TokenKind::For => "For",
        TokenKind::In => "In",
        TokenKind::Pub => "Pub",
        TokenKind::Where => "Where",
        TokenKind::True => "True",
        TokenKind::False => "False",
        TokenKind::Trait => "Trait",
        TokenKind::Try => "Try",
        TokenKind::While => "While",
        TokenKind::Break => "Break",
        TokenKind::Continue => "Continue",
        TokenKind::Loop => "Loop",
        TokenKind::Use => "Use",
        TokenKind::As => "As",
        TokenKind::Extern => "Extern",
        TokenKind::Mod => "Mod",
        TokenKind::Super => "Super",
        TokenKind::Requires => "Requires",
        TokenKind::Unsafe => "Unsafe",
        TokenKind::Integer => "Integer",
        TokenKind::Float => "Float",
        TokenKind::String => "String",
        TokenKind::RawString => "RawString",
        TokenKind::InterpolationStart => "InterpolationStart",
        TokenKind::InterpolationMiddle => "InterpolationMiddle",
        TokenKind::InterpolationEnd => "InterpolationEnd",
        TokenKind::Identifier => "Identifier",
        TokenKind::Plus => "Plus",
        TokenKind::Minus => "Minus",
        TokenKind::Star => "Star",
        TokenKind::Slash => "Slash",
        TokenKind::Percent => "Percent",
        TokenKind::EqualEqual => "EqualEqual",
        TokenKind::BangEqual => "BangEqual",
        TokenKind::Less => "Less",
        TokenKind::Greater => "Greater",
        TokenKind::LessEqual => "LessEqual",
        TokenKind::GreaterEqual => "GreaterEqual",
        TokenKind::AmpAmp => "AmpAmp",
        TokenKind::PipePipe => "PipePipe",
        TokenKind::Pipe => "Pipe",
        TokenKind::Bang => "Bang",
        TokenKind::Equal => "Equal",
        TokenKind::PlusEqual => "PlusEqual",
        TokenKind::MinusEqual => "MinusEqual",
        TokenKind::StarEqual => "StarEqual",
        TokenKind::SlashEqual => "SlashEqual",
        TokenKind::PercentEqual => "PercentEqual",
        TokenKind::LeftParen => "LeftParen",
        TokenKind::RightParen => "RightParen",
        TokenKind::LeftBrace => "LeftBrace",
        TokenKind::RightBrace => "RightBrace",
        TokenKind::LeftBracket => "LeftBracket",
        TokenKind::RightBracket => "RightBracket",
        TokenKind::Comma => "Comma",
        TokenKind::Colon => "Colon",
        TokenKind::ColonColon => "ColonColon",
        TokenKind::Dot => "Dot",
        TokenKind::DotDot => "DotDot",
        TokenKind::DotDotEqual => "DotDotEqual",
        TokenKind::FatArrow => "FatArrow",
        TokenKind::Arrow => "Arrow",
        TokenKind::Question => "Question",
        TokenKind::At => "At",
        TokenKind::Semicolon => "Semicolon",
        TokenKind::Error => "Error",
        TokenKind::Eof => "Eof",
    }
}

const TOKEN_SURFACE: &str = r#"
fn let mut const struct enum match impl effect handle with if else catch test return
for in pub where true false trait try while break continue loop use as extern mod super requires unsafe
name 12 3.5 "plain" r"raw" "a ${x} b ${y} c"
+ - * / % == != < > <= >= && || | ! = += -= *= /= %= ( ) { } [ ] , : :: . .. ..= => -> ? @ ;
"#;

#[rustfmt::skip]
const EXPECTED_TOKEN_TAGS: &[&str] = &[
    "AmpAmp", "Arrow", "As", "At", "Bang", "BangEqual", "Break", "Catch", "Colon",
    "ColonColon", "Comma", "Const", "Continue", "Dot", "DotDot", "DotDotEqual", "Effect",
    "Else", "Enum", "Eof", "Equal", "EqualEqual", "Error", "Extern", "False", "FatArrow",
    "Float", "Fn", "For", "Greater", "GreaterEqual", "Handle", "Identifier", "If", "Impl",
    "In", "Integer", "InterpolationEnd", "InterpolationMiddle", "InterpolationStart", "LeftBrace",
    "LeftBracket", "LeftParen", "Less", "LessEqual", "Let", "Loop", "Match", "Minus",
    "MinusEqual", "Mod", "Mut", "Percent", "PercentEqual", "Pipe", "PipePipe", "Plus",
    "PlusEqual", "Pub", "Question", "RawString", "Requires", "Return", "RightBrace",
    "RightBracket", "RightParen", "Semicolon", "Slash", "SlashEqual", "Star", "StarEqual",
    "String", "Struct", "Super", "Test", "Trait", "True", "Try", "Unsafe", "Use", "Where",
    "While", "With",
];

#[test]
fn token_kind_inventory_is_exhaustive_and_exact() {
    let valid = lex(&SourceFile::new(SourceId(900), "tokens.vorton", TOKEN_SURFACE).unwrap());
    assert!(valid.diagnostics.is_empty());
    let invalid = lex(&SourceFile::new(SourceId(901), "error.vorton", "&").unwrap());
    assert_eq!(invalid.diagnostics.len(), 1);

    let actual: BTreeSet<_> = valid
        .tokens
        .iter()
        .chain(&invalid.tokens)
        .map(|token| token_tag(token.kind))
        .collect();
    let expected: BTreeSet<_> = EXPECTED_TOKEN_TAGS.iter().copied().collect();
    assert_eq!(EXPECTED_TOKEN_TAGS.len(), 83);
    assert_eq!(actual, expected);
}
