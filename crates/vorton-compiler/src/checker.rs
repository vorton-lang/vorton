//! Type checking for the Milestone 1 subset.
//!
//! The subset covers `Int`, `Float`, `Bool`, `Str` and `Unit` values, named
//! functions with written signatures, local bindings, assignment to `let mut`
//! locals, `if`, `while`, `loop`, `break`, `continue`, `return`, string
//! interpolation, and the `print`, `assert` and `panic` intrinsics. Every other
//! construct reports [`CheckDiagnosticKind::Unsupported`] instead of being
//! treated as checked.

use std::collections::BTreeMap;

use crate::ast::{AssignmentOperator, BinaryOperator, Span, UnaryOperator};
use crate::project::{
    EntityId, EntityKind, LibraryId, ModuleRef, OriginRef, ResolvedBlock, ResolvedCallArgument,
    ResolvedDeclarationKind, ResolvedExpr, ResolvedExprKind, ResolvedFunction,
    ResolvedInterpolationPart, ResolvedProject, ResolvedReference, ResolvedStatement,
    ResolvedStatementKind, ResolvedType, ResolvedTypeKind, SourceRef,
};

/// A Milestone 1 value type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Type {
    Int,
    Float,
    Bool,
    Str,
    Unit,
    Never,
}

impl Type {
    fn name(self) -> &'static str {
        match self {
            Self::Int => "Int",
            Self::Float => "Float",
            Self::Bool => "Bool",
            Self::Str => "Str",
            Self::Unit => "Unit",
            Self::Never => "Never",
        }
    }
}

/// One deterministic failure from checking a resolved project.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckDiagnostic {
    pub kind: CheckDiagnosticKind,
    pub primary: Option<OriginRef>,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckDiagnosticKind {
    /// Valid source outside the constructs the current checker supports.
    Unsupported,
    TypeMismatch,
    ArgumentCount,
    /// An assignment target is not a `let mut` local.
    NotAssignable,
    /// `break` or `continue` appears outside a loop.
    OutsideLoop,
    /// A numeric literal cannot be represented by its type.
    LiteralOutOfRange,
    /// The entry library root has no `fn main()` without parameters that returns `Unit`.
    MissingMain,
}

/// A checked program ready for code generation.
pub(crate) struct Program {
    pub(crate) functions: Vec<Function>,
    pub(crate) main: usize,
}

pub(crate) struct Function {
    pub(crate) name: String,
    pub(crate) parameters: Vec<usize>,
    pub(crate) locals: Vec<Local>,
    pub(crate) result: Type,
    pub(crate) body: Block,
}

pub(crate) struct Local {
    pub(crate) name: String,
    pub(crate) ty: Type,
}

pub(crate) struct Block {
    pub(crate) statements: Vec<Statement>,
    pub(crate) tail: Option<Box<Expr>>,
    pub(crate) ty: Type,
}

pub(crate) enum Statement {
    Let {
        local: usize,
        value: Expr,
    },
    Assign {
        local: usize,
        operator: AssignmentOperator,
        value: Expr,
    },
    Expr(Expr),
    Return(Option<Expr>),
    Break,
    Continue,
    While {
        condition: Expr,
        body: Block,
    },
    Loop(Block),
}

pub(crate) struct Expr {
    pub(crate) ty: Type,
    pub(crate) kind: ExprKind,
}

pub(crate) enum ExprKind {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(String),
    Unit,
    Local(usize),
    Call {
        function: usize,
        arguments: Vec<Expr>,
    },
    Intrinsic {
        intrinsic: Intrinsic,
        arguments: Vec<Expr>,
    },
    Unary {
        operator: UnaryOperator,
        operand: Box<Expr>,
    },
    Binary {
        operator: BinaryOperator,
        left: Box<Expr>,
        right: Box<Expr>,
    },
    If {
        condition: Box<Expr>,
        then_branch: Block,
        else_branch: Option<Box<Expr>>,
    },
    Block(Block),
    /// String interpolation; each part is `Int`, `Float`, `Bool` or `Str`.
    Interpolate(Vec<Expr>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Intrinsic {
    Print,
    Assert,
    Panic,
}

struct Signature {
    index: usize,
    parameters: Vec<Type>,
    result: Type,
}

pub(crate) fn check(project: &ResolvedProject) -> Result<Program, CheckDiagnostic> {
    let mut declarations = Vec::new();
    for (module, resolved) in &project.modules {
        let Some(body) = &resolved.body else {
            continue;
        };
        if module.source_library() == Some(project.core) {
            continue;
        }
        if body.requires.is_some() {
            return Err(unsupported(
                Some(body.origin.clone()),
                "module capability limits",
            ));
        }
        for declaration in &body.declarations {
            match &declaration.kind {
                ResolvedDeclarationKind::Function(function) => {
                    let identity = declaration
                        .identity
                        .clone()
                        .expect("every resolved function has an identity");
                    declarations.push((identity, function, declaration.origin.clone()));
                }
                ResolvedDeclarationKind::Module(_) => {}
                _ => {
                    return Err(unsupported(
                        Some(declaration.origin.clone()),
                        "declarations other than functions",
                    ));
                }
            }
        }
    }

    let mut signatures = BTreeMap::new();
    for (index, (identity, function, origin)) in declarations.iter().enumerate() {
        let signature = check_signature(index, function, origin)?;
        signatures.insert(identity.clone(), signature);
    }

    let mut functions = Vec::new();
    for (identity, function, origin) in &declarations {
        let signature = &signatures[identity];
        let mut checker = BodyChecker {
            signatures: &signatures,
            library: origin.library,
            source: origin.source.clone(),
            locals: Vec::new(),
            local_ids: BTreeMap::new(),
            mutable: Vec::new(),
            loops: Vec::new(),
            result: signature.result,
        };
        let mut parameters = Vec::new();
        for (parameter, ty) in function.parameters.iter().zip(&signature.parameters) {
            parameters.push(checker.declare(&parameter.binding.identity, *ty, false));
        }
        let body = checker.check_block(&function.body, Some(signature.result))?;
        functions.push(Function {
            name: identity.name.clone(),
            parameters,
            locals: checker.locals,
            result: signature.result,
            body,
        });
    }
    let main = declarations
        .iter()
        .position(|(identity, _, _)| {
            identity.module == ModuleRef::root(project.entry)
                && identity.kind == EntityKind::Function
                && identity.name == "main"
        })
        .filter(|&index| {
            let (identity, _, _) = &declarations[index];
            let signature = &signatures[identity];
            signature.parameters.is_empty() && signature.result == Type::Unit
        })
        .ok_or_else(|| CheckDiagnostic {
            kind: CheckDiagnosticKind::MissingMain,
            primary: None,
            message: "the entry library needs `fn main()` without parameters that returns `Unit`"
                .to_owned(),
        })?;

    Ok(Program { functions, main })
}

fn check_signature(
    index: usize,
    function: &ResolvedFunction,
    origin: &OriginRef,
) -> Result<Signature, CheckDiagnostic> {
    if !function.type_parameters.is_empty() || !function.effect_parameters.is_empty() {
        return Err(unsupported(Some(origin.clone()), "generic functions"));
    }
    if function.effects.is_some() {
        return Err(unsupported(Some(origin.clone()), "effect annotations"));
    }
    let mut parameters = Vec::new();
    for parameter in &function.parameters {
        let at = Some(parameter.binding.origin.clone());
        if parameter.mode.is_some() {
            return Err(unsupported(at, "`mut` and `move` parameters"));
        }
        let Some(annotation) = &parameter.annotation else {
            return Err(unsupported(at, "receivers outside methods"));
        };
        parameters.push(value_type(annotation, origin)?);
    }
    let result = match &function.return_type {
        Some(ty) => value_type(ty, origin)?,
        None => Type::Unit,
    };
    Ok(Signature {
        index,
        parameters,
        result,
    })
}

fn value_type(ty: &ResolvedType, origin: &OriginRef) -> Result<Type, CheckDiagnostic> {
    match &ty.kind {
        ResolvedTypeKind::Grouped(inner) => value_type(inner, origin),
        ResolvedTypeKind::Named(named) if named.arguments.is_empty() => {
            if let ResolvedReference::Exact { target, .. } = &named.reference
                && target.kind == EntityKind::LanguageType
            {
                let ty = match target.name.as_str() {
                    "Int" => Some(Type::Int),
                    "Float" => Some(Type::Float),
                    "Bool" => Some(Type::Bool),
                    "Str" => Some(Type::Str),
                    "Unit" => Some(Type::Unit),
                    "Never" => Some(Type::Never),
                    _ => None,
                };
                if let Some(ty) = ty {
                    return Ok(ty);
                }
            }
            Err(unsupported(Some(at(origin, ty.span)), "this type"))
        }
        _ => Err(unsupported(Some(at(origin, ty.span)), "this type")),
    }
}

fn at(origin: &OriginRef, span: Span) -> OriginRef {
    OriginRef {
        library: origin.library,
        source: origin.source.clone(),
        span,
    }
}

fn unsupported(primary: Option<OriginRef>, what: &str) -> CheckDiagnostic {
    CheckDiagnostic {
        kind: CheckDiagnosticKind::Unsupported,
        primary,
        message: format!("{what} are not supported yet"),
    }
}

struct LoopFrame {
    breaks: bool,
}

struct BodyChecker<'a> {
    signatures: &'a BTreeMap<EntityId, Signature>,
    library: LibraryId,
    source: SourceRef,
    locals: Vec<Local>,
    local_ids: BTreeMap<EntityId, usize>,
    mutable: Vec<bool>,
    loops: Vec<LoopFrame>,
    result: Type,
}

impl BodyChecker<'_> {
    fn origin(&self, span: Span) -> Option<OriginRef> {
        Some(OriginRef {
            library: self.library,
            source: self.source.clone(),
            span,
        })
    }

    fn error(&self, kind: CheckDiagnosticKind, span: Span, message: String) -> CheckDiagnostic {
        CheckDiagnostic {
            kind,
            primary: self.origin(span),
            message,
        }
    }

    fn unsupported(&self, span: Span, what: &str) -> CheckDiagnostic {
        unsupported(self.origin(span), what)
    }

    fn mismatch(&self, span: Span, expected: Type, actual: Type) -> CheckDiagnostic {
        self.error(
            CheckDiagnosticKind::TypeMismatch,
            span,
            format!("expected `{}`, found `{}`", expected.name(), actual.name()),
        )
    }

    fn declare(&mut self, identity: &EntityId, ty: Type, mutable: bool) -> usize {
        let index = self.locals.len();
        self.locals.push(Local {
            name: identity.name.clone(),
            ty,
        });
        self.mutable.push(mutable);
        self.local_ids.insert(identity.clone(), index);
        index
    }

    /// Checks that `actual` can stand where `expected` is required.
    fn require(&self, span: Span, expected: Type, actual: Type) -> Result<(), CheckDiagnostic> {
        if actual == expected || actual == Type::Never {
            Ok(())
        } else {
            Err(self.mismatch(span, expected, actual))
        }
    }

    fn check_block(
        &mut self,
        block: &ResolvedBlock,
        expected: Option<Type>,
    ) -> Result<Block, CheckDiagnostic> {
        let scope = self.local_ids.clone();
        let mut statements = Vec::new();
        let mut diverges = false;
        for statement in &block.statements {
            let (statement, statement_diverges) = self.check_statement(statement)?;
            diverges |= statement_diverges;
            statements.push(statement);
        }
        let (tail, ty) = match &block.tail {
            Some(tail) => {
                let discard = expected == Some(Type::Unit);
                let tail = self.check_expr(tail, expected)?;
                let ty = if tail.ty == Type::Never || diverges {
                    Type::Never
                } else if discard {
                    Type::Unit
                } else {
                    tail.ty
                };
                (Some(Box::new(tail)), ty)
            }
            None if diverges => (None, Type::Never),
            None => (None, Type::Unit),
        };
        if let Some(expected) = expected {
            let span = block.tail.as_ref().map_or(block.span, |tail| tail.span);
            self.require(span, expected, ty)?;
        }
        self.local_ids = scope;
        Ok(Block {
            statements,
            tail,
            ty,
        })
    }

    /// Returns the checked statement and whether control cannot continue after it.
    fn check_statement(
        &mut self,
        statement: &ResolvedStatement,
    ) -> Result<(Statement, bool), CheckDiagnostic> {
        let span = statement.span;
        match &statement.kind {
            ResolvedStatementKind::Let {
                bindings,
                mutable,
                annotation,
                value,
            } => {
                let [binding] = bindings.as_slice() else {
                    return Err(self.unsupported(span, "tuple destructuring"));
                };
                let expected = annotation
                    .as_ref()
                    .map(|annotation| {
                        value_type(
                            annotation,
                            &OriginRef {
                                library: self.library,
                                source: self.source.clone(),
                                span,
                            },
                        )
                    })
                    .transpose()?;
                let value = self.check_expr(value, expected)?;
                if let Some(expected) = expected {
                    self.require(span, expected, value.ty)?;
                }
                let ty = expected.unwrap_or(value.ty);
                let diverges = value.ty == Type::Never;
                let local = self.declare(&binding.identity, ty, mutable.is_some());
                Ok((Statement::Let { local, value }, diverges))
            }
            ResolvedStatementKind::Assignment {
                target,
                operator: (operator_span, operator),
                value,
            } => {
                if !target.projections.is_empty() {
                    return Err(self.unsupported(target.span, "assignment to fields and elements"));
                }
                let local = match &target.root {
                    ResolvedReference::Exact { target: entity, .. } => {
                        self.local_ids.get(entity).copied()
                    }
                    ResolvedReference::Selection { .. } => None,
                };
                let Some(local) = local.filter(|&local| self.mutable[local]) else {
                    return Err(self.error(
                        CheckDiagnosticKind::NotAssignable,
                        target.span,
                        "only a `let mut` variable can be assigned".to_owned(),
                    ));
                };
                let ty = self.locals[local].ty;
                let value = self.check_expr(value, Some(ty))?;
                self.require(span, ty, value.ty)?;
                if *operator != AssignmentOperator::Assign && !matches!(ty, Type::Int | Type::Float)
                {
                    return Err(self.mismatch(*operator_span, Type::Int, ty));
                }
                let diverges = value.ty == Type::Never;
                Ok((
                    Statement::Assign {
                        local,
                        operator: *operator,
                        value,
                    },
                    diverges,
                ))
            }
            ResolvedStatementKind::Expression(expression) => {
                // The value is discarded, so branches and blocks may end in any type.
                let expression = self.check_expr(expression, Some(Type::Unit))?;
                let diverges = expression.ty == Type::Never;
                Ok((Statement::Expr(expression), diverges))
            }
            ResolvedStatementKind::Return(value) => {
                let value = match value {
                    Some(value) => {
                        let checked = self.check_expr(value, Some(self.result))?;
                        self.require(value.span, self.result, checked.ty)?;
                        Some(checked)
                    }
                    None => {
                        self.require(span, self.result, Type::Unit)?;
                        None
                    }
                };
                Ok((Statement::Return(value), true))
            }
            ResolvedStatementKind::Break | ResolvedStatementKind::Continue => {
                let is_break = matches!(statement.kind, ResolvedStatementKind::Break);
                let Some(frame) = self.loops.last_mut() else {
                    return Err(self.error(
                        CheckDiagnosticKind::OutsideLoop,
                        span,
                        "`break` and `continue` must be inside a loop".to_owned(),
                    ));
                };
                if is_break {
                    frame.breaks = true;
                    Ok((Statement::Break, true))
                } else {
                    Ok((Statement::Continue, true))
                }
            }
            ResolvedStatementKind::While { condition, body } => {
                let condition = self.check_condition(condition)?;
                self.loops.push(LoopFrame { breaks: false });
                let body = self.check_block(body, Some(Type::Unit));
                self.loops.pop();
                Ok((
                    Statement::While {
                        condition,
                        body: body?,
                    },
                    false,
                ))
            }
            ResolvedStatementKind::Loop(body) => {
                self.loops.push(LoopFrame { breaks: false });
                let body = self.check_block(body, Some(Type::Unit));
                let frame = self.loops.pop().expect("the loop frame was pushed");
                Ok((Statement::Loop(body?), !frame.breaks))
            }
            ResolvedStatementKind::Alias { .. } => Err(self.unsupported(span, "in-place aliases")),
            ResolvedStatementKind::IfLet { .. } => Err(self.unsupported(span, "`if let`")),
            ResolvedStatementKind::For { .. } => Err(self.unsupported(span, "`for` loops")),
        }
    }

    fn check_condition(&mut self, condition: &ResolvedExpr) -> Result<Expr, CheckDiagnostic> {
        let checked = self.check_expr(condition, Some(Type::Bool))?;
        self.require(condition.span, Type::Bool, checked.ty)?;
        Ok(checked)
    }

    fn check_expr(
        &mut self,
        expression: &ResolvedExpr,
        expected: Option<Type>,
    ) -> Result<Expr, CheckDiagnostic> {
        let span = expression.span;
        let (ty, kind) = match &expression.kind {
            ResolvedExprKind::Integer(text) => {
                (Type::Int, ExprKind::Int(self.integer(span, text)?))
            }
            ResolvedExprKind::Float(text) => {
                let value = text
                    .parse::<f64>()
                    .expect("the lexer admits only decimal floats");
                if !value.is_finite() {
                    return Err(self.error(
                        CheckDiagnosticKind::LiteralOutOfRange,
                        span,
                        "this float literal is too large".to_owned(),
                    ));
                }
                (Type::Float, ExprKind::Float(value))
            }
            ResolvedExprKind::String(value) | ResolvedExprKind::RawString { value, .. } => {
                (Type::Str, ExprKind::Str(value.clone()))
            }
            ResolvedExprKind::Boolean(value) => (Type::Bool, ExprKind::Bool(*value)),
            ResolvedExprKind::Unit => (Type::Unit, ExprKind::Unit),
            ResolvedExprKind::InterpolatedString(parts) => {
                let mut checked = Vec::new();
                for part in parts {
                    match part {
                        ResolvedInterpolationPart::String { value, .. } => {
                            if !value.is_empty() {
                                checked.push(Expr {
                                    ty: Type::Str,
                                    kind: ExprKind::Str(value.clone()),
                                });
                            }
                        }
                        ResolvedInterpolationPart::Expression(part) => {
                            let part_span = part.span;
                            let part = self.check_expr(part, None)?;
                            if !matches!(part.ty, Type::Int | Type::Float | Type::Bool | Type::Str)
                            {
                                return Err(self.error(
                                    CheckDiagnosticKind::TypeMismatch,
                                    part_span,
                                    format!("`{}` cannot be interpolated", part.ty.name()),
                                ));
                            }
                            checked.push(part);
                        }
                    }
                }
                (Type::Str, ExprKind::Interpolate(checked))
            }
            ResolvedExprKind::Path(reference) => {
                let local = match reference {
                    ResolvedReference::Exact { target, .. } => self.local_ids.get(target).copied(),
                    ResolvedReference::Selection { .. } => None,
                };
                let Some(local) = local else {
                    return Err(self.unsupported(span, "values other than local variables"));
                };
                (self.locals[local].ty, ExprKind::Local(local))
            }
            ResolvedExprKind::Parenthesized(inner) => {
                if let ResolvedExprKind::Integer(_) = inner.kind {
                    // Keep `-(9223372036854775808)` a literal of the minimum `Int`.
                    return self.check_expr(inner, expected);
                }
                let inner = self.check_expr(inner, expected)?;
                (inner.ty, inner.kind)
            }
            ResolvedExprKind::Block(block) => {
                let block = self.check_block(block, expected)?;
                (block.ty, ExprKind::Block(block))
            }
            ResolvedExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => self.check_if(condition, then_branch, else_branch.as_deref(), expected)?,
            ResolvedExprKind::Unary { operator, operand } => {
                self.check_unary(*operator, operand)?
            }
            ResolvedExprKind::Binary {
                left,
                operator,
                right,
            } => self.check_binary(*operator, left, right)?,
            ResolvedExprKind::Call { callee, arguments } => {
                self.check_call(span, callee, arguments)?
            }
            _ => return Err(self.unsupported(span, "these expressions")),
        };
        Ok(Expr { ty, kind })
    }

    fn integer(&self, span: Span, text: &str) -> Result<i64, CheckDiagnostic> {
        text.parse::<i64>().map_err(|_| {
            self.error(
                CheckDiagnosticKind::LiteralOutOfRange,
                span,
                "this integer literal is larger than the largest `Int`".to_owned(),
            )
        })
    }

    fn check_if(
        &mut self,
        condition: &ResolvedExpr,
        then_branch: &ResolvedBlock,
        else_branch: Option<&ResolvedExpr>,
        expected: Option<Type>,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let condition = self.check_condition(condition)?;
        let Some(else_branch) = else_branch else {
            let then_branch = self.check_block(then_branch, Some(Type::Unit))?;
            return Ok((
                Type::Unit,
                ExprKind::If {
                    condition: Box::new(condition),
                    then_branch,
                    else_branch: None,
                },
            ));
        };
        let then_branch = self.check_block(then_branch, expected)?;
        let expected = expected.or(Some(then_branch.ty).filter(|ty| *ty != Type::Never));
        let else_span = else_branch.span;
        let else_branch = self.check_expr(else_branch, expected)?;
        let ty = match (then_branch.ty, else_branch.ty) {
            (Type::Never, other) | (other, Type::Never) => other,
            _ if expected == Some(Type::Unit) => Type::Unit,
            (then_ty, else_ty) => {
                self.require(else_span, then_ty, else_ty)?;
                then_ty
            }
        };
        Ok((
            ty,
            ExprKind::If {
                condition: Box::new(condition),
                then_branch,
                else_branch: Some(Box::new(else_branch)),
            },
        ))
    }

    fn check_unary(
        &mut self,
        (span, operator): (Span, UnaryOperator),
        operand: &ResolvedExpr,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        if operator == UnaryOperator::Negate
            && let Some(text) = integer_literal(operand)
            && text == "9223372036854775808"
        {
            return Ok((Type::Int, ExprKind::Int(i64::MIN)));
        }
        let operand = self.check_expr(operand, None)?;
        let valid = match operator {
            UnaryOperator::Negate => matches!(operand.ty, Type::Int | Type::Float),
            UnaryOperator::Not => operand.ty == Type::Bool,
        };
        if !valid {
            return Err(self.error(
                CheckDiagnosticKind::TypeMismatch,
                span,
                format!("this operator does not apply to `{}`", operand.ty.name()),
            ));
        }
        Ok((
            operand.ty,
            ExprKind::Unary {
                operator,
                operand: Box::new(operand),
            },
        ))
    }

    fn check_binary(
        &mut self,
        (span, operator): (Span, BinaryOperator),
        left: &ResolvedExpr,
        right: &ResolvedExpr,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        use BinaryOperator as Op;
        let left = self.check_expr(left, None)?;
        let right_span = right.span;
        let right = self.check_expr(right, Some(left.ty))?;
        if left.ty != right.ty {
            return Err(self.mismatch(right_span, left.ty, right.ty));
        }
        let ty = left.ty;
        let result = match operator {
            Op::Add | Op::Subtract | Op::Multiply | Op::Divide | Op::Remainder => {
                matches!(ty, Type::Int | Type::Float).then_some(ty)
            }
            Op::Equal
            | Op::NotEqual
            | Op::Less
            | Op::Greater
            | Op::LessEqual
            | Op::GreaterEqual => {
                matches!(ty, Type::Int | Type::Float | Type::Bool | Type::Str).then_some(Type::Bool)
            }
            Op::LogicAnd | Op::LogicOr => (ty == Type::Bool).then_some(Type::Bool),
            Op::RangeExclusive | Op::RangeInclusive => {
                return Err(self.unsupported(span, "ranges"));
            }
        };
        let Some(result) = result else {
            return Err(self.error(
                CheckDiagnosticKind::TypeMismatch,
                span,
                format!("this operator does not apply to `{}`", ty.name()),
            ));
        };
        Ok((
            result,
            ExprKind::Binary {
                operator,
                left: Box::new(left),
                right: Box::new(right),
            },
        ))
    }

    fn check_call(
        &mut self,
        span: Span,
        callee: &ResolvedExpr,
        arguments: &[ResolvedCallArgument],
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let ResolvedExprKind::Path(ResolvedReference::Exact { target, .. }) = &callee.kind else {
            return Err(self.unsupported(callee.span, "calls of computed functions"));
        };
        let mut values = Vec::new();
        for argument in arguments {
            match argument {
                ResolvedCallArgument::Expression(expression) => values.push(expression),
                ResolvedCallArgument::Mut { span, .. }
                | ResolvedCallArgument::Move { span, .. } => {
                    return Err(self.unsupported(*span, "`mut` and `move` arguments"));
                }
            }
        }
        if target.kind == EntityKind::LanguageFunction {
            return self.check_intrinsic(span, &target.name, &values);
        }
        let Some(signature) = self.signatures.get(target) else {
            return Err(self.unsupported(callee.span, "calls of this kind"));
        };
        if values.len() != signature.parameters.len() {
            return Err(self.error(
                CheckDiagnosticKind::ArgumentCount,
                span,
                format!(
                    "expected {} arguments, found {}",
                    signature.parameters.len(),
                    values.len()
                ),
            ));
        }
        let (index, parameters, result) = (
            signature.index,
            signature.parameters.clone(),
            signature.result,
        );
        let mut checked = Vec::new();
        for (value, ty) in values.into_iter().zip(parameters) {
            let argument = self.check_expr(value, Some(ty))?;
            self.require(value.span, ty, argument.ty)?;
            checked.push(argument);
        }
        Ok((
            result,
            ExprKind::Call {
                function: index,
                arguments: checked,
            },
        ))
    }

    fn check_intrinsic(
        &mut self,
        span: Span,
        name: &str,
        values: &[&ResolvedExpr],
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let (intrinsic, parameters, result): (Intrinsic, &[Option<Type>], Type) = match name {
            "print" => (Intrinsic::Print, &[None], Type::Unit),
            "assert" => (
                Intrinsic::Assert,
                &[Some(Type::Bool), Some(Type::Str)],
                Type::Unit,
            ),
            "panic" => (Intrinsic::Panic, &[Some(Type::Str)], Type::Never),
            _ => return Err(self.unsupported(span, "this intrinsic")),
        };
        if values.len() != parameters.len() {
            return Err(self.error(
                CheckDiagnosticKind::ArgumentCount,
                span,
                format!(
                    "expected {} arguments, found {}",
                    parameters.len(),
                    values.len()
                ),
            ));
        }
        let mut arguments = Vec::new();
        for (value, expected) in values.iter().zip(parameters) {
            let argument = self.check_expr(value, *expected)?;
            match expected {
                Some(expected) => self.require(value.span, *expected, argument.ty)?,
                None if !matches!(
                    argument.ty,
                    Type::Int | Type::Float | Type::Bool | Type::Str
                ) =>
                {
                    return Err(self.error(
                        CheckDiagnosticKind::TypeMismatch,
                        value.span,
                        format!("`{}` cannot be printed", argument.ty.name()),
                    ));
                }
                None => {}
            }
            arguments.push(argument);
        }
        Ok((
            result,
            ExprKind::Intrinsic {
                intrinsic,
                arguments,
            },
        ))
    }
}

fn integer_literal(expression: &ResolvedExpr) -> Option<&str> {
    match &expression.kind {
        ResolvedExprKind::Integer(text) => Some(text),
        ResolvedExprKind::Parenthesized(inner) => integer_literal(inner),
        _ => None,
    }
}
