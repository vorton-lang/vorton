//! C11 code generation for checked programs.
//!
//! Expressions are flattened into temporaries so evaluation order is explicit.
//! `Str` values are reference counted, and so are tuples and structs that
//! contain them ("counted" types): locals and temporaries own one count,
//! parameters and borrowed operands own none, and every owned value is released
//! when its scope ends or right after its last borrowing use.

use std::fmt::Write as _;

use crate::ast::{AssignmentOperator, BinaryOperator, UnaryOperator};
use crate::checker::{
    Block, Expr, ExprKind, Function, Intrinsic, Place, Program, Statement, Type, TypeKind, Types,
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

/// C definitions for every tuple and struct type, components first, with the
/// retain and release helpers of counted ones.
fn type_definitions(types: &Types) -> String {
    fn visit(types: &Types, ty: Type, done: &mut [bool], output: &mut String) {
        if done[ty.index()] || !is_aggregate(types, ty) {
            return;
        }
        done[ty.index()] = true;
        let components = types.components(ty);
        for component in &components {
            visit(types, *component, done, output);
        }
        let name = c_type(types, ty);
        writeln!(output, "typedef struct {name} {{").unwrap();
        let mut stored = 0;
        for (index, component) in components.iter().enumerate() {
            if types.has_storage(*component) {
                writeln!(output, "    {} f{index};", c_type(types, *component)).unwrap();
                stored += 1;
            }
        }
        if stored == 0 {
            output.push_str("    char vt_empty;\n");
        }
        writeln!(output, "}} {name};").unwrap();
        if types.is_counted(ty) {
            for action in ["retain", "release"] {
                writeln!(
                    output,
                    "static void vt_{action}_T{}({name} v) {{",
                    ty.index()
                )
                .unwrap();
                for (index, component) in components.iter().enumerate() {
                    if types.is_counted(*component) {
                        writeln!(
                            output,
                            "    {}",
                            count_line(*component, action, &format!("v.f{index}"))
                        )
                        .unwrap();
                    }
                }
                output.push_str("}\n");
            }
        }
    }
    let mut output = String::new();
    let mut done = vec![false; types.len()];
    for ty in types.all() {
        visit(types, ty, &mut done, &mut output);
    }
    output
}

fn is_aggregate(types: &Types, ty: Type) -> bool {
    matches!(types.kind(ty), TypeKind::Tuple(_) | TypeKind::Struct(_))
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
        TypeKind::Tuple(_) | TypeKind::Struct(_) => format!("vt_T{}", ty.index()),
    }
}

fn zero(types: &Types, ty: Type) -> &'static str {
    match types.kind(ty) {
        TypeKind::Int => "0",
        TypeKind::Float => "0.0",
        TypeKind::Bool => "false",
        TypeKind::Str => "NULL",
        TypeKind::Tuple(_) | TypeKind::Struct(_) => "{0}",
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
    /// Counted locals that currently own their value, per open scope.
    scopes: Vec<Vec<usize>>,
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
            let line = count_line(ty, "release", code);
            self.line(&line);
        }
    }

    fn release_scopes_from(&mut self, depth: usize) {
        let locals = self.scopes[depth..]
            .iter()
            .flatten()
            .rev()
            .copied()
            .collect::<Vec<_>>();
        for local in locals {
            let info = &self.function.locals[local];
            let line = count_line(info.ty, "release", &local_name(local, &info.name));
            self.line(&line);
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
        let info = &self.function.locals[place.local];
        let mut code = local_name(place.local, &info.name);
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
                let name = local_name(*local, &self.function.locals[*local].name);
                self.line(&format!("{name} = {};", value.code()));
                if self.counted(ty) {
                    self.scopes
                        .last_mut()
                        .expect("a scope is open")
                        .push(*local);
                }
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
                        let release = count_line(ty, "release", &name);
                        self.line(&release);
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
                body.ty == Type::NEVER && !self.loop_breaks(body)
            }
        }
    }

    fn loop_body(&mut self, body: &Block) {
        self.loops.push(self.scopes.len());
        self.block(body);
        self.loops.pop();
    }

    fn loop_breaks(&self, body: &Block) -> bool {
        fn block_breaks(block: &Block) -> bool {
            block.statements.iter().any(statement_breaks)
                || block.tail.as_deref().is_some_and(expr_breaks)
        }
        fn statement_breaks(statement: &Statement) -> bool {
            match statement {
                Statement::Break => true,
                Statement::Let { value, .. } | Statement::Assign { value, .. } => {
                    expr_breaks(value)
                }
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
                _ => false,
            }
        }
        block_breaks(body)
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
                let info = &self.function.locals[*local];
                if self.types.has_storage(info.ty) {
                    Value::Code {
                        code: local_name(*local, &info.name),
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
                self.aggregate(expression.ty, None, &fields)
            }
            ExprKind::Construct { base, fields } => {
                let fields = fields
                    .iter()
                    .map(|(index, value)| (*index, value))
                    .collect::<Vec<_>>();
                self.aggregate(expression.ty, base.as_deref(), &fields)
            }
            ExprKind::Field { base, index } => self.field(base, *index, expression.ty),
        }
    }

    /// Builds a tuple or struct from `base` and the given fields, evaluated in
    /// that order.
    fn aggregate(&mut self, ty: Type, base: Option<&Expr>, fields: &[(usize, &Expr)]) -> Value {
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
        for (index, field_ty, value) in values {
            if matches!(value, Value::Unit) {
                continue;
            }
            let value = self.owned(value, field_ty);
            let target = format!("{result}.f{index}");
            if base.is_some() && self.counted(field_ty) {
                let release = count_line(field_ty, "release", &target);
                self.line(&release);
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
        let field = format!("{code}.f{index}");
        if !owned {
            return Value::Code {
                code: field,
                owned: false,
            };
        }
        let result = self.owned(
            Value::Code {
                code: field,
                owned: false,
            },
            ty,
        );
        let result = match result {
            Value::Code { owned: true, .. } => result,
            Value::Code { code, .. } => self.store(ty, code, false),
            other => other,
        };
        self.release(&Value::Code { code, owned }, base.ty);
        result
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
            (Op::Equal, Type::STR) => format!("vt_str_eq({a}, {b})"),
            (Op::NotEqual, Type::STR) => format!("(!vt_str_eq({a}, {b}))"),
            (Op::Less, Type::STR) => format!("(vt_str_compare({a}, {b}) < 0)"),
            (Op::Greater, Type::STR) => format!("(vt_str_compare({a}, {b}) > 0)"),
            (Op::LessEqual, Type::STR) => format!("(vt_str_compare({a}, {b}) <= 0)"),
            (Op::GreaterEqual, Type::STR) => format!("(vt_str_compare({a}, {b}) >= 0)"),
            (Op::Equal, _) => format!("({a} == {b})"),
            (Op::NotEqual, _) => format!("({a} != {b})"),
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

fn int_literal(value: i64) -> String {
    if value == i64::MIN {
        "INT64_MIN".to_owned()
    } else {
        format!("INT64_C({value})")
    }
}
