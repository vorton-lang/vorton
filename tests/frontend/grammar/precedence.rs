use vorton::ast::{BinaryOp, Decl, Expr, Stmt, UnaryOp};

use super::manifest::{SyntaxCase, run_syntax_cases};

fn function_body(program: &vorton::ast::Program) -> &Expr {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    &function.body
}

fn tail(program: &vorton::ast::Program) -> &Expr {
    let Expr::Block {
        tail: Some(tail), ..
    } = function_body(program)
    else {
        panic!("tail")
    };
    tail
}

fn assert_expr(program: &vorton::ast::Program) {
    assert!(matches!(tail(program), Expr::Integer { .. }));
}

fn assert_or(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Binary {
            op: BinaryOp::Or,
            ..
        }
    ));
}

fn assert_and(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Binary {
            op: BinaryOp::And,
            ..
        }
    ));
}

fn assert_equal(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Binary {
            op: BinaryOp::Equal,
            ..
        }
    ));
}

fn assert_compare(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Binary {
            op: BinaryOp::Less,
            ..
        }
    ));
}

fn assert_postfix(program: &vorton::ast::Program) {
    assert!(matches!(tail(program), Expr::Index { .. }));
}

fn assert_field(program: &vorton::ast::Program) {
    assert!(matches!(tail(program), Expr::FieldAccess { .. }));
}

fn assert_postfix_over_unary(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Unary {
            op: UnaryOp::Negate,
            operand,
            ..
        } if matches!(operand.as_ref(), Expr::FieldAccess { .. })
    ));
}

fn assert_unary_over_mul(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Binary {
            op: BinaryOp::Multiply,
            left,
            ..
        } if matches!(left.as_ref(), Expr::Unary { .. })
    ));
}

fn assert_mul_over_add(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Binary {
            op: BinaryOp::Add,
            right,
            ..
        } if matches!(right.as_ref(), Expr::Binary { op: BinaryOp::Multiply, .. })
    ));
}

fn assert_add_over_range(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Range { end, .. }
            if matches!(end.as_ref(), Expr::Binary { op: BinaryOp::Add, .. })
    ));
}

fn assert_range_over_compare(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Binary {
            op: BinaryOp::Less,
            left,
            right,
            ..
        } if matches!(left.as_ref(), Expr::Range { .. })
            && matches!(right.as_ref(), Expr::Range { .. })
    ));
}

fn assert_compare_over_equality(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Binary {
            op: BinaryOp::Equal,
            left,
            right,
            ..
        } if matches!(left.as_ref(), Expr::Binary { op: BinaryOp::Less, .. })
            && matches!(right.as_ref(), Expr::Binary { op: BinaryOp::Less, .. })
    ));
}

fn assert_equality_over_and(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Binary {
            op: BinaryOp::And,
            left,
            right,
            ..
        } if matches!(left.as_ref(), Expr::Binary { op: BinaryOp::Equal, .. })
            && matches!(right.as_ref(), Expr::Binary { op: BinaryOp::Equal, .. })
    ));
}

fn assert_and_over_or(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Binary {
            op: BinaryOp::Or,
            left,
            ..
        } if matches!(left.as_ref(), Expr::Binary { op: BinaryOp::And, .. })
    ));
}

fn assert_or_over_catch(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Catch { expression, .. }
            if matches!(expression.as_ref(), Expr::Binary { op: BinaryOp::Or, .. })
    ));
}

fn assert_left_binary(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Binary { left, .. } if matches!(left.as_ref(), Expr::Binary { .. })
    ));
}

fn assert_left_range(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Range { start, .. } if matches!(start.as_ref(), Expr::Range { .. })
    ));
}

fn assert_right_unary(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Unary { operand, .. } if matches!(operand.as_ref(), Expr::Unary { .. })
    ));
}

fn assert_left_postfix(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Index { receiver, .. } if matches!(receiver.as_ref(), Expr::MethodCall { .. })
    ));
}

fn assert_left_catch(program: &vorton::ast::Program) {
    assert!(matches!(
        tail(program),
        Expr::Catch { expression, .. } if matches!(expression.as_ref(), Expr::Catch { .. })
    ));
}

fn assert_same_line_call(program: &vorton::ast::Program) {
    assert!(matches!(tail(program), Expr::Call { .. }));
}

fn assert_next_line_not_call(program: &vorton::ast::Program) {
    let Expr::Block {
        statements,
        tail: Some(tail),
        ..
    } = function_body(program)
    else {
        panic!("block")
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

fn assert_same_line_method(program: &vorton::ast::Program) {
    assert!(matches!(tail(program), Expr::MethodCall { .. }));
}

fn assert_next_line_method_split(program: &vorton::ast::Program) {
    let Expr::Block {
        statements,
        tail: Some(tail),
        ..
    } = function_body(program)
    else {
        panic!("block")
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

#[rustfmt::skip]
const CASES: &[SyntaxCase] = &[
    SyntaxCase::valid("V.S.Expr.integer", "S.Expr", "fn f() {1}", assert_expr),
    SyntaxCase::invalid("I.S.Expr.missing", "S.Expr", "fn f() {let x = }", "E0101", "}"),
    SyntaxCase::valid("V.S.CatchExpr.left-chain", "S.CatchExpr", "fn f() {x catch {} catch {}}", assert_left_catch),
    SyntaxCase::invalid("I.S.CatchExpr.missing-arm-group", "S.CatchExpr", "fn f() {x catch}", "E0103", "}"),
    SyntaxCase::valid("V.S.LogicOrExpr.many", "S.LogicOrExpr", "fn f() {a || b || c}", assert_or),
    SyntaxCase::invalid("I.S.LogicOrExpr.single-pipe", "S.LogicOrExpr", "fn f() {a | b}", "E0101", "|"),
    SyntaxCase::valid("V.S.LogicAndExpr.many", "S.LogicAndExpr", "fn f() {a && b && c}", assert_and),
    SyntaxCase::invalid("I.S.LogicAndExpr.single-amp", "S.LogicAndExpr", "fn f() {a & b}", "E0101", "&"),
    SyntaxCase::valid("V.S.EqualityExpr.one", "S.EqualityExpr", "fn f() {a == b}", assert_equal),
    SyntaxCase::invalid("I.S.EqualityExpr.chain", "S.EqualityExpr", "fn f() {a == b == c}", "E0101", "=="),
    SyntaxCase::valid("V.S.CompareExpr.one", "S.CompareExpr", "fn f() {a < b}", assert_compare),
    SyntaxCase::invalid("I.S.CompareExpr.chain", "S.CompareExpr", "fn f() {a < b < c}", "E0101", "<"),
    SyntaxCase::valid("V.S.RangeExpr.left-chain", "S.RangeExpr", "fn f() {1..2..3}", assert_left_range),
    SyntaxCase::invalid("I.S.RangeExpr.missing-end", "S.RangeExpr", "fn f() {1..}", "E0101", "}"),
    SyntaxCase::valid("V.S.AddExpr.left", "S.AddExpr", "fn f() {1 + 2 + 3}", assert_left_binary),
    SyntaxCase::invalid("I.S.AddExpr.missing-right", "S.AddExpr", "fn f() {1 +}", "E0101", "}"),
    SyntaxCase::valid("V.S.MulExpr.left", "S.MulExpr", "fn f() {1 * 2 * 3}", assert_left_binary),
    SyntaxCase::invalid("I.S.MulExpr.missing-right", "S.MulExpr", "fn f() {1 *}", "E0101", "}"),
    SyntaxCase::valid("V.S.UnaryExpr.nested-right", "S.UnaryExpr", "fn f() {-!value}", assert_right_unary),
    SyntaxCase::invalid("I.S.UnaryExpr.missing-operand", "S.UnaryExpr", "fn f() {!}", "E0101", "}"),
    SyntaxCase::valid("V.S.PostfixExpr.long-chain", "S.PostfixExpr", "fn f() {value.method()[0]}", assert_postfix),
    SyntaxCase::invalid("I.S.PostfixExpr.missing-index-close", "S.PostfixExpr", "fn f() {value[0}", "E0103", "}"),
    SyntaxCase::valid("V.S.PostfixPart.field", "S.PostfixPart", "fn f() {value.field}", assert_field),
    SyntaxCase::invalid("I.S.PostfixPart.missing-field", "S.PostfixPart", "fn f() {value.}", "E0103", "}"),
    SyntaxCase::context_valid("C.expr.precedence.postfix-over-unary", "fn f() {-value.field}", assert_postfix_over_unary),
    SyntaxCase::context_valid("C.expr.precedence.unary-over-mul", "fn f() {-1 * 2}", assert_unary_over_mul),
    SyntaxCase::context_valid("C.expr.precedence.mul-over-add", "fn f() {1 + 2 * 3}", assert_mul_over_add),
    SyntaxCase::context_valid("C.expr.precedence.add-over-range", "fn f() {1..2 + 3}", assert_add_over_range),
    SyntaxCase::context_valid("C.expr.precedence.range-over-compare", "fn f() {1..2 < 3..4}", assert_range_over_compare),
    SyntaxCase::context_valid("C.expr.precedence.compare-over-equality", "fn f() {1 < 2 == 3 < 4}", assert_compare_over_equality),
    SyntaxCase::context_valid("C.expr.precedence.equality-over-and", "fn f() {1 == 2 && 3 == 4}", assert_equality_over_and),
    SyntaxCase::context_valid("C.expr.precedence.and-over-or", "fn f() {a && b || c}", assert_and_over_or),
    SyntaxCase::context_valid("C.expr.precedence.or-over-catch", "fn f() {a || b catch {}}", assert_or_over_catch),
    SyntaxCase::context_valid("C.expr.assoc.catch-left", "fn f() {x catch {} catch {}}", assert_left_catch),
    SyntaxCase::context_valid("C.expr.assoc.or-left", "fn f() {a || b || c}", assert_left_binary),
    SyntaxCase::context_valid("C.expr.assoc.and-left", "fn f() {a && b && c}", assert_left_binary),
    SyntaxCase::context_valid("C.expr.assoc.range-left", "fn f() {1..2..3}", assert_left_range),
    SyntaxCase::context_valid("C.expr.assoc.add-left", "fn f() {1 + 2 + 3}", assert_left_binary),
    SyntaxCase::context_valid("C.expr.assoc.mul-left", "fn f() {1 * 2 * 3}", assert_left_binary),
    SyntaxCase::context_valid("C.expr.assoc.unary-right", "fn f() {-!value}", assert_right_unary),
    SyntaxCase::context_valid("C.expr.assoc.postfix-left", "fn f() {value.method()[0]}", assert_left_postfix),
    SyntaxCase::context_invalid("C.expr.nonassoc.equality-chain-rejected", "fn f() {a == b == c}", "E0101", "=="),
    SyntaxCase::context_invalid("C.expr.nonassoc.compare-chain-rejected", "fn f() {a < b < c}", "E0101", "<"),
    SyntaxCase::context_valid("C.expr.nonassoc.mixed-equality-compare-structural", "fn f() {1 < 2 == 3 < 4}", assert_compare_over_equality),
    SyntaxCase::context_valid("C.expr.call.same-line", "fn f() {call(1)}", assert_same_line_call),
    SyntaxCase::context_valid("C.expr.call.next-line-not-call", "fn f() {call\n(1)}", assert_next_line_not_call),
    SyntaxCase::context_valid("C.expr.method-call.same-line", "fn f() {value.method(1)}", assert_same_line_method),
    SyntaxCase::context_valid("C.expr.method-call.next-line-is-field-then-paren", "fn f() {value.method\n(1)}", assert_next_line_method_split),
    SyntaxCase::context_valid("C.expr.index-cross-line", "fn f() {value\n[0]}", assert_postfix),
    SyntaxCase::context_valid("C.expr.dot-cross-line", "fn f() {value\n.field}", assert_field),
];

pub(crate) fn cases() -> &'static [SyntaxCase] {
    CASES
}

#[test]
fn precedence_and_associativity_cases_are_structural() {
    run_syntax_cases(CASES);
}
