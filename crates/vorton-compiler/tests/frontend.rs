use vorton_compiler::ast::*;
use vorton_compiler::diagnostic::{
    ExpectedToken, FoundToken, FrontendDiagnosticKind, LexicalDiagnosticKind,
};
use vorton_compiler::parse;

fn first_function_body(source: &str) -> Block {
    let mut program = parse(source).expect("source should parse");
    let declaration = program.declarations.remove(0);
    let DeclarationKind::Function(function) = declaration.kind else {
        panic!("first declaration should be a function")
    };
    function.item.body
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
requires {unsafe, console};
pub use api::{Thing as PublicThing, make,};
use super::support;
use api::Thing as LocalThing;

pub fn transform<T: Show + Eq + Source<Item = Int>>(
    value: move T,
    callback: fn(mut T, move Resource) -> Unit with {console},
    row: {x: Int, ..rest},
    pair: (Int, Str),
) -> Option<T> with {console, mut<T>} {
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
    pub fn get(self: Self) -> T { self.value }
    pub type Item = T;
}

impl<T: Show> Show for Box<T> {
    type Output = Str;
    fn show(self: Self) -> Str { "box" }
}

pub trait Show<T>: Eq + Debug {
    type Output: Eq + Debug = Str;
    fn show(self: Self, other: T) -> Output with {};
}

effect Reader<T> {
    fn read(key: Str) -> T;
}

pub effect alias Host<T> = {Reader<T>, fail<T>, mut, unsafe};
extern fn host<T>(value: T) -> Unit with {unsafe};
extern type Handle<T>;
type Mapper<T> = fn(T) -> T;
const origin: Point = Point { x: 0, y: 0 };
test "frontend" { () }

pub mod inner requires {} {
    use super::Thing;
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
    assert_eq!(program.declarations.len(), 14);

    let DeclarationKind::Function(function) = &program.declarations[0].kind else {
        panic!("function declaration expected")
    };
    assert!(function.visibility.is_some());
    assert_eq!(function.item.type_parameters[0].bounds.len(), 3);
    assert!(matches!(
        function.item.type_parameters[0].bounds[2].kind.arguments[0],
        TypeArgument::AssociatedType { .. }
    ));
    assert!(matches!(
        function.item.parameters[0]
            .annotation
            .as_ref()
            .and_then(|annotation| annotation.mode.as_ref())
            .map(|mode| mode.kind),
        Some(ParameterMode::Move)
    ));
    assert!(matches!(
        function.item.parameters[1]
            .annotation
            .as_ref()
            .map(|annotation| &annotation.ty.kind),
        Some(TypeKind::Function(_))
    ));
    assert!(matches!(
        function.item.parameters[2]
            .annotation
            .as_ref()
            .map(|annotation| &annotation.ty.kind),
        Some(TypeKind::Record(RecordType { rest: Some(_), .. }))
    ));
    assert!(matches!(
        function.item.parameters[3]
            .annotation
            .as_ref()
            .map(|annotation| &annotation.ty.kind),
        Some(TypeKind::Tuple(values)) if values.len() == 2
    ));
    assert!(matches!(
        function.item.return_type.as_ref().map(|ty| &ty.kind),
        Some(TypeKind::Named(NamedTypeKind { arguments, .. }))
            if matches!(arguments[0], TypeArgument::Type(_))
    ));

    let DeclarationKind::Struct(structure) = &program.declarations[1].kind else {
        panic!("struct declaration expected")
    };
    assert!(structure.item.fields[0].visibility.is_some());
    assert!(structure.item.fields[1].visibility.is_none());

    let DeclarationKind::Enum(enumeration) = &program.declarations[2].kind else {
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
        program.declarations[3].kind,
        DeclarationKind::InherentImpl(_)
    ));
    assert!(matches!(
        program.declarations[4].kind,
        DeclarationKind::TraitImpl(_)
    ));
    let DeclarationKind::InherentImpl(inherent) = &program.declarations[3].kind else {
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
    let DeclarationKind::Trait(trait_declaration) = &program.declarations[5].kind else {
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
        program.declarations[6].kind,
        DeclarationKind::Effect(_)
    ));
    assert!(matches!(
        program.declarations[7].kind,
        DeclarationKind::EffectAlias(_)
    ));
    assert!(matches!(
        program.declarations[8].kind,
        DeclarationKind::Extern(Declared {
            item: ExternDeclaration::Function(_),
            ..
        })
    ));
    assert!(matches!(
        program.declarations[9].kind,
        DeclarationKind::Extern(Declared {
            item: ExternDeclaration::Type { .. },
            ..
        })
    ));
    assert!(matches!(
        program.declarations[10].kind,
        DeclarationKind::TypeAlias(_)
    ));
    assert!(matches!(
        program.declarations[11].kind,
        DeclarationKind::Const(_)
    ));
    assert!(matches!(
        program.declarations[12].kind,
        DeclarationKind::Test(_)
    ));
    let DeclarationKind::Module(module) = &program.declarations[13].kind else {
        panic!("module declaration expected")
    };
    assert!(module.visibility.is_some());
    assert!(module.item.requires.is_some());
    assert_eq!(module.item.uses.len(), 1);
    assert_eq!(module.item.declarations.len(), 1);
}

#[test]
fn preserves_statements_tail_and_terminators() {
    let body = first_function_body(
        r#"
fn statements() {
    let value = 1;
    let mut state: Int = 2;
    let (left, Pair(right, _)) = pair;
    return;
    break;
    continue;
    state.field += 1;
    if let some(item) = option { item; } else { () }
    while ready { continue; }
    for item in items {}
    for (key, value,) in entries {}
    loop { break; }
    if ready {}
    work();
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
        body.statements[12].terminator,
        StatementTerminator::Implicit
    ));
    assert!(matches!(
        body.statements[13].terminator,
        StatementTerminator::Explicit(_)
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
}

#[test]
fn distinguishes_method_calls_field_calls_and_postfix_shapes() {
    let expression = tail_expression("value.member\n(mut state, move file).field[0].1?");
    let ExprKind::Propagate(receiver) = expression.kind else {
        panic!("propagation expected")
    };
    let ExprKind::TupleField { receiver, index } = receiver.kind else {
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

    let matched = tail_expression("match value { some(item) if ready => item, none => 0, }");
    assert!(matches!(
        matched.kind,
        ExprKind::Match { ref arms, .. }
            if arms.len() == 2 && arms[0].guard.is_some()
    ));

    let handled =
        tail_expression("handle { Reader.read(\"key\") } with { Reader.read(key: Str) => key, }");
    assert!(matches!(
        handled.kind,
        ExprKind::Handle { ref handlers, .. }
            if handlers.len() == 1 && handlers[0].operation.text == "read"
    ));

    let closure = tail_expression(
        "fn [mut counter: Int, move resource, name](step: Int) -> Int with {mut<Int>} { counter + step }",
    );
    let ExprKind::Closure(closure) = closure.kind else {
        panic!("closure expected")
    };
    let captures = closure.captures.expect("explicit capture list expected");
    assert_eq!(captures.captures.len(), 3);
    assert_eq!(
        captures.captures[0].mode.as_ref().unwrap().kind,
        ParameterMode::Mut
    );
    assert_eq!(
        captures.captures[1].mode.as_ref().unwrap().kind,
        ParameterMode::Move
    );
    assert!(captures.captures[2].mode.is_none());
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
    _ => 0,
    1 => 1,
    2.5 => 2,
    "text" => 3,
    true => 4,
    none => 5,
    Pair(left, _) => 6,
    Named { first, second: _, .. } => 7,
    (left, right) => 8,
    Red | Green if visible => 9,
}
"#,
    );
    let ExprKind::Match { arms, .. } = expression.kind else {
        panic!("match expected")
    };
    assert_eq!(arms.len(), 10);
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
}

#[test]
fn accepts_unresolved_surface_without_semantic_guessing() {
    let program = parse(
        r#"
fn unresolved(value) {
    lower_case { ..base, field };
    UPPER(1);
    namespace::constructor { value: 1 };
    transfer(mut state.field, move resource);
    mode_assertion?
}
"#,
    )
    .unwrap();
    let DeclarationKind::Function(function) = &program.declarations[0].kind else {
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
    1;
    1.5;
    "plain";
    r"raw";
    "before ${value} after";
    true;
    value;
    Thing {};
    [value];
    ();
    (value);
    (left, right);
    { value };
    if ready {} else {};
    match value {};
    handle {} with {};
    fn() {};
    unsafe {};
    risky catch {};
    -value;
    !value;
    left + right;
    value?;
    callable(value);
    value[index];
    value.0;
    value.field;
    value.method();
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
        .collect::<Vec<_>>();
    assert_eq!(expressions.len(), 28);
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
    assert!(matches!(expressions[22], ExprKind::Propagate(_)));
    assert!(matches!(expressions[23], ExprKind::Call { .. }));
    assert!(matches!(expressions[24], ExprKind::Index { .. }));
    assert!(matches!(expressions[25], ExprKind::TupleField { .. }));
    assert!(matches!(expressions[26], ExprKind::Field { .. }));
    assert!(matches!(expressions[27], ExprKind::MethodCall { .. }));
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

    let body = first_function_body(
        r#"
fn assignments() {
    value = one;
    value += one;
    value -= one;
    value *= one;
    value /= one;
    value %= one;
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

    let call = tail_expression("callable(value, mut state.field, move resource)");
    let ExprKind::Call { arguments, .. } = call.kind else {
        panic!("call expected")
    };
    assert!(matches!(arguments[0], CallArgument::Expression(_)));
    assert!(matches!(
        arguments[1],
        CallArgument::Mode {
            mode: Spanned {
                kind: ParameterMode::Mut,
                ..
            },
            ..
        }
    ));
    assert!(matches!(
        arguments[2],
        CallArgument::Mode {
            mode: Spanned {
                kind: ParameterMode::Move,
                ..
            },
            ..
        }
    ));
}

#[test]
fn preserves_effect_path_and_optional_carriers() {
    let program = parse(
        r#"
requires {console, mut<Int>, unsafe};
fn probe() with {Reader<Str>, mut, unsafe} { () }
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
        EffectKind::Mutation { ref arguments } if arguments.len() == 1
    ));
    assert!(matches!(
        requires.effects.effects[2].kind,
        EffectKind::Unsafe
    ));

    let DeclarationKind::Function(function) = &program.declarations[0].kind else {
        unreachable!()
    };
    let effects = function.item.effects.as_ref().unwrap();
    assert!(matches!(
        effects.effects[0].kind,
        EffectKind::Named { ref arguments, .. } if arguments.len() == 1
    ));
    assert!(matches!(
        effects.effects[1].kind,
        EffectKind::Mutation { ref arguments } if arguments.is_empty()
    ));

    let absent = first_function_body("fn absent(parameter) { work(); }");
    assert!(absent.tail.is_none());
    let empty_capture = tail_expression("fn []() {}");
    assert!(matches!(
        empty_capture.kind,
        ExprKind::Closure(ClosureExpression {
            captures: Some(CaptureList { ref captures, .. }),
            ..
        }) if captures.is_empty()
    ));

    let use_path = &program.requires.expect("requires expected").effects.effects[0];
    let EffectKind::Named { path, .. } = &use_path.kind else {
        unreachable!()
    };
    assert!(matches!(path.segments[0], PathSegment::Identifier(_)));

    let super_program = parse("use super::parent::value;").unwrap();
    assert!(matches!(
        super_program.uses[0].path.segments[0],
        PathSegment::Super(_)
    ));
}

#[test]
fn rejects_excluded_or_ambiguous_surfaces() {
    let invalid = [
        "fn invalid(value: Int?) {}",
        "fn invalid(mut value) {}",
        "fn invalid(mut self) {}",
        "fn invalid() { fn(value) [move resource] { value }; }",
        "pub impl Value {}",
        "effect Bad { fn op() -> Unit, }",
        "trait Bad { fn method() {} }",
        "fn invalid() { ordinary() next(); }",
        "fn invalid() { while ready {}; () }",
        "fn invalid() { transfer(mut make_state()); }",
        "fn invalid() { transfer(move (resource)); }",
        "fn invalid() { Thing { field, ..base } }",
        "fn invalid() { (single,) }",
        "fn invalid(value: (Single)) {}",
        "fn first() {} use later;",
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

    let diagnostic = parse("fn invalid() { @derive(Json); }").unwrap_err();
    assert_eq!(
        diagnostic.kind,
        FrontendDiagnosticKind::Lexical(LexicalDiagnosticKind::UnexpectedCharacter)
    );
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
const inferred = value;
fn optional(parameter) {
    return value;
}
fn conditional() {
    if ready {}
}
"#,
    )
    .unwrap();
    assert!(program.requires.is_none());
    let DeclarationKind::Const(constant) = &program.declarations[0].kind else {
        unreachable!()
    };
    assert!(constant.visibility.is_none());
    assert!(constant.item.annotation.is_none());

    let DeclarationKind::Function(function) = &program.declarations[1].kind else {
        unreachable!()
    };
    assert!(function.item.parameters[0].annotation.is_none());
    assert!(function.item.return_type.is_none());
    assert!(function.item.effects.is_none());
    assert!(function.item.body.tail.is_none());
    assert!(matches!(
        function.item.body.statements[0].kind,
        StatementKind::Return(Some(_))
    ));

    let DeclarationKind::Function(conditional) = &program.declarations[2].kind else {
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
    let DeclarationKind::Function(function) = &program.declarations[0].kind else {
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

    let invalid = "fn invalid() { return +; }";
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
        parse("fn valid() { if (packet { ready: true }).ready { start(); } () }").unwrap();
    assert_eq!(program.declarations.len(), 1);
}
