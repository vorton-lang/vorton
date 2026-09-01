use vorton::ast::{Decl, EffectName, Expr, Pattern, Stmt, TypeExpr, UseKind};
use vorton::source::{SourceFile, SourceId};

use super::manifest::{SyntaxCase, run_syntax_cases};

fn assert_program(program: &vorton::ast::Program) {
    assert!(!program.declarations.is_empty() || !program.uses.is_empty());
}

fn assert_module_requires(program: &vorton::ast::Program) {
    let Some(Decl::Module(module)) = program.declarations.first() else {
        panic!("module")
    };
    assert!(module.requires.is_some());
}

fn assert_public_inherent_member(program: &vorton::ast::Program) {
    let Some(Decl::Impl(value)) = program.declarations.first() else {
        panic!("impl")
    };
    let vorton::ast::ImplMember::Method(method) = &value.members[0] else {
        panic!("method")
    };
    assert!(method.visibility.public);
}

fn assert_self_receiver(program: &vorton::ast::Program) {
    let Some(Decl::Impl(value)) = program.declarations.first() else {
        panic!("impl")
    };
    let vorton::ast::ImplMember::Method(method) = &value.members[0] else {
        panic!("method")
    };
    assert_eq!(method.params[0].name.text, "self");
    assert!(method.params[0].type_annotation.is_some());
    let Expr::Block {
        statements, tail, ..
    } = &method.body
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
    assert!(matches!(tail.as_deref(), Some(Expr::MethodCall { .. })));
}

fn assert_super_use(program: &vorton::ast::Program) {
    let Some(Decl::Module(outer)) = program.declarations.first() else {
        panic!("outer")
    };
    let Some(Decl::Module(inner)) = outer.declarations.first() else {
        panic!("inner")
    };
    assert!(matches!(inner.uses[0].kind, UseKind::Bare));
    assert_eq!(inner.uses[0].path.segments[0].text, "super");
}

fn assert_super_expression(program: &vorton::ast::Program) {
    let Some(Decl::Module(module)) = program.declarations.first() else {
        panic!("module")
    };
    let Some(Decl::Function(function)) = module.declarations.first() else {
        panic!("function")
    };
    let Expr::Block {
        tail: Some(tail), ..
    } = &function.body
    else {
        panic!("tail")
    };
    assert!(matches!(tail.as_ref(), Expr::Call { callee, .. }
        if matches!(callee.as_ref(), Expr::Path { path, .. } if path.segments[0].text == "super")));
}

fn first_function_body(program: &vorton::ast::Program) -> &Expr {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    &function.body
}

fn assert_lowercase_named_literal(program: &vorton::ast::Program) {
    let Expr::Block {
        tail: Some(tail), ..
    } = first_function_body(program)
    else {
        panic!("tail")
    };
    assert!(
        matches!(tail.as_ref(), Expr::NamedLiteral { path, .. } if path.segments[0].text == "shape")
    );
}

fn assert_lowercase_call(program: &vorton::ast::Program) {
    let Expr::Block {
        tail: Some(tail), ..
    } = first_function_body(program)
    else {
        panic!("tail")
    };
    assert!(matches!(tail.as_ref(), Expr::Call { callee, .. }
        if matches!(callee.as_ref(), Expr::Path { path, .. } if path.segments[0].text == "some")));
}

fn assert_lowercase_pattern(program: &vorton::ast::Program) {
    let Expr::Block {
        tail: Some(tail), ..
    } = first_function_body(program)
    else {
        panic!("tail")
    };
    let Expr::Match { arms, .. } = tail.as_ref() else {
        panic!("match")
    };
    assert!(
        matches!(arms[0].pattern, Pattern::Constructor { ref path, .. } if path.segments[0].text == "some")
    );
}

fn assert_parenthesized_named_literal_control(program: &vorton::ast::Program) {
    let Expr::Block {
        tail: Some(tail), ..
    } = first_function_body(program)
    else {
        panic!("tail")
    };
    assert!(matches!(tail.as_ref(), Expr::If { condition, .. }
        if matches!(condition.as_ref(), Expr::Parenthesized { inner, .. }
            if matches!(inner.as_ref(), Expr::NamedLiteral { .. }))));
}

fn assert_unparenthesized_control_path(program: &vorton::ast::Program) {
    let Expr::Block {
        tail: Some(tail), ..
    } = first_function_body(program)
    else {
        panic!("tail")
    };
    assert!(
        matches!(tail.as_ref(), Expr::If { condition, .. } if matches!(condition.as_ref(), Expr::Path { .. }))
    );
}

fn assert_if_let_named_literal(program: &vorton::ast::Program) {
    let Expr::Block { statements, .. } = first_function_body(program) else {
        panic!("block")
    };
    assert!(matches!(
        statements[0],
        Stmt::IfLet {
            value: Expr::Parenthesized { ref inner, .. },
            ..
        } if matches!(inner.as_ref(), Expr::NamedLiteral { .. })
    ));
}

fn assert_while_named_literal(program: &vorton::ast::Program) {
    let Expr::Block { statements, .. } = first_function_body(program) else {
        panic!("block")
    };
    assert!(matches!(
        statements[0],
        Stmt::While {
            condition: Expr::Parenthesized { ref inner, .. },
            ..
        } if matches!(inner.as_ref(), Expr::NamedLiteral { .. })
    ));
}

fn assert_for_named_literal(program: &vorton::ast::Program) {
    let Expr::Block { statements, .. } = first_function_body(program) else {
        panic!("block")
    };
    assert!(matches!(
        statements[0],
        Stmt::For {
            iterable: Expr::Parenthesized { ref inner, .. },
            ..
        } if matches!(inner.as_ref(), Expr::NamedLiteral { .. })
    ));
}

fn assert_match_named_literal(program: &vorton::ast::Program) {
    let Expr::Block {
        tail: Some(tail), ..
    } = first_function_body(program)
    else {
        panic!("tail")
    };
    assert!(matches!(
        tail.as_ref(),
        Expr::Match {
            scrutinee,
            ..
        } if matches!(scrutinee.as_ref(), Expr::Parenthesized { inner, .. }
            if matches!(inner.as_ref(), Expr::NamedLiteral { .. }))
    ));
}

fn assert_bare_return_then_let(program: &vorton::ast::Program) {
    let Expr::Block { statements, .. } = first_function_body(program) else {
        panic!("block")
    };
    assert!(matches!(statements[0], Stmt::Return { value: None, .. }));
    assert!(matches!(statements[1], Stmt::Let { .. }));
}

fn assert_return_newline_value(program: &vorton::ast::Program) {
    let Expr::Block { statements, .. } = first_function_body(program) else {
        panic!("block")
    };
    assert!(matches!(statements[0], Stmt::Return { value: Some(_), .. }));
}

fn assert_bare_return_then_expression(program: &vorton::ast::Program) {
    let Expr::Block {
        statements, tail, ..
    } = first_function_body(program)
    else {
        panic!("block")
    };
    assert!(matches!(statements[0], Stmt::Return { value: None, .. }));
    assert!(matches!(tail.as_deref(), Some(Expr::Call { .. })));
}

fn assert_or_arm(program: &vorton::ast::Program) {
    let Expr::Block {
        tail: Some(tail), ..
    } = first_function_body(program)
    else {
        panic!("tail")
    };
    assert!(matches!(tail.as_ref(), Expr::Match { arms, .. }
        if matches!(arms[0].pattern, Pattern::Or { .. })));
}

#[rustfmt::skip]
const CASES: &[SyntaxCase] = &[
    SyntaxCase::context_valid("C.program.use-before-decl", "use m\nfn f() {}", assert_program),
    SyntaxCase::context_invalid("C.module.use-before-decl", "mod m {fn f() {} use x}", "E0706", "use"),
    SyntaxCase::context_invalid("C.program.file-requires-rejected", "requires {io}", "E0101", "requires"),
    SyntaxCase::context_valid("C.module.inline-requires-accepted", "mod m requires {io} {}", assert_module_requires),
    SyntaxCase::context_invalid("C.visibility.pub-impl-rejected", "pub impl T {}", "E0101", "pub"),
    SyntaxCase::context_invalid("C.visibility.trait-member-pub-rejected", "trait T {pub fn f()}", "E0101", "pub"),
    SyntaxCase::context_invalid("C.visibility.trait-impl-member-pub-rejected", "impl Tr for T {pub fn f(){}}", "E0101", "pub"),
    SyntaxCase::context_valid("C.visibility.inherent-member-pub-accepted", "impl T {pub fn f(){}}", assert_public_inherent_member),
    SyntaxCase::context_invalid("C.removed.where-hard-fail", "fn f(x: Int where x) {}", "E0101", "where"),
    SyntaxCase::context_invalid("C.removed.try-hard-fail", "fn f() {try value}", "E0101", "try"),
    SyntaxCase::context_invalid("C.removed.question-type-hard-fail", "fn f(x: Int?) {}", "E0101", "?"),
    SyntaxCase::context_invalid("C.removed.question-postfix-hard-fail", "fn f() {value?}", "E0101", "?"),
    SyntaxCase::context_invalid("C.removed.attribute-hard-fail", "@derive(Json) struct S {}", "E0101", "@derive"),
    SyntaxCase::context_invalid("C.removed.default-param-fn", "fn f(x = 1) {}", "E0101", "="),
    SyntaxCase::context_invalid("C.removed.default-param-extern", "extern fn f(x = 1)", "E0101", "="),
    SyntaxCase::context_invalid("C.removed.default-param-effect", "effect E {fn f(x = 1) -> Int}", "E0101", "="),
    SyntaxCase::context_invalid("C.removed.default-param-handler", "fn f() {handle {} with {E.f(x = 1) => 0}}", "E0101", "="),
    SyntaxCase::context_invalid("C.removed.default-param-lambda", "fn f() {fn(x = 1) {x}}", "E0101", "="),
    SyntaxCase::context_invalid("C.removed.default-param-trait", "trait T {fn f(x = 1)}", "E0101", "="),
    SyntaxCase::context_invalid("C.removed.effect-op-body-hard-fail", "effect E {fn f() -> Int {1}}", "E0101", "{"),
    SyntaxCase::context_invalid("C.removed.trait-method-body-hard-fail", "trait T {fn f() {}}", "E0101", "{"),
    SyntaxCase::context_invalid("C.removed.impl-extern-hard-fail", "impl T {extern fn f()}", "E0101", "extern"),
    SyntaxCase::context_invalid("C.removed.delegate-member-hard-fail", "impl T {delegate f}", "E0101", "delegate"),
    SyntaxCase::context_valid("C.context.type-declaration-vs-identifier", "type type = type", assert_program),
    SyntaxCase::context_valid("C.context.effect-alias-word", "effect alias alias = {}", assert_program),
    SyntaxCase::context_valid("C.context.self-method-parameter", "impl T {fn f(self: T) {self.member; self.method()}}", assert_self_receiver),
    SyntaxCase::context_invalid("C.context.self-colon-colon-rejected", "fn f() {self::value}", "E0101", "self"),
    SyntaxCase::context_valid("C.context.super-use-path", "mod outer {mod inner {use super::value}}", assert_super_use),
    SyntaxCase::context_valid("C.context.super-expression-path", "mod inner {fn f() {super::value()}}", assert_super_expression),
    SyntaxCase::context_valid("C.path.lowercase-named-literal", "fn f() {shape {}}", assert_lowercase_named_literal),
    SyntaxCase::context_valid("C.path.lowercase-positional-constructor", "fn f() {some(value)}", assert_lowercase_call),
    SyntaxCase::context_valid("C.path.lowercase-constructor-pattern", "fn f(x: T) {match x {some(value) => value}}", assert_lowercase_pattern),
    SyntaxCase::context_valid("C.control.if-named-literal-needs-parens", "fn f() {if (shape {}) {}}", assert_parenthesized_named_literal_control),
    SyntaxCase::context_valid("C.control.if-unparenthesized-is-path", "fn f() {if shape {}}", assert_unparenthesized_control_path),
    SyntaxCase::context_valid("C.control.if-let-rhs-named-literal-needs-parens", "fn f() {if let x = (shape {}) {}}", assert_if_let_named_literal),
    SyntaxCase::context_valid("C.control.while-named-literal-needs-parens", "fn f() {while (shape {}) {}}", assert_while_named_literal),
    SyntaxCase::context_valid("C.control.for-rhs-named-literal-needs-parens", "fn f() {for x in (shape {}) {}}", assert_for_named_literal),
    SyntaxCase::context_valid("C.control.match-scrutinee-named-literal-needs-parens", "fn f() {match (shape {}) {_ => 0}}", assert_match_named_literal),
    SyntaxCase::context_valid("C.pattern.or-only-arm-top-level", "fn f(x: T) {match x {A | B => 0}}", assert_or_arm),
    SyntaxCase::context_invalid("C.pattern.raw-string-rejected", "fn f(x: T) {match x {r\"raw\" => 0}}", "E0101", "r\"raw\""),
    SyntaxCase::context_invalid("C.return.arm-only-expression", "fn f() {let x = return 1}", "E0101", "return"),
    SyntaxCase::context_valid("C.return.bare-before-statement-token", "fn f() {return let x = 1}", assert_bare_return_then_let),
    SyntaxCase::context_valid("C.return.newline-expression-is-value", "fn f() {return\ncall()}", assert_return_newline_value),
    SyntaxCase::context_valid("C.return.semicolon-before-expression", "fn f() {return; call()}", assert_bare_return_then_expression),
    SyntaxCase::context_invalid("C.assignment.index-target-rejected", "fn f() {xs[0] = 1}", "E0101", "xs[0]"),
    SyntaxCase::context_invalid("C.use.grouped-requires-colon-colon", "use parser {Token}", "E0101", "{"),
    SyntaxCase::context_invalid("C.use.no-declaration-semicolon", "use parser;", "E0101", ";"),
];

pub(crate) fn cases() -> &'static [SyntaxCase] {
    CASES
}

#[test]
fn contextual_grammar_cases_are_executable() {
    run_syntax_cases(CASES);
}

#[test]
fn shared_path_surface_preserves_segments_and_half_open_spans() {
    let text = concat!(
        "use module::item\n",
        "type Alias = module::Type\n",
        "fn f(value: module::Type) with {module::io} {module::value}\n",
    );
    let output =
        vorton::parse_source(SourceFile::new(SourceId(700), "paths.vorton", text).unwrap());
    let program = output.syntax.expect("shared path fixture");

    let assert_path = |path: &vorton::ast::Path, expected: &str| {
        assert_eq!(path.segments.len(), 2);
        assert_eq!(
            &text[path.span.start as usize..path.span.end as usize],
            expected
        );
    };
    assert_path(&program.uses[0].path, "module::item");

    let Decl::TypeAlias(alias) = &program.declarations[0] else {
        panic!("type alias")
    };
    let TypeExpr::Named { path, .. } = &alias.ty else {
        panic!("named type")
    };
    assert_path(path, "module::Type");

    let Decl::Function(function) = &program.declarations[1] else {
        panic!("function")
    };
    let Some(TypeExpr::Named { path, .. }) = &function.params[0].type_annotation else {
        panic!("parameter type")
    };
    assert_path(path, "module::Type");
    let EffectName::Path(path) = &function.effects.as_ref().unwrap().effects[0].name else {
        panic!("effect path")
    };
    assert_path(path, "module::io");
    let Expr::Block {
        tail: Some(tail), ..
    } = &function.body
    else {
        panic!("tail")
    };
    let Expr::Path { path, .. } = tail.as_ref() else {
        panic!("value path")
    };
    assert_path(path, "module::value");
}

#[test]
fn super_root_keeps_the_same_path_shape_across_frontend_surfaces() {
    let text = r#"
mod outer {
    mod inner {
        use super::{value, helper}
        use super::super::{root}
        type Parent = super::Type
        fn f<T: super::Bound>(value: super::Type) with {super::io} {
            let literal = super::Shape {}
            let matched = match value {super::some(item) => item}
            super::value
        }
    }
}
"#;
    let output =
        vorton::parse_source(SourceFile::new(SourceId(701), "super.vorton", text).unwrap());
    let program = output.syntax.expect("super path fixture");
    let Decl::Module(outer) = &program.declarations[0] else {
        panic!("outer")
    };
    let Decl::Module(inner) = &outer.declarations[0] else {
        panic!("inner")
    };
    assert_eq!(inner.uses[0].path.segments.len(), 1);
    assert_eq!(inner.uses[0].path.segments[0].text, "super");
    assert!(matches!(inner.uses[0].kind, UseKind::NamedItems(_)));
    assert_eq!(inner.uses[1].path.segments.len(), 2);

    let Decl::TypeAlias(alias) = &inner.declarations[0] else {
        panic!("type alias")
    };
    let TypeExpr::Named { path, .. } = &alias.ty else {
        panic!("type path")
    };
    assert_eq!(path.segments[0].text, "super");

    let Decl::Function(function) = &inner.declarations[1] else {
        panic!("function")
    };
    assert_eq!(
        function.type_params[0].bounds[0].path.segments[0].text,
        "super"
    );
    let Some(TypeExpr::Named { path, .. }) = &function.params[0].type_annotation else {
        panic!("parameter type")
    };
    assert_eq!(path.segments[0].text, "super");
    let EffectName::Path(path) = &function.effects.as_ref().unwrap().effects[0].name else {
        panic!("effect")
    };
    assert_eq!(path.segments[0].text, "super");
    let Expr::Block {
        statements, tail, ..
    } = &function.body
    else {
        panic!("body")
    };
    assert!(matches!(
        statements[0],
        Stmt::Let {
            value: Expr::NamedLiteral { ref path, .. },
            ..
        } if path.segments[0].text == "super"
    ));
    let Stmt::Let {
        value: Expr::Match { arms, .. },
        ..
    } = &statements[1]
    else {
        panic!("match")
    };
    assert!(
        matches!(arms[0].pattern, Pattern::Constructor { ref path, .. }
        if path.segments[0].text == "super")
    );
    assert!(matches!(tail.as_deref(), Some(Expr::Path { path, .. })
        if path.segments[0].text == "super"));
}
