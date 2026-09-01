use vorton::ast::{Decl, EffectName, TypeExpr};

use super::coverage::AstCoverage;
use super::manifest::{SyntaxCase, run_syntax_cases};

fn assert_type_alias(program: &vorton::ast::Program) -> &vorton::ast::TypeAliasDecl {
    let Some(Decl::TypeAlias(alias)) = program.declarations.first() else {
        panic!("type alias")
    };
    alias
}

fn assert_path(program: &vorton::ast::Program) {
    let TypeExpr::Named { path, .. } = &assert_type_alias(program).ty else {
        panic!("named type")
    };
    assert_eq!(path.segments.len(), 3);
}

fn assert_all_type_expr_alternatives(program: &vorton::ast::Program) {
    let mut coverage = AstCoverage::default();
    coverage.visit_program(program);
    for tag in [
        "TypeExpr::Named",
        "TypeExpr::Function",
        "TypeExpr::Tuple",
        "TypeExpr::Parenthesized",
        "TypeExpr::Record",
    ] {
        assert!(coverage.variants.contains(tag), "missing {tag}");
    }
}

fn assert_named_type_args(program: &vorton::ast::Program) {
    let TypeExpr::Named { type_args, .. } = &assert_type_alias(program).ty else {
        panic!("named type")
    };
    assert_eq!(type_args.len(), 2);
}

fn assert_function_type(program: &vorton::ast::Program) {
    let TypeExpr::Function {
        params, effects, ..
    } = &assert_type_alias(program).ty
    else {
        panic!("function type")
    };
    assert_eq!(params.len(), 2);
    assert!(effects.is_some());
}

fn assert_tuple_type(program: &vorton::ast::Program) {
    let TypeExpr::Tuple { elements, .. } = &assert_type_alias(program).ty else {
        panic!("tuple type")
    };
    assert_eq!(elements.len(), 2);
}

fn assert_parenthesized_type(program: &vorton::ast::Program) {
    assert!(matches!(
        assert_type_alias(program).ty,
        TypeExpr::Parenthesized { .. }
    ));
}

fn assert_record_type(program: &vorton::ast::Program) {
    let TypeExpr::Record { fields, rest, .. } = &assert_type_alias(program).ty else {
        panic!("record type")
    };
    assert_eq!(fields.len(), 2);
    assert!(rest.is_some());
}

fn assert_record_field(program: &vorton::ast::Program) {
    let TypeExpr::Record { fields, .. } = &assert_type_alias(program).ty else {
        panic!("record type")
    };
    assert_eq!(fields.len(), 1);
}

fn assert_type_expr_list(program: &vorton::ast::Program) {
    let TypeExpr::Function { params, .. } = &assert_type_alias(program).ty else {
        panic!("function type")
    };
    assert_eq!(params.len(), 2);
}

fn assert_type_params(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    assert_eq!(function.type_params.len(), 2);
}

fn assert_type_param_bounds(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    assert_eq!(function.type_params[0].bounds.len(), 2);
}

fn assert_type_bound(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    let bound = &function.type_params[0].bounds[0];
    assert_eq!(bound.type_args.len(), 1);
    assert_eq!(bound.associated.len(), 1);
}

fn assert_effect_expr(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    let effects = function.effects.as_ref().expect("effects");
    assert_eq!(effects.effects.len(), 3);
    assert!(matches!(effects.effects[0].name, EffectName::Path(_)));
    assert!(matches!(effects.effects[1].name, EffectName::Mutation(_)));
    assert!(matches!(effects.effects[2].name, EffectName::Unsafe(_)));
}

const ALL_TYPES: &str = r#"
type Named = module::Thing<Int, Str>
type Function = fn(Int, Str,) -> Int with {io}
type Tuple = (Int, Str,)
type Parenthesized = (Int)
type Record = {x: Int, y: Str, ..rest,}
"#;

#[rustfmt::skip]
const CASES: &[SyntaxCase] = &[
    SyntaxCase::valid("V.S.Path.many", "S.Path", "type X = module::inner::T", assert_path),
    SyntaxCase::invalid("I.S.Path.self-root", "S.Path", "type X = self::T", "E0101", "self"),
    SyntaxCase::valid("V.S.TypeExpr.all-alternatives", "S.TypeExpr", ALL_TYPES, assert_all_type_expr_alternatives),
    SyntaxCase::invalid("I.S.TypeExpr.impl-trait", "S.TypeExpr", "type X = impl Trait", "E0101", "impl"),
    SyntaxCase::valid("V.S.NamedType.args", "S.NamedType", "type X = Pair<Int, Str,>", assert_named_type_args),
    SyntaxCase::invalid("I.S.NamedType.empty-args", "S.NamedType", "type X = Pair<>", "E0101", ">"),
    SyntaxCase::valid("V.S.FnType.many-trailing-effects", "S.FnType", "type F = fn(Int, Str,) -> Int with {io}", assert_function_type),
    SyntaxCase::invalid("I.S.FnType.missing-arrow", "S.FnType", "type F = fn(Int) Int", "E0103", "Int"),
    SyntaxCase::valid("V.S.TupleType.many-trailing", "S.TupleType", "type T = (Int, Str,)", assert_tuple_type),
    SyntaxCase::invalid("I.S.TupleType.one-with-comma", "S.TupleType", "type T = (Int,)", "E0101", "("),
    SyntaxCase::valid("V.S.ParenthesizedType.minimal", "S.ParenthesizedType", "type T = (Int)", assert_parenthesized_type),
    SyntaxCase::invalid("I.S.ParenthesizedType.empty", "S.ParenthesizedType", "type T = ()", "E0101", ")"),
    SyntaxCase::valid("V.S.RecordType.many-rest-trailing", "S.RecordType", "type T = {x: Int, y: Str, ..rest,}", assert_record_type),
    SyntaxCase::invalid("I.S.RecordType.rest-only", "S.RecordType", "type T = {..rest}", "E0101", ".."),
    SyntaxCase::valid("V.S.RecordField.minimal", "S.RecordField", "type T = {x: Int}", assert_record_field),
    SyntaxCase::invalid("I.S.RecordField.missing-colon", "S.RecordField", "type T = {x Int}", "E0103", "Int"),
    SyntaxCase::valid("V.S.TypeExprList.many-trailing", "S.TypeExprList", "type F = fn(Int, Str,) -> Int", assert_type_expr_list),
    SyntaxCase::invalid("I.S.TypeExprList.missing-comma", "S.TypeExprList", "type F = fn(Int Str) -> Int", "E0103", "Str"),
    SyntaxCase::valid("V.S.TypeParams.many-trailing", "S.TypeParams", "fn f<T, U,>() {}", assert_type_params),
    SyntaxCase::invalid("I.S.TypeParams.empty", "S.TypeParams", "fn f<>() {}", "E0101", ">"),
    SyntaxCase::valid("V.S.TypeParam.many-bounds", "S.TypeParam", "fn f<T: A + B>() {}", assert_type_param_bounds),
    SyntaxCase::invalid("I.S.TypeParam.trailing-plus", "S.TypeParam", "fn f<T: A +>() {}", "E0103", ">"),
    SyntaxCase::valid("V.S.TypeBound.mixed-trailing", "S.TypeBound", "fn f<T: module::Bound<Int, Item = Str,>>() {}", assert_type_bound),
    SyntaxCase::invalid("I.S.TypeBound.empty-angles", "S.TypeBound", "fn f<T: Bound<>>() {}", "E0101", ">"),
    SyntaxCase::valid("V.S.BoundArg.type-and-associated", "S.BoundArg", "fn f<T: Bound<Int, Item = Str>>() {}", assert_type_bound),
    SyntaxCase::invalid("I.S.BoundArg.missing-associated-type", "S.BoundArg", "fn f<T: Bound<Item = >>() {}", "E0101", ">"),
    SyntaxCase::valid("V.S.TypeArgs.nested-trailing", "S.TypeArgs", "type X = Outer<Inner<Int,>, Str,>", assert_named_type_args),
    SyntaxCase::invalid("I.S.TypeArgs.missing-comma", "S.TypeArgs", "type X = Pair<Int Str>", "E0103", "Str"),
    SyntaxCase::valid("V.S.EffectExpr.generic", "S.EffectExpr", "fn f() with {io<Int>, mut<Int>, unsafe} {}", assert_effect_expr),
    SyntaxCase::invalid("I.S.EffectExpr.empty-args", "S.EffectExpr", "fn f() with {io<>} {}", "E0101", ">"),
    SyntaxCase::valid("V.S.EffectName.all-alternatives", "S.EffectName", "fn f() with {module::io, mut<Int>, unsafe} {}", assert_effect_expr),
    SyntaxCase::invalid("I.S.EffectName.trailing-colon-colon", "S.EffectName", "fn f() with {io::} {}", "E0103", "}"),
];

pub(crate) fn cases() -> &'static [SyntaxCase] {
    CASES
}

#[test]
fn type_grammar_cases_are_executable() {
    run_syntax_cases(CASES);
}
