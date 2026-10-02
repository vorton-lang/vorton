use vorton_compiler::ast::*;
use vorton_compiler::diagnostic::{
    ExpectedToken, FoundToken, FrontendDiagnosticKind, LayoutDiagnosticKind, LexicalDiagnosticKind,
    TokenClass,
};
use vorton_compiler::parse;

fn first_function(source: &str) -> FunctionDeclaration {
    let mut program = parse(source).expect("source should parse");
    let DeclarationKind::Function(function) = program.items.remove(0).kind else {
        panic!("first declaration should be a function")
    };
    function.item
}

fn declaration(program: &Program, index: usize) -> &Declaration {
    &program.items[index]
}

fn parameter_type(parameter: &Parameter) -> &TypeExpr {
    parameter.ty.as_ref().expect("parameter type")
}

fn return_type(function: &FunctionDeclaration) -> &TypeExpr {
    function
        .signature
        .return_type
        .as_ref()
        .expect("return type")
}

fn first_function_body(source: &str) -> Block {
    first_function(source).body
}

fn tail_expression(expression: &str) -> Expr {
    let source = format!("fn probe() {{ {expression} }}");
    *first_function_body(&source)
        .tail
        .expect("function should have a tail")
}

#[test]
fn parses_all_declaration_families_and_type_carriers() {
    let source = r#"
requires {unsafe, console}
pub use api::{Thing as PublicThing, make,}
use super::support
use api::Thing as LocalThing

pub fn transform<T: Show + Eq + Source<Item = Int>, F: Display>(
    value: &T,
    callback: F,
    pair: (Int, Str),
) -> Option<T> with {console} {
    value
}

pub struct Box<T> {
    pub value: T,
    hidden: Int,
}

enum Choice<T> {
    none,
    one(T,),
    named { value: T, code: Int, },
    empty {},
}

impl<T> Box<T> {
    pub fn get(self) -> T { self.value }
    pub type Item = T
}

impl<T: Show> Show for Box<T> {
    type Output = Str
    fn show(self) -> Str { "box" }
}

pub trait Show<T>: Eq + Debug {
    type Output: Eq + Debug = Str
    fn show(self, other: T) -> Output with {}
}

effect alias {
    fn read(key: Str) -> Str
}

pub effect alias Host<T> = {Reader<T>, fail<T>, unsafe}
extern fn host<T>(value: T) -> Unit with {unsafe}
extern type Handle<T>
type Mapper<T> = T
const origin: Point = Point { x: 0, y: 0 }
fn test(test: Int) -> Int { test }

pub mod inner requires {} {
    use super::Thing
    fn unit() { () }
}
"#;

    let program = parse(source).unwrap();
    assert!(program.requires.is_some());
    assert_eq!(program.uses.len(), 3);
    assert!(program.uses[0].visibility.is_some());
    assert!(matches!(
        program.uses[0].suffix,
        Some(UseSuffix::Items { .. })
    ));
    assert!(program.uses[1].suffix.is_none());
    assert!(matches!(program.uses[2].suffix, Some(UseSuffix::Alias(_))));
    assert_eq!(program.items.len(), 14);

    let DeclarationKind::Function(function) = &declaration(&program, 0).kind else {
        panic!("function declaration expected")
    };
    assert!(function.visibility.is_some());
    assert_eq!(function.item.signature.type_parameters[0].bounds.len(), 3);
    assert!(matches!(
        function.item.signature.type_parameters[0].bounds[2],
        Spanned {
            kind: NamedTypeKind { ref arguments, .. },
            ..
        } if matches!(arguments[0], TypeArgument::AssociatedType { .. })
    ));
    assert!(matches!(
        function.item.signature.parameters[0]
            .borrow
            .as_ref()
            .map(|borrow| borrow.kind),
        Some(BorrowKind::Shared)
    ));
    assert!(function.item.signature.parameters[1].borrow.is_none());
    assert!(matches!(
        parameter_type(&function.item.signature.parameters[2]).kind,
        TypeKind::Tuple(ref values) if values.len() == 2
    ));
    assert!(matches!(
        return_type(&function.item).kind,
        TypeKind::Named(NamedTypeKind { ref arguments, .. })
            if matches!(arguments[0], TypeArgument::Type(_))
    ));

    let DeclarationKind::Struct(structure) = &declaration(&program, 1).kind else {
        panic!("struct declaration expected")
    };
    assert!(structure.item.fields[0].visibility.is_some());
    assert!(structure.item.fields[1].visibility.is_none());

    let DeclarationKind::Enum(enumeration) = &declaration(&program, 2).kind else {
        panic!("enum declaration expected")
    };
    assert!(matches!(
        enumeration.item.variants[0].fields,
        VariantFields::Unit
    ));
    assert!(matches!(
        enumeration.item.variants[1].fields,
        VariantFields::Positional(ref fields) if fields.len() == 1
    ));
    assert!(matches!(
        enumeration.item.variants[2].fields,
        VariantFields::Named(ref fields) if fields.len() == 2
    ));
    assert!(matches!(
        enumeration.item.variants[3].fields,
        VariantFields::Named(ref fields) if fields.is_empty()
    ));

    assert!(matches!(
        declaration(&program, 3).kind,
        DeclarationKind::InherentImpl(_)
    ));
    assert!(matches!(
        declaration(&program, 4).kind,
        DeclarationKind::TraitImpl(_)
    ));
    let DeclarationKind::InherentImpl(inherent) = &declaration(&program, 3).kind else {
        unreachable!()
    };
    assert!(matches!(
        inherent.members[0].kind,
        ImplMemberKind::Function(_)
    ));
    assert!(matches!(
        inherent.members[1].kind,
        ImplMemberKind::AssociatedType(_)
    ));
    let DeclarationKind::Trait(trait_declaration) = &declaration(&program, 5).kind else {
        unreachable!()
    };
    assert!(matches!(
        trait_declaration.item.members[0].kind,
        TraitMemberKind::AssociatedType(_)
    ));
    assert!(matches!(
        trait_declaration.item.members[1].kind,
        TraitMemberKind::Method(_)
    ));
    assert!(matches!(
        declaration(&program, 6).kind,
        DeclarationKind::Effect(_)
    ));
    assert!(matches!(
        declaration(&program, 7).kind,
        DeclarationKind::EffectAlias(_)
    ));
    assert!(matches!(
        declaration(&program, 8).kind,
        DeclarationKind::Extern(Declared {
            item: ExternDeclaration::Function(_),
            ..
        })
    ));
    assert!(matches!(
        declaration(&program, 9).kind,
        DeclarationKind::Extern(Declared {
            item: ExternDeclaration::Type { .. },
            ..
        })
    ));
    assert!(matches!(
        declaration(&program, 10).kind,
        DeclarationKind::TypeAlias(_)
    ));
    assert!(matches!(
        declaration(&program, 11).kind,
        DeclarationKind::Const(_)
    ));
    let DeclarationKind::Function(test_function) = &declaration(&program, 12).kind else {
        panic!("ordinary function named test expected")
    };
    assert_eq!(test_function.item.signature.name.text, "test");
    assert_eq!(test_function.item.signature.parameters[0].name.text, "test");
    let ExprKind::Path(test_reference) = &test_function
        .item
        .body
        .tail
        .as_deref()
        .expect("test function should return its parameter")
        .kind
    else {
        panic!("ordinary test identifier reference expected")
    };
    let [PathSegment::Identifier(test_reference)] = test_reference.segments.as_slice() else {
        panic!("single test identifier path expected")
    };
    assert_eq!(test_reference.text, "test");
    let DeclarationKind::Module(module) = &declaration(&program, 13).kind else {
        panic!("module declaration expected")
    };
    assert!(module.visibility.is_some());
    assert!(module.item.requires.is_some());
    assert_eq!(module.item.uses.len(), 1);
    assert_eq!(module.item.items.len(), 1);
}

#[test]
fn preserves_module_item_order_and_utf8_spans() {
    let source = r#"
use prelude
const VALUE = 1
pub fn root() { "λ" }
fn generate(generate: Int) -> Int { generate }
mod inner {
    use super::prelude
    fn nested() {}
}
struct Target {}
trait Build { fn build(self) }
impl Target { pub fn inherent(self) {} }
impl Build for Target { fn build(self) {} }
"#;
    let program = parse(source).expect("mixed module items should parse");
    assert_eq!(program.uses.len(), 1);
    assert_eq!(program.items.len(), 8);
    assert!(matches!(
        declaration(&program, 0).kind,
        DeclarationKind::Const(_)
    ));
    let DeclarationKind::Function(root) = &declaration(&program, 1).kind else {
        panic!("root function expected")
    };
    assert!(root.visibility.is_some());
    let tail = root.item.body.tail.as_ref().expect("UTF-8 tail");
    assert_eq!(&source[tail.span.start..tail.span.end], "\"λ\"");
    let DeclarationKind::Function(named_generate) = &declaration(&program, 2).kind else {
        panic!("ordinary spelling remains a function name")
    };
    assert_eq!(named_generate.item.signature.name.text, "generate");
    let DeclarationKind::Module(inner) = &declaration(&program, 3).kind else {
        panic!("inline module expected")
    };
    assert_eq!(inner.item.uses.len(), 1);
    assert!(matches!(
        inner.item.items[0].kind,
        DeclarationKind::Function(_)
    ));
    let DeclarationKind::InherentImpl(inherent) = &declaration(&program, 6).kind else {
        panic!("inherent impl expected")
    };
    assert!(matches!(
        inherent.members[0].kind,
        ImplMemberKind::Function(_)
    ));
    assert!(inherent.members[0].visibility.is_some());
    let DeclarationKind::TraitImpl(implementation) = &declaration(&program, 7).kind else {
        panic!("trait impl expected")
    };
    assert!(matches!(
        implementation.members[0].kind,
        ImplMemberKind::Function(_)
    ));
    assert!(implementation.members[0].visibility.is_none());
}

#[test]
fn preserves_parameter_types_modes_where_and_effect_ownership() {
    let source = r#"
fn modes<G: Debug, F: Display>(
    readonly: &Int,
    mutable: &mut State,
    mut owned: Token,
    callback: F,
    direct: fn(Int, &mut State, &Token, G) -> &Unit with {},
    named_scoped: scoped,
    named_call: call,
    qualified: call::Type,
    qualified_scoped: scoped::Type,
) -> (fn(Int, G) -> Unit with {fs}) with {} {
    fn(callback: F, direct: fn(G) -> Unit, inferred) -> (fn(Int) -> Unit) {}
}
trait Use {
    fn invoke<F: Display>(&self, callback: F, state: &mut State, token: Token) -> Unit
}
extern fn external<F: Display>(callback: F, state: &mut State, token: Token) -> Unit with {}
effect Operations<F> { fn run(callback: F, state: &mut State, token: Token) -> Unit }
impl<T> Use for Target where (T, T): Pair + Debug, T::Item: Eq, {
    fn invoke<F: Display>(&mut self, callback: F, state: &mut State, token: Token) -> Unit {}
}
"#;
    let program = parse(source).expect("parameter and predicate carriers should parse");
    let DeclarationKind::Function(modes) = &declaration(&program, 0).kind else {
        panic!("modes function expected")
    };
    let parameters = &modes.item.signature.parameters;
    for (index, expected) in [(0, BorrowKind::Shared), (1, BorrowKind::Mutable)] {
        assert_eq!(
            parameters[index].borrow.as_ref().map(|borrow| borrow.kind),
            Some(expected)
        );
    }
    let borrow = parameters[1].borrow.as_ref().expect("mutable borrow");
    assert_eq!(&source[borrow.span.start..borrow.span.end], "&mut");
    assert!(parameters[2].borrow.is_none());
    let mutable = parameters[2].mutable.expect("mutable by-value parameter");
    assert_eq!(&source[mutable.start..mutable.end], "mut");
    let TypeKind::Function(direct) = &parameter_type(&parameters[4]).kind else {
        panic!("direct function parameter type expected")
    };
    assert_eq!(direct.parameters.len(), 4);
    assert!(direct.parameters[0].borrow.is_none());
    assert_eq!(
        direct.parameters[1].borrow.as_ref().unwrap().kind,
        BorrowKind::Mutable
    );
    assert_eq!(
        direct.parameters[2].borrow.as_ref().unwrap().kind,
        BorrowKind::Shared
    );
    assert!(direct.parameters[3].borrow.is_none());
    assert_eq!(
        direct.return_borrow.as_ref().map(|borrow| borrow.kind),
        Some(BorrowKind::Shared)
    );
    assert!(matches!(direct.effects, Some(EffectSet { ref effects, .. }) if effects.is_empty()));
    for parameter in &parameters[5..] {
        assert!(parameter.borrow.is_none());
        assert!(matches!(parameter_type(parameter).kind, TypeKind::Named(_)));
    }
    let TypeKind::Grouped(inner) = &return_type(&modes.item).kind else {
        panic!("factory return grouping expected")
    };
    let TypeKind::Function(factory) = &inner.kind else {
        panic!("function return expected")
    };
    assert!(
        matches!(factory.effects, Some(EffectSet { ref effects, .. }) if matches!(effects[0].kind, EffectKind::Named { .. }))
    );
    assert!(
        matches!(modes.item.signature.effects, Some(EffectSet { ref effects, .. }) if effects.is_empty())
    );
    let ExprKind::Closure(closure) = &modes.item.body.tail.as_deref().expect("closure tail").kind
    else {
        panic!("closure expected")
    };
    assert!(closure.parameters[0].borrow.is_none());
    assert!(matches!(
        parameter_type(&closure.parameters[1]).kind,
        TypeKind::Function(_)
    ));
    assert!(closure.parameters[2].ty.is_none());
    assert!(matches!(
        closure.return_type.as_deref().map(|ty| &ty.kind),
        Some(TypeKind::Grouped(_))
    ));
    let DeclarationKind::Trait(trait_declaration) = &declaration(&program, 1).kind else {
        panic!("trait expected")
    };
    let TraitMemberKind::Method(signature) = &trait_declaration.item.members[0].kind else {
        panic!("trait method expected")
    };
    assert!(signature.parameters[0].ty.is_none());
    assert_eq!(
        signature.parameters[0]
            .borrow
            .as_ref()
            .map(|borrow| borrow.kind),
        Some(BorrowKind::Shared)
    );
    assert!(signature.parameters[1].borrow.is_none());
    let DeclarationKind::Extern(external) = &declaration(&program, 2).kind else {
        panic!("extern expected")
    };
    let ExternDeclaration::Function(external) = &external.item else {
        panic!("extern function expected")
    };
    assert!(external.parameters[0].borrow.is_none());
    let DeclarationKind::TraitImpl(implementation) = &declaration(&program, 4).kind else {
        panic!("trait impl expected")
    };
    let where_clause = implementation.where_clause.as_ref().expect("where clause");
    assert_eq!(
        &source[where_clause.keyword_span.start..where_clause.keyword_span.end],
        "where"
    );
    assert_eq!(where_clause.predicates.len(), 2);
    assert!(
        matches!(where_clause.predicates[0].subject.kind, TypeKind::Tuple(ref elements) if elements.len() == 2)
    );
    assert_eq!(where_clause.predicates[0].bounds.len(), 2);
    assert!(matches!(
        where_clause.predicates[1].subject.kind,
        TypeKind::Named(_)
    ));
}

#[test]
fn preserves_statements_tail_and_newlines() {
    let body = first_function_body(
        r#"
fn statements() {
    let value = 1
    let mut state: Int = 2
    let (left, Pair(right, _)) = pair
    return
    break
    continue
    state.field += 1
    if let some(item) = option { item } else { () }
    while ready { continue }
    for item in items {}
    for (key, value,) in entries {}
    loop { break }
    if ready {}
    work()
    42
}
"#,
    );
    assert_eq!(body.statements.len(), 14);
    assert!(matches!(
        body.statements[0].kind,
        StatementKind::Let {
            binding: LetBinding::Name { mutable: None, .. },
            ..
        }
    ));
    assert!(matches!(
        body.statements[1].kind,
        StatementKind::Let {
            binding: LetBinding::Name {
                mutable: Some(_),
                ..
            },
            ..
        }
    ));
    assert!(matches!(
        body.statements[2].kind,
        StatementKind::Let {
            binding: LetBinding::Tuple(_),
            ..
        }
    ));
    assert!(matches!(
        body.statements[3].kind,
        StatementKind::Return(None)
    ));
    assert!(matches!(body.statements[4].kind, StatementKind::Break));
    assert!(matches!(body.statements[5].kind, StatementKind::Continue));
    assert!(matches!(
        body.statements[6].kind,
        StatementKind::Assignment {
            operator: Spanned {
                kind: AssignmentOperator::AddAssign,
                ..
            },
            ..
        }
    ));
    assert!(matches!(
        body.statements[7].kind,
        StatementKind::IfLet { .. }
    ));
    assert!(matches!(
        body.statements[8].kind,
        StatementKind::While { .. }
    ));
    assert!(matches!(
        body.statements[9].kind,
        StatementKind::For {
            binding: ForBinding::Name(_),
            ..
        }
    ));
    assert!(matches!(
        body.statements[10].kind,
        StatementKind::For {
            binding: ForBinding::Tuple { .. },
            ..
        }
    ));
    assert!(matches!(body.statements[11].kind, StatementKind::Loop(_)));
    assert!(matches!(
        body.statements[12].kind,
        StatementKind::Expression(Spanned {
            kind: ExprKind::If { .. },
            ..
        })
    ));
    assert!(matches!(
        body.statements[13].kind,
        StatementKind::Expression(Spanned {
            kind: ExprKind::Call { .. },
            ..
        })
    ));
    assert!(matches!(
        body.tail.as_deref().map(|expression| &expression.kind),
        Some(ExprKind::Integer(value)) if value == "42"
    ));
}

#[test]
fn preserves_precedence_and_associativity() {
    let expression = tail_expression("a || b && c == d < e..f + g * -h");
    let ExprKind::Binary {
        operator, right, ..
    } = expression.kind
    else {
        panic!("outer binary expression expected")
    };
    assert_eq!(operator.kind, BinaryOperator::LogicOr);
    let ExprKind::Binary {
        operator, right, ..
    } = right.kind
    else {
        panic!("logical and expected")
    };
    assert_eq!(operator.kind, BinaryOperator::LogicAnd);
    let ExprKind::Binary {
        operator, right, ..
    } = right.kind
    else {
        panic!("equality expected")
    };
    assert_eq!(operator.kind, BinaryOperator::Equal);
    let ExprKind::Binary {
        operator, right, ..
    } = right.kind
    else {
        panic!("comparison expected")
    };
    assert_eq!(operator.kind, BinaryOperator::Less);
    let ExprKind::Binary {
        operator, right, ..
    } = right.kind
    else {
        panic!("range expected")
    };
    assert_eq!(operator.kind, BinaryOperator::RangeExclusive);
    assert!(matches!(
        right.kind,
        ExprKind::Binary {
            operator: Spanned {
                kind: BinaryOperator::Add,
                ..
            },
            ..
        }
    ));

    let subtraction = tail_expression("a - b - c");
    let ExprKind::Binary { left, operator, .. } = subtraction.kind else {
        panic!("binary expression expected")
    };
    assert_eq!(operator.kind, BinaryOperator::Subtract);
    assert!(matches!(
        left.kind,
        ExprKind::Binary {
            operator: Spanned {
                kind: BinaryOperator::Subtract,
                ..
            },
            ..
        }
    ));

    let mixed = tail_expression("a < b == c < d");
    let ExprKind::Binary {
        left,
        operator,
        right,
    } = mixed.kind
    else {
        panic!("equality expression expected")
    };
    assert_eq!(operator.kind, BinaryOperator::Equal);
    for comparison in [left, right] {
        assert!(matches!(
            comparison.kind,
            ExprKind::Binary {
                operator: Spanned {
                    kind: BinaryOperator::Less,
                    ..
                },
                ..
            }
        ));
    }
    for source in ["a || b < c < d", "a == b < c < d", "a && b == c != d"] {
        let diagnostic = parse(&format!("fn probe() {{ {source} }}")).unwrap_err();
        let last_operator = source.rfind(['<', '!']).unwrap();
        assert_eq!(diagnostic.span.start, "fn probe() { ".len() + last_operator);
        assert!(matches!(
            diagnostic.kind,
            FrontendDiagnosticKind::Layout(LayoutDiagnosticKind::MissingSeparator)
        ));
    }
}

#[test]
fn nested_expressions_fit_the_default_windows_stack() {
    // The test harness normally gives its threads more than the failing
    // Windows main thread's 1 MiB stack. Keep parse, observation, and Drop here.
    std::thread::Builder::new()
        .stack_size(1024 * 1024)
        .spawn(|| {
            let header = "// 前\nfn probe() { ";
            for (prefix, suffix) in [
                ("Wrap { value: ", " }"),
                ("if true { ", " } else { 0 }"),
                ("f(", ")"),
                ("\"前${", "}後\""),
            ] {
                let source = format!("{header}{}1{} }}", prefix.repeat(32), suffix.repeat(32));
                eprintln!("ENTER parse {prefix}");
                let program = parse(&source).unwrap();
                eprintln!("RETURN parse");
                let DeclarationKind::Function(function) = &declaration(&program, 0).kind else {
                    panic!("function expected")
                };
                let mut expression = function.item.body.tail.as_deref().unwrap();
                let mut span = Span {
                    start: header.len(),
                    end: source.len() - 2,
                };
                for _ in 0..32 {
                    assert_eq!(expression.span, span);
                    expression = match (prefix, &expression.kind) {
                        ("Wrap { value: ", ExprKind::NamedConstruct { path, entries }) => {
                            assert_eq!(&source[path.span.start..path.span.end], "Wrap");
                            assert_eq!(entries.len(), 1);
                            let ConstructEntryKind::Field { name, value } = &entries[0].kind else {
                                panic!("named field expected")
                            };
                            assert_eq!(name.text, "value");
                            value.as_ref().unwrap()
                        }
                        (
                            "if true { ",
                            ExprKind::If {
                                condition,
                                then_branch,
                                else_branch,
                            },
                        ) => {
                            assert!(matches!(condition.kind, ExprKind::Boolean(true)));
                            assert!(then_branch.statements.is_empty());
                            let ExprKind::Block(block) = &else_branch.as_ref().unwrap().kind else {
                                panic!("else block expected")
                            };
                            assert!(matches!(
                                &block.tail.as_ref().unwrap().kind,
                                ExprKind::Integer(value) if value == "0"
                            ));
                            then_branch.tail.as_deref().unwrap()
                        }
                        ("f(", ExprKind::Call { callee, arguments }) => {
                            assert!(matches!(callee.kind, ExprKind::Path(_)));
                            assert_eq!(&source[callee.span.start..callee.span.end], "f");
                            assert_eq!(arguments.len(), 1);
                            &arguments[0]
                        }
                        ("\"前${", ExprKind::InterpolatedString(parts)) => {
                            let [
                                InterpolationPart::String(before),
                                InterpolationPart::Expression(inner),
                                InterpolationPart::String(after),
                            ] = parts.as_slice()
                            else {
                                panic!("one interpolation expected")
                            };
                            assert_eq!(before.value, "前");
                            assert_eq!(after.value, "後");
                            inner
                        }
                        _ => panic!("nested expression shape changed"),
                    };
                    span.start += prefix.len();
                    span.end -= suffix.len();
                }
                assert_eq!(expression.span, span);
                assert!(matches!(&expression.kind, ExprKind::Integer(value) if value == "1"));
                drop(program);
                eprintln!("DROP parse");

                let shallow = parse(&format!("{header}{prefix}+{suffix} }}")).unwrap_err();
                let invalid = format!("{header}{}+{} }}", prefix.repeat(32), suffix.repeat(32));
                let diagnostic = parse(&invalid).unwrap_err();
                assert_eq!(diagnostic.kind, shallow.kind);
                assert_eq!(diagnostic.span, span);
            }

            let source = format!("{header}{}1", "(".repeat(32));
            let diagnostic = parse(&source).unwrap_err();
            assert_eq!(
                diagnostic.span,
                Span {
                    start: source.len(),
                    end: source.len(),
                }
            );
            assert_eq!(
                diagnostic.kind,
                FrontendDiagnosticKind::UnexpectedToken {
                    found: FoundToken::Eof,
                    expected: vec![ExpectedToken::Fixed(")".to_owned())],
                }
            );
        })
        .unwrap()
        .join()
        .unwrap();
}

#[test]
fn distinguishes_method_calls_field_calls_and_postfix_shapes() {
    let expression = tail_expression("value.member(&mut state, file).field[0].1");
    let ExprKind::TupleField { receiver, index } = expression.kind else {
        panic!("tuple field expected")
    };
    assert_eq!(index.value, "1");
    let ExprKind::Index { receiver, .. } = receiver.kind else {
        panic!("index expected")
    };
    let ExprKind::Field { receiver, name } = receiver.kind else {
        panic!("field expected")
    };
    assert_eq!(name.text, "field");
    assert!(matches!(
        receiver.kind,
        ExprKind::MethodCall { ref method, ref arguments, .. }
            if method.text == "member" && arguments.len() == 2
    ));

    let field_call = tail_expression("(value.member)(argument)");
    let ExprKind::Call { callee, .. } = field_call.kind else {
        panic!("ordinary call expected")
    };
    assert!(matches!(
        callee.kind,
        ExprKind::Parenthesized(ref expression)
            if matches!(expression.kind, ExprKind::Field { .. })
    ));
}

#[test]
fn parses_construction_collections_parentheses_and_blocks() {
    let construction = tail_expression("Thing { ..base, first, second: build() }");
    let ExprKind::NamedConstruct { path, entries } = construction.kind else {
        panic!("named construction expected")
    };
    assert_eq!(path.segments.len(), 1);
    assert_eq!(entries.len(), 3);
    assert!(matches!(entries[0].kind, ConstructEntryKind::Spread(_)));
    assert!(matches!(
        entries[1].kind,
        ConstructEntryKind::Field { value: None, .. }
    ));
    assert!(matches!(
        entries[2].kind,
        ConstructEntryKind::Field { value: Some(_), .. }
    ));

    assert!(matches!(tail_expression("[]").kind, ExprKind::List(ref values) if values.is_empty()));
    assert!(
        matches!(tail_expression("[1, 2,]").kind, ExprKind::List(ref values) if values.len() == 2)
    );
    assert!(matches!(tail_expression("()").kind, ExprKind::Unit));
    assert!(matches!(
        tail_expression("(value)").kind,
        ExprKind::Parenthesized(_)
    ));
    assert!(matches!(
        tail_expression("(left, right,)").kind,
        ExprKind::Tuple(ref values) if values.len() == 2
    ));
    assert!(matches!(
        tail_expression("{ let value = 1; value }").kind,
        ExprKind::Block(_)
    ));
}

#[test]
fn parses_control_effect_closure_and_catch_expressions() {
    let conditional = tail_expression("if ready { 1 } else if fallback { 2 } else { 3 }");
    assert!(matches!(
        conditional.kind,
        ExprKind::If {
            else_branch: Some(ref branch),
            ..
        } if matches!(branch.kind, ExprKind::If { .. })
    ));

    let matched = tail_expression("match value { some(item) if ready => item, none => 0}");
    assert!(matches!(
        matched.kind,
        ExprKind::Match { ref arms, .. }
            if arms.len() == 2 && arms[0].guard.is_some()
    ));

    let handled =
        tail_expression("handle { Reader.read(\"key\") } with { Reader.read(key: Str) => key}");
    assert!(matches!(
        handled.kind,
        ExprKind::Handle { ref handlers, .. }
            if handlers.len() == 1 && handlers[0].operation.text == "read"
    ));

    let closure = tail_expression("fn(step: Int) -> Int with {fs} { counter + step }");
    let ExprKind::Closure(closure) = closure.kind else {
        panic!("closure expected")
    };
    assert_eq!(closure.parameters.len(), 1);
    assert!(closure.effects.is_some());

    assert!(matches!(
        tail_expression("unsafe { operation() }").kind,
        ExprKind::Unsafe(_)
    ));

    let caught =
        tail_expression("risky() catch { Missing(name) => repair(name), _ => 0 } catch { _ => 1 }");
    let ExprKind::Catch { expression, arms } = caught.kind else {
        panic!("outer catch expected")
    };
    assert_eq!(arms.len(), 1);
    assert!(matches!(expression.kind, ExprKind::Catch { .. }));
}

#[test]
fn decodes_interpolation_and_preserves_raw_mode() {
    let interpolated = tail_expression(r#""left ${first} middle ${call("${nested}")} right""#);
    let ExprKind::InterpolatedString(parts) = interpolated.kind else {
        panic!("interpolated string expected")
    };
    assert_eq!(parts.len(), 5);
    assert!(matches!(
        &parts[0],
        InterpolationPart::String(StringValue { value, .. }) if value == "left "
    ));
    assert!(matches!(&parts[1], InterpolationPart::Expression(_)));
    assert!(matches!(
        &parts[2],
        InterpolationPart::String(StringValue { value, .. }) if value == " middle "
    ));
    assert!(matches!(&parts[3], InterpolationPart::Expression(_)));
    assert!(matches!(
        &parts[4],
        InterpolationPart::String(StringValue { value, .. }) if value == " right"
    ));

    let raw = tail_expression("r#\"line 1\r\nline \"2\" \0\"#");
    assert!(matches!(
        raw.kind,
        ExprKind::RawString {
            delimiter: RawStringDelimiter::HashQuote,
            ref value,
        } if value.contains("\r\n") && value.contains('\0')
    ));
}

#[test]
fn parses_every_pattern_shape_and_arm_level_or() {
    let expression = tail_expression(
        r#"
match value {
    _ => 0
    1 => 1
    2.5 => 2
    "text" => 3
    true => 4
    none => 5
    Pair(left, _) => 6
    Named { first, second: _, .. } => 7
    (left, right) => 8
    Red | Green if visible => 9
    _::Variant => 10
    _(_) => 11
    _ { field } => 12
}
"#,
    );
    let ExprKind::Match { arms, .. } = expression.kind else {
        panic!("match expected")
    };
    assert_eq!(arms.len(), 13);
    assert!(matches!(
        arms[0].pattern.alternatives[0].kind,
        PatternKind::Wildcard
    ));
    assert!(matches!(
        arms[1].pattern.alternatives[0].kind,
        PatternKind::Integer(_)
    ));
    assert!(matches!(
        arms[2].pattern.alternatives[0].kind,
        PatternKind::Float(_)
    ));
    assert!(matches!(
        arms[3].pattern.alternatives[0].kind,
        PatternKind::String(_)
    ));
    assert!(matches!(
        arms[4].pattern.alternatives[0].kind,
        PatternKind::Boolean(true)
    ));
    assert!(matches!(
        arms[5].pattern.alternatives[0].kind,
        PatternKind::Path { fields: None, .. }
    ));
    assert!(matches!(
        arms[6].pattern.alternatives[0].kind,
        PatternKind::Path {
            fields: Some(PatternFields::Positional(_)),
            ..
        }
    ));
    assert!(matches!(
        arms[7].pattern.alternatives[0].kind,
        PatternKind::Path {
            fields: Some(PatternFields::Named { rest: Some(_), .. }),
            ..
        }
    ));
    assert!(matches!(
        arms[8].pattern.alternatives[0].kind,
        PatternKind::Tuple(_)
    ));
    assert_eq!(arms[9].pattern.alternatives.len(), 2);
    assert!(arms[9].guard.is_some());
    let PatternKind::Path { path, fields: None } = &arms[10].pattern.alternatives[0].kind else {
        panic!("qualified underscore path pattern expected")
    };
    assert!(matches!(
        &path.segments[..],
        [PathSegment::Identifier(root), PathSegment::Identifier(variant)]
            if root.text == "_" && variant.text == "Variant"
    ));
    let PatternKind::Path {
        path,
        fields: Some(PatternFields::Positional(fields)),
    } = &arms[11].pattern.alternatives[0].kind
    else {
        panic!("underscore positional path pattern expected")
    };
    assert!(matches!(
        &path.segments[..],
        [PathSegment::Identifier(root)] if root.text == "_"
    ));
    assert!(matches!(
        &fields[..],
        [field] if matches!(field.kind, PatternKind::Wildcard)
    ));
    let PatternKind::Path {
        path,
        fields: Some(PatternFields::Named { fields, rest: None }),
    } = &arms[12].pattern.alternatives[0].kind
    else {
        panic!("underscore named path pattern expected")
    };
    assert!(matches!(
        &path.segments[..],
        [PathSegment::Identifier(root)] if root.text == "_"
    ));
    assert!(matches!(
        &fields[..],
        [field] if field.name.text == "field" && field.pattern.is_none()
    ));
}

#[test]
fn accepts_unresolved_surface_without_semantic_guessing() {
    let program = parse(
        r#"
fn unresolved(value: Int) {
    lower_case { ..base, field }
    UPPER(1)
    namespace::constructor { value: 1 }
    transfer(&mut state.field, resource)
    unresolved_name
}
"#,
    )
    .unwrap();
    let DeclarationKind::Function(function) = &declaration(&program, 0).kind else {
        unreachable!()
    };
    assert_eq!(function.item.body.statements.len(), 4);
    assert!(matches!(
        function.item.body.statements[0].kind,
        StatementKind::Expression(Spanned {
            kind: ExprKind::NamedConstruct { .. },
            ..
        })
    ));
    assert!(matches!(
        function.item.body.statements[1].kind,
        StatementKind::Expression(Spanned {
            kind: ExprKind::Call { .. },
            ..
        })
    ));
}

#[test]
fn every_expression_variant_has_a_direct_source_shape() {
    let body = first_function_body(
        r#"
fn variants() {
    1
    1.5
    "plain"
    r"raw"
    "before ${value} after"
    true
    value
    Thing {}
    [value]
    ()
    (value)
    (left, right)
    { value }
    if ready {} else {}
    match value {}
    handle {} with {}
    fn() {}
    unsafe {}
    risky catch {}
    -value
    !value
    left + right
    callable(value)
    value[index]
    value.0
    value.field
    value.method()
}
"#,
    );
    let expressions = body
        .statements
        .iter()
        .map(|statement| match &statement.kind {
            StatementKind::Expression(expression) => &expression.kind,
            _ => panic!("expression statement expected"),
        })
        .chain(body.tail.iter().map(|expression| &expression.kind))
        .collect::<Vec<_>>();
    assert_eq!(expressions.len(), 27);
    assert!(matches!(expressions[0], ExprKind::Integer(_)));
    assert!(matches!(expressions[1], ExprKind::Float(_)));
    assert!(matches!(expressions[2], ExprKind::String(_)));
    assert!(matches!(
        expressions[3],
        ExprKind::RawString {
            delimiter: RawStringDelimiter::Quote,
            ..
        }
    ));
    assert!(matches!(expressions[4], ExprKind::InterpolatedString(_)));
    assert!(matches!(expressions[5], ExprKind::Boolean(true)));
    assert!(matches!(expressions[6], ExprKind::Path(_)));
    assert!(matches!(expressions[7], ExprKind::NamedConstruct { .. }));
    assert!(matches!(expressions[8], ExprKind::List(_)));
    assert!(matches!(expressions[9], ExprKind::Unit));
    assert!(matches!(expressions[10], ExprKind::Parenthesized(_)));
    assert!(matches!(expressions[11], ExprKind::Tuple(_)));
    assert!(matches!(expressions[12], ExprKind::Block(_)));
    assert!(matches!(expressions[13], ExprKind::If { .. }));
    assert!(matches!(expressions[14], ExprKind::Match { .. }));
    assert!(matches!(expressions[15], ExprKind::Handle { .. }));
    assert!(matches!(expressions[16], ExprKind::Closure(_)));
    assert!(matches!(expressions[17], ExprKind::Unsafe(_)));
    assert!(matches!(expressions[18], ExprKind::Catch { .. }));
    assert!(matches!(expressions[19], ExprKind::Unary { .. }));
    assert!(matches!(expressions[20], ExprKind::Unary { .. }));
    assert!(matches!(expressions[21], ExprKind::Binary { .. }));
    assert!(matches!(expressions[22], ExprKind::Call { .. }));
    assert!(matches!(expressions[23], ExprKind::Index { .. }));
    assert!(matches!(expressions[24], ExprKind::TupleField { .. }));
    assert!(matches!(expressions[25], ExprKind::Field { .. }));
    assert!(matches!(expressions[26], ExprKind::MethodCall { .. }));
}

#[test]
fn preserves_every_operator_and_call_argument_kind() {
    let binary_cases = [
        ("left || right", BinaryOperator::LogicOr),
        ("left && right", BinaryOperator::LogicAnd),
        ("left == right", BinaryOperator::Equal),
        ("left != right", BinaryOperator::NotEqual),
        ("left < right", BinaryOperator::Less),
        ("left > right", BinaryOperator::Greater),
        ("left <= right", BinaryOperator::LessEqual),
        ("left >= right", BinaryOperator::GreaterEqual),
        ("left..right", BinaryOperator::RangeExclusive),
        ("left..=right", BinaryOperator::RangeInclusive),
        ("left + right", BinaryOperator::Add),
        ("left - right", BinaryOperator::Subtract),
        ("left * right", BinaryOperator::Multiply),
        ("left / right", BinaryOperator::Divide),
        ("left % right", BinaryOperator::Remainder),
    ];
    for (source, expected) in binary_cases {
        let expression = tail_expression(source);
        let ExprKind::Binary { operator, .. } = expression.kind else {
            panic!("binary expression expected for {source}")
        };
        assert_eq!(operator.kind, expected, "{source}");
    }

    for (source, expected) in [
        ("-value", UnaryOperator::Negate),
        ("!value", UnaryOperator::Not),
    ] {
        let expression = tail_expression(source);
        let ExprKind::Unary { operator, .. } = expression.kind else {
            panic!("unary expression expected for {source}")
        };
        assert_eq!(operator.kind, expected);
    }

    for (source, expected, spelling) in [
        ("&value.items[0]", BorrowKind::Shared, "&"),
        ("&mut value.items[0]", BorrowKind::Mutable, "&mut"),
    ] {
        let expression = tail_expression(source);
        let ExprKind::Borrow { kind, operand } = expression.kind else {
            panic!("borrow expected for {source}")
        };
        assert_eq!(kind.kind, expected);
        assert_eq!(kind.span.end - kind.span.start, spelling.len());
        assert!(
            matches!(operand.kind, ExprKind::Index { .. }),
            "{source} borrows the whole place"
        );
    }

    let body = first_function_body(
        r#"
fn assignments() {
    value = one
    value += one
    value -= one
    value *= one
    value /= one
    value %= one
}
"#,
    );
    let expected = [
        AssignmentOperator::Assign,
        AssignmentOperator::AddAssign,
        AssignmentOperator::SubtractAssign,
        AssignmentOperator::MultiplyAssign,
        AssignmentOperator::DivideAssign,
        AssignmentOperator::RemainderAssign,
    ];
    for (statement, expected) in body.statements.iter().zip(expected) {
        let StatementKind::Assignment { operator, .. } = &statement.kind else {
            panic!("assignment expected")
        };
        assert_eq!(operator.kind, expected);
    }

    let call = tail_expression("callable(value, &mut state.field, &make())");
    let ExprKind::Call { arguments, .. } = call.kind else {
        panic!("call expected")
    };
    assert!(matches!(arguments[0].kind, ExprKind::Path(_)));
    assert!(matches!(
        arguments[1].kind,
        ExprKind::Borrow { ref kind, .. } if kind.kind == BorrowKind::Mutable
    ));
    assert!(matches!(
        arguments[2].kind,
        ExprKind::Borrow { ref kind, ref operand }
            if kind.kind == BorrowKind::Shared && matches!(operand.kind, ExprKind::Call { .. })
    ));
}

#[test]
fn preserves_effect_path_and_optional_carriers() {
    let program = parse(
        r#"
requires {console, unsafe}
fn probe() with {Reader<Str>, unsafe} { () }
"#,
    )
    .unwrap();
    let requires = program.requires.as_ref().unwrap();
    assert!(matches!(
        requires.effects.effects[0].kind,
        EffectKind::Named { .. }
    ));
    assert!(matches!(
        requires.effects.effects[1].kind,
        EffectKind::Unsafe
    ));

    let DeclarationKind::Function(function) = &declaration(&program, 0).kind else {
        unreachable!()
    };
    let effects = function.item.signature.effects.as_ref().unwrap();
    assert!(matches!(
        effects.effects[0].kind,
        EffectKind::Named { ref arguments, .. } if arguments.len() == 1
    ));
    assert!(matches!(effects.effects[1].kind, EffectKind::Unsafe));

    let absent = first_function_body("fn absent(parameter: Int) { work()\nreturn }");
    assert!(absent.tail.is_none());

    let use_path = &program.requires.expect("requires expected").effects.effects[0];
    let EffectKind::Named { path, .. } = &use_path.kind else {
        unreachable!()
    };
    assert!(matches!(path.segments[0], PathSegment::Identifier(_)));

    let super_program = parse("use super::parent::value").unwrap();
    assert!(matches!(
        super_program.uses[0].path.segments[0],
        PathSegment::Super(_)
    ));
}

#[test]
fn preserves_callable_effect_parameters_and_method_scheme_arguments() {
    let source = r#"
trait Fetch {
    fn fetch<T, F: Display, effect E, effect Tail>(
        self,
        callback: F
    ) -> Unit
}

fn run<T: Fetch, F: Display, effect E, effect Tail>(
    source: T,
    inferred: fn(Str) -> Unit,
    pure: fn(Str) -> Unit with {},
    callback: fn(Str) -> Unit with {E}
) -> Unit with {Fetch::fetch<T, F, effect {E, fs}, effect {Tail}>} {
    source.fetch(callback)
}

extern fn invoke<F: Display, effect E>(callback: F) -> Unit with {E}
"#;
    let program = parse(source).expect("callable effect surface parses");

    let DeclarationKind::Trait(trait_declaration) = &declaration(&program, 0).kind else {
        panic!("trait expected")
    };
    let TraitMemberKind::Method(method) = &trait_declaration.item.members[0].kind else {
        panic!("trait method expected")
    };
    assert_eq!(
        method
            .effect_parameters
            .iter()
            .map(|parameter| parameter.name.text.as_str())
            .collect::<Vec<_>>(),
        ["E", "Tail"]
    );
    assert_eq!(
        &source[method.effect_parameters[0].span.start..method.effect_parameters[0].span.end],
        "effect E"
    );
    assert!(method.parameters[0].ty.is_none());
    assert_eq!(method.type_parameters[1].bounds.len(), 1);
    assert!(method.parameters[1].borrow.is_none());
    assert!(matches!(
        parameter_type(&method.parameters[1]).kind,
        TypeKind::Named(_)
    ));

    let DeclarationKind::Function(function) = &declaration(&program, 1).kind else {
        panic!("function expected")
    };
    assert_eq!(function.item.signature.type_parameters.len(), 2);
    assert_eq!(function.item.signature.effect_parameters.len(), 2);
    let TypeKind::Function(callback_type) =
        &parameter_type(&function.item.signature.parameters[1]).kind
    else {
        panic!("inferred callback should retain a function type")
    };
    assert!(callback_type.effects.is_none());
    let TypeKind::Function(pure_type) =
        &parameter_type(&function.item.signature.parameters[2]).kind
    else {
        panic!("pure callback should retain a function type")
    };
    assert!(matches!(
        pure_type.effects,
        Some(EffectSet { ref effects, .. }) if effects.is_empty()
    ));
    let TypeKind::Function(callback) = &parameter_type(&function.item.signature.parameters[3]).kind
    else {
        panic!("callback function type expected")
    };
    assert_eq!(
        callback
            .effects
            .as_ref()
            .expect("callback effect row")
            .effects
            .len(),
        1
    );
    assert!(function.item.signature.parameters[3].borrow.is_none());

    let outer_effects = function
        .item
        .signature
        .effects
        .as_ref()
        .expect("outer effect bound");
    let EffectKind::Named {
        path,
        arguments,
        effect_arguments,
    } = &outer_effects.effects[0].kind
    else {
        panic!("method scheme application expected")
    };
    assert_eq!(path.segments.len(), 2);
    assert_eq!(arguments.len(), 2);
    assert_eq!(effect_arguments.len(), 2);
    assert_eq!(
        &source[effect_arguments[0].span.start..effect_arguments[0].span.end],
        "effect {E, fs}"
    );
    assert_eq!(effect_arguments[0].effects.effects.len(), 2);

    let DeclarationKind::Extern(external) = &declaration(&program, 2).kind else {
        panic!("extern expected")
    };
    let ExternDeclaration::Function(external) = &external.item else {
        panic!("extern function expected")
    };
    assert_eq!(external.effect_parameters.len(), 1);
    assert!(external.effects.is_some());
    assert!(external.parameters[0].borrow.is_none());

    let impl_program = parse(
        "struct Worker {}; impl Worker { fn invoke<F: Display, effect E>(callback: F) -> Unit with {E} { callback() } }",
    )
    .expect("impl methods reuse callable parameters");
    let DeclarationKind::InherentImpl(implementation) = &declaration(&impl_program, 1).kind else {
        panic!("inherent impl expected")
    };
    let ImplMemberKind::Function(method) = &implementation.members[0].kind else {
        panic!("impl method expected")
    };
    assert_eq!(method.signature.effect_parameters.len(), 1);
}

#[test]
fn parses_grouped_types_without_changing_other_type_carriers() {
    let source = r#"
fn grouped(
    named: (Single),
    nested: ((Single)),
    function: (fn() -> Int),
    tuple: ((Int, Str)),
    callback: fn() -> Unit,
    boxed: Box<F>,
) -> Reader {}
type Mapper<F> = F
enum Payload { one(Single,), }
"#;
    let program = parse(source).unwrap();
    let DeclarationKind::Function(grouped) = &declaration(&program, 0).kind else {
        panic!("grouped function expected")
    };
    let parameters = &grouped.item.signature.parameters;

    for (parameter, expected_source) in
        [(&parameters[0], "(Single)"), (&parameters[1], "((Single))")]
    {
        let ty = parameter_type(parameter);
        assert!(matches!(ty.kind, TypeKind::Grouped(_)));
        assert_eq!(&source[ty.span.start..ty.span.end], expected_source);
    }

    let grouped_function = parameter_type(&parameters[2]);
    assert!(matches!(grouped_function.kind, TypeKind::Grouped(_)));
    assert_eq!(
        &source[grouped_function.span.start..grouped_function.span.end],
        "(fn() -> Int)"
    );

    let grouped_tuple = parameter_type(&parameters[3]);
    assert!(matches!(
        grouped_tuple.kind,
        TypeKind::Grouped(ref inner)
            if matches!(inner.kind, TypeKind::Tuple(ref elements) if elements.len() == 2)
    ));
    assert_eq!(
        &source[grouped_tuple.span.start..grouped_tuple.span.end],
        "((Int, Str))"
    );

    assert!(matches!(
        parameter_type(&parameters[4]).kind,
        TypeKind::Function(_)
    ));
    let TypeKind::Named(boxed) = &parameter_type(&parameters[5]).kind else {
        panic!("Box should remain a named type")
    };
    assert!(matches!(
        boxed.arguments[0],
        TypeArgument::Type(Spanned {
            kind: TypeKind::Named(_),
            ..
        })
    ));
    assert!(matches!(
        return_type(&grouped.item).kind,
        TypeKind::Named(_)
    ));
    assert!(matches!(
        declaration(&program, 1).kind,
        DeclarationKind::TypeAlias(Declared {
            item: TypeAliasDeclaration {
                value: Spanned {
                    kind: TypeKind::Named(_),
                    ..
                },
                ..
            },
            ..
        })
    ));
    assert!(matches!(
        declaration(&program, 2).kind,
        DeclarationKind::Enum(Declared {
            item: EnumDeclaration { ref variants, .. },
            ..
        }) if matches!(variants[0].fields, VariantFields::Positional(ref fields) if fields.len() == 1)
    ));
}

#[test]
fn function_return_types_are_allowed_in_all_type_positions() {
    for source in [
        "fn make() -> (fn() -> Int) {}",
        "fn make() -> fn() -> Int {}",
        "mod inner { fn make() -> (fn() -> Int) {} }",
        "mod inner { fn make() -> fn() -> Int {} }",
        "impl Maker { fn make() -> (fn() -> Int) {} }",
        "impl Maker { fn make() -> fn() -> Int {} }",
        "impl Make for Maker { fn make() -> (fn() -> Int) {} }",
        "impl Make for Maker { fn make() -> fn() -> Int {} }",
        "fn outer() { fn() -> (fn() -> Int) {} }",
        "fn outer() { fn() -> fn() -> Int {} }",
        "trait Make { fn make() -> (fn() -> Int) }",
        "extern fn make() -> (fn() -> Int) with {}",
        "effect Make { fn make() -> (fn() -> Int) }",
        "type Factory = fn() -> Int",
        "struct Storage { callback: fn() -> Int }",
        "fn nested(value: Box<fn() -> Int>) {}",
        "fn nested_return() -> (fn() -> (fn() -> Int)) {}",
    ] {
        parse(source).unwrap_or_else(|diagnostic| panic!("{source}: {diagnostic:?}"));
    }
}

#[test]
fn preserves_grouped_return_effect_ownership_and_spans() {
    let cases = [
        ("fn make() -> (fn() -> Int) {}", None, None),
        (
            "fn make() -> (fn() -> Int) with {fs} {}",
            None,
            Some("{fs}"),
        ),
        (
            "fn make() -> (fn() -> Int with {fs}) {}",
            Some("{fs}"),
            None,
        ),
        (
            "fn make() -> (fn() -> Int with {fs}) with {} {}",
            Some("{fs}"),
            Some("{}"),
        ),
        ("fn make() -> (fn() -> Int with {}) {}", Some("{}"), None),
        ("fn make() -> (fn() -> Int) with {} {}", None, Some("{}")),
    ];

    for (source, inner_effects, outer_effects) in cases {
        let function = first_function(source);
        let return_type_expr = return_type(&function);
        let TypeKind::Grouped(inner) = &return_type_expr.kind else {
            panic!("factory return should preserve its grouping for {source}")
        };
        let TypeKind::Function(returned_function) = &inner.kind else {
            panic!("grouped return should preserve the function type for {source}")
        };
        let grouped_start = source.find("-> (").unwrap() + "-> ".len();
        let grouped_end = source.rfind(')').unwrap() + 1;
        assert_eq!(
            &source[return_type_expr.span.start..return_type_expr.span.end],
            &source[grouped_start..grouped_end],
            "{source}"
        );
        assert_eq!(
            &source[returned_function.return_type.as_ref().unwrap().span.start
                ..returned_function.return_type.as_ref().unwrap().span.end],
            "Int",
            "{source}"
        );
        assert_eq!(
            returned_function
                .effects
                .as_ref()
                .map(|effects| &source[effects.span.start..effects.span.end]),
            inner_effects,
            "{source}"
        );
        assert_eq!(
            function
                .signature
                .effects
                .as_ref()
                .map(|effects| &source[effects.span.start..effects.span.end]),
            outer_effects,
            "{source}"
        );
    }
}

#[test]
fn rejects_new_surface_outside_its_exact_positions() {
    let invalid = [
        "impl Trait for Target where {}",
        "impl Target where T: Trait {}",
        "fn bad() where T: Trait {}",
    ];
    for source in invalid {
        assert!(parse(source).is_err(), "unexpectedly accepted {source:?}");
    }
}

#[test]
fn rejects_excluded_or_ambiguous_surfaces() {
    let invalid = [
        "fn invalid(mut value) {}",
        "fn invalid(self: &mut Self) {}",
        "fn invalid(&value: Int) {}",
        "fn invalid(value: &&Int) {}",
        "fn invalid() { transfer(&&value) }",
        "struct Invalid { field: &Node }",
        "fn invalid(value: List<&Node>) {}",
        "pub impl Value {}",
        "effect Bad { fn op() -> Unit, }",
        "trait Bad { fn method() {} }",
        "trait Bad { fn method(value) }",
        "effect Bad { fn operation(value) -> Unit }",
        "extern fn missing_effect(value: Int)",
        "extern fn missing_type(value) with {}",
        "fn invalid<effect E, T>() {}",
        "fn invalid<effect E>() with {Query::method<effect {E}>} {}",
        "fn invalid<T, effect E>() with {Query::method<T, effect {E}, T>} {}",
        "fn invalid() { fn<effect E>() {} }",
        "struct Invalid<effect E> {}",
        "enum Invalid<effect E> {}",
        "trait Invalid<effect E> {}",
        "effect Invalid<effect E> {}",
        "effect alias Invalid<effect E> = {}",
        "impl<effect E> Invalid {}",
        "extern type Invalid<effect E>",
        "type Invalid<effect E> = Int",
        "type Invalid = fn<effect E>() -> Unit",
        "fn invalid() { ordinary() next() }",
        "fn invalid() { while ready {};\n() }",
        "fn invalid() { transfer(mut make_state()) }",
        "fn invalid() { Thing { field, ..base } }",
        "fn invalid() { (single,) }",
        "fn invalid() { match value { Variant() => 0 } }",
        "fn invalid(value: (Single,)) {}",
        "fn invalid(value: ()) {}",
        "fn first() {}; use later",
        "fn invalid() { if packet { ready: true } {} }",
        "fn invalid() { if let item = packet { ready: true } {} }",
        "fn invalid() { while packet { ready: true } {} }",
        "fn invalid() { for item in packet { ready: true } {} }",
        "fn invalid() { match packet { ready: true } {} }",
        "fn invalid() { a < b < c }",
        "fn invalid() { a == b == c }",
    ];
    for source in invalid {
        assert!(parse(source).is_err(), "unexpectedly accepted {source:?}");
    }

    for source in [r#"test "name" {}"#, r#"pub test "name" {}"#] {
        let diagnostic = parse(source).unwrap_err();
        assert_eq!(&source[diagnostic.span.start..diagnostic.span.end], "test");
        let FrontendDiagnosticKind::UnexpectedToken { found, expected } = diagnostic.kind else {
            panic!("native-test declaration should fail in the parser")
        };
        assert_eq!(found, FoundToken::Class(TokenClass::Identifier));
        assert!(!expected.contains(&ExpectedToken::Fixed("test".to_owned())));
    }

    let diagnostic = parse("fn invalid() { @derive(Json) }").unwrap_err();
    assert_eq!(
        diagnostic.kind,
        FrontendDiagnosticKind::Lexical(LexicalDiagnosticKind::UnexpectedCharacter)
    );

    let attribute_source = "#[test] fn probe() {}";
    let diagnostic = parse(attribute_source).unwrap_err();
    assert_eq!(
        diagnostic.kind,
        FrontendDiagnosticKind::Lexical(LexicalDiagnosticKind::UnexpectedCharacter)
    );
    assert_eq!(
        &attribute_source[diagnostic.span.start..diagnostic.span.end],
        "#"
    );
}

#[test]
fn rejects_record_types_at_the_opening_brace() {
    let invalid = [
        "fn closed(value: { x: Int }) {}",
        "fn open(value: { x: Int, ..r }) {}",
        "type Nested = Option<{ x: Int }>",
    ];

    for source in invalid {
        let diagnostic = parse(source).unwrap_err();
        assert_eq!(
            &source[diagnostic.span.start..diagnostic.span.end],
            "{",
            "{source}"
        );
        let FrontendDiagnosticKind::UnexpectedToken { found, expected } = diagnostic.kind else {
            panic!("record type should fail in the parser for {source}")
        };
        assert_eq!(found, FoundToken::Fixed("{".to_owned()), "{source}");
        assert!(
            !expected.contains(&ExpectedToken::Fixed("{".to_owned())),
            "{source}"
        );
    }
}

#[test]
fn lexical_failure_precedes_an_earlier_parser_failure() {
    let source = "fn invalid( { value } @";
    let diagnostic = parse(source).unwrap_err();
    assert_eq!(
        diagnostic.kind,
        FrontendDiagnosticKind::Lexical(LexicalDiagnosticKind::UnexpectedCharacter)
    );
    assert_eq!(&source[diagnostic.span.start..diagnostic.span.end], "@");
}

#[test]
fn preserves_present_and_absent_optional_syntax() {
    assert_eq!(parse("").unwrap().span, Span { start: 0, end: 0 });

    let program = parse(
        r#"
const inferred = value
fn optional(parameter: Int) {
    return value
}
fn conditional() {
    if ready {}
}
"#,
    )
    .unwrap();
    assert!(program.requires.is_none());
    let DeclarationKind::Const(constant) = &declaration(&program, 0).kind else {
        unreachable!()
    };
    assert!(constant.visibility.is_none());
    assert!(constant.item.annotation.is_none());

    let DeclarationKind::Function(function) = &declaration(&program, 1).kind else {
        unreachable!()
    };
    assert!(function.item.signature.parameters[0].ty.is_some());
    assert!(function.item.signature.return_type.is_none());
    assert!(function.item.signature.effects.is_none());
    assert!(function.item.body.tail.is_none());
    assert!(matches!(
        function.item.body.statements[0].kind,
        StatementKind::Return(Some(_))
    ));

    let DeclarationKind::Function(conditional) = &declaration(&program, 2).kind else {
        unreachable!()
    };
    assert!(matches!(
        conditional.item.body.tail.as_deref().map(|tail| &tail.kind),
        Some(ExprKind::If {
            else_branch: None,
            ..
        })
    ));
}

#[test]
fn spans_are_original_utf8_byte_offsets_and_eof_is_empty() {
    let source = "// λ\r\nfn probe() { \"λ\" }";
    let program = parse(source).unwrap();
    assert_eq!(
        program.span,
        Span {
            start: 0,
            end: source.len()
        }
    );
    let DeclarationKind::Function(function) = &declaration(&program, 0).kind else {
        unreachable!()
    };
    let tail = function.item.body.tail.as_ref().unwrap();
    assert_eq!(&source[tail.span.start..tail.span.end], "\"λ\"");

    let missing = "fn probe() {";
    let diagnostic = parse(missing).unwrap_err();
    assert_eq!(
        diagnostic.span,
        Span {
            start: missing.len(),
            end: missing.len(),
        }
    );
    assert!(matches!(
        diagnostic.kind,
        FrontendDiagnosticKind::UnexpectedToken {
            found: FoundToken::Eof,
            ..
        }
    ));

    let top_level = parse(";").unwrap_err();
    assert!(matches!(
        top_level.kind,
        FrontendDiagnosticKind::UnexpectedToken { ref expected, .. }
            if expected.contains(&ExpectedToken::Eof)
    ));
}

#[test]
fn repeated_success_and_failure_are_identical() {
    let source = r#"
fn deterministic(value: Int) {
    "value ${value + 1}" catch { _ => "fallback" }
}
"#;
    let expected = parse(source).unwrap();
    for _ in 0..32 {
        assert_eq!(parse(source).unwrap(), expected);
    }

    let invalid = "fn invalid() { return + }";
    let expected = parse(invalid).unwrap_err();
    for _ in 0..32 {
        assert_eq!(parse(invalid).unwrap_err(), expected);
    }
    let FrontendDiagnosticKind::UnexpectedToken { expected, .. } = expected.kind else {
        panic!("parser diagnostic expected")
    };
    let first_class = expected
        .iter()
        .position(|item| matches!(item, ExpectedToken::Class(_)))
        .unwrap();
    assert!(
        expected[..first_class]
            .iter()
            .all(|item| matches!(item, ExpectedToken::Fixed(_)))
    );
    assert!(
        expected[first_class..]
            .iter()
            .all(|item| matches!(item, ExpectedToken::Class(_) | ExpectedToken::Eof))
    );
}

#[test]
fn parenthesized_construction_is_allowed_in_control_heads() {
    let program =
        parse("fn valid() { if (packet { ready: true }).ready { start() }; () }").unwrap();
    assert_eq!(program.items.len(), 1);
}
