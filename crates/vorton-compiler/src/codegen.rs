//! C11 code generation for checked Milestone 1 programs.
//!
//! Expressions are flattened into temporaries so evaluation order is explicit.
//! `Str` values are reference counted: locals and temporaries own one count,
//! parameters and borrowed operands own none, and every owned value is released
//! when its scope ends or right after its last borrowing use.

use std::fmt::Write as _;

use crate::ast::{AssignmentOperator, BinaryOperator, UnaryOperator};
use crate::checker::{Block, Expr, ExprKind, Function, Intrinsic, Program, Statement, Type};

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
    output.push_str(&literals.declarations);
    for (index, function) in program.functions.iter().enumerate() {
        writeln!(output, "{};", prototype(index, function)).unwrap();
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

fn function_name(index: usize, function: &Function) -> String {
    format!("vt_f{index}_{}", function.name)
}

fn prototype(index: usize, function: &Function) -> String {
    let parameters = function
        .parameters
        .iter()
        .map(|&local| {
            let local_info = &function.locals[local];
            format!(
                "{} {}",
                c_type(local_info.ty),
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
        c_type(function.result),
        function_name(index, function)
    )
}

fn c_type(ty: Type) -> &'static str {
    match ty {
        Type::Int => "int64_t",
        Type::Float => "double",
        Type::Bool => "bool",
        Type::Str => "vt_str *",
        Type::Unit | Type::Never => "void",
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

/// A lowered operand. `owned` operands hold one `Str` count that the consumer
/// must either store or release.
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
    function: &'a Function,
    literals: &'a mut Literals,
    declarations: String,
    body: String,
    indent: usize,
    temporaries: usize,
    /// `Str` locals that currently own a count, per open scope.
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
        let mut emitter = FunctionEmitter {
            program,
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
            if !function.parameters.contains(&local) && !matches!(info.ty, Type::Unit | Type::Never)
            {
                writeln!(
                    emitter.declarations,
                    "    {} {} = {};",
                    c_type(info.ty),
                    local_name(local, &info.name),
                    zero(info.ty)
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
            prototype(index, function),
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
            c_type(ty),
            zero(ty)
        )
        .unwrap();
        name
    }

    /// Makes `value` an owned operand, retaining a borrowed `Str`.
    fn owned(&mut self, value: Value, ty: Type) -> Value {
        match value {
            Value::Code { code, owned: false } if ty == Type::Str => {
                let temporary = self.temporary(Type::Str);
                self.line(&format!("{temporary} = {code};"));
                self.line(&format!("vt_str_retain({temporary});"));
                Value::Code {
                    code: temporary,
                    owned: true,
                }
            }
            value => value,
        }
    }

    /// Releases `value` after a borrowing use if it owns a count.
    fn release(&mut self, value: &Value) {
        if let Value::Code { code, owned: true } = value {
            self.line(&format!("vt_str_release({code});"));
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
            let name = local_name(local, &self.function.locals[local].name);
            self.line(&format!("vt_str_release({name});"));
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
                if block.ty == Type::Unit {
                    self.release(&value);
                    Value::Unit
                } else if matches!(value, Value::Never) || block.ty == Type::Never {
                    Value::Never
                } else {
                    self.owned(value, block.ty)
                }
            }
            None if block.ty == Type::Never => Value::Never,
            None => Value::Unit,
        };
        if !matches!(value, Value::Never) {
            let depth = self.scopes.len() - 1;
            self.release_scopes_from(depth);
        }
        self.scopes.pop();
        value
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
                if ty == Type::Str {
                    self.scopes
                        .last_mut()
                        .expect("a scope is open")
                        .push(*local);
                }
                false
            }
            Statement::Assign {
                local,
                operator,
                value,
            } => {
                let ty = self.function.locals[*local].ty;
                let value = self.expr(value);
                if matches!(value, Value::Never) {
                    return true;
                }
                if matches!(value, Value::Unit) {
                    return false;
                }
                let name = local_name(*local, &self.function.locals[*local].name);
                let code = value.code().to_owned();
                match (operator, ty) {
                    (AssignmentOperator::Assign, Type::Str) => {
                        let value = self.owned(value, ty);
                        self.line(&format!("vt_str_release({name});"));
                        self.line(&format!("{name} = {};", value.code()));
                    }
                    (AssignmentOperator::Assign, _) => self.line(&format!("{name} = {code};")),
                    (operator, Type::Int) => {
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
                self.release(&value);
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
                body.ty == Type::Never && !self.loop_breaks(body)
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
                if matches!(info.ty, Type::Unit | Type::Never) {
                    Value::Unit
                } else {
                    Value::Code {
                        code: local_name(*local, &info.name),
                        owned: false,
                    }
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
                    (UnaryOperator::Negate, Type::Int) => format!("vt_int_neg({})", operand.code()),
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
            values.push(value);
        }
        let name = function_name(function, &self.program.functions[function]);
        let code = format!(
            "{name}({})",
            values
                .iter()
                .filter(|value| !matches!(value, Value::Unit))
                .map(Value::code)
                .collect::<Vec<_>>()
                .join(", ")
        );
        let result = match ty {
            Type::Unit | Type::Never => {
                self.line(&format!("{code};"));
                if ty == Type::Never {
                    Value::Never
                } else {
                    Value::Unit
                }
            }
            _ => self.store(ty, code, ty == Type::Str),
        };
        for value in &values {
            self.release(value);
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
                self.release(&text);
                self.release(&values[0]);
                Value::Unit
            }
            Intrinsic::Assert => {
                self.line(&format!(
                    "if (!{}) vt_panic_assert({});",
                    values[0].code(),
                    values[1].code()
                ));
                self.release(&values[1]);
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
            Type::Str => Value::Code {
                code: value.code().to_owned(),
                owned: false,
            },
            Type::Int => self.store(Type::Str, format!("vt_int_to_str({})", value.code()), true),
            Type::Float => self.store(
                Type::Str,
                format!("vt_float_to_str({})", value.code()),
                true,
            ),
            Type::Bool => Value::Code {
                code: format!("vt_bool_to_str({})", value.code()),
                owned: false,
            },
            Type::Unit | Type::Never => unreachable!("the checker admits only printable values"),
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
            Type::Str,
            format!(
                "vt_str_join({}, (vt_str *[]){{{list}}})",
                texts.len().max(1)
            ),
            true,
        );
        for text in &texts {
            self.release(text);
        }
        for (value, _) in &values {
            self.release(value);
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
            let result = self.store(Type::Bool, left.code().to_owned(), false);
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
            self.release(&left);
            return Value::Never;
        }
        let (a, b) = (left.code(), right.code());
        let code = match (operator, operand_ty) {
            (Op::Add, Type::Int) => format!("vt_int_add({a}, {b})"),
            (Op::Subtract, Type::Int) => format!("vt_int_sub({a}, {b})"),
            (Op::Multiply, Type::Int) => format!("vt_int_mul({a}, {b})"),
            (Op::Divide, Type::Int) => format!("vt_int_div({a}, {b})"),
            (Op::Remainder, Type::Int) => format!("vt_int_rem({a}, {b})"),
            (Op::Add, _) => format!("({a} + {b})"),
            (Op::Subtract, _) => format!("({a} - {b})"),
            (Op::Multiply, _) => format!("({a} * {b})"),
            (Op::Divide, _) => format!("({a} / {b})"),
            (Op::Remainder, _) => format!("fmod({a}, {b})"),
            (Op::Equal, Type::Str) => format!("vt_str_eq({a}, {b})"),
            (Op::NotEqual, Type::Str) => format!("(!vt_str_eq({a}, {b}))"),
            (Op::Less, Type::Str) => format!("(vt_str_compare({a}, {b}) < 0)"),
            (Op::Greater, Type::Str) => format!("(vt_str_compare({a}, {b}) > 0)"),
            (Op::LessEqual, Type::Str) => format!("(vt_str_compare({a}, {b}) <= 0)"),
            (Op::GreaterEqual, Type::Str) => format!("(vt_str_compare({a}, {b}) >= 0)"),
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
        self.release(&left);
        self.release(&right);
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
        let result = (!matches!(ty, Type::Unit | Type::Never)).then(|| self.temporary(ty));
        self.line(&format!("if ({}) {{", condition.code()));
        self.indent += 1;
        let value = self.block(then_branch);
        self.assign_branch(result.as_deref(), value, ty);
        self.indent -= 1;
        if let Some(else_branch) = else_branch {
            self.line("} else {");
            self.indent += 1;
            let value = self.expr(else_branch);
            self.assign_branch(result.as_deref(), value, ty);
            self.indent -= 1;
        }
        self.line("}");
        match result {
            Some(code) => Value::Code {
                code,
                owned: ty == Type::Str,
            },
            None if ty == Type::Never => Value::Never,
            None => Value::Unit,
        }
    }

    fn assign_branch(&mut self, result: Option<&str>, value: Value, ty: Type) {
        match (result, value) {
            (Some(result), value @ Value::Code { .. }) => {
                let value = self.owned(value, ty);
                self.line(&format!("{result} = {};", value.code()));
            }
            (None, value @ Value::Code { .. }) => self.release(&value),
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

fn zero(ty: Type) -> &'static str {
    match ty {
        Type::Int => "0",
        Type::Float => "0.0",
        Type::Bool => "false",
        Type::Str => "NULL",
        Type::Unit | Type::Never => unreachable!("unit values have no storage"),
    }
}
