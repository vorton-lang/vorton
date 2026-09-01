use vorton::ast::{Decl, Expr, Pattern};

use super::coverage::AstCoverage;
use super::manifest::{SyntaxCase, run_syntax_cases};

const FULL_SURFACE: &str = include_str!("../fixtures/full_surface.vorton");

fn function_tail(program: &vorton::ast::Program) -> &Expr {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    let Expr::Block {
        tail: Some(tail), ..
    } = &function.body
    else {
        panic!("tail")
    };
    tail
}

fn assert_primary_alternatives(program: &vorton::ast::Program) {
    let mut coverage = AstCoverage::default();
    coverage.visit_program(program);
    for tag in [
        "Expr::Integer",
        "Expr::Float",
        "Expr::String",
        "Expr::RawString",
        "Expr::InterpolatedString",
        "Expr::Boolean",
        "Expr::Path",
        "Expr::NamedLiteral",
        "Expr::List",
        "Expr::Tuple",
        "Expr::Unit",
        "Expr::Parenthesized",
        "Expr::Block",
        "Expr::If",
        "Expr::Match",
        "Expr::Handle",
        "Expr::Lambda",
        "Expr::Unsafe",
    ] {
        assert!(coverage.variants.contains(tag), "missing {tag}");
    }
}

fn assert_named_literal(program: &vorton::ast::Program) {
    let Expr::NamedLiteral {
        path,
        spread,
        fields,
        ..
    } = function_tail(program)
    else {
        panic!("named literal")
    };
    assert_eq!(path.segments[0].text, "shape");
    assert!(spread.is_some());
    assert_eq!(fields.len(), 2);
}

fn assert_field_init(program: &vorton::ast::Program) {
    let Expr::NamedLiteral { fields, .. } = function_tail(program) else {
        panic!("named literal")
    };
    assert!(fields[0].shorthand);
    assert!(!fields[1].shorthand);
}

fn assert_list(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::List { elements, .. } if elements.len() == 2));
}

fn assert_tuple(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Tuple { elements, .. } if elements.len() == 2));
}

fn assert_if(program: &vorton::ast::Program) {
    assert!(matches!(
        function_tail(program),
        Expr::If {
            else_branch: Some(_),
            ..
        }
    ));
}

fn assert_match(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Match { arms, .. } if arms.len() == 2));
}

fn assert_guarded_arm(program: &vorton::ast::Program) {
    let Expr::Match { arms, .. } = function_tail(program) else {
        panic!("match")
    };
    assert!(arms[0].guard.is_some());
}

fn assert_return_arm(program: &vorton::ast::Program) {
    let Expr::Match { arms, .. } = function_tail(program) else {
        panic!("match")
    };
    assert!(matches!(arms[0].body, Expr::Return { value: Some(_), .. }));
    assert!(matches!(arms[1].body, Expr::Return { value: None, .. }));
}

fn assert_or_pattern(program: &vorton::ast::Program) {
    let Expr::Match { arms, .. } = function_tail(program) else {
        panic!("match")
    };
    assert!(
        matches!(arms[0].pattern, Pattern::Or { ref alternatives, .. } if alternatives.len() == 2)
    );
}

fn assert_handle(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Handle { handlers, .. } if handlers.len() == 2));
}

fn assert_handler_path(program: &vorton::ast::Program) {
    let Expr::Handle { handlers, .. } = function_tail(program) else {
        panic!("handle")
    };
    assert_eq!(handlers[0].effect.segments.len(), 2);
    assert_eq!(handlers[0].params.len(), 2);
}

fn assert_lambda(program: &vorton::ast::Program) {
    assert!(
        matches!(function_tail(program), Expr::Lambda { params, return_type: Some(_), .. } if params.len() == 2)
    );
}

fn assert_call_args(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Call { args, .. } if args.len() == 2));
}

#[rustfmt::skip]
const CASES: &[SyntaxCase] = &[
    SyntaxCase::valid("V.S.PrimaryExpr.all-alternatives", "S.PrimaryExpr", FULL_SURFACE, assert_primary_alternatives),
    SyntaxCase::invalid("I.S.PrimaryExpr.incomplete-if", "S.PrimaryExpr", "fn f() {if}", "E0101", "}"),
    SyntaxCase::valid("V.S.NamedLiteral.lowercase-path", "S.NamedLiteral", "fn f(base: shape) {shape {..base, x, y: 1,}}", assert_named_literal),
    SyntaxCase::invalid("I.S.NamedLiteral.missing-close", "S.NamedLiteral", "fn f() {shape {x: 1}", "E0103", ""),
    SyntaxCase::valid("V.S.NamedLiteralBody.spread-and-fields", "S.NamedLiteralBody", "fn f(base: shape) {shape {..base, x, y: 1,}}", assert_named_literal),
    SyntaxCase::invalid("I.S.NamedLiteralBody.missing-comma-after-spread", "S.NamedLiteralBody", "fn f(base: shape) {shape {..base x: 1}}", "E0103", "x"),
    SyntaxCase::valid("V.S.FieldInit.punning-and-explicit", "S.FieldInit", "fn f() {shape {x, y: 1}}", assert_field_init),
    SyntaxCase::invalid("I.S.FieldInit.missing-value", "S.FieldInit", "fn f() {shape {x:}}", "E0101", "}"),
    SyntaxCase::valid("V.S.ListLit.many-trailing", "S.ListLit", "fn f() {[1, 2,]}", assert_list),
    SyntaxCase::invalid("I.S.ListLit.leading-comma", "S.ListLit", "fn f() {[, 1]}", "E0101", ","),
    SyntaxCase::valid("V.S.TupleOrParen.tuple-trailing", "S.TupleOrParen", "fn f() {(1, 2,)}", assert_tuple),
    SyntaxCase::invalid("I.S.TupleOrParen.single-tuple", "S.TupleOrParen", "fn f() {(1,)}", "E0101", "(1,)"),
    SyntaxCase::valid("V.S.ExprList.many-trailing", "S.ExprList", "fn f() {(1, 2,)}", assert_tuple),
    SyntaxCase::invalid("I.S.ExprList.missing-comma", "S.ExprList", "fn f() {(1 2)}", "E0103", "2"),
    SyntaxCase::valid("V.S.IfExpr.else-if", "S.IfExpr", "fn f() {if true {1} else if false {2} else {3}}", assert_if),
    SyntaxCase::invalid("I.S.IfExpr.dangling-else", "S.IfExpr", "fn f() {if true {} else}", "E0103", "}"),
    SyntaxCase::valid("V.S.MatchExpr.many-arm", "S.MatchExpr", "fn f(x: T) {match x {A => 1, B => 2,}}", assert_match),
    SyntaxCase::invalid("I.S.MatchExpr.missing-scrutinee", "S.MatchExpr", "fn f() {match {}}", "E0103", "}"),
    SyntaxCase::valid("V.S.MatchArm.guard-comma", "S.MatchArm", "fn f(x: T) {match x {A if true => 1,}}", assert_guarded_arm),
    SyntaxCase::invalid("I.S.MatchArm.missing-arrow", "S.MatchArm", "fn f(x: T) {match x {A 1}}", "E0103", "1"),
    SyntaxCase::valid("V.S.ArmBody.expr-and-return", "S.ArmBody", "fn f(x: T) {match x {A => return 1, B => return,}}", assert_return_arm),
    SyntaxCase::invalid("I.S.ArmBody.general-return-outside-arm", "S.ArmBody", "fn f() {let x = return 1}", "E0101", "return"),
    SyntaxCase::valid("V.S.ReturnExpr.bare-and-value", "S.ReturnExpr", "fn f(x: T) {match x {A => return 1, B => return,}}", assert_return_arm),
    SyntaxCase::invalid("I.S.ReturnExpr.semicolon-in-arm-body", "S.ReturnExpr", "fn f(x: T) {match x {A => return;}}", "E0101", ";"),
    SyntaxCase::valid("V.S.OrPattern.many", "S.OrPattern", "fn f(x: T) {match x {A | B => 1}}", assert_or_pattern),
    SyntaxCase::invalid("I.S.OrPattern.trailing-pipe", "S.OrPattern", "fn f(x: T) {match x {A | => 1}}", "E0101", "=>"),
    SyntaxCase::valid("V.S.Guard.minimal", "S.Guard", "fn f(x: T) {match x {A if true => 1}}", assert_guarded_arm),
    SyntaxCase::invalid("I.S.Guard.missing-expression", "S.Guard", "fn f(x: T) {match x {A if => 1}}", "E0101", "=>"),
    SyntaxCase::valid("V.S.HandleExpr.many-trailing", "S.HandleExpr", "fn f() {handle {} with {io.a() => 1, io.b() => 2,}}", assert_handle),
    SyntaxCase::invalid("I.S.HandleExpr.empty", "S.HandleExpr", "fn f() {handle {} with {}}", "E0101", "}"),
    SyntaxCase::valid("V.S.Handler.typed-untyped", "S.Handler", "fn f() {handle {} with {module::io.op(a: Int, b) => 1}}", assert_handler_path),
    SyntaxCase::invalid("I.S.Handler.missing-dot", "S.Handler", "fn f() {handle {} with {io op() => 1}}", "E0103", "op"),
    SyntaxCase::valid("V.S.LambdaExpr.return", "S.LambdaExpr", "fn f() {fn(a: Int, b) -> Int {a}}", assert_lambda),
    SyntaxCase::invalid("I.S.LambdaExpr.default-param", "S.LambdaExpr", "fn f() {fn(a = 1) {a}}", "E0101", "="),
    SyntaxCase::valid("V.S.ArgList.many-trailing", "S.ArgList", "fn f() {call(1, 2,)}", assert_call_args),
    SyntaxCase::invalid("I.S.ArgList.missing-comma", "S.ArgList", "fn f() {call(1 2)}", "E0103", "2"),
];

pub(crate) fn cases() -> &'static [SyntaxCase] {
    CASES
}

#[test]
fn expression_grammar_cases_are_executable() {
    run_syntax_cases(CASES);
}
