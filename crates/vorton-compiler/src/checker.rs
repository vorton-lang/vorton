//! Type checking.
//!
//! The checker covers `Int`, `Float`, `Bool`, `Str` and `Unit` values,
//! tuples, non-generic structs, named functions with written signatures,
//! local bindings, assignment to `let mut` locals and their fields, `if`,
//! `while`, `loop`, `break`, `continue`, `return`, string interpolation, and
//! the `print`, `assert` and `panic` intrinsics. Every other construct reports
//! [`CheckDiagnosticKind::Unsupported`] instead of being treated as checked.

use std::collections::{BTreeMap, BTreeSet};

use crate::ast::{AssignmentOperator, BinaryOperator, Span, UnaryOperator};
use crate::project::{
    EntityId, EntityKind, LibraryId, ModuleRef, OriginRef, ResolvedBlock, ResolvedConstructEntry,
    ResolvedDeclarationKind, ResolvedExpr, ResolvedExprKind, ResolvedField, ResolvedFunction,
    ResolvedInterpolationPart, ResolvedPlace, ResolvedPlaceProjection, ResolvedProject,
    ResolvedReference, ResolvedStatement, ResolvedStatementKind, ResolvedType, ResolvedTypeKind,
    SourceRef,
};
pub(crate) use crate::types::{Field, StructInfo, Type, TypeKind, Types};

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
    /// An assignment target is not rooted in a `let mut` local or `mut` parameter.
    NotAssignable,
    /// `break` or `continue` appears outside a loop.
    OutsideLoop,
    /// A numeric literal cannot be represented by its type.
    LiteralOutOfRange,
    /// The entry library root has no `fn main()` without parameters that returns `Unit`.
    MissingMain,
    /// A field or tuple element that the type does not have.
    UnknownField,
    /// A struct construction leaves a field without a value.
    MissingField,
}

/// A checked program ready for code generation.
pub(crate) struct Program {
    pub(crate) types: Types,
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
        place: Place,
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

/// A local and a path of field or tuple-element indices inside it.
pub(crate) struct Place {
    pub(crate) local: usize,
    pub(crate) path: Vec<usize>,
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
    Tuple(Vec<Expr>),
    /// A struct value. `base` is evaluated first, then `fields` in source
    /// order; each field is named by its declaration index. Fields missing
    /// from `fields` come from `base`.
    Construct {
        base: Option<Box<Expr>>,
        fields: Vec<(usize, Expr)>,
    },
    /// A struct field or tuple element, by declaration or position index.
    Field {
        base: Box<Expr>,
        index: usize,
    },
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

/// Declared nominal types, by identity.
struct Nominals {
    structs: BTreeMap<EntityId, Type>,
}

pub(crate) fn check(project: &ResolvedProject) -> Result<Program, CheckDiagnostic> {
    let mut functions_found = Vec::new();
    let mut structs_found = Vec::new();
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
            let identity = || {
                declaration
                    .identity
                    .clone()
                    .expect("every resolved declaration of this kind has an identity")
            };
            match &declaration.kind {
                ResolvedDeclarationKind::Function(function) => {
                    functions_found.push((identity(), function, declaration.origin.clone()));
                }
                ResolvedDeclarationKind::Struct {
                    type_parameters,
                    fields,
                } => {
                    if !type_parameters.is_empty() {
                        return Err(unsupported(
                            Some(declaration.origin.clone()),
                            "generic structs",
                        ));
                    }
                    structs_found.push((identity(), fields, declaration.origin.clone()));
                }
                ResolvedDeclarationKind::Module(_) => {}
                _ => {
                    return Err(unsupported(
                        Some(declaration.origin.clone()),
                        "declarations of this kind",
                    ));
                }
            }
        }
    }

    let mut types = Types::new();
    let nominals = declare_structs(&mut types, &structs_found)?;

    let mut signatures = BTreeMap::new();
    for (index, (identity, function, origin)) in functions_found.iter().enumerate() {
        let signature = check_signature(index, function, origin, &nominals, &mut types)?;
        signatures.insert(identity.clone(), signature);
    }

    let mut functions = Vec::new();
    for (identity, function, origin) in &functions_found {
        let signature = &signatures[identity];
        let mut checker = BodyChecker {
            types: &mut types,
            nominals: &nominals,
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
            parameters.push(checker.declare(
                &parameter.binding.identity,
                *ty,
                parameter.mutable.is_some(),
            ));
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
    let main = functions_found
        .iter()
        .position(|(identity, _, _)| {
            identity.module == ModuleRef::root(project.entry)
                && identity.kind == EntityKind::Function
                && identity.name == "main"
        })
        .filter(|&index| {
            let (identity, _, _) = &functions_found[index];
            let signature = &signatures[identity];
            signature.parameters.is_empty() && signature.result == Type::UNIT
        })
        .ok_or_else(|| CheckDiagnostic {
            kind: CheckDiagnosticKind::MissingMain,
            primary: None,
            message: "the entry library needs `fn main()` without parameters that returns `Unit`"
                .to_owned(),
        })?;

    Ok(Program {
        types,
        functions,
        main,
    })
}

/// Registers every struct first, so field types may refer to structs declared
/// later, then rejects structs that contain themselves by value.
fn declare_structs(
    types: &mut Types,
    structs: &[(EntityId, &Vec<ResolvedField>, OriginRef)],
) -> Result<Nominals, CheckDiagnostic> {
    let mut nominals = Nominals {
        structs: BTreeMap::new(),
    };
    for (identity, _, _) in structs {
        let index = types.structs.len();
        types.structs.push(StructInfo {
            name: identity.name.clone(),
            fields: Vec::new(),
        });
        let ty = types.intern(TypeKind::Struct(index));
        nominals.structs.insert(identity.clone(), ty);
    }
    for (index, (_, fields, origin)) in structs.iter().enumerate() {
        let mut resolved = Vec::new();
        for field in fields.iter() {
            let ty = value_type(&field.ty, origin, &nominals, types)?;
            if ty == Type::NEVER {
                return Err(unsupported(
                    Some(at(origin, field.ty.span)),
                    "`Never` fields",
                ));
            }
            resolved.push(Field {
                name: field.identity.name.clone(),
                ty,
            });
        }
        types.structs[index].fields = resolved;
    }
    for (index, (_, _, origin)) in structs.iter().enumerate() {
        let start = types.intern(TypeKind::Struct(index));
        if contains_by_value(types, start, start, &mut BTreeSet::new()) {
            return Err(unsupported(Some(origin.clone()), "recursive structs"));
        }
    }
    Ok(nominals)
}

fn contains_by_value(types: &Types, ty: Type, target: Type, seen: &mut BTreeSet<Type>) -> bool {
    types.components(ty).into_iter().any(|component| {
        component == target
            || (seen.insert(component) && contains_by_value(types, component, target, seen))
    })
}

fn check_signature(
    index: usize,
    function: &ResolvedFunction,
    origin: &OriginRef,
    nominals: &Nominals,
    types: &mut Types,
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
        if parameter.borrow.is_some() {
            return Err(unsupported(at, "borrowed parameters"));
        }
        let Some(annotation) = &parameter.annotation else {
            return Err(unsupported(at, "receivers outside methods"));
        };
        parameters.push(value_type(annotation, origin, nominals, types)?);
    }
    if function.return_borrow.is_some() {
        return Err(unsupported(Some(origin.clone()), "borrowed return values"));
    }
    let result = match &function.return_type {
        Some(ty) => value_type(ty, origin, nominals, types)?,
        None => Type::UNIT,
    };
    Ok(Signature {
        index,
        parameters,
        result,
    })
}

fn value_type(
    ty: &ResolvedType,
    origin: &OriginRef,
    nominals: &Nominals,
    types: &mut Types,
) -> Result<Type, CheckDiagnostic> {
    match &ty.kind {
        ResolvedTypeKind::Grouped(inner) => value_type(inner, origin, nominals, types),
        ResolvedTypeKind::Tuple(elements) => {
            let elements = elements
                .iter()
                .map(|element| value_type(element, origin, nominals, types))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(types.intern(TypeKind::Tuple(elements)))
        }
        ResolvedTypeKind::Named(named) if named.arguments.is_empty() => {
            if let ResolvedReference::Exact { target, .. } = &named.reference {
                if target.kind == EntityKind::LanguageType {
                    let ty = match target.name.as_str() {
                        "Int" => Some(Type::INT),
                        "Float" => Some(Type::FLOAT),
                        "Bool" => Some(Type::BOOL),
                        "Str" => Some(Type::STR),
                        "Unit" => Some(Type::UNIT),
                        "Never" => Some(Type::NEVER),
                        _ => None,
                    };
                    if let Some(ty) = ty {
                        return Ok(ty);
                    }
                }
                if let Some(&ty) = nominals.structs.get(target) {
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
    types: &'a mut Types,
    nominals: &'a Nominals,
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
            format!(
                "expected `{}`, found `{}`",
                self.types.name(expected),
                self.types.name(actual)
            ),
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
        if actual == expected || actual == Type::NEVER {
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
                let discard = expected == Some(Type::UNIT);
                let tail = self.check_expr(tail, expected)?;
                let ty = if tail.ty == Type::NEVER || diverges {
                    Type::NEVER
                } else if discard {
                    Type::UNIT
                } else {
                    tail.ty
                };
                (Some(Box::new(tail)), ty)
            }
            None if diverges => (None, Type::NEVER),
            None => (None, Type::UNIT),
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
                annotation_borrow,
                annotation,
                value,
            } => {
                let [binding] = bindings.as_slice() else {
                    return Err(self.unsupported(span, "tuple destructuring"));
                };
                if annotation_borrow.is_some() {
                    return Err(self.unsupported(span, "borrowed bindings"));
                }
                let expected = match annotation {
                    Some(annotation) => {
                        let origin = OriginRef {
                            library: self.library,
                            source: self.source.clone(),
                            span,
                        };
                        Some(value_type(annotation, &origin, self.nominals, self.types)?)
                    }
                    None => None,
                };
                let value = self.check_expr(value, expected)?;
                if let Some(expected) = expected {
                    self.require(span, expected, value.ty)?;
                }
                let ty = expected.unwrap_or(value.ty);
                let diverges = value.ty == Type::NEVER;
                let local = self.declare(&binding.identity, ty, mutable.is_some());
                Ok((Statement::Let { local, value }, diverges))
            }
            ResolvedStatementKind::Assignment {
                target,
                operator: (operator_span, operator),
                value,
            } => {
                let (place, ty) = self.check_place(target)?;
                let value = self.check_expr(value, Some(ty))?;
                self.require(span, ty, value.ty)?;
                if *operator != AssignmentOperator::Assign && !matches!(ty, Type::INT | Type::FLOAT)
                {
                    return Err(self.mismatch(*operator_span, Type::INT, ty));
                }
                let diverges = value.ty == Type::NEVER;
                Ok((
                    Statement::Assign {
                        place,
                        operator: *operator,
                        value,
                    },
                    diverges,
                ))
            }
            ResolvedStatementKind::Expression(expression) => {
                // The value is discarded, so branches and blocks may end in any type.
                let expression = self.check_expr(expression, Some(Type::UNIT))?;
                let diverges = expression.ty == Type::NEVER;
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
                        self.require(span, self.result, Type::UNIT)?;
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
                let body = self.check_block(body, Some(Type::UNIT));
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
                let body = self.check_block(body, Some(Type::UNIT));
                let frame = self.loops.pop().expect("the loop frame was pushed");
                Ok((Statement::Loop(body?), !frame.breaks))
            }
            ResolvedStatementKind::IfLet { .. } => Err(self.unsupported(span, "`if let`")),
            ResolvedStatementKind::For { .. } => Err(self.unsupported(span, "`for` loops")),
        }
    }

    /// Checks an assignment target and returns it with its type.
    fn check_place(&mut self, target: &ResolvedPlace) -> Result<(Place, Type), CheckDiagnostic> {
        let local = match &target.root {
            ResolvedReference::Exact { target: entity, .. } => self.local_ids.get(entity).copied(),
            ResolvedReference::Selection { .. } => None,
        };
        let Some(local) = local.filter(|&local| self.mutable[local]) else {
            return Err(self.error(
                CheckDiagnosticKind::NotAssignable,
                target.span,
                "only a `let mut` variable, a `mut` parameter or a part of one can be assigned"
                    .to_owned(),
            ));
        };
        let mut ty = self.locals[local].ty;
        let mut path = Vec::new();
        for projection in &target.projections {
            let (index, field_ty) = match projection {
                ResolvedPlaceProjection::Field(selection) => {
                    self.named_field(ty, &selection.name, selection.origin.span)?
                }
                ResolvedPlaceProjection::TupleField { index, origin } => {
                    self.tuple_element(ty, index, origin.span)?
                }
                ResolvedPlaceProjection::Index(index) => {
                    return Err(self.unsupported(index.span, "assignment to elements"));
                }
            };
            path.push(index);
            ty = field_ty;
        }
        Ok((Place { local, path }, ty))
    }

    fn named_field(
        &self,
        ty: Type,
        name: &str,
        span: Span,
    ) -> Result<(usize, Type), CheckDiagnostic> {
        if let TypeKind::Struct(index) = self.types.kind(ty)
            && let Some((position, field)) = self.types.structs[*index]
                .fields
                .iter()
                .enumerate()
                .find(|(_, field)| field.name == name)
        {
            return Ok((position, field.ty));
        }
        Err(self.error(
            CheckDiagnosticKind::UnknownField,
            span,
            format!("`{}` has no field `{name}`", self.types.name(ty)),
        ))
    }

    fn tuple_element(
        &self,
        ty: Type,
        index: &str,
        span: Span,
    ) -> Result<(usize, Type), CheckDiagnostic> {
        if let TypeKind::Tuple(elements) = self.types.kind(ty)
            && let Ok(position) = index.parse::<usize>()
            && let Some(&element) = elements.get(position)
        {
            return Ok((position, element));
        }
        Err(self.error(
            CheckDiagnosticKind::UnknownField,
            span,
            format!("`{}` has no element `{index}`", self.types.name(ty)),
        ))
    }

    fn check_condition(&mut self, condition: &ResolvedExpr) -> Result<Expr, CheckDiagnostic> {
        let checked = self.check_expr(condition, Some(Type::BOOL))?;
        self.require(condition.span, Type::BOOL, checked.ty)?;
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
                (Type::INT, ExprKind::Int(self.integer(span, text)?))
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
                (Type::FLOAT, ExprKind::Float(value))
            }
            ResolvedExprKind::String(value) | ResolvedExprKind::RawString { value, .. } => {
                (Type::STR, ExprKind::Str(value.clone()))
            }
            ResolvedExprKind::Boolean(value) => (Type::BOOL, ExprKind::Bool(*value)),
            ResolvedExprKind::Unit => (Type::UNIT, ExprKind::Unit),
            ResolvedExprKind::InterpolatedString(parts) => {
                let mut checked = Vec::new();
                for part in parts {
                    match part {
                        ResolvedInterpolationPart::String { value, .. } => {
                            if !value.is_empty() {
                                checked.push(Expr {
                                    ty: Type::STR,
                                    kind: ExprKind::Str(value.clone()),
                                });
                            }
                        }
                        ResolvedInterpolationPart::Expression(part) => {
                            let part_span = part.span;
                            let part = self.check_expr(part, None)?;
                            if !is_printable(part.ty) {
                                return Err(self.error(
                                    CheckDiagnosticKind::TypeMismatch,
                                    part_span,
                                    format!(
                                        "`{}` cannot be interpolated",
                                        self.types.name(part.ty)
                                    ),
                                ));
                            }
                            checked.push(part);
                        }
                    }
                }
                (Type::STR, ExprKind::Interpolate(checked))
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
            ResolvedExprKind::Tuple(elements) => self.check_tuple(elements, expected)?,
            ResolvedExprKind::NamedConstruct { target, entries } => {
                self.check_construct(span, target, entries)?
            }
            ResolvedExprKind::Field { receiver, field } => {
                let base = self.check_expr(receiver, None)?;
                let (index, ty) = self.named_field(base.ty, &field.name, field.origin.span)?;
                (
                    ty,
                    ExprKind::Field {
                        base: Box::new(base),
                        index,
                    },
                )
            }
            ResolvedExprKind::TupleField {
                receiver,
                index,
                origin,
            } => {
                let base = self.check_expr(receiver, None)?;
                let (index, ty) = self.tuple_element(base.ty, index, origin.span)?;
                (
                    ty,
                    ExprKind::Field {
                        base: Box::new(base),
                        index,
                    },
                )
            }
            _ => return Err(self.unsupported(span, "these expressions")),
        };
        Ok(Expr { ty, kind })
    }

    fn check_tuple(
        &mut self,
        elements: &[ResolvedExpr],
        expected: Option<Type>,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let expected_elements = match expected.map(|ty| self.types.kind(ty)) {
            Some(TypeKind::Tuple(types)) if types.len() == elements.len() => Some(types.clone()),
            _ => None,
        };
        let mut checked = Vec::new();
        for (position, element) in elements.iter().enumerate() {
            let expected = expected_elements.as_ref().map(|types| types[position]);
            let value = self.check_expr(element, expected)?;
            if value.ty == Type::NEVER {
                return Err(self.unsupported(element.span, "diverging tuple elements"));
            }
            if let Some(expected) = expected {
                self.require(element.span, expected, value.ty)?;
            }
            checked.push(value);
        }
        let ty = self.types.intern(TypeKind::Tuple(
            checked.iter().map(|element| element.ty).collect(),
        ));
        Ok((ty, ExprKind::Tuple(checked)))
    }

    fn check_construct(
        &mut self,
        span: Span,
        target: &ResolvedReference,
        entries: &[ResolvedConstructEntry],
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let ResolvedReference::Exact { target, .. } = target else {
            return Err(self.unsupported(span, "this construction"));
        };
        let Some(&ty) = self.nominals.structs.get(target) else {
            return Err(self.unsupported(span, "constructions other than structs"));
        };
        let TypeKind::Struct(index) = *self.types.kind(ty) else {
            unreachable!("struct identities map to struct types")
        };
        let field_count = self.types.structs[index].fields.len();
        let mut base = None;
        let mut fields = Vec::new();
        let mut given = vec![false; field_count];
        for entry in entries {
            match entry {
                ResolvedConstructEntry::Spread(expression) => {
                    let value = self.check_expr(expression, Some(ty))?;
                    self.require(expression.span, ty, value.ty)?;
                    if value.ty == Type::NEVER {
                        return Err(self.unsupported(expression.span, "diverging bases"));
                    }
                    base = Some(Box::new(value));
                }
                ResolvedConstructEntry::Field {
                    member,
                    value,
                    shorthand,
                } => {
                    let (position, field_ty) =
                        self.named_field(ty, &member.name, member.origin.span)?;
                    if std::mem::replace(&mut given[position], true) {
                        return Err(self.error(
                            CheckDiagnosticKind::UnknownField,
                            member.origin.span,
                            format!("field `{}` is given twice", member.name),
                        ));
                    }
                    let shorthand_expression;
                    let expression = match (value, shorthand) {
                        (Some(value), _) => value.as_ref(),
                        (None, Some(reference)) => {
                            shorthand_expression = ResolvedExpr {
                                span: member.origin.span,
                                kind: ResolvedExprKind::Path(reference.as_ref().clone()),
                            };
                            &shorthand_expression
                        }
                        (None, None) => unreachable!("a field without a value is a shorthand"),
                    };
                    let checked = self.check_expr(expression, Some(field_ty))?;
                    self.require(expression.span, field_ty, checked.ty)?;
                    if checked.ty == Type::NEVER {
                        return Err(self.unsupported(expression.span, "diverging fields"));
                    }
                    fields.push((position, checked));
                }
            }
        }
        if base.is_none()
            && let Some(position) = given.iter().position(|given| !given)
        {
            return Err(self.error(
                CheckDiagnosticKind::MissingField,
                span,
                format!(
                    "field `{}` has no value",
                    self.types.structs[index].fields[position].name
                ),
            ));
        }
        Ok((ty, ExprKind::Construct { base, fields }))
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
            let then_branch = self.check_block(then_branch, Some(Type::UNIT))?;
            return Ok((
                Type::UNIT,
                ExprKind::If {
                    condition: Box::new(condition),
                    then_branch,
                    else_branch: None,
                },
            ));
        };
        let then_branch = self.check_block(then_branch, expected)?;
        let expected = expected.or(Some(then_branch.ty).filter(|ty| *ty != Type::NEVER));
        let else_span = else_branch.span;
        let else_branch = self.check_expr(else_branch, expected)?;
        let ty = match (then_branch.ty, else_branch.ty) {
            (Type::NEVER, other) | (other, Type::NEVER) => other,
            _ if expected == Some(Type::UNIT) => Type::UNIT,
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
            return Ok((Type::INT, ExprKind::Int(i64::MIN)));
        }
        let operand = self.check_expr(operand, None)?;
        let valid = match operator {
            UnaryOperator::Negate => matches!(operand.ty, Type::INT | Type::FLOAT),
            UnaryOperator::Not => operand.ty == Type::BOOL,
        };
        if !valid {
            return Err(self.error(
                CheckDiagnosticKind::TypeMismatch,
                span,
                format!(
                    "this operator does not apply to `{}`",
                    self.types.name(operand.ty)
                ),
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
                matches!(ty, Type::INT | Type::FLOAT).then_some(ty)
            }
            Op::Equal
            | Op::NotEqual
            | Op::Less
            | Op::Greater
            | Op::LessEqual
            | Op::GreaterEqual => is_printable(ty).then_some(Type::BOOL),
            Op::LogicAnd | Op::LogicOr => (ty == Type::BOOL).then_some(Type::BOOL),
            Op::RangeExclusive | Op::RangeInclusive => {
                return Err(self.unsupported(span, "ranges"));
            }
        };
        let Some(result) = result else {
            return Err(self.error(
                CheckDiagnosticKind::TypeMismatch,
                span,
                format!("this operator does not apply to `{}`", self.types.name(ty)),
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
        arguments: &[ResolvedExpr],
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let ResolvedExprKind::Path(ResolvedReference::Exact { target, .. }) = &callee.kind else {
            return Err(self.unsupported(callee.span, "calls of computed functions"));
        };
        let values = arguments.iter().collect::<Vec<_>>();
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
            "print" => (Intrinsic::Print, &[None], Type::UNIT),
            "assert" => (
                Intrinsic::Assert,
                &[Some(Type::BOOL), Some(Type::STR)],
                Type::UNIT,
            ),
            "panic" => (Intrinsic::Panic, &[Some(Type::STR)], Type::NEVER),
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
                None if !is_printable(argument.ty) => {
                    return Err(self.error(
                        CheckDiagnosticKind::TypeMismatch,
                        value.span,
                        format!("`{}` cannot be printed", self.types.name(argument.ty)),
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

/// Whether `ty` has a built-in text form and built-in comparisons.
fn is_printable(ty: Type) -> bool {
    matches!(ty, Type::INT | Type::FLOAT | Type::BOOL | Type::STR)
}

fn integer_literal(expression: &ResolvedExpr) -> Option<&str> {
    match &expression.kind {
        ResolvedExprKind::Integer(text) => Some(text),
        ResolvedExprKind::Parenthesized(inner) => integer_literal(inner),
        _ => None,
    }
}
