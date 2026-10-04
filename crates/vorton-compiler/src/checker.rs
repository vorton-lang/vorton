//! Type checking.
//!
//! The checker turns the resolved project into the typed program of
//! [`crate::typed`]. It gives every expression a type, resolves method and
//! trait calls, checks the bounds of generic functions and types, which are
//! checked once and instantiated afterwards by [`crate::mono`], and checks
//! that patterns are exhaustive. A construct it does not support yet reports
//! [`CheckDiagnosticKind::Unsupported`] instead of being treated as checked.
//!
//! The checker also decides where a value is copied or moved and where a
//! borrow begins. Whether that move or borrow is allowed there, such as a
//! use after a move, a move out of a part, or an access that conflicts with
//! a live borrow, is checked on the IR of each function by
//! [`crate::borrowck`], which follows every path of the control flow.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};

use crate::ast::{AssignmentOperator, BinaryOperator, BorrowKind, Span, UnaryOperator};
use crate::diagnostic::{CheckDiagnostic, CheckDiagnosticKind};
use crate::exhaustive;
use crate::project::{
    CoreRoles, EntityId, EntityKind, EntitySite, LibraryId, ModuleRef, OriginRef, ResolvedBlock,
    ResolvedConstructEntry, ResolvedDeclarationKind, ResolvedExpr, ResolvedExprKind, ResolvedField,
    ResolvedFunction, ResolvedImplMemberKind, ResolvedInterpolationPart, ResolvedMatchArm,
    ResolvedNamedType, ResolvedPattern, ResolvedPatternFields, ResolvedPatternKind, ResolvedPlace,
    ResolvedPlaceProjection, ResolvedProject, ResolvedReference, ResolvedStatement,
    ResolvedStatementKind, ResolvedTraitMember, ResolvedTraitMemberKind, ResolvedType,
    ResolvedTypeArgument, ResolvedTypeKind, ResolvedVariant, ResolvedVariantFields, SourceRef,
};
use crate::resolver::owner_key_from_entity;
use crate::typed::{
    Arm, Block, BorrowTarget, Builtin, Callee, Expr, ExprKind, ForSource, Function, Impls,
    Intrinsic, ListMethod, Local, MapMethod, Pattern, Place, Program, Projection, Receiver,
    SetMethod, Statement, StrMethod,
};
use crate::types::{
    Comparison, CoreEnums, Field, NominalInfo, OptionEnum, OrderingEnum, Type, TypeKind, Types,
    Variant,
};

#[derive(Clone)]
struct Signature {
    index: usize,
    /// Whether the first parameter is the `self` of a method.
    receiver: bool,
    /// The parameter and result types mention these as [`TypeKind::Param`].
    type_parameters: Vec<TypeParameter>,
    /// The type of each type parameter, by its identity.
    type_scope: BTreeMap<EntityId, Type>,
    parameters: Vec<(Type, Option<BorrowKind>)>,
    result: Type,
    result_borrow: Option<BorrowKind>,
}

/// A type parameter of a generic function and its bounds.
#[derive(Clone)]
struct TypeParameter {
    name: String,
    /// The traits it is bound by, with their supertraits. This is the one
    /// record of what the parameter implements: `Copy` and `Clone` among
    /// them, whether written or reached as supertraits.
    traits: BTreeSet<usize>,
}

/// A trait declaration.
struct TraitDeclaration<'a> {
    name: String,
    visibility: Visibility,
    /// The direct supertraits, by index.
    supertraits: Vec<usize>,
    methods: Vec<&'a ResolvedTraitMember>,
    /// The checker does not support associated types yet, so such a trait
    /// cannot be implemented or used as a bound.
    associated_types: bool,
    /// Whether the official core declares it.
    core: bool,
}

/// The traits, and the signature of each trait method with `Self` as the
/// type parameter at index 0.
struct Traits<'a> {
    declarations: Vec<TraitDeclaration<'a>>,
    by_identity: BTreeMap<EntityId, usize>,
    signatures: Vec<Vec<Signature>>,
    display: usize,
    copy: usize,
    clone: usize,
    drop: usize,
    /// `PartialEq`, `Eq`, `PartialOrd` and `Ord`.
    comparisons: [usize; 4],
}

impl Traits<'_> {
    /// `trait_index` and its supertraits, transitively.
    fn closure(&self, trait_index: usize, into: &mut BTreeSet<usize>) {
        if into.insert(trait_index) {
            for &supertrait in &self.declarations[trait_index].supertraits {
                self.closure(supertrait, into);
            }
        }
    }

    fn method_name(&self, trait_index: usize, method: usize) -> &str {
        &self.declarations[trait_index].methods[method].identity.name
    }

    /// The comparison that `trait_index` is, if it is one.
    fn comparison(&self, trait_index: usize) -> Option<Comparison> {
        let position = self
            .comparisons
            .iter()
            .position(|&comparison| comparison == trait_index)?;
        Some(
            [
                Comparison::PartialEq,
                Comparison::Eq,
                Comparison::PartialOrd,
                Comparison::Ord,
            ][position],
        )
    }

    /// Whether the checker supports impls of and bounds on `trait_index`.
    fn supported(&self, trait_index: usize) -> bool {
        let declaration = &self.declarations[trait_index];
        !declaration.associated_types
            && (!declaration.core
                || [self.display, self.copy, self.clone, self.drop].contains(&trait_index)
                || self.comparison(trait_index).is_some())
    }
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
    /// The module that declares it, where its private fields are visible.
    module: ModuleRef,
    public: bool,
}

/// Where an item may be used: anywhere if it is public, otherwise in the
/// module that declares it and the modules inside that one.
#[derive(Clone)]
struct Visibility {
    public: bool,
    module: ModuleRef,
}

impl Visibility {
    fn admits(&self, module: &ModuleRef) -> bool {
        self.public || *module == self.module || module.is_descendant_of(&self.module)
    }
}

/// Struct and enum declarations, and the enum constructors by identity.
struct Nominals<'a> {
    declarations: Vec<NominalDeclaration<'a>>,
    by_identity: BTreeMap<EntityId, usize>,
    constructors: BTreeMap<EntityId, (usize, usize)>,
    /// The types written as map keys and set elements.
    keys: RefCell<Keys>,
}

/// Whether a type can be a map key depends on its hand-written impls, so a
/// key written before they are all known waits until they are; after that,
/// a key is checked where it is written.
#[derive(Default)]
struct Keys {
    ready: bool,
    waiting: Vec<(Type, OriginRef)>,
}

impl Nominals<'_> {
    /// Requires `key`, written at `origin`, to be a map key or set element.
    fn require_key(
        &self,
        types: &Types,
        key: Type,
        origin: OriginRef,
    ) -> Result<(), CheckDiagnostic> {
        let mut keys = self.keys.borrow_mut();
        if !keys.ready {
            keys.waiting.push((key, origin));
            return Ok(());
        }
        check_key(types, key, origin)
    }

    /// Checks the keys that waited, now that every hand-written impl is
    /// known, and checks keys where they are written from now on.
    fn check_keys(&self, types: &Types) -> Result<(), CheckDiagnostic> {
        let mut keys = self.keys.borrow_mut();
        keys.ready = true;
        for (key, origin) in std::mem::take(&mut keys.waiting) {
            check_key(types, key, origin)?;
        }
        Ok(())
    }
}

fn check_key(types: &Types, key: Type, origin: OriginRef) -> Result<(), CheckDiagnostic> {
    if types.is_key(key) {
        return Ok(());
    }
    Err(CheckDiagnostic {
        kind: CheckDiagnosticKind::TypeMismatch,
        primary: Some(origin),
        message: format!(
            "`{}` cannot be a map key or set element; those are values without `Float` or a hand-written `PartialEq` or `Drop`",
            types.name(key)
        ),
    })
}

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
type Methods = BTreeMap<(usize, String), (EntityId, Visibility)>;

pub(crate) fn check(project: &ResolvedProject) -> Result<Program, CheckDiagnostic> {
    let mut functions_found = Vec::new();
    let mut impls = Vec::new();
    let mut traits_found = Vec::new();
    let mut trait_impls_found = Vec::new();
    let mut nominals = Nominals {
        declarations: Vec::new(),
        by_identity: BTreeMap::new(),
        constructors: BTreeMap::new(),
        keys: RefCell::default(),
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
                let bound = match &declaration.kind {
                    ResolvedDeclarationKind::Struct {
                        type_parameters, ..
                    }
                    | ResolvedDeclarationKind::Enum {
                        type_parameters, ..
                    } => type_parameters
                        .iter()
                        .find_map(|parameter| parameter.bounds.first()),
                    _ => None,
                };
                if let Some(bound) = bound {
                    return Err(unsupported(
                        Some(declaration.origin.at(bound.span)),
                        "bounds on the type parameters of structs and enums",
                    ));
                }
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
                    module: identity.module.clone(),
                    public: declaration.public,
                });
                continue;
            }
            if let ResolvedDeclarationKind::Trait { .. } = &declaration.kind {
                traits_found.push((identity(), declaration, is_core));
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
                ResolvedDeclarationKind::TraitImpl {
                    implementation,
                    trait_type,
                    where_clause,
                } => {
                    if where_clause.is_some() {
                        return Err(unsupported(
                            Some(declaration.origin.clone()),
                            "`where` clauses",
                        ));
                    }
                    trait_impls_found.push((
                        implementation.as_ref(),
                        trait_type,
                        declaration.origin.clone(),
                    ));
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

    let roles = &project.core_roles;
    let variant = |identity: &EntityId| nominals.constructors[identity].1;
    let mut types = Types::new(CoreEnums {
        option: OptionEnum {
            declaration: nominals.by_identity[&roles.option.declaration],
            some: variant(&roles.option.some),
            none: variant(&roles.option.none),
        },
        ordering: OrderingEnum {
            less: variant(&roles.ordering.less),
            equal: variant(&roles.ordering.equal),
        },
    });
    for declaration in &nominals.declarations {
        types.nominals.push(NominalInfo {
            name: declaration.name.clone(),
            is_enum: matches!(declaration.shape, Shape::Enum(_)),
            origin: declaration.origin.clone(),
        });
    }
    // Every non-generic declaration is instantiated, so its fields are checked
    // even when no function mentions it.
    for (index, declaration) in nominals.declarations.iter().enumerate() {
        if declaration.type_parameters.is_empty() {
            instantiate(&mut types, &nominals, index, Vec::new())?;
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
        let owner = resolve_type(&mut types, &nominals, &target, &BTreeMap::new(), &origin)?;
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
            let visibility = Visibility {
                public: member.public,
                module: member.identity.module.clone(),
            };
            if methods
                .insert(
                    (declaration, name.clone()),
                    (member.identity.clone(), visibility),
                )
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

    let traits = collect_traits(&traits_found, &project.core_roles, &nominals, &mut types)?;
    let found_impls = collect_trait_impls(
        &trait_impls_found,
        &traits,
        &nominals,
        &mut types,
        &mut functions_found,
    )?;
    for implementation in &found_impls {
        let trait_index = implementation.trait_index;
        let written = types.written.entry(implementation.owner).or_default();
        let method = implementation.methods.first().copied();
        match traits.comparison(trait_index) {
            Some(Comparison::PartialEq) => written.eq = method,
            Some(Comparison::Eq) => written.total_eq = true,
            Some(Comparison::PartialOrd) => written.partial_cmp = method,
            Some(Comparison::Ord) => written.cmp = method,
            None if trait_index == traits.clone => written.clone = method,
            None if trait_index == traits.drop => written.drop = method,
            None => {}
        }
    }
    // Value types are copied, which is their `Clone`.
    if let Some(implementation) = found_impls.iter().find(|implementation| {
        implementation.trait_index == traits.clone && !types.is_entity(implementation.owner)
    }) {
        return Err(CheckDiagnostic {
            kind: CheckDiagnosticKind::DuplicateImpl,
            primary: Some(implementation.origin.clone()),
            message: format!(
                "`{}` is a value type, which is copied; its `Clone` is the copy",
                types.name(implementation.owner)
            ),
        });
    }
    nominals.check_keys(&types)?;
    check_interfaces(project, &nominals, &traits)?;

    let mut signatures = BTreeMap::new();
    for (index, found) in functions_found.iter().enumerate() {
        let signature = check_signature(
            index,
            found.function,
            &found.origin,
            found.owner,
            &nominals,
            &traits,
            &mut types,
        )?;
        signatures.insert(found.identity.clone(), signature);
    }
    let trait_impls = check_trait_impls(
        &found_impls,
        &traits,
        &signatures,
        &functions_found,
        &mut types,
    )?;

    let identities = functions_found
        .iter()
        .map(|found| found.identity.clone())
        .collect::<Vec<_>>();
    let mut functions = Vec::new();
    let mut calls = Vec::new();
    for found in &functions_found {
        let (function, origin) = (found.function, &found.origin);
        let signature = &signatures[&found.identity];
        let mut checker = BodyChecker {
            types: &mut types,
            nominals: &nominals,
            signatures: &signatures,
            identities: &identities,
            methods: &methods,
            traits: &traits,
            trait_impls: &trait_impls,
            library: origin.library,
            source: origin.source.clone(),
            module: found.identity.module.clone(),
            type_scope: signature.type_scope.clone(),
            type_parameters: signature.type_parameters.clone(),
            calls: Vec::new(),
            locals: Vec::new(),
            local_ids: BTreeMap::new(),
            mutable: Vec::new(),
            guarded: Vec::new(),
            loops: Vec::new(),
            result: signature.result,
            result_borrow: signature.result_borrow,
            depth: 0,
        };
        let mut parameters = Vec::new();
        for (parameter, (ty, borrow)) in function.parameters.iter().zip(&signature.parameters) {
            parameters.push(match borrow {
                Some(kind) => checker.declare_borrow(&parameter.binding.identity, *ty, *kind),
                None => checker.declare(
                    &parameter.binding.identity,
                    *ty,
                    parameter.mutable.is_some(),
                ),
            });
        }
        let body = checker.check_block(&function.body, Some(signature.result))?;
        calls.push(checker.calls);
        functions.push(Function {
            name: found.name.clone(),
            parameters,
            locals: checker.locals,
            result: signature.result,
            result_borrow: signature.result_borrow,
            body,
        });
    }
    check_recursion(&calls, &types)?;
    let main = functions_found
        .iter()
        .position(|found| {
            found.identity.module == ModuleRef::root(project.entry)
                && found.identity.kind == EntityKind::Function
                && found.identity.name == "main"
        })
        .filter(|&index| {
            let signature = &signatures[&functions_found[index].identity];
            signature.type_parameters.is_empty()
                && signature.parameters.is_empty()
                && signature.result == Type::UNIT
        })
        .ok_or_else(|| CheckDiagnostic {
            kind: CheckDiagnosticKind::MissingMain,
            primary: None,
            message: "the entry library needs `fn main()` without parameters that returns `Unit`"
                .to_owned(),
        })?;

    let generic = functions_found
        .iter()
        .map(|found| !signatures[&found.identity].type_parameters.is_empty())
        .collect::<Vec<_>>();
    Ok(Program {
        types,
        functions,
        origins: functions_found
            .iter()
            .map(|found| found.origin.clone())
            .collect(),
        generic,
        main,
        impls: trait_impls,
        display: traits.display,
    })
}

/// Collects the trait declarations. `Self` in their method signatures is
/// the type parameter at index 0.
fn collect_traits<'a>(
    found: &[(EntityId, &'a crate::project::ResolvedDeclaration, bool)],
    roles: &CoreRoles,
    nominals: &Nominals,
    types: &mut Types,
) -> Result<Traits<'a>, CheckDiagnostic> {
    let by_identity = found
        .iter()
        .enumerate()
        .map(|(index, (identity, _, _))| (identity.clone(), index))
        .collect::<BTreeMap<_, _>>();
    let self_type = types.intern(TypeKind::Param {
        index: 0,
        name: "Self".to_owned(),
        copy: false,
    });
    let mut declarations = Vec::new();
    let mut signatures = Vec::new();
    for (identity, declaration, core) in found {
        let ResolvedDeclarationKind::Trait {
            type_parameters,
            supertraits,
            members,
        } = &declaration.kind
        else {
            unreachable!("only traits are collected here")
        };
        if !type_parameters.is_empty() {
            return Err(unsupported(
                Some(declaration.origin.clone()),
                "generic traits",
            ));
        }
        // The declaration check has made sure these name traits.
        let supertraits = supertraits
            .iter()
            .filter_map(|supertrait| match &supertrait.reference {
                ResolvedReference::Exact { target, .. } => by_identity.get(target).copied(),
                ResolvedReference::Selection { .. } => None,
            })
            .collect();
        let methods = members
            .iter()
            .filter(|member| matches!(member.kind, ResolvedTraitMemberKind::Method(_)))
            .collect::<Vec<_>>();
        let associated_types = methods.len() != members.len();
        let mut method_signatures = Vec::new();
        if !associated_types {
            let scope = BTreeMap::from([(identity.clone(), self_type)]);
            for member in &methods {
                let ResolvedTraitMemberKind::Method(signature) = &member.kind else {
                    unreachable!("only methods were kept")
                };
                let origin = match &member.identity.site {
                    EntitySite::Source(site) => site.clone(),
                    _ => declaration.origin.clone(),
                };
                method_signatures.push(trait_method_signature(
                    signature, &scope, self_type, nominals, types, &origin,
                )?);
            }
        }
        declarations.push(TraitDeclaration {
            name: identity.name.clone(),
            visibility: Visibility {
                public: declaration.public,
                module: identity.module.clone(),
            },
            supertraits,
            methods,
            associated_types,
            core: *core,
        });
        signatures.push(method_signatures);
    }
    Ok(Traits {
        display: by_identity[&roles.display.declaration],
        copy: by_identity[&roles.copy],
        clone: by_identity[&roles.clone.declaration],
        drop: by_identity[&roles.drop.declaration],
        comparisons: [
            by_identity[&roles.partial_eq.declaration],
            by_identity[&roles.eq],
            by_identity[&roles.partial_ord.declaration],
            by_identity[&roles.ord.declaration],
        ],
        declarations,
        by_identity,
        signatures,
    })
}

/// The signature of a trait method, whose `self` has type `self_type`.
fn trait_method_signature(
    signature: &crate::project::ResolvedFunctionSignature,
    scope: &BTreeMap<EntityId, Type>,
    self_type: Type,
    nominals: &Nominals,
    types: &mut Types,
    origin: &OriginRef,
) -> Result<Signature, CheckDiagnostic> {
    if !signature.type_parameters.is_empty() || !signature.effect_parameters.is_empty() {
        return Err(unsupported(Some(origin.clone()), "generic trait methods"));
    }
    if signature
        .parameters
        .first()
        .is_none_or(|parameter| parameter.binding.identity.name != "self")
    {
        return Err(unsupported(
            Some(origin.clone()),
            "trait functions without `self`",
        ));
    }
    let mut parameters = Vec::new();
    for parameter in &signature.parameters {
        let ty = match &parameter.annotation {
            Some(annotation) => resolve_type(types, nominals, annotation, scope, origin)?,
            None => self_type,
        };
        parameters.push((ty, parameter.borrow.map(|(_, kind)| kind)));
    }
    let result = match &signature.return_type {
        Some(ty) => resolve_type(types, nominals, ty, scope, origin)?,
        None => Type::UNIT,
    };
    Ok(Signature {
        index: usize::MAX,
        receiver: true,
        type_parameters: Vec::new(),
        type_scope: BTreeMap::new(),
        parameters,
        result,
        result_borrow: signature.return_borrow.map(|(_, kind)| kind),
    })
}

/// An `impl Trait for Type` whose methods are added to the functions.
struct FoundImpl {
    trait_index: usize,
    owner: Type,
    /// The function of each trait method, in the trait's order.
    methods: Vec<usize>,
    origin: OriginRef,
}

/// Collects the trait impls and adds their methods to `functions`.
fn collect_trait_impls<'a>(
    found: &[(
        &'a crate::project::ResolvedImpl,
        &ResolvedNamedType,
        OriginRef,
    )],
    traits: &Traits,
    nominals: &Nominals,
    types: &mut Types,
    functions: &mut Vec<FoundFunction<'a>>,
) -> Result<Vec<FoundImpl>, CheckDiagnostic> {
    let mut impls = Vec::new();
    for (implementation, trait_type, origin) in found {
        let trait_index = match &trait_type.reference {
            ResolvedReference::Exact { target, .. } => traits.by_identity.get(target).copied(),
            ResolvedReference::Selection { .. } => None,
        };
        let Some(trait_index) = trait_index else {
            return Err(unsupported(Some(origin.clone()), "impls of this trait"));
        };
        let declaration = &traits.declarations[trait_index];
        if trait_index == traits.copy {
            return Err(CheckDiagnostic {
                kind: CheckDiagnosticKind::DuplicateImpl,
                primary: Some(origin.clone()),
                message: "only the compiler implements `Copy`, for value types".to_owned(),
            });
        }
        if !implementation.type_parameters.is_empty() {
            return Err(unsupported(Some(origin.clone()), "generic impls"));
        }
        if declaration.associated_types {
            return Err(unsupported(Some(origin.clone()), "associated types"));
        }
        if !traits.supported(trait_index) {
            return Err(unsupported(
                Some(origin.clone()),
                &format!("impls of `{}`", declaration.name),
            ));
        }
        let target_type = ResolvedType {
            span: implementation.target.span,
            kind: ResolvedTypeKind::Named(Box::new(implementation.target.clone())),
        };
        let owner = resolve_type(types, nominals, &target_type, &BTreeMap::new(), origin)?;
        let &TypeKind::Nominal {
            declaration: nominal,
            ..
        } = types.kind(owner)
        else {
            return Err(unsupported(
                Some(origin.clone()),
                "impls for built-in types",
            ));
        };
        if !nominals.declarations[nominal].type_parameters.is_empty() {
            return Err(unsupported(Some(origin.clone()), "impls for generic types"));
        }
        let mut methods = vec![None; declaration.methods.len()];
        for member in &implementation.members {
            let member_origin = match &member.identity.site {
                EntitySite::Source(site) => site.clone(),
                _ => origin.clone(),
            };
            let ResolvedImplMemberKind::Function(function) = &member.kind else {
                return Err(unsupported(Some(member_origin), "associated types"));
            };
            let name = &member.identity.name;
            let Some(position) = declaration
                .methods
                .iter()
                .position(|method| method.identity.name == *name)
            else {
                return Err(CheckDiagnostic {
                    kind: CheckDiagnosticKind::UnknownMethod,
                    primary: Some(member_origin),
                    message: format!("`{}` has no method `{name}`", declaration.name),
                });
            };
            methods[position] = Some(functions.len());
            functions.push(FoundFunction {
                name: format!("{}_{name}", types.name(owner)),
                identity: member.identity.clone(),
                function,
                origin: member_origin,
                owner: Some(owner),
            });
        }
        let methods = methods
            .into_iter()
            .enumerate()
            .map(|(position, method)| {
                method.ok_or_else(|| CheckDiagnostic {
                    kind: CheckDiagnosticKind::MissingMethod,
                    primary: Some(origin.clone()),
                    message: format!(
                        "this impl of `{}` lacks the method `{}`",
                        declaration.name,
                        traits.method_name(trait_index, position)
                    ),
                })
            })
            .collect::<Result<_, _>>()?;
        impls.push(FoundImpl {
            trait_index,
            owner,
            methods,
            origin: origin.clone(),
        });
    }
    Ok(impls)
}

/// Checks that each impl is the only one of its trait for its type, that
/// its methods have the trait's signatures, and that the type implements
/// the trait's supertraits.
fn check_trait_impls(
    found: &[FoundImpl],
    traits: &Traits,
    signatures: &BTreeMap<EntityId, Signature>,
    functions: &[FoundFunction],
    types: &mut Types,
) -> Result<Impls, CheckDiagnostic> {
    let mut impls = Impls::new();
    for implementation in found {
        let key = (implementation.trait_index, implementation.owner);
        if impls.insert(key, implementation.methods.clone()).is_some() {
            return Err(CheckDiagnostic {
                kind: CheckDiagnosticKind::DuplicateImpl,
                primary: Some(implementation.origin.clone()),
                message: format!(
                    "`{}` already implements `{}`",
                    types.name(implementation.owner),
                    traits.declarations[implementation.trait_index].name
                ),
            });
        }
    }
    for implementation in found {
        let trait_index = implementation.trait_index;
        let declaration = &traits.declarations[trait_index];
        for (position, &function) in implementation.methods.iter().enumerate() {
            let expected = substitute_signature(
                types,
                &traits.signatures[trait_index][position],
                &[implementation.owner],
            )?;
            let actual = &signatures[&functions[function].identity];
            if !actual.receiver
                || !actual.type_parameters.is_empty()
                || actual.parameters != expected.parameters
                || actual.result != expected.result
                || actual.result_borrow != expected.result_borrow
            {
                return Err(CheckDiagnostic {
                    kind: CheckDiagnosticKind::TypeMismatch,
                    primary: Some(functions[function].origin.clone()),
                    message: format!(
                        "`{}` of `{}` must be `{}`",
                        traits.method_name(trait_index, position),
                        declaration.name,
                        signature_text(types, &expected)
                    ),
                });
            }
        }
        for &supertrait in &declaration.supertraits {
            if !implements(traits, &impls, &[], types, implementation.owner, supertrait) {
                return Err(CheckDiagnostic {
                    kind: CheckDiagnosticKind::UnsatisfiedBound,
                    primary: Some(implementation.origin.clone()),
                    message: format!(
                        "`{}` implements `{}` but not its supertrait `{}`",
                        types.name(implementation.owner),
                        declaration.name,
                        traits.declarations[supertrait].name
                    ),
                });
            }
        }
    }
    Ok(impls)
}

/// `signature` with its type parameters replaced by `arguments`.
fn substitute_signature(
    types: &mut Types,
    signature: &Signature,
    arguments: &[Type],
) -> Result<Signature, CheckDiagnostic> {
    let substitute = |types: &mut Types, ty| {
        types
            .substitute(ty, arguments)
            .map_err(|error| error.diagnostic(types))
    };
    let mut result = signature.clone();
    for (ty, _) in &mut result.parameters {
        *ty = substitute(types, *ty)?;
    }
    result.result = substitute(types, result.result)?;
    Ok(result)
}

/// A method signature as written, such as `fn(&self, other: &Point) -> Bool`.
fn signature_text(types: &Types, signature: &Signature) -> String {
    let borrow = |kind: Option<BorrowKind>| match kind {
        None => "",
        Some(BorrowKind::Shared) => "&",
        Some(BorrowKind::Mutable) => "&mut ",
    };
    let parameters = signature
        .parameters
        .iter()
        .enumerate()
        .map(|(position, (ty, kind))| {
            if position == 0 && signature.receiver {
                format!("{}self", borrow(*kind))
            } else {
                format!("{}{}", borrow(*kind), types.name(*ty))
            }
        })
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "fn({parameters}) -> {}{}",
        borrow(signature.result_borrow),
        types.name(signature.result)
    )
}

/// Whether `ty` implements the trait: a type parameter through its bounds,
/// another type through an impl, or through what the compiler provides:
/// `Copy` of a value type, `Clone` and the comparisons through the parts,
/// and `Display` of a built-in type. Every check of a bound, a supertrait
/// or a method that a trait gives asks here.
fn implements(
    traits: &Traits,
    impls: &Impls,
    type_parameters: &[TypeParameter],
    types: &Types,
    ty: Type,
    trait_index: usize,
) -> bool {
    let param_implements = |index: usize| type_parameters[index].traits.contains(&trait_index);
    match types.kind(ty) {
        TypeKind::Param { index, .. } => param_implements(*index),
        _ => {
            impls.contains_key(&(trait_index, ty))
                || (trait_index == traits.display && is_printable(ty))
                || (trait_index == traits.copy && !types.is_entity(ty))
                || (trait_index == traits.clone && types.clones(ty, &param_implements))
                || traits
                    .comparison(trait_index)
                    .is_some_and(|comparison| types.compares(ty, comparison, &param_implements))
        }
    }
}

/// A call of a named function: the callee, its type arguments in the
/// caller's type parameters (none unless it is generic), and where the call
/// is.
type NamedCall = (usize, Vec<Type>, OriginRef);

/// Rejects polymorphic recursion. Inside a group of functions that call
/// each other, every type argument must be one of the caller's own type
/// parameters or a type without type parameters; then the instances of the
/// group draw from a finite set of types, and instantiation ends.
fn check_recursion(calls: &[Vec<NamedCall>], types: &Types) -> Result<(), CheckDiagnostic> {
    let edges = calls
        .iter()
        .map(|calls| calls.iter().map(|(callee, _, _)| *callee).collect())
        .collect::<Vec<Vec<usize>>>();
    let component = strongly_connected(&edges);
    for (caller, calls) in calls.iter().enumerate() {
        for (callee, arguments, origin) in calls {
            if component[*callee] != component[caller] {
                continue;
            }
            if let Some(argument) = arguments.iter().find(|argument| {
                types.is_generic(**argument)
                    && !matches!(types.kind(**argument), TypeKind::Param { .. })
            }) {
                return Err(CheckDiagnostic {
                    kind: CheckDiagnosticKind::PolymorphicRecursion,
                    primary: Some(origin.clone()),
                    message: format!(
                        "this recursive call passes `{}` as a type argument; inside recursion a type argument must be a type parameter itself or mention none",
                        types.name(*argument)
                    ),
                });
            }
        }
    }
    Ok(())
}

/// Tarjan's algorithm: the strongly connected component of each node.
fn strongly_connected(edges: &[Vec<usize>]) -> Vec<usize> {
    struct State<'e> {
        edges: &'e [Vec<usize>],
        index: Vec<Option<usize>>,
        low: Vec<usize>,
        stack: Vec<usize>,
        on_stack: Vec<bool>,
        component: Vec<usize>,
        next: usize,
        components: usize,
    }
    fn visit(state: &mut State, node: usize) {
        state.index[node] = Some(state.next);
        state.low[node] = state.next;
        state.next += 1;
        state.stack.push(node);
        state.on_stack[node] = true;
        for &next in &state.edges[node] {
            match state.index[next] {
                None => {
                    visit(state, next);
                    state.low[node] = state.low[node].min(state.low[next]);
                }
                Some(index) if state.on_stack[next] => {
                    state.low[node] = state.low[node].min(index);
                }
                Some(_) => {}
            }
        }
        if Some(state.low[node]) == state.index[node] {
            while let Some(member) = state.stack.pop() {
                state.on_stack[member] = false;
                state.component[member] = state.components;
                if member == node {
                    break;
                }
            }
            state.components += 1;
        }
    }
    let count = edges.len();
    let mut state = State {
        edges,
        index: vec![None; count],
        low: vec![0; count],
        stack: Vec::new(),
        on_stack: vec![false; count],
        component: vec![0; count],
        next: 0,
        components: 0,
    };
    for node in 0..count {
        if state.index[node].is_none() {
            visit(&mut state, node);
        }
    }
    state.component
}

/// `declaration` applied to `arguments`: an instance of its template, whose
/// fields are worked out from the declaration the first time it is used.
fn instantiate(
    types: &mut Types,
    nominals: &Nominals,
    declaration: usize,
    arguments: Vec<Type>,
) -> Result<Type, CheckDiagnostic> {
    template(types, nominals, declaration)?;
    types
        .instantiate(declaration, arguments)
        .map_err(|error| error.diagnostic(types))
}

/// The template of `declaration`: the declaration applied to its own type
/// parameters, with the field types it declares. Every instance
/// substitutes these, so the fields of an instance have one source.
fn template(
    types: &mut Types,
    nominals: &Nominals,
    declaration: usize,
) -> Result<Type, CheckDiagnostic> {
    if let Some(template) = types.template(declaration) {
        return Ok(template);
    }
    let info = &nominals.declarations[declaration];
    let parameters = info
        .type_parameters
        .iter()
        .enumerate()
        .map(|(index, parameter)| {
            types.intern(TypeKind::Param {
                index,
                name: parameter.name.clone(),
                copy: false,
            })
        })
        .collect::<Vec<_>>();
    let template = types.begin_template(declaration, parameters.clone());
    let substitution = info
        .type_parameters
        .iter()
        .cloned()
        .zip(parameters)
        .collect::<BTreeMap<_, _>>();
    let mut field = |ty: &ResolvedType, name: String| -> Result<Field, CheckDiagnostic> {
        let ty = resolve_type(types, nominals, ty, &substitution, &info.origin)?;
        if ty == Type::NEVER {
            return Err(unsupported(Some(info.origin.clone()), "`Never` fields"));
        }
        Ok(Field { name, ty })
    };
    let variants = match &info.shape {
        Shape::Struct(fields) => vec![Variant {
            name: info.name.clone(),
            positional: false,
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
                    positional: matches!(variant.fields, ResolvedVariantFields::Positional(_)),
                    fields,
                })
            })
            .collect::<Result<_, CheckDiagnostic>>()?,
    };
    types
        .finish_template(declaration, variants)
        .map_err(|error| error.diagnostic(types))?;
    Ok(template)
}

/// Rejects a private type or trait in a public interface: the signature and
/// bounds of a public function, of a public method of a public type, or of
/// a method of a public trait; an associated type of a public trait or of a
/// public type; a supertrait of a public trait; a public field of a public
/// struct; and a field of a variant of a public enum. Code outside the
/// module could otherwise hold or name what it cannot see.
///
/// Every kind of declaration and member is matched by name, and signatures
/// are taken apart field by field, so supporting a new one means deciding
/// here which of its types are its interface.
fn check_interfaces(
    project: &ResolvedProject,
    nominals: &Nominals,
    traits: &Traits,
) -> Result<(), CheckDiagnostic> {
    let private = |ty: &ResolvedType| private_in(ty, nominals, traits);
    let bounds = |parameters: &[crate::project::ResolvedTypeParameter]| {
        parameters
            .iter()
            .flat_map(|parameter| &parameter.bounds)
            .find_map(|bound| private_named(bound, nominals, traits))
    };
    let signature = |type_parameters: &[crate::project::ResolvedTypeParameter],
                     parameters: &[crate::project::ResolvedParameter],
                     return_type: &Option<ResolvedType>| {
        bounds(type_parameters)
            .or_else(|| {
                parameters
                    .iter()
                    .filter_map(|parameter| parameter.annotation.as_ref())
                    .find_map(private)
            })
            .or_else(|| return_type.as_ref().and_then(private))
    };
    // Effect parameters and effect annotations are rejected as unsupported
    // when the signature is checked.
    let function = |function: &ResolvedFunction| {
        let ResolvedFunction {
            type_parameters,
            effect_parameters: _,
            parameters,
            return_borrow: _,
            return_type,
            effects: _,
            body: _,
        } = function;
        signature(type_parameters, parameters, return_type)
    };
    let method = |method: &crate::project::ResolvedFunctionSignature| {
        let crate::project::ResolvedFunctionSignature {
            identity: _,
            type_parameters,
            effect_parameters: _,
            parameters,
            return_borrow: _,
            return_type,
            effects: _,
        } = method;
        signature(type_parameters, parameters, return_type)
    };
    let check = |origin: &OriginRef, found: Option<(Span, String)>, place: &str| match found {
        Some((span, name)) => Err(CheckDiagnostic {
            kind: CheckDiagnosticKind::PrivateInInterface,
            primary: Some(origin.at(span)),
            message: format!("`{name}` is private, so it cannot appear in {place}"),
        }),
        None => Ok(()),
    };
    for (module, resolved) in &project.modules {
        let Some(body) = &resolved.body else {
            continue;
        };
        if module.source_library() == Some(project.core) {
            continue;
        }
        for declaration in &body.declarations {
            let origin = &declaration.origin;
            let name = declaration
                .identity
                .as_ref()
                .map_or("", |identity| identity.name.as_str());
            match &declaration.kind {
                ResolvedDeclarationKind::Function(declared) => {
                    if declaration.public {
                        let place = format!("the public signature of `{name}`");
                        check(origin, function(declared), &place)?;
                    }
                }
                ResolvedDeclarationKind::Struct {
                    type_parameters,
                    fields,
                } => {
                    if declaration.public {
                        let found = bounds(type_parameters).or_else(|| {
                            fields
                                .iter()
                                .filter(|field| field.public)
                                .find_map(|field| private(&field.ty))
                        });
                        check(origin, found, &format!("the public fields of `{name}`"))?;
                    }
                }
                ResolvedDeclarationKind::Enum {
                    type_parameters,
                    variants,
                } => {
                    if declaration.public {
                        let found = bounds(type_parameters).or_else(|| {
                            variants.iter().find_map(|variant| match &variant.fields {
                                ResolvedVariantFields::Unit => None,
                                ResolvedVariantFields::Positional(fields) => {
                                    fields.iter().find_map(private)
                                }
                                ResolvedVariantFields::Named(fields) => {
                                    fields.iter().find_map(|field| private(&field.ty))
                                }
                            })
                        });
                        check(origin, found, &format!("the variants of `{name}`"))?;
                    }
                }
                ResolvedDeclarationKind::Trait {
                    type_parameters,
                    supertraits,
                    members,
                } => {
                    if !declaration.public {
                        continue;
                    }
                    let place = format!("the public trait `{name}`");
                    // Implementing the trait means implementing its
                    // supertraits too.
                    let found = bounds(type_parameters).or_else(|| {
                        supertraits
                            .iter()
                            .find_map(|supertrait| private_named(supertrait, nominals, traits))
                    });
                    check(origin, found, &place)?;
                    for member in members {
                        let found = match &member.kind {
                            ResolvedTraitMemberKind::Method(declared) => method(declared),
                            ResolvedTraitMemberKind::AssociatedType { bounds, default } => bounds
                                .iter()
                                .find_map(|bound| private_named(bound, nominals, traits))
                                .or_else(|| default.as_ref().and_then(private)),
                        };
                        check(origin, found, &place)?;
                    }
                }
                ResolvedDeclarationKind::InherentImpl(implementation) => {
                    // A method of a private type cannot be reached from
                    // outside, whatever its own visibility.
                    let owner_public = match &implementation.target.reference {
                        ResolvedReference::Exact { target, .. } => nominals
                            .by_identity
                            .get(target)
                            .is_some_and(|&index| nominals.declarations[index].public),
                        ResolvedReference::Selection { .. } => false,
                    };
                    if !owner_public {
                        continue;
                    }
                    for member in implementation.members.iter().filter(|member| member.public) {
                        let member_origin = match &member.identity.site {
                            EntitySite::Source(site) => site,
                            _ => origin,
                        };
                        let found = match &member.kind {
                            ResolvedImplMemberKind::Function(declared) => function(declared),
                            ResolvedImplMemberKind::AssociatedType(ty) => private(ty),
                        };
                        let place = format!("the public `{}`", member.identity.name);
                        check(member_origin, found, &place)?;
                    }
                }
                // The interface of a trait impl is the trait's.
                ResolvedDeclarationKind::TraitImpl { .. } | ResolvedDeclarationKind::Module(_) => {}
                // The checker rejects these as unsupported before this
                // check runs.
                ResolvedDeclarationKind::Effect { .. }
                | ResolvedDeclarationKind::EffectAlias { .. }
                | ResolvedDeclarationKind::ExternFunction(_)
                | ResolvedDeclarationKind::ExternType { .. }
                | ResolvedDeclarationKind::TypeAlias { .. }
                | ResolvedDeclarationKind::Const { .. } => {}
            }
        }
    }
    Ok(())
}
/// The span and name of the first private type or trait that `ty` names.
fn private_in(ty: &ResolvedType, nominals: &Nominals, traits: &Traits) -> Option<(Span, String)> {
    match &ty.kind {
        ResolvedTypeKind::Named(named) => private_named(named, nominals, traits),
        ResolvedTypeKind::Grouped(inner) => private_in(inner, nominals, traits),
        ResolvedTypeKind::Tuple(elements) => elements
            .iter()
            .find_map(|element| private_in(element, nominals, traits)),
        ResolvedTypeKind::Function {
            parameters,
            return_type,
            ..
        } => parameters
            .iter()
            .find_map(|parameter| private_in(&parameter.ty, nominals, traits))
            .or_else(|| {
                return_type
                    .as_deref()
                    .and_then(|result| private_in(result, nominals, traits))
            }),
    }
}

fn private_named(
    named: &ResolvedNamedType,
    nominals: &Nominals,
    traits: &Traits,
) -> Option<(Span, String)> {
    if let ResolvedReference::Exact { target, .. } = &named.reference {
        let public = if let Some(&index) = nominals.by_identity.get(target) {
            Some(nominals.declarations[index].public)
        } else {
            traits
                .by_identity
                .get(target)
                .map(|&index| traits.declarations[index].visibility.public)
        };
        if public == Some(false) {
            return Some((named.span, target.name.clone()));
        }
    }
    named.arguments.iter().find_map(|argument| match argument {
        ResolvedTypeArgument::Type(ty) | ResolvedTypeArgument::AssociatedType { value: ty, .. } => {
            private_in(ty, nominals, traits)
        }
    })
}

/// Checks the signature of a function, or of a method of `self_type`.
fn check_signature(
    index: usize,
    function: &ResolvedFunction,
    origin: &OriginRef,
    self_type: Option<Type>,
    nominals: &Nominals,
    traits: &Traits,
    types: &mut Types,
) -> Result<Signature, CheckDiagnostic> {
    if !function.effect_parameters.is_empty() {
        return Err(unsupported(Some(origin.clone()), "effect parameters"));
    }
    if function.effects.is_some() {
        return Err(unsupported(Some(origin.clone()), "effect annotations"));
    }
    if !function.type_parameters.is_empty() && self_type.is_some() {
        return Err(unsupported(Some(origin.clone()), "generic methods"));
    }
    let mut type_parameters = Vec::new();
    let mut type_scope = BTreeMap::new();
    for (position, parameter) in function.type_parameters.iter().enumerate() {
        let mut bounds = TypeParameter {
            name: parameter.binding.identity.name.clone(),
            traits: BTreeSet::new(),
        };
        for bound in &parameter.bounds {
            let trait_index = match &bound.reference {
                ResolvedReference::Exact { target, .. } => traits.by_identity.get(target).copied(),
                ResolvedReference::Selection { .. } => None,
            };
            if let Some(trait_index) = trait_index {
                if trait_index == traits.drop {
                    return Err(CheckDiagnostic {
                        kind: CheckDiagnosticKind::InvalidBound,
                        primary: Some(origin.at(bound.span)),
                        message:
                            "`Drop` cannot be a bound; `drop` runs only when a value is released"
                                .to_owned(),
                    });
                }
                if !traits.supported(trait_index) {
                    return Err(unsupported(
                        Some(origin.at(bound.span)),
                        &format!("bounds on `{}`", traits.declarations[trait_index].name),
                    ));
                }
                traits.closure(trait_index, &mut bounds.traits);
            } else {
                return Err(unsupported(Some(origin.at(bound.span)), "this bound"));
            }
        }
        let ty = types.intern(TypeKind::Param {
            index: position,
            name: bounds.name.clone(),
            copy: bounds.traits.contains(&traits.copy),
        });
        type_scope.insert(parameter.binding.identity.clone(), ty);
        type_parameters.push(bounds);
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
                resolve_type(types, nominals, annotation, &type_scope, origin)?
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
        Some(ty) => resolve_type(types, nominals, ty, &type_scope, origin)?,
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
        type_parameters,
        type_scope,
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
) -> Result<Type, CheckDiagnostic> {
    match &ty.kind {
        ResolvedTypeKind::Grouped(inner) => {
            resolve_type(types, nominals, inner, substitution, origin)
        }
        ResolvedTypeKind::Tuple(elements) => {
            let elements = elements
                .iter()
                .map(|element| resolve_type(types, nominals, element, substitution, origin))
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
                return Err(unsupported(Some(origin.at(ty.span)), "this type"));
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
                return resolve_type(types, nominals, &self_type, substitution, origin);
            }
            // `Self` in a trait stands for the implementing type, which
            // `substitution` gives under the trait's identity.
            if target.kind == EntityKind::SelfType
                && let Some(&self_type) = substitution.iter().find_map(|(owner, ty)| {
                    (target.owner.as_ref() == Some(&owner_key_from_entity(owner))).then_some(ty)
                })
            {
                return Ok(self_type);
            }
            let mut arguments = Vec::new();
            for argument in &named.arguments {
                let ResolvedTypeArgument::Type(argument) = argument else {
                    return Err(unsupported(Some(origin.at(ty.span)), "this type"));
                };
                arguments.push(resolve_type(
                    types,
                    nominals,
                    argument,
                    substitution,
                    origin,
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
                        Some(origin.at(ty.span)),
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
                    _ => return Err(unsupported(Some(origin.at(ty.span)), "this type")),
                };
                nominals.require_key(types, *key, origin.at(ty.span))?;
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
                        primary: Some(origin.at(ty.span)),
                        message: format!(
                            "`{}` takes {expected} type arguments, found {}",
                            target.name,
                            arguments.len()
                        ),
                    });
                }
                return instantiate(types, nominals, declaration, arguments);
            }
            Err(unsupported(Some(origin.at(ty.span)), "this type"))
        }
        ResolvedTypeKind::Function { .. } => {
            Err(unsupported(Some(origin.at(ty.span)), "function types"))
        }
    }
}

fn unsupported(primary: Option<OriginRef>, what: &str) -> CheckDiagnostic {
    CheckDiagnostic {
        kind: CheckDiagnosticKind::Unsupported,
        primary,
        message: format!("{what} are not supported yet"),
    }
}

/// A place and its type.
type PlaceAccess = (Place, Type);

/// A checked operand of a borrow, a method call or a loop.
enum Operand {
    Place(PlaceAccess),
    /// Any other expression; a borrow of it borrows a temporary.
    Value(Expr),
}

impl Operand {
    fn ty(&self) -> Type {
        match self {
            Self::Place((_, ty)) => *ty,
            Self::Value(value) => value.ty,
        }
    }

    /// The expression again: a place, or the value.
    fn into_expr(self) -> Expr {
        match self {
            Self::Place((place, ty)) => Expr {
                ty,
                span: place.span,
                kind: ExprKind::Place(place),
            },
            Self::Value(value) => value,
        }
    }
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
    /// The identity of each function, by index.
    identities: &'a [EntityId],
    methods: &'a Methods,
    traits: &'a Traits<'a>,
    trait_impls: &'a Impls,
    library: LibraryId,
    source: SourceRef,
    /// The module of the function, which decides what private items it
    /// may use.
    module: ModuleRef,
    /// The types of the function's type parameters, by identity.
    type_scope: BTreeMap<EntityId, Type>,
    type_parameters: Vec<TypeParameter>,
    /// Every call of a named function, for the recursion check.
    calls: Vec<NamedCall>,
    locals: Vec<Local>,
    /// The local of each binding. Name resolution has given every binding
    /// its own identity and decided where each name refers, so scopes are
    /// not tracked again here.
    local_ids: BTreeMap<EntityId, usize>,
    mutable: Vec<bool>,
    /// The `&mut` bindings of the arm whose guard is being checked, which
    /// the guard only reads.
    guarded: Vec<usize>,
    /// For each enclosing loop, whether a `break` leaves it.
    loops: Vec<bool>,
    result: Type,
    result_borrow: Option<BorrowKind>,
    /// How many blocks enclose the statement being checked.
    depth: usize,
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

    /// Why `place` cannot be changed, as a clause, or `None` if it can.
    fn unchangeable(&self, place: &Place) -> Option<String> {
        let name = &self.locals[place.local].name;
        if self.guarded.contains(&place.local) {
            Some(format!("a guard only reads `{name}`"))
        } else if self.mutable[place.local] {
            None
        } else if place.call.is_some() {
            Some(format!("`{name}` returns `&`"))
        } else {
            Some(format!("`{name}` is not declared `mut`"))
        }
    }

    /// Checks that `place` may be borrowed with `kind`: `&mut` needs a
    /// changeable place. Conflicts with other borrows are checked on the IR.
    fn check_borrow(
        &self,
        place: &Place,
        kind: BorrowKind,
        span: Span,
    ) -> Result<(), CheckDiagnostic> {
        if kind == BorrowKind::Mutable
            && let Some(reason) = self.unchangeable(place)
        {
            return Err(self.error(
                CheckDiagnosticKind::NotAssignable,
                span,
                format!("{reason}, so it cannot be borrowed with `&mut`"),
            ));
        }
        Ok(())
    }

    /// The borrow with `kind` of a checked operand: of a place, which `&mut`
    /// needs to be changeable, or of a temporary.
    fn borrow(
        &self,
        kind: BorrowKind,
        operand: Operand,
        span: Span,
    ) -> Result<Expr, CheckDiagnostic> {
        let (target, ty) = match operand {
            Operand::Place((place, ty)) => {
                self.check_borrow(&place, kind, span)?;
                (BorrowTarget::Place(place), ty)
            }
            Operand::Value(value) => {
                let ty = value.ty;
                (BorrowTarget::Value(value), ty)
            }
        };
        Ok(Expr {
            ty,
            span,
            kind: ExprKind::Borrow(kind, Box::new(target)),
        })
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
        index
    }

    fn resolve_type(
        &mut self,
        ty: &ResolvedType,
        substitution: &BTreeMap<EntityId, Type>,
    ) -> Result<Type, CheckDiagnostic> {
        let origin = self.at(ty.span);
        resolve_type(self.types, self.nominals, ty, substitution, &origin)
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
        let mut statements = Vec::new();
        let mut diverges = false;
        self.depth += 1;
        for statement in &block.statements {
            let (statement, statement_diverges) = self.check_statement(statement)?;
            diverges |= statement_diverges;
            statements.push(statement);
        }
        let (tail, ty) = match &block.tail {
            Some(tail) => {
                let discard = expected == Some(Type::UNIT);
                // The tail of the function body is its result.
                let tail = match self.result_borrow {
                    Some(kind) if self.depth == 1 => self.check_returned_borrow(tail, kind)?,
                    _ => self.check_expr(tail, expected)?,
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
        self.depth -= 1;
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
                let value = match (value, self.result_borrow) {
                    (Some(value), Some(kind)) => Some(self.check_returned_borrow(value, kind)?),
                    (Some(value), None) => {
                        let checked = self.check_expr(value, Some(self.result))?;
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
                let Some(breaks) = self.loops.last_mut() else {
                    return Err(self.error(
                        CheckDiagnosticKind::OutsideLoop,
                        span,
                        "`break` and `continue` must be inside a loop".to_owned(),
                    ));
                };
                if matches!(statement.kind, ResolvedStatementKind::Break) {
                    *breaks = true;
                    Ok((Statement::Break, true))
                } else {
                    Ok((Statement::Continue, true))
                }
            }
            ResolvedStatementKind::While { condition, body } => {
                self.loops.push(false);
                let checked = self.check_condition(condition).and_then(|condition| {
                    Ok((condition, self.check_block(body, Some(Type::UNIT))?))
                });
                self.loops.pop();
                let (condition, body) = checked?;
                Ok((Statement::While { condition, body }, false))
            }
            ResolvedStatementKind::Loop(body) => {
                self.loops.push(false);
                let body = self.check_block(body, Some(Type::UNIT));
                let breaks = self.loops.pop().expect("the loop was pushed");
                Ok((Statement::Loop(body?), !breaks))
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
            Some(annotation) => Some(self.resolve_type(annotation, &self.type_scope.clone())?),
            None => None,
        };
        // `&place`, `&mut place`, or a call that returns a borrow, binds a
        // borrow. Any other call is checked here and used below.
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
        if let Some((kind, (place, ty), operand_span)) = borrowed {
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
            let target = self.borrow(kind, Operand::Place((place, ty)), operand_span)?;
            let statement = match pattern {
                Some(pattern) => {
                    let pattern =
                        self.check_pattern(pattern, ty, Some(kind), &mut BTreeMap::new())?;
                    self.require_exhaustive(span, &pattern, ty)?;
                    Statement::LetPattern {
                        pattern,
                        value: target,
                    }
                }
                None => {
                    let [binding] = bindings.as_slice() else {
                        unreachable!("a let without a pattern binds one name")
                    };
                    let local = self.declare_borrow(&binding.identity, ty, kind);
                    Statement::Let {
                        local,
                        value: target,
                    }
                }
            };
            return Ok((statement, false));
        }
        if let Some((annotation_span, _)) = annotation_borrow {
            return Err(self.error(
                CheckDiagnosticKind::TypeMismatch,
                *annotation_span,
                "this binding borrows its value; write `&` or `&mut` before the value".to_owned(),
            ));
        }
        if let Some(pattern) = pattern {
            if let Some(mutable) = mutable {
                return Err(self.error(
                    CheckDiagnosticKind::NotAssignable,
                    *mutable,
                    "a pattern binds nothing to change; `mut` goes on the names in it".to_owned(),
                ));
            }
            let value_span = value.span;
            let value = match checked {
                Some(value) => value,
                None => self.check_expr(value, expected)?,
            };
            if let Some(expected) = expected {
                self.require(value_span, expected, value.ty)?;
            }
            if value.ty == Type::NEVER {
                return Ok((Statement::Expr(value), true));
            }
            let pattern = self.check_pattern(pattern, value.ty, None, &mut BTreeMap::new())?;
            self.require_exhaustive(span, &pattern, value.ty)?;
            return Ok((Statement::LetPattern { pattern, value }, false));
        }
        let [binding] = bindings.as_slice() else {
            unreachable!("a let without a pattern binds one name")
        };
        let value = match checked {
            Some(value) => value,
            None => self.check_expr(value, expected)?,
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
    /// `kind`: `&place`, `&mut place`, or a call that returns a borrow. The
    /// IR checks that it reaches only places of the parameters passed by
    /// borrow.
    fn check_returned_borrow(
        &mut self,
        value: &ResolvedExpr,
        kind: BorrowKind,
    ) -> Result<Expr, CheckDiagnostic> {
        let (operand, span) = match &value.kind {
            ResolvedExprKind::If { .. }
            | ResolvedExprKind::Match { .. }
            | ResolvedExprKind::Block(_) => {
                return Err(
                    self.unsupported(value.span, "borrowed results chosen by a branch or block")
                );
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
                // A borrow of a temporary ends when the function returns:
                // move and borrow checking reports it, as it does every
                // returned borrow that does not come from a parameter.
                (self.check_operand(operand, None)?, operand.span)
            }
            _ => match self.check_operand(value, None)? {
                Operand::Place((place, ty))
                    if place.call.is_some() && place.projections.is_empty() =>
                {
                    (Operand::Place((place, ty)), value.span)
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
        self.require(span, self.result, operand.ty())?;
        self.borrow(kind, operand, span)
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

    fn check_for(
        &mut self,
        statement: &ResolvedStatement,
        bindings: &[crate::project::ResolvedBinding],
        iterable: &ResolvedExpr,
        body: &ResolvedBlock,
    ) -> Result<(Statement, bool), CheckDiagnostic> {
        let span = statement.span;
        let (source, element, mode) = match &iterable.kind {
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
                (source, Type::INT, None)
            }
            ResolvedExprKind::Borrow {
                kind: (_, kind),
                operand,
            } => {
                let kind = *kind;
                let Operand::Place((place, ty)) = self.check_operand(operand, None)? else {
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
                self.check_borrow(&place, kind, operand.span)?;
                (ForSource::Borrowed(place, kind), element, Some(kind))
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
                    None => (ForSource::RangeValue(value), Type::INT, None),
                    Some(element) => (
                        ForSource::Taken {
                            container: value,
                            element,
                        },
                        element,
                        None,
                    ),
                }
            }
        };
        self.loops.push(false);
        let binding = match bindings {
            [single] => Ok(Pattern::Binding(
                self.declare_binding(&single.identity, element, mode),
                single.origin.span,
            )),
            many => match self.types.kind(element).clone() {
                TypeKind::Tuple(elements) if elements.len() == many.len() => Ok(Pattern::Tuple(
                    many.iter()
                        .zip(elements)
                        .map(|(binding, ty)| {
                            Pattern::Binding(
                                self.declare_binding(&binding.identity, ty, mode),
                                binding.origin.span,
                            )
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
        let body =
            binding.and_then(|checked| Ok((checked, self.check_block(body, Some(Type::UNIT))?)));
        self.loops.pop();
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

    /// Checks an expression and tells whether it is a place, for a position
    /// that borrows it or uses it as a receiver.
    fn check_operand(
        &mut self,
        expression: &ResolvedExpr,
        expected: Option<Type>,
    ) -> Result<Operand, CheckDiagnostic> {
        let checked = self.check_expr(expression, expected)?;
        Ok(match checked.kind {
            ExprKind::Place(place) => Operand::Place((place, checked.ty)),
            _ => Operand::Value(checked),
        })
    }

    /// A call that returns a borrow is a place, reached through a local
    /// named after the function; any other call is a value.
    fn call_place(&mut self, call: Expr, name: String) -> Expr {
        let ExprKind::Call {
            borrow: Some(kind), ..
        } = call.kind
        else {
            return call;
        };
        let (ty, span) = (call.ty, call.span);
        let local = self.push_local(name, ty, kind == BorrowKind::Mutable, Some(kind));
        Expr {
            ty,
            span,
            kind: ExprKind::Place(Place {
                local,
                span,
                call: Some(Box::new(call)),
                projections: Vec::new(),
            }),
        }
    }

    /// A part of type `ty` of `base`: a part of a place is a place; a part
    /// of any other value is read from it.
    fn project(&self, base: Expr, projection: Projection, ty: Type, span: Span) -> Expr {
        let kind = match base.kind {
            ExprKind::Place(mut place) => {
                place.projections.push(projection);
                place.span = span;
                ExprKind::Place(place)
            }
            kind => {
                let base = Box::new(Expr { kind, ..base });
                match projection {
                    Projection::Field(index) => ExprKind::Field { base, index },
                    Projection::Index(index) => ExprKind::Index { base, index },
                }
            }
        };
        Expr { ty, span, kind }
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
        if self.guarded.contains(&local) {
            return Err(self.error(
                CheckDiagnosticKind::NotAssignable,
                target.span,
                format!(
                    "a guard only reads `{}`, so it cannot be assigned",
                    self.locals[local].name
                ),
            ));
        }
        let mut ty = self.locals[local].ty;
        let mut projections = Vec::new();
        for projection in &target.projections {
            match projection {
                ResolvedPlaceProjection::Field(selection) => {
                    let (index, field_ty) =
                        self.named_field(ty, &selection.name, selection.origin.span)?;
                    projections.push(Projection::Field(index));
                    ty = field_ty;
                }
                ResolvedPlaceProjection::TupleField { index, origin } => {
                    let (index, field_ty) = self.tuple_element(ty, index, origin.span)?;
                    projections.push(Projection::Field(index));
                    ty = field_ty;
                }
                ResolvedPlaceProjection::Index(index) => {
                    let (element, index) = self.check_subscript(ty, target.span, index)?;
                    projections.push(Projection::Index(Box::new(index)));
                    ty = element;
                }
            }
        }
        Ok((
            Place {
                local,
                span: target.span,
                call: None,
                projections,
            },
            ty,
        ))
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
            if let Some(visibility) = self.field_visibility(ty, position) {
                self.require_visible(&visibility, span, || format!("the field `{name}`"))?;
            }
            return Ok((position, field.ty));
        }
        Err(self.error(
            CheckDiagnosticKind::UnknownField,
            span,
            format!("`{}` has no field `{name}`", self.types.name(ty)),
        ))
    }

    /// Who may use field `position` of the struct type `ty`.
    fn field_visibility(&self, ty: Type, position: usize) -> Option<Visibility> {
        let &TypeKind::Nominal { declaration, .. } = self.types.kind(ty) else {
            return None;
        };
        let info = &self.nominals.declarations[declaration];
        let Shape::Struct(fields) = info.shape else {
            return None;
        };
        Some(Visibility {
            public: fields[position].public,
            module: info.module.clone(),
        })
    }

    /// Rejects a use of an item that `visibility` does not admit here.
    fn require_visible(
        &self,
        visibility: &Visibility,
        span: Span,
        item: impl FnOnce() -> String,
    ) -> Result<(), CheckDiagnostic> {
        if visibility.admits(&self.module) {
            return Ok(());
        }
        Err(self.error(
            CheckDiagnosticKind::InaccessibleMember,
            span,
            format!("{} is private to its module", item()),
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
                                    span,
                                    kind: ExprKind::Str(value.clone()),
                                });
                            }
                        }
                        ResolvedInterpolationPart::Expression(part) => {
                            checked.push(self.check_displayed(part)?);
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
                    let place = Place {
                        local,
                        span,
                        call: None,
                        projections: Vec::new(),
                    };
                    (self.locals[local].ty, ExprKind::Place(place))
                } else if let Some(&(declaration, variant)) = self.nominals.constructors.get(target)
                {
                    self.check_variant(span, declaration, variant, None, expected)?
                } else {
                    return Err(self.unsupported(span, "values other than local variables"));
                }
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
                let (ty, kind) = self.check_call(span, callee, arguments, expected)?;
                return Ok(self.call_place(Expr { ty, span, kind }, callee_name(callee)));
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
                return Ok(self.project(base, Projection::Field(index), ty, span));
            }
            ResolvedExprKind::TupleField {
                receiver,
                index,
                origin,
            } => {
                let base = self.check_expr(receiver, None)?;
                let (index, ty) = self.tuple_element(base.ty, index, origin.span)?;
                return Ok(self.project(base, Projection::Field(index), ty, span));
            }
            ResolvedExprKind::List(elements) => self.check_list(span, elements, expected)?,
            ResolvedExprKind::Index { receiver, index } => {
                let base = self.check_expr(receiver, None)?;
                let (element, index) = self.check_subscript(base.ty, receiver.span, index)?;
                return Ok(self.project(base, Projection::Index(Box::new(index)), element, span));
            }
            ResolvedExprKind::MethodCall {
                receiver,
                method,
                arguments,
            } => {
                let (ty, kind) = self.check_method(span, receiver, &method.name, arguments)?;
                return Ok(self.call_place(Expr { ty, span, kind }, method.name.clone()));
            }
            // The positions that take a borrow look for it before checking a
            // value; anywhere else one is an error.
            ResolvedExprKind::Borrow { .. } => {
                return Err(self.error(
                    CheckDiagnosticKind::TypeMismatch,
                    span,
                    "`&` and `&mut` go only in an argument to a borrowed parameter, the value of a `let`, the subject of a `for`, `match` or `if let`, or the result of a function that returns a borrow".to_owned(),
                ));
            }
            _ => return Err(self.unsupported(span, "these expressions")),
        };
        Ok(Expr { ty, span, kind })
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
            let value_checked = self.check_expr(value, element)?;
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

    fn option_type(&mut self, element: Type) -> Result<Type, CheckDiagnostic> {
        let declaration = self.types.core.option.declaration;
        instantiate(self.types, self.nominals, declaration, vec![element])
    }

    /// Checks a method call: an inherent method of the receiver's type, a
    /// method of a trait it implements, or else a built-in method.
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
            && let Some((identity, visibility)) = self.methods.get(&(declaration, name.to_owned()))
        {
            self.require_visible(visibility, span, || format!("the method `{name}`"))?;
            let signature = &signatures[identity];
            if !signature.receiver {
                let owner = self.types.name(ty);
                return Err(self.error(
                    CheckDiagnosticKind::UnknownMethod,
                    span,
                    format!("`{owner}::{name}` has no `self`; call it as `{owner}::{name}(...)`"),
                ));
            }
            let callee = Callee::Function(signature.index);
            return self.call_method(span, callee, signature, operand, receiver, arguments);
        }
        if let Some((callee, signature)) = self.trait_method(ty, name, span)? {
            return self.call_method(span, callee, &signature, operand, receiver, arguments);
        }
        let receiver_value = match operand {
            Operand::Place((place, _)) => Receiver::Place(place),
            Operand::Value(value) => Receiver::Value(Box::new(value)),
        };
        let unknown = |checker: &Self| {
            checker.error(
                CheckDiagnosticKind::UnknownMethod,
                span,
                format!("`{}` has no method `{name}`", checker.types.name(ty)),
            )
        };
        let (builtin, parameters, result) = if name == "clone" && self.can_clone(ty) {
            (Builtin::Clone, Vec::new(), ty)
        } else if let TypeKind::List(element) = *self.types.kind(ty) {
            use ListMethod as M;
            let (method, parameters, result) = match name {
                "push" => (M::Push, vec![element], Type::UNIT),
                "pop" => (M::Pop, Vec::new(), self.option_type(element)?),
                "len" => (M::Len, Vec::new(), Type::INT),
                "is_empty" => (M::IsEmpty, Vec::new(), Type::BOOL),
                "insert" => (M::Insert, vec![Type::INT, element], Type::UNIT),
                "remove" => (M::Remove, vec![Type::INT], element),
                "clear" => (M::Clear, Vec::new(), Type::UNIT),
                "contains" if !self.types.is_entity(element) && self.has_equality(element) => {
                    (M::Contains, vec![element], Type::BOOL)
                }
                "get" if !self.types.is_entity(element) => {
                    (M::Get, vec![Type::INT], self.option_type(element)?)
                }
                _ => return Err(unknown(self)),
            };
            (Builtin::List(method), parameters, result)
        } else if let TypeKind::Map(key, value) = *self.types.kind(ty) {
            use MapMethod as M;
            let (method, parameters, result) = match name {
                "insert" => (M::Insert, vec![key, value], self.option_type(value)?),
                "remove" => (M::Remove, vec![key], self.option_type(value)?),
                "get" if !self.types.is_entity(value) => {
                    (M::Get, vec![key], self.option_type(value)?)
                }
                "contains_key" => (M::ContainsKey, vec![key], Type::BOOL),
                "keys" => (M::Keys, Vec::new(), self.types.intern(TypeKind::List(key))),
                "len" => (M::Len, Vec::new(), Type::INT),
                "is_empty" => (M::IsEmpty, Vec::new(), Type::BOOL),
                "clear" => (M::Clear, Vec::new(), Type::UNIT),
                _ => return Err(unknown(self)),
            };
            (Builtin::Map(method), parameters, result)
        } else if let TypeKind::Set(element) = *self.types.kind(ty) {
            use SetMethod as M;
            let (method, parameters, result) = match name {
                "insert" => (M::Insert, vec![element], Type::BOOL),
                "remove" => (M::Remove, vec![element], Type::BOOL),
                "contains" => (M::Contains, vec![element], Type::BOOL),
                "len" => (M::Len, Vec::new(), Type::INT),
                "is_empty" => (M::IsEmpty, Vec::new(), Type::BOOL),
                "clear" => (M::Clear, Vec::new(), Type::UNIT),
                _ => return Err(unknown(self)),
            };
            (Builtin::Set(method), parameters, result)
        } else if ty == Type::STR {
            use StrMethod as M;
            let text = Type::STR;
            let (method, parameters, result) = match name {
                "len" => (M::Len, Vec::new(), Type::INT),
                "is_empty" => (M::IsEmpty, Vec::new(), Type::BOOL),
                "contains" => (M::Contains, vec![text], Type::BOOL),
                "starts_with" => (M::StartsWith, vec![text], Type::BOOL),
                "ends_with" => (M::EndsWith, vec![text], Type::BOOL),
                "find" => (M::Find, vec![text], self.option_type(Type::INT)?),
                "slice" => (M::Slice, vec![Type::INT, Type::INT], text),
                "split" => (
                    M::Split,
                    vec![text],
                    self.types.intern(TypeKind::List(text)),
                ),
                "trim" => (M::Trim, Vec::new(), text),
                "replace" => (M::Replace, vec![text, text], text),
                "repeat" => (M::Repeat, vec![Type::INT], text),
                "chars" => (
                    M::Chars,
                    Vec::new(),
                    self.types.intern(TypeKind::List(text)),
                ),
                "to_upper" => (M::ToUpper, Vec::new(), text),
                "to_lower" => (M::ToLower, Vec::new(), text),
                "parse_int" => (M::ParseInt, Vec::new(), self.option_type(Type::INT)?),
                _ => return Err(unknown(self)),
            };
            (Builtin::Str(method), parameters, result)
        } else {
            return Err(unknown(self));
        }; // A temporary can always be changed.
        if builtin.changes_receiver()
            && let Receiver::Place(place) = &receiver_value
            && let Some(reason) = self.unchangeable(place)
        {
            return Err(self.error(
                CheckDiagnosticKind::NotAssignable,
                receiver.span,
                format!("`{name}` changes its receiver, but {reason}"),
            ));
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
        let mut checked = Vec::new();
        for (argument, parameter) in arguments.iter().zip(parameters) {
            let value = self.check_expr(argument, Some(parameter))?;
            self.require(argument.span, parameter, value.ty)?;
            checked.push(value);
        }
        Ok((
            result,
            ExprKind::Builtin {
                builtin,
                receiver: Box::new(receiver_value),
                arguments: checked,
            },
        ))
    }

    /// Checks a value that `print` or interpolation shows: a built-in type
    /// as it is, any other type through its `Display::to_str`, which borrows
    /// the value.
    fn check_displayed(&mut self, expression: &ResolvedExpr) -> Result<Expr, CheckDiagnostic> {
        let span = expression.span;
        let operand = self.check_operand(expression, None)?;
        let ty = operand.ty();
        if is_printable(ty) {
            return Ok(operand.into_expr());
        }
        let display = self.traits.display;
        if !self.implements(ty, display) {
            return Err(self.error(
                CheckDiagnosticKind::UnsatisfiedBound,
                span,
                format!("`{}` does not implement `Display`", self.types.name(ty)),
            ));
        }
        let (callee, signature) = self.trait_callee(ty, display, 0, span)?;
        let (result, kind) = self.finish_call(
            span,
            callee,
            &signature,
            vec![Argument::Receiver(operand, expression)],
            None,
        )?;
        Ok(Expr {
            ty: result,
            span,
            kind,
        })
    }

    /// Calls a method with `signature` on the checked receiver `operand`.
    fn call_method(
        &mut self,
        span: Span,
        callee: Callee,
        signature: &Signature,
        operand: Operand,
        receiver: &ResolvedExpr,
        arguments: &[ResolvedExpr],
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        if arguments.len() + 1 != signature.parameters.len() {
            return Err(self.error(
                CheckDiagnosticKind::ArgumentCount,
                span,
                format!(
                    "this method takes {} arguments, found {}",
                    signature.parameters.len() - 1,
                    arguments.len()
                ),
            ));
        }
        let arguments = std::iter::once(Argument::Receiver(operand, receiver))
            .chain(arguments.iter().map(Argument::Written))
            .collect();
        self.finish_call(span, callee, signature, arguments, None)
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
        // Building a struct writes all its fields, so outside its module
        // every field must be public.
        if let Shape::Struct(fields) = info.shape
            && let Some(field) = fields.iter().find(|field| {
                !Visibility {
                    public: field.public,
                    module: info.module.clone(),
                }
                .admits(&self.module)
            })
        {
            return Err(self.error(
                CheckDiagnosticKind::InaccessibleMember,
                span,
                format!(
                    "the field `{}` of `{}` is private to its module, so only that module can build a `{}`",
                    field.identity.name, info.name, info.name
                ),
            ));
        }
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
        let ty = instantiate(self.types, nominals, declaration, type_arguments)?;
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
                let arguments = match (self.types.kind(actual).clone(), target.kind) {
                    (
                        TypeKind::Nominal {
                            declaration,
                            arguments,
                        },
                        _,
                    ) if self.nominals.by_identity.get(target) == Some(&declaration) => {
                        Some(arguments)
                    }
                    (TypeKind::List(element), EntityKind::LanguageType)
                        if target.name == "List" =>
                    {
                        Some(vec![element])
                    }
                    (TypeKind::Set(element), EntityKind::LanguageType) if target.name == "Set" => {
                        Some(vec![element])
                    }
                    (TypeKind::Map(key, value), EntityKind::LanguageType)
                        if target.name == "Map" =>
                    {
                        Some(vec![key, value])
                    }
                    _ => None,
                };
                if let Some(arguments) = arguments {
                    return named.arguments.len() == arguments.len()
                        && named
                            .arguments
                            .iter()
                            .zip(arguments)
                            .all(|(written, actual)| {
                                matches!(written, ResolvedTypeArgument::Type(written)
                                if self.bind(written, actual, substitution))
                            });
                }
                if self.nominals.by_identity.contains_key(target) {
                    return false;
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

    /// Checks the subject of a `match` or `if let`. A subject written `&e`
    /// or `&mut e` is borrowed, and its borrow mode is returned.
    fn check_subject(
        &mut self,
        subject: &ResolvedExpr,
    ) -> Result<(Expr, Option<BorrowKind>), CheckDiagnostic> {
        let ResolvedExprKind::Borrow {
            kind: (_, kind),
            operand,
        } = &subject.kind
        else {
            return Ok((self.check_expr(subject, None)?, None));
        };
        let kind = *kind;
        let checked = match self.check_operand(operand, None)? {
            Operand::Value(value) if value.ty == Type::NEVER => return Ok((value, None)),
            checked => checked,
        };
        let borrowed = self.borrow(kind, checked, operand.span)?;
        Ok((
            Expr {
                span: subject.span,
                ..borrowed
            },
            Some(kind),
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
        let (scrutinee, mode) = self.check_subject(scrutinee)?;
        if scrutinee.ty == Type::NEVER {
            return Ok((Type::NEVER, scrutinee.kind));
        }
        let mut expected = expected;
        let mut ty = None;
        let mut checked = Vec::new();
        for arm in arms {
            let pattern =
                self.check_pattern(&arm.pattern, scrutinee.ty, mode, &mut BTreeMap::new())?;
            // A guard only reads the bindings; they become `&mut` once it holds.
            let mut guarded = self.guarded.clone();
            guarded.extend(self.mutable_bindings(&pattern));
            let outer = std::mem::replace(&mut self.guarded, guarded);
            let guard = arm
                .guard
                .as_ref()
                .map(|guard| self.check_condition(guard))
                .transpose()?;
            self.guarded = outer;
            let body = self.check_expr(&arm.body, expected)?;
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
        let (scrutinee, mode) = self.check_subject(value)?;
        if scrutinee.ty == Type::NEVER {
            return Ok(scrutinee);
        }
        let pattern = self.check_pattern(pattern, scrutinee.ty, mode, &mut BTreeMap::new())?;
        let then_branch = self.check_block(then_branch, Some(Type::UNIT))?;
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
                span: value.span,
                kind: ExprKind::Block(body),
            },
        };
        Ok(Expr {
            ty,
            span: value.span,
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
                    Pattern::Binding(local, span)
                } else {
                    let local = self.declare_binding(&binding.identity, ty, mode);
                    shared.insert(name, local);
                    Pattern::Binding(local, span)
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
                let shape = &self.types.variants(ty)[variant];
                let positional = shape.positional;
                let field_types = shape
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
                        if patterns.len() != field_types.len() || !positional {
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
            && let ResolvedExprKind::Integer(text) = &operand.kind
            && text == "9223372036854775808"
        {
            return Ok((Type::INT, ExprKind::Int(i64::MIN)));
        }
        let operand = self.check_expr(operand, None)?;
        // An operand that never produces a value fits any operator.
        let valid = match operator {
            _ if operand.ty == Type::NEVER => true,
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
        let expected = (left.ty != Type::NEVER).then_some(left.ty);
        let right = self.check_expr(right, expected)?;
        // An operand that never produces a value fits the other one, as it
        // fits wherever a value is expected.
        let ty = match expected {
            Some(ty) => {
                self.require(right_span, ty, right.ty)?;
                ty
            }
            None => right.ty,
        };
        if ty == Type::NEVER {
            let kind = ExprKind::Binary {
                operator,
                left: Box::new(left),
                right: Box::new(right),
            };
            return Ok((Type::NEVER, kind));
        }
        let result = match operator {
            Op::Add | Op::Subtract | Op::Multiply | Op::Divide | Op::Remainder => {
                matches!(ty, Type::INT | Type::FLOAT).then_some(ty)
            }
            Op::Equal | Op::NotEqual => self.has_equality(ty).then_some(Type::BOOL),
            Op::Less | Op::Greater | Op::LessEqual | Op::GreaterEqual => self
                .compares(ty, Comparison::PartialOrd)
                .then_some(Type::BOOL),
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
        self.compares(ty, Comparison::PartialEq)
    }

    /// Whether `ty` implements `comparison`, a type parameter through its
    /// bounds.
    fn compares(&self, ty: Type, comparison: Comparison) -> bool {
        self.implements(ty, self.traits.comparisons[comparison as usize])
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
                let Some((identity, visibility)) =
                    self.methods.get(&(declaration, member.name.clone()))
                else {
                    return Err(self.error(
                        CheckDiagnosticKind::UnknownMethod,
                        member.origin.span,
                        format!("`{}` has no function `{}`", base.name, member.name),
                    ));
                };
                self.require_visible(visibility, member.origin.span, || {
                    format!("the function `{}::{}`", base.name, member.name)
                })?;
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
        let callee = Callee::Function(signature.index);
        self.finish_call(span, callee, signature, arguments, expected)
    }

    /// Checks the arguments of a call of the function with `signature`. The
    /// type arguments of a generic function come from the arguments, in
    /// order, and then from the type the call is expected to have.
    fn finish_call(
        &mut self,
        span: Span,
        callee: Callee,
        signature: &Signature,
        arguments: Vec<Argument>,
        expected: Option<Type>,
    ) -> Result<(Type, ExprKind), CheckDiagnostic> {
        let borrow = signature.result_borrow;
        let mut bindings = vec![None; signature.type_parameters.len()];
        let arguments =
            self.check_arguments(arguments, signature.parameters.clone(), &mut bindings)?;
        if borrow.is_some()
            && arguments.iter().any(|argument| {
                matches!(&argument.kind, ExprKind::Borrow(_, target)
                    if matches!(target.as_ref(), BorrowTarget::Value(_)))
            })
        {
            return Err(self.unsupported(span, "borrowed results of calls that borrow temporaries"));
        }
        if let Some(expected) = expected
            && bindings.iter().any(Option::is_none)
        {
            // A failed match leaves the parameters unbound, which is
            // reported below.
            let mut tentative = bindings.clone();
            if self.match_type(signature.result, expected, &mut tentative) {
                bindings = tentative;
            }
        }
        let mut type_arguments = Vec::new();
        for (parameter, binding) in signature.type_parameters.iter().zip(&bindings) {
            let Some(argument) = *binding else {
                return Err(self.error(
                    CheckDiagnosticKind::CannotInfer,
                    span,
                    format!(
                        "the type argument `{}` of this call cannot be inferred here; write the expected type",
                        parameter.name
                    ),
                ));
            };
            let unsatisfied = parameter
                .traits
                .iter()
                .find(|&&trait_index| !self.implements(argument, trait_index))
                .map(|&trait_index| self.traits.declarations[trait_index].name.as_str());
            if let Some(bound) = unsatisfied {
                return Err(self.error(
                    CheckDiagnosticKind::UnsatisfiedBound,
                    span,
                    format!(
                        "`{}` does not implement `{bound}`, which the type parameter `{}` of this function requires",
                        self.types.name(argument),
                        parameter.name
                    ),
                ));
            }
            type_arguments.push(argument);
        }
        let result = self.substitute(signature.result, &type_arguments)?;
        if let Callee::Function(function) = callee {
            self.calls
                .push((function, type_arguments.clone(), self.at(span)));
        }
        Ok((
            result,
            ExprKind::Call {
                callee,
                type_arguments,
                arguments,
                borrow,
            },
        ))
    }

    fn implements(&self, ty: Type, trait_index: usize) -> bool {
        implements(
            self.traits,
            self.trait_impls,
            &self.type_parameters,
            self.types,
            ty,
            trait_index,
        )
    }

    /// Finds the trait method `name` of a receiver of type `ty` among the
    /// traits `ty` implements, by an impl or as the compiler provides them,
    /// and among a type parameter's bounds. Returns the callee and its
    /// signature for this receiver, or `None` when no trait has the method
    /// or it is `Clone::clone`, which the built-in `clone` carries out.
    fn trait_method(
        &mut self,
        ty: Type,
        name: &str,
        span: Span,
    ) -> Result<Option<(Callee, Signature)>, CheckDiagnostic> {
        let traits = self.traits;
        let candidates = (0..traits.declarations.len())
            .filter(|&trait_index| {
                traits.declarations[trait_index]
                    .methods
                    .iter()
                    .any(|method| method.identity.name == name)
                    && self.implements(ty, trait_index)
            })
            .collect::<Vec<_>>();
        let (found, hidden): (Vec<_>, Vec<_>) = candidates
            .into_iter()
            .filter_map(|trait_index| {
                traits.declarations[trait_index]
                    .methods
                    .iter()
                    .position(|method| method.identity.name == name)
                    .map(|method| (trait_index, method))
            })
            .partition(|(trait_index, _)| {
                traits.declarations[*trait_index]
                    .visibility
                    .admits(&self.module)
            });
        // A trait that is private to another module gives no methods here.
        if found.is_empty()
            && let Some((trait_index, _)) = hidden.first()
        {
            let declaration = &traits.declarations[*trait_index];
            self.require_visible(&declaration.visibility, span, || {
                format!("the trait `{}`", declaration.name)
            })?;
        }
        let (trait_index, method) = match found.as_slice() {
            [] => return Ok(None),
            [(trait_index, _)] if *trait_index == traits.clone => return Ok(None),
            [(trait_index, _)] if *trait_index == traits.drop => {
                return Err(self.error(
                    CheckDiagnosticKind::UnknownMethod,
                    span,
                    "`drop` runs when the value is released; it cannot be called".to_owned(),
                ));
            }
            [found] => *found,
            [(first, _), (second, _), ..] => {
                return Err(self.error(
                    CheckDiagnosticKind::AmbiguousMethod,
                    span,
                    format!(
                        "`{name}` is a method of both `{}` and `{}` for `{}`",
                        traits.declarations[*first].name,
                        traits.declarations[*second].name,
                        self.types.name(ty)
                    ),
                ));
            }
        };
        self.trait_callee(ty, trait_index, method, span).map(Some)
    }

    /// The callee and signature of `method` of `trait_index` for a receiver
    /// of type `ty`, which implements the trait: the impl's function for a
    /// concrete type, or the trait method for a type parameter.
    fn trait_callee(
        &mut self,
        ty: Type,
        trait_index: usize,
        method: usize,
        span: Span,
    ) -> Result<(Callee, Signature), CheckDiagnostic> {
        if let Some(methods) = self.trait_impls.get(&(trait_index, ty)) {
            let function = methods[method];
            let signature = self.signatures[&self.identities[function]].clone();
            return Ok((Callee::Function(function), signature));
        }
        // Instantiation finds an impl for a type argument, or the built-in
        // `Display` of a built-in type; compiler-made comparisons have no
        // method to call.
        if self.traits.comparison(trait_index).is_some() {
            return Err(self.unsupported(
                span,
                "comparison methods of types without a hand-written impl (compare with the operators)",
            ));
        }
        let signature = substitute_signature(
            self.types,
            &self.traits.signatures[trait_index][method],
            &[ty],
        )?;
        Ok((
            Callee::Trait {
                trait_index,
                method,
                self_type: ty,
            },
            signature,
        ))
    }

    /// Whether `clone()` applies to `ty`.
    fn can_clone(&self, ty: Type) -> bool {
        self.implements(ty, self.traits.clone)
    }
    /// Matches `pattern`, a type of a generic function's signature, against
    /// `actual`, binding the function's type parameters. Returns whether
    /// they fit. `Never` fits anything and binds nothing.
    fn match_type(&self, pattern: Type, actual: Type, bindings: &mut [Option<Type>]) -> bool {
        if actual == Type::NEVER {
            return true;
        }
        match (self.types.kind(pattern), self.types.kind(actual)) {
            (&TypeKind::Param { index, .. }, _) => match bindings[index] {
                Some(bound) => bound == actual,
                None => {
                    bindings[index] = Some(actual);
                    true
                }
            },
            _ if !self.types.is_generic(pattern) => pattern == actual,
            (TypeKind::Tuple(patterns), TypeKind::Tuple(actuals))
            | (
                TypeKind::Nominal {
                    arguments: patterns,
                    ..
                },
                TypeKind::Nominal {
                    arguments: actuals, ..
                },
            ) => {
                let same_declaration = match (self.types.kind(pattern), self.types.kind(actual)) {
                    (
                        TypeKind::Nominal { declaration, .. },
                        TypeKind::Nominal {
                            declaration: actual_declaration,
                            ..
                        },
                    ) => declaration == actual_declaration,
                    _ => true,
                };
                same_declaration
                    && patterns.len() == actuals.len()
                    && patterns
                        .clone()
                        .iter()
                        .zip(actuals.clone())
                        .all(|(pattern, actual)| self.match_type(*pattern, actual, bindings))
            }
            (&TypeKind::List(pattern), &TypeKind::List(actual))
            | (&TypeKind::Set(pattern), &TypeKind::Set(actual)) => {
                self.match_type(pattern, actual, bindings)
            }
            (&TypeKind::Map(key, value), &TypeKind::Map(actual_key, actual_value)) => {
                self.match_type(key, actual_key, bindings)
                    && self.match_type(value, actual_value, bindings)
            }
            _ => false,
        }
    }

    /// `ty` with the type parameters of a callee's signature replaced by
    /// `arguments`.
    fn substitute(&mut self, ty: Type, arguments: &[Type]) -> Result<Type, CheckDiagnostic> {
        if arguments.is_empty() {
            return Ok(ty);
        }
        self.types
            .substitute(ty, arguments)
            .map_err(|error| error.diagnostic(self.types))
    }

    /// The type a parameter of a generic callee expects, once `bindings`
    /// give every type parameter it mentions.
    fn instantiated(
        &mut self,
        ty: Type,
        bindings: &[Option<Type>],
    ) -> Result<Option<Type>, CheckDiagnostic> {
        if bindings.is_empty() {
            return Ok(Some(ty));
        }
        let mut arguments = Vec::new();
        for binding in bindings {
            // An unbound parameter that `ty` does not mention is never read.
            arguments.push(binding.unwrap_or(Type::NEVER));
        }
        let mentioned_unbound = bindings
            .iter()
            .enumerate()
            .any(|(index, binding)| binding.is_none() && self.types.mentions_param(ty, index));
        if mentioned_unbound {
            return Ok(None);
        }
        self.substitute(ty, &arguments).map(Some)
    }

    /// Checks call arguments in order. Whether borrows of them conflict is
    /// checked on the IR. The parameter types of a generic
    /// callee mention its type parameters, which each argument binds in
    /// `bindings` as far as it can.
    fn check_arguments(
        &mut self,
        values: Vec<Argument>,
        parameters: Vec<(Type, Option<BorrowKind>)>,
        bindings: &mut [Option<Type>],
    ) -> Result<Vec<Expr>, CheckDiagnostic> {
        let mut checked = Vec::new();
        for (value, (parameter, borrow)) in values.into_iter().zip(parameters) {
            let expected = self.instantiated(parameter, bindings)?;
            let (checked_operand, operand) = match (value, borrow) {
                (Argument::Written(value), None) => {
                    let argument = self.check_expr(value, expected)?;
                    self.fit(value.span, parameter, expected, argument.ty, bindings)?;
                    checked.push(argument);
                    continue;
                }
                // A method that takes `self` takes the receiver.
                (Argument::Receiver(receiver, _), None) => {
                    checked.push(receiver.into_expr());
                    continue;
                }
                // The receiver of `&self` and `&mut self` is borrowed as is.
                (Argument::Receiver(receiver, value), Some(_)) => (receiver, value),
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
                    (self.check_operand(operand, expected)?, operand.as_ref())
                }
            };
            let kind = borrow.expect("only borrowed arguments get here");
            let ty = self.fit(
                operand.span,
                parameter,
                expected,
                checked_operand.ty(),
                bindings,
            )?;
            let borrowed = self.borrow(kind, checked_operand, operand.span)?;
            checked.push(Expr { ty, ..borrowed });
        }
        Ok(checked)
    }

    /// Checks that an argument of type `actual` fits `parameter`: it must be
    /// `expected` if that is known, and otherwise binds the type parameters
    /// that `parameter` mentions. Returns the parameter type in the caller's
    /// terms.
    fn fit(
        &mut self,
        span: Span,
        parameter: Type,
        expected: Option<Type>,
        actual: Type,
        bindings: &mut [Option<Type>],
    ) -> Result<Type, CheckDiagnostic> {
        if let Some(expected) = expected {
            self.require(span, expected, actual)?;
            return Ok(expected);
        }
        if !self.match_type(parameter, actual, bindings) {
            return Err(self.mismatch(span, parameter, actual));
        }
        Ok(self.instantiated(parameter, bindings)?.unwrap_or(actual))
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
        let arguments = self.check_arguments(
            vec![
                Argument::Receiver(first_operand, operand),
                Argument::Written(second),
            ],
            vec![(ty, Some(BorrowKind::Mutable)), (ty, second_parameter)],
            &mut [],
        )?;
        let result = match intrinsic {
            Intrinsic::Replace => ty,
            _ => Type::UNIT,
        };
        Ok((
            result,
            ExprKind::Intrinsic {
                intrinsic,
                arguments,
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
            let argument = match expected {
                Some(expected) => {
                    let argument = self.check_expr(value, Some(*expected))?;
                    self.require(value.span, *expected, argument.ty)?;
                    argument
                }
                None => self.check_displayed(value)?,
            };
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

/// A call argument: an expression as written, or the receiver of a method,
/// checked already to find the method, which the call borrows or takes as
/// the method declares.
enum Argument<'r> {
    Written(&'r ResolvedExpr),
    Receiver(Operand, &'r ResolvedExpr),
}

/// The name of a called function, for the local that holds its borrowed
/// result.
fn callee_name(callee: &ResolvedExpr) -> String {
    match &callee.kind {
        ResolvedExprKind::Path(ResolvedReference::Exact { target, .. }) => target.name.clone(),
        _ => "result".to_owned(),
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
