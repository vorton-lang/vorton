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

fn assert_named_type(program: &vorton::ast::Program) {
    assert!(matches!(
        assert_type_alias(program).ty,
        TypeExpr::Named { .. }
    ));
}

fn assert_any_function_type(program: &vorton::ast::Program) {
    assert!(matches!(
        assert_type_alias(program).ty,
        TypeExpr::Function { .. }
    ));
}

fn assert_any_record_type(program: &vorton::ast::Program) {
    assert!(matches!(
        assert_type_alias(program).ty,
        TypeExpr::Record { .. }
    ));
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

fn assert_tuple_type_many(program: &vorton::ast::Program) {
    let TypeExpr::Tuple { elements, .. } = &assert_type_alias(program).ty else {
        panic!("tuple type")
    };
    assert_eq!(elements.len(), 3);
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

fn assert_any_type_param(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    assert!(!function.type_params.is_empty());
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

fn assert_any_type_bound(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    assert!(!function.type_params[0].bounds.is_empty());
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

fn assert_one_effect(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    assert_eq!(function.effects.as_ref().unwrap().effects.len(), 1);
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
    SyntaxCase::valid("V.S.Path.one", "S.Path", "type X = T", assert_named_type),
    SyntaxCase::valid("V.S.Path.super-one", "S.Path", "type X = super::T", assert_named_type),
    SyntaxCase::valid("V.S.Path.super-many", "S.Path", "type X = super::super::T", assert_named_type),
    SyntaxCase::invalid("I.S.Path.leading-colon-colon", "S.Path", "type X = ::T", "E0101", "::"),
    SyntaxCase::invalid("I.S.Path.trailing-colon-colon", "S.Path", "type X = module::", "E0103", ""),
    SyntaxCase::invalid("I.S.Path.empty-segment", "S.Path", "type X = module::::T", "E0103", "::"),
    SyntaxCase::invalid("I.S.Path.self-root", "S.Path", "type X = self::T", "E0101", "self"),
    SyntaxCase::invalid("I.S.Path.bare-super", "S.Path", "type X = super", "E0101", "super"),
    SyntaxCase::valid("V.S.TypeExpr.all-alternatives", "S.TypeExpr", ALL_TYPES, assert_all_type_expr_alternatives),
    SyntaxCase::valid("V.S.TypeExpr.named", "S.TypeExpr", "type X = Int", assert_named_type),
    SyntaxCase::valid("V.S.TypeExpr.fn", "S.TypeExpr", "type X = fn() -> Int", assert_any_function_type),
    SyntaxCase::valid("V.S.TypeExpr.tuple", "S.TypeExpr", "type X = (Int, Str)", assert_tuple_type),
    SyntaxCase::valid("V.S.TypeExpr.record", "S.TypeExpr", "type X = {x: Int}", assert_any_record_type),
    SyntaxCase::valid("V.S.TypeExpr.parenthesized", "S.TypeExpr", "type X = (Int)", assert_parenthesized_type),
    SyntaxCase::invalid("I.S.TypeExpr.question-option", "S.TypeExpr", "type X = Int?", "E0101", "?"),
    SyntaxCase::invalid("I.S.TypeExpr.impl-trait", "S.TypeExpr", "type X = impl Trait", "E0101", "impl"),
    SyntaxCase::valid("V.S.NamedType.args", "S.NamedType", "type X = Pair<Int, Str,>", assert_named_type_args),
    SyntaxCase::valid("V.S.NamedType.plain", "S.NamedType", "type X = module::Int", assert_named_type),
    SyntaxCase::invalid("I.S.NamedType.empty-args", "S.NamedType", "type X = Pair<>", "E0101", ">"),
    SyntaxCase::valid("V.S.FnType.many-trailing-effects", "S.FnType", "type F = fn(Int, Str,) -> Int with {io}", assert_function_type),
    SyntaxCase::valid("V.S.FnType.zero-params", "S.FnType", "type F = fn() -> Int", assert_any_function_type),
    SyntaxCase::valid("V.S.FnType.one-param", "S.FnType", "type F = fn(Int) -> Int", assert_any_function_type),
    SyntaxCase::valid("V.S.FnType.many-params", "S.FnType", "type F = fn(Int, Str) -> Int", assert_any_function_type),
    SyntaxCase::valid("V.S.FnType.trailing", "S.FnType", "type F = fn(Int, Str,) -> Int", assert_any_function_type),
    SyntaxCase::valid("V.S.FnType.effects", "S.FnType", "type F = fn() -> Int with {io}", assert_any_function_type),
    SyntaxCase::invalid("I.S.FnType.missing-return", "S.FnType", "type F = fn() ->", "E0101", ""),
    SyntaxCase::invalid("I.S.FnType.missing-arrow", "S.FnType", "type F = fn(Int) Int", "E0103", "Int"),
    SyntaxCase::valid("V.S.TupleType.many-trailing", "S.TupleType", "type T = (Int, Str,)", assert_tuple_type),
    SyntaxCase::valid("V.S.TupleType.two", "S.TupleType", "type T = (Int, Str)", assert_tuple_type),
    SyntaxCase::valid("V.S.TupleType.many", "S.TupleType", "type T = (Int, Str, Bool)", assert_tuple_type_many),
    SyntaxCase::invalid("I.S.TupleType.empty", "S.TupleType", "type T = ()", "E0101", ")"),
    SyntaxCase::invalid("I.S.TupleType.one-with-comma", "S.TupleType", "type T = (Int,)", "E0101", "("),
    SyntaxCase::valid("V.S.ParenthesizedType.minimal", "S.ParenthesizedType", "type T = (Int)", assert_parenthesized_type),
    SyntaxCase::invalid("I.S.ParenthesizedType.empty", "S.ParenthesizedType", "type T = ()", "E0101", ")"),
    SyntaxCase::valid("V.S.RecordType.many-rest-trailing", "S.RecordType", "type T = {x: Int, y: Str, ..rest,}", assert_record_type),
    SyntaxCase::valid("V.S.RecordType.one", "S.RecordType", "type T = {x: Int}", assert_record_field),
    SyntaxCase::valid("V.S.RecordType.many", "S.RecordType", "type T = {x: Int, y: Str}", assert_any_record_type),
    SyntaxCase::valid("V.S.RecordType.many-trailing", "S.RecordType", "type T = {x: Int, y: Str,}", assert_any_record_type),
    SyntaxCase::valid("V.S.RecordType.one-rest", "S.RecordType", "type T = {x: Int, ..rest}", assert_any_record_type),
    SyntaxCase::valid("V.S.RecordType.many-rest", "S.RecordType", "type T = {x: Int, y: Str, ..rest}", assert_record_type),
    SyntaxCase::valid("V.S.RecordType.rest-trailing", "S.RecordType", "type T = {x: Int, ..rest,}", assert_any_record_type),
    SyntaxCase::invalid("I.S.RecordType.empty", "S.RecordType", "type T = {}", "E0101", "}"),
    SyntaxCase::invalid("I.S.RecordType.leading-comma", "S.RecordType", "type T = {,x: Int}", "E0103", ","),
    SyntaxCase::invalid("I.S.RecordType.missing-comma", "S.RecordType", "type T = {x: Int y: Str}", "E0103", "y"),
    SyntaxCase::invalid("I.S.RecordType.rest-not-last", "S.RecordType", "type T = {x: Int, ..rest, y: Str}", "E0103", "y"),
    SyntaxCase::invalid("I.S.RecordType.double-comma", "S.RecordType", "type T = {x: Int,,y: Str}", "E0103", ","),
    SyntaxCase::invalid("I.S.RecordType.rest-only", "S.RecordType", "type T = {..rest}", "E0101", ".."),
    SyntaxCase::valid("V.S.RecordField.minimal", "S.RecordField", "type T = {x: Int}", assert_record_field),
    SyntaxCase::invalid("I.S.RecordField.missing-colon", "S.RecordField", "type T = {x Int}", "E0103", "Int"),
    SyntaxCase::valid("V.S.TypeExprList.many-trailing", "S.TypeExprList", "type F = fn(Int, Str,) -> Int", assert_type_expr_list),
    SyntaxCase::valid("V.S.TypeExprList.one", "S.TypeExprList", "type F = fn(Int) -> Int", assert_any_function_type),
    SyntaxCase::valid("V.S.TypeExprList.many", "S.TypeExprList", "type F = fn(Int, Str) -> Int", assert_type_expr_list),
    SyntaxCase::invalid("I.S.TypeExprList.empty", "S.TypeExprList", "type T = (,)", "E0101", ","),
    SyntaxCase::invalid("I.S.TypeExprList.leading-comma", "S.TypeExprList", "type F = fn(,Int) -> Int", "E0101", ","),
    SyntaxCase::invalid("I.S.TypeExprList.double-comma", "S.TypeExprList", "type F = fn(Int,,Str) -> Int", "E0101", ","),
    SyntaxCase::invalid("I.S.TypeExprList.missing-comma", "S.TypeExprList", "type F = fn(Int Str) -> Int", "E0103", "Str"),
    SyntaxCase::valid("V.S.TypeParams.many-trailing", "S.TypeParams", "fn f<T, U,>() {}", assert_type_params),
    SyntaxCase::valid("V.S.TypeParams.one", "S.TypeParams", "fn f<T>() {}", assert_any_type_param),
    SyntaxCase::valid("V.S.TypeParams.many", "S.TypeParams", "fn f<T, U>() {}", assert_type_params),
    SyntaxCase::invalid("I.S.TypeParams.leading-comma", "S.TypeParams", "fn f<,T>() {}", "E0103", ","),
    SyntaxCase::invalid("I.S.TypeParams.double-comma", "S.TypeParams", "fn f<T,,U>() {}", "E0103", ","),
    SyntaxCase::invalid("I.S.TypeParams.missing-comma", "S.TypeParams", "fn f<T U>() {}", "E0103", "U"),
    SyntaxCase::invalid("I.S.TypeParams.empty", "S.TypeParams", "fn f<>() {}", "E0101", ">"),
    SyntaxCase::valid("V.S.TypeParam.many-bounds", "S.TypeParam", "fn f<T: A + B>() {}", assert_type_param_bounds),
    SyntaxCase::valid("V.S.TypeParam.plain", "S.TypeParam", "fn f<T>() {}", assert_any_type_param),
    SyntaxCase::valid("V.S.TypeParam.one-bound", "S.TypeParam", "fn f<T: A>() {}", assert_any_type_bound),
    SyntaxCase::invalid("I.S.TypeParam.missing-bound", "S.TypeParam", "fn f<T: >() {}", "E0103", ">"),
    SyntaxCase::invalid("I.S.TypeParam.trailing-plus", "S.TypeParam", "fn f<T: A +>() {}", "E0103", ">"),
    SyntaxCase::valid("V.S.TypeBound.mixed-trailing", "S.TypeBound", "fn f<T: module::Bound<Int, Item = Str,>>() {}", assert_type_bound),
    SyntaxCase::valid("V.S.TypeBound.plain", "S.TypeBound", "fn f<T: Bound>() {}", assert_any_type_bound),
    SyntaxCase::valid("V.S.TypeBound.type-arg", "S.TypeBound", "fn f<T: Bound<Int>>() {}", assert_any_type_bound),
    SyntaxCase::valid("V.S.TypeBound.assoc-constraint", "S.TypeBound", "fn f<T: Bound<Item = Int>>() {}", assert_any_type_bound),
    SyntaxCase::valid("V.S.TypeBound.mixed", "S.TypeBound", "fn f<T: Bound<Int, Item = Str>>() {}", assert_type_bound),
    SyntaxCase::valid("V.S.TypeBound.many", "S.TypeBound", "fn f<T: Bound<Int, Str>>() {}", assert_any_type_bound),
    SyntaxCase::valid("V.S.TypeBound.trailing", "S.TypeBound", "fn f<T: Bound<Int,>>() {}", assert_any_type_bound),
    SyntaxCase::invalid("I.S.TypeBound.leading-comma", "S.TypeBound", "fn f<T: Bound<,Int>>() {}", "E0101", ","),
    SyntaxCase::invalid("I.S.TypeBound.double-comma", "S.TypeBound", "fn f<T: Bound<Int,,Str>>() {}", "E0101", ","),
    SyntaxCase::invalid("I.S.TypeBound.missing-comma", "S.TypeBound", "fn f<T: Bound<Int Str>>() {}", "E0103", "Str"),
    SyntaxCase::invalid("I.S.TypeBound.empty-angles", "S.TypeBound", "fn f<T: Bound<>>() {}", "E0101", ">"),
    SyntaxCase::valid("V.S.BoundArg.type-and-associated", "S.BoundArg", "fn f<T: Bound<Int, Item = Str>>() {}", assert_type_bound),
    SyntaxCase::valid("V.S.BoundArg.type", "S.BoundArg", "fn f<T: Bound<Int>>() {}", assert_any_type_bound),
    SyntaxCase::valid("V.S.BoundArg.associated", "S.BoundArg", "fn f<T: Bound<Item = Str>>() {}", assert_any_type_bound),
    SyntaxCase::invalid("I.S.BoundArg.missing-associated-type", "S.BoundArg", "fn f<T: Bound<Item = >>() {}", "E0101", ">"),
    SyntaxCase::valid("V.S.TypeArgs.nested-trailing", "S.TypeArgs", "type X = Outer<Inner<Int,>, Str,>", assert_named_type_args),
    SyntaxCase::valid("V.S.TypeArgs.one", "S.TypeArgs", "type X = Outer<Int>", assert_named_type),
    SyntaxCase::valid("V.S.TypeArgs.many", "S.TypeArgs", "type X = Outer<Int, Str>", assert_named_type_args),
    SyntaxCase::valid("V.S.TypeArgs.many-trailing", "S.TypeArgs", "type X = Outer<Int, Str,>", assert_named_type_args),
    SyntaxCase::valid("V.S.TypeArgs.nested", "S.TypeArgs", "type X = Outer<Inner<Int>>", assert_named_type),
    SyntaxCase::invalid("I.S.TypeArgs.empty", "S.TypeArgs", "type X = Outer<>", "E0101", ">"),
    SyntaxCase::invalid("I.S.TypeArgs.leading-comma", "S.TypeArgs", "type X = Outer<,Int>", "E0101", ","),
    SyntaxCase::invalid("I.S.TypeArgs.double-comma", "S.TypeArgs", "type X = Outer<Int,,Str>", "E0101", ","),
    SyntaxCase::invalid("I.S.TypeArgs.missing-comma", "S.TypeArgs", "type X = Pair<Int Str>", "E0103", "Str"),
    SyntaxCase::valid("V.S.EffectExpr.generic", "S.EffectExpr", "fn f() with {io<Int>, mut<Int>, unsafe} {}", assert_effect_expr),
    SyntaxCase::valid("V.S.EffectExpr.plain", "S.EffectExpr", "fn f() with {io} {}", assert_one_effect),
    SyntaxCase::invalid("I.S.EffectExpr.empty-args", "S.EffectExpr", "fn f() with {io<>} {}", "E0101", ">"),
    SyntaxCase::valid("V.S.EffectName.all-alternatives", "S.EffectName", "fn f() with {module::io, mut<Int>, unsafe} {}", assert_effect_expr),
    SyntaxCase::valid("V.S.EffectName.one-segment", "S.EffectName", "fn f() with {io} {}", assert_one_effect),
    SyntaxCase::valid("V.S.EffectName.many-segment", "S.EffectName", "fn f() with {module::io} {}", assert_one_effect),
    SyntaxCase::valid("V.S.EffectName.mut", "S.EffectName", "fn f() with {mut<Int>} {}", assert_one_effect),
    SyntaxCase::valid("V.S.EffectName.unsafe", "S.EffectName", "fn f() with {unsafe} {}", assert_one_effect),
    SyntaxCase::invalid("I.S.EffectName.trailing-colon-colon", "S.EffectName", "fn f() with {io::} {}", "E0103", "}"),
];

pub(crate) fn cases() -> &'static [SyntaxCase] {
    CASES
}

#[test]
fn type_grammar_cases_are_executable() {
    run_syntax_cases(CASES);
}
