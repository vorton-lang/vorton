use vorton::ast::{AssignOp, Decl, Expr, ForBinding, Pattern, Stmt};

use super::coverage::AstCoverage;
use super::manifest::{SyntaxCase, run_syntax_cases};

const FULL_SURFACE: &str = include_str!("../fixtures/full_surface.vorton");

fn function_statements(program: &vorton::ast::Program) -> &[Stmt] {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    let Expr::Block { statements, .. } = &function.body else {
        panic!("block")
    };
    statements
}

fn assert_all_stmt_alternatives(program: &vorton::ast::Program) {
    let mut coverage = AstCoverage::default();
    coverage.visit_program(program);
    for tag in [
        "Stmt::Let",
        "Stmt::IfLet",
        "Stmt::Return",
        "Stmt::While",
        "Stmt::Loop",
        "Stmt::For",
        "Stmt::Break",
        "Stmt::Continue",
        "Stmt::Assign",
        "Stmt::Expression",
    ] {
        assert!(coverage.variants.contains(tag), "missing {tag}");
    }
}

fn assert_let_name(program: &vorton::ast::Program) {
    assert!(matches!(
        function_statements(program)[0],
        Stmt::Let {
            pattern: Pattern::Name { .. },
            ..
        }
    ));
}

fn assert_let_constructor(program: &vorton::ast::Program) {
    assert!(matches!(
        function_statements(program)[0],
        Stmt::Let {
            pattern: Pattern::Constructor { .. },
            ..
        }
    ));
}

fn assert_let_nested_tuple(program: &vorton::ast::Program) {
    let Stmt::Let { pattern, .. } = &function_statements(program)[0] else {
        panic!("let")
    };
    let Pattern::Tuple { elements, .. } = pattern else {
        panic!("tuple pattern")
    };
    assert_eq!(elements.len(), 2);
    assert!(matches!(elements[1], Pattern::Tuple { .. }));
}

fn assert_let_mut_typed(program: &vorton::ast::Program) {
    assert!(matches!(
        function_statements(program)[0],
        Stmt::Let {
            mutable: true,
            pattern: Pattern::Name { .. },
            type_annotation: Some(_),
            ..
        }
    ));
}

fn assert_let_mut_name(program: &vorton::ast::Program) {
    assert!(matches!(
        function_statements(program)[0],
        Stmt::Let {
            mutable: true,
            pattern: Pattern::Name { .. },
            ..
        }
    ));
}

fn assert_tuple_let(program: &vorton::ast::Program) {
    assert!(matches!(
        function_statements(program)[0],
        Stmt::Let {
            pattern: Pattern::Tuple { .. },
            ..
        }
    ));
}

macro_rules! first_stmt_assertion {
    ($name:ident, $pattern:pat) => {
        fn $name(program: &vorton::ast::Program) {
            assert!(matches!(
                function_statements(program).first(),
                Some($pattern)
            ));
        }
    };
}

first_stmt_assertion!(assert_if_let, Stmt::IfLet { .. });
first_stmt_assertion!(assert_while, Stmt::While { .. });
first_stmt_assertion!(assert_loop, Stmt::Loop { .. });
first_stmt_assertion!(assert_for, Stmt::For { .. });
first_stmt_assertion!(assert_expr_stmt, Stmt::Expression { .. });

fn assert_terminated_expression_statement(program: &vorton::ast::Program) {
    assert!(matches!(
        function_statements(program)[0],
        Stmt::Expression {
            has_semicolon: true,
            ..
        }
    ));
}

fn assert_unterminated_expression_is_tail(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    let Expr::Block {
        statements, tail, ..
    } = &function.body
    else {
        panic!("block")
    };
    assert!(statements.is_empty());
    assert!(matches!(tail.as_deref(), Some(Expr::Call { .. })));
}

fn assert_for_tuple(program: &vorton::ast::Program) {
    let Stmt::For { binding, .. } = &function_statements(program)[0] else {
        panic!("for")
    };
    assert!(matches!(binding, ForBinding::Tuple(names, _) if names.len() == 2));
}

fn assert_any_for_tuple(program: &vorton::ast::Program) {
    let Stmt::For { binding, .. } = &function_statements(program)[0] else {
        panic!("for")
    };
    assert!(matches!(binding, ForBinding::Tuple(_, _)));
}

fn assert_bare_return_then_let(program: &vorton::ast::Program) {
    let statements = function_statements(program);
    assert!(matches!(statements[0], Stmt::Return { value: None, .. }));
    assert!(matches!(statements[1], Stmt::Let { .. }));
}

fn assert_return_value(program: &vorton::ast::Program) {
    assert!(matches!(
        function_statements(program)[0],
        Stmt::Return { value: Some(_), .. }
    ));
}

fn assert_bare_return(program: &vorton::ast::Program) {
    assert!(matches!(
        function_statements(program)[0],
        Stmt::Return { value: None, .. }
    ));
}

fn assert_all_assign_ops(program: &vorton::ast::Program) {
    let statements = function_statements(program);
    let ops: Vec<_> = statements
        .iter()
        .filter_map(|statement| match statement {
            Stmt::Assign { op, .. } => Some(*op),
            _ => None,
        })
        .collect();
    assert_eq!(
        ops,
        [
            AssignOp::Assign,
            AssignOp::AddAssign,
            AssignOp::SubtractAssign,
            AssignOp::MultiplyAssign,
            AssignOp::DivideAssign,
            AssignOp::RemainderAssign,
        ]
    );
}

fn assert_any_assign(program: &vorton::ast::Program) {
    assert!(matches!(
        function_statements(program)[0],
        Stmt::Assign { .. }
    ));
}

fn assert_assignment_path(program: &vorton::ast::Program) {
    let Stmt::Assign { target, .. } = &function_statements(program)[0] else {
        panic!("assignment")
    };
    assert!(matches!(target, Expr::Path { path, .. } if path.segments.len() == 2));
}

fn assert_block(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    assert!(matches!(function.body, Expr::Block { .. }));
}

fn assert_unsafe(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    let Expr::Block {
        tail: Some(tail), ..
    } = &function.body
    else {
        panic!("tail")
    };
    assert!(matches!(tail.as_ref(), Expr::Unsafe { .. }));
}

const ASSIGNMENTS: &str = r#"
fn f() {
    x = 1
    x += 1
    x -= 1
    x *= 1
    x /= 1
    x %= 1
}
"#;

#[rustfmt::skip]
const CASES: &[SyntaxCase] = &[
    SyntaxCase::valid("V.S.Stmt.all-alternatives", "S.Stmt", FULL_SURFACE, assert_all_stmt_alternatives),
    SyntaxCase::invalid("I.S.Stmt.incomplete-let", "S.Stmt", "fn f() {let}", "E0103", "}"),
    SyntaxCase::valid("V.S.LetStmt.inferred", "S.LetStmt", "fn f() {let x = 1}", assert_let_name),
    SyntaxCase::valid("V.S.LetStmt.typed", "S.LetStmt", "fn f() {let x: Int = 1}", assert_let_name),
    SyntaxCase::valid("V.S.LetStmt.semicolon", "S.LetStmt", "fn f() {let x = 1;}", assert_let_name),
    SyntaxCase::valid("V.S.LetStmt.no-semicolon", "S.LetStmt", "fn f() {let x = 1}", assert_let_name),
    SyntaxCase::invalid("I.S.LetStmt.missing-name", "S.LetStmt", "fn f() {let = 1}", "E0103", "="),
    SyntaxCase::invalid("I.S.LetStmt.missing-equals", "S.LetStmt", "fn f() {let x 1}", "E0103", "1"),
    SyntaxCase::invalid("I.S.LetStmt.missing-value", "S.LetStmt", "fn f() {let x =}", "E0101", "}"),
    SyntaxCase::valid("V.S.LetMutStmt.typed", "S.LetMutStmt", "fn f() {let mut x: Int = 1}", assert_let_mut_typed),
    SyntaxCase::valid("V.S.LetMutStmt.inferred", "S.LetMutStmt", "fn f() {let mut x = 1}", assert_let_mut_name),
    SyntaxCase::valid("V.S.LetMutStmt.semicolon", "S.LetMutStmt", "fn f() {let mut x: Int = 1;}", assert_let_mut_typed),
    SyntaxCase::valid("V.S.LetMutStmt.no-semicolon", "S.LetMutStmt", "fn f() {let mut x: Int = 1}", assert_let_mut_typed),
    SyntaxCase::invalid("I.S.LetMutStmt.missing-name", "S.LetMutStmt", "fn f() {let mut = 1}", "E0103", "="),
    SyntaxCase::invalid("I.S.LetMutStmt.missing-equals", "S.LetMutStmt", "fn f() {let mut x 1}", "E0103", "1"),
    SyntaxCase::invalid("I.S.LetMutStmt.missing-value", "S.LetMutStmt", "fn f() {let mut x =}", "E0101", "}"),
    SyntaxCase::invalid("I.S.LetMutStmt.pattern", "S.LetMutStmt", "fn f() {let mut (x, y) = pair}", "E0101", "("),
    SyntaxCase::valid("V.S.LetPattern.constructor", "S.LetPattern", "fn f() {let some(x) = value}", assert_let_constructor),
    SyntaxCase::valid("V.S.LetPattern.nested-tuple", "S.LetPattern", "fn f() {let (x, (y, z),) = value}", assert_let_nested_tuple),
    SyntaxCase::valid("V.S.LetPattern.two", "S.LetPattern", "fn f() {let (x, y) = value}", assert_tuple_let),
    SyntaxCase::valid("V.S.LetPattern.many", "S.LetPattern", "fn f() {let (x, y, z) = value}", assert_tuple_let),
    SyntaxCase::valid("V.S.LetPattern.trailing", "S.LetPattern", "fn f() {let (x, y,) = value}", assert_tuple_let),
    SyntaxCase::invalid("I.S.LetPattern.empty", "S.LetPattern", "fn f() {let () = value}", "E0101", ")"),
    SyntaxCase::invalid("I.S.LetPattern.one", "S.LetPattern", "fn f() {let (x,) = value}", "E0101", "("),
    SyntaxCase::invalid("I.S.LetPattern.missing-equals", "S.LetPattern", "fn f() {let (x, y) value}", "E0103", "value"),
    SyntaxCase::invalid("I.S.LetPattern.or-is-arm-only", "S.LetPattern", "fn f() {let A | B = value}", "E0103", "|"),
    SyntaxCase::valid("V.S.IfLetStmt.with-else", "S.IfLetStmt", "fn f() {if let some(x) = value {} else {}}", assert_if_let),
    SyntaxCase::valid("V.S.IfLetStmt.without-else", "S.IfLetStmt", "fn f() {if let x = value {}}", assert_if_let),
    SyntaxCase::invalid("I.S.IfLetStmt.missing-pattern", "S.IfLetStmt", "fn f() {if let = value {}}", "E0101", "="),
    SyntaxCase::invalid("I.S.IfLetStmt.missing-equals", "S.IfLetStmt", "fn f() {if let x value {}}", "E0103", "value"),
    SyntaxCase::invalid("I.S.IfLetStmt.missing-block", "S.IfLetStmt", "fn f() {if let x = value}", "E0103", "}"),
    SyntaxCase::valid("V.S.WhileStmt.minimal", "S.WhileStmt", "fn f() {while true {}}", assert_while),
    SyntaxCase::invalid("I.S.WhileStmt.missing-condition", "S.WhileStmt", "fn f() {while}", "E0101", "}"),
    SyntaxCase::invalid("I.S.WhileStmt.missing-block", "S.WhileStmt", "fn f() {while true}", "E0103", "}"),
    SyntaxCase::valid("V.S.LoopStmt.minimal", "S.LoopStmt", "fn f() {loop {}}", assert_loop),
    SyntaxCase::invalid("I.S.LoopStmt.missing-block", "S.LoopStmt", "fn f() {loop value}", "E0103", "value"),
    SyntaxCase::valid("V.S.ForInStmt.tuple", "S.ForInStmt", "fn f() {for (x, y,) in items {}}", assert_for),
    SyntaxCase::valid("V.S.ForInStmt.name", "S.ForInStmt", "fn f() {for x in items {}}", assert_for),
    SyntaxCase::invalid("I.S.ForInStmt.missing-in", "S.ForInStmt", "fn f() {for x items {}}", "E0103", "items"),
    SyntaxCase::invalid("I.S.ForInStmt.missing-iterable", "S.ForInStmt", "fn f() {for x in}", "E0101", "}"),
    SyntaxCase::invalid("I.S.ForInStmt.missing-block", "S.ForInStmt", "fn f() {for x in items}", "E0103", "}"),
    SyntaxCase::valid("V.S.ForBinding.tuple-trailing", "S.ForBinding", "fn f() {for (x, y,) in items {}}", assert_for_tuple),
    SyntaxCase::valid("V.S.ForBinding.name", "S.ForBinding", "fn f() {for x in items {}}", assert_for),
    SyntaxCase::valid("V.S.ForBinding.tuple-two", "S.ForBinding", "fn f() {for (x, y) in items {}}", assert_for_tuple),
    SyntaxCase::valid("V.S.ForBinding.tuple-many", "S.ForBinding", "fn f() {for (x, y, z) in items {}}", assert_any_for_tuple),
    SyntaxCase::invalid("I.S.ForBinding.tuple-empty", "S.ForBinding", "fn f() {for () in items {}}", "E0103", ")"),
    SyntaxCase::invalid("I.S.ForBinding.tuple-one", "S.ForBinding", "fn f() {for (x) in items {}}", "E0101", "(x)"),
    SyntaxCase::invalid("I.S.ForBinding.missing-comma", "S.ForBinding", "fn f() {for (x y) in items {}}", "E0103", "y"),
    SyntaxCase::valid("V.S.BreakStmt.semicolon", "S.BreakStmt", "fn f() {loop {break;}}", assert_loop),
    SyntaxCase::valid("V.S.BreakStmt.no-semicolon", "S.BreakStmt", "fn f() {loop {break}}", assert_loop),
    SyntaxCase::invalid("I.S.BreakStmt.expression-after-break", "S.BreakStmt", "fn f() {loop {break 1}}", "E0101", "1"),
    SyntaxCase::valid("V.S.ContinueStmt.no-semicolon", "S.ContinueStmt", "fn f() {loop {continue}}", assert_loop),
    SyntaxCase::valid("V.S.ContinueStmt.semicolon", "S.ContinueStmt", "fn f() {loop {continue;}}", assert_loop),
    SyntaxCase::invalid("I.S.ContinueStmt.expression-after-continue", "S.ContinueStmt", "fn f() {loop {continue 1}}", "E0101", "1"),
    SyntaxCase::valid("V.S.ReturnStmt.bare-before-let", "S.ReturnStmt", "fn f() {return let x = 1}", assert_bare_return_then_let),
    SyntaxCase::valid("V.S.ReturnStmt.bare", "S.ReturnStmt", "fn f() {return}", assert_bare_return),
    SyntaxCase::valid("V.S.ReturnStmt.value", "S.ReturnStmt", "fn f() {return 1}", assert_return_value),
    SyntaxCase::valid("V.S.ReturnStmt.bare-semicolon", "S.ReturnStmt", "fn f() {return;}", assert_bare_return),
    SyntaxCase::valid("V.S.ReturnStmt.value-semicolon", "S.ReturnStmt", "fn f() {return 1;}", assert_return_value),
    SyntaxCase::invalid("I.S.ReturnStmt.double-semicolon", "S.ReturnStmt", "fn f() {return;;}", "E0101", ";"),
    SyntaxCase::valid("V.S.AssignStmt.all-operators", "S.AssignStmt", ASSIGNMENTS, assert_all_assign_ops),
    SyntaxCase::valid("V.S.AssignStmt.assign", "S.AssignStmt", "fn f() {x = 1}", assert_any_assign),
    SyntaxCase::valid("V.S.AssignStmt.add", "S.AssignStmt", "fn f() {x += 1}", assert_any_assign),
    SyntaxCase::valid("V.S.AssignStmt.subtract", "S.AssignStmt", "fn f() {x -= 1}", assert_any_assign),
    SyntaxCase::valid("V.S.AssignStmt.multiply", "S.AssignStmt", "fn f() {x *= 1}", assert_any_assign),
    SyntaxCase::valid("V.S.AssignStmt.divide", "S.AssignStmt", "fn f() {x /= 1}", assert_any_assign),
    SyntaxCase::valid("V.S.AssignStmt.remainder", "S.AssignStmt", "fn f() {x %= 1}", assert_any_assign),
    SyntaxCase::valid("V.S.AssignStmt.semicolon", "S.AssignStmt", "fn f() {x = 1;}", assert_any_assign),
    SyntaxCase::valid("V.S.AssignStmt.no-semicolon", "S.AssignStmt", "fn f() {x = 1}", assert_any_assign),
    SyntaxCase::invalid("I.S.AssignStmt.missing-value", "S.AssignStmt", "fn f() {x = }", "E0101", "}"),
    SyntaxCase::valid("V.S.AssignTarget.qualified-path", "S.AssignTarget", "fn f() {module::x = 1}", assert_assignment_path),
    SyntaxCase::valid("V.S.AssignTarget.ident", "S.AssignTarget", "fn f() {x = 1}", assert_any_assign),
    SyntaxCase::valid("V.S.AssignTarget.one-field", "S.AssignTarget", "fn f() {x.field = 1}", assert_any_assign),
    SyntaxCase::valid("V.S.AssignTarget.many-field", "S.AssignTarget", "fn f() {x.a.b = 1}", assert_any_assign),
    SyntaxCase::invalid("I.S.AssignTarget.index", "S.AssignTarget", "fn f() {xs[0] = 1}", "E0101", "xs[0]"),
    SyntaxCase::invalid("I.S.AssignTarget.call", "S.AssignTarget", "fn f() {call() = 1}", "E0101", "call()"),
    SyntaxCase::invalid("I.S.AssignTarget.tuple-field-root", "S.AssignTarget", "fn f() {(x, y).field = 1}", "E0101", "(x, y).field"),
    SyntaxCase::valid("V.S.ExprStmt.semicolon", "S.ExprStmt", "fn f() {call();}", assert_expr_stmt),
    SyntaxCase::valid("V.S.ExprStmt.terminated", "S.ExprStmt", "fn f() {call();}", assert_terminated_expression_statement),
    SyntaxCase::invalid("I.S.ExprStmt.double-semicolon", "S.ExprStmt", "fn f() {call();;}", "E0101", ";"),
    SyntaxCase::invalid("I.S.ExprStmt.missing-semicolon-before-next", "S.ExprStmt", "fn f() {call() next()}", "E0101", "next"),
    SyntaxCase::context_valid("C.block.unterminated-expression-is-tail", "fn f() {call()}", assert_unterminated_expression_is_tail),
    SyntaxCase::valid("V.S.Block.stmts-and-tail", "S.Block", "fn f() {let x = 1 x}", assert_block),
    SyntaxCase::valid("V.S.Block.empty", "S.Block", "fn f() {}", assert_block),
    SyntaxCase::valid("V.S.Block.tail-only", "S.Block", "fn f() {1}", assert_block),
    SyntaxCase::valid("V.S.Block.stmt-only", "S.Block", "fn f() {let x = 1}", assert_block),
    SyntaxCase::valid("V.S.Block.many-stmts", "S.Block", "fn f() {let x = 1; let y = 2;}", assert_block),
    SyntaxCase::invalid("I.S.Block.missing-close", "S.Block", "fn f() {1", "E0103", ""),
    SyntaxCase::invalid("I.S.Block.extra-token-after-tail", "S.Block", "fn f() {1 2}", "E0101", "2"),
    SyntaxCase::valid("V.S.UnsafeExpr.nonempty-block", "S.UnsafeExpr", "fn f() {unsafe {1}}", assert_unsafe),
    SyntaxCase::valid("V.S.UnsafeExpr.empty-block", "S.UnsafeExpr", "fn f() {unsafe {}}", assert_unsafe),
    SyntaxCase::invalid("I.S.UnsafeExpr.missing-block", "S.UnsafeExpr", "fn f() {unsafe value}", "E0103", "value"),
];

pub(crate) fn cases() -> &'static [SyntaxCase] {
    CASES
}

#[test]
fn statement_grammar_cases_are_executable() {
    run_syntax_cases(CASES);
}
