//! C11 code generation for checked programs.
//!
//! Expressions are flattened into temporaries so evaluation order is explicit.
//! `Str` values are reference counted, and so are tuples, structs and enums
//! that contain them ("counted" types): locals and temporaries own one count,
//! parameters and borrowed operands own none, and every owned value is released
//! when its scope ends or right after its last borrowing use.

use std::fmt::Write as _;

use crate::ast::{AssignmentOperator, BinaryOperator, UnaryOperator};
use crate::checker::{
    Arm, Block, Expr, ExprKind, Function, Intrinsic, Pattern, Place, Program, Statement, Type,
    TypeKind, Types,
};

const RUNTIME: &str = include_str!("../../../runtime/vorton_runtime.c");

/// Generates one self-contained C11 translation unit for `program`.
pub(crate) fn emit(program: &Program) -> String {
    let mut literals = Literals::default();
    let mut bodies = String::new();
    for (index, function) in program.functions.iter().enumerate() {
        bodies.push_str(&FunctionEmitter::emit(
            program,
            index,
            function,
            &mut literals,
        ));
    }

    let mut output = String::from(RUNTIME);
    output.push('\n');
    output.push_str(&type_definitions(&program.types));
    output.push_str(&literals.declarations);
    for (index, function) in program.functions.iter().enumerate() {
        writeln!(output, "{};", prototype(&program.types, index, function)).unwrap();
    }
    output.push('\n');
    output.push_str(&bodies);
    writeln!(
        output,
        "int main(void) {{\n    {}();\n    vt_finish();\n    return 0;\n}}",
        function_name(program.main, &program.functions[program.main])
    )
    .unwrap();
    output
}

/// C definitions for every tuple, struct and enum type, components first,
/// with retain and release helpers for counted types and an equality function
/// for types that support `==`.
fn type_definitions(types: &Types) -> String {
    let mut output = String::new();
    let mut done = vec![false; types.len()];
    for ty in types.all() {
        define(types, ty, &mut done, &mut output);
    }
    output
}

fn define(types: &Types, ty: Type, done: &mut [bool], output: &mut String) {
    if done[ty.index()] || !is_aggregate(types, ty) {
        return;
    }
    done[ty.index()] = true;
    for component in types.components(ty) {
        define(types, component, done, output);
    }
    let name = c_type(types, ty);
    writeln!(output, "typedef struct {name} {{").unwrap();
    if types.is_enum(ty) {
        output.push_str("    int32_t tag;\n");
        let mut union = String::new();
        for (variant, fields) in variant_fields(types, ty).iter().enumerate() {
            let members = fields
                .iter()
                .enumerate()
                .filter(|(_, field)| types.has_storage(**field))
                .map(|(index, field)| format!("{} f{index};", c_type(types, *field)))
                .collect::<Vec<_>>();
            if !members.is_empty() {
                writeln!(
                    union,
                    "        struct {{ {} }} v{variant};",
                    members.join(" ")
                )
                .unwrap();
            }
        }
        if !union.is_empty() {
            writeln!(output, "    union {{\n{union}    }} u;").unwrap();
        }
    } else {
        let mut stored = 0;
        for (index, component) in types.components(ty).iter().enumerate() {
            if types.has_storage(*component) {
                writeln!(output, "    {} f{index};", c_type(types, *component)).unwrap();
                stored += 1;
            }
        }
        if stored == 0 {
            output.push_str("    char vt_empty;\n");
        }
    }
    writeln!(output, "}} {name};").unwrap();

    let parts = variant_fields(types, ty);
    if types.is_counted(ty) {
        for action in ["retain", "release"] {
            writeln!(
                output,
                "static void vt_{action}_T{}({name} v) {{",
                ty.index()
            )
            .unwrap();
            for (variant, fields) in parts.iter().enumerate() {
                let lines = fields
                    .iter()
                    .enumerate()
                    .filter(|(_, field)| types.is_counted(**field))
                    .map(|(index, field)| {
                        count_line(*field, action, &field_code(types, ty, variant, index, "v"))
                    })
                    .collect::<Vec<_>>();
                if lines.is_empty() {
                    continue;
                }
                if types.is_enum(ty) {
                    writeln!(
                        output,
                        "    if (v.tag == {variant}) {{ {} }}",
                        lines.join(" ")
                    )
                    .unwrap();
                } else {
                    for line in lines {
                        writeln!(output, "    {line}").unwrap();
                    }
                }
            }
            output.push_str("}\n");
        }
    }
    if has_equality(types, ty) {
        writeln!(
            output,
            "static bool vt_eq_T{}({name} a, {name} b) {{",
            ty.index()
        )
        .unwrap();
        if types.is_enum(ty) {
            output.push_str("    if (a.tag != b.tag) return false;\n");
        }
        for (variant, fields) in parts.iter().enumerate() {
            let tests = fields
                .iter()
                .enumerate()
                .filter(|(_, field)| types.has_storage(**field))
                .map(|(index, field)| {
                    equal_code(
                        types,
                        *field,
                        &field_code(types, ty, variant, index, "a"),
                        &field_code(types, ty, variant, index, "b"),
                    )
                })
                .collect::<Vec<_>>();
            if tests.is_empty() {
                continue;
            }
            if types.is_enum(ty) {
                writeln!(
                    output,
                    "    if (a.tag == {variant}) return {};",
                    tests.join(" && ")
                )
                .unwrap();
            } else {
                writeln!(output, "    return {};", tests.join(" && ")).unwrap();
            }
        }
        output.push_str("    return true;\n}\n");
    }
}

/// The field types of each variant; a tuple or struct has one variant.
fn variant_fields(types: &Types, ty: Type) -> Vec<Vec<Type>> {
    match types.kind(ty) {
        TypeKind::Tuple(elements) => vec![elements.clone()],
        TypeKind::Nominal { .. } => types
            .variants(ty)
            .iter()
            .map(|variant| variant.fields.iter().map(|field| field.ty).collect())
            .collect(),
        _ => Vec::new(),
    }
}

/// The C lvalue of field `index` of `variant` inside `base` of type `ty`.
fn field_code(types: &Types, ty: Type, variant: usize, index: usize, base: &str) -> String {
    if types.is_enum(ty) {
        format!("{base}.u.v{variant}.f{index}")
    } else {
        format!("{base}.f{index}")
    }
}

fn is_aggregate(types: &Types, ty: Type) -> bool {
    matches!(
        types.kind(ty),
        TypeKind::Tuple(_) | TypeKind::Nominal { .. }
    )
}

fn has_equality(types: &Types, ty: Type) -> bool {
    match types.kind(ty) {
        TypeKind::Int | TypeKind::Float | TypeKind::Bool | TypeKind::Str | TypeKind::Unit => true,
        TypeKind::Never => false,
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } => types
            .components(ty)
            .into_iter()
            .all(|component| has_equality(types, component)),
    }
}

/// A C expression that compares two values of type `ty`.
fn equal_code(types: &Types, ty: Type, a: &str, b: &str) -> String {
    match types.kind(ty) {
        TypeKind::Unit | TypeKind::Never => "true".to_owned(),
        TypeKind::Str => format!("vt_str_eq({a}, {b})"),
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } => {
            format!("vt_eq_T{}({a}, {b})", ty.index())
        }
        TypeKind::Int | TypeKind::Float | TypeKind::Bool => format!("({a} == {b})"),
    }
}

/// The statement that retains or releases the counts inside `code`.
fn count_line(ty: Type, action: &str, code: &str) -> String {
    if ty == Type::STR {
        format!("vt_str_{action}({code});")
    } else {
        format!("vt_{action}_T{}({code});", ty.index())
    }
}

fn function_name(index: usize, function: &Function) -> String {
    format!("vt_f{index}_{}", function.name)
}

fn prototype(types: &Types, index: usize, function: &Function) -> String {
    let parameters = function
        .parameters
        .iter()
        .filter(|&&local| types.has_storage(function.locals[local].ty))
        .map(|&local| {
            let local_info = &function.locals[local];
            format!(
                "{} {}",
                c_type(types, local_info.ty),
                local_name(local, &local_info.name)
            )
        })
        .collect::<Vec<_>>();
    let parameters = if parameters.is_empty() {
        "void".to_owned()
    } else {
        parameters.join(", ")
    };
    format!(
        "static {} {}({parameters})",
        c_type(types, function.result),
        function_name(index, function)
    )
}

fn c_type(types: &Types, ty: Type) -> String {
    match types.kind(ty) {
        TypeKind::Int => "int64_t".to_owned(),
        TypeKind::Float => "double".to_owned(),
        TypeKind::Bool => "bool".to_owned(),
        TypeKind::Str => "vt_str *".to_owned(),
        TypeKind::Unit | TypeKind::Never => "void".to_owned(),
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } => format!("vt_T{}", ty.index()),
    }
}

fn zero(types: &Types, ty: Type) -> &'static str {
    match types.kind(ty) {
        TypeKind::Int => "0",
        TypeKind::Float => "0.0",
        TypeKind::Bool => "false",
        TypeKind::Str => "NULL",
        TypeKind::Tuple(_) | TypeKind::Nominal { .. } => "{0}",
        TypeKind::Unit | TypeKind::Never => unreachable!("unit values have no storage"),
    }
}

fn local_name(local: usize, name: &str) -> String {
    format!("v{local}_{name}")
}

#[derive(Default)]
struct Literals {
    declarations: String,
    count: usize,
}

impl Literals {
    fn add(&mut self, value: &str) -> String {
        let name = format!("vt_lit{}", self.count);
        self.count += 1;
        writeln!(
            self.declarations,
            "static vt_str {name} = {{-1, {}, \"{}\"}};",
            value.len(),
            escape_c(value)
        )
        .unwrap();
        format!("(&{name})")
    }
}

fn escape_c(value: &str) -> String {
    let mut escaped = String::new();
    for byte in value.bytes() {
        match byte {
            b'\\' => escaped.push_str("\\\\"),
            b'"' => escaped.push_str("\\\""),
            b'?' => escaped.push_str("\\?"),
            b' '..=b'~' => escaped.push(char::from(byte)),
            _ => write!(escaped, "\\{byte:03o}").unwrap(),
        }
    }
    escaped
}

/// A lowered operand. `owned` operands of counted types hold one count that
/// the consumer must either store or release.
#[derive(Clone)]
enum Value {
    Unit,
    Never,
    Code { code: String, owned: bool },
}

impl Value {
    fn code(&self) -> &str {
        match self {
            Self::Code { code, .. } => code,
            Self::Unit | Self::Never => unreachable!("only typed values have C code"),
        }
    }
}

struct FunctionEmitter<'a> {
    program: &'a Program,
    types: &'a Types,
    function: &'a Function,
    literals: &'a mut Literals,
    declarations: String,
    body: String,
    indent: usize,
    temporaries: usize,
    labels: usize,
    /// Counted values that the current code owns, per open scope, as C
    /// lvalues with their types.
    scopes: Vec<Vec<(String, Type)>>,
    /// The scope depth at the start of each enclosing loop body.
    loops: Vec<usize>,
}

impl FunctionEmitter<'_> {
    fn emit(
        program: &Program,
        index: usize,
        function: &Function,
        literals: &mut Literals,
    ) -> String {
        let types = &program.types;
        let mut emitter = FunctionEmitter {
            program,
            types,
            function,
            literals,
            declarations: String::new(),
            body: String::new(),
            indent: 1,
            temporaries: 0,
            labels: 0,
            scopes: Vec::new(),
            loops: Vec::new(),
        };
        for (local, info) in function.locals.iter().enumerate() {
            if !function.parameters.contains(&local) && types.has_storage(info.ty) {
                writeln!(
                    emitter.declarations,
                    "    {} {} = {};",
                    c_type(types, info.ty),
                    local_name(local, &info.name),
                    zero(types, info.ty)
                )
                .unwrap();
            }
        }
        let value = emitter.block(&function.body);
        match value {
            Value::Never => {}
            Value::Unit => emitter.line("return;"),
            Value::Code { .. } => {
                let value = emitter.owned(value, function.result);
                emitter.line(&format!("return {};", value.code()));
            }
        }
        format!(
            "{} {{\n{}{}}}\n\n",
            prototype(types, index, function),
            emitter.declarations,
            emitter.body
        )
    }

    fn line(&mut self, text: &str) {
        for _ in 0..self.indent {
            self.body.push_str("    ");
        }
        self.body.push_str(text);
        self.body.push('\n');
    }

    fn temporary(&mut self, ty: Type) -> String {
        let name = format!("t{}", self.temporaries);
        self.temporaries += 1;
        writeln!(
            self.declarations,
            "    {} {name} = {};",
            c_type(self.types, ty),
            zero(self.types, ty)
        )
        .unwrap();
        name
    }

    fn counted(&self, ty: Type) -> bool {
        self.types.is_counted(ty)
    }

    fn local_code(&self, local: usize) -> String {
        local_name(local, &self.function.locals[local].name)
    }

    /// Records that the innermost scope owns `code` of type `ty`.
    fn own(&mut self, code: String, ty: Type) {
        if self.counted(ty) {
            self.scopes
                .last_mut()
                .expect("a scope is open")
                .push((code, ty));
        }
    }

    /// Makes `value` an owned operand, retaining a borrowed counted value.
    fn owned(&mut self, value: Value, ty: Type) -> Value {
        match value {
            Value::Code { code, owned: false } if self.counted(ty) => {
                let temporary = self.temporary(ty);
                self.line(&format!("{temporary} = {code};"));
                self.line(&count_line(ty, "retain", &temporary));
                Value::Code {
                    code: temporary,
                    owned: true,
                }
            }
            value => value,
        }
    }

    /// Releases `value` after a borrowing use if it owns a count.
    fn release(&mut self, value: &Value, ty: Type) {
        if let Value::Code { code, owned: true } = value {
            self.line(&count_line(ty, "release", code));
        }
    }

    fn release_scopes_from(&mut self, depth: usize) {
        let owned = self.scopes[depth..]
            .iter()
            .flatten()
            .rev()
            .cloned()
            .collect::<Vec<_>>();
        for (code, ty) in owned {
            self.line(&count_line(ty, "release", &code));
        }
    }

    fn block(&mut self, block: &Block) -> Value {
        self.scopes.push(Vec::new());
        for statement in &block.statements {
            if self.statement(statement) {
                self.scopes.pop();
                return Value::Never;
            }
        }
        let value = match &block.tail {
            Some(tail) => {
                let value = self.expr(tail);
                if block.ty == Type::UNIT {
                    self.release(&value, tail.ty);
                    Value::Unit
                } else if matches!(value, Value::Never) || block.ty == Type::NEVER {
                    Value::Never
                } else {
                    self.owned(value, block.ty)
                }
            }
            None if block.ty == Type::NEVER => Value::Never,
            None => Value::Unit,
        };
        if !matches!(value, Value::Never) {
            let depth = self.scopes.len() - 1;
            self.release_scopes_from(depth);
        }
        self.scopes.pop();
        value
    }

    fn place_code(&self, place: &Place) -> String {
        let mut code = self.local_code(place.local);
        for index in &place.path {
            write!(code, ".f{index}").unwrap();
        }
        code
    }

    /// Emits `statement` and returns whether control cannot continue after it.
    fn statement(&mut self, statement: &Statement) -> bool {
        match statement {
            Statement::Let { local, value } => {
                let ty = self.function.locals[*local].ty;
                let value = self.expr(value);
                if matches!(value, Value::Never) {
                    return true;
                }
                if matches!(value, Value::Unit) {
                    return false;
                }
                let value = self.owned(value, ty);
                let name = self.local_code(*local);
                self.line(&format!("{name} = {};", value.code()));
                self.own(name, ty);
                false
            }
            Statement::LetPattern { pattern, value } => {
                let ty = value.ty;
                let subject = self.expr(value);
                if matches!(subject, Value::Never) {
                    return true;
                }
                let code = self.subject(subject, ty);
                self.bind(pattern, &code, ty);
                self.close_subject();
                self.register_bindings(pattern);
                false
            }
            Statement::Assign {
                place,
                operator,
                value,
            } => {
                let ty = value.ty;
                let value = self.expr(value);
                if matches!(value, Value::Never) {
                    return true;
                }
                if matches!(value, Value::Unit) {
                    return false;
                }
                let name = self.place_code(place);
                let code = value.code().to_owned();
                match (operator, ty) {
                    (AssignmentOperator::Assign, ty) if self.counted(ty) => {
                        let value = self.owned(value, ty);
                        self.line(&count_line(ty, "release", &name));
                        self.line(&format!("{name} = {};", value.code()));
                    }
                    (AssignmentOperator::Assign, _) => self.line(&format!("{name} = {code};")),
                    (operator, Type::INT) => {
                        let function = match operator {
                            AssignmentOperator::AddAssign => "vt_int_add",
                            AssignmentOperator::SubtractAssign => "vt_int_sub",
                            AssignmentOperator::MultiplyAssign => "vt_int_mul",
                            AssignmentOperator::DivideAssign => "vt_int_div",
                            AssignmentOperator::RemainderAssign => "vt_int_rem",
                            AssignmentOperator::Assign => unreachable!(),
                        };
                        self.line(&format!("{name} = {function}({name}, {code});"));
                    }
                    (operator, _) => {
                        let expression = match operator {
                            AssignmentOperator::AddAssign => format!("{name} + {code}"),
                            AssignmentOperator::SubtractAssign => format!("{name} - {code}"),
                            AssignmentOperator::MultiplyAssign => format!("{name} * {code}"),
                            AssignmentOperator::DivideAssign => format!("{name} / {code}"),
                            AssignmentOperator::RemainderAssign => format!("fmod({name}, {code})"),
                            AssignmentOperator::Assign => unreachable!(),
                        };
                        self.line(&format!("{name} = {expression};"));
                    }
                }
                false
            }
            Statement::Expr(expression) => {
                let value = self.expr(expression);
                self.release(&value, expression.ty);
                matches!(value, Value::Never)
            }
            Statement::Return(value) => {
                let value = match value {
                    Some(value) => self.expr(value),
                    None => Value::Unit,
                };
                match value {
                    Value::Never => {}
                    Value::Unit => {
                        self.release_scopes_from(0);
                        self.line("return;");
                    }
                    value => {
                        let value = self.owned(value, self.function.result);
                        self.release_scopes_from(0);
                        self.line(&format!("return {};", value.code()));
                    }
                }
                true
            }
            Statement::Break | Statement::Continue => {
                let depth = *self
                    .loops
                    .last()
                    .expect("the checker allows these only in loops");
                self.release_scopes_from(depth);
                self.line(if matches!(statement, Statement::Break) {
                    "break;"
                } else {
                    "continue;"
                });
                true
            }
            Statement::While { condition, body } => {
                self.line("for (;;) {");
                self.indent += 1;
                let condition = self.expr(condition);
                if !matches!(condition, Value::Never) {
                    self.line(&format!("if (!{}) break;", condition.code()));
                    self.loop_body(body);
                }
                self.indent -= 1;
                self.line("}");
                false
            }
            Statement::Loop(body) => {
                self.line("for (;;) {");
                self.indent += 1;
                self.loop_body(body);
                self.indent -= 1;
                self.line("}");
                body.ty == Type::NEVER && !loop_breaks(body)
            }
        }
    }

    fn loop_body(&mut self, body: &Block) {
        self.loops.push(self.scopes.len());
        self.block(body);
        self.loops.pop();
    }

    fn expr(&mut self, expression: &Expr) -> Value {
        match &expression.kind {
            ExprKind::Int(value) => Value::Code {
                code: int_literal(*value),
                owned: false,
            },
            ExprKind::Float(value) => Value::Code {
                code: format!("{value:e}"),
                owned: false,
            },
            ExprKind::Bool(value) => Value::Code {
                code: if *value { "true" } else { "false" }.to_owned(),
                owned: false,
            },
            ExprKind::Str(value) => Value::Code {
                code: self.literals.add(value),
                owned: false,
            },
            ExprKind::Unit => Value::Unit,
            ExprKind::Local(local) => {
                if self.types.has_storage(self.function.locals[*local].ty) {
                    Value::Code {
                        code: self.local_code(*local),
                        owned: false,
                    }
                } else {
                    Value::Unit
                }
            }
            ExprKind::Call {
                function,
                arguments,
            } => self.call(*function, arguments, expression.ty),
            ExprKind::Intrinsic {
                intrinsic,
                arguments,
            } => self.intrinsic(*intrinsic, arguments),
            ExprKind::Unary { operator, operand } => {
                let operand = self.expr(operand);
                if matches!(operand, Value::Never) {
                    return Value::Never;
                }
                let code = match (operator, expression.ty) {
                    (UnaryOperator::Negate, Type::INT) => format!("vt_int_neg({})", operand.code()),
                    (UnaryOperator::Negate, _) => format!("(-{})", operand.code()),
                    (UnaryOperator::Not, _) => format!("(!{})", operand.code()),
                };
                self.store(expression.ty, code, false)
            }
            ExprKind::Binary {
                operator,
                left,
                right,
            } => self.binary(*operator, left, right, expression.ty),
            ExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => self.if_expr(
                condition,
                then_branch,
                else_branch.as_deref(),
                expression.ty,
            ),
            ExprKind::Block(block) => self.block(block),
            ExprKind::Interpolate(parts) => self.interpolate(parts),
            ExprKind::Tuple(elements) => {
                let fields = elements.iter().enumerate().collect::<Vec<_>>();
                self.aggregate(expression.ty, 0, None, &fields)
            }
            ExprKind::Construct {
                variant,
                base,
                fields,
            } => {
                let fields = fields
                    .iter()
                    .map(|(index, value)| (*index, value))
                    .collect::<Vec<_>>();
                self.aggregate(expression.ty, *variant, base.as_deref(), &fields)
            }
            ExprKind::Field { base, index } => self.field(base, *index, expression.ty),
            ExprKind::Match { scrutinee, arms } => self.match_expr(scrutinee, arms, expression.ty),
        }
    }

    /// Builds a tuple, struct or enum value from `base` and the given fields,
    /// evaluated in that order.
    fn aggregate(
        &mut self,
        ty: Type,
        variant: usize,
        base: Option<&Expr>,
        fields: &[(usize, &Expr)],
    ) -> Value {
        let base = match base {
            Some(base) => {
                let value = self.expr(base);
                if matches!(value, Value::Never) {
                    return Value::Never;
                }
                Some(self.owned(value, ty))
            }
            None => None,
        };
        let mut values = Vec::new();
        for (index, field) in fields {
            let value = self.expr(field);
            if matches!(value, Value::Never) {
                return Value::Never;
            }
            values.push((*index, field.ty, value));
        }
        let result = self.temporary(ty);
        if let Some(base) = &base {
            self.line(&format!("{result} = {};", base.code()));
        }
        if self.types.is_enum(ty) {
            self.line(&format!("{result}.tag = {variant};"));
        }
        for (index, field_ty, value) in values {
            if matches!(value, Value::Unit) {
                continue;
            }
            let value = self.owned(value, field_ty);
            let target = field_code(self.types, ty, variant, index, &result);
            if base.is_some() && self.counted(field_ty) {
                self.line(&count_line(field_ty, "release", &target));
            }
            self.line(&format!("{target} = {};", value.code()));
        }
        Value::Code {
            code: result,
            owned: self.counted(ty),
        }
    }

    fn field(&mut self, base: &Expr, index: usize, ty: Type) -> Value {
        let value = self.expr(base);
        let Value::Code { code, owned } = value else {
            return value;
        };
        if !self.types.has_storage(ty) {
            self.release(&Value::Code { code, owned }, base.ty);
            return Value::Unit;
        }
        let field = field_code(self.types, base.ty, 0, index, &code);
        if !owned {
            return Value::Code {
                code: field,
                owned: false,
            };
        }
        let result = if self.counted(ty) {
            self.owned(
                Value::Code {
                    code: field,
                    owned: false,
                },
                ty,
            )
        } else {
            self.store(ty, field, false)
        };
        self.release(&Value::Code { code, owned }, base.ty);
        result
    }

    /// Keeps a match subject in a temporary that the tests and bindings read.
    /// An owned counted subject is owned by a new scope that
    /// [`Self::close_subject`] closes.
    fn subject(&mut self, value: Value, ty: Type) -> Option<String> {
        self.scopes.push(Vec::new());
        match value {
            Value::Code { code, owned } => {
                let temporary = self.store(ty, code, owned);
                if owned {
                    self.own(temporary.code().to_owned(), ty);
                }
                Some(temporary.code().to_owned())
            }
            Value::Unit | Value::Never => None,
        }
    }

    fn close_subject(&mut self) {
        let depth = self.scopes.len() - 1;
        self.release_scopes_from(depth);
        self.scopes.pop();
    }

    fn match_expr(&mut self, scrutinee: &Expr, arms: &[Arm], ty: Type) -> Value {
        let subject_ty = scrutinee.ty;
        let value = self.expr(scrutinee);
        if matches!(value, Value::Never) {
            return Value::Never;
        }
        let code = self.subject(value, subject_ty);
        let result = self.types.has_storage(ty).then(|| self.temporary(ty));
        let end = format!("vt_m{}", self.labels);
        self.labels += 1;
        for arm in arms {
            let test = code.as_deref().map_or_else(
                || "true".to_owned(),
                |code| self.test(&arm.pattern, code, subject_ty),
            );
            self.line(&format!("if ({test}) {{"));
            self.indent += 1;
            self.scopes.push(Vec::new());
            self.bind(&arm.pattern, &code, subject_ty);
            self.register_bindings(&arm.pattern);
            let guard = match &arm.guard {
                Some(guard) => {
                    let value = self.expr(guard);
                    if matches!(value, Value::Never) {
                        None
                    } else {
                        self.line(&format!("if ({}) {{", value.code()));
                        self.indent += 1;
                        Some(())
                    }
                }
                None => None,
            };
            let value = self.expr(&arm.body);
            if !matches!(value, Value::Never) {
                self.assign_branch(result.as_deref(), value, arm.body.ty);
                let depth = self.scopes.len() - 1;
                self.release_scopes_from(depth);
                self.line(&format!("goto {end};"));
            }
            if guard.is_some() {
                self.indent -= 1;
                self.line("}");
                let depth = self.scopes.len() - 1;
                self.release_scopes_from(depth);
            }
            self.scopes.pop();
            self.indent -= 1;
            self.line("}");
        }
        self.line("vt_unreachable();");
        self.line(&format!("{end}:;"));
        self.close_subject();
        match result {
            Some(code) => Value::Code {
                code,
                owned: self.counted(ty),
            },
            None if ty == Type::NEVER => Value::Never,
            None => Value::Unit,
        }
    }

    /// A side-effect-free C condition that holds when `pattern` matches `code`.
    fn test(&mut self, pattern: &Pattern, code: &str, ty: Type) -> String {
        match pattern {
            Pattern::Wildcard | Pattern::Binding(_) => "true".to_owned(),
            Pattern::Int(value) => format!("({code} == {})", int_literal(*value)),
            Pattern::Float(value) => format!("({code} == {value:e})"),
            Pattern::Bool(value) => format!("({code} == {value})"),
            Pattern::Str(value) => format!("vt_str_eq({code}, {})", self.literals.add(value)),
            Pattern::Tuple(elements) => {
                let element_types = self.types.components(ty);
                let tests = elements
                    .iter()
                    .zip(element_types)
                    .enumerate()
                    .map(|(index, (element, element_ty))| {
                        let field = field_code(self.types, ty, 0, index, code);
                        self.test(element, &field, element_ty)
                    })
                    .collect::<Vec<_>>();
                conjunction(&tests)
            }
            Pattern::Variant { variant, fields } => {
                let mut tests = vec![format!("({code}.tag == {variant})")];
                for (index, field) in fields {
                    let field_ty = self.types.variants(ty)[*variant].fields[*index].ty;
                    let field_code = field_code(self.types, ty, *variant, *index, code);
                    tests.push(self.test(field, &field_code, field_ty));
                }
                conjunction(&tests)
            }
            Pattern::Or(alternatives) => {
                let tests = alternatives
                    .iter()
                    .map(|alternative| self.test(alternative, code, ty))
                    .collect::<Vec<_>>();
                format!("({})", tests.join(" || "))
            }
        }
    }

    /// Copies the matched parts of `code` into the pattern's binding locals,
    /// retaining counted ones.
    fn bind(&mut self, pattern: &Pattern, code: &Option<String>, ty: Type) {
        let Some(code) = code else {
            return;
        };
        match pattern {
            Pattern::Binding(local) => {
                if self.types.has_storage(ty) {
                    let name = self.local_code(*local);
                    self.line(&format!("{name} = {code};"));
                    if self.counted(ty) {
                        self.line(&count_line(ty, "retain", &name));
                    }
                }
            }
            Pattern::Tuple(elements) => {
                let element_types = self.types.components(ty);
                for (index, (element, element_ty)) in elements.iter().zip(element_types).enumerate()
                {
                    let field = field_code(self.types, ty, 0, index, code);
                    self.bind(element, &Some(field), element_ty);
                }
            }
            Pattern::Variant { variant, fields } => {
                for (index, field) in fields {
                    let field_ty = self.types.variants(ty)[*variant].fields[*index].ty;
                    let field_code = field_code(self.types, ty, *variant, *index, code);
                    self.bind(field, &Some(field_code), field_ty);
                }
            }
            Pattern::Or(alternatives) => {
                if !binds(pattern) {
                    return;
                }
                let mut keyword = "if";
                for alternative in alternatives {
                    let test = self.test(alternative, code, ty);
                    self.line(&format!("{keyword} ({test}) {{"));
                    self.indent += 1;
                    self.bind(alternative, &Some(code.clone()), ty);
                    self.indent -= 1;
                    self.line("}");
                    keyword = "else if";
                }
            }
            Pattern::Wildcard
            | Pattern::Int(_)
            | Pattern::Float(_)
            | Pattern::Bool(_)
            | Pattern::Str(_) => {}
        }
    }

    /// Makes the innermost scope own the counted binding locals of `pattern`.
    fn register_bindings(&mut self, pattern: &Pattern) {
        let mut locals = Vec::new();
        collect_bindings(pattern, &mut locals);
        for local in locals {
            let ty = self.function.locals[local].ty;
            let code = self.local_code(local);
            self.own(code, ty);
        }
    }

    /// Stores `code` in a new temporary so later side effects cannot reorder it.
    fn store(&mut self, ty: Type, code: String, owned: bool) -> Value {
        let temporary = self.temporary(ty);
        self.line(&format!("{temporary} = {code};"));
        Value::Code {
            code: temporary,
            owned,
        }
    }

    fn call(&mut self, function: usize, arguments: &[Expr], ty: Type) -> Value {
        let mut values = Vec::new();
        for argument in arguments {
            let value = self.expr(argument);
            if matches!(value, Value::Never) {
                return Value::Never;
            }
            values.push((value, argument.ty));
        }
        let name = function_name(function, &self.program.functions[function]);
        let code = format!(
            "{name}({})",
            values
                .iter()
                .filter(|(value, _)| !matches!(value, Value::Unit))
                .map(|(value, _)| value.code())
                .collect::<Vec<_>>()
                .join(", ")
        );
        let result = if self.types.has_storage(ty) {
            self.store(ty, code, self.counted(ty))
        } else {
            self.line(&format!("{code};"));
            if ty == Type::NEVER {
                Value::Never
            } else {
                Value::Unit
            }
        };
        for (value, ty) in &values {
            self.release(value, *ty);
        }
        result
    }

    fn intrinsic(&mut self, intrinsic: Intrinsic, arguments: &[Expr]) -> Value {
        let mut values = Vec::new();
        for argument in arguments {
            let value = self.expr(argument);
            if matches!(value, Value::Never) {
                return Value::Never;
            }
            values.push(value);
        }
        match intrinsic {
            Intrinsic::Print => {
                let text = self.stringify(&values[0], arguments[0].ty);
                self.line(&format!("vt_print({});", text.code()));
                self.release(&text, Type::STR);
                self.release(&values[0], arguments[0].ty);
                Value::Unit
            }
            Intrinsic::Assert => {
                self.line(&format!(
                    "if (!{}) vt_panic_assert({});",
                    values[0].code(),
                    values[1].code()
                ));
                self.release(&values[1], Type::STR);
                Value::Unit
            }
            Intrinsic::Panic => {
                self.line(&format!("vt_panic_str({});", values[0].code()));
                Value::Never
            }
        }
    }

    /// Converts a printable value to a `Str` operand without consuming it.
    fn stringify(&mut self, value: &Value, ty: Type) -> Value {
        match ty {
            Type::STR => Value::Code {
                code: value.code().to_owned(),
                owned: false,
            },
            Type::INT => self.store(Type::STR, format!("vt_int_to_str({})", value.code()), true),
            Type::FLOAT => self.store(
                Type::STR,
                format!("vt_float_to_str({})", value.code()),
                true,
            ),
            Type::BOOL => Value::Code {
                code: format!("vt_bool_to_str({})", value.code()),
                owned: false,
            },
            _ => unreachable!("the checker admits only printable values"),
        }
    }

    fn interpolate(&mut self, parts: &[Expr]) -> Value {
        let mut values = Vec::new();
        for part in parts {
            let value = self.expr(part);
            if matches!(value, Value::Never) {
                return Value::Never;
            }
            values.push((value, part.ty));
        }
        let mut texts = Vec::new();
        for (value, ty) in &values {
            texts.push(self.stringify(value, *ty));
        }
        let list = texts.iter().map(Value::code).collect::<Vec<_>>().join(", ");
        let result = self.store(
            Type::STR,
            format!(
                "vt_str_join({}, (vt_str *[]){{{list}}})",
                texts.len().max(1)
            ),
            true,
        );
        for text in &texts {
            self.release(text, Type::STR);
        }
        for (value, ty) in &values {
            self.release(value, *ty);
        }
        result
    }

    fn binary(&mut self, operator: BinaryOperator, left: &Expr, right: &Expr, ty: Type) -> Value {
        use BinaryOperator as Op;
        if matches!(operator, Op::LogicAnd | Op::LogicOr) {
            let left = self.expr(left);
            if matches!(left, Value::Never) {
                return Value::Never;
            }
            let result = self.store(Type::BOOL, left.code().to_owned(), false);
            let test = if operator == Op::LogicAnd {
                result.code().to_owned()
            } else {
                format!("!{}", result.code())
            };
            self.line(&format!("if ({test}) {{"));
            self.indent += 1;
            let right = self.expr(right);
            if !matches!(right, Value::Never) {
                self.line(&format!("{} = {};", result.code(), right.code()));
            }
            self.indent -= 1;
            self.line("}");
            return result;
        }
        let operand_ty = left.ty;
        let left = self.expr(left);
        if matches!(left, Value::Never) {
            return Value::Never;
        }
        let right = self.expr(right);
        if matches!(right, Value::Never) {
            self.release(&left, operand_ty);
            return Value::Never;
        }
        if !self.types.has_storage(operand_ty) {
            let code = if operator == Op::Equal {
                "true"
            } else {
                "false"
            };
            return self.store(ty, code.to_owned(), false);
        }
        let (a, b) = (left.code(), right.code());
        let code = match (operator, operand_ty) {
            (Op::Add, Type::INT) => format!("vt_int_add({a}, {b})"),
            (Op::Subtract, Type::INT) => format!("vt_int_sub({a}, {b})"),
            (Op::Multiply, Type::INT) => format!("vt_int_mul({a}, {b})"),
            (Op::Divide, Type::INT) => format!("vt_int_div({a}, {b})"),
            (Op::Remainder, Type::INT) => format!("vt_int_rem({a}, {b})"),
            (Op::Add, _) => format!("({a} + {b})"),
            (Op::Subtract, _) => format!("({a} - {b})"),
            (Op::Multiply, _) => format!("({a} * {b})"),
            (Op::Divide, _) => format!("({a} / {b})"),
            (Op::Remainder, _) => format!("fmod({a}, {b})"),
            (Op::Equal, _) => equal_code(self.types, operand_ty, a, b),
            (Op::NotEqual, _) => format!("(!{})", equal_code(self.types, operand_ty, a, b)),
            (Op::Less, Type::STR) => format!("(vt_str_compare({a}, {b}) < 0)"),
            (Op::Greater, Type::STR) => format!("(vt_str_compare({a}, {b}) > 0)"),
            (Op::LessEqual, Type::STR) => format!("(vt_str_compare({a}, {b}) <= 0)"),
            (Op::GreaterEqual, Type::STR) => format!("(vt_str_compare({a}, {b}) >= 0)"),
            (Op::Less, _) => format!("({a} < {b})"),
            (Op::Greater, _) => format!("({a} > {b})"),
            (Op::LessEqual, _) => format!("({a} <= {b})"),
            (Op::GreaterEqual, _) => format!("({a} >= {b})"),
            (Op::LogicAnd | Op::LogicOr | Op::RangeExclusive | Op::RangeInclusive, _) => {
                unreachable!("handled above or rejected by the checker")
            }
        };
        let result = self.store(ty, code, false);
        self.release(&left, operand_ty);
        self.release(&right, operand_ty);
        result
    }

    fn if_expr(
        &mut self,
        condition: &Expr,
        then_branch: &Block,
        else_branch: Option<&Expr>,
        ty: Type,
    ) -> Value {
        let condition = self.expr(condition);
        if matches!(condition, Value::Never) {
            return Value::Never;
        }
        let result = self.types.has_storage(ty).then(|| self.temporary(ty));
        self.line(&format!("if ({}) {{", condition.code()));
        self.indent += 1;
        let value = self.block(then_branch);
        self.assign_branch(result.as_deref(), value, then_branch.ty);
        self.indent -= 1;
        if let Some(else_branch) = else_branch {
            self.line("} else {");
            self.indent += 1;
            let value = self.expr(else_branch);
            self.assign_branch(result.as_deref(), value, else_branch.ty);
            self.indent -= 1;
        }
        self.line("}");
        match result {
            Some(code) => Value::Code {
                code,
                owned: self.counted(ty),
            },
            None if ty == Type::NEVER => Value::Never,
            None => Value::Unit,
        }
    }

    fn assign_branch(&mut self, result: Option<&str>, value: Value, ty: Type) {
        match (result, value) {
            (Some(result), value @ Value::Code { .. }) => {
                let value = self.owned(value, ty);
                self.line(&format!("{result} = {};", value.code()));
            }
            (None, value @ Value::Code { .. }) => self.release(&value, ty),
            (_, Value::Unit | Value::Never) => {}
        }
    }
}

fn conjunction(tests: &[String]) -> String {
    let tests = tests
        .iter()
        .filter(|test| test.as_str() != "true")
        .cloned()
        .collect::<Vec<_>>();
    if tests.is_empty() {
        "true".to_owned()
    } else {
        format!("({})", tests.join(" && "))
    }
}

/// Whether `pattern` binds any local.
fn binds(pattern: &Pattern) -> bool {
    let mut locals = Vec::new();
    collect_bindings(pattern, &mut locals);
    !locals.is_empty()
}

/// The binding locals of `pattern`; the alternatives of an or-pattern bind
/// the same locals, so only the first is read.
fn collect_bindings(pattern: &Pattern, locals: &mut Vec<usize>) {
    match pattern {
        Pattern::Binding(local) => locals.push(*local),
        Pattern::Tuple(elements) => {
            for element in elements {
                collect_bindings(element, locals);
            }
        }
        Pattern::Variant { fields, .. } => {
            for (_, field) in fields {
                collect_bindings(field, locals);
            }
        }
        Pattern::Or(alternatives) => {
            if let Some(first) = alternatives.first() {
                collect_bindings(first, locals);
            }
        }
        Pattern::Wildcard
        | Pattern::Int(_)
        | Pattern::Float(_)
        | Pattern::Bool(_)
        | Pattern::Str(_) => {}
    }
}

/// Whether some path through `body` reaches a `break` of this loop.
fn loop_breaks(body: &Block) -> bool {
    fn block_breaks(block: &Block) -> bool {
        block.statements.iter().any(statement_breaks)
            || block.tail.as_deref().is_some_and(expr_breaks)
    }
    fn statement_breaks(statement: &Statement) -> bool {
        match statement {
            Statement::Break => true,
            Statement::Let { value, .. }
            | Statement::LetPattern { value, .. }
            | Statement::Assign { value, .. } => expr_breaks(value),
            Statement::Expr(value) => expr_breaks(value),
            Statement::Return(value) => value.as_ref().is_some_and(expr_breaks),
            Statement::Continue | Statement::While { .. } | Statement::Loop(_) => false,
        }
    }
    fn expr_breaks(expression: &Expr) -> bool {
        match &expression.kind {
            ExprKind::Block(block) => block_breaks(block),
            ExprKind::If {
                then_branch,
                else_branch,
                ..
            } => block_breaks(then_branch) || else_branch.as_deref().is_some_and(expr_breaks),
            ExprKind::Match { arms, .. } => arms.iter().any(|arm| expr_breaks(&arm.body)),
            _ => false,
        }
    }
    block_breaks(body)
}

fn int_literal(value: i64) -> String {
    if value == i64::MIN {
        "INT64_MIN".to_owned()
    } else {
        format!("INT64_C({value})")
    }
}
