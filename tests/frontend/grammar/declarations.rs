use vorton::ast::{Decl, ImplKind, ImplMember, TraitMember, UseKind, VariantFields};

use super::coverage::AstCoverage;
use super::manifest::{SyntaxCase, run_syntax_cases};

const FULL_SURFACE: &str = include_str!("../fixtures/full_surface.vorton");

fn assert_empty_program(program: &vorton::ast::Program) {
    assert!(program.uses.is_empty());
    assert!(program.declarations.is_empty());
}

fn assert_nonempty_program(program: &vorton::ast::Program) {
    assert!(!program.uses.is_empty() || !program.declarations.is_empty());
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

fn assert_empty_effect_set(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    assert!(function.effects.as_ref().unwrap().effects.is_empty());
}

fn assert_one_effect(program: &vorton::ast::Program) {
    let Some(Decl::Function(function)) = program.declarations.first() else {
        panic!("function")
    };
    assert_eq!(function.effects.as_ref().unwrap().effects.len(), 1);
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

fn assert_bare_use(program: &vorton::ast::Program) {
    assert!(matches!(program.uses[0].kind, UseKind::Bare));
}

fn assert_alias_use(program: &vorton::ast::Program) {
    assert!(matches!(program.uses[0].kind, UseKind::PathAlias(_)));
}

fn assert_relative_grouped_uses(program: &vorton::ast::Program) {
    assert_eq!(program.uses.len(), 2);
    assert_eq!(program.uses[0].path.segments.len(), 1);
    assert_eq!(program.uses[1].path.segments.len(), 2);
    assert!(
        program
            .uses
            .iter()
            .all(|value| matches!(value.kind, UseKind::NamedItems(_)))
    );
}

fn assert_public_struct_field(program: &vorton::ast::Program) {
    let Some(Decl::Struct(value)) = program.declarations.first() else {
        panic!("struct")
    };
    assert!(value.fields[0].visibility.public);
}

fn assert_private_struct_field(program: &vorton::ast::Program) {
    let Some(Decl::Struct(value)) = program.declarations.first() else {
        panic!("struct")
    };
    assert!(!value.fields[0].visibility.public);
}

#[rustfmt::skip]
const CASES: &[SyntaxCase] = &[
    SyntaxCase::valid("V.S.Program.empty", "S.Program", "", assert_empty_program),
    SyntaxCase::valid("V.S.Program.uses-only", "S.Program", "use module", assert_nonempty_program),
    SyntaxCase::valid("V.S.Program.decls-only", "S.Program", "fn f() {}", assert_nonempty_program),
    SyntaxCase::valid("V.S.Program.uses-then-decls", "S.Program", "use module\nfn f() {}", assert_nonempty_program),
    SyntaxCase::valid("V.S.Program.many", "S.Program", "use module\nfn f() {}\nstruct S {}", assert_nonempty_program),
    SyntaxCase::invalid("I.S.Program.use-after-decl", "S.Program", "fn f() {} use m", "E0706", "use"),
    SyntaxCase::invalid("I.S.Program.file-requires", "S.Program", "requires {io}", "E0101", "requires"),
    SyntaxCase::invalid("I.S.Program.unexpected-token", "S.Program", ";", "E0101", ";"),
    SyntaxCase::valid("V.S.Decl.private-and-impl", "S.Decl", "impl T {}", assert_impl),
    SyntaxCase::valid("V.S.Decl.private-kind", "S.Decl", "fn f() {}", assert_function),
    SyntaxCase::valid("V.S.Decl.pub-kind", "S.Decl", "pub fn f() {}", assert_function),
    SyntaxCase::invalid("I.S.Decl.pub-impl", "S.Decl", "pub impl T {}", "E0101", "pub"),
    SyntaxCase::invalid("I.S.Decl.double-pub", "S.Decl", "pub pub fn f() {}", "E0101", "pub"),
    SyntaxCase::invalid("I.S.Decl.use-in-decl-position", "S.Decl", "fn f() {} use m", "E0706", "use"),
    SyntaxCase::valid("V.S.DeclKind.all-alternatives", "S.DeclKind", FULL_SURFACE, assert_all_decl_alternatives),
    SyntaxCase::valid("V.S.DeclKind.fn", "S.DeclKind", "fn f() {}", assert_function),
    SyntaxCase::valid("V.S.DeclKind.struct", "S.DeclKind", "struct S {}", assert_struct),
    SyntaxCase::valid("V.S.DeclKind.enum", "S.DeclKind", "enum E {}", assert_enum),
    SyntaxCase::valid("V.S.DeclKind.trait", "S.DeclKind", "trait T {}", assert_trait),
    SyntaxCase::valid("V.S.DeclKind.effect", "S.DeclKind", "effect E {}", assert_effect),
    SyntaxCase::valid("V.S.DeclKind.effect-alias", "S.DeclKind", "effect alias E = {}", assert_effect_alias),
    SyntaxCase::valid("V.S.DeclKind.extern", "S.DeclKind", "extern type T", assert_extern_type),
    SyntaxCase::valid("V.S.DeclKind.type-alias", "S.DeclKind", "type T = Int", assert_type_alias),
    SyntaxCase::valid("V.S.DeclKind.test", "S.DeclKind", "test \"x\" {}", assert_test),
    SyntaxCase::valid("V.S.DeclKind.const", "S.DeclKind", "const X = 1", assert_const),
    SyntaxCase::valid("V.S.DeclKind.mod", "S.DeclKind", "mod m {}", assert_module),
    SyntaxCase::invalid("I.S.DeclKind.impl-is-not-kind", "S.DeclKind", "pub impl T {}", "E0101", "pub"),
    SyntaxCase::invalid("I.S.DeclKind.unknown-start", "S.DeclKind", "unknown", "E0101", "unknown"),
    SyntaxCase::valid("V.S.FnDecl.all-optionals", "S.FnDecl", "pub fn f<T>(a: T, mut b) -> T with {io} { a }", assert_function),
    SyntaxCase::valid("V.S.FnDecl.minimal", "S.FnDecl", "fn f() {}", assert_function),
    SyntaxCase::valid("V.S.FnDecl.type-params", "S.FnDecl", "fn f<T>() {}", assert_function),
    SyntaxCase::valid("V.S.FnDecl.zero-params", "S.FnDecl", "fn f() {}", assert_function),
    SyntaxCase::valid("V.S.FnDecl.one-param", "S.FnDecl", "fn f(x) {}", assert_function),
    SyntaxCase::valid("V.S.FnDecl.many-params", "S.FnDecl", "fn f(x, y,) {}", assert_function),
    SyntaxCase::valid("V.S.FnDecl.return", "S.FnDecl", "fn f() -> Int {1}", assert_function),
    SyntaxCase::valid("V.S.FnDecl.effects", "S.FnDecl", "fn f() with {io} {}", assert_function),
    SyntaxCase::invalid("I.S.FnDecl.missing-name", "S.FnDecl", "fn () {}", "E0103", "("),
    SyntaxCase::invalid("I.S.FnDecl.missing-parens", "S.FnDecl", "fn f {}", "E0103", "{"),
    SyntaxCase::invalid("I.S.FnDecl.missing-block", "S.FnDecl", "fn f()", "E0103", ""),
    SyntaxCase::invalid("I.S.FnDecl.default-param", "S.FnDecl", "fn f(x = 1) {}", "E0101", "="),
    SyntaxCase::invalid("I.S.FnDecl.where", "S.FnDecl", "fn f(x: Int where x) {}", "E0101", "where"),
    SyntaxCase::invalid("I.S.FnDecl.bodyless", "S.FnDecl", "fn f()", "E0103", ""),
    SyntaxCase::valid("V.S.EffectAnnotation.nonempty-set", "S.EffectAnnotation", "fn f() with {io} {}", assert_function_effects),
    SyntaxCase::valid("V.S.EffectAnnotation.empty-set", "S.EffectAnnotation", "fn f() with {} {}", assert_empty_effect_set),
    SyntaxCase::invalid("I.S.EffectAnnotation.missing-set", "S.EffectAnnotation", "fn f() with fn g() {}", "E0103", "fn"),
    SyntaxCase::valid("V.S.EffectSet.many-trailing", "S.EffectSet", "fn f() with {io, fs,} {}", assert_function_effects),
    SyntaxCase::valid("V.S.EffectSet.zero", "S.EffectSet", "fn f() with {} {}", assert_empty_effect_set),
    SyntaxCase::valid("V.S.EffectSet.one", "S.EffectSet", "fn f() with {io} {}", assert_one_effect),
    SyntaxCase::valid("V.S.EffectSet.many", "S.EffectSet", "fn f() with {io, fs} {}", assert_function_effects),
    SyntaxCase::invalid("I.S.EffectSet.leading-comma", "S.EffectSet", "fn f() with {, io} {}", "E0103", ","),
    SyntaxCase::invalid("I.S.EffectSet.double-comma", "S.EffectSet", "fn f() with {io,, fs} {}", "E0103", ","),
    SyntaxCase::invalid("I.S.EffectSet.missing-comma", "S.EffectSet", "fn f() with {io fs} {}", "E0103", "fs"),
    SyntaxCase::invalid("I.S.EffectSet.missing-close", "S.EffectSet", "fn f() with {io", "E0103", ""),
    SyntaxCase::valid("V.S.Params.many-trailing", "S.Params", "fn f(a: Int, mut b,) {}", assert_function_params),
    SyntaxCase::valid("V.S.Params.zero", "S.Params", "fn f() {}", assert_function),
    SyntaxCase::valid("V.S.Params.one", "S.Params", "fn f(a) {}", assert_function),
    SyntaxCase::valid("V.S.Params.many", "S.Params", "fn f(a: Int, mut b) {}", assert_function_params),
    SyntaxCase::invalid("I.S.Params.leading-comma", "S.Params", "fn f(,a) {}", "E0103", ","),
    SyntaxCase::invalid("I.S.Params.double-comma", "S.Params", "fn f(a,,b) {}", "E0103", ","),
    SyntaxCase::invalid("I.S.Params.default-value", "S.Params", "fn f(a = 1) {}", "E0101", "="),
    SyntaxCase::invalid("I.S.Params.missing-comma", "S.Params", "fn f(a: Int b: Int) {}", "E0103", "b"),
    SyntaxCase::valid("V.S.Param.all-alternatives", "S.Param", "fn f(a: Int, mut b,) {}", assert_function_params),
    SyntaxCase::valid("V.S.Param.plain-untyped", "S.Param", "fn f(a) {}", assert_function),
    SyntaxCase::valid("V.S.Param.plain-typed", "S.Param", "fn f(a: Int) {}", assert_function),
    SyntaxCase::valid("V.S.Param.mut-untyped", "S.Param", "fn f(mut a) {}", assert_function),
    SyntaxCase::valid("V.S.Param.mut-typed", "S.Param", "fn f(mut a: Int) {}", assert_function),
    SyntaxCase::invalid("I.S.Param.missing-name", "S.Param", "fn f(: Int) {}", "E0103", ":"),
    SyntaxCase::invalid("I.S.Param.missing-type", "S.Param", "fn f(a:) {}", "E0101", ")"),
    SyntaxCase::valid("V.S.StructDecl.one-field", "S.StructDecl", "struct S {x: Int}", assert_struct),
    SyntaxCase::valid("V.S.StructDecl.empty", "S.StructDecl", "struct S {}", assert_struct),
    SyntaxCase::valid("V.S.StructDecl.many-fields", "S.StructDecl", "struct S {x: Int, y: Str}", assert_struct),
    SyntaxCase::valid("V.S.StructDecl.generic", "S.StructDecl", "struct S<T> {x: T}", assert_struct),
    SyntaxCase::invalid("I.S.StructDecl.missing-name", "S.StructDecl", "struct {}", "E0103", "{"),
    SyntaxCase::invalid("I.S.StructDecl.missing-body", "S.StructDecl", "struct S", "E0103", ""),
    SyntaxCase::invalid("I.S.StructDecl.unexpected-member", "S.StructDecl", "struct S {fn f() {}}", "E0103", "fn"),
    SyntaxCase::valid("V.S.StructField.private", "S.StructField", "struct S {x: Int}", assert_struct_field),
    SyntaxCase::valid("V.S.StructField.public-comma", "S.StructField", "struct S {pub x: Int,}", assert_public_struct_field),
    SyntaxCase::valid("V.S.StructField.public-no-comma", "S.StructField", "struct S {pub x: Int}", assert_public_struct_field),
    SyntaxCase::valid("V.S.StructField.private-comma", "S.StructField", "struct S {x: Int,}", assert_private_struct_field),
    SyntaxCase::valid("V.S.StructField.private-no-comma", "S.StructField", "struct S {x: Int}", assert_private_struct_field),
    SyntaxCase::invalid("I.S.StructField.missing-type", "S.StructField", "struct S {x:}", "E0101", "}"),
    SyntaxCase::invalid("I.S.StructField.double-comma", "S.StructField", "struct S {x: Int,,}", "E0103", ","),
    SyntaxCase::invalid("I.S.StructField.missing-colon", "S.StructField", "struct S {x Int}", "E0103", "Int"),
    SyntaxCase::valid("V.S.EnumDecl.mixed-field-kinds", "S.EnumDecl", "enum E {unit, tuple(Int,), named{x: Int,}}", assert_enum),
    SyntaxCase::valid("V.S.EnumDecl.empty", "S.EnumDecl", "enum E {}", assert_enum),
    SyntaxCase::valid("V.S.EnumDecl.one", "S.EnumDecl", "enum E {one}", assert_enum),
    SyntaxCase::valid("V.S.EnumDecl.many", "S.EnumDecl", "enum E {one, two}", assert_enum),
    SyntaxCase::valid("V.S.EnumDecl.generic", "S.EnumDecl", "enum E<T> {one(T)}", assert_enum),
    SyntaxCase::invalid("I.S.EnumDecl.missing-name", "S.EnumDecl", "enum {}", "E0103", "{"),
    SyntaxCase::invalid("I.S.EnumDecl.missing-body", "S.EnumDecl", "enum E", "E0103", ""),
    SyntaxCase::valid("V.S.EnumVariant.all-alternatives", "S.EnumVariant", "enum E {unit, tuple(Int), named{x: Int}}", assert_enum),
    SyntaxCase::valid("V.S.EnumVariant.adjacent-no-comma", "S.EnumVariant", "enum E {first second third(Int) fourth{x: Int}}", assert_enum),
    SyntaxCase::valid("V.S.EnumVariant.unit", "S.EnumVariant", "enum E {unit}", assert_enum),
    SyntaxCase::valid("V.S.EnumVariant.positional", "S.EnumVariant", "enum E {item(Int)}", assert_enum),
    SyntaxCase::valid("V.S.EnumVariant.named", "S.EnumVariant", "enum E {item{x: Int}}", assert_enum),
    SyntaxCase::valid("V.S.EnumVariant.comma", "S.EnumVariant", "enum E {unit,}", assert_enum),
    SyntaxCase::valid("V.S.EnumVariant.no-comma", "S.EnumVariant", "enum E {unit}", assert_enum),
    SyntaxCase::invalid("I.S.EnumVariant.empty-named-group", "S.EnumVariant", "enum E {unit {}}", "E0101", "}"),
    SyntaxCase::invalid("I.S.EnumVariant.unexpected-equals", "S.EnumVariant", "enum E {unit = Int}", "E0103", "="),
    SyntaxCase::invalid("I.S.EnumVariant.missing-field-comma", "S.EnumVariant", "enum E {tuple(Int Str)}", "E0103", "Str"),
    SyntaxCase::valid("V.S.VariantFields.positional-and-named", "S.VariantFields", "enum E {tuple(Int, Str,), named{x: Int, y: Str,}}", assert_variant_fields),
    SyntaxCase::valid("V.S.VariantFields.positional-one", "S.VariantFields", "enum E {item(Int)}", assert_enum),
    SyntaxCase::valid("V.S.VariantFields.positional-many", "S.VariantFields", "enum E {item(Int, Str)}", assert_enum),
    SyntaxCase::valid("V.S.VariantFields.positional-trailing", "S.VariantFields", "enum E {item(Int, Str,)}", assert_enum),
    SyntaxCase::valid("V.S.VariantFields.named-one", "S.VariantFields", "enum E {item{x: Int}}", assert_enum),
    SyntaxCase::valid("V.S.VariantFields.named-many", "S.VariantFields", "enum E {item{x: Int, y: Str}}", assert_enum),
    SyntaxCase::valid("V.S.VariantFields.named-trailing", "S.VariantFields", "enum E {item{x: Int, y: Str,}}", assert_enum),
    SyntaxCase::invalid("I.S.VariantFields.positional-empty", "S.VariantFields", "enum E {unit()}", "E0104", ")"),
    SyntaxCase::invalid("I.S.VariantFields.named-empty", "S.VariantFields", "enum E {unit {}}", "E0101", "}"),
    SyntaxCase::invalid("I.S.VariantFields.missing-comma", "S.VariantFields", "enum E {item(Int Str)}", "E0103", "Str"),
    SyntaxCase::invalid("I.S.VariantFields.double-comma", "S.VariantFields", "enum E {item(Int,,Str)}", "E0101", ","),
    SyntaxCase::valid("V.S.NamedField.minimal", "S.NamedField", "enum E {named{x: Int}}", assert_enum),
    SyntaxCase::invalid("I.S.NamedField.missing-name", "S.NamedField", "enum E {named{: Int}}", "E0103", ":"),
    SyntaxCase::invalid("I.S.NamedField.missing-colon", "S.NamedField", "enum E {named{x Int}}", "E0103", "Int"),
    SyntaxCase::invalid("I.S.NamedField.missing-type", "S.NamedField", "enum E {named{x:}}", "E0101", "}"),
    SyntaxCase::valid("V.S.ImplDecl.inherent-and-trait", "S.ImplDecl", "impl T {} impl Tr for T {}", assert_impl_kinds),
    SyntaxCase::valid("V.S.ImplDecl.inherent", "S.ImplDecl", "impl T {}", assert_impl),
    SyntaxCase::valid("V.S.ImplDecl.trait", "S.ImplDecl", "impl Tr for T {}", assert_impl),
    SyntaxCase::invalid("I.S.ImplDecl.pub-impl", "S.ImplDecl", "pub impl T {}", "E0101", "pub"),
    SyntaxCase::valid("V.S.InherentImplDecl.many-members", "S.InherentImplDecl", "impl T {type Item = Int fn f() {}}", assert_inherent_members),
    SyntaxCase::valid("V.S.InherentImplDecl.plain", "S.InherentImplDecl", "impl T {}", assert_impl),
    SyntaxCase::valid("V.S.InherentImplDecl.generic", "S.InherentImplDecl", "impl<T> Box<T> {}", assert_impl),
    SyntaxCase::valid("V.S.InherentImplDecl.target-args", "S.InherentImplDecl", "impl Box<Int> {}", assert_impl),
    SyntaxCase::valid("V.S.InherentImplDecl.empty-members", "S.InherentImplDecl", "impl T {}", assert_impl),
    SyntaxCase::invalid("I.S.InherentImplDecl.tuple-target", "S.InherentImplDecl", "impl (T, U) {}", "E0101", "(T, U)"),
    SyntaxCase::invalid("I.S.InherentImplDecl.fn-target", "S.InherentImplDecl", "impl fn() -> Int {}", "E0101", "fn() -> Int"),
    SyntaxCase::invalid("I.S.InherentImplDecl.record-target", "S.InherentImplDecl", "impl {x: Int} {}", "E0101", "{x: Int}"),
    SyntaxCase::invalid("I.S.InherentImplDecl.extern-member", "S.InherentImplDecl", "impl T {extern fn f()}", "E0101", "extern"),
    SyntaxCase::invalid("I.S.InherentImplDecl.delegate-member", "S.InherentImplDecl", "impl T {delegate f}", "E0101", "delegate"),
    SyntaxCase::valid("V.S.TraitImplDecl.target-args", "S.TraitImplDecl", "impl Tr<Int> for T<Int> {}", assert_impl),
    SyntaxCase::valid("V.S.TraitImplDecl.plain", "S.TraitImplDecl", "impl Tr for T {}", assert_impl),
    SyntaxCase::valid("V.S.TraitImplDecl.generic", "S.TraitImplDecl", "impl<T> Tr<T> for Box<T> {}", assert_impl),
    SyntaxCase::valid("V.S.TraitImplDecl.empty-members", "S.TraitImplDecl", "impl Tr for T {}", assert_impl),
    SyntaxCase::valid("V.S.TraitImplDecl.many-members", "S.TraitImplDecl", "impl Tr for T {type Item = Int fn f(){}}", assert_impl),
    SyntaxCase::invalid("I.S.TraitImplDecl.non-named-trait", "S.TraitImplDecl", "impl (Tr, Other) for T {}", "E0101", "(Tr, Other)"),
    SyntaxCase::invalid("I.S.TraitImplDecl.non-named-target", "S.TraitImplDecl", "impl Tr for (T, U) {}", "E0101", "(T, U)"),
    SyntaxCase::invalid("I.S.TraitImplDecl.pub-member", "S.TraitImplDecl", "impl Tr for T {pub fn f(){}}", "E0101", "pub"),
    SyntaxCase::invalid("I.S.TraitImplDecl.extern-member", "S.TraitImplDecl", "impl Tr for T {extern fn f()}", "E0101", "extern"),
    SyntaxCase::valid("V.S.InherentImplMember.fn-and-type", "S.InherentImplMember", "impl T {pub type Item = Int pub fn f() {}}", assert_inherent_members),
    SyntaxCase::valid("V.S.InherentImplMember.fn-private", "S.InherentImplMember", "impl T {fn f(){}}", assert_impl),
    SyntaxCase::valid("V.S.InherentImplMember.fn-pub", "S.InherentImplMember", "impl T {pub fn f(){}}", assert_impl),
    SyntaxCase::valid("V.S.InherentImplMember.type-private", "S.InherentImplMember", "impl T {type Item = Int}", assert_impl),
    SyntaxCase::valid("V.S.InherentImplMember.type-pub", "S.InherentImplMember", "impl T {pub type Item = Int}", assert_impl),
    SyntaxCase::invalid("I.S.InherentImplMember.extern-fn", "S.InherentImplMember", "impl T {extern fn f()}", "E0101", "extern"),
    SyntaxCase::invalid("I.S.InherentImplMember.delegate", "S.InherentImplMember", "impl T {delegate f}", "E0101", "delegate"),
    SyntaxCase::valid("V.S.TraitImplMember.fn-and-type", "S.TraitImplMember", "impl Tr for T {type Item = Int fn f() {}}", assert_impl),
    SyntaxCase::valid("V.S.TraitImplMember.fn", "S.TraitImplMember", "impl Tr for T {fn f(){}}", assert_impl),
    SyntaxCase::valid("V.S.TraitImplMember.type", "S.TraitImplMember", "impl Tr for T {type Item = Int}", assert_impl),
    SyntaxCase::invalid("I.S.TraitImplMember.pub-fn", "S.TraitImplMember", "impl Tr for T {pub fn f() {}}", "E0101", "pub"),
    SyntaxCase::invalid("I.S.TraitImplMember.pub-type", "S.TraitImplMember", "impl Tr for T {pub type Item = Int}", "E0101", "pub"),
    SyntaxCase::invalid("I.S.TraitImplMember.extern-fn", "S.TraitImplMember", "impl Tr for T {extern fn f()}", "E0101", "extern"),
    SyntaxCase::valid("V.S.TraitDecl.mixed-members", "S.TraitDecl", "trait Tr: A + B {type Item: A = Int; fn f<T>(x: T) -> Int with {};}", assert_trait),
    SyntaxCase::valid("V.S.TraitDecl.empty", "S.TraitDecl", "trait Tr {}", assert_trait),
    SyntaxCase::valid("V.S.TraitDecl.generic", "S.TraitDecl", "trait Tr<T> {}", assert_trait),
    SyntaxCase::valid("V.S.TraitDecl.one-super", "S.TraitDecl", "trait Tr: A {}", assert_trait),
    SyntaxCase::valid("V.S.TraitDecl.many-super", "S.TraitDecl", "trait Tr: A + B {}", assert_trait),
    SyntaxCase::invalid("I.S.TraitDecl.trailing-plus", "S.TraitDecl", "trait Tr: A + {}", "E0103", "{"),
    SyntaxCase::invalid("I.S.TraitDecl.body-method", "S.TraitDecl", "trait Tr {fn f(){}}", "E0101", "{"),
    SyntaxCase::invalid("I.S.TraitDecl.pub-member", "S.TraitDecl", "trait Tr {pub fn f()}", "E0101", "pub"),
    SyntaxCase::valid("V.S.TraitMember.all-alternatives", "S.TraitMember", "trait Tr {type Item fn f();}", assert_trait_members),
    SyntaxCase::valid("V.S.TraitMember.method", "S.TraitMember", "trait Tr {fn f()}", assert_trait),
    SyntaxCase::valid("V.S.TraitMember.assoc-type", "S.TraitMember", "trait Tr {type Item}", assert_trait),
    SyntaxCase::invalid("I.S.TraitMember.pub-member", "S.TraitMember", "trait Tr {pub fn f()}", "E0101", "pub"),
    SyntaxCase::invalid("I.S.TraitMember.unknown-member", "S.TraitMember", "trait Tr {const X = 1}", "E0101", "const"),
    SyntaxCase::valid("V.S.TraitMethod.semicolon", "S.TraitMethod", "trait Tr {fn f<T>(x: T) -> Int with {};}", assert_trait),
    SyntaxCase::valid("V.S.TraitMethod.minimal", "S.TraitMethod", "trait Tr {fn f()}", assert_trait),
    SyntaxCase::valid("V.S.TraitMethod.generic", "S.TraitMethod", "trait Tr {fn f<T>()}", assert_trait),
    SyntaxCase::valid("V.S.TraitMethod.params", "S.TraitMethod", "trait Tr {fn f(x: Int)}", assert_trait),
    SyntaxCase::valid("V.S.TraitMethod.return", "S.TraitMethod", "trait Tr {fn f() -> Int}", assert_trait),
    SyntaxCase::valid("V.S.TraitMethod.effects", "S.TraitMethod", "trait Tr {fn f() with {io}}", assert_trait),
    SyntaxCase::valid("V.S.TraitMethod.no-semicolon", "S.TraitMethod", "trait Tr {fn f()}", assert_trait),
    SyntaxCase::invalid("I.S.TraitMethod.body", "S.TraitMethod", "trait Tr {fn f() {}}", "E0101", "{"),
    SyntaxCase::invalid("I.S.TraitMethod.default-param", "S.TraitMethod", "trait Tr {fn f(x = 1)}", "E0101", "="),
    SyntaxCase::valid("V.S.AssocTypeDecl.bounds-default-semicolon", "S.AssocTypeDecl", "trait Tr {type Item: A + B = Int;}", assert_trait),
    SyntaxCase::valid("V.S.AssocTypeDecl.bare", "S.AssocTypeDecl", "trait Tr {type Item}", assert_trait),
    SyntaxCase::valid("V.S.AssocTypeDecl.one-bound", "S.AssocTypeDecl", "trait Tr {type Item: A}", assert_trait),
    SyntaxCase::valid("V.S.AssocTypeDecl.many-bounds", "S.AssocTypeDecl", "trait Tr {type Item: A + B}", assert_trait),
    SyntaxCase::valid("V.S.AssocTypeDecl.default", "S.AssocTypeDecl", "trait Tr {type Item = Int}", assert_trait),
    SyntaxCase::valid("V.S.AssocTypeDecl.semicolon", "S.AssocTypeDecl", "trait Tr {type Item;}", assert_trait),
    SyntaxCase::valid("V.S.AssocTypeDecl.no-semicolon", "S.AssocTypeDecl", "trait Tr {type Item}", assert_trait),
    SyntaxCase::invalid("I.S.AssocTypeDecl.missing-name", "S.AssocTypeDecl", "trait Tr {type}", "E0103", "}"),
    SyntaxCase::invalid("I.S.AssocTypeDecl.trailing-plus", "S.AssocTypeDecl", "trait Tr {type Item: A +}", "E0103", "}"),
    SyntaxCase::invalid("I.S.AssocTypeDecl.double-equals", "S.AssocTypeDecl", "trait Tr {type Item == Int}", "E0101", "=="),
    SyntaxCase::valid("V.S.EffectDecl.many-ops", "S.EffectDecl", "effect E {fn a() -> Int; fn b(x: Int) -> Int,}", assert_effect),
    SyntaxCase::valid("V.S.EffectDecl.empty", "S.EffectDecl", "effect E {}", assert_effect),
    SyntaxCase::valid("V.S.EffectDecl.generic", "S.EffectDecl", "effect E<T> {}", assert_effect),
    SyntaxCase::valid("V.S.EffectDecl.one-op", "S.EffectDecl", "effect E {fn a() -> Int}", assert_effect),
    SyntaxCase::invalid("I.S.EffectDecl.default-op-body", "S.EffectDecl", "effect E {fn a() -> Int {1}}", "E0101", "{"),
    SyntaxCase::invalid("I.S.EffectDecl.unknown-member", "S.EffectDecl", "effect E {const X = 1}", "E0103", "const"),
    SyntaxCase::valid("V.S.EffectOp.separator-alternatives", "S.EffectOp", "effect E {fn a() -> Int; fn b() -> Int,}", assert_effect_op),
    SyntaxCase::valid("V.S.EffectOp.no-separator", "S.EffectOp", "effect E {fn a() -> Int}", assert_effect),
    SyntaxCase::valid("V.S.EffectOp.semicolon", "S.EffectOp", "effect E {fn a() -> Int;}", assert_effect),
    SyntaxCase::valid("V.S.EffectOp.comma", "S.EffectOp", "effect E {fn a() -> Int,}", assert_effect),
    SyntaxCase::valid("V.S.EffectOp.params", "S.EffectOp", "effect E {fn a(x: Int) -> Int}", assert_effect),
    SyntaxCase::invalid("I.S.EffectOp.missing-return", "S.EffectOp", "effect E {fn a()}", "E0103", "}"),
    SyntaxCase::invalid("I.S.EffectOp.body", "S.EffectOp", "effect E {fn a() -> Int {1}}", "E0101", "{"),
    SyntaxCase::invalid("I.S.EffectOp.type-params", "S.EffectOp", "effect E {fn a<T>() -> Int}", "E0103", "<"),
    SyntaxCase::invalid("I.S.EffectOp.semicolon-comma", "S.EffectOp", "effect E {fn a() -> Int;,}", "E0101", ","),
    SyntaxCase::invalid("I.S.EffectOp.comma-semicolon", "S.EffectOp", "effect E {fn a() -> Int,;}", "E0101", ";"),
    SyntaxCase::invalid("I.S.EffectOp.double-separator", "S.EffectOp", "effect E {fn a() -> Int;;}", "E0101", ";"),
    SyntaxCase::invalid("I.S.EffectOp.default-param", "S.EffectOp", "effect E {fn a(x = 1) -> Int}", "E0101", "="),
    SyntaxCase::valid("V.S.EffectAliasDecl.generic", "S.EffectAliasDecl", "effect alias E<T> = {io<T>}", assert_effect_alias),
    SyntaxCase::valid("V.S.EffectAliasDecl.empty-set", "S.EffectAliasDecl", "effect alias E = {}", assert_effect_alias),
    SyntaxCase::valid("V.S.EffectAliasDecl.nonempty-set", "S.EffectAliasDecl", "effect alias E = {io}", assert_effect_alias),
    SyntaxCase::invalid("I.S.EffectAliasDecl.missing-alias-word", "S.EffectAliasDecl", "effect E = {}", "E0103", "="),
    SyntaxCase::invalid("I.S.EffectAliasDecl.missing-equals", "S.EffectAliasDecl", "effect alias E {io}", "E0103", "{"),
    SyntaxCase::invalid("I.S.EffectAliasDecl.missing-set", "S.EffectAliasDecl", "effect alias E =", "E0103", ""),
    SyntaxCase::valid("V.S.ExternDecl.fn", "S.ExternDecl", "extern fn f() -> Int with {io}", assert_extern_function),
    SyntaxCase::valid("V.S.ExternDecl.type", "S.ExternDecl", "extern type T", assert_extern_type),
    SyntaxCase::invalid("I.S.ExternDecl.unknown-kind", "S.ExternDecl", "extern const X", "E0103", "const"),
    SyntaxCase::valid("V.S.ExternKind.type", "S.ExternKind", "extern type Handle<T>", assert_extern_type),
    SyntaxCase::valid("V.S.ExternKind.fn", "S.ExternKind", "extern fn f()", assert_extern_function),
    SyntaxCase::valid("V.S.ExternKind.fn-generic", "S.ExternKind", "extern fn f<T>(x: T)", assert_extern_function),
    SyntaxCase::valid("V.S.ExternKind.fn-return", "S.ExternKind", "extern fn f() -> Int", assert_extern_function),
    SyntaxCase::valid("V.S.ExternKind.fn-effects", "S.ExternKind", "extern fn f() with {io}", assert_extern_function),
    SyntaxCase::valid("V.S.ExternKind.type-generic", "S.ExternKind", "extern type T<A>", assert_extern_type),
    SyntaxCase::invalid("I.S.ExternKind.fn-body", "S.ExternKind", "extern fn f() {}", "E0101", "{"),
    SyntaxCase::invalid("I.S.ExternKind.extra-semicolon", "S.ExternKind", "extern fn f();", "E0101", ";"),
    SyntaxCase::invalid("I.S.ExternKind.unknown-kind", "S.ExternKind", "extern const X", "E0103", "const"),
    SyntaxCase::valid("V.S.TypeAliasDecl.generic", "S.TypeAliasDecl", "type Id<T> = T", assert_type_alias),
    SyntaxCase::valid("V.S.TypeAliasDecl.plain", "S.TypeAliasDecl", "type Id = Int", assert_type_alias),
    SyntaxCase::invalid("I.S.TypeAliasDecl.missing-equals", "S.TypeAliasDecl", "type Id Int", "E0103", "Int"),
    SyntaxCase::invalid("I.S.TypeAliasDecl.extra-semicolon", "S.TypeAliasDecl", "type Id = Int;", "E0101", ";"),
    SyntaxCase::valid("V.S.ConstDecl.typed", "S.ConstDecl", "const X: Int = 1", assert_const),
    SyntaxCase::valid("V.S.ConstDecl.inferred", "S.ConstDecl", "const X = 1", assert_const),
    SyntaxCase::invalid("I.S.ConstDecl.missing-equals", "S.ConstDecl", "const X Int", "E0103", "Int"),
    SyntaxCase::invalid("I.S.ConstDecl.extra-semicolon", "S.ConstDecl", "const X = 1;", "E0101", ";"),
    SyntaxCase::valid("V.S.TestDecl.plain-string", "S.TestDecl", "test \"case\" {}", assert_test),
    SyntaxCase::invalid("I.S.TestDecl.raw-string", "S.TestDecl", "test r\"case\" {}", "E0103", "r\"case\""),
    SyntaxCase::invalid("I.S.TestDecl.interpolated-string", "S.TestDecl", "test \"case ${x}\" {}", "E0103", "\"case ${"),
    SyntaxCase::invalid("I.S.TestDecl.missing-block", "S.TestDecl", "test \"case\"", "E0103", ""),
    SyntaxCase::valid("V.S.ModDecl.uses-then-decls", "S.ModDecl", "mod m requires {io} {use x fn f() {}}", assert_module),
    SyntaxCase::valid("V.S.ModDecl.empty", "S.ModDecl", "mod m {}", assert_module),
    SyntaxCase::valid("V.S.ModDecl.requires-empty", "S.ModDecl", "mod m requires {} {}", assert_module),
    SyntaxCase::valid("V.S.ModDecl.requires-many", "S.ModDecl", "mod m requires {io, fs} {}", assert_module),
    SyntaxCase::valid("V.S.ModDecl.uses-only", "S.ModDecl", "mod m {use x}", assert_module),
    SyntaxCase::valid("V.S.ModDecl.decls-only", "S.ModDecl", "mod m {fn f(){}}", assert_module),
    SyntaxCase::valid("V.S.ModDecl.nested", "S.ModDecl", "mod m {mod n {}}", assert_module),
    SyntaxCase::invalid("I.S.ModDecl.file-header-shape", "S.ModDecl", "requires {io}", "E0101", "requires"),
    SyntaxCase::invalid("I.S.ModDecl.use-after-decl", "S.ModDecl", "mod m {fn f() {} use x}", "E0706", "use"),
    SyntaxCase::valid("V.S.UseDecl.all-alternatives", "S.UseDecl", "use a\nuse b as c\nuse d::{x as y}\n", assert_uses),
    SyntaxCase::valid("V.S.UseDecl.private", "S.UseDecl", "use module", assert_bare_use),
    SyntaxCase::valid("V.S.UseDecl.pub", "S.UseDecl", "pub use module", assert_bare_use),
    SyntaxCase::valid("V.S.UseDecl.bare", "S.UseDecl", "use module", assert_bare_use),
    SyntaxCase::valid("V.S.UseDecl.path-alias", "S.UseDecl", "use module as alias", assert_alias_use),
    SyntaxCase::valid("V.S.UseDecl.grouped", "S.UseDecl", "use module::{item}", assert_named_use),
    SyntaxCase::invalid("I.S.UseDecl.extra-semicolon", "S.UseDecl", "use module;", "E0101", ";"),
    SyntaxCase::invalid("I.S.UseDecl.missing-path", "S.UseDecl", "use", "E0103", ""),
    SyntaxCase::invalid("I.S.UseDecl.bare-super", "S.UseDecl", "use super", "E0101", "super"),
    SyntaxCase::valid("V.S.UseKind.grouped-alias", "S.UseKind", "use d::{x as y, z,}", assert_named_use),
    SyntaxCase::valid("V.S.UseKind.bare", "S.UseKind", "use d", assert_bare_use),
    SyntaxCase::valid("V.S.UseKind.path-alias", "S.UseKind", "use d as alias", assert_alias_use),
    SyntaxCase::valid("V.S.UseKind.grouped-one", "S.UseKind", "use d::{x}", assert_named_use),
    SyntaxCase::valid("V.S.UseKind.grouped-many", "S.UseKind", "use d::{x, y}", assert_named_use),
    SyntaxCase::valid("V.S.UseKind.grouped-trailing", "S.UseKind", "use d::{x, y,}", assert_named_use),
    SyntaxCase::invalid("I.S.UseKind.empty-group", "S.UseKind", "use d::{}", "E0101", "}"),
    SyntaxCase::invalid("I.S.UseKind.group-without-colon-colon", "S.UseKind", "use d {x}", "E0101", "{"),
    SyntaxCase::invalid("I.S.UseKind.missing-alias", "S.UseKind", "use d as", "E0103", ""),
    SyntaxCase::valid("V.S.UseItem.alias", "S.UseItem", "use d::{x as y}", assert_use_item_alias),
    SyntaxCase::valid("V.S.UseItem.plain", "S.UseItem", "use d::{x}", assert_named_use),
    SyntaxCase::invalid("I.S.UseItem.missing-name", "S.UseItem", "use d::{,}", "E0103", ","),
    SyntaxCase::invalid("I.S.UseItem.missing-alias", "S.UseItem", "use d::{x as}", "E0103", "}"),
    SyntaxCase::valid("V.S.RelativeGroupedUse.single-and-multi", "S.RelativeGroupedUse", "use super::{value, helper}\nuse super::super::{root}", assert_relative_grouped_uses),
    SyntaxCase::invalid("I.S.RelativeGroupedUse.missing-separator", "S.RelativeGroupedUse", "use super {value}", "E0101", "{"),
    SyntaxCase::valid("V.S.GroupedUse.many-trailing", "S.GroupedUse", "use super::{value, helper,}", assert_named_use),
    SyntaxCase::invalid("I.S.GroupedUse.empty", "S.GroupedUse", "use super::{}", "E0101", "}"),
];

pub(crate) fn cases() -> &'static [SyntaxCase] {
    CASES
}

#[test]
fn declaration_grammar_cases_are_executable() {
    run_syntax_cases(CASES);
}
