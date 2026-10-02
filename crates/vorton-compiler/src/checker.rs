//! Type checking.
//!
//! The checker covers `Int`, `Float`, `Bool`, `Str` and `Unit` values,
//! tuples, structs and enums (generic ones are instantiated at concrete type
//! arguments), `match`, `if let` and tuple destructuring with exhaustiveness,
//! named functions with written signatures, local bindings, assignment to
//! `let mut` locals and their fields, `if`, `while`, `loop`, `break`,
//! `continue`, `return`, string interpolation, and the `print`, `assert` and
//! `panic` intrinsics. Every other construct reports
//! [`CheckDiagnosticKind::Unsupported`] instead of being treated as checked.

use std::collections::{BTreeMap, BTreeSet};

use crate::ast::{AssignmentOperator, BinaryOperator, Span, UnaryOperator};
use crate::exhaustive;
use crate::project::{
    EntityId, EntityKind, LibraryId, ModuleRef, OriginRef, ResolvedBlock, ResolvedConstructEntry,
    ResolvedDeclarationKind, ResolvedExpr, ResolvedExprKind, ResolvedField, ResolvedFunction,
    ResolvedInterpolationPart, ResolvedMatchArm, ResolvedPattern, ResolvedPatternFields,
    ResolvedPatternKind, ResolvedPlace, ResolvedPlaceProjection, ResolvedProject,
    ResolvedReference, ResolvedStatement, ResolvedStatementKind, ResolvedType,
    ResolvedTypeArgument, ResolvedTypeKind, ResolvedVariant, ResolvedVariantFields, SourceRef,
};
pub(crate) use crate::types::{Field, NominalInfo, Type, TypeKind, Types, Variant};

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
    /// A construction leaves a field without a value.
    MissingField,
    /// The type arguments of a generic construction cannot be determined.
    CannotInfer,
    /// A `match`, `if let` alternative or destructuring misses possible values.
    NonExhaustive,
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
    /// An irrefutable destructuring `let`.
    LetPattern {
        pattern: Pattern,
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

/// A local and a path of struct-field or tuple-element indices inside it.
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
    /// A struct (variant 0) or enum variant. `base` is evaluated first, then
    /// `fields` in source order; each field is named by its declaration index.
    /// Fields missing from `fields` come from `base`.
    Construct {
        variant: usize,
        base: Option<Box<Expr>>,
        fields: Vec<(usize, Expr)>,
    },
    /// A struct field or tuple element, by declaration or position index.
    Field {
        base: Box<Expr>,
        index: usize,
    },
    Match {
        scrutinee: Box<Expr>,
        arms: Vec<Arm>,
    },
}

pub(crate) struct Arm {
    pub(crate) pattern: Pattern,
    pub(crate) guard: Option<Expr>,
    pub(crate) body: Expr,
}

#[derive(Debug, Clone)]
pub(crate) enum Pattern {
    Wildcard,
    Binding(usize),
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    Tuple(Vec<Pattern>),
    /// An enum variant with patterns for some of its fields, by index.
    Variant {
        variant: usize,
        fields: Vec<(usize, Pattern)>,
    },
    /// Alternatives that bind the same locals.
    Or(Vec<Pattern>),
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

enum Shape<'a> {
    Struct(&'a [ResolvedField]),
    Enum(&'a [ResolvedVariant]),
}

struct NominalDeclaration<'a> {
    name: String,
    type_parameters: Vec<EntityId>,
    shape: Shape<'a>,
    origin: OriginRef,
}

/// Struct and enum declarations, and the enum constructors by identity.
struct Nominals<'a> {
    declarations: Vec<NominalDeclaration<'a>>,
    by_identity: BTreeMap<EntityId, usize>,
    constructors: BTreeMap<EntityId, (usize, usize)>,
}

/// How deep generic instantiation may nest before it is reported.
const INSTANTIATION_DEPTH: usize = 64;

pub(crate) fn check(project: &ResolvedProject) -> Result<Program, CheckDiagnostic> {
    let mut functions_found = Vec::new();
    let mut nominals = Nominals {
        declarations: Vec::new(),
        by_identity: BTreeMap::new(),
        constructors: BTreeMap::new(),
    };
    for (module, resolved) in &project.modules {
        let Some(body) = &resolved.body else {
            continue;
        };
        let is_core = module.source_library() == Some(project.core);
        if body.requires.is_some() && !is_core {
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
            let type_parameters = |parameters: &[crate::project::ResolvedTypeParameter]| {
                parameters
                    .iter()
                    .map(|parameter| parameter.binding.identity.clone())
                    .collect::<Vec<_>>()
            };
            let shape = match &declaration.kind {
                ResolvedDeclarationKind::Struct {
                    type_parameters: parameters,
                    fields,
                } => Some((type_parameters(parameters), Shape::Struct(fields))),
                ResolvedDeclarationKind::Enum {
                    type_parameters: parameters,
                    variants,
                } => Some((type_parameters(parameters), Shape::Enum(variants))),
                _ => None,
            };
            if let Some((type_parameters, shape)) = shape {
                let identity = identity();
                let index = nominals.declarations.len();
                if let Shape::Enum(variants) = &shape {
                    for (position, variant) in variants.iter().enumerate() {
                        nominals
                            .constructors
                            .insert(variant.identity.clone(), (index, position));
                    }
                }
                nominals.by_identity.insert(identity.clone(), index);
                nominals.declarations.push(NominalDeclaration {
                    name: identity.name.clone(),
                    type_parameters,
                    shape,
                    origin: declaration.origin.clone(),
                });
                continue;
            }
            if is_core {
                continue;
            }
            match &declaration.kind {
                ResolvedDeclarationKind::Function(function) => {
                    functions_found.push((identity(), function, declaration.origin.clone()));
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
    for declaration in &nominals.declarations {
        types.nominals.push(NominalInfo {
            name: declaration.name.clone(),
            is_enum: matches!(declaration.shape, Shape::Enum(_)),
        });
    }
    // Every non-generic declaration is instantiated, so its fields are checked
    // even when no function mentions it.
    for (index, declaration) in nominals.declarations.iter().enumerate() {
        if declaration.type_parameters.is_empty() {
            instantiate(&mut types, &nominals, index, Vec::new(), 0)?;
        }
    }

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
    reject_recursive_types(&types, &nominals)?;

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

/// Interns `declaration` applied to `arguments` and, the first time, computes
/// the field types of its variants.
fn instantiate(
    types: &mut Types,
    nominals: &Nominals,
    declaration: usize,
    arguments: Vec<Type>,
    depth: usize,
) -> Result<Type, CheckDiagnostic> {
    let info = &nominals.declarations[declaration];
    let (ty, new) = types.intern_new(TypeKind::Nominal {
        declaration,
        arguments: arguments.clone(),
    });
    if !new {
        return Ok(ty);
    }
    if depth > INSTANTIATION_DEPTH {
        return Err(unsupported(
            Some(info.origin.clone()),
            "generic types nested this deeply",
        ));
    }
    let substitution = info
        .type_parameters
        .iter()
        .cloned()
        .zip(arguments)
        .collect::<BTreeMap<_, _>>();
    let mut field = |ty: &ResolvedType, name: String| -> Result<Field, CheckDiagnostic> {
        let ty = resolve_type(types, nominals, ty, &substitution, &info.origin, depth + 1)?;
        if ty == Type::NEVER {
            return Err(unsupported(Some(info.origin.clone()), "`Never` fields"));
        }
        Ok(Field { name, ty })
    };
    let variants = match &info.shape {
        Shape::Struct(fields) => vec![Variant {
            name: info.name.clone(),
            fields: fields
                .iter()
                .map(|resolved| field(&resolved.ty, resolved.identity.name.clone()))
                .collect::<Result<_, _>>()?,
        }],
        Shape::Enum(variants) => variants
            .iter()
            .map(|variant| {
                let fields = match &variant.fields {
                    ResolvedVariantFields::Unit => Vec::new(),
                    ResolvedVariantFields::Positional(fields) => fields
                        .iter()
                        .enumerate()
                        .map(|(index, ty)| field(ty, index.to_string()))
                        .collect::<Result<_, _>>()?,
                    ResolvedVariantFields::Named(fields) => fields
                        .iter()
                        .map(|named| field(&named.ty, named.identity.name.clone()))
                        .collect::<Result<_, _>>()?,
                };
                Ok(Variant {
                    name: variant.identity.name.clone(),
                    fields,
                })
            })
            .collect::<Result<_, CheckDiagnostic>>()?,
    };
    types.set_variants(ty, variants);
    Ok(ty)
}

/// Rejects nominal types that contain themselves by value, which would have
/// no finite size.
fn reject_recursive_types(types: &Types, nominals: &Nominals) -> Result<(), CheckDiagnostic> {
    for ty in types.all() {
        if let TypeKind::Nominal { declaration, .. } = types.kind(ty)
            && contains_by_value(types, ty, ty, &mut BTreeSet::new())
        {
            return Err(unsupported(
                Some(nominals.declarations[*declaration].origin.clone()),
                "recursive types",
            ));
        }
    }
    Ok(())
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
        parameters.push(resolve_type(
            types,
            nominals,
            annotation,
            &BTreeMap::new(),
            origin,
            0,
        )?);
    }
    if function.return_borrow.is_some() {
        return Err(unsupported(Some(origin.clone()), "borrowed return values"));
    }
    let result = match &function.return_type {
        Some(ty) => resolve_type(types, nominals, ty, &BTreeMap::new(), origin, 0)?,
        None => Type::UNIT,
    };
    Ok(Signature {
        index,
        parameters,
        result,
    })
}

/// Converts a written type. `substitution` gives the types of the type
/// parameters in scope.
fn resolve_type(
    types: &mut Types,
    nominals: &Nominals,
    ty: &ResolvedType,
    substitution: &BTreeMap<EntityId, Type>,
    origin: &OriginRef,
    depth: usize,
) -> Result<Type, CheckDiagnostic> {
    match &ty.kind {
        ResolvedTypeKind::Grouped(inner) => {
            resolve_type(types, nominals, inner, substitution, origin, depth)
        }
        ResolvedTypeKind::Tuple(elements) => {
            let elements = elements
                .iter()
                .map(|element| resolve_type(types, nominals, element, substitution, origin, depth))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(types.intern(TypeKind::Tuple(elements)))
        }
        ResolvedTypeKind::Named(named) => {
            let ResolvedReference::Exact { target, .. } = &named.reference else {
                return Err(unsupported(Some(at(origin, ty.span)), "this type"));
            };
            let mut arguments = Vec::new();
            for argument in &named.arguments {
                let ResolvedTypeArgument::Type(argument) = argument else {
                    return Err(unsupported(Some(at(origin, ty.span)), "this type"));
                };
                arguments.push(resolve_type(
                    types,
                    nominals,
                    argument,
                    substitution,
                    origin,
                    depth,
                )?);
            }
            if let Some(&ty) = substitution.get(target)
                && arguments.is_empty()
            {
                return Ok(ty);
            }
            if target.kind == EntityKind::LanguageType && arguments.is_empty() {
                let language = match target.name.as_str() {
                    "Int" => Some(Type::INT),
                    "Float" => Some(Type::FLOAT),
                    "Bool" => Some(Type::BOOL),
                    "Str" => Some(Type::STR),
                    "Unit" => Some(Type::UNIT),
                    "Never" => Some(Type::NEVER),
                    _ => None,
                };
                if let Some(language) = language {
                    return Ok(language);
                }
            }
            if let Some(&declaration) = nominals.by_identity.get(target) {
                let expected = nominals.declarations[declaration].type_parameters.len();
                if arguments.len() != expected {
                    return Err(CheckDiagnostic {
                        kind: CheckDiagnosticKind::ArgumentCount,
                        primary: Some(at(origin, ty.span)),
                        message: format!(
                            "`{}` takes {expected} type arguments, found {}",
                            target.name,
                            arguments.len()
                        ),
                    });
                }
                return instantiate(types, nominals, declaration, arguments, depth);
            }
            Err(unsupported(Some(at(origin, ty.span)), "this type"))
        }
        ResolvedTypeKind::Function { .. } => {
            Err(unsupported(Some(at(origin, ty.span)), "function types"))
        }
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

/// The values given to a variant or struct, in source order.
enum Arguments<'r> {
    Positional(&'r [ResolvedExpr]),
    Named(&'r [ResolvedConstructEntry]),
}

struct BodyChecker<'a> {
    types: &'a mut Types,
    nominals: &'a Nominals<'a>,
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
        Some(self.at(span))
    }

    fn at(&self, span: Span) -> OriginRef {
        OriginRef {
            library: self.library,
            source: self.source.clone(),
            span,
        }
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

    fn resolve_type(
        &mut self,
        ty: &ResolvedType,
        substitution: &BTreeMap<EntityId, Type>,
    ) -> Result<Type, CheckDiagnostic> {
        let origin = self.at(ty.span);
        resolve_type(self.types, self.nominals, ty, substitution, &origin, 0)
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
                pattern,
                mutable,
                annotation_borrow,
                annotation,
                value,
            } => {
                if annotation_borrow.is_some() {
                    return Err(self.unsupported(span, "borrowed bindings"));
                }
                if let Some(pattern) = pattern {
                    let value = self.check_expr(value, None)?;
                    if value.ty == Type::NEVER {
                        return Ok((Statement::Expr(value), true));
                    }
                    let pattern = self.check_pattern(pattern, value.ty, &mut BTreeMap::new())?;
                    if let Some(missing) = exhaustive::missing(self.types, &[&pattern], value.ty) {
                        return Err(self.error(
                            CheckDiagnosticKind::NonExhaustive,
                            span,
                            format!("this destructuring does not cover `{missing}`"),
                        ));
                    }
                    return Ok((Statement::LetPattern { pattern, value }, false));
                }
                let [binding] = bindings.as_slice() else {
                    unreachable!("a let without a pattern binds one name")
                };
                let expected = match annotation {
                    Some(annotation) => Some(self.resolve_type(annotation, &BTreeMap::new())?),
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
            ResolvedStatementKind::IfLet {
                pattern,
                value,
                then_branch,
                else_branch,
            } => {
                let expression = self.check_if_let(pattern, value, then_branch, else_branch)?;
                let diverges = expression.ty == Type::NEVER;
                Ok((Statement::Expr(expression), diverges))
            }
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
        if let Some((position, field)) = self
            .types
            .struct_fields(ty)
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
                (Type::FLOAT, ExprKind::Float(self.float(span, text)?))
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
                let ResolvedReference::Exact { target, .. } = reference else {
                    return Err(self.unsupported(span, "values other than local variables"));
                };
                if let Some(&local) = self.local_ids.get(target) {
                    (self.locals[local].ty, ExprKind::Local(local))
                } else if let Some(&(declaration, variant)) = self.nominals.constructors.get(target)
                {
                    self.check_variant(span, declaration, variant, None, expected)?
                } else {
                    return Err(self.unsupported(span, "values other than local variables"));
                }
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
            ResolvedExprKind::Match { scrutinee, arms } => {
                self.check_match(span, scrutinee, arms, expected)?
            }
            ResolvedExprKind::Unary { operator, operand } => {
                self.check_unary(*operator, operand)?
            }
            ResolvedExprKind::Binary {
                left,
                operator,
                right,
            } => self.check_binary(*operator, left, right)?,
            ResolvedExprKind::Call { callee, arguments } => {
                self.check_call(span, callee, arguments, expected)?
            }
            ResolvedExprKind::Tuple(elements) => self.check_tuple(elements, expected)?,
            ResolvedExprKind::NamedConstruct { target, entries } => {
                let ResolvedReference::Exact { target, .. } = target else {
                    return Err(self.unsupported(span, "this construction"));
                };
                if let Some(&declaration) = self.nominals.by_identity.get(target)
                    && matches!(
                        self.nominals.declarations[declaration].shape,
                        Shape::Struct(_)
                    )
                {
                    self.check_variant(
                        span,
                        declaration,
                        0,
                        Some(Arguments::Named(entries)),
                        expected,
                    )?
                } else if let Some(&(declaration, variant)) = self.nominals.constructors.get(target)
                {
                    self.check_variant(
                        span,
                        declaration,
                        variant,
                        Some(Arguments::Named(entries)),
                        expected,
                    )?
                } else {
                    return Err(self.unsupported(span, "this construction"));
                }
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

    /// Checks a struct construction (variant 0) or an enum variant value,
    /// inferring type arguments from `expected` or from the given fields.
    fn check_variant(
        &mut self,
        span: Span,
        declaration: usize,
        variant: usize,
        arguments: Option<Arguments>,
        expected: Option<Type>,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let nominals = self.nominals;
        let info = &nominals.declarations[declaration];
        let written_fields: Vec<(String, &ResolvedType)> = match &info.shape {
            Shape::Struct(fields) => fields
                .iter()
                .map(|field| (field.identity.name.clone(), &field.ty))
                .collect(),
            Shape::Enum(variants) => match &variants[variant].fields {
                ResolvedVariantFields::Unit => Vec::new(),
                ResolvedVariantFields::Positional(fields) => fields
                    .iter()
                    .enumerate()
                    .map(|(index, ty)| (index.to_string(), ty))
                    .collect(),
                ResolvedVariantFields::Named(fields) => fields
                    .iter()
                    .map(|field| (field.identity.name.clone(), &field.ty))
                    .collect(),
            },
        };
        let is_struct = matches!(info.shape, Shape::Struct(_));
        let mut substitution = BTreeMap::new();
        if let Some(expected) = expected
            && let TypeKind::Nominal {
                declaration: expected_declaration,
                arguments,
            } = self.types.kind(expected)
            && *expected_declaration == declaration
        {
            substitution = info
                .type_parameters
                .iter()
                .cloned()
                .zip(arguments.iter().copied())
                .collect();
        }

        // Pair every given value with its field, in source order.
        let mut given: Vec<(usize, &ResolvedExpr, Span)> = Vec::new();
        let mut shorthands = Vec::new();
        let mut base_expression = None;
        match arguments {
            None => {}
            Some(Arguments::Positional(values)) => {
                let positional = matches!(
                    &info.shape,
                    Shape::Enum(variants)
                        if matches!(variants[variant].fields, ResolvedVariantFields::Positional(_))
                );
                if !positional || values.len() != written_fields.len() {
                    return Err(self.error(
                        CheckDiagnosticKind::ArgumentCount,
                        span,
                        format!(
                            "`{}` takes {} positional values, found {}",
                            self.variant_name(declaration, variant),
                            if positional { written_fields.len() } else { 0 },
                            values.len()
                        ),
                    ));
                }
                for (index, value) in values.iter().enumerate() {
                    given.push((index, value, value.span));
                }
            }
            Some(Arguments::Named(entries)) => {
                let named = is_struct
                    || matches!(
                        &info.shape,
                        Shape::Enum(variants)
                            if matches!(variants[variant].fields, ResolvedVariantFields::Named(_))
                    );
                if !named {
                    return Err(self.error(
                        CheckDiagnosticKind::TypeMismatch,
                        span,
                        format!(
                            "`{}` has no named fields",
                            self.variant_name(declaration, variant)
                        ),
                    ));
                }
                for entry in entries {
                    match entry {
                        ResolvedConstructEntry::Spread(expression) => {
                            if !is_struct {
                                return Err(self.unsupported(expression.span, "enum spreads"));
                            }
                            base_expression = Some(expression);
                        }
                        ResolvedConstructEntry::Field {
                            member,
                            value,
                            shorthand,
                        } => {
                            let Some(index) = written_fields
                                .iter()
                                .position(|(name, _)| *name == member.name)
                            else {
                                return Err(self.error(
                                    CheckDiagnosticKind::UnknownField,
                                    member.origin.span,
                                    format!(
                                        "`{}` has no field `{}`",
                                        self.variant_name(declaration, variant),
                                        member.name
                                    ),
                                ));
                            };
                            if given.iter().any(|(existing, _, _)| *existing == index) {
                                return Err(self.error(
                                    CheckDiagnosticKind::UnknownField,
                                    member.origin.span,
                                    format!("field `{}` is given twice", member.name),
                                ));
                            }
                            match (value, shorthand) {
                                (Some(value), _) => given.push((index, value, value.span)),
                                (None, Some(reference)) => {
                                    shorthands.push((index, member.origin.span, reference));
                                }
                                (None, None) => {
                                    unreachable!("a field without a value is a shorthand")
                                }
                            }
                        }
                    }
                }
            }
        }
        let shorthand_expressions = shorthands
            .iter()
            .map(|(index, field_span, reference)| {
                (
                    *index,
                    ResolvedExpr {
                        span: *field_span,
                        kind: ResolvedExprKind::Path(reference.as_ref().clone()),
                    },
                )
            })
            .collect::<Vec<_>>();
        for (index, expression) in &shorthand_expressions {
            given.push((*index, expression, expression.span));
        }
        given.sort_by_key(|(_, _, span)| span.start);

        let base = match base_expression {
            Some(expression) => {
                let base = self.check_expr(expression, expected)?;
                if base.ty == Type::NEVER {
                    return Err(self.unsupported(expression.span, "diverging bases"));
                }
                if let TypeKind::Nominal {
                    declaration: base_declaration,
                    arguments,
                } = self.types.kind(base.ty)
                    && *base_declaration == declaration
                {
                    substitution = info
                        .type_parameters
                        .iter()
                        .cloned()
                        .zip(arguments.iter().copied())
                        .collect();
                } else {
                    return Err(self.error(
                        CheckDiagnosticKind::TypeMismatch,
                        expression.span,
                        format!(
                            "expected a `{}` value, found `{}`",
                            info.name,
                            self.types.name(base.ty)
                        ),
                    ));
                }
                Some(Box::new(base))
            }
            None => None,
        };

        let mut fields = Vec::new();
        for (index, value, value_span) in given {
            let written = written_fields[index].1;
            let field_expected = if mentions_only(written, &substitution, &info.type_parameters) {
                Some(self.resolve_type(written, &substitution)?)
            } else {
                None
            };
            let checked = self.check_expr(value, field_expected)?;
            if checked.ty == Type::NEVER {
                return Err(self.unsupported(value_span, "diverging fields"));
            }
            match field_expected {
                Some(field_expected) => self.require(value_span, field_expected, checked.ty)?,
                None => {
                    if !self.bind(written, checked.ty, &mut substitution) {
                        return Err(self.error(
                            CheckDiagnosticKind::TypeMismatch,
                            value_span,
                            format!(
                                "`{}` does not fit field `{}`",
                                self.types.name(checked.ty),
                                written_fields[index].0
                            ),
                        ));
                    }
                }
            }
            fields.push((index, checked));
        }
        if base.is_none()
            && let Some(position) = (0..written_fields.len())
                .find(|position| fields.iter().all(|(index, _)| index != position))
        {
            return Err(self.error(
                CheckDiagnosticKind::MissingField,
                span,
                format!("field `{}` has no value", written_fields[position].0),
            ));
        }
        let mut type_arguments = Vec::new();
        for parameter in &info.type_parameters {
            let Some(&argument) = substitution.get(parameter) else {
                return Err(self.error(
                    CheckDiagnosticKind::CannotInfer,
                    span,
                    format!(
                        "the type arguments of `{}` cannot be inferred here; write the expected type",
                        info.name
                    ),
                ));
            };
            type_arguments.push(argument);
        }
        let ty = instantiate(self.types, nominals, declaration, type_arguments, 0)?;
        for (index, value) in &fields {
            let field_ty = self.types.variants(ty)[variant].fields[*index].ty;
            if value.ty != field_ty {
                return Err(self.mismatch(span, field_ty, value.ty));
            }
        }
        Ok((
            ty,
            ExprKind::Construct {
                variant,
                base,
                fields,
            },
        ))
    }

    fn variant_name(&self, declaration: usize, variant: usize) -> String {
        let info = &self.nominals.declarations[declaration];
        match &info.shape {
            Shape::Struct(_) => info.name.clone(),
            Shape::Enum(variants) => format!("{}::{}", info.name, variants[variant].identity.name),
        }
    }

    /// Matches the written type `written` against `actual`, binding type
    /// parameters in `substitution`. Returns whether they fit.
    fn bind(
        &mut self,
        written: &ResolvedType,
        actual: Type,
        substitution: &mut BTreeMap<EntityId, Type>,
    ) -> bool {
        match &written.kind {
            ResolvedTypeKind::Grouped(inner) => self.bind(inner, actual, substitution),
            ResolvedTypeKind::Tuple(elements) => {
                let TypeKind::Tuple(actual_elements) = self.types.kind(actual).clone() else {
                    return false;
                };
                elements.len() == actual_elements.len()
                    && elements
                        .iter()
                        .zip(actual_elements)
                        .all(|(element, actual)| self.bind(element, actual, substitution))
            }
            ResolvedTypeKind::Named(named) => {
                let ResolvedReference::Exact { target, .. } = &named.reference else {
                    return false;
                };
                if target.kind == EntityKind::TypeParameter && named.arguments.is_empty() {
                    return match substitution.get(target) {
                        Some(&bound) => bound == actual,
                        None => {
                            substitution.insert(target.clone(), actual);
                            true
                        }
                    };
                }
                if let Some(&declaration) = self.nominals.by_identity.get(target) {
                    let TypeKind::Nominal {
                        declaration: actual_declaration,
                        arguments,
                    } = self.types.kind(actual).clone()
                    else {
                        return false;
                    };
                    return declaration == actual_declaration
                        && named.arguments.len() == arguments.len()
                        && named
                            .arguments
                            .iter()
                            .zip(arguments)
                            .all(|(written, actual)| {
                                matches!(written, ResolvedTypeArgument::Type(written)
                                if self.bind(written, actual, substitution))
                            });
                }
                self.resolve_type(written, substitution)
                    .is_ok_and(|resolved| resolved == actual)
            }
            ResolvedTypeKind::Function { .. } => false,
        }
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

    fn float(&self, span: Span, text: &str) -> Result<f64, CheckDiagnostic> {
        let value = text
            .parse::<f64>()
            .expect("the lexer admits only decimal floats");
        if value.is_finite() {
            Ok(value)
        } else {
            Err(self.error(
                CheckDiagnosticKind::LiteralOutOfRange,
                span,
                "this float literal is too large".to_owned(),
            ))
        }
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

    fn check_match(
        &mut self,
        span: Span,
        scrutinee: &ResolvedExpr,
        arms: &[ResolvedMatchArm],
        expected: Option<Type>,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        if matches!(scrutinee.kind, ResolvedExprKind::Borrow { .. }) {
            return Err(self.unsupported(scrutinee.span, "borrowed `match` subjects"));
        }
        let scrutinee = self.check_expr(scrutinee, None)?;
        if scrutinee.ty == Type::NEVER {
            return Ok((Type::NEVER, scrutinee.kind));
        }
        let mut expected = expected;
        let mut ty = None;
        let mut checked = Vec::new();
        for arm in arms {
            let scope = self.local_ids.clone();
            let pattern = self.check_pattern(&arm.pattern, scrutinee.ty, &mut BTreeMap::new())?;
            let guard = arm
                .guard
                .as_ref()
                .map(|guard| self.check_condition(guard))
                .transpose()?;
            let body = self.check_expr(&arm.body, expected)?;
            self.local_ids = scope;
            if body.ty != Type::NEVER {
                match ty {
                    None => {
                        ty = Some(body.ty);
                        expected = expected.or(Some(body.ty));
                    }
                    Some(_) if expected == Some(Type::UNIT) => {}
                    Some(previous) => self.require(arm.body.span, previous, body.ty)?,
                }
            }
            checked.push(Arm {
                pattern,
                guard,
                body,
            });
        }
        let unguarded = checked
            .iter()
            .filter(|arm| arm.guard.is_none())
            .map(|arm| &arm.pattern)
            .collect::<Vec<_>>();
        if let Some(missing) = exhaustive::missing(self.types, &unguarded, scrutinee.ty) {
            return Err(self.error(
                CheckDiagnosticKind::NonExhaustive,
                span,
                format!("this `match` does not cover `{missing}`"),
            ));
        }
        let ty = match ty {
            None => Type::NEVER,
            Some(_) if expected == Some(Type::UNIT) => Type::UNIT,
            Some(ty) => ty,
        };
        Ok((
            ty,
            ExprKind::Match {
                scrutinee: Box::new(scrutinee),
                arms: checked,
            },
        ))
    }

    /// `if let P = v { A } else { B }` is `match v { P => A, _ => B }` of type `Unit`.
    fn check_if_let(
        &mut self,
        pattern: &ResolvedPattern,
        value: &ResolvedExpr,
        then_branch: &ResolvedBlock,
        else_branch: &Option<ResolvedBlock>,
    ) -> Result<Expr, CheckDiagnostic> {
        if matches!(value.kind, ResolvedExprKind::Borrow { .. }) {
            return Err(self.unsupported(value.span, "borrowed `if let` subjects"));
        }
        let scrutinee = self.check_expr(value, None)?;
        if scrutinee.ty == Type::NEVER {
            return Ok(scrutinee);
        }
        let scope = self.local_ids.clone();
        let pattern = self.check_pattern(pattern, scrutinee.ty, &mut BTreeMap::new())?;
        let then_branch = self.check_block(then_branch, Some(Type::UNIT))?;
        self.local_ids = scope;
        let else_body = match else_branch {
            Some(block) => self.check_block(block, Some(Type::UNIT))?,
            None => Block {
                statements: Vec::new(),
                tail: None,
                ty: Type::UNIT,
            },
        };
        let ty = if then_branch.ty == Type::NEVER && else_body.ty == Type::NEVER {
            Type::NEVER
        } else {
            Type::UNIT
        };
        let arm = |pattern, body: Block| Arm {
            pattern,
            guard: None,
            body: Expr {
                ty: body.ty,
                kind: ExprKind::Block(body),
            },
        };
        Ok(Expr {
            ty,
            kind: ExprKind::Match {
                scrutinee: Box::new(scrutinee),
                arms: vec![arm(pattern, then_branch), arm(Pattern::Wildcard, else_body)],
            },
        })
    }

    /// Checks `pattern` against a value of type `ty`, declaring its bindings.
    /// `shared` maps binding names to the locals of earlier alternatives.
    fn check_pattern(
        &mut self,
        pattern: &ResolvedPattern,
        ty: Type,
        shared: &mut BTreeMap<String, usize>,
    ) -> Result<Pattern, CheckDiagnostic> {
        let span = pattern.span;
        let literal = |checker: &Self, literal_ty: Type| -> Result<(), CheckDiagnostic> {
            if literal_ty == ty {
                Ok(())
            } else {
                Err(checker.mismatch(span, ty, literal_ty))
            }
        };
        Ok(match &pattern.kind {
            ResolvedPatternKind::Wildcard => Pattern::Wildcard,
            ResolvedPatternKind::Integer(text) => {
                literal(self, Type::INT)?;
                Pattern::Int(self.integer(span, text)?)
            }
            ResolvedPatternKind::Float(text) => {
                literal(self, Type::FLOAT)?;
                Pattern::Float(self.float(span, text)?)
            }
            ResolvedPatternKind::String(value) => {
                literal(self, Type::STR)?;
                Pattern::Str(value.clone())
            }
            ResolvedPatternKind::Boolean(value) => {
                literal(self, Type::BOOL)?;
                Pattern::Bool(*value)
            }
            ResolvedPatternKind::Binding(binding) => {
                let name = binding.identity.name.clone();
                if let Some(&local) = shared.get(&name) {
                    if self.locals[local].ty != ty {
                        return Err(self.mismatch(span, self.locals[local].ty, ty));
                    }
                    self.local_ids.insert(binding.identity.clone(), local);
                    Pattern::Binding(local)
                } else {
                    let local = self.declare(&binding.identity, ty, false);
                    shared.insert(name, local);
                    Pattern::Binding(local)
                }
            }
            ResolvedPatternKind::Tuple(elements) => {
                let TypeKind::Tuple(element_types) = self.types.kind(ty).clone() else {
                    return Err(self.error(
                        CheckDiagnosticKind::TypeMismatch,
                        span,
                        format!("a tuple pattern cannot match `{}`", self.types.name(ty)),
                    ));
                };
                if element_types.len() != elements.len() {
                    return Err(self.error(
                        CheckDiagnosticKind::TypeMismatch,
                        span,
                        format!(
                            "`{}` has {} elements, the pattern has {}",
                            self.types.name(ty),
                            element_types.len(),
                            elements.len()
                        ),
                    ));
                }
                Pattern::Tuple(
                    elements
                        .iter()
                        .zip(element_types)
                        .map(|(element, element_ty)| {
                            self.check_pattern(element, element_ty, shared)
                        })
                        .collect::<Result<_, _>>()?,
                )
            }
            ResolvedPatternKind::Or(alternatives) => {
                let mut checked = Vec::new();
                for alternative in alternatives {
                    checked.push(self.check_pattern(alternative, ty, shared)?);
                }
                Pattern::Or(checked)
            }
            ResolvedPatternKind::Constructor { target, fields } => {
                let constructor = match target {
                    ResolvedReference::Exact { target, .. } => {
                        self.nominals.constructors.get(target).copied()
                    }
                    ResolvedReference::Selection { .. } => None,
                };
                let Some((declaration, variant)) = constructor else {
                    return Err(self.unsupported(span, "this pattern"));
                };
                let matches_type = matches!(
                    self.types.kind(ty),
                    TypeKind::Nominal { declaration: actual, .. } if *actual == declaration
                );
                if !matches_type {
                    return Err(self.error(
                        CheckDiagnosticKind::TypeMismatch,
                        span,
                        format!(
                            "`{}` cannot match `{}`",
                            self.variant_name(declaration, variant),
                            self.types.name(ty)
                        ),
                    ));
                }
                let field_types = self.types.variants(ty)[variant]
                    .fields
                    .iter()
                    .map(|field| (field.name.clone(), field.ty))
                    .collect::<Vec<_>>();
                let mut checked = Vec::new();
                match fields {
                    None if field_types.is_empty() => {}
                    None => {
                        return Err(self.error(
                            CheckDiagnosticKind::ArgumentCount,
                            span,
                            format!(
                                "`{}` has fields; write a pattern for them",
                                self.variant_name(declaration, variant)
                            ),
                        ));
                    }
                    Some(ResolvedPatternFields::Positional(patterns)) => {
                        if patterns.len() != field_types.len()
                            || field_types
                                .iter()
                                .any(|(name, _)| name.parse::<usize>().is_err())
                        {
                            return Err(self.error(
                                CheckDiagnosticKind::ArgumentCount,
                                span,
                                format!(
                                    "`{}` has {} positional fields, the pattern has {}",
                                    self.variant_name(declaration, variant),
                                    field_types.len(),
                                    patterns.len()
                                ),
                            ));
                        }
                        for (index, (pattern, (_, field_ty))) in
                            patterns.iter().zip(&field_types).enumerate()
                        {
                            checked.push((index, self.check_pattern(pattern, *field_ty, shared)?));
                        }
                    }
                    Some(ResolvedPatternFields::Named {
                        fields: named,
                        rest,
                    }) => {
                        for field in named {
                            let Some(index) = field_types
                                .iter()
                                .position(|(name, _)| *name == field.member.name)
                            else {
                                return Err(self.error(
                                    CheckDiagnosticKind::UnknownField,
                                    field.member.origin.span,
                                    format!(
                                        "`{}` has no field `{}`",
                                        self.variant_name(declaration, variant),
                                        field.member.name
                                    ),
                                ));
                            };
                            let field_ty = field_types[index].1;
                            checked.push((
                                index,
                                self.check_pattern(&field.pattern, field_ty, shared)?,
                            ));
                        }
                        if rest.is_none() && checked.len() != field_types.len() {
                            return Err(self.error(
                                CheckDiagnosticKind::MissingField,
                                span,
                                "list every field or end the pattern with `..`".to_owned(),
                            ));
                        }
                    }
                }
                Pattern::Variant {
                    variant,
                    fields: checked,
                }
            }
        })
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
            Op::Equal | Op::NotEqual => self.has_equality(ty).then_some(Type::BOOL),
            Op::Less | Op::Greater | Op::LessEqual | Op::GreaterEqual => {
                is_printable(ty).then_some(Type::BOOL)
            }
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

    /// Whether `==` applies: built-in values and aggregates of them.
    fn has_equality(&self, ty: Type) -> bool {
        match self.types.kind(ty) {
            TypeKind::Int | TypeKind::Float | TypeKind::Bool | TypeKind::Str | TypeKind::Unit => {
                true
            }
            TypeKind::Never => false,
            TypeKind::Tuple(_) | TypeKind::Nominal { .. } => self
                .types
                .components(ty)
                .into_iter()
                .all(|component| self.has_equality(component)),
        }
    }

    fn check_call(
        &mut self,
        span: Span,
        callee: &ResolvedExpr,
        arguments: &[ResolvedExpr],
        expected: Option<Type>,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let ResolvedExprKind::Path(ResolvedReference::Exact { target, .. }) = &callee.kind else {
            return Err(self.unsupported(callee.span, "calls of computed functions"));
        };
        if let Some(&(declaration, variant)) = self.nominals.constructors.get(target) {
            return self.check_variant(
                span,
                declaration,
                variant,
                Some(Arguments::Positional(arguments)),
                expected,
            );
        }
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

/// Whether every type parameter that `ty` mentions is bound in `substitution`.
fn mentions_only(
    ty: &ResolvedType,
    substitution: &BTreeMap<EntityId, Type>,
    parameters: &[EntityId],
) -> bool {
    match &ty.kind {
        ResolvedTypeKind::Grouped(inner) => mentions_only(inner, substitution, parameters),
        ResolvedTypeKind::Tuple(elements) => elements
            .iter()
            .all(|element| mentions_only(element, substitution, parameters)),
        ResolvedTypeKind::Named(named) => {
            let parameter_bound = match &named.reference {
                ResolvedReference::Exact { target, .. } if parameters.contains(target) => {
                    substitution.contains_key(target)
                }
                _ => true,
            };
            parameter_bound
                && named.arguments.iter().all(|argument| match argument {
                    ResolvedTypeArgument::Type(argument) => {
                        mentions_only(argument, substitution, parameters)
                    }
                    ResolvedTypeArgument::AssociatedType { value, .. } => {
                        mentions_only(value, substitution, parameters)
                    }
                })
        }
        ResolvedTypeKind::Function { .. } => true,
    }
}

/// Whether `ty` has a built-in text form and built-in ordering.
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
