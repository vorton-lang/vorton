use vorton::ast::{Decl, ImplKind, ImplMember, TraitMember, UseKind, VariantFields};

use super::coverage::AstCoverage;
use super::manifest::{SyntaxCase, run_syntax_cases};

const FULL_SURFACE: &str = include_str!("../fixtures/full_surface.vorton");

fn assert_empty_program(program: &vorton::ast::Program) {
    assert!(program.uses.is_empty());
    assert!(program.declarations.is_empty());
}

fn assert_all_decl_alternatives(program: &vorton::ast::Program) {
    let mut coverage = AstCoverage::default();
    coverage.visit_program(program);
    for tag in [
        "Decl::Function",
        "Decl::Struct",
        "Decl::Enum",
        "Decl::Trait",
        "Decl::Impl",
        "Decl::Effect",
        "Decl::EffectAlias",
        "Decl::ExternFunction",
        "Decl::ExternType",
        "Decl::TypeAlias",
        "Decl::Test",
        "Decl::Const",
        "Decl::Module",
    ] {
        assert!(coverage.variants.contains(tag), "missing {tag}");
    }
}

macro_rules! decl_assertion {
    ($name:ident, $pattern:pat) => {
        fn $name(program: &vorton::ast::Program) {
            assert!(matches!(program.declarations.first(), Some($pattern)));
        }
    };
}

decl_assertion!(assert_function, Decl::Function(_));
decl_assertion!(assert_struct, Decl::Struct(_));
decl_assertion!(assert_enum, Decl::Enum(_));
decl_assertion!(assert_trait, Decl::Trait(_));
decl_assertion!(assert_impl, Decl::Impl(_));
decl_assertion!(assert_effect, Decl::Effect(_));
decl_assertion!(assert_effect_alias, Decl::EffectAlias(_));
decl_assertion!(assert_extern_function, Decl::ExternFunction(_));
decl_assertion!(assert_extern_type, Decl::ExternType(_));
decl_assertion!(assert_type_alias, Decl::TypeAlias(_));
decl_assertion!(assert_const, Decl::Const(_));
decl_assertion!(assert_test, Decl::Test(_));
decl_assertion!(assert_module, Decl::Module(_));

fn assert_function_effects(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    assert!(function.effects.is_some());
}

fn assert_function_params(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    assert_eq!(function.params.len(), 2);
    assert!(function.params[0].type_annotation.is_some());
    assert!(function.params[1].mutable);
}

fn assert_struct_field(program: &vorton::ast::Program) {
    let Some(Decl::Struct(value)) = program.declarations.first() else {
        panic!("struct")
    };
    assert_eq!(value.fields.len(), 1);
}

fn assert_variant_fields(program: &vorton::ast::Program) {
    let Some(Decl::Enum(value)) = program.declarations.first() else {
        panic!("enum")
    };
    assert!(matches!(
        value.variants[0].fields,
        VariantFields::Positional(_)
    ));
    assert!(matches!(value.variants[1].fields, VariantFields::Named(_)));
}

fn assert_impl_kinds(program: &vorton::ast::Program) {
    let mut kinds = program.declarations.iter().filter_map(|decl| match decl {
        Decl::Impl(value) => Some(&value.kind),
        _ => None,
    });
    assert!(matches!(kinds.next(), Some(ImplKind::Inherent { .. })));
    assert!(matches!(kinds.next(), Some(ImplKind::Trait { .. })));
}

fn assert_inherent_members(program: &vorton::ast::Program) {
    let Some(Decl::Impl(value)) = program.declarations.first() else {
        panic!("impl")
    };
    assert!(matches!(value.members[0], ImplMember::AssociatedType(_)));
    assert!(matches!(value.members[1], ImplMember::Method(_)));
}

fn assert_trait_members(program: &vorton::ast::Program) {
    let Some(Decl::Trait(value)) = program.declarations.first() else {
        panic!("trait")
    };
    assert!(matches!(value.members[0], TraitMember::AssociatedType(_)));
    assert!(matches!(value.members[1], TraitMember::Method(_)));
}

fn assert_effect_op(program: &vorton::ast::Program) {
    let Some(Decl::Effect(value)) = program.declarations.first() else {
        panic!("effect")
    };
    assert_eq!(value.operations.len(), 2);
}

fn assert_uses(program: &vorton::ast::Program) {
    assert_eq!(program.uses.len(), 3);
    assert!(matches!(program.uses[0].kind, UseKind::Bare));
    assert!(matches!(program.uses[1].kind, UseKind::PathAlias(_)));
    assert!(matches!(program.uses[2].kind, UseKind::NamedItems(_)));
}

fn assert_use_item_alias(program: &vorton::ast::Program) {
    let UseKind::NamedItems(items) = &program.uses[0].kind else {
        panic!("named items")
    };
    assert!(items[0].alias.is_some());
}

fn assert_named_use(program: &vorton::ast::Program) {
    assert!(matches!(program.uses[0].kind, UseKind::NamedItems(_)));
}

#[rustfmt::skip]
const CASES: &[SyntaxCase] = &[
    SyntaxCase::valid("V.S.Program.empty", "S.Program", "", assert_empty_program),
    SyntaxCase::invalid("I.S.Program.use-after-decl", "S.Program", "fn f() {} use m", "E0706", "use"),
    SyntaxCase::valid("V.S.Decl.private-and-impl", "S.Decl", "impl T {}", assert_impl),
    SyntaxCase::invalid("I.S.Decl.pub-impl", "S.Decl", "pub impl T {}", "E0101", "pub"),
    SyntaxCase::valid("V.S.DeclKind.all-alternatives", "S.DeclKind", FULL_SURFACE, assert_all_decl_alternatives),
    SyntaxCase::invalid("I.S.DeclKind.unknown-start", "S.DeclKind", "unknown", "E0101", "unknown"),
    SyntaxCase::valid("V.S.FnDecl.all-optionals", "S.FnDecl", "pub fn f<T>(a: T, mut b) -> T with {io} { a }", assert_function),
    SyntaxCase::invalid("I.S.FnDecl.missing-name", "S.FnDecl", "fn () {}", "E0103", "("),
    SyntaxCase::valid("V.S.EffectAnnotation.nonempty-set", "S.EffectAnnotation", "fn f() with {io} {}", assert_function_effects),
    SyntaxCase::invalid("I.S.EffectAnnotation.missing-set", "S.EffectAnnotation", "fn f() with fn g() {}", "E0103", "fn"),
    SyntaxCase::valid("V.S.EffectSet.many-trailing", "S.EffectSet", "fn f() with {io, fs,} {}", assert_function_effects),
    SyntaxCase::invalid("I.S.EffectSet.missing-comma", "S.EffectSet", "fn f() with {io fs} {}", "E0103", "fs"),
    SyntaxCase::valid("V.S.Params.many-trailing", "S.Params", "fn f(a: Int, mut b,) {}", assert_function_params),
    SyntaxCase::invalid("I.S.Params.missing-comma", "S.Params", "fn f(a: Int b: Int) {}", "E0103", "b"),
    SyntaxCase::valid("V.S.Param.all-alternatives", "S.Param", "fn f(a: Int, mut b,) {}", assert_function_params),
    SyntaxCase::invalid("I.S.Param.missing-type", "S.Param", "fn f(a:) {}", "E0101", ")"),
    SyntaxCase::valid("V.S.StructDecl.one-field", "S.StructDecl", "struct S {x: Int}", assert_struct),
    SyntaxCase::invalid("I.S.StructDecl.missing-body", "S.StructDecl", "struct S", "E0103", ""),
    SyntaxCase::valid("V.S.StructField.private", "S.StructField", "struct S {x: Int}", assert_struct_field),
    SyntaxCase::invalid("I.S.StructField.missing-colon", "S.StructField", "struct S {x Int}", "E0103", "Int"),
    SyntaxCase::valid("V.S.EnumDecl.mixed-field-kinds", "S.EnumDecl", "enum E {unit, tuple(Int,), named{x: Int,}}", assert_enum),
    SyntaxCase::invalid("I.S.EnumDecl.missing-body", "S.EnumDecl", "enum E", "E0103", ""),
    SyntaxCase::valid("V.S.EnumVariant.all-alternatives", "S.EnumVariant", "enum E {unit, tuple(Int), named{x: Int}}", assert_enum),
    SyntaxCase::invalid("I.S.EnumVariant.unexpected-equals", "S.EnumVariant", "enum E {unit = Int}", "E0103", "="),
    SyntaxCase::valid("V.S.VariantFields.positional-and-named", "S.VariantFields", "enum E {tuple(Int, Str,), named{x: Int, y: Str,}}", assert_variant_fields),
    SyntaxCase::invalid("I.S.VariantFields.positional-empty", "S.VariantFields", "enum E {unit()}", "E0104", ")"),
    SyntaxCase::valid("V.S.NamedField.minimal", "S.NamedField", "enum E {named{x: Int}}", assert_enum),
    SyntaxCase::invalid("I.S.NamedField.missing-colon", "S.NamedField", "enum E {named{x Int}}", "E0103", "Int"),
    SyntaxCase::valid("V.S.ImplDecl.inherent-and-trait", "S.ImplDecl", "impl T {} impl Tr for T {}", assert_impl_kinds),
    SyntaxCase::invalid("I.S.ImplDecl.pub-impl", "S.ImplDecl", "pub impl T {}", "E0101", "pub"),
    SyntaxCase::valid("V.S.InherentImplDecl.many-members", "S.InherentImplDecl", "impl T {type Item = Int fn f() {}}", assert_inherent_members),
    SyntaxCase::invalid("I.S.InherentImplDecl.tuple-target", "S.InherentImplDecl", "impl (T, U) {}", "E0101", "(T, U)"),
    SyntaxCase::valid("V.S.TraitImplDecl.target-args", "S.TraitImplDecl", "impl Tr<Int> for T<Int> {}", assert_impl),
    SyntaxCase::invalid("I.S.TraitImplDecl.non-named-target", "S.TraitImplDecl", "impl Tr for (T, U) {}", "E0101", "(T, U)"),
    SyntaxCase::valid("V.S.InherentImplMember.fn-and-type", "S.InherentImplMember", "impl T {pub type Item = Int pub fn f() {}}", assert_inherent_members),
    SyntaxCase::invalid("I.S.InherentImplMember.extern-fn", "S.InherentImplMember", "impl T {extern fn f()}", "E0101", "extern"),
    SyntaxCase::valid("V.S.TraitImplMember.fn-and-type", "S.TraitImplMember", "impl Tr for T {type Item = Int fn f() {}}", assert_impl),
    SyntaxCase::invalid("I.S.TraitImplMember.pub-fn", "S.TraitImplMember", "impl Tr for T {pub fn f() {}}", "E0101", "pub"),
    SyntaxCase::valid("V.S.TraitDecl.mixed-members", "S.TraitDecl", "trait Tr: A + B {type Item: A = Int; fn f<T>(x: T) -> Int with {};}", assert_trait),
    SyntaxCase::invalid("I.S.TraitDecl.trailing-plus", "S.TraitDecl", "trait Tr: A + {}", "E0103", "{"),
    SyntaxCase::valid("V.S.TraitMember.all-alternatives", "S.TraitMember", "trait Tr {type Item fn f();}", assert_trait_members),
    SyntaxCase::invalid("I.S.TraitMember.unknown-member", "S.TraitMember", "trait Tr {const X = 1}", "E0101", "const"),
    SyntaxCase::valid("V.S.TraitMethod.semicolon", "S.TraitMethod", "trait Tr {fn f<T>(x: T) -> Int with {};}", assert_trait),
    SyntaxCase::invalid("I.S.TraitMethod.body", "S.TraitMethod", "trait Tr {fn f() {}}", "E0101", "{"),
    SyntaxCase::valid("V.S.AssocTypeDecl.bounds-default-semicolon", "S.AssocTypeDecl", "trait Tr {type Item: A + B = Int;}", assert_trait),
    SyntaxCase::invalid("I.S.AssocTypeDecl.double-equals", "S.AssocTypeDecl", "trait Tr {type Item == Int}", "E0101", "=="),
    SyntaxCase::valid("V.S.EffectDecl.many-ops", "S.EffectDecl", "effect E {fn a() -> Int; fn b(x: Int) -> Int,}", assert_effect),
    SyntaxCase::invalid("I.S.EffectDecl.unknown-member", "S.EffectDecl", "effect E {const X = 1}", "E0103", "const"),
    SyntaxCase::valid("V.S.EffectOp.separator-alternatives", "S.EffectOp", "effect E {fn a() -> Int; fn b() -> Int,}", assert_effect_op),
    SyntaxCase::invalid("I.S.EffectOp.semicolon-comma", "S.EffectOp", "effect E {fn a() -> Int;,}", "E0101", ","),
    SyntaxCase::valid("V.S.EffectAliasDecl.generic", "S.EffectAliasDecl", "effect alias E<T> = {io<T>}", assert_effect_alias),
    SyntaxCase::invalid("I.S.EffectAliasDecl.missing-equals", "S.EffectAliasDecl", "effect alias E {io}", "E0103", "{"),
    SyntaxCase::valid("V.S.ExternDecl.fn", "S.ExternDecl", "extern fn f() -> Int with {io}", assert_extern_function),
    SyntaxCase::invalid("I.S.ExternDecl.unknown-kind", "S.ExternDecl", "extern const X", "E0103", "const"),
    SyntaxCase::valid("V.S.ExternKind.type", "S.ExternKind", "extern type Handle<T>", assert_extern_type),
    SyntaxCase::invalid("I.S.ExternKind.fn-body", "S.ExternKind", "extern fn f() {}", "E0101", "{"),
    SyntaxCase::valid("V.S.TypeAliasDecl.generic", "S.TypeAliasDecl", "type Id<T> = T", assert_type_alias),
    SyntaxCase::invalid("I.S.TypeAliasDecl.extra-semicolon", "S.TypeAliasDecl", "type Id = Int;", "E0101", ";"),
    SyntaxCase::valid("V.S.ConstDecl.typed", "S.ConstDecl", "const X: Int = 1", assert_const),
    SyntaxCase::invalid("I.S.ConstDecl.extra-semicolon", "S.ConstDecl", "const X = 1;", "E0101", ";"),
    SyntaxCase::valid("V.S.TestDecl.plain-string", "S.TestDecl", "test \"case\" {}", assert_test),
    SyntaxCase::invalid("I.S.TestDecl.raw-string", "S.TestDecl", "test r\"case\" {}", "E0103", "r\"case\""),
    SyntaxCase::valid("V.S.ModDecl.uses-then-decls", "S.ModDecl", "mod m requires {io} {use x fn f() {}}", assert_module),
    SyntaxCase::invalid("I.S.ModDecl.use-after-decl", "S.ModDecl", "mod m {fn f() {} use x}", "E0706", "use"),
    SyntaxCase::valid("V.S.UseDecl.all-alternatives", "S.UseDecl", "use a\nuse b as c\nuse d::{x as y}\n", assert_uses),
    SyntaxCase::invalid("I.S.UseDecl.missing-path", "S.UseDecl", "use", "E0103", ""),
    SyntaxCase::valid("V.S.UseKind.grouped-alias", "S.UseKind", "use d::{x as y, z,}", assert_named_use),
    SyntaxCase::invalid("I.S.UseKind.empty-group", "S.UseKind", "use d::{}", "E0101", "}"),
    SyntaxCase::valid("V.S.UseItem.alias", "S.UseItem", "use d::{x as y}", assert_use_item_alias),
    SyntaxCase::invalid("I.S.UseItem.missing-alias", "S.UseItem", "use d::{x as}", "E0103", "}"),
];

pub(crate) fn cases() -> &'static [SyntaxCase] {
    CASES
}

#[test]
fn declaration_grammar_cases_are_executable() {
    run_syntax_cases(CASES);
}
