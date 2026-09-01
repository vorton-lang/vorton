use vorton::ast::{Decl, Expr, Pattern};

use super::coverage::AstCoverage;
use super::manifest::{SyntaxCase, run_syntax_cases};

fn assert_pattern_alternatives(program: &vorton::ast::Program) {
    let mut coverage = AstCoverage::default();
    coverage.visit_program(program);
    for tag in [
        "Pattern::Wildcard",
        "Pattern::Name",
        "Pattern::Literal",
        "Pattern::Constructor",
        "Pattern::NamedConstructor",
        "Pattern::Tuple",
        "Pattern::Or",
        "PatternLiteral::Integer",
        "PatternLiteral::Float",
        "PatternLiteral::String",
        "PatternLiteral::Boolean",
    ] {
        assert!(coverage.variants.contains(tag), "missing {tag}");
    }
}

fn assert_any_pattern(program: &vorton::ast::Program) {
    assert!(!match_arms(program).is_empty());
}

fn match_arms(program: &vorton::ast::Program) -> &[vorton::ast::MatchArm] {
    let Some(Decl::Function(function)) = program.declarations.first() else {
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
    arms
}

fn assert_positional_fields(program: &vorton::ast::Program) {
    assert!(matches!(
        match_arms(program)[0].pattern,
        Pattern::Constructor { ref fields, .. } if fields.len() == 2
    ));
}

fn assert_any_constructor(program: &vorton::ast::Program) {
    assert!(matches!(
        match_arms(program)[0].pattern,
        Pattern::Constructor { .. }
    ));
}

fn assert_any_named_pattern(program: &vorton::ast::Program) {
    assert!(matches!(
        match_arms(program)[0].pattern,
        Pattern::NamedConstructor { .. }
    ));
}

fn assert_named_group(program: &vorton::ast::Program) {
    assert!(matches!(
        match_arms(program)[0].pattern,
        Pattern::NamedConstructor {
            ref fields,
            rest: Some(_),
            ..
        } if fields.len() == 2
    ));
}

fn assert_named_pattern_fields(program: &vorton::ast::Program) {
    let Pattern::NamedConstructor { fields, .. } = &match_arms(program)[0].pattern else {
        panic!("named pattern")
    };
    assert!(fields[0].shorthand);
    assert!(!fields[1].shorthand);
}

const ALL_PATTERNS: &str = r#"
fn f(value: T) {
    match value {
        _ => 0,
        name => 0,
        1 => 0,
        3.5 => 0,
        "text" => 0,
        true => 0,
        some(item,) => 0,
        module::some(item) => 0,
        shape {x, y: item, ..,} => 0,
        (left, right,) => 0,
        A | B => 0,
    }
}
"#;

#[rustfmt::skip]
const CASES: &[SyntaxCase] = &[
    SyntaxCase::valid("V.S.Pattern.all-single-alternatives", "S.Pattern", ALL_PATTERNS, assert_pattern_alternatives),
    SyntaxCase::invalid("I.S.Pattern.arm-or-outside-arm", "S.Pattern", "fn f(x: T) {if let A | B = x {}}", "E0103", "|"),
    SyntaxCase::valid("V.S.SinglePattern.lowercase-and-qualified", "S.SinglePattern", ALL_PATTERNS, assert_pattern_alternatives),
    SyntaxCase::valid("V.S.SinglePattern.wildcard", "S.SinglePattern", "fn f(x: T) {match x {_ => 0}}", assert_any_pattern),
    SyntaxCase::valid("V.S.SinglePattern.int", "S.SinglePattern", "fn f(x: T) {match x {1 => 0}}", assert_any_pattern),
    SyntaxCase::valid("V.S.SinglePattern.float", "S.SinglePattern", "fn f(x: T) {match x {1.5 => 0}}", assert_any_pattern),
    SyntaxCase::valid("V.S.SinglePattern.string", "S.SinglePattern", "fn f(x: T) {match x {\"x\" => 0}}", assert_any_pattern),
    SyntaxCase::valid("V.S.SinglePattern.bool", "S.SinglePattern", "fn f(x: T) {match x {true => 0}}", assert_any_pattern),
    SyntaxCase::valid("V.S.SinglePattern.name", "S.SinglePattern", "fn f(x: T) {match x {name => 0}}", assert_any_pattern),
    SyntaxCase::valid("V.S.SinglePattern.positional-ctor", "S.SinglePattern", "fn f(x: T) {match x {some(value) => 0}}", assert_any_constructor),
    SyntaxCase::valid("V.S.SinglePattern.named-ctor", "S.SinglePattern", "fn f(x: T) {match x {shape {value} => 0}}", assert_any_named_pattern),
    SyntaxCase::valid("V.S.SinglePattern.qualified-ctor", "S.SinglePattern", "fn f(x: T) {match x {module::some(value) => 0}}", assert_any_constructor),
    SyntaxCase::valid("V.S.SinglePattern.tuple", "S.SinglePattern", "fn f(x: T) {match x {(a, b) => 0}}", assert_any_pattern),
    SyntaxCase::invalid("I.S.SinglePattern.raw-string", "S.SinglePattern", "fn f(x: T) {match x {r\"raw\" => 0}}", "E0101", "r\"raw\""),
    SyntaxCase::invalid("I.S.SinglePattern.interpolated-string", "S.SinglePattern", "fn f(x: T) {match x {\"${value}\" => 0}}", "E0101", "\"${"),
    SyntaxCase::invalid("I.S.SinglePattern.empty-positional-ctor", "S.SinglePattern", "fn f(x: T) {match x {none() => 0}}", "E0101", ")"),
    SyntaxCase::invalid("I.S.SinglePattern.single-tuple", "S.SinglePattern", "fn f(x: T) {match x {(a,) => 0}}", "E0101", "("),
    SyntaxCase::valid("V.S.PatFields.positional", "S.PatFields", "fn f(x: T) {match x {some(a, b,) => 0}}", assert_positional_fields),
    SyntaxCase::valid("V.S.PatFields.named", "S.PatFields", "fn f(x: T) {match x {shape {a} => 0}}", assert_any_named_pattern),
    SyntaxCase::invalid("I.S.PatFields.empty-positional", "S.PatFields", "fn f(x: T) {match x {none() => 0}}", "E0101", ")"),
    SyntaxCase::valid("V.S.PatList.many-trailing", "S.PatList", "fn f(x: T) {match x {some(a, b,) => 0}}", assert_positional_fields),
    SyntaxCase::valid("V.S.PatList.one", "S.PatList", "fn f(x: T) {match x {some(a) => 0}}", assert_any_constructor),
    SyntaxCase::valid("V.S.PatList.many", "S.PatList", "fn f(x: T) {match x {some(a, b) => 0}}", assert_positional_fields),
    SyntaxCase::invalid("I.S.PatList.empty", "S.PatList", "fn f(x: T) {match x {none() => 0}}", "E0101", ")"),
    SyntaxCase::invalid("I.S.PatList.leading-comma", "S.PatList", "fn f(x: T) {match x {some(,a) => 0}}", "E0101", ","),
    SyntaxCase::invalid("I.S.PatList.double-comma", "S.PatList", "fn f(x: T) {match x {some(a,,b) => 0}}", "E0101", ","),
    SyntaxCase::invalid("I.S.PatList.missing-comma", "S.PatList", "fn f(x: T) {match x {some(a b) => 0}}", "E0103", "b"),
    SyntaxCase::valid("V.S.NamedPatGroup.fields-rest-trailing", "S.NamedPatGroup", "fn f(x: T) {match x {shape {a, b: value, ..,} => 0}}", assert_named_group),
    SyntaxCase::valid("V.S.NamedPatGroup.empty", "S.NamedPatGroup", "fn f(x: T) {match x {shape {} => 0}}", assert_any_named_pattern),
    SyntaxCase::valid("V.S.NamedPatGroup.rest-only", "S.NamedPatGroup", "fn f(x: T) {match x {shape {..} => 0}}", assert_any_named_pattern),
    SyntaxCase::valid("V.S.NamedPatGroup.rest-only-trailing", "S.NamedPatGroup", "fn f(x: T) {match x {shape {..,} => 0}}", assert_any_named_pattern),
    SyntaxCase::valid("V.S.NamedPatGroup.one-field", "S.NamedPatGroup", "fn f(x: T) {match x {shape {a} => 0}}", assert_any_named_pattern),
    SyntaxCase::valid("V.S.NamedPatGroup.many-fields", "S.NamedPatGroup", "fn f(x: T) {match x {shape {a, b} => 0}}", assert_any_named_pattern),
    SyntaxCase::valid("V.S.NamedPatGroup.fields-rest", "S.NamedPatGroup", "fn f(x: T) {match x {shape {a, ..} => 0}}", assert_any_named_pattern),
    SyntaxCase::invalid("I.S.NamedPatGroup.leading-comma", "S.NamedPatGroup", "fn f(x: T) {match x {shape {,a} => 0}}", "E0103", ","),
    SyntaxCase::invalid("I.S.NamedPatGroup.rest-first-with-fields", "S.NamedPatGroup", "fn f(x: T) {match x {shape {.., a} => 0}}", "E0103", "a"),
    SyntaxCase::invalid("I.S.NamedPatGroup.field-after-rest", "S.NamedPatGroup", "fn f(x: T) {match x {shape {a, .., b} => 0}}", "E0103", "b"),
    SyntaxCase::invalid("I.S.NamedPatGroup.double-comma", "S.NamedPatGroup", "fn f(x: T) {match x {shape {a,,b} => 0}}", "E0103", ","),
    SyntaxCase::valid("V.S.NamedPat.punning-explicit", "S.NamedPat", "fn f(x: T) {match x {shape {a, b: value} => 0}}", assert_named_pattern_fields),
    SyntaxCase::valid("V.S.NamedPat.punning", "S.NamedPat", "fn f(x: T) {match x {shape {a} => 0}}", assert_any_named_pattern),
    SyntaxCase::valid("V.S.NamedPat.explicit", "S.NamedPat", "fn f(x: T) {match x {shape {a: value} => 0}}", assert_any_named_pattern),
    SyntaxCase::invalid("I.S.NamedPat.missing-pattern", "S.NamedPat", "fn f(x: T) {match x {shape {a:} => 0}}", "E0101", "}"),
];

pub(crate) fn cases() -> &'static [SyntaxCase] {
    CASES
}

#[test]
fn pattern_grammar_cases_are_executable() {
    run_syntax_cases(CASES);
}
