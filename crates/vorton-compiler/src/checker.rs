//! Type checking.
//!
//! The checker covers `Int`, `Float`, `Bool`, `Str` and `Unit` values,
//! tuples, structs and enums (generic ones are instantiated at concrete type
//! arguments), `List` and `Map` with their built-in methods, `match`, `if let` and tuple
//! destructuring with exhaustiveness, named functions with written
//! signatures, inherent methods and associated functions of non-generic
//! types, local bindings, assignment to `let mut` locals and their parts,
//! `if`, `while`, `loop`, `for` over ranges and lists, `break`, `continue`,
//! `return`, string interpolation, and the `print`, `assert` and `panic`
//! intrinsics. Every other construct reports
//! [`CheckDiagnosticKind::Unsupported`] instead of being treated as checked.
//!
//! Entities (lists and the aggregates that contain them) are moved, never
//! copied. The checker tracks which locals may have been moved along every
//! path and rejects a later use, a move out of a field or element, and a move
//! of an outer local that a later loop iteration would see.
//!
//! Borrows appear as parameters, call arguments, `for` and `match` subjects,
//! `let` values and function results. While a borrow lasts, the place it
//! names cannot be changed, moved or, after `&mut`, borrowed again: a call
//! argument lasts until the call ends, a loop or `match` subject until it
//! ends, the arguments of a call that returns a borrow until the statement
//! ends, and a `let` borrow until the last use of its bindings on some path,
//! as in Rust.

use std::collections::{BTreeMap, BTreeSet};

use crate::ast::{AssignmentOperator, BinaryOperator, BorrowKind, Span, UnaryOperator};
use crate::exhaustive;
use crate::project::{
    EntityId, EntityKind, EntitySite, LibraryId, ModuleRef, OriginRef, ResolvedBlock,
    ResolvedConstructEntry, ResolvedDeclarationKind, ResolvedExpr, ResolvedExprKind, ResolvedField,
    ResolvedFunction, ResolvedImplMemberKind, ResolvedInterpolationPart, ResolvedMatchArm,
    ResolvedPattern, ResolvedPatternFields, ResolvedPatternKind, ResolvedPlace,
    ResolvedPlaceProjection, ResolvedProject, ResolvedReference, ResolvedStatement,
    ResolvedStatementKind, ResolvedType, ResolvedTypeArgument, ResolvedTypeKind, ResolvedVariant,
    ResolvedVariantFields, SourceRef,
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
    /// A local is used after its entity value may have been moved away.
    UseAfterMove,
    /// An entity is moved out of a field, an element or a borrow.
    CannotMove,
    /// A method that the receiver's type does not have.
    UnknownMethod,
    /// A place is changed while a loop or borrow still reads it.
    BorrowConflict,
    /// A returned borrow names a place that ends when the function returns.
    BorrowOutlives,
    /// Two impls give a type methods of the same name.
    DuplicateMethod,
    /// A struct, enum or tuple contains itself by value and has no finite
    /// size.
    RecursiveType,
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
    /// A borrowed result is a pointer to a place of type `result`.
    pub(crate) result_borrow: Option<BorrowKind>,
    pub(crate) body: Block,
}

pub(crate) struct Local {
    pub(crate) name: String,
    pub(crate) ty: Type,
    /// A borrowed local holds a pointer to a place of type `ty`.
    pub(crate) borrow: Option<BorrowKind>,
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
    For {
        binding: Pattern,
        source: ForSource,
        body: Block,
    },
}

pub(crate) enum ForSource {
    /// `start..end` or `start..=end` over `Int`.
    Range {
        start: Expr,
        end: Expr,
        inclusive: bool,
    },
    /// Counts through a `Range<Int>` value.
    RangeValue(Expr),
    /// Takes the list or map and yields its elements of type `element`: a
    /// map's entries as `(key, value)` tuples.
    Taken { container: Expr, element: Type },
    /// Borrows the elements of a list place without taking them.
    Borrowed(Place),
}

/// A local and a path of parts inside it.
pub(crate) struct Place {
    pub(crate) local: usize,
    /// A call that returns a borrow, made first; the borrowed `local` then
    /// points at what it returns.
    pub(crate) call: Option<Box<Expr>>,
    pub(crate) projections: Vec<Projection>,
}

pub(crate) enum Projection {
    /// A struct field or tuple element, by index.
    Field(usize),
    /// A list element at a checked index.
    Index(Box<Expr>),
}

/// The receiver of a built-in method: a place it reads or changes, or a
/// value it reads and then releases.
pub(crate) enum Receiver {
    Place(Place),
    Value(Box<Expr>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Builtin {
    /// `List::push(&mut self, value)`.
    Push,
    /// `List::pop(&mut self) -> Option<T>`.
    Pop,
    /// `len(&self) -> Int` of a list or map.
    Len,
    /// `is_empty(&self) -> Bool` of a list or map.
    IsEmpty,
    /// `List::insert(&mut self, index, value)`, or
    /// `Map::insert(&mut self, key, value) -> Option<V>`.
    Insert,
    /// `List::remove(&mut self, index) -> T`, or
    /// `Map::remove(&mut self, key) -> Option<V>`.
    Remove,
    /// `clear(&mut self)` of a list or map.
    Clear,
    /// `List::contains(&self, value) -> Bool`.
    Contains,
    /// `List::get(&self, index) -> Option<T>` or
    /// `Map::get(&self, key) -> Option<V>`, for a value element.
    Get,
    /// `Map::contains_key(&self, key) -> Bool`.
    ContainsKey,
    /// `Map::keys(&self) -> List<K>`.
    Keys,
    /// `clone(&self)` of any type.
    Clone,
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
        /// Pairs of borrowed arguments whose places must differ at run time.
        checks: Vec<DisjointCheck>,
        /// A call that returns a borrow names the place it points at.
        borrow: Option<BorrowKind>,
    },
    Intrinsic {
        intrinsic: Intrinsic,
        arguments: Vec<Expr>,
        /// For `swap`, places that must differ at run time.
        checks: Vec<DisjointCheck>,
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
    /// Takes the entity value of a local, or of a part of it reached through
    /// fields, which is left empty.
    Move(Place),
    List(Vec<Expr>),
    /// `Map::new()` or `Set::new()`.
    EmptyMap,
    /// `start..end` or `start..=end` as a `Range<Int>` value.
    Range {
        start: Box<Expr>,
        end: Box<Expr>,
        inclusive: bool,
    },
    /// Reads a value element of a list, or the value of a key in a map.
    Index {
        base: Box<Expr>,
        index: Box<Expr>,
    },
    Builtin {
        builtin: Builtin,
        receiver: Box<Receiver>,
        arguments: Vec<Expr>,
    },
    /// `&x` or `&mut x` as a call argument, `match` subject, `let` value or
    /// returned result: a pointer to a place, or to a temporary that lives
    /// until the end of the enclosing statement.
    Borrow(Box<BorrowTarget>),
}

pub(crate) enum BorrowTarget {
    Place(Place),
    Value(Expr),
}

/// Two borrowed arguments of one call whose places have the same shape and
/// differ only in list indices; they must not name the same element.
pub(crate) struct DisjointCheck {
    pub(crate) first: usize,
    pub(crate) second: usize,
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

impl Pattern {
    /// The binding locals; the alternatives of an or-pattern bind the same
    /// locals, so only the first is read.
    pub(crate) fn bindings(&self) -> Vec<usize> {
        fn collect(pattern: &Pattern, locals: &mut Vec<usize>) {
            match pattern {
                Pattern::Binding(local) => locals.push(*local),
                Pattern::Tuple(elements) => {
                    for element in elements {
                        collect(element, locals);
                    }
                }
                Pattern::Variant { fields, .. } => {
                    for (_, field) in fields {
                        collect(field, locals);
                    }
                }
                Pattern::Or(alternatives) => {
                    if let Some(first) = alternatives.first() {
                        collect(first, locals);
                    }
                }
                Pattern::Wildcard
                | Pattern::Int(_)
                | Pattern::Float(_)
                | Pattern::Bool(_)
                | Pattern::Str(_) => {}
            }
        }
        let mut locals = Vec::new();
        collect(self, &mut locals);
        locals
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Intrinsic {
    Print,
    Assert,
    Panic,
    /// `replace(place: &mut T, value: T) -> T`.
    Replace,
    /// `swap(a: &mut T, b: &mut T)`.
    Swap,
}

struct Signature {
    index: usize,
    /// Whether the first parameter is the `self` of a method.
    receiver: bool,
    parameters: Vec<(Type, Option<BorrowKind>)>,
    result: Type,
    result_borrow: Option<BorrowKind>,
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
    /// The core `Option` declaration and its `Some` and `None` variants.
    option: Option<(usize, usize, usize)>,
}

/// How deep generic instantiation may nest before it is reported.
const INSTANTIATION_DEPTH: usize = 64;

/// A function or inherent method to check.
struct FoundFunction<'a> {
    identity: EntityId,
    /// The name in the generated code; a method's includes its type.
    name: String,
    function: &'a ResolvedFunction,
    origin: OriginRef,
    /// The type a method belongs to.
    owner: Option<Type>,
}

/// The inherent methods and associated functions of each struct or enum
/// declaration, by name.
type Methods = BTreeMap<(usize, String), EntityId>;

pub(crate) fn check(project: &ResolvedProject) -> Result<Program, CheckDiagnostic> {
    let mut functions_found = Vec::new();
    let mut impls = Vec::new();
    let mut nominals = Nominals {
        declarations: Vec::new(),
        by_identity: BTreeMap::new(),
        constructors: BTreeMap::new(),
        option: None,
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
                    let identity = identity();
                    functions_found.push(FoundFunction {
                        name: identity.name.clone(),
                        identity,
                        function,
                        origin: declaration.origin.clone(),
                        owner: None,
                    });
                }
                ResolvedDeclarationKind::InherentImpl(implementation) => {
                    impls.push((implementation, declaration.origin.clone()));
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

    let option = &project.core_roles.option;
    if let (Some(&declaration), Some(&(_, some)), Some(&(_, none))) = (
        nominals.by_identity.get(&option.declaration),
        nominals.constructors.get(&option.some),
        nominals.constructors.get(&option.none),
    ) {
        nominals.option = Some((declaration, some, none));
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

    let mut methods = BTreeMap::new();
    for (implementation, origin) in impls {
        if !implementation.type_parameters.is_empty() {
            return Err(unsupported(Some(origin), "generic impls"));
        }
        let target = ResolvedType {
            span: implementation.target.span,
            kind: ResolvedTypeKind::Named(Box::new(implementation.target.clone())),
        };
        let owner = resolve_type(&mut types, &nominals, &target, &BTreeMap::new(), &origin, 0)?;
        let &TypeKind::Nominal { declaration, .. } = types.kind(owner) else {
            return Err(unsupported(Some(origin), "methods of built-in types"));
        };
        if !nominals.declarations[declaration]
            .type_parameters
            .is_empty()
        {
            return Err(unsupported(Some(origin), "methods of generic types"));
        }
        for member in &implementation.members {
            let member_origin = match &member.identity.site {
                EntitySite::Source(site) => site.clone(),
                _ => origin.clone(),
            };
            let ResolvedImplMemberKind::Function(function) = &member.kind else {
                return Err(unsupported(Some(member_origin), "associated types"));
            };
            let name = member.identity.name.clone();
            if methods
                .insert((declaration, name.clone()), member.identity.clone())
                .is_some()
            {
                return Err(CheckDiagnostic {
                    kind: CheckDiagnosticKind::DuplicateMethod,
                    primary: Some(member_origin),
                    message: format!("`{}` already has a method `{name}`", types.name(owner)),
                });
            }
            functions_found.push(FoundFunction {
                name: format!("{}_{name}", types.name(owner)),
                identity: member.identity.clone(),
                function,
                origin: member_origin,
                owner: Some(owner),
            });
        }
    }

    let mut signatures = BTreeMap::new();
    for (index, found) in functions_found.iter().enumerate() {
        let signature = check_signature(
            index,
            found.function,
            &found.origin,
            found.owner,
            &nominals,
            &mut types,
        )?;
        signatures.insert(found.identity.clone(), signature);
    }

    let mut functions = Vec::new();
    for found in &functions_found {
        let (function, origin) = (found.function, &found.origin);
        let signature = &signatures[&found.identity];
        let mut checker = BodyChecker {
            types: &mut types,
            nominals: &nominals,
            signatures: &signatures,
            methods: &methods,
            library: origin.library,
            source: origin.source.clone(),
            locals: Vec::new(),
            local_ids: BTreeMap::new(),
            mutable: Vec::new(),
            loops: Vec::new(),
            result: signature.result,
            result_borrow: signature.result_borrow,
            moved: BTreeSet::new(),
            frozen: Vec::new(),
            held: Vec::new(),
            conflicts: 0,
            depth: 0,
            from_parameters: Vec::new(),
        };
        let mut parameters = Vec::new();
        for (parameter, (ty, borrow)) in function.parameters.iter().zip(&signature.parameters) {
            parameters.push(match borrow {
                Some(kind) => {
                    let local = checker.declare_borrow(&parameter.binding.identity, *ty, *kind);
                    checker.from_parameters[local] = true;
                    local
                }
                None => checker.declare(
                    &parameter.binding.identity,
                    *ty,
                    parameter.mutable.is_some(),
                ),
            });
        }
        let body = checker.check_block(&function.body, Some(signature.result))?;
        functions.push(Function {
            name: found.name.clone(),
            parameters,
            locals: checker.locals,
            result: signature.result,
            result_borrow: signature.result_borrow,
            body,
        });
    }
    let main = functions_found
        .iter()
        .position(|found| {
            found.identity.module == ModuleRef::root(project.entry)
                && found.identity.kind == EntityKind::Function
                && found.identity.name == "main"
        })
        .filter(|&index| {
            let signature = &signatures[&functions_found[index].identity];
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
    // A type that contains itself by value has no finite size. It is
    // rejected as soon as its fields are known, before anything walks them.
    if contains_by_value(types, ty, ty, &mut BTreeSet::new()) {
        return Err(CheckDiagnostic {
            kind: CheckDiagnosticKind::RecursiveType,
            primary: Some(info.origin.clone()),
            message: format!(
                "`{}` contains itself, so it has no finite size; keep the inner values in a `List` or a `Map`",
                types.name(ty)
            ),
        });
    }
    Ok(ty)
}

fn contains_by_value(types: &Types, ty: Type, target: Type, seen: &mut BTreeSet<Type>) -> bool {
    types.components(ty).into_iter().any(|component| {
        component == target
            || (seen.insert(component) && contains_by_value(types, component, target, seen))
    })
}

/// Checks the signature of a function, or of a method of `self_type`.
fn check_signature(
    index: usize,
    function: &ResolvedFunction,
    origin: &OriginRef,
    self_type: Option<Type>,
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
    let mut receiver = false;
    for parameter in &function.parameters {
        let at = Some(parameter.binding.origin.clone());
        if parameter.borrow.is_some() && parameter.mutable.is_some() {
            return Err(CheckDiagnostic {
                kind: CheckDiagnosticKind::NotAssignable,
                primary: at,
                message:
                    "a borrowed parameter cannot be `mut`; it already names the caller's place"
                        .to_owned(),
            });
        }
        // Only the `self` of a method has no written type.
        let ty = match (&parameter.annotation, self_type) {
            (Some(annotation), _) => {
                resolve_type(types, nominals, annotation, &BTreeMap::new(), origin, 0)?
            }
            (None, Some(self_type)) => {
                receiver = true;
                self_type
            }
            (None, None) => return Err(unsupported(at, "receivers outside methods")),
        };
        parameters.push((ty, parameter.borrow.map(|(_, kind)| kind)));
    }
    let result = match &function.return_type {
        Some(ty) => resolve_type(types, nominals, ty, &BTreeMap::new(), origin, 0)?,
        None => Type::UNIT,
    };
    let result_borrow = function.return_borrow.map(|(_, kind)| kind);
    if result_borrow.is_some() && !types.has_storage(result) {
        return Err(unsupported(
            Some(origin.clone()),
            "borrowed `Unit` and `Never` results",
        ));
    }
    Ok(Signature {
        index,
        receiver,
        parameters,
        result,
        result_borrow,
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
            let ResolvedReference::Exact {
                target,
                self_reference,
                ..
            } = &named.reference
            else {
                return Err(unsupported(Some(at(origin, ty.span)), "this type"));
            };
            // `Self` in an impl stands for the impl's target type.
            if target.kind == EntityKind::SelfType
                && let Some(self_target) = self_reference
                    .as_ref()
                    .and_then(|reference| reference.target.as_ref())
            {
                let self_type = ResolvedType {
                    span: ty.span,
                    kind: ResolvedTypeKind::Named(self_target.clone()),
                };
                return resolve_type(types, nominals, &self_type, substitution, origin, depth);
            }
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
            if target.kind == EntityKind::LanguageType
                && target.name == "List"
                && let [element] = arguments.as_slice()
            {
                return Ok(types.intern(TypeKind::List(*element)));
            }
            if target.kind == EntityKind::LanguageType
                && target.name == "Range"
                && let [element] = arguments.as_slice()
            {
                if *element != Type::INT {
                    return Err(unsupported(
                        Some(at(origin, ty.span)),
                        "ranges of other types than `Int`",
                    ));
                }
                return Ok(types.intern(TypeKind::Range));
            }
            if target.kind == EntityKind::LanguageType
                && matches!(target.name.as_str(), "Map" | "Set")
                && let Some(key) = arguments.first()
            {
                let kind = match (target.name.as_str(), arguments.as_slice()) {
                    ("Map", [_, value]) => TypeKind::Map(*key, *value),
                    ("Set", [_]) => TypeKind::Set(*key),
                    _ => return Err(unsupported(Some(at(origin, ty.span)), "this type")),
                };
                if !types.is_key(*key) {
                    return Err(CheckDiagnostic {
                        kind: CheckDiagnosticKind::TypeMismatch,
                        primary: Some(at(origin, ty.span)),
                        message: format!(
                            "`{}` cannot be a map key or set element; those are values compared with `==`, without `Float`",
                            types.name(*key)
                        ),
                    });
                }
                return Ok(types.intern(kind));
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
    /// The number of conflicts recorded when the loop starts.
    entry_conflicts: usize,
    /// The conflicts of the held borrows at each `break` and `continue`.
    break_conflicts: Vec<Vec<Option<Conflict>>>,
    continue_conflicts: Vec<Vec<Option<Conflict>>>,
    /// The locals that may be moved when the loop starts.
    entry_moved: BTreeSet<usize>,
    /// Locals with a smaller index are declared outside the loop.
    outer_locals: usize,
    /// The moved locals at each `break`.
    break_states: Vec<BTreeSet<usize>>,
}

/// A place, its type, and the path that loops freeze while reading it.
type PlaceAccess = (Place, Type, Vec<Option<usize>>);

/// A checked operand of a borrow, a method call or a loop.
enum Operand {
    Place(PlaceAccess),
    /// Any other expression; a borrow of it borrows a temporary.
    Value(Expr),
}

impl Operand {
    fn ty(&self) -> Type {
        match self {
            Self::Place((_, ty, _)) => *ty,
            Self::Value(value) => value.ty,
        }
    }
}

/// A checked arm pattern and the locals visible in its arm.
type ArmPattern = (Pattern, BTreeMap<EntityId, usize>);

/// A place that a running loop reads, so the loop body may not change it.
#[derive(Clone)]
struct Frozen {
    local: usize,
    /// Field indices from the local; `None` stands for any list element.
    path: Vec<Option<usize>>,
    /// Whether the borrow is `&mut`, which excludes even shared access.
    exclusive: bool,
}

/// The borrow that `let` bindings hold until their last use. A conflicting
/// access is recorded instead of rejected, and the next use of a binding
/// after it is an error; so is a conflict in a loop that uses a binding,
/// because the next iteration uses it after the conflict.
struct HeldBorrow {
    locals: Vec<usize>,
    /// The names of the bindings, to find their uses in a loop.
    names: Vec<EntityId>,
    frozen: Vec<Frozen>,
    /// The depth of the block that declares the bindings.
    depth: usize,
    /// How many loops enclose the declaration.
    loops: usize,
    /// The first conflict on some path to here.
    conflict: Option<Conflict>,
}

#[derive(Clone)]
struct Conflict {
    span: Span,
    message: String,
    /// How many conflicts were recorded before this one.
    order: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Access {
    /// A shared borrow, or a read that is not a value copy.
    Share,
    /// An assignment, a move, a `&mut` borrow or a changing method.
    Change,
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
    methods: &'a Methods,
    library: LibraryId,
    source: SourceRef,
    locals: Vec<Local>,
    local_ids: BTreeMap<EntityId, usize>,
    mutable: Vec<bool>,
    loops: Vec<LoopFrame>,
    result: Type,
    result_borrow: Option<BorrowKind>,
    /// Locals whose entity value may have been moved on some path to here.
    moved: BTreeSet<usize>,
    frozen: Vec<Frozen>,
    held: Vec<HeldBorrow>,
    /// How many conflicts with held borrows have been recorded.
    conflicts: usize,
    /// How many blocks enclose the statement being checked.
    depth: usize,
    /// For each local, whether it is a borrow that reaches only places of
    /// the parameters passed by borrow, so the function may return it.
    from_parameters: Vec<bool>,
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
        self.declare_local(identity, ty, mutable, None)
    }

    /// Declares a binding of a part of type `ty` that a pattern or loop
    /// reaches with `mode`: a copy or move without it, otherwise a pointer
    /// into the place. A value read through `&` is copied instead.
    fn declare_binding(
        &mut self,
        identity: &EntityId,
        ty: Type,
        mode: Option<BorrowKind>,
    ) -> usize {
        match mode {
            Some(kind) if kind == BorrowKind::Mutable || self.types.is_entity(ty) => {
                self.declare_borrow(identity, ty, kind)
            }
            _ => self.declare(identity, ty, false),
        }
    }

    /// Checks that `place` may be borrowed with `kind` now: `&mut` needs a
    /// changeable place, and neither may conflict with a running borrow.
    fn check_borrow(
        &mut self,
        place: &Place,
        path: &[Option<usize>],
        kind: BorrowKind,
        span: Span,
    ) -> Result<(), CheckDiagnostic> {
        self.check_borrow_except(&[], place, path, kind, span)
    }

    /// Like [`Self::check_borrow`], ignoring the running borrows at the
    /// positions `skip` of the borrow stack.
    fn check_borrow_except(
        &mut self,
        skip: &[usize],
        place: &Place,
        path: &[Option<usize>],
        kind: BorrowKind,
        span: Span,
    ) -> Result<(), CheckDiagnostic> {
        if kind == BorrowKind::Mutable && !self.mutable[place.local] {
            let name = &self.locals[place.local].name;
            let message = if place.call.is_some() {
                format!("`{name}` returns `&`, so its result cannot be borrowed with `&mut`")
            } else {
                format!("`{name}` is not declared `mut`, so it cannot be borrowed with `&mut`")
            };
            return Err(self.error(CheckDiagnosticKind::NotAssignable, span, message));
        }
        let access = match kind {
            BorrowKind::Shared => Access::Share,
            BorrowKind::Mutable => Access::Change,
        };
        self.check_access_except(skip, place.local, path, access, span)
    }

    /// Declares a local that points at a borrowed place; through `&mut` the
    /// place can be changed.
    fn declare_borrow(&mut self, identity: &EntityId, ty: Type, kind: BorrowKind) -> usize {
        self.declare_local(identity, ty, kind == BorrowKind::Mutable, Some(kind))
    }

    fn declare_local(
        &mut self,
        identity: &EntityId,
        ty: Type,
        mutable: bool,
        borrow: Option<BorrowKind>,
    ) -> usize {
        let index = self.push_local(identity.name.clone(), ty, mutable, borrow);
        self.local_ids.insert(identity.clone(), index);
        index
    }

    /// Adds a local that no name in the source refers to.
    fn push_local(
        &mut self,
        name: String,
        ty: Type,
        mutable: bool,
        borrow: Option<BorrowKind>,
    ) -> usize {
        let index = self.locals.len();
        self.locals.push(Local { name, ty, borrow });
        self.mutable.push(mutable);
        self.from_parameters.push(false);
        index
    }

    /// Records that the borrowed ones of `locals` reach what `root` reaches.
    fn borrow_from(&mut self, locals: &[usize], root: Option<usize>) {
        let reaches = root.is_some_and(|root| self.from_parameters[root]);
        for &local in locals {
            if self.locals[local].borrow.is_some() {
                self.from_parameters[local] = reaches;
            }
        }
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

    /// Rejects a use of `local` after its value may have been moved, or
    /// after a conflict with the borrow it holds.
    fn use_local(&self, local: usize, span: Span) -> Result<(), CheckDiagnostic> {
        if self.moved.contains(&local) {
            return Err(self.error(
                CheckDiagnosticKind::UseAfterMove,
                span,
                format!(
                    "`{}` is used after its value may have been moved",
                    self.locals[local].name
                ),
            ));
        }
        self.check_held_use(local)
    }

    /// Rejects a use of a `let` borrow binding after a conflict with its
    /// borrow; the error points at the conflict.
    fn check_held_use(&self, local: usize) -> Result<(), CheckDiagnostic> {
        for held in &self.held {
            if held.locals.contains(&local)
                && let Some(conflict) = &held.conflict
            {
                return Err(self.error(
                    CheckDiagnosticKind::BorrowConflict,
                    conflict.span,
                    format!(
                        "{}, and `{}` is used later",
                        conflict.message, self.locals[local].name
                    ),
                ));
            }
        }
        Ok(())
    }

    /// Turns `expression` into a value that its consumer owns: an entity
    /// local is moved, and an entity inside a field or element is rejected.
    fn consume(&mut self, expression: Expr, span: Span) -> Result<Expr, CheckDiagnostic> {
        if !self.types.is_entity(expression.ty) {
            return Ok(expression);
        }
        match expression.kind {
            ExprKind::Local(_)
            | ExprKind::Field { .. }
            | ExprKind::Index { .. }
            | ExprKind::Call {
                borrow: Some(_), ..
            } => {
                // Moving a part moves the whole variable.
                let (local, fields) = self.movable_part(&expression, expression.ty, span)?;
                let path = fields.iter().copied().map(Some).collect::<Vec<_>>();
                self.check_not_frozen(local, &path, span)?;
                self.moved.insert(local);
                Ok(Expr {
                    ty: expression.ty,
                    kind: ExprKind::Move(Place {
                        local,
                        call: None,
                        projections: fields.into_iter().map(Projection::Field).collect(),
                    }),
                })
            }
            _ => Ok(expression),
        }
    }

    /// The local and the fields from it that `expression` reads, if a `ty`
    /// can be moved out of there: a local the function owns, or a part of
    /// one reached through fields only.
    fn movable_part(
        &self,
        expression: &Expr,
        ty: Type,
        span: Span,
    ) -> Result<(usize, Vec<usize>), CheckDiagnostic> {
        let name = || self.types.name(ty);
        match &expression.kind {
            ExprKind::Local(local) if self.locals[*local].borrow.is_some() => Err(self.error(
                CheckDiagnosticKind::CannotMove,
                span,
                format!(
                    "`{}` is borrowed, so its `{}` cannot be moved; use `clone()`",
                    self.locals[*local].name,
                    name()
                ),
            )),
            ExprKind::Local(local) => Ok((*local, Vec::new())),
            ExprKind::Field { base, index } => {
                let (local, mut fields) = self.movable_part(base, ty, span)?;
                fields.push(*index);
                Ok((local, fields))
            }
            ExprKind::Call {
                borrow: Some(_), ..
            } => Err(self.error(
                CheckDiagnosticKind::CannotMove,
                span,
                format!(
                    "this call returns a borrow, so its `{}` cannot be moved; use `clone()`",
                    name()
                ),
            )),
            _ => Err(self.error(
                CheckDiagnosticKind::CannotMove,
                span,
                format!(
                    "a `{}` cannot be moved out of an element or a temporary; use `clone()`, or take it with `remove` or `replace`",
                    name()
                ),
            )),
        }
    }

    fn check_consumed(
        &mut self,
        expression: &ResolvedExpr,
        expected: Option<Type>,
    ) -> Result<Expr, CheckDiagnostic> {
        let checked = self.check_expr(expression, expected)?;
        self.consume(checked, expression.span)
    }

    /// Checks an access to `local` along `path` against the borrows of
    /// overlapping places: any change conflicts with a borrow, and a shared
    /// access conflicts with an exclusive one. Reading a value never
    /// conflicts. A conflict with a running borrow is rejected; one with a
    /// held borrow is recorded for its later uses.
    fn check_access(
        &mut self,
        local: usize,
        path: &[Option<usize>],
        access: Access,
        span: Span,
    ) -> Result<(), CheckDiagnostic> {
        self.check_access_except(&[], local, path, access, span)
    }

    /// Like [`Self::check_access`], ignoring the running borrows at the
    /// positions `skip` of the borrow stack.
    fn check_access_except(
        &mut self,
        skip: &[usize],
        local: usize,
        path: &[Option<usize>],
        access: Access,
        span: Span,
    ) -> Result<(), CheckDiagnostic> {
        let conflicts = |frozen: &Frozen| {
            frozen.local == local
                && (access == Access::Change || frozen.exclusive)
                && frozen
                    .path
                    .iter()
                    .zip(path)
                    .all(|(left, right)| left.is_none() || right.is_none() || left == right)
        };
        let what = if access == Access::Change {
            "change"
        } else {
            "be borrowed"
        };
        let name = &self.locals[local].name;
        if self
            .frozen
            .iter()
            .enumerate()
            .any(|(position, frozen)| !skip.contains(&position) && conflicts(frozen))
        {
            return Err(self.error(
                CheckDiagnosticKind::BorrowConflict,
                span,
                format!("`{name}` cannot {what} while it is borrowed"),
            ));
        }
        let mut recorded = false;
        for held in &mut self.held {
            if held.conflict.is_none() && held.frozen.iter().any(conflicts) {
                held.conflict = Some(Conflict {
                    span,
                    message: format!("`{name}` cannot {what} while it is borrowed"),
                    order: self.conflicts,
                });
                recorded = true;
            }
        }
        if recorded {
            self.conflicts += 1;
        }
        Ok(())
    }

    fn check_not_frozen(
        &mut self,
        local: usize,
        path: &[Option<usize>],
        span: Span,
    ) -> Result<(), CheckDiagnostic> {
        self.check_access(local, path, Access::Change, span)
    }

    /// Ends the body of the innermost loop. `reaches_end` tells whether an
    /// iteration can finish normally, and `head` is the state where the loop
    /// may stop between iterations (`None` for `loop`). A conflict that
    /// reaches the next iteration, with a borrow held from outside that each
    /// iteration uses as `mentions` tells, is an error. Afterwards the held
    /// borrows have the conflicts that reach the code after the loop.
    fn end_loop_conflicts(
        &mut self,
        reaches_end: bool,
        head: Option<Vec<Option<Conflict>>>,
        mentions: impl Fn(&[EntityId]) -> bool,
    ) -> Result<(), CheckDiagnostic> {
        let loops = self.loops.len();
        let frame = self.loops.last().expect("inside a loop");
        let mut back = frame.continue_conflicts.clone();
        if reaches_end {
            back.push(self.held_conflicts());
        }
        let back = self.joined_conflicts(&back);
        for (held, conflict) in self.held.iter().zip(&back) {
            if held.loops < loops
                && let Some(conflict) = conflict
                && conflict.order >= frame.entry_conflicts
                && mentions(&held.names)
            {
                return Err(self.error(
                    CheckDiagnosticKind::BorrowConflict,
                    conflict.span,
                    format!(
                        "{}, and `{}` is used in the next iteration",
                        conflict.message, self.locals[held.locals[0]].name
                    ),
                ));
            }
        }
        let mut exits = frame.break_conflicts.clone();
        if let Some(head) = head {
            exits.push(head);
            exits.push(back);
        }
        if !exits.is_empty() {
            let after = self.joined_conflicts(&exits);
            self.set_held_conflicts(&after);
        }
        Ok(())
    }

    /// The conflicts of the held borrows, to check branches from the same
    /// state.
    fn held_conflicts(&self) -> Vec<Option<Conflict>> {
        self.held.iter().map(|held| held.conflict.clone()).collect()
    }

    fn set_held_conflicts(&mut self, conflicts: &[Option<Conflict>]) {
        for (held, conflict) in self.held.iter_mut().zip(conflicts) {
            held.conflict = conflict.clone();
        }
    }

    /// Where paths join, a held borrow has a conflict if it has one on some
    /// path. A state taken inside a nested block may hold more borrows,
    /// which have ended by now.
    fn joined_conflicts(&self, states: &[Vec<Option<Conflict>>]) -> Vec<Option<Conflict>> {
        (0..self.held.len())
            .map(|position| states.iter().find_map(|state| state[position].clone()))
            .collect()
    }

    /// Joins the conflicts at the ends of branches; a branch of type
    /// `Never` does not reach the join.
    fn join_branch_conflicts(&mut self, branches: &[(Type, Vec<Option<Conflict>>)]) {
        let reaching = branches
            .iter()
            .filter(|(ty, _)| *ty != Type::NEVER)
            .map(|(_, state)| state.clone())
            .collect::<Vec<_>>();
        let joined = if reaching.is_empty() {
            let all = branches
                .iter()
                .map(|(_, state)| state.clone())
                .collect::<Vec<_>>();
            self.joined_conflicts(&all)
        } else {
            self.joined_conflicts(&reaching)
        };
        self.set_held_conflicts(&joined);
    }
    /// Ends one path through a loop body: an outer local that the next
    /// iteration would see moved is an error.
    fn check_loop_back(&self, span: Span) -> Result<(), CheckDiagnostic> {
        let frame = self.loops.last().expect("inside a loop");
        if let Some(&local) = self
            .moved
            .iter()
            .find(|local| **local < frame.outer_locals && !frame.entry_moved.contains(local))
        {
            return Err(self.error(
                CheckDiagnosticKind::UseAfterMove,
                span,
                format!(
                    "`{}` is moved in one loop iteration and would be used in the next",
                    self.locals[local].name
                ),
            ));
        }
        Ok(())
    }

    fn enter_loop(&mut self) {
        self.loops.push(LoopFrame {
            breaks: false,
            entry_conflicts: self.conflicts,
            break_conflicts: Vec::new(),
            continue_conflicts: Vec::new(),
            entry_moved: self.moved.clone(),
            outer_locals: self.locals.len(),
            break_states: Vec::new(),
        });
    }

    /// Leaves a loop. After it, a local is moved if it was when the loop
    /// started or at some `break`.
    fn exit_loop(&mut self) -> LoopFrame {
        let frame = self.loops.pop().expect("the loop frame was pushed");
        let mut moved = frame.entry_moved.clone();
        for state in &frame.break_states {
            moved.extend(state.iter().copied());
        }
        self.moved = moved;
        frame
    }

    fn check_block(
        &mut self,
        block: &ResolvedBlock,
        expected: Option<Type>,
    ) -> Result<Block, CheckDiagnostic> {
        let scope = self.local_ids.clone();
        let mut statements = Vec::new();
        let mut diverges = false;
        self.depth += 1;
        for statement in &block.statements {
            let frozen_before = self.frozen.len();
            let (statement, statement_diverges) = self.check_statement(statement)?;
            diverges |= statement_diverges;
            statements.push(statement);
            self.frozen.truncate(frozen_before);
        }
        let (tail, ty) = match &block.tail {
            Some(tail) => {
                let discard = expected == Some(Type::UNIT);
                // The tail of the function body is its result.
                let tail = match self.result_borrow {
                    Some(kind) if self.depth == 1 => self.check_returned_borrow(tail, kind)?,
                    _ => self.check_consumed(tail, expected)?,
                };
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
        let depth = self.depth;
        self.held.retain(|held| held.depth != depth);
        self.depth -= 1;
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
            ResolvedStatementKind::Let { .. } => self.check_let(statement),
            ResolvedStatementKind::Assignment {
                target,
                operator: (operator_span, operator),
                value,
            } => {
                let (place, ty) = self.check_place(target, true)?;
                let value = self.check_consumed(value, Some(ty))?;
                self.require(span, ty, value.ty)?;
                if *operator != AssignmentOperator::Assign && !matches!(ty, Type::INT | Type::FLOAT)
                {
                    return Err(self.mismatch(*operator_span, Type::INT, ty));
                }
                if place.projections.is_empty() {
                    self.moved.remove(&place.local);
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
                let value = match (value, self.result_borrow) {
                    (Some(value), Some(kind)) => Some(self.check_returned_borrow(value, kind)?),
                    (Some(value), None) => {
                        let checked = self.check_consumed(value, Some(self.result))?;
                        self.require(value.span, self.result, checked.ty)?;
                        Some(checked)
                    }
                    (None, _) => {
                        self.require(span, self.result, Type::UNIT)?;
                        None
                    }
                };
                Ok((Statement::Return(value), true))
            }
            ResolvedStatementKind::Break | ResolvedStatementKind::Continue => {
                let is_break = matches!(statement.kind, ResolvedStatementKind::Break);
                let conflicts = self.held_conflicts();
                let Some(frame) = self.loops.last_mut() else {
                    return Err(self.error(
                        CheckDiagnosticKind::OutsideLoop,
                        span,
                        "`break` and `continue` must be inside a loop".to_owned(),
                    ));
                };
                if is_break {
                    frame.breaks = true;
                    frame.break_states.push(self.moved.clone());
                    frame.break_conflicts.push(conflicts);
                    Ok((Statement::Break, true))
                } else {
                    frame.continue_conflicts.push(conflicts);
                    self.check_loop_back(span)?;
                    Ok((Statement::Continue, true))
                }
            }
            ResolvedStatementKind::While { condition, body } => {
                self.enter_loop();
                let checked = self.check_condition(condition);
                let checked = checked.and_then(|checked| {
                    let head = self.held_conflicts();
                    let checked_body = self.check_block(body, Some(Type::UNIT))?;
                    let reaches_end = checked_body.ty != Type::NEVER;
                    if reaches_end {
                        self.check_loop_back(span)?;
                    }
                    self.end_loop_conflicts(reaches_end, Some(head), |names| {
                        statement_mentions(statement, names)
                    })?;
                    Ok((checked, checked_body))
                });
                self.exit_loop();
                let (condition, body) = checked?;
                Ok((Statement::While { condition, body }, false))
            }
            ResolvedStatementKind::Loop(body) => {
                self.enter_loop();
                let body = self.check_block(body, Some(Type::UNIT)).and_then(|body| {
                    let reaches_end = body.ty != Type::NEVER;
                    if reaches_end {
                        self.check_loop_back(span)?;
                    }
                    self.end_loop_conflicts(reaches_end, None, |names| {
                        statement_mentions(statement, names)
                    })?;
                    Ok(body)
                });
                let frame = self.exit_loop();
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
            ResolvedStatementKind::For {
                bindings,
                iterable,
                body,
            } => self.check_for(statement, bindings, iterable, body),
        }
    }

    /// Checks a `let` statement. A value written `&place` or `&mut place`, or
    /// a call that returns a borrow, makes the bindings point into the place,
    /// which stays borrowed until their last use.
    fn check_let(
        &mut self,
        statement: &ResolvedStatement,
    ) -> Result<(Statement, bool), CheckDiagnostic> {
        let span = statement.span;
        let ResolvedStatementKind::Let {
            bindings,
            pattern,
            mutable,
            annotation_borrow,
            annotation,
            value,
        } = &statement.kind
        else {
            unreachable!("only `let` statements are checked here")
        };
        let expected = match annotation {
            Some(annotation) => Some(self.resolve_type(annotation, &BTreeMap::new())?),
            None => None,
        };
        // `&place`, `&mut place`, or a call that returns a borrow, binds a
        // borrow. Any other call is checked here and used below.
        let frozen_before = self.frozen.len();
        let mut checked = None;
        let borrowed = match &value.kind {
            ResolvedExprKind::Borrow {
                kind: (_, kind),
                operand,
            } => match self.check_operand(operand, None)? {
                Operand::Place(access) => Some((*kind, access, operand.span)),
                Operand::Value(_) => {
                    return Err(self.unsupported(operand.span, "borrowed bindings of temporaries"));
                }
            },
            ResolvedExprKind::Call { .. } | ResolvedExprKind::MethodCall { .. } => {
                match self.check_operand(value, expected)? {
                    Operand::Place(access) => {
                        let kind = self.locals[access.0.local]
                            .borrow
                            .expect("the result of a call is a borrowed place");
                        Some((kind, access, value.span))
                    }
                    Operand::Value(call) => {
                        checked = Some(call);
                        None
                    }
                }
            }
            _ => None,
        };
        if let Some((kind, (place, ty, path), operand_span)) = borrowed {
            if let Some(mutable) = mutable {
                return Err(self.error(
                    CheckDiagnosticKind::NotAssignable,
                    *mutable,
                    "a borrowed binding cannot be `mut`; it always names the place it borrows"
                        .to_owned(),
                ));
            }
            if let Some((annotation_span, written)) = annotation_borrow
                && *written != kind
            {
                return Err(self.error(
                    CheckDiagnosticKind::TypeMismatch,
                    *annotation_span,
                    "the annotation and the value borrow in different ways".to_owned(),
                ));
            }
            if let Some(expected) = expected {
                self.require(operand_span, expected, ty)?;
            }
            self.check_borrow(&place, &path, kind, operand_span)?;
            let root = place.local;
            let mut frozen = self.held_frozen(root, path, kind);
            frozen.extend(self.take_frozen(frozen_before));
            let target = Expr {
                ty,
                kind: ExprKind::Borrow(Box::new(BorrowTarget::Place(place))),
            };
            let (statement, mut locals) = match pattern {
                Some(pattern) => {
                    let pattern =
                        self.check_pattern(pattern, ty, Some(kind), &mut BTreeMap::new())?;
                    self.require_exhaustive(span, &pattern, ty)?;
                    let locals = pattern.bindings();
                    (
                        Statement::LetPattern {
                            pattern,
                            value: target,
                        },
                        locals,
                    )
                }
                None => {
                    let [binding] = bindings.as_slice() else {
                        unreachable!("a let without a pattern binds one name")
                    };
                    let local = self.declare_borrow(&binding.identity, ty, kind);
                    (
                        Statement::Let {
                            local,
                            value: target,
                        },
                        vec![local],
                    )
                }
            };
            locals.retain(|&local| self.locals[local].borrow.is_some());
            self.borrow_from(&locals, Some(root));
            if !locals.is_empty() {
                let names = bindings
                    .iter()
                    .map(|binding| binding.identity.clone())
                    .collect::<Vec<_>>();
                self.held.push(HeldBorrow {
                    locals,
                    names,
                    frozen,
                    depth: self.depth,
                    loops: self.loops.len(),
                    conflict: None,
                });
            }
            return Ok((statement, false));
        }
        if let Some((annotation_span, _)) = annotation_borrow {
            return Err(self.error(
                CheckDiagnosticKind::TypeMismatch,
                *annotation_span,
                "this binding borrows its value; write `&` or `&mut` before the value".to_owned(),
            ));
        }
        let value_span = value.span;
        if let Some(pattern) = pattern {
            let value = match checked {
                Some(value) => value,
                None => self.check_expr(value, None)?,
            };
            if value.ty == Type::NEVER {
                return Ok((Statement::Expr(value), true));
            }
            let pattern = self.check_pattern(pattern, value.ty, None, &mut BTreeMap::new())?;
            self.require_exhaustive(span, &pattern, value.ty)?;
            let value = if self.binds_entity(&pattern) {
                self.consume(value, value_span)?
            } else {
                value
            };
            return Ok((Statement::LetPattern { pattern, value }, false));
        }
        let [binding] = bindings.as_slice() else {
            unreachable!("a let without a pattern binds one name")
        };
        let value = match checked {
            Some(value) => self.consume(value, value_span)?,
            None => self.check_consumed(value, expected)?,
        };
        if let Some(expected) = expected {
            self.require(span, expected, value.ty)?;
        }
        let ty = expected.unwrap_or(value.ty);
        let diverges = value.ty == Type::NEVER;
        let local = self.declare(&binding.identity, ty, mutable.is_some());
        Ok((Statement::Let { local, value }, diverges))
    }

    /// Checks a value returned by a function whose result is borrowed with
    /// `kind`: `&place`, `&mut place`, or a call that returns a borrow, all
    /// reaching only places of the parameters passed by borrow.
    fn check_returned_borrow(
        &mut self,
        value: &ResolvedExpr,
        kind: BorrowKind,
    ) -> Result<Expr, CheckDiagnostic> {
        let (place, ty, path, span) = match &value.kind {
            ResolvedExprKind::Parenthesized(inner) => {
                return self.check_returned_borrow(inner, kind);
            }
            ResolvedExprKind::Borrow {
                kind: (_, written),
                operand,
            } => {
                if *written != kind {
                    return Err(self.error(
                        CheckDiagnosticKind::TypeMismatch,
                        value.span,
                        "the value borrows differently from the declared result".to_owned(),
                    ));
                }
                match self.check_operand(operand, None)? {
                    Operand::Place((place, ty, path)) => (place, ty, path, operand.span),
                    Operand::Value(_) => {
                        return Err(self.error(
                            CheckDiagnosticKind::BorrowOutlives,
                            operand.span,
                            "a returned borrow cannot name a temporary, which ends when the function returns"
                                .to_owned(),
                        ));
                    }
                }
            }
            _ => match self.check_operand(value, None)? {
                Operand::Place((place, ty, path))
                    if place.call.is_some() && place.projections.is_empty() =>
                {
                    (place, ty, path, value.span)
                }
                Operand::Value(checked) if checked.ty == Type::NEVER => return Ok(checked),
                _ => {
                    return Err(self.error(
                        CheckDiagnosticKind::TypeMismatch,
                        value.span,
                        "this function returns a borrow; return `&place`, `&mut place` or a call that returns a borrow".to_owned(),
                    ));
                }
            },
        };
        self.require(span, self.result, ty)?;
        self.check_borrow(&place, &path, kind, span)?;
        if !self.from_parameters[place.local] {
            return Err(self.error(
                CheckDiagnosticKind::BorrowOutlives,
                span,
                format!(
                    "a returned borrow must come from a parameter passed by borrow; `{}` ends when the function returns",
                    self.locals[place.local].name
                ),
            ));
        }
        Ok(Expr {
            ty,
            kind: ExprKind::Borrow(Box::new(BorrowTarget::Place(place))),
        })
    }

    fn require_exhaustive(
        &self,
        span: Span,
        pattern: &Pattern,
        ty: Type,
    ) -> Result<(), CheckDiagnostic> {
        match exhaustive::missing(self.types, &[pattern], ty) {
            Some(missing) => Err(self.error(
                CheckDiagnosticKind::NonExhaustive,
                span,
                format!("this destructuring does not cover `{missing}`"),
            )),
            None => Ok(()),
        }
    }

    /// What a new `let` borrow of `local` along `path` holds: that place, and
    /// what the held borrow that `local` belongs to holds.
    fn held_frozen(&self, local: usize, path: Vec<Option<usize>>, kind: BorrowKind) -> Vec<Frozen> {
        let exclusive = kind == BorrowKind::Mutable;
        let mut frozen = vec![Frozen {
            local,
            path,
            exclusive,
        }];
        for held in self.held.iter().filter(|held| held.locals.contains(&local)) {
            frozen.extend(held.frozen.iter().map(|inner| Frozen {
                exclusive: inner.exclusive && exclusive,
                ..inner.clone()
            }));
        }
        frozen
    }

    /// Takes the running borrows from position `base` of the borrow stack,
    /// which the calls in a `let` value made, so the `let` holds them.
    fn take_frozen(&mut self, base: usize) -> Vec<Frozen> {
        let mut frozen = Vec::new();
        for taken in self.frozen.split_off(base) {
            let kind = if taken.exclusive {
                BorrowKind::Mutable
            } else {
                BorrowKind::Shared
            };
            frozen.extend(self.held_frozen(taken.local, taken.path, kind));
        }
        frozen
    }

    fn check_for(
        &mut self,
        statement: &ResolvedStatement,
        bindings: &[crate::project::ResolvedBinding],
        iterable: &ResolvedExpr,
        body: &ResolvedBlock,
    ) -> Result<(Statement, bool), CheckDiagnostic> {
        let span = statement.span;
        let (source, element, frozen, mode) = match &iterable.kind {
            ResolvedExprKind::Binary {
                left,
                operator:
                    (
                        _,
                        operator
                        @ (BinaryOperator::RangeExclusive | BinaryOperator::RangeInclusive),
                    ),
                right,
            } => {
                let start = self.check_expr(left, Some(Type::INT))?;
                self.require(left.span, Type::INT, start.ty)?;
                let end = self.check_expr(right, Some(Type::INT))?;
                self.require(right.span, Type::INT, end.ty)?;
                let source = ForSource::Range {
                    start,
                    end,
                    inclusive: *operator == BinaryOperator::RangeInclusive,
                };
                (source, Type::INT, None, None)
            }
            ResolvedExprKind::Borrow {
                kind: (_, kind),
                operand,
            } => {
                let kind = *kind;
                let Operand::Place((place, ty, path)) = self.check_operand(operand, None)? else {
                    return Err(self.unsupported(operand.span, "borrowing loops over temporaries"));
                };
                // A borrowed map yields its values, and a set copies its
                // elements, which cannot change in place.
                let element = match *self.types.kind(ty) {
                    TypeKind::List(element) | TypeKind::Map(_, element) => element,
                    TypeKind::Set(element) if kind == BorrowKind::Shared => element,
                    TypeKind::Set(_) => {
                        return Err(self.error(
                            CheckDiagnosticKind::TypeMismatch,
                            operand.span,
                            "the elements of a `Set` cannot be changed in place; loop over `&` instead"
                                .to_owned(),
                        ));
                    }
                    _ => {
                        return Err(self.error(
                            CheckDiagnosticKind::TypeMismatch,
                            operand.span,
                            format!("`for` cannot iterate over `{}`", self.types.name(ty)),
                        ));
                    }
                };
                self.check_borrow(&place, &path, kind, operand.span)?;
                let frozen = Frozen {
                    local: place.local,
                    path,
                    exclusive: kind == BorrowKind::Mutable,
                };
                (
                    ForSource::Borrowed(place),
                    element,
                    Some(frozen),
                    Some(kind),
                )
            }
            _ => {
                let value = self.check_expr(iterable, None)?;
                // A taken map yields `(key, value)`.
                let element = match *self.types.kind(value.ty) {
                    TypeKind::Range => None,
                    TypeKind::List(element) | TypeKind::Set(element) => Some(element),
                    TypeKind::Map(key, element) => {
                        Some(self.types.intern(TypeKind::Tuple(vec![key, element])))
                    }
                    _ => {
                        return Err(self.error(
                            CheckDiagnosticKind::TypeMismatch,
                            iterable.span,
                            format!("`for` cannot iterate over `{}`", self.types.name(value.ty)),
                        ));
                    }
                };
                match element {
                    None => (ForSource::RangeValue(value), Type::INT, None, None),
                    Some(element) => {
                        let value = self.consume(value, iterable.span)?;
                        (
                            ForSource::Taken {
                                container: value,
                                element,
                            },
                            element,
                            None,
                            None,
                        )
                    }
                }
            }
        };
        let scope = self.local_ids.clone();
        self.enter_loop();
        let binding = match bindings {
            [single] => Ok(Pattern::Binding(self.declare_binding(
                &single.identity,
                element,
                mode,
            ))),
            many => match self.types.kind(element).clone() {
                TypeKind::Tuple(elements) if elements.len() == many.len() => Ok(Pattern::Tuple(
                    many.iter()
                        .zip(elements)
                        .map(|(binding, ty)| {
                            Pattern::Binding(self.declare_binding(&binding.identity, ty, mode))
                        })
                        .collect(),
                )),
                _ => Err(self.error(
                    CheckDiagnosticKind::TypeMismatch,
                    span,
                    format!(
                        "the elements are `{}`, not a tuple of {}",
                        self.types.name(element),
                        many.len()
                    ),
                )),
            },
        };
        if let Ok(binding) = &binding {
            self.borrow_from(&binding.bindings(), frozen.as_ref().map(|f| f.local));
        }
        let has_frozen = frozen.is_some();
        if let Some(frozen) = frozen {
            self.frozen.push(frozen);
        }
        let body = binding.and_then(|checked| {
            let head = self.held_conflicts();
            let checked_body = self.check_block(body, Some(Type::UNIT))?;
            let reaches_end = checked_body.ty != Type::NEVER;
            if reaches_end {
                self.check_loop_back(span)?;
            }
            // A range or a taken list is evaluated once; a borrowed one is
            // used by every iteration.
            self.end_loop_conflicts(reaches_end, Some(head), |names| {
                block_mentions(body, names) || (has_frozen && expr_mentions(iterable, names))
            })?;
            Ok((checked, checked_body))
        });
        if has_frozen {
            self.frozen.pop();
        }
        self.exit_loop();
        self.local_ids = scope;
        let (binding, body) = body?;
        Ok((
            Statement::For {
                binding,
                source,
                body,
            },
            false,
        ))
    }

    /// Checks an expression that may be borrowed or used as a receiver. A
    /// local followed by field, tuple-element and index accesses is a place,
    /// returned with the path that loops freeze; so is a call that returns a
    /// borrow, and the parts of such a place. Anything else is a value,
    /// checked against `expected`.
    fn check_operand(
        &mut self,
        expression: &ResolvedExpr,
        expected: Option<Type>,
    ) -> Result<Operand, CheckDiagnostic> {
        let span = expression.span;
        match &expression.kind {
            ResolvedExprKind::Path(ResolvedReference::Exact { target, .. })
                if let Some(&local) = self.local_ids.get(target) =>
            {
                self.use_local(local, span)?;
                Ok(Operand::Place((
                    Place {
                        local,
                        call: None,
                        projections: Vec::new(),
                    },
                    self.locals[local].ty,
                    Vec::new(),
                )))
            }
            ResolvedExprKind::Call { callee, .. } => {
                let call = self.check_expr(expression, expected)?;
                Ok(self.call_operand(call, callee_name(callee)))
            }
            ResolvedExprKind::MethodCall { method, .. } => {
                let call = self.check_expr(expression, expected)?;
                Ok(self.call_operand(call, method.name.clone()))
            }
            ResolvedExprKind::Parenthesized(inner) => self.check_operand(inner, expected),
            ResolvedExprKind::Field { receiver, field } => {
                let base = self.check_operand(receiver, None)?;
                let (index, ty) = self.named_field(base.ty(), &field.name, field.origin.span)?;
                Ok(self.project(base, Projection::Field(index), Some(index), ty))
            }
            ResolvedExprKind::TupleField {
                receiver,
                index,
                origin,
            } => {
                let base = self.check_operand(receiver, None)?;
                let (index, ty) = self.tuple_element(base.ty(), index, origin.span)?;
                Ok(self.project(base, Projection::Field(index), Some(index), ty))
            }
            ResolvedExprKind::Index { receiver, index } => {
                let base = self.check_operand(receiver, None)?;
                let (element, index) = self.check_subscript(base.ty(), receiver.span, index)?;
                Ok(self.project(base, Projection::Index(Box::new(index)), None, element))
            }
            _ => Ok(Operand::Value(self.check_expr(expression, expected)?)),
        }
    }

    /// A call that returns a borrow is a place, reached through a local
    /// named after the function; any other call is a value.
    fn call_operand(&mut self, call: Expr, name: String) -> Operand {
        let ExprKind::Call {
            borrow: Some(kind), ..
        } = call.kind
        else {
            return Operand::Value(call);
        };
        let ty = call.ty;
        let local = self.push_local(name, ty, kind == BorrowKind::Mutable, Some(kind));
        self.from_parameters[local] = self.call_from_parameters(&call);
        Operand::Place((
            Place {
                local,
                call: Some(Box::new(call)),
                projections: Vec::new(),
            },
            ty,
            Vec::new(),
        ))
    }

    /// A part of type `ty` of `base`: a part of a place is a place, `step`
    /// extending its loop path; a part of a value is read from it.
    fn project(
        &self,
        base: Operand,
        projection: Projection,
        step: Option<usize>,
        ty: Type,
    ) -> Operand {
        match base {
            Operand::Place((mut place, _, mut path)) => {
                place.projections.push(projection);
                path.push(step);
                Operand::Place((place, ty, path))
            }
            Operand::Value(base) => {
                let base = Box::new(base);
                let kind = match projection {
                    Projection::Field(index) => ExprKind::Field { base, index },
                    Projection::Index(index) => ExprKind::Index { base, index },
                };
                Operand::Value(Expr { ty, kind })
            }
        }
    }

    /// The value a place holds, as an expression that reads it.
    fn place_value(&self, place: Place) -> Expr {
        let mut value = match place.call {
            Some(call) => *call,
            None => Expr {
                ty: self.locals[place.local].ty,
                kind: ExprKind::Local(place.local),
            },
        };
        for projection in place.projections {
            let base = Box::new(value);
            value = match projection {
                Projection::Field(index) => Expr {
                    ty: self.types.components(base.ty)[index],
                    kind: ExprKind::Field { base, index },
                },
                Projection::Index(index) => Expr {
                    ty: self.list_element_type(base.ty),
                    kind: ExprKind::Index { base, index },
                },
            };
        }
        value
    }

    fn list_element_type(&self, ty: Type) -> Type {
        match self.types.kind(ty) {
            TypeKind::List(element) | TypeKind::Map(_, element) => *element,
            _ => unreachable!("only lists and maps are indexed"),
        }
    }

    /// Checks `container[index]`: an `Int` index into a list, or a key into
    /// a map. Returns the element type and the checked index.
    fn check_subscript(
        &mut self,
        container: Type,
        span: Span,
        index: &ResolvedExpr,
    ) -> Result<(Type, Expr), CheckDiagnostic> {
        let (key, element) = match *self.types.kind(container) {
            TypeKind::List(element) => (Type::INT, element),
            TypeKind::Map(key, value) => (key, value),
            _ => {
                return Err(self.error(
                    CheckDiagnosticKind::TypeMismatch,
                    span,
                    format!("`{}` cannot be indexed", self.types.name(container)),
                ));
            }
        };
        let checked = self.check_expr(index, Some(key))?;
        self.require(index.span, key, checked.ty)?;
        Ok((element, checked))
    }

    /// Checks an assignment target and returns it with its type. Assigning
    /// a whole local is allowed after its value was moved.
    fn check_place(
        &mut self,
        target: &ResolvedPlace,
        reinitializes: bool,
    ) -> Result<(Place, Type), CheckDiagnostic> {
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
        if !(reinitializes && target.projections.is_empty()) {
            self.use_local(local, target.span)?;
        }
        // Assigning through a borrow binding uses it.
        self.check_held_use(local)?;
        let mut ty = self.locals[local].ty;
        let mut projections = Vec::new();
        let mut path = Vec::new();
        for projection in &target.projections {
            match projection {
                ResolvedPlaceProjection::Field(selection) => {
                    let (index, field_ty) =
                        self.named_field(ty, &selection.name, selection.origin.span)?;
                    projections.push(Projection::Field(index));
                    path.push(Some(index));
                    ty = field_ty;
                }
                ResolvedPlaceProjection::TupleField { index, origin } => {
                    let (index, field_ty) = self.tuple_element(ty, index, origin.span)?;
                    projections.push(Projection::Field(index));
                    path.push(Some(index));
                    ty = field_ty;
                }
                ResolvedPlaceProjection::Index(index) => {
                    let (element, index) = self.check_subscript(ty, target.span, index)?;
                    projections.push(Projection::Index(Box::new(index)));
                    path.push(None);
                    ty = element;
                }
            }
        }
        self.check_not_frozen(local, &path, target.span)?;
        Ok((
            Place {
                local,
                call: None,
                projections,
            },
            ty,
        ))
    }

    /// Whether some binding of `pattern` holds an entity.
    fn binds_entity(&self, pattern: &Pattern) -> bool {
        match pattern {
            Pattern::Binding(local) => self.types.is_entity(self.locals[*local].ty),
            Pattern::Tuple(elements) => elements.iter().any(|element| self.binds_entity(element)),
            Pattern::Variant { fields, .. } => {
                fields.iter().any(|(_, field)| self.binds_entity(field))
            }
            Pattern::Or(alternatives) => alternatives
                .iter()
                .any(|alternative| self.binds_entity(alternative)),
            Pattern::Wildcard
            | Pattern::Int(_)
            | Pattern::Float(_)
            | Pattern::Str(_)
            | Pattern::Bool(_) => false,
        }
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

    /// Checks a condition, which is read at once, so the borrows it makes
    /// end with it.
    fn check_condition(&mut self, condition: &ResolvedExpr) -> Result<Expr, CheckDiagnostic> {
        let frozen_before = self.frozen.len();
        let checked = self.check_expr(condition, Some(Type::BOOL))?;
        self.require(condition.span, Type::BOOL, checked.ty)?;
        self.frozen.truncate(frozen_before);
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
                    self.use_local(local, span)?;
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
            ResolvedExprKind::List(elements) => self.check_list(span, elements, expected)?,
            ResolvedExprKind::Index { receiver, index } => {
                let base = self.check_expr(receiver, None)?;
                let (element, index) = self.check_subscript(base.ty, receiver.span, index)?;
                (
                    element,
                    ExprKind::Index {
                        base: Box::new(base),
                        index: Box::new(index),
                    },
                )
            }
            ResolvedExprKind::MethodCall {
                receiver,
                method,
                arguments,
            } => self.check_method(span, receiver, &method.name, arguments)?,
            ResolvedExprKind::Borrow { .. } => {
                return Err(self.unsupported(span, "borrows outside `for` loops"));
            }
            _ => return Err(self.unsupported(span, "these expressions")),
        };
        Ok(Expr { ty, kind })
    }

    fn check_list(
        &mut self,
        span: Span,
        elements: &[ResolvedExpr],
        expected: Option<Type>,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let mut element = match expected.map(|ty| self.types.kind(ty)) {
            Some(TypeKind::List(element)) => Some(*element),
            _ => None,
        };
        let mut checked = Vec::new();
        for value in elements {
            let value_checked = self.check_consumed(value, element)?;
            if value_checked.ty == Type::NEVER {
                return Err(self.unsupported(value.span, "diverging list elements"));
            }
            match element {
                Some(element) => self.require(value.span, element, value_checked.ty)?,
                None => element = Some(value_checked.ty),
            }
            checked.push(value_checked);
        }
        let Some(element) = element else {
            return Err(self.error(
                CheckDiagnosticKind::CannotInfer,
                span,
                "the element type of an empty list cannot be inferred here; write the expected type"
                    .to_owned(),
            ));
        };
        Ok((
            self.types.intern(TypeKind::List(element)),
            ExprKind::List(checked),
        ))
    }

    fn option_type(&mut self, span: Span, element: Type) -> Result<Type, CheckDiagnostic> {
        let Some((declaration, _, _)) = self.nominals.option else {
            return Err(self.unsupported(span, "`Option` without the core declaration"));
        };
        instantiate(self.types, self.nominals, declaration, vec![element], 0)
    }

    /// Checks a method call: an inherent method of the receiver's type, or
    /// else a built-in method.
    fn check_method(
        &mut self,
        span: Span,
        receiver: &ResolvedExpr,
        name: &str,
        arguments: &[ResolvedExpr],
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let operand = self.check_operand(receiver, None)?;
        let ty = operand.ty();
        let signatures = self.signatures;
        if let &TypeKind::Nominal { declaration, .. } = self.types.kind(ty)
            && let Some(identity) = self.methods.get(&(declaration, name.to_owned()))
        {
            let signature = &signatures[identity];
            if !signature.receiver {
                let owner = self.types.name(ty);
                return Err(self.error(
                    CheckDiagnosticKind::UnknownMethod,
                    span,
                    format!("`{owner}::{name}` has no `self`; call it as `{owner}::{name}(...)`"),
                ));
            }
            if arguments.len() + 1 != signature.parameters.len() {
                return Err(self.error(
                    CheckDiagnosticKind::ArgumentCount,
                    span,
                    format!(
                        "`{name}` takes {} arguments, found {}",
                        signature.parameters.len() - 1,
                        arguments.len()
                    ),
                ));
            }
            let arguments = std::iter::once(Argument::Receiver(operand, receiver))
                .chain(arguments.iter().map(Argument::Written))
                .collect();
            return self.finish_call(span, signature, arguments);
        }
        let (receiver_value, path) = match operand {
            Operand::Place((place, _, path)) => (Receiver::Place(place), Some(path)),
            Operand::Value(value) => (Receiver::Value(Box::new(value)), None),
        };
        let unknown = |checker: &Self| {
            checker.error(
                CheckDiagnosticKind::UnknownMethod,
                span,
                format!("`{}` has no method `{name}`", checker.types.name(ty)),
            )
        };
        let (builtin, parameters, result, mutates): (Builtin, Vec<(Type, bool)>, Type, bool) =
            if name == "clone" {
                (Builtin::Clone, Vec::new(), ty, false)
            } else if let TypeKind::List(element) = *self.types.kind(ty) {
                match name {
                    "push" => (Builtin::Push, vec![(element, true)], Type::UNIT, true),
                    "pop" => (
                        Builtin::Pop,
                        Vec::new(),
                        self.option_type(span, element)?,
                        true,
                    ),
                    "len" => (Builtin::Len, Vec::new(), Type::INT, false),
                    "is_empty" => (Builtin::IsEmpty, Vec::new(), Type::BOOL, false),
                    "insert" => (
                        Builtin::Insert,
                        vec![(Type::INT, false), (element, true)],
                        Type::UNIT,
                        true,
                    ),
                    "remove" => (Builtin::Remove, vec![(Type::INT, false)], element, true),
                    "clear" => (Builtin::Clear, Vec::new(), Type::UNIT, true),
                    "contains" if !self.types.is_entity(element) && self.has_equality(element) => {
                        (Builtin::Contains, vec![(element, false)], Type::BOOL, false)
                    }
                    "get" if !self.types.is_entity(element) => (
                        Builtin::Get,
                        vec![(Type::INT, false)],
                        self.option_type(span, element)?,
                        false,
                    ),
                    _ => return Err(unknown(self)),
                }
            } else if let TypeKind::Map(key, value) = *self.types.kind(ty) {
                match name {
                    "insert" => (
                        Builtin::Insert,
                        vec![(key, true), (value, true)],
                        self.option_type(span, value)?,
                        true,
                    ),
                    "remove" => (
                        Builtin::Remove,
                        vec![(key, true)],
                        self.option_type(span, value)?,
                        true,
                    ),
                    "get" if !self.types.is_entity(value) => (
                        Builtin::Get,
                        vec![(key, true)],
                        self.option_type(span, value)?,
                        false,
                    ),
                    "contains_key" => (Builtin::ContainsKey, vec![(key, true)], Type::BOOL, false),
                    "keys" => (
                        Builtin::Keys,
                        Vec::new(),
                        self.types.intern(TypeKind::List(key)),
                        false,
                    ),
                    "len" => (Builtin::Len, Vec::new(), Type::INT, false),
                    "is_empty" => (Builtin::IsEmpty, Vec::new(), Type::BOOL, false),
                    "clear" => (Builtin::Clear, Vec::new(), Type::UNIT, true),
                    _ => return Err(unknown(self)),
                }
            } else if let TypeKind::Set(element) = *self.types.kind(ty) {
                match name {
                    "insert" => (Builtin::Insert, vec![(element, true)], Type::BOOL, true),
                    "remove" => (Builtin::Remove, vec![(element, true)], Type::BOOL, true),
                    "contains" => (Builtin::Contains, vec![(element, true)], Type::BOOL, false),
                    "len" => (Builtin::Len, Vec::new(), Type::INT, false),
                    "is_empty" => (Builtin::IsEmpty, Vec::new(), Type::BOOL, false),
                    "clear" => (Builtin::Clear, Vec::new(), Type::UNIT, true),
                    _ => return Err(unknown(self)),
                }
            } else {
                return Err(unknown(self));
            };
        if mutates {
            let Receiver::Place(place) = &receiver_value else {
                return Err(self.error(
                    CheckDiagnosticKind::NotAssignable,
                    receiver.span,
                    format!(
                        "`{name}` changes its receiver, which must be a variable or a part of one"
                    ),
                ));
            };
            if !self.mutable[place.local] {
                return Err(self.error(
                    CheckDiagnosticKind::NotAssignable,
                    receiver.span,
                    format!(
                        "`{name}` changes `{}`, which is not declared `mut`",
                        self.locals[place.local].name
                    ),
                ));
            }
            let local = place.local;
            self.check_not_frozen(local, path.as_deref().unwrap_or(&[]), receiver.span)?;
        }
        if arguments.len() != parameters.len() {
            return Err(self.error(
                CheckDiagnosticKind::ArgumentCount,
                span,
                format!(
                    "`{name}` takes {} arguments, found {}",
                    parameters.len(),
                    arguments.len()
                ),
            ));
        }
        // The receiver is borrowed while the arguments are checked.
        let frozen_before = self.frozen.len();
        if let (Receiver::Place(place), Some(path)) = (&receiver_value, path) {
            self.frozen.push(Frozen {
                local: place.local,
                path,
                exclusive: mutates,
            });
        }
        let mut checked = Vec::new();
        for (argument, (parameter, consumed)) in arguments.iter().zip(parameters) {
            let value = if consumed {
                self.check_consumed(argument, Some(parameter))?
            } else {
                self.check_expr(argument, Some(parameter))?
            };
            self.require(argument.span, parameter, value.ty)?;
            checked.push(value);
        }
        self.frozen.truncate(frozen_before);
        Ok((
            result,
            ExprKind::Builtin {
                builtin,
                receiver: Box::new(receiver_value),
                arguments: checked,
            },
        ))
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
            let value = self.check_consumed(element, expected)?;
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
                let base = self.check_consumed(expression, expected)?;
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
            let checked = self.check_consumed(value, field_expected)?;
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
        let before = self.moved.clone();
        let Some(else_branch) = else_branch else {
            let conflicts = self.held_conflicts();
            let then_branch = self.check_block(then_branch, Some(Type::UNIT))?;
            if then_branch.ty == Type::NEVER {
                self.moved = before;
                self.set_held_conflicts(&conflicts);
            } else {
                self.moved.extend(before);
            }
            return Ok((
                Type::UNIT,
                ExprKind::If {
                    condition: Box::new(condition),
                    then_branch,
                    else_branch: None,
                },
            ));
        };
        let conflicts = self.held_conflicts();
        let then_branch = self.check_block(then_branch, expected)?;
        let after_then = std::mem::replace(&mut self.moved, before);
        let then_conflicts = self.held_conflicts();
        self.set_held_conflicts(&conflicts);
        let expected = expected.or(Some(then_branch.ty).filter(|ty| *ty != Type::NEVER));
        let else_span = else_branch.span;
        let else_branch = self.check_consumed(else_branch, expected)?;
        self.merge_moved([
            (then_branch.ty, after_then),
            (else_branch.ty, self.moved.clone()),
        ]);
        let else_conflicts = self.held_conflicts();
        self.join_branch_conflicts(&[
            (then_branch.ty, then_conflicts),
            (else_branch.ty, else_conflicts),
        ]);
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

    /// Joins the moved locals of branches; a branch of type `Never` does not
    /// reach the join.
    fn merge_moved(&mut self, branches: impl IntoIterator<Item = (Type, BTreeSet<usize>)>) {
        let mut reaching = None::<BTreeSet<usize>>;
        let mut all = BTreeSet::new();
        for (ty, moved) in branches {
            all.extend(moved.iter().copied());
            if ty != Type::NEVER {
                reaching.get_or_insert_with(BTreeSet::new).extend(moved);
            }
        }
        self.moved = reaching.unwrap_or(all);
    }

    /// Checks the patterns of `arms` against `ty`, binding with `mode`;
    /// returns each pattern with the locals visible in its arm.
    fn check_arm_patterns<'p>(
        &mut self,
        patterns: impl IntoIterator<Item = &'p ResolvedPattern>,
        ty: Type,
        mode: Option<BorrowKind>,
    ) -> Result<Vec<ArmPattern>, CheckDiagnostic> {
        let scope = self.local_ids.clone();
        let mut checked = Vec::new();
        for pattern in patterns {
            let pattern = self.check_pattern(pattern, ty, mode, &mut BTreeMap::new())?;
            checked.push((
                pattern,
                std::mem::replace(&mut self.local_ids, scope.clone()),
            ));
        }
        Ok(checked)
    }

    /// Checks the subject of a `match` or `if let`. A subject written `&e`
    /// or `&mut e` is borrowed: it returns the borrow mode, and for a place
    /// the borrow that the arms keep.
    fn check_subject(
        &mut self,
        subject: &ResolvedExpr,
    ) -> Result<(Expr, Option<BorrowKind>, Option<Frozen>), CheckDiagnostic> {
        let ResolvedExprKind::Borrow {
            kind: (_, kind),
            operand,
        } = &subject.kind
        else {
            return Ok((self.check_expr(subject, None)?, None, None));
        };
        let kind = *kind;
        let (target, ty, frozen) = match self.check_operand(operand, None)? {
            Operand::Place((place, ty, path)) => {
                self.check_borrow(&place, &path, kind, operand.span)?;
                let frozen = Frozen {
                    local: place.local,
                    path,
                    exclusive: kind == BorrowKind::Mutable,
                };
                (BorrowTarget::Place(place), ty, Some(frozen))
            }
            Operand::Value(value) => {
                if value.ty == Type::NEVER {
                    return Ok((value, None, None));
                }
                let ty = value.ty;
                (BorrowTarget::Value(value), ty, None)
            }
        };
        Ok((
            Expr {
                ty,
                kind: ExprKind::Borrow(Box::new(target)),
            },
            Some(kind),
            frozen,
        ))
    }

    /// The bindings of `pattern` that point into the matched place with `&mut`.
    fn mutable_bindings(&self, pattern: &Pattern) -> Vec<usize> {
        let mut locals = pattern.bindings();
        locals.retain(|&local| self.locals[local].borrow == Some(BorrowKind::Mutable));
        locals
    }

    fn check_match(
        &mut self,
        span: Span,
        scrutinee: &ResolvedExpr,
        arms: &[ResolvedMatchArm],
        expected: Option<Type>,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let scrutinee_span = scrutinee.span;
        let (scrutinee, mode, frozen) = self.check_subject(scrutinee)?;
        if scrutinee.ty == Type::NEVER {
            return Ok((Type::NEVER, scrutinee.kind));
        }
        let patterns =
            self.check_arm_patterns(arms.iter().map(|arm| &arm.pattern), scrutinee.ty, mode)?;
        for (pattern, _) in &patterns {
            self.borrow_from(&pattern.bindings(), frozen.as_ref().map(|f| f.local));
        }
        let scrutinee = if mode.is_none()
            && patterns
                .iter()
                .any(|(pattern, _)| self.binds_entity(pattern))
        {
            self.consume(scrutinee, scrutinee_span)?
        } else {
            scrutinee
        };
        let has_frozen = frozen.is_some();
        self.frozen.extend(frozen);
        let scope = self.local_ids.clone();
        let before = self.moved.clone();
        // Every arm starts from the conflicts before the `match` and those of
        // the guards before it, which may fail and fall through.
        let mut conflicts = self.held_conflicts();
        let mut arm_conflicts = Vec::new();
        let mut ends = Vec::new();
        let mut expected = expected;
        let mut ty = None;
        let mut checked = Vec::new();
        for (arm, (pattern, visible)) in arms.iter().zip(patterns) {
            self.local_ids = visible;
            self.moved = before.clone();
            self.set_held_conflicts(&conflicts);
            // A guard only reads the bindings; they become `&mut` once it holds.
            let readonly = self.mutable_bindings(&pattern);
            for &local in &readonly {
                self.mutable[local] = false;
            }
            let guard = arm
                .guard
                .as_ref()
                .map(|guard| self.check_condition(guard))
                .transpose()?;
            for &local in &readonly {
                self.mutable[local] = true;
            }
            conflicts = self.held_conflicts();
            // Each arm's value is stored when the arm ends.
            let frozen_before = self.frozen.len();
            let body = self.check_consumed(&arm.body, expected)?;
            self.frozen.truncate(frozen_before);
            ends.push((body.ty, self.moved.clone()));
            arm_conflicts.push((body.ty, self.held_conflicts()));
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
        if has_frozen {
            self.frozen.pop();
        }
        self.local_ids = scope;
        if ends.is_empty() {
            self.moved = before;
            self.set_held_conflicts(&conflicts);
        } else {
            self.merge_moved(ends);
            self.join_branch_conflicts(&arm_conflicts);
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
        let (scrutinee, mode, frozen) = self.check_subject(value)?;
        if scrutinee.ty == Type::NEVER {
            return Ok(scrutinee);
        }
        let mut patterns = self.check_arm_patterns([pattern], scrutinee.ty, mode)?;
        let (pattern, visible) = patterns.pop().expect("one pattern was checked");
        self.borrow_from(&pattern.bindings(), frozen.as_ref().map(|f| f.local));
        let scrutinee = if mode.is_none() && self.binds_entity(&pattern) {
            self.consume(scrutinee, value.span)?
        } else {
            scrutinee
        };
        let has_frozen = frozen.is_some();
        self.frozen.extend(frozen);
        let scope = std::mem::replace(&mut self.local_ids, visible);
        let before = self.moved.clone();
        let conflicts = self.held_conflicts();
        let then_branch = self.check_block(then_branch, Some(Type::UNIT))?;
        if has_frozen {
            self.frozen.pop();
        }
        self.local_ids = scope;
        let after_then = std::mem::replace(&mut self.moved, before);
        let then_conflicts = self.held_conflicts();
        self.set_held_conflicts(&conflicts);
        let else_body = match else_branch {
            Some(block) => self.check_block(block, Some(Type::UNIT))?,
            None => Block {
                statements: Vec::new(),
                tail: None,
                ty: Type::UNIT,
            },
        };
        self.merge_moved([
            (then_branch.ty, after_then),
            (else_body.ty, self.moved.clone()),
        ]);
        let else_conflicts = self.held_conflicts();
        self.join_branch_conflicts(&[
            (then_branch.ty, then_conflicts),
            (else_body.ty, else_conflicts),
        ]);
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

    /// Checks `pattern` against a value of type `ty`, declaring its bindings
    /// with `mode`. `shared` maps binding names to the locals of earlier
    /// alternatives.
    fn check_pattern(
        &mut self,
        pattern: &ResolvedPattern,
        ty: Type,
        mode: Option<BorrowKind>,
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
                    let local = self.declare_binding(&binding.identity, ty, mode);
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
                            self.check_pattern(element, element_ty, mode, shared)
                        })
                        .collect::<Result<_, _>>()?,
                )
            }
            ResolvedPatternKind::Or(alternatives) => {
                let mut checked = Vec::new();
                for alternative in alternatives {
                    checked.push(self.check_pattern(alternative, ty, mode, shared)?);
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
                            checked.push((
                                index,
                                self.check_pattern(pattern, *field_ty, mode, shared)?,
                            ));
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
                                self.check_pattern(&field.pattern, field_ty, mode, shared)?,
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
                self.types.has_order(ty).then_some(Type::BOOL)
            }
            Op::LogicAnd | Op::LogicOr => (ty == Type::BOOL).then_some(Type::BOOL),
            Op::RangeExclusive | Op::RangeInclusive => {
                if ty != Type::INT {
                    return Err(self.mismatch(span, Type::INT, ty));
                }
                return Ok((
                    self.types.intern(TypeKind::Range),
                    ExprKind::Range {
                        start: Box::new(left),
                        end: Box::new(right),
                        inclusive: operator == Op::RangeInclusive,
                    },
                ));
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

    fn has_equality(&self, ty: Type) -> bool {
        self.types.has_equality(ty)
    }

    fn check_call(
        &mut self,
        span: Span,
        callee: &ResolvedExpr,
        arguments: &[ResolvedExpr],
        expected: Option<Type>,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let signatures = self.signatures;
        let signature = match &callee.kind {
            ResolvedExprKind::Path(ResolvedReference::Exact { target, .. }) => {
                if let Some(&(declaration, variant)) = self.nominals.constructors.get(target) {
                    return self.check_variant(
                        span,
                        declaration,
                        variant,
                        Some(Arguments::Positional(arguments)),
                        expected,
                    );
                }
                if target.kind == EntityKind::LanguageFunction {
                    let values = arguments.iter().collect::<Vec<_>>();
                    return self.check_intrinsic(span, &target.name, &values);
                }
                let Some(signature) = signatures.get(target) else {
                    return Err(self.unsupported(callee.span, "calls of this kind"));
                };
                signature
            }
            ResolvedExprKind::Path(ResolvedReference::Selection { base, members, .. })
                if base.kind == EntityKind::LanguageType
                    && matches!(base.name.as_str(), "Map" | "Set")
                    && let [member] = members.as_slice()
                    && member.name == "new" =>
            {
                let name = &base.name;
                if !arguments.is_empty() {
                    return Err(self.error(
                        CheckDiagnosticKind::ArgumentCount,
                        span,
                        format!("`{name}::new` takes no arguments"),
                    ));
                }
                let Some(ty) = expected.filter(|ty| match self.types.kind(*ty) {
                    TypeKind::Map(..) => name == "Map",
                    TypeKind::Set(_) => name == "Set",
                    _ => false,
                }) else {
                    return Err(self.error(
                        CheckDiagnosticKind::CannotInfer,
                        span,
                        format!(
                            "the types of an empty `{name}` cannot be inferred here; write the expected type"
                        ),
                    ));
                };
                return Ok((ty, ExprKind::EmptyMap));
            }
            // `Type::function(...)` names a function of an inherent impl.
            ResolvedExprKind::Path(ResolvedReference::Selection { base, members, .. })
                if let [member] = members.as_slice()
                    && let Some(&declaration) = self.nominals.by_identity.get(base) =>
            {
                let Some(identity) = self.methods.get(&(declaration, member.name.clone())) else {
                    return Err(self.error(
                        CheckDiagnosticKind::UnknownMethod,
                        member.origin.span,
                        format!("`{}` has no function `{}`", base.name, member.name),
                    ));
                };
                &signatures[identity]
            }
            _ => return Err(self.unsupported(callee.span, "calls of computed functions")),
        };
        if arguments.len() != signature.parameters.len() {
            return Err(self.error(
                CheckDiagnosticKind::ArgumentCount,
                span,
                format!(
                    "expected {} arguments, found {}",
                    signature.parameters.len(),
                    arguments.len()
                ),
            ));
        }
        let arguments = arguments.iter().map(Argument::Written).collect();
        self.finish_call(span, signature, arguments)
    }

    /// Checks the arguments of a call of the function with `signature`.
    fn finish_call(
        &mut self,
        span: Span,
        signature: &Signature,
        arguments: Vec<Argument>,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let borrow = signature.result_borrow;
        // The borrowed arguments of a call that returns a borrow stay
        // borrowed until the statement ends, or longer if a `let` binds it.
        let frozen_before = self.frozen.len();
        let checked = self.check_arguments(arguments, signature.parameters.clone());
        if borrow.is_none() {
            self.frozen.truncate(frozen_before);
        }
        let (arguments, checks) = checked?;
        if borrow.is_some()
            && arguments.iter().any(|argument| {
                matches!(&argument.kind, ExprKind::Borrow(target)
                    if matches!(target.as_ref(), BorrowTarget::Value(_)))
            })
        {
            return Err(self.unsupported(span, "borrowed results of calls that borrow temporaries"));
        }
        Ok((
            signature.result,
            ExprKind::Call {
                function: signature.index,
                arguments,
                checks,
                borrow,
            },
        ))
    }

    /// Whether every borrowed argument of `call` reaches only places of the
    /// parameters passed by borrow.
    fn call_from_parameters(&self, call: &Expr) -> bool {
        let ExprKind::Call { arguments, .. } = &call.kind else {
            unreachable!("only calls are passed here")
        };
        arguments.iter().all(|argument| match &argument.kind {
            ExprKind::Borrow(target) => match target.as_ref() {
                BorrowTarget::Place(place) => self.from_parameters[place.local],
                BorrowTarget::Value(_) => false,
            },
            _ => true,
        })
    }

    /// Checks call arguments in order. A borrowed argument stays borrowed
    /// while the later ones are checked; two borrows of one place that
    /// differ only in list indices are checked at run time.
    fn check_arguments(
        &mut self,
        values: Vec<Argument>,
        parameters: Vec<(Type, Option<BorrowKind>)>,
    ) -> Result<(Vec<Expr>, Vec<DisjointCheck>), CheckDiagnostic> {
        let mut checked = Vec::new();
        let mut borrows: Vec<ArgumentBorrow> = Vec::new();
        // The positions on the borrow stack of this call's own borrowed
        // arguments, which are compared with each other below.
        let mut own = Vec::new();
        let mut checks = Vec::new();
        for (position, (value, (ty, borrow))) in values.into_iter().zip(parameters).enumerate() {
            let (checked_operand, operand, is_receiver) = match (value, borrow) {
                (Argument::Written(value), None) => {
                    let argument = self.check_consumed(value, Some(ty))?;
                    self.require(value.span, ty, argument.ty)?;
                    checked.push(argument);
                    continue;
                }
                // A method that takes `self` takes the receiver.
                (Argument::Receiver(receiver, value), None) => {
                    let receiver = match receiver {
                        Operand::Place((place, _, _)) => self.place_value(place),
                        Operand::Value(value) => value,
                    };
                    checked.push(self.consume(receiver, value.span)?);
                    continue;
                }
                // The receiver of `&self` and `&mut self` is borrowed as is.
                (Argument::Receiver(receiver, value), Some(_)) => (receiver, value, true),
                (Argument::Written(value), Some(kind)) => {
                    let spelled = match kind {
                        BorrowKind::Shared => "&",
                        BorrowKind::Mutable => "&mut",
                    };
                    let ResolvedExprKind::Borrow {
                        kind: (_, written),
                        operand,
                    } = &value.kind
                    else {
                        return Err(self.error(
                            CheckDiagnosticKind::TypeMismatch,
                            value.span,
                            format!(
                                "this parameter borrows its argument; write `{spelled}` before it"
                            ),
                        ));
                    };
                    if *written != kind {
                        return Err(self.error(
                            CheckDiagnosticKind::TypeMismatch,
                            value.span,
                            format!("this parameter borrows with `{spelled}`"),
                        ));
                    }
                    (
                        self.check_operand(operand, Some(ty))?,
                        operand.as_ref(),
                        false,
                    )
                }
            };
            let kind = borrow.expect("only borrowed arguments get here");
            let target = match checked_operand {
                Operand::Place((place, place_ty, path)) => {
                    self.require(operand.span, ty, place_ty)?;
                    self.check_borrow_except(&own, &place, &path, kind, operand.span)?;
                    let keys = index_keys(operand);
                    for earlier in &borrows {
                        if earlier.local != place.local
                            || (kind == BorrowKind::Shared && earlier.kind == BorrowKind::Shared)
                        {
                            continue;
                        }
                        match overlap(&earlier.path, &path) {
                            Overlap::Disjoint => {}
                            Overlap::IfIndicesEqual(positions)
                                if !positions.iter().all(|&at| {
                                    earlier.keys.get(at).cloned().flatten().is_some()
                                        && earlier.keys.get(at) == keys.get(at)
                                }) =>
                            {
                                checks.push(DisjointCheck {
                                    first: earlier.position,
                                    second: position,
                                });
                            }
                            Overlap::IfIndicesEqual(_) | Overlap::Certain => {
                                return Err(self.error(
                                    CheckDiagnosticKind::BorrowConflict,
                                    operand.span,
                                    format!(
                                        "`{}` is borrowed twice in one call, at least once with `&mut`",
                                        self.locals[place.local].name
                                    ),
                                ));
                            }
                        }
                    }
                    own.push(self.frozen.len());
                    self.frozen.push(Frozen {
                        local: place.local,
                        path: path.clone(),
                        exclusive: kind == BorrowKind::Mutable,
                    });
                    borrows.push(ArgumentBorrow {
                        position,
                        local: place.local,
                        path,
                        kind,
                        keys,
                    });
                    BorrowTarget::Place(place)
                }
                Operand::Value(value) => {
                    if is_receiver && kind == BorrowKind::Mutable {
                        return Err(self.error(
                            CheckDiagnosticKind::NotAssignable,
                            operand.span,
                            "a method with `&mut self` changes its receiver, which must be a variable or a part of one".to_owned(),
                        ));
                    }
                    self.require(operand.span, ty, value.ty)?;
                    BorrowTarget::Value(value)
                }
            };
            checked.push(Expr {
                ty,
                kind: ExprKind::Borrow(Box::new(target)),
            });
        }
        Ok((checked, checks))
    }

    /// Checks `replace(&mut place, value)` or `swap(&mut a, &mut b)`, whose
    /// type `T` is that of the first place.
    fn check_exchange(
        &mut self,
        span: Span,
        intrinsic: Intrinsic,
        values: &[&ResolvedExpr],
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let [first, second] = values else {
            return Err(self.error(
                CheckDiagnosticKind::ArgumentCount,
                span,
                format!("expected 2 arguments, found {}", values.len()),
            ));
        };
        let ResolvedExprKind::Borrow {
            kind: (_, BorrowKind::Mutable),
            operand,
        } = &first.kind
        else {
            return Err(self.error(
                CheckDiagnosticKind::TypeMismatch,
                first.span,
                "this parameter borrows its argument; write `&mut` before it".to_owned(),
            ));
        };
        let first_operand = self.check_operand(operand, None)?;
        let ty = first_operand.ty();
        let second_parameter = match intrinsic {
            Intrinsic::Swap => Some(BorrowKind::Mutable),
            _ => None,
        };
        let frozen_before = self.frozen.len();
        let checked = self.check_arguments(
            vec![
                Argument::Receiver(first_operand, operand),
                Argument::Written(second),
            ],
            vec![(ty, Some(BorrowKind::Mutable)), (ty, second_parameter)],
        );
        self.frozen.truncate(frozen_before);
        let (arguments, checks) = checked?;
        // Only places can be changed.
        for (argument, value) in arguments.iter().zip([operand.as_ref(), second]) {
            if let ExprKind::Borrow(target) = &argument.kind
                && let BorrowTarget::Value(_) = target.as_ref()
            {
                return Err(self.error(
                    CheckDiagnosticKind::NotAssignable,
                    value.span,
                    "this must be a variable or a part of one".to_owned(),
                ));
            }
        }
        let result = match intrinsic {
            Intrinsic::Replace => ty,
            _ => Type::UNIT,
        };
        Ok((
            result,
            ExprKind::Intrinsic {
                intrinsic,
                arguments,
                checks,
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
            "replace" => return self.check_exchange(span, Intrinsic::Replace, values),
            "swap" => return self.check_exchange(span, Intrinsic::Swap, values),
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
                checks: Vec::new(),
            },
        ))
    }
}

/// A call argument: an expression as written, or the receiver of a method,
/// checked already to find the method, which the call borrows or takes as
/// the method declares.
enum Argument<'r> {
    Written(&'r ResolvedExpr),
    Receiver(Operand, &'r ResolvedExpr),
}

/// A borrowed call argument: its position, the place it borrows, and the
/// `index_keys` of the place.
struct ArgumentBorrow {
    position: usize,
    local: usize,
    path: Vec<Option<usize>>,
    kind: BorrowKind,
    keys: Vec<Option<String>>,
}

/// The name of a called function, for the local that holds its borrowed
/// result.
fn callee_name(callee: &ResolvedExpr) -> String {
    match &callee.kind {
        ResolvedExprKind::Path(ResolvedReference::Exact { target, .. }) => target.name.clone(),
        _ => "result".to_owned(),
    }
}

fn block_mentions(block: &ResolvedBlock, names: &[EntityId]) -> bool {
    block
        .statements
        .iter()
        .any(|statement| statement_mentions(statement, names))
        || block
            .tail
            .as_deref()
            .is_some_and(|tail| expr_mentions(tail, names))
}

fn statement_mentions(statement: &ResolvedStatement, names: &[EntityId]) -> bool {
    match &statement.kind {
        ResolvedStatementKind::Let { value, .. } | ResolvedStatementKind::Expression(value) => {
            expr_mentions(value, names)
        }
        ResolvedStatementKind::Return(value) => value
            .as_ref()
            .is_some_and(|value| expr_mentions(value, names)),
        ResolvedStatementKind::Break | ResolvedStatementKind::Continue => false,
        ResolvedStatementKind::Assignment { target, value, .. } => {
            reference_mentions(&target.root, names)
                || target.projections.iter().any(|projection| {
                    matches!(projection, ResolvedPlaceProjection::Index(index)
                        if expr_mentions(index, names))
                })
                || expr_mentions(value, names)
        }
        ResolvedStatementKind::IfLet {
            value,
            then_branch,
            else_branch,
            ..
        } => {
            expr_mentions(value, names)
                || block_mentions(then_branch, names)
                || else_branch
                    .as_ref()
                    .is_some_and(|block| block_mentions(block, names))
        }
        ResolvedStatementKind::While { condition, body } => {
            expr_mentions(condition, names) || block_mentions(body, names)
        }
        ResolvedStatementKind::For { iterable, body, .. } => {
            expr_mentions(iterable, names) || block_mentions(body, names)
        }
        ResolvedStatementKind::Loop(body) => block_mentions(body, names),
    }
}

fn expr_mentions(expression: &ResolvedExpr, names: &[EntityId]) -> bool {
    let any = |expressions: &[ResolvedExpr]| {
        expressions
            .iter()
            .any(|expression| expr_mentions(expression, names))
    };
    let arms = |arms: &[ResolvedMatchArm]| {
        arms.iter().any(|arm| {
            arm.guard
                .as_ref()
                .is_some_and(|guard| expr_mentions(guard, names))
                || expr_mentions(&arm.body, names)
        })
    };
    match &expression.kind {
        ResolvedExprKind::Integer(_)
        | ResolvedExprKind::Float(_)
        | ResolvedExprKind::String(_)
        | ResolvedExprKind::RawString { .. }
        | ResolvedExprKind::Boolean(_)
        | ResolvedExprKind::Unit => false,
        ResolvedExprKind::InterpolatedString(parts) => parts.iter().any(|part| {
            matches!(part, ResolvedInterpolationPart::Expression(part)
                if expr_mentions(part, names))
        }),
        ResolvedExprKind::Path(reference) => reference_mentions(reference, names),
        ResolvedExprKind::NamedConstruct { entries, .. } => {
            entries.iter().any(|entry| match entry {
                ResolvedConstructEntry::Spread(value) => expr_mentions(value, names),
                ResolvedConstructEntry::Field {
                    value, shorthand, ..
                } => {
                    value
                        .as_deref()
                        .is_some_and(|value| expr_mentions(value, names))
                        || shorthand
                            .as_deref()
                            .is_some_and(|reference| reference_mentions(reference, names))
                }
            })
        }
        ResolvedExprKind::List(elements) | ResolvedExprKind::Tuple(elements) => any(elements),
        ResolvedExprKind::Parenthesized(inner)
        | ResolvedExprKind::Unary { operand: inner, .. }
        | ResolvedExprKind::Borrow { operand: inner, .. }
        | ResolvedExprKind::Field {
            receiver: inner, ..
        }
        | ResolvedExprKind::TupleField {
            receiver: inner, ..
        } => expr_mentions(inner, names),
        ResolvedExprKind::Block(block) | ResolvedExprKind::Unsafe(block) => {
            block_mentions(block, names)
        }
        ResolvedExprKind::If {
            condition,
            then_branch,
            else_branch,
        } => {
            expr_mentions(condition, names)
                || block_mentions(then_branch, names)
                || else_branch
                    .as_deref()
                    .is_some_and(|branch| expr_mentions(branch, names))
        }
        ResolvedExprKind::Match {
            scrutinee: subject,
            arms: cases,
        }
        | ResolvedExprKind::Catch {
            expression: subject,
            arms: cases,
        } => expr_mentions(subject, names) || arms(cases),
        // The checker rejects these; counting them as mentions is safe.
        ResolvedExprKind::Handle { .. } | ResolvedExprKind::Closure(_) => true,
        ResolvedExprKind::Binary { left, right, .. }
        | ResolvedExprKind::Index {
            receiver: left,
            index: right,
        } => expr_mentions(left, names) || expr_mentions(right, names),
        ResolvedExprKind::Call { callee, arguments } => {
            expr_mentions(callee, names) || any(arguments)
        }
        ResolvedExprKind::MethodCall {
            receiver,
            arguments,
            ..
        } => expr_mentions(receiver, names) || any(arguments),
    }
}

fn reference_mentions(reference: &ResolvedReference, names: &[EntityId]) -> bool {
    match reference {
        ResolvedReference::Exact { target, .. } => names.contains(target),
        ResolvedReference::Selection { base, .. } => names.contains(base),
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

enum Overlap {
    Disjoint,
    Certain,
    /// The places overlap exactly when the list indices at these path
    /// positions are equal.
    IfIndicesEqual(Vec<usize>),
}

/// Compares two paths from the same local.
fn overlap(left: &[Option<usize>], right: &[Option<usize>]) -> Overlap {
    let mut positions = Vec::new();
    for (position, (left, right)) in left.iter().zip(right).enumerate() {
        match (left, right) {
            (Some(left), Some(right)) if left != right => return Overlap::Disjoint,
            (None, None) => positions.push(position),
            _ => {}
        }
    }
    if positions.is_empty() {
        Overlap::Certain
    } else {
        Overlap::IfIndicesEqual(positions)
    }
}

/// For each projection of a place expression, from its root: a key that
/// names the index when it is a literal or a plain variable, so two equal
/// keys denote the same element.
fn index_keys(expression: &ResolvedExpr) -> Vec<Option<String>> {
    match &expression.kind {
        ResolvedExprKind::Parenthesized(inner) => index_keys(inner),
        ResolvedExprKind::Field { receiver, .. }
        | ResolvedExprKind::TupleField { receiver, .. } => {
            let mut keys = index_keys(receiver);
            keys.push(None);
            keys
        }
        ResolvedExprKind::Index { receiver, index } => {
            let mut keys = index_keys(receiver);
            keys.push(match &index.kind {
                ResolvedExprKind::Integer(text) => Some(format!("integer {text}")),
                ResolvedExprKind::Path(ResolvedReference::Exact { target, .. }) => {
                    Some(format!("{target:?}"))
                }
                _ => None,
            });
            keys
        }
        _ => Vec::new(),
    }
}
