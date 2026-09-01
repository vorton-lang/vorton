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

macro_rules! ast_tag_assertion {
    ($name:ident, $tag:literal) => {
        fn $name(program: &vorton::ast::Program) {
            let mut coverage = AstCoverage::default();
            coverage.visit_program(program);
            assert!(coverage.variants.contains($tag));
        }
    };
}

ast_tag_assertion!(assert_integer, "Expr::Integer");
ast_tag_assertion!(assert_float, "Expr::Float");
ast_tag_assertion!(assert_string, "Expr::String");
ast_tag_assertion!(assert_raw, "Expr::RawString");
ast_tag_assertion!(assert_bool, "Expr::Boolean");
ast_tag_assertion!(assert_interp, "Expr::InterpolatedString");
ast_tag_assertion!(assert_path_expr, "Expr::Path");
ast_tag_assertion!(assert_block_expr, "Expr::Block");
ast_tag_assertion!(assert_match_expr, "Expr::Match");
ast_tag_assertion!(assert_unsafe_expr, "Expr::Unsafe");
ast_tag_assertion!(assert_unary_expr, "Expr::Unary");

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

fn assert_any_named_literal(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::NamedLiteral { .. }));
}

fn assert_field_init(program: &vorton::ast::Program) {
    let Expr::NamedLiteral { fields, .. } = function_tail(program) else {
        panic!("named literal")
    };
    assert!(fields[0].shorthand);
    assert!(!fields[1].shorthand);
}

fn assert_punning_field(program: &vorton::ast::Program) {
    let Expr::NamedLiteral { fields, .. } = function_tail(program) else {
        panic!("named literal")
    };
    assert!(fields[0].shorthand);
}

fn assert_explicit_field(program: &vorton::ast::Program) {
    let Expr::NamedLiteral { fields, .. } = function_tail(program) else {
        panic!("named literal")
    };
    assert!(!fields[0].shorthand);
}

fn assert_list(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::List { elements, .. } if elements.len() == 2));
}

fn assert_any_list(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::List { .. }));
}

fn assert_tuple(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Tuple { elements, .. } if elements.len() == 2));
}

fn assert_unit(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Unit { .. }));
}

fn assert_parenthesized(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Parenthesized { .. }));
}

fn assert_any_tuple(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Tuple { .. }));
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

fn assert_any_if(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::If { .. }));
}

fn assert_match(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Match { arms, .. } if arms.len() == 2));
}

fn assert_any_match(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Match { .. }));
}

fn assert_guarded_arm(program: &vorton::ast::Program) {
    let Expr::Match { arms, .. } = function_tail(program) else {
        panic!("match")
    };
    assert!(arms[0].guard.is_some());
}

fn assert_unguarded_adjacent_arms(program: &vorton::ast::Program) {
    let Expr::Match { arms, .. } = function_tail(program) else {
        panic!("match")
    };
    assert_eq!(arms.len(), 2);
    assert!(arms.iter().all(|arm| arm.guard.is_none()));
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

fn assert_any_handle(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Handle { .. }));
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

fn assert_any_lambda(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Lambda { .. }));
}

fn assert_call_args(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Call { args, .. } if args.len() == 2));
}

fn assert_any_call(program: &vorton::ast::Program) {
    assert!(matches!(function_tail(program), Expr::Call { .. }));
}

#[rustfmt::skip]
const CASES: &[SyntaxCase] = &[
    SyntaxCase::valid("V.S.PrimaryExpr.all-alternatives", "S.PrimaryExpr", FULL_SURFACE, assert_primary_alternatives),
    SyntaxCase::valid("V.S.PrimaryExpr.int", "S.PrimaryExpr", "fn f() {1}", assert_integer),
    SyntaxCase::valid("V.S.PrimaryExpr.float", "S.PrimaryExpr", "fn f() {1.5}", assert_float),
    SyntaxCase::valid("V.S.PrimaryExpr.string", "S.PrimaryExpr", "fn f() {\"x\"}", assert_string),
    SyntaxCase::valid("V.S.PrimaryExpr.raw", "S.PrimaryExpr", "fn f() {r\"x\"}", assert_raw),
    SyntaxCase::valid("V.S.PrimaryExpr.true", "S.PrimaryExpr", "fn f() {true}", assert_bool),
    SyntaxCase::valid("V.S.PrimaryExpr.false", "S.PrimaryExpr", "fn f() {false}", assert_bool),
    SyntaxCase::valid("V.S.PrimaryExpr.interp", "S.PrimaryExpr", "fn f() {\"${x}\"}", assert_interp),
    SyntaxCase::valid("V.S.PrimaryExpr.path", "S.PrimaryExpr", "fn f() {value}", assert_path_expr),
    SyntaxCase::valid("V.S.PrimaryExpr.named-literal", "S.PrimaryExpr", "fn f() {Shape {}}", assert_any_named_literal),
    SyntaxCase::valid("V.S.PrimaryExpr.list", "S.PrimaryExpr", "fn f() {[]}", assert_any_list),
    SyntaxCase::valid("V.S.PrimaryExpr.tuple-or-paren", "S.PrimaryExpr", "fn f() {()}", assert_unit),
    SyntaxCase::valid("V.S.PrimaryExpr.block", "S.PrimaryExpr", "fn f() {{1}}", assert_block_expr),
    SyntaxCase::valid("V.S.PrimaryExpr.if", "S.PrimaryExpr", "fn f() {if true {1}}", assert_any_if),
    SyntaxCase::valid("V.S.PrimaryExpr.match", "S.PrimaryExpr", "fn f(x: T) {match x {}}", assert_match_expr),
    SyntaxCase::valid("V.S.PrimaryExpr.handle", "S.PrimaryExpr", "fn f() {handle {} with {io.op() => 1}}", assert_any_handle),
    SyntaxCase::valid("V.S.PrimaryExpr.lambda", "S.PrimaryExpr", "fn f() {fn() {1}}", assert_any_lambda),
    SyntaxCase::valid("V.S.PrimaryExpr.unsafe", "S.PrimaryExpr", "fn f() {unsafe {1}}", assert_unsafe_expr),
    SyntaxCase::valid("V.S.PrimaryExpr.unary", "S.PrimaryExpr", "fn f() {-1}", assert_unary_expr),
    SyntaxCase::invalid("I.S.PrimaryExpr.incomplete-if", "S.PrimaryExpr", "fn f() {if}", "E0101", "}"),
    SyntaxCase::valid("V.S.NamedLiteral.lowercase-path", "S.NamedLiteral", "fn f(base: shape) {shape {..base, x, y: 1,}}", assert_named_literal),
    SyntaxCase::valid("V.S.NamedLiteral.empty", "S.NamedLiteral", "fn f() {Shape {}}", assert_any_named_literal),
    SyntaxCase::valid("V.S.NamedLiteral.spread-only", "S.NamedLiteral", "fn f(base: Shape) {Shape {..base}}", assert_any_named_literal),
    SyntaxCase::valid("V.S.NamedLiteral.fields-only", "S.NamedLiteral", "fn f() {Shape {x: 1}}", assert_any_named_literal),
    SyntaxCase::valid("V.S.NamedLiteral.spread-and-fields", "S.NamedLiteral", "fn f(base: Shape) {Shape {..base, x: 1}}", assert_any_named_literal),
    SyntaxCase::invalid("I.S.NamedLiteral.missing-comma-after-spread", "S.NamedLiteral", "fn f(base: Shape) {Shape {..base x: 1}}", "E0103", "x"),
    SyntaxCase::invalid("I.S.NamedLiteral.missing-close", "S.NamedLiteral", "fn f() {shape {x: 1}", "E0103", ""),
    SyntaxCase::valid("V.S.NamedLiteralBody.spread-and-fields", "S.NamedLiteralBody", "fn f(base: shape) {shape {..base, x, y: 1,}}", assert_named_literal),
    SyntaxCase::valid("V.S.NamedLiteralBody.spread", "S.NamedLiteralBody", "fn f(base: Shape) {Shape {..base}}", assert_any_named_literal),
    SyntaxCase::valid("V.S.NamedLiteralBody.spread-trailing", "S.NamedLiteralBody", "fn f(base: Shape) {Shape {..base,}}", assert_any_named_literal),
    SyntaxCase::valid("V.S.NamedLiteralBody.spread-one-field", "S.NamedLiteralBody", "fn f(base: Shape) {Shape {..base, x: 1}}", assert_any_named_literal),
    SyntaxCase::valid("V.S.NamedLiteralBody.spread-many-fields", "S.NamedLiteralBody", "fn f(base: Shape) {Shape {..base, x: 1, y: 2}}", assert_any_named_literal),
    SyntaxCase::valid("V.S.NamedLiteralBody.one-field", "S.NamedLiteralBody", "fn f() {Shape {x: 1}}", assert_any_named_literal),
    SyntaxCase::valid("V.S.NamedLiteralBody.many-fields", "S.NamedLiteralBody", "fn f() {Shape {x: 1, y: 2}}", assert_any_named_literal),
    SyntaxCase::valid("V.S.NamedLiteralBody.trailing", "S.NamedLiteralBody", "fn f() {Shape {x: 1, y: 2,}}", assert_any_named_literal),
    SyntaxCase::invalid("I.S.NamedLiteralBody.leading-comma", "S.NamedLiteralBody", "fn f() {Shape {,x: 1}}", "E0103", ","),
    SyntaxCase::invalid("I.S.NamedLiteralBody.missing-comma-after-spread", "S.NamedLiteralBody", "fn f(base: shape) {shape {..base x: 1}}", "E0103", "x"),
    SyntaxCase::invalid("I.S.NamedLiteralBody.double-comma", "S.NamedLiteralBody", "fn f() {Shape {x: 1,,y: 2}}", "E0103", ","),
    SyntaxCase::valid("V.S.FieldInit.punning-and-explicit", "S.FieldInit", "fn f() {shape {x, y: 1}}", assert_field_init),
    SyntaxCase::valid("V.S.FieldInit.punning", "S.FieldInit", "fn f() {Shape {x}}", assert_punning_field),
    SyntaxCase::valid("V.S.FieldInit.explicit", "S.FieldInit", "fn f() {Shape {x: 1}}", assert_explicit_field),
    SyntaxCase::invalid("I.S.FieldInit.missing-value", "S.FieldInit", "fn f() {shape {x:}}", "E0101", "}"),
    SyntaxCase::valid("V.S.ListLit.many-trailing", "S.ListLit", "fn f() {[1, 2,]}", assert_list),
    SyntaxCase::valid("V.S.ListLit.zero", "S.ListLit", "fn f() {[]}", assert_any_list),
    SyntaxCase::valid("V.S.ListLit.one", "S.ListLit", "fn f() {[1]}", assert_any_list),
    SyntaxCase::valid("V.S.ListLit.many", "S.ListLit", "fn f() {[1, 2]}", assert_list),
    SyntaxCase::invalid("I.S.ListLit.leading-comma", "S.ListLit", "fn f() {[, 1]}", "E0101", ","),
    SyntaxCase::invalid("I.S.ListLit.double-comma", "S.ListLit", "fn f() {[1,,2]}", "E0101", ","),
    SyntaxCase::invalid("I.S.ListLit.missing-comma", "S.ListLit", "fn f() {[1 2]}", "E0103", "2"),
    SyntaxCase::valid("V.S.TupleOrParen.tuple-trailing", "S.TupleOrParen", "fn f() {(1, 2,)}", assert_tuple),
    SyntaxCase::valid("V.S.TupleOrParen.unit", "S.TupleOrParen", "fn f() {()}", assert_unit),
    SyntaxCase::valid("V.S.TupleOrParen.paren", "S.TupleOrParen", "fn f() {(1)}", assert_parenthesized),
    SyntaxCase::valid("V.S.TupleOrParen.tuple-two", "S.TupleOrParen", "fn f() {(1, 2)}", assert_tuple),
    SyntaxCase::valid("V.S.TupleOrParen.tuple-many", "S.TupleOrParen", "fn f() {(1, 2, 3)}", assert_any_tuple),
    SyntaxCase::invalid("I.S.TupleOrParen.leading-comma", "S.TupleOrParen", "fn f() {(,1)}", "E0101", ","),
    SyntaxCase::invalid("I.S.TupleOrParen.double-comma", "S.TupleOrParen", "fn f() {(1,,2)}", "E0101", ","),
    SyntaxCase::invalid("I.S.TupleOrParen.single-tuple", "S.TupleOrParen", "fn f() {(1,)}", "E0101", "(1,)"),
    SyntaxCase::valid("V.S.ExprList.many-trailing", "S.ExprList", "fn f() {(1, 2,)}", assert_tuple),
    SyntaxCase::valid("V.S.ExprList.one", "S.ExprList", "fn f() {(1, 2)}", assert_tuple),
    SyntaxCase::valid("V.S.ExprList.many", "S.ExprList", "fn f() {(1, 2, 3)}", assert_any_tuple),
    SyntaxCase::invalid("I.S.ExprList.empty", "S.ExprList", "fn f() {(1,)}", "E0101", "(1,)"),
    SyntaxCase::invalid("I.S.ExprList.leading-comma", "S.ExprList", "fn f() {(1,,2)}", "E0101", ","),
    SyntaxCase::invalid("I.S.ExprList.double-comma", "S.ExprList", "fn f() {(1,2,,3)}", "E0101", ","),
    SyntaxCase::invalid("I.S.ExprList.missing-comma", "S.ExprList", "fn f() {(1 2)}", "E0103", "2"),
    SyntaxCase::valid("V.S.IfExpr.else-if", "S.IfExpr", "fn f() {if true {1} else if false {2} else {3}}", assert_if),
    SyntaxCase::valid("V.S.IfExpr.no-else", "S.IfExpr", "fn f() {if true {1}}", assert_any_if),
    SyntaxCase::valid("V.S.IfExpr.else-block", "S.IfExpr", "fn f() {if true {1} else {2}}", assert_if),
    SyntaxCase::invalid("I.S.IfExpr.missing-condition", "S.IfExpr", "fn f() {if}", "E0101", "}"),
    SyntaxCase::invalid("I.S.IfExpr.missing-block", "S.IfExpr", "fn f() {if true}", "E0103", "}"),
    SyntaxCase::invalid("I.S.IfExpr.dangling-else", "S.IfExpr", "fn f() {if true {} else}", "E0103", "}"),
    SyntaxCase::valid("V.S.MatchExpr.many-arm", "S.MatchExpr", "fn f(x: T) {match x {A => 1, B => 2,}}", assert_match),
    SyntaxCase::valid("V.S.MatchExpr.zero-arm", "S.MatchExpr", "fn f(x: T) {match x {}}", assert_any_match),
    SyntaxCase::valid("V.S.MatchExpr.one-arm", "S.MatchExpr", "fn f(x: T) {match x {A => 1}}", assert_any_match),
    SyntaxCase::invalid("I.S.MatchExpr.missing-brace", "S.MatchExpr", "fn f(x: T) {match x", "E0103", ""),
    SyntaxCase::invalid("I.S.MatchExpr.missing-scrutinee", "S.MatchExpr", "fn f() {match}", "E0101", "}"),
    SyntaxCase::valid("V.S.MatchArm.guard-comma", "S.MatchArm", "fn f(x: T) {match x {A if true => 1,}}", assert_guarded_arm),
    SyntaxCase::valid("V.S.MatchArm.guard-no-comma", "S.MatchArm", "fn f(x: T) {match x {A if true => 1}}", assert_guarded_arm),
    SyntaxCase::valid("V.S.MatchArm.plain", "S.MatchArm", "fn f(x: T) {match x {A => 1}}", assert_any_match),
    SyntaxCase::valid("V.S.MatchArm.guard", "S.MatchArm", "fn f(x: T) {match x {A if true => 1}}", assert_guarded_arm),
    SyntaxCase::valid("V.S.MatchArm.comma", "S.MatchArm", "fn f(x: T) {match x {A => 1,}}", assert_any_match),
    SyntaxCase::valid("V.S.MatchArm.no-comma", "S.MatchArm", "fn f(x: T) {match x {A => 1}}", assert_any_match),
    SyntaxCase::invalid("I.S.MatchArm.missing-pattern", "S.MatchArm", "fn f(x: T) {match x {=> 1}}", "E0101", "=>"),
    SyntaxCase::valid("V.S.MatchArm.no-guard-no-comma", "S.MatchArm", "fn f(x: T) {match x {A => 1 B => 2}}", assert_unguarded_adjacent_arms),
    SyntaxCase::valid("V.S.MatchArm.no-guard-comma", "S.MatchArm", "fn f(x: T) {match x {A => 1, B => 2,}}", assert_unguarded_adjacent_arms),
    SyntaxCase::invalid("I.S.MatchArm.missing-arrow", "S.MatchArm", "fn f(x: T) {match x {A 1}}", "E0103", "1"),
    SyntaxCase::invalid("I.S.MatchArm.missing-body", "S.MatchArm", "fn f(x: T) {match x {A =>}}", "E0101", "}"),
    SyntaxCase::valid("V.S.ArmBody.expr-and-return", "S.ArmBody", "fn f(x: T) {match x {A => return 1, B => return,}}", assert_return_arm),
    SyntaxCase::valid("V.S.ArmBody.expr", "S.ArmBody", "fn f(x: T) {match x {A => 1}}", assert_any_match),
    SyntaxCase::valid("V.S.ArmBody.return-bare", "S.ArmBody", "fn f(x: T) {match x {A => return}}", assert_any_match),
    SyntaxCase::valid("V.S.ArmBody.return-value", "S.ArmBody", "fn f(x: T) {match x {A => return 1}}", assert_any_match),
    SyntaxCase::invalid("I.S.ArmBody.missing-after-arrow", "S.ArmBody", "fn f(x: T) {match x {A => }}", "E0101", "}"),
    SyntaxCase::valid("V.S.ReturnExpr.bare-and-value", "S.ReturnExpr", "fn f(x: T) {match x {A => return 1, B => return,}}", assert_return_arm),
    SyntaxCase::valid("V.S.ReturnExpr.bare", "S.ReturnExpr", "fn f(x: T) {match x {A => return}}", assert_any_match),
    SyntaxCase::valid("V.S.ReturnExpr.value", "S.ReturnExpr", "fn f(x: T) {match x {A => return 1}}", assert_any_match),
    SyntaxCase::invalid("I.S.ReturnExpr.semicolon-in-arm-body", "S.ReturnExpr", "fn f(x: T) {match x {A => return;}}", "E0101", ";"),
    SyntaxCase::valid("V.S.OrPattern.many", "S.OrPattern", "fn f(x: T) {match x {A | B => 1}}", assert_or_pattern),
    SyntaxCase::valid("V.S.OrPattern.one", "S.OrPattern", "fn f(x: T) {match x {A => 1}}", assert_any_match),
    SyntaxCase::invalid("I.S.OrPattern.leading-pipe", "S.OrPattern", "fn f(x: T) {match x {| A => 1}}", "E0101", "|"),
    SyntaxCase::invalid("I.S.OrPattern.trailing-pipe", "S.OrPattern", "fn f(x: T) {match x {A | => 1}}", "E0101", "=>"),
    SyntaxCase::invalid("I.S.OrPattern.double-pipe", "S.OrPattern", "fn f(x: T) {match x {A | | B => 1}}", "E0101", "|"),
    SyntaxCase::invalid("I.S.OrPattern.nested-pipe", "S.OrPattern", "fn f(x: T) {match x {some(A | B) => 1}}", "E0103", "|"),
    SyntaxCase::valid("V.S.Guard.minimal", "S.Guard", "fn f(x: T) {match x {A if true => 1}}", assert_guarded_arm),
    SyntaxCase::invalid("I.S.Guard.missing-expression", "S.Guard", "fn f(x: T) {match x {A if => 1}}", "E0101", "=>"),
    SyntaxCase::valid("V.S.HandleExpr.many-trailing", "S.HandleExpr", "fn f() {handle {} with {io.a() => 1, io.b() => 2,}}", assert_handle),
    SyntaxCase::valid("V.S.HandleExpr.one-handler", "S.HandleExpr", "fn f() {handle {} with {io.a() => 1}}", assert_any_handle),
    SyntaxCase::valid("V.S.HandleExpr.many", "S.HandleExpr", "fn f() {handle {} with {io.a() => 1, io.b() => 2}}", assert_handle),
    SyntaxCase::invalid("I.S.HandleExpr.empty", "S.HandleExpr", "fn f() {handle {} with {}}", "E0101", "}"),
    SyntaxCase::invalid("I.S.HandleExpr.missing-comma", "S.HandleExpr", "fn f() {handle {} with {io.a() => 1 io.b() => 2}}", "E0103", "io"),
    SyntaxCase::invalid("I.S.HandleExpr.double-comma", "S.HandleExpr", "fn f() {handle {} with {io.a() => 1,, io.b() => 2}}", "E0103", ","),
    SyntaxCase::invalid("I.S.HandleExpr.missing-with", "S.HandleExpr", "fn f() {handle {}}", "E0103", "}"),
    SyntaxCase::valid("V.S.Handler.typed-untyped", "S.Handler", "fn f() {handle {} with {module::io.op(a: Int, b) => 1}}", assert_handler_path),
    SyntaxCase::valid("V.S.Handler.zero-params", "S.Handler", "fn f() {handle {} with {io.op() => 1}}", assert_any_handle),
    SyntaxCase::valid("V.S.Handler.one-param", "S.Handler", "fn f() {handle {} with {io.op(a) => 1}}", assert_any_handle),
    SyntaxCase::valid("V.S.Handler.many-params", "S.Handler", "fn f() {handle {} with {io.op(a, b) => 1}}", assert_any_handle),
    SyntaxCase::valid("V.S.Handler.typed", "S.Handler", "fn f() {handle {} with {io.op(a: Int) => 1}}", assert_any_handle),
    SyntaxCase::valid("V.S.Handler.untyped", "S.Handler", "fn f() {handle {} with {io.op(a) => 1}}", assert_any_handle),
    SyntaxCase::invalid("I.S.Handler.missing-dot", "S.Handler", "fn f() {handle {} with {io op() => 1}}", "E0103", "op"),
    SyntaxCase::invalid("I.S.Handler.missing-op", "S.Handler", "fn f() {handle {} with {io.() => 1}}", "E0103", "("),
    SyntaxCase::invalid("I.S.Handler.missing-arrow", "S.Handler", "fn f() {handle {} with {io.op() 1}}", "E0103", "1"),
    SyntaxCase::invalid("I.S.Handler.default-param", "S.Handler", "fn f() {handle {} with {io.op(a = 1) => 1}}", "E0101", "="),
    SyntaxCase::valid("V.S.LambdaExpr.return", "S.LambdaExpr", "fn f() {fn(a: Int, b) -> Int {a}}", assert_lambda),
    SyntaxCase::valid("V.S.LambdaExpr.zero-params", "S.LambdaExpr", "fn f() {fn() {1}}", assert_any_lambda),
    SyntaxCase::valid("V.S.LambdaExpr.one-param", "S.LambdaExpr", "fn f() {fn(a) {a}}", assert_any_lambda),
    SyntaxCase::valid("V.S.LambdaExpr.many-params", "S.LambdaExpr", "fn f() {fn(a, b) {a}}", assert_any_lambda),
    SyntaxCase::valid("V.S.LambdaExpr.no-return", "S.LambdaExpr", "fn f() {fn(a) {a}}", assert_any_lambda),
    SyntaxCase::invalid("I.S.LambdaExpr.missing-block", "S.LambdaExpr", "fn f() {fn(a)}", "E0103", "}"),
    SyntaxCase::invalid("I.S.LambdaExpr.default-param", "S.LambdaExpr", "fn f() {fn(a = 1) {a}}", "E0101", "="),
    SyntaxCase::valid("V.S.ArgList.many-trailing", "S.ArgList", "fn f() {call(1, 2,)}", assert_call_args),
    SyntaxCase::valid("V.S.ArgList.zero", "S.ArgList", "fn f() {call()}", assert_any_call),
    SyntaxCase::valid("V.S.ArgList.one", "S.ArgList", "fn f() {call(1)}", assert_any_call),
    SyntaxCase::valid("V.S.ArgList.many", "S.ArgList", "fn f() {call(1, 2)}", assert_call_args),
    SyntaxCase::invalid("I.S.ArgList.leading-comma", "S.ArgList", "fn f() {call(,1)}", "E0101", ","),
    SyntaxCase::invalid("I.S.ArgList.double-comma", "S.ArgList", "fn f() {call(1,,2)}", "E0101", ","),
    SyntaxCase::invalid("I.S.ArgList.missing-comma", "S.ArgList", "fn f() {call(1 2)}", "E0103", "2"),
];

pub(crate) fn cases() -> &'static [SyntaxCase] {
    CASES
}

#[test]
fn expression_grammar_cases_are_executable() {
    run_syntax_cases(CASES);
}
