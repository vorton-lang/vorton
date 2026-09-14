use super::*;
use crate::project::{
    ResolvedGenericBound, ResolvedImplMemberKind, ResolvedTraitMemberKind, ResolvedTypeParameter,
};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct ProjectionType {
    pub(super) receiver: CheckedType,
    pub(super) member: Option<EntityId>,
    pub(super) name: String,
    pub(super) bound: Option<TraitUse>,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct TraitUse {
    pub(super) declaration: EntityId,
    pub(super) arguments: Vec<CheckedType>,
    pub(super) associated: BTreeMap<EntityId, CheckedType>,
}

#[derive(Debug, Clone)]
pub(super) struct Requirement {
    pub(super) subject: CheckedType,
    pub(super) bound: TraitUse,
    pub(super) origin: CheckOrigin,
}

#[derive(Clone)]
pub(super) struct TraitDefinition {
    pub(super) self_type: TypeFormal,
    pub(super) formals: Vec<TypeFormal>,
    pub(super) requirements: Vec<Requirement>,
    pub(super) associated: BTreeMap<EntityId, (Vec<TraitUse>, Option<CheckedType>)>,
    pub(super) methods: BTreeMap<String, EntityId>,
}

#[derive(Clone)]
pub(super) struct ImplDefinition {
    pub(super) identity: EntityId,
    pub(super) formals: Vec<TypeFormal>,
    pub(super) target: CheckedType,
    pub(super) trait_use: Option<TraitUse>,
    pub(super) requirements: Vec<Requirement>,
    pub(super) associated: BTreeMap<EntityId, CheckedType>,
    pub(super) methods: BTreeMap<String, EntityId>,
}

#[derive(Default)]
pub(super) struct TraitEnvironment {
    pub(super) traits: BTreeMap<EntityId, TraitDefinition>,
    pub(super) implementations: Vec<ImplDefinition>,
    pub(super) requirements: BTreeMap<EntityId, Vec<Requirement>>,
    pub(super) owner_formals: BTreeMap<EntityId, Vec<TypeFormal>>,
}

pub(super) fn declaration_identity<'a>(
    project: &'a ResolvedProject,
    declaration: &'a ResolvedDeclaration,
) -> Option<&'a EntityId> {
    declaration.identity.as_ref().or_else(|| {
        project.entities.keys().find(|identity| {
            identity.kind == EntityKind::SelfType
                && identity.owner.as_ref().is_some_and(|owner| {
                    matches!(owner.kind, EntityKind::InherentImpl | EntityKind::TraitImpl)
                })
                && identity.site == EntitySite::Source(declaration.origin.clone())
        })
    })
}

fn declaration_formals(owner: &EntityId, parameters: &[ResolvedTypeParameter]) -> Vec<TypeFormal> {
    parameters
        .iter()
        .enumerate()
        .map(|(ordinal, parameter)| TypeFormal {
            owner: owner.clone(),
            ordinal,
            name: parameter.binding.identity.name.clone(),
        })
        .collect()
}

impl SourceTypeNormalizer {
    pub(super) fn index_owner_formals(&mut self, project: &ResolvedProject) {
        for module in project.modules.values() {
            for declaration in module.body.iter().flat_map(|body| &body.declarations) {
                let Some(identity) = declaration_identity(project, declaration) else {
                    continue;
                };
                let parameters = match &declaration.kind {
                    ResolvedDeclarationKind::Function(function) => &function.type_parameters,
                    ResolvedDeclarationKind::Trait {
                        type_parameters, ..
                    }
                    | ResolvedDeclarationKind::Struct {
                        type_parameters, ..
                    }
                    | ResolvedDeclarationKind::Enum {
                        type_parameters, ..
                    }
                    | ResolvedDeclarationKind::Effect {
                        type_parameters, ..
                    }
                    | ResolvedDeclarationKind::EffectAlias {
                        type_parameters, ..
                    } => type_parameters,
                    ResolvedDeclarationKind::InherentImpl(implementation) => {
                        &implementation.type_parameters
                    }
                    ResolvedDeclarationKind::TraitImpl { implementation, .. } => {
                        &implementation.type_parameters
                    }
                    _ => continue,
                };
                self.source_formals.extend(
                    parameters
                        .iter()
                        .zip(declaration_formals(identity, parameters))
                        .map(|(parameter, formal)| (parameter.binding.identity.clone(), formal)),
                );
                let member_parameters = match &declaration.kind {
                    ResolvedDeclarationKind::Trait { members, .. } => members
                        .iter()
                        .filter_map(|member| {
                            let ResolvedTraitMemberKind::Method(signature) = &member.kind else {
                                return None;
                            };
                            Some((&member.identity, &signature.type_parameters))
                        })
                        .collect::<Vec<_>>(),
                    ResolvedDeclarationKind::InherentImpl(implementation) => implementation
                        .members
                        .iter()
                        .filter_map(|member| {
                            let ResolvedImplMemberKind::Function(function) = &member.kind else {
                                return None;
                            };
                            Some((&member.identity, &function.type_parameters))
                        })
                        .collect(),
                    ResolvedDeclarationKind::TraitImpl { implementation, .. } => implementation
                        .members
                        .iter()
                        .filter_map(|member| {
                            let ResolvedImplMemberKind::Function(function) = &member.kind else {
                                return None;
                            };
                            Some((&member.identity, &function.type_parameters))
                        })
                        .collect(),
                    _ => Vec::new(),
                };
                for (owner, parameters) in member_parameters {
                    self.source_formals.extend(
                        parameters
                            .iter()
                            .zip(declaration_formals(owner, parameters))
                            .map(|(parameter, formal)| {
                                (parameter.binding.identity.clone(), formal)
                            }),
                    );
                }
                if identity.kind == EntityKind::Trait {
                    for (self_identity, entity) in &project.entities {
                        if self_identity.kind == EntityKind::SelfType
                            && (entity.owner.as_ref() == Some(identity)
                                || self_identity == identity)
                        {
                            self.self_types.insert(
                                self_identity.clone(),
                                CheckedType::Formal(Box::new(TypeFormal {
                                    owner: identity.clone(),
                                    ordinal: usize::MAX,
                                    name: "Self".to_owned(),
                                })),
                            );
                        }
                    }
                }
            }
        }
    }

    pub(super) fn normalize_projection(
        &mut self,
        reference: &ResolvedReference,
        formals: &BTreeMap<EntityId, TypeFormal>,
    ) -> Result<CheckedType, CheckDiagnostic> {
        let ResolvedReference::Selection {
            occurrence,
            base,
            members,
            self_reference,
            ..
        } = reference
        else {
            unreachable!()
        };
        let mut ty = if let Some(self_reference) = self_reference {
            self.self_types[&self_reference.identity].clone()
        } else {
            self.normalize_with_formals(
                &ResolvedType {
                    span: occurrence.span,
                    kind: ResolvedTypeKind::Named(Box::new(ResolvedNamedType {
                        span: occurrence.span,
                        reference: ResolvedReference::Exact {
                            occurrence: occurrence.clone(),
                            target: base.clone(),
                            self_reference: None,
                        },
                        arguments: Vec::new(),
                    })),
                },
                formals,
            )?
        };
        for member in members {
            ty = CheckedType::Projection(Box::new(ProjectionType {
                receiver: ty,
                member: member.declaration.as_ref().map(|identity| {
                    self.associated_members
                        .get(identity)
                        .unwrap_or(identity)
                        .clone()
                }),
                name: member.name.clone(),
                bound: None,
            }));
        }
        Ok(ty)
    }

    pub(super) fn associated_reference(
        &self,
        member: &EntityId,
        origin: &OriginRef,
    ) -> Result<CheckedType, CheckDiagnostic> {
        let owner = member
            .owner
            .as_ref()
            .expect("associated declarations have owners");
        let receiver = self
            .self_types
            .iter()
            .find_map(|(identity, ty)| (identity.owner.as_ref() == Some(owner)).then_some(ty));
        let Some(receiver) = receiver else {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "associated type has no checked owner",
                origin.clone(),
                Vec::new(),
            ));
        };
        Ok(CheckedType::Projection(Box::new(ProjectionType {
            receiver: receiver.clone(),
            member: Some(
                self.associated_members
                    .get(member)
                    .unwrap_or(member)
                    .clone(),
            ),
            name: member.name.clone(),
            bound: None,
        })))
    }

    fn trait_use(
        &mut self,
        bound: &ResolvedNamedType,
        formals: &BTreeMap<EntityId, TypeFormal>,
    ) -> Result<TraitUse, CheckDiagnostic> {
        let ResolvedReference::Exact {
            occurrence, target, ..
        } = &bound.reference
        else {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "a requirement must name an exact trait",
                reference_origin(&bound.reference).clone(),
                Vec::new(),
            ));
        };
        if target.kind != EntityKind::Trait {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "a requirement must name a trait declaration",
                occurrence.clone(),
                entity_origin(target).into_iter().collect(),
            ));
        }
        let mut arguments = Vec::new();
        let mut associated = BTreeMap::new();
        for argument in &bound.arguments {
            match argument {
                ResolvedTypeArgument::Type(ty) => {
                    arguments.push(self.normalize_with_formals(ty, formals)?)
                }
                ResolvedTypeArgument::AssociatedType { member, value } => {
                    let Some(identity) = &member.declaration else {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            "associated bound must select a declared trait member",
                            member.origin.clone(),
                            Vec::new(),
                        ));
                    };
                    associated.insert(
                        identity.clone(),
                        self.normalize_with_formals(value, formals)?,
                    );
                }
            }
        }
        if self.arities.get(target).copied() != Some(arguments.len()) {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "trait argument count does not match its declaration",
                occurrence.clone(),
                entity_origin(target).into_iter().collect(),
            ));
        }
        Ok(TraitUse {
            declaration: target.clone(),
            arguments,
            associated,
        })
    }
}

pub(super) fn reference_origin(reference: &ResolvedReference) -> &OriginRef {
    match reference {
        ResolvedReference::Exact { occurrence, .. }
        | ResolvedReference::Selection { occurrence, .. } => occurrence,
    }
}

impl TraitEnvironment {
    pub(super) fn collect(
        project: &ResolvedProject,
        normalizer: &mut SourceTypeNormalizer,
    ) -> Result<Self, CheckDiagnostic> {
        normalizer.index_owner_formals(project);
        let mut environment = Self::default();
        // Owner identities and outer substitutions exist before any member is
        // normalized. In particular an impl T remains owned by that impl.
        for module in project.modules.values() {
            for declaration in module.body.iter().flat_map(|body| &body.declarations) {
                let Some(identity) = declaration_identity(project, declaration) else {
                    continue;
                };
                let implementation = match &declaration.kind {
                    ResolvedDeclarationKind::InherentImpl(implementation) => implementation,
                    ResolvedDeclarationKind::TraitImpl { implementation, .. } => implementation,
                    _ => continue,
                };
                let formals = declaration_formals(identity, &implementation.type_parameters);
                environment.owner_formals.insert(identity.clone(), formals);
                let target = normalizer.normalize(&ResolvedType {
                    span: implementation.target.span,
                    kind: ResolvedTypeKind::Named(Box::new(implementation.target.clone())),
                })?;
                for (self_identity, entity) in &project.entities {
                    if self_identity.kind == EntityKind::SelfType
                        && (entity.owner.as_ref() == Some(identity) || self_identity == identity)
                    {
                        normalizer
                            .self_types
                            .insert(self_identity.clone(), target.clone());
                    }
                }
            }
        }
        for module in project.modules.values() {
            for declaration in module.body.iter().flat_map(|body| &body.declarations) {
                let Some(identity) = declaration_identity(project, declaration) else {
                    continue;
                };
                if let ResolvedDeclarationKind::Trait {
                    type_parameters,
                    supertraits,
                    members,
                } = &declaration.kind
                {
                    let formals = declaration_formals(identity, type_parameters);
                    let self_type = TypeFormal {
                        owner: identity.clone(),
                        ordinal: usize::MAX,
                        name: "Self".to_owned(),
                    };
                    let mut requirements = source_requirements(type_parameters, normalizer)?;
                    for bound in supertraits {
                        requirements.push(Requirement {
                            subject: CheckedType::Formal(Box::new(self_type.clone())),
                            bound: normalizer.trait_use(bound, &BTreeMap::new())?,
                            origin: CheckOrigin::Source(reference_origin(&bound.reference).clone()),
                        });
                    }
                    let mut associated = BTreeMap::new();
                    let mut methods = BTreeMap::new();
                    for member in members {
                        match &member.kind {
                            ResolvedTraitMemberKind::Method(_) => {
                                methods
                                    .insert(member.identity.name.clone(), member.identity.clone());
                            }
                            ResolvedTraitMemberKind::AssociatedType { bounds, default } => {
                                associated.insert(
                                    member.identity.clone(),
                                    (
                                        bounds
                                            .iter()
                                            .map(|bound| {
                                                normalizer.trait_use(bound, &BTreeMap::new())
                                            })
                                            .collect::<Result<_, _>>()?,
                                        default
                                            .as_ref()
                                            .map(|ty| normalizer.normalize(ty))
                                            .transpose()?,
                                    ),
                                );
                            }
                        }
                    }
                    environment.owner_formals.insert(
                        identity.clone(),
                        std::iter::once(self_type.clone())
                            .chain(formals.iter().cloned())
                            .collect(),
                    );
                    environment
                        .requirements
                        .insert(identity.clone(), requirements.clone());
                    environment.traits.insert(
                        identity.clone(),
                        TraitDefinition {
                            self_type,
                            formals,
                            requirements,
                            associated,
                            methods,
                        },
                    );
                }
            }
        }
        for module in project.modules.values() {
            for declaration in module.body.iter().flat_map(|body| &body.declarations) {
                let Some(identity) = declaration_identity(project, declaration) else {
                    continue;
                };
                match &declaration.kind {
                    ResolvedDeclarationKind::Function(function) => {
                        environment.requirements.insert(
                            identity.clone(),
                            source_requirements(&function.type_parameters, normalizer)?,
                        );
                    }
                    ResolvedDeclarationKind::Struct {
                        type_parameters, ..
                    }
                    | ResolvedDeclarationKind::Enum {
                        type_parameters, ..
                    }
                    | ResolvedDeclarationKind::Effect {
                        type_parameters, ..
                    }
                    | ResolvedDeclarationKind::EffectAlias {
                        type_parameters, ..
                    } => {
                        environment.owner_formals.insert(
                            identity.clone(),
                            declaration_formals(identity, type_parameters),
                        );
                        environment.requirements.insert(
                            identity.clone(),
                            source_requirements(type_parameters, normalizer)?,
                        );
                    }
                    ResolvedDeclarationKind::InherentImpl(_)
                    | ResolvedDeclarationKind::TraitImpl { .. } => {
                        let (implementation, trait_use, where_clause) = match &declaration.kind {
                            ResolvedDeclarationKind::InherentImpl(implementation) => {
                                (implementation, None, None)
                            }
                            ResolvedDeclarationKind::TraitImpl {
                                implementation,
                                trait_type,
                                where_clause,
                            } => (
                                implementation.as_ref(),
                                Some(normalizer.trait_use(trait_type, &BTreeMap::new())?),
                                where_clause.as_ref(),
                            ),
                            _ => unreachable!(),
                        };
                        if trait_use.as_ref().is_some_and(|bound| {
                            [
                                &project.core_roles.drop.declaration,
                                &project.core_roles.copy,
                                &project.core_roles.fn_once,
                                &project.core_roles.fn_mut,
                                &project.core_roles.function,
                            ]
                            .contains(&&bound.declaration)
                        }) {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::Unsupported,
                                "source impl cannot provide closed Fn/Copy capabilities or the deferred user Drop resource behavior",
                                declaration.origin.clone(),
                                Vec::new(),
                            ));
                        }
                        let mut requirements =
                            source_requirements(&implementation.type_parameters, normalizer)?;
                        for predicate in where_clause
                            .into_iter()
                            .flat_map(|clause| &clause.predicates)
                        {
                            let subject = normalizer.normalize(&predicate.subject)?;
                            for bound in &predicate.bounds {
                                requirements.push(Requirement {
                                    subject: subject.clone(),
                                    bound: normalizer.trait_use(bound, &BTreeMap::new())?,
                                    origin: CheckOrigin::Source(
                                        reference_origin(&bound.reference).clone(),
                                    ),
                                });
                            }
                        }
                        let target = normalizer.normalize(&ResolvedType {
                            span: implementation.target.span,
                            kind: ResolvedTypeKind::Named(Box::new(implementation.target.clone())),
                        })?;
                        let mut associated = BTreeMap::new();
                        let mut methods = BTreeMap::new();
                        for member in &implementation.members {
                            match &member.kind {
                                ResolvedImplMemberKind::Function(function) => {
                                    methods.insert(
                                        member.identity.name.clone(),
                                        member.identity.clone(),
                                    );
                                    environment.requirements.insert(
                                        member.identity.clone(),
                                        source_requirements(&function.type_parameters, normalizer)?,
                                    );
                                }
                                ResolvedImplMemberKind::AssociatedType(ty) => {
                                    let selected = if let Some(bound) = &trait_use {
                                        environment.traits[&bound.declaration]
                                            .associated
                                            .keys()
                                            .find(|item| item.name == member.identity.name)
                                            .cloned()
                                    } else {
                                        Some(member.identity.clone())
                                    };
                                    let Some(selected) = selected else {
                                        return Err(source_diagnostic(
                                            CheckDiagnosticKind::TypeMismatch,
                                            "impl defines an associated type absent from its trait",
                                            entity_origin(&member.identity).unwrap(),
                                            vec![declaration.origin.clone()],
                                        ));
                                    };
                                    normalizer
                                        .associated_members
                                        .insert(member.identity.clone(), selected.clone());
                                    associated.insert(selected, normalizer.normalize(ty)?);
                                }
                            }
                        }
                        environment
                            .requirements
                            .insert(identity.clone(), requirements.clone());
                        environment.implementations.push(ImplDefinition {
                            identity: identity.clone(),
                            formals: environment.owner_formals[identity].clone(),
                            target,
                            trait_use,
                            requirements,
                            associated,
                            methods,
                        });
                    }
                    _ => {}
                }
            }
        }
        Ok(environment)
    }
}

fn source_requirements(
    parameters: &[ResolvedTypeParameter],
    normalizer: &mut SourceTypeNormalizer,
) -> Result<Vec<Requirement>, CheckDiagnostic> {
    let mut requirements = Vec::new();
    for parameter in parameters {
        for bound in &parameter.bounds {
            if let ResolvedGenericBound::Named(bound) = bound {
                let formal = normalizer.source_formals[&parameter.binding.identity].clone();
                requirements.push(Requirement {
                    subject: CheckedType::Formal(Box::new(formal)),
                    bound: normalizer.trait_use(bound, &BTreeMap::new())?,
                    origin: CheckOrigin::Source(reference_origin(&bound.reference).clone()),
                });
            }
        }
    }
    Ok(requirements)
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct TraitGoal {
    subject: CheckedType,
    bound: TraitUse,
}

#[derive(Debug, Clone)]
pub(super) enum Evidence {
    Given {
        subject: CheckedType,
        bound: TraitUse,
    },
    Source {
        implementation: EntityId,
        mapping: BTreeMap<TypeFormal, CheckedType>,
        premises: Vec<Evidence>,
    },
    Primitive {
        subject: CheckedType,
        declaration: EntityId,
    },
    Callable {
        value: FunctionValue,
        declaration: EntityId,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum Query {
    Type(CheckedType),
    Evidence(Box<TraitGoal>),
    Applicable(Box<Candidate>),
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum Candidate {
    Trait(TraitGoal),
    Inherent {
        implementation: EntityId,
        mapping: BTreeMap<TypeFormal, CheckedType>,
    },
}

#[derive(Clone)]
enum Answer {
    Type(CheckedType),
    Evidence(Box<Evidence>),
    Applicable(Option<Box<Evidence>>),
}

impl Query {
    fn evidence(goal: TraitGoal) -> Self {
        Self::Evidence(Box::new(goal))
    }
}
impl Answer {
    fn evidence(evidence: Evidence) -> Self {
        Self::Evidence(Box::new(evidence))
    }
}

enum SolveFrame {
    Enter(Query),
    Remember(Query),
    Applicability(usize),
    Tuple(usize),
    Nominal(EntityId, usize),
    Function(EntityId, Vec<TypeFormal>),
    Projection(ProjectionType),
    TraitProjection(Box<ProjectionType>),
    QualifiedProjection {
        projection: Box<ProjectionType>,
        choices: Vec<(EntityId, TraitUse)>,
    },
    QualifiedInherent {
        projection: Box<ProjectionType>,
        choices: Vec<(EntityId, CheckedType)>,
    },
    SelectedProjection {
        projection: Box<ProjectionType>,
        bound: TraitUse,
    },
    EvidenceTypes {
        goal: TraitGoal,
        associated: Vec<EntityId>,
    },
    Select(TraitGoal),
    ExpandImpl {
        identity: EntityId,
        mapping: BTreeMap<TypeFormal, CheckedType>,
        goal: TraitGoal,
    },
    InferAssociated {
        identity: EntityId,
        mapping: BTreeMap<TypeFormal, CheckedType>,
        goal: TraitGoal,
        pattern: CheckedType,
    },
    CheckInferredBinding {
        identity: EntityId,
        mapping: BTreeMap<TypeFormal, CheckedType>,
        goal: TraitGoal,
        actual: CheckedType,
    },
    CheckAssociated {
        identity: EntityId,
        mapping: BTreeMap<TypeFormal, CheckedType>,
        requirements: Vec<Requirement>,
        expected: Vec<CheckedType>,
    },
    SourceEvidence {
        identity: EntityId,
        mapping: BTreeMap<TypeFormal, CheckedType>,
        count: usize,
    },
}

// Both bounds count logical work, independent of wall time and host recursion.
// The same counter includes projection expansion and candidate header matching.
const SOLVE_WORK_LIMIT: usize = 8192;
const SOLVE_TYPE_LIMIT: usize = 256;

// Only a definite failure of a closed condition may unwind to this boundary.
// Cycles, ambiguous selection and work exhaustion propagate as diagnostics.
fn reject_inapplicable(
    frames: &mut Vec<SolveFrame>,
    values: &mut Vec<Answer>,
    active: &mut BTreeSet<Query>,
) -> bool {
    let Some((index, base)) = frames.iter().enumerate().rev().find_map(|(index, frame)| {
        if let SolveFrame::Applicability(base) = frame {
            Some((index, *base))
        } else {
            None
        }
    }) else {
        return false;
    };
    for frame in frames.drain(index..) {
        if let SolveFrame::Remember(query) = frame {
            active.remove(&query);
        }
    }
    values.truncate(base);
    values.push(Answer::Applicable(None));
    true
}

pub(super) struct TraitSolver<'a> {
    environment: &'a TraitEnvironment,
    project: &'a ResolvedProject,
    inference: &'a TypeInference,
    givens: Vec<Requirement>,
    origin: OriginRef,
    remaining: usize,
    answers: BTreeMap<Query, Answer>,
    public_surface: bool,
}

impl<'a> TraitSolver<'a> {
    pub(super) fn new(
        environment: &'a TraitEnvironment,
        project: &'a ResolvedProject,
        inference: &'a TypeInference,
        givens: &[Requirement],
        origin: OriginRef,
    ) -> Result<Self, CheckDiagnostic> {
        let mut solver = Self {
            environment,
            project,
            inference,
            givens: givens.to_vec(),
            origin,
            remaining: SOLVE_WORK_LIMIT,
            answers: BTreeMap::new(),
            public_surface: false,
        };
        let mut visited = BTreeSet::new();
        let mut index = 0;
        while index < solver.givens.len() {
            solver.charge()?;
            let given = solver.givens[index].clone();
            index += 1;
            if !visited.insert(TraitGoal {
                subject: given.subject.clone(),
                bound: given.bound.clone(),
            }) {
                continue;
            }
            let definition = &environment.traits[&given.bound.declaration];
            let mapping = trait_mapping(definition, &given.subject, &given.bound.arguments);
            for requirement in &definition.requirements {
                if !matches!(&requirement.subject, CheckedType::Formal(formal) if formal.as_ref() == &definition.self_type)
                {
                    continue;
                }
                let requirement = instantiate_requirement(requirement, &mapping);
                if !visited.contains(&TraitGoal {
                    subject: requirement.subject.clone(),
                    bound: requirement.bound.clone(),
                }) {
                    solver.givens.push(requirement);
                }
            }
        }
        for index in 0..solver.givens.len() {
            let mut given = solver.givens[index].clone();
            normalize_requirement(&mut given, &mut solver)?;
            solver.givens[index] = given;
        }
        // Answers made while normalizing inputs can retain their old spelling.
        // Subsequent proof results must use the completed dictionary inputs.
        solver.answers.clear();
        Ok(solver)
    }

    pub(super) fn set_public_surface(&mut self, exposed: bool) {
        if self.public_surface != exposed {
            self.answers.clear();
            self.public_surface = exposed;
        }
    }

    fn require_public_associated(
        &self,
        member: &EntityId,
        trait_owner: Option<&EntityId>,
    ) -> Result<(), CheckDiagnostic> {
        if self.public_surface
            && !trait_owner.map_or_else(
                || self.project.entities[member].public,
                |owner| actual_public_exports(self.project).contains(owner),
            )
        {
            return Err(self.diagnostic(format!(
                "public type surface references private associated declaration `{}`",
                member.name
            )));
        }
        Ok(())
    }

    fn bounds_for_type(&mut self, ty: &CheckedType) -> Result<Vec<Requirement>, CheckDiagnostic> {
        let mut bounds = self
            .givens
            .iter()
            .filter(|given| inferred_types_equal(&given.subject, ty, self.inference))
            .cloned()
            .collect::<Vec<_>>();
        if let CheckedType::Projection(projection) = ty
            && let (Some(member), Some(bound)) = (&projection.member, &projection.bound)
        {
            let definition = &self.environment.traits[&bound.declaration];
            let mapping = trait_mapping(definition, &projection.receiver, &bound.arguments);
            for bound in &definition.associated[member].0 {
                bounds.push(Requirement {
                    subject: ty.clone(),
                    bound: instantiate_trait(bound, &mapping),
                    origin: CheckOrigin::Source(entity_origin(member).unwrap()),
                });
            }
        }
        let mut index = 0;
        let mut visited = BTreeSet::new();
        while index < bounds.len() {
            self.charge()?;
            let bound = bounds[index].clone();
            index += 1;
            if !visited.insert((bound.subject.clone(), bound.bound.clone())) {
                continue;
            }
            let definition = &self.environment.traits[&bound.bound.declaration];
            let mapping = trait_mapping(definition, &bound.subject, &bound.bound.arguments);
            bounds.extend(
                definition
                    .requirements
                    .iter()
                    .filter(|requirement| matches!(&requirement.subject, CheckedType::Formal(formal) if formal.as_ref() == &definition.self_type))
                    .map(|requirement| instantiate_requirement(requirement, &mapping))
                    .filter(|requirement| {
                        !visited.contains(&(requirement.subject.clone(), requirement.bound.clone()))
                    }),
            );
        }
        Ok(bounds
            .into_iter()
            .filter(|bound| inferred_types_equal(&bound.subject, ty, self.inference))
            .collect())
    }

    fn diagnostic(&self, message: impl Into<String>) -> CheckDiagnostic {
        CheckDiagnostic {
            kind: CheckDiagnosticKind::TypeMismatch,
            message: message.into(),
            primary: Some(CheckOrigin::Source(self.origin.clone())),
            related: self
                .givens
                .iter()
                .map(|given| given.origin.clone())
                .collect(),
        }
    }

    fn charge(&mut self) -> Result<(), CheckDiagnostic> {
        if self.remaining == 0 {
            return Err(self.incomplete(format!("logical work limit {SOLVE_WORK_LIMIT} exhausted")));
        }
        self.remaining -= 1;
        Ok(())
    }

    fn incomplete(&self, reason: impl fmt::Display) -> CheckDiagnostic {
        source_diagnostic(
            CheckDiagnosticKind::Unsupported,
            format!(
                "incomplete solve: {reason}; used {} of {SOLVE_WORK_LIMIT} logical work units",
                SOLVE_WORK_LIMIT - self.remaining
            ),
            self.origin.clone(),
            Vec::new(),
        )
    }

    fn check_size(&mut self, ty: &CheckedType) -> Result<(), CheckDiagnostic> {
        let mut pending = vec![ty];
        let mut count = 0;
        while let Some(ty) = pending.pop() {
            count += 1;
            self.charge()?;
            if count > SOLVE_TYPE_LIMIT {
                return Err(self.incomplete(format!("type state exceeds {SOLVE_TYPE_LIMIT} nodes")));
            }
            match ty {
                CheckedType::Tuple(elements) => pending.extend(elements),
                CheckedType::Nominal(nominal) => pending.extend(&nominal.arguments),
                CheckedType::Projection(projection) => {
                    pending.push(&projection.receiver);
                    if let Some(bound) = &projection.bound {
                        pending.extend(&bound.arguments);
                        pending.extend(bound.associated.values());
                    }
                }
                CheckedType::Function(value) => {
                    pending.extend(value.types.iter().map(|(_, ty)| ty))
                }
                _ => {}
            }
        }
        Ok(())
    }

    pub(super) fn normalize(&mut self, ty: &CheckedType) -> Result<CheckedType, CheckDiagnostic> {
        let Answer::Type(ty) = self.solve(Query::Type(self.inference.resolve(ty)))? else {
            unreachable!()
        };
        Ok(ty)
    }

    pub(super) fn prove(&mut self, requirement: &Requirement) -> Result<Evidence, CheckDiagnostic> {
        let answer = self
            .solve(Query::evidence(TraitGoal {
                subject: self.inference.resolve(&requirement.subject),
                bound: requirement.bound.clone(),
            }))
            .map_err(|mut diagnostic| {
                if !diagnostic.related.contains(&requirement.origin) {
                    diagnostic.related.push(requirement.origin.clone());
                }
                diagnostic
            })?;
        let Answer::Evidence(evidence) = answer else {
            unreachable!()
        };
        Ok(*evidence)
    }

    fn applicable(&mut self, candidate: Candidate) -> Result<Option<Evidence>, CheckDiagnostic> {
        let Answer::Applicable(evidence) = self.solve(Query::Applicable(Box::new(candidate)))?
        else {
            unreachable!()
        };
        Ok(evidence.map(|evidence| *evidence))
    }

    fn solve(&mut self, root: Query) -> Result<Answer, CheckDiagnostic> {
        let mut frames = vec![SolveFrame::Enter(root)];
        let mut values = Vec::new();
        let mut active = BTreeSet::new();
        while let Some(frame) = frames.pop() {
            self.charge()?;
            match frame {
                SolveFrame::Enter(query) => {
                    if let Some(answer) = self.answers.get(&query) {
                        values.push(answer.clone());
                        continue;
                    }
                    if !active.insert(query.clone()) {
                        return Err(self.diagnostic("illegal type/projection/evidence cycle: the query needs its own unproved answer"));
                    }
                    frames.push(SolveFrame::Remember(query.clone()));
                    match query {
                        Query::Applicable(candidate) => {
                            frames.push(SolveFrame::Applicability(values.len()));
                            match *candidate {
                                Candidate::Trait(goal) => {
                                    frames.push(SolveFrame::Enter(Query::evidence(goal)))
                                }
                                Candidate::Inherent {
                                    implementation,
                                    mapping,
                                } => {
                                    let definition = self
                                        .environment
                                        .implementations
                                        .iter()
                                        .find(|item| item.identity == implementation)
                                        .unwrap();
                                    frames.push(SolveFrame::SourceEvidence {
                                        identity: implementation,
                                        mapping: mapping.clone(),
                                        count: definition.requirements.len(),
                                    });
                                    frames.extend(definition.requirements.iter().rev().map(
                                        |requirement| {
                                            let requirement =
                                                instantiate_requirement(requirement, &mapping);
                                            SolveFrame::Enter(Query::evidence(TraitGoal {
                                                subject: requirement.subject,
                                                bound: requirement.bound,
                                            }))
                                        },
                                    ));
                                }
                            }
                        }
                        Query::Type(ty) => {
                            self.check_size(&ty)?;
                            match ty {
                                CheckedType::Tuple(elements) => {
                                    frames.push(SolveFrame::Tuple(elements.len()));
                                    frames.extend(
                                        elements
                                            .into_iter()
                                            .rev()
                                            .map(|ty| SolveFrame::Enter(Query::Type(ty))),
                                    );
                                }
                                CheckedType::Nominal(nominal) => {
                                    frames.push(SolveFrame::Nominal(
                                        nominal.declaration,
                                        nominal.arguments.len(),
                                    ));
                                    frames.extend(
                                        nominal
                                            .arguments
                                            .into_iter()
                                            .rev()
                                            .map(|ty| SolveFrame::Enter(Query::Type(ty))),
                                    );
                                }
                                CheckedType::Projection(projection) => {
                                    let receiver = projection.receiver.clone();
                                    frames.push(SolveFrame::Projection(*projection));
                                    frames.push(SolveFrame::Enter(Query::Type(receiver)));
                                }
                                CheckedType::Function(value) => {
                                    frames.push(SolveFrame::Function(
                                        value.declaration,
                                        value
                                            .types
                                            .iter()
                                            .map(|(formal, _)| formal.clone())
                                            .collect(),
                                    ));
                                    frames.extend(
                                        value
                                            .types
                                            .into_iter()
                                            .rev()
                                            .map(|(_, ty)| SolveFrame::Enter(Query::Type(ty))),
                                    );
                                }
                                other => values.push(Answer::Type(other)),
                            }
                        }
                        Query::Evidence(goal) => {
                            let goal = *goal;
                            let associated =
                                goal.bound.associated.keys().cloned().collect::<Vec<_>>();
                            let types = std::iter::once(goal.subject.clone())
                                .chain(goal.bound.arguments.iter().cloned())
                                .chain(goal.bound.associated.values().cloned())
                                .collect::<Vec<_>>();
                            frames.push(SolveFrame::EvidenceTypes { goal, associated });
                            frames.extend(
                                types
                                    .into_iter()
                                    .rev()
                                    .map(|ty| SolveFrame::Enter(Query::Type(ty))),
                            );
                        }
                    }
                }
                SolveFrame::Remember(query) => {
                    self.answers.insert(
                        query.clone(),
                        values
                            .last()
                            .expect("each query produces an answer")
                            .clone(),
                    );
                    active.remove(&query);
                }
                SolveFrame::Applicability(_) => {
                    let Answer::Evidence(evidence) = values.pop().unwrap() else {
                        unreachable!()
                    };
                    values.push(Answer::Applicable(Some(evidence)));
                }
                SolveFrame::Tuple(count) => {
                    let elements = take_types(&mut values, count);
                    values.push(Answer::Type(CheckedType::Tuple(elements)));
                }
                SolveFrame::Nominal(declaration, count) => {
                    let arguments = take_types(&mut values, count);
                    values.push(Answer::Type(CheckedType::Nominal(Box::new(NominalType {
                        declaration,
                        arguments,
                    }))));
                }
                SolveFrame::Function(declaration, formals) => {
                    let types = take_types(&mut values, formals.len());
                    values.push(Answer::Type(CheckedType::Function(Box::new(
                        FunctionValue {
                            declaration,
                            types: formals.into_iter().zip(types).collect(),
                        },
                    ))));
                }
                SolveFrame::Projection(mut projection) => {
                    projection.receiver = take_types(&mut values, 1).pop().unwrap();
                    if projection.bound.is_none() {
                        let has_given =
                            self.bounds_for_type(&projection.receiver)?
                                .iter()
                                .any(|given| {
                                    self.environment.traits[&given.bound.declaration]
                                        .associated
                                        .keys()
                                        .any(|member| {
                                            member.name == projection.name
                                                && projection
                                                    .member
                                                    .as_ref()
                                                    .is_none_or(|selected| selected == member)
                                        })
                                });
                        if !has_given {
                            let mut candidates = Vec::new();
                            let caller = module_for_origin(self.project, &self.origin)
                                .expect("projection has a source module");
                            let mut hidden = false;
                            for implementation in self
                                .environment
                                .implementations
                                .iter()
                                .filter(|implementation| implementation.trait_use.is_none())
                            {
                                let Some((member, value)) =
                                    implementation.associated.iter().find(|(member, _)| {
                                        member.name == projection.name
                                            && projection
                                                .member
                                                .as_ref()
                                                .is_none_or(|selected| selected == *member)
                                    })
                                else {
                                    continue;
                                };
                                let mut mapping = BTreeMap::new();
                                if !match_type(
                                    &implementation.target,
                                    &projection.receiver,
                                    &implementation.formals,
                                    &mut mapping,
                                ) {
                                    continue;
                                }
                                if !self.project.entities[member].public
                                    && !(caller.library() == member.module.library()
                                        && caller.path().starts_with(member.module.path()))
                                {
                                    hidden = true;
                                    continue;
                                }
                                candidates.push((
                                    implementation,
                                    member,
                                    instantiate_type(value, &mapping),
                                    mapping,
                                ));
                            }
                            if !candidates.is_empty() {
                                let queries = candidates
                                    .iter()
                                    .map(|(implementation, _, _, mapping)| {
                                        Query::Applicable(Box::new(Candidate::Inherent {
                                            implementation: implementation.identity.clone(),
                                            mapping: mapping.clone(),
                                        }))
                                    })
                                    .collect::<Vec<_>>();
                                let choices = candidates
                                    .into_iter()
                                    .map(|(_, member, replacement, _)| {
                                        (member.clone(), replacement)
                                    })
                                    .collect();
                                frames.push(SolveFrame::QualifiedInherent {
                                    projection: Box::new(projection),
                                    choices,
                                });
                                frames.extend(queries.into_iter().rev().map(SolveFrame::Enter));
                                continue;
                            }
                            if hidden && self.projection_bounds(&projection)?.0.is_empty() {
                                return Err(self.diagnostic(
                                    "inherent associated type is private in this scope",
                                ));
                            }
                        }
                    }
                    frames.push(SolveFrame::TraitProjection(Box::new(projection)));
                }
                SolveFrame::QualifiedInherent {
                    projection,
                    choices,
                } => {
                    let results = values.split_off(values.len() - choices.len());
                    let mut available = choices
                        .into_iter()
                        .zip(results)
                        .filter_map(|(choice, result)| {
                            let Answer::Applicable(proof) = result else {
                                unreachable!()
                            };
                            proof.map(|_| choice)
                        })
                        .collect::<Vec<_>>();
                    if available.len() > 1 {
                        return Err(self.diagnostic("ambiguous inherent associated selection"));
                    }
                    if let Some((member, replacement)) = available.pop() {
                        self.require_public_associated(&member, None)?;
                        frames.push(SolveFrame::Enter(Query::Type(replacement)));
                    } else {
                        frames.push(SolveFrame::TraitProjection(projection));
                    }
                }
                SolveFrame::QualifiedProjection {
                    mut projection,
                    choices,
                } => {
                    let results = values.split_off(values.len() - choices.len());
                    let mut available = choices
                        .into_iter()
                        .zip(results)
                        .filter_map(|(choice, result)| {
                            let Answer::Applicable(proof) = result else {
                                unreachable!()
                            };
                            proof.map(|proof| (choice, proof))
                        })
                        .collect::<Vec<_>>();
                    if available.len() != 1 {
                        return Err(self.diagnostic(if available.is_empty() {
                            "associated selection has no trait evidence"
                        } else {
                            "ambiguous associated selection"
                        }));
                    }
                    let ((member, bound), proof) = available.pop().unwrap();
                    self.require_public_associated(&member, Some(&bound.declaration))?;
                    projection.member = Some(member);
                    projection.bound = Some(bound.clone());
                    frames.push(SolveFrame::SelectedProjection { projection, bound });
                    values.push(Answer::Evidence(proof));
                }
                SolveFrame::TraitProjection(mut projection) => {
                    let (choices, fixed) = self.projection_bounds(&projection)?;
                    if !fixed {
                        let queries = choices
                            .iter()
                            .map(|(_, bound)| {
                                Query::Applicable(Box::new(Candidate::Trait(TraitGoal {
                                    subject: projection.receiver.clone(),
                                    bound: bound.clone(),
                                })))
                            })
                            .collect::<Vec<_>>();
                        frames.push(SolveFrame::QualifiedProjection {
                            projection,
                            choices,
                        });
                        frames.extend(queries.into_iter().rev().map(SolveFrame::Enter));
                        continue;
                    }
                    let [(member, bound)] = choices.as_slice() else {
                        return Err(self.diagnostic(if choices.is_empty() {
                            "associated selection has no trait evidence"
                        } else {
                            "ambiguous associated selection"
                        }));
                    };
                    projection.member = Some(member.clone());
                    projection.bound = Some(bound.clone());
                    self.require_public_associated(member, Some(&bound.declaration))?;
                    let query = Query::evidence(TraitGoal {
                        subject: projection.receiver.clone(),
                        bound: bound.clone(),
                    });
                    frames.push(SolveFrame::SelectedProjection {
                        projection,
                        bound: bound.clone(),
                    });
                    frames.push(SolveFrame::Enter(query));
                }
                SolveFrame::SelectedProjection { projection, bound } => {
                    let projection = *projection;
                    let Answer::Evidence(evidence) = values.pop().unwrap() else {
                        unreachable!()
                    };
                    let member = projection.member.as_ref().unwrap();
                    let replacement = match *evidence {
                        Evidence::Given { bound, .. } => bound.associated.get(member).cloned(),
                        Evidence::Source {
                            implementation,
                            mapping,
                            ..
                        } => {
                            let implementation = self
                                .environment
                                .implementations
                                .iter()
                                .find(|item| item.identity == implementation)
                                .unwrap();
                            if let Some(value) = implementation.associated.get(member) {
                                Some(instantiate_type(value, &mapping))
                            } else {
                                let definition = &self.environment.traits[&bound.declaration];
                                let default = definition.associated[member].1.as_ref();
                                default.map(|ty| {
                                    instantiate_type(
                                        ty,
                                        &trait_mapping(
                                            definition,
                                            &projection.receiver,
                                            &bound.arguments,
                                        ),
                                    )
                                })
                            }
                        }
                        Evidence::Primitive { .. } | Evidence::Callable { .. } => None,
                    };
                    if let Some(replacement) = replacement {
                        frames.push(SolveFrame::Enter(Query::Type(replacement)));
                    } else {
                        values.push(Answer::Type(CheckedType::Projection(Box::new(projection))));
                    }
                }
                SolveFrame::EvidenceTypes {
                    mut goal,
                    associated,
                } => {
                    let mut types = take_types(
                        &mut values,
                        1 + goal.bound.arguments.len() + associated.len(),
                    )
                    .into_iter();
                    goal.subject = types.next().unwrap();
                    goal.bound.arguments =
                        types.by_ref().take(goal.bound.arguments.len()).collect();
                    goal.bound.associated = associated.into_iter().zip(types).collect();
                    frames.push(SolveFrame::Select(goal));
                }
                SolveFrame::Select(goal) => {
                    if let Some(given) =
                        self.bounds_for_type(&goal.subject)?.iter().find(|given| {
                            inferred_types_equal(&given.subject, &goal.subject, self.inference)
                                && given.bound.declaration == goal.bound.declaration
                                && given.bound.arguments == goal.bound.arguments
                                && goal.bound.associated.iter().all(|(member, ty)| {
                                    given.bound.associated.get(member) == Some(ty)
                                })
                        })
                    {
                        values.push(Answer::evidence(Evidence::Given {
                            subject: goal.subject,
                            bound: given.bound.clone(),
                        }));
                        continue;
                    }
                    if let CheckedType::Function(value) = &goal.subject
                        && [
                            &self.project.core_roles.function,
                            &self.project.core_roles.fn_mut,
                            &self.project.core_roles.fn_once,
                        ]
                        .contains(&&goal.bound.declaration)
                    {
                        values.push(Answer::evidence(Evidence::Callable {
                            value: value.as_ref().clone(),
                            declaration: goal.bound.declaration,
                        }));
                        continue;
                    }
                    if self.primitive_evidence(&goal) {
                        values.push(Answer::evidence(Evidence::Primitive {
                            subject: goal.subject,
                            declaration: goal.bound.declaration,
                        }));
                        continue;
                    }
                    if matches!(goal.subject, CheckedType::Infer(_)) {
                        return Err(self.incomplete(
                            "trait selection still requires an unknown receiver type",
                        ));
                    }
                    let mut candidates = Vec::new();
                    for implementation in &self.environment.implementations {
                        let Some(bound) = &implementation.trait_use else {
                            continue;
                        };
                        if bound.declaration != goal.bound.declaration {
                            continue;
                        }
                        let mut mapping = BTreeMap::new();
                        if match_type(
                            &implementation.target,
                            &goal.subject,
                            &implementation.formals,
                            &mut mapping,
                        ) && bound.arguments.iter().zip(&goal.bound.arguments).all(
                            |(pattern, actual)| {
                                match_type(pattern, actual, &implementation.formals, &mut mapping)
                            },
                        ) {
                            candidates.push((implementation, mapping));
                        }
                    }
                    if candidates.is_empty()
                        && std::iter::once(&goal.subject)
                            .chain(&goal.bound.arguments)
                            .chain(goal.bound.associated.values())
                            .all(closed_identity_type)
                        && reject_inapplicable(&mut frames, &mut values, &mut active)
                    {
                        continue;
                    }
                    let [(implementation, mapping)] = candidates.as_slice() else {
                        return Err(self.diagnostic(if candidates.is_empty() {
                            format!(
                                "no impl evidence for {}: {}",
                                display_type(&goal.subject),
                                goal.bound.declaration.name
                            )
                        } else {
                            "trait selection cannot prove one applicable impl".to_owned()
                        }));
                    };
                    frames.push(SolveFrame::ExpandImpl {
                        identity: implementation.identity.clone(),
                        mapping: mapping.clone(),
                        goal,
                    });
                }
                SolveFrame::ExpandImpl {
                    identity,
                    mapping,
                    goal,
                } => {
                    let implementation = self
                        .environment
                        .implementations
                        .iter()
                        .find(|item| item.identity == identity)
                        .unwrap();
                    let missing = implementation
                        .formals
                        .iter()
                        .filter(|formal| !mapping.contains_key(*formal))
                        .cloned()
                        .collect::<BTreeSet<_>>();
                    if !missing.is_empty() {
                        let known = mapping.keys().cloned().collect::<BTreeSet<_>>();
                        let inferred = implementation.requirements.iter().find_map(|requirement| {
                            if !fixed_formals(&requirement.subject).is_subset(&known)
                                || requirement
                                    .bound
                                    .arguments
                                    .iter()
                                    .any(|ty| !fixed_formals(ty).is_subset(&known))
                            {
                                return None;
                            }
                            requirement
                                .bound
                                .associated
                                .iter()
                                .find_map(|(member, pattern)| {
                                    (!fixed_formals(pattern).is_disjoint(&missing)).then(|| {
                                        let mut bound =
                                            instantiate_trait(&requirement.bound, &mapping);
                                        bound.associated.clear();
                                        (
                                            pattern.clone(),
                                            CheckedType::Projection(Box::new(ProjectionType {
                                                receiver: instantiate_type(
                                                    &requirement.subject,
                                                    &mapping,
                                                ),
                                                member: Some(member.clone()),
                                                name: member.name.clone(),
                                                bound: Some(bound),
                                            })),
                                        )
                                    })
                                })
                        });
                        let Some((pattern, projection)) = inferred else {
                            return Err(self.diagnostic("impl type formal is not determined by its header or associated binding"));
                        };
                        frames.push(SolveFrame::InferAssociated {
                            identity,
                            mapping,
                            goal,
                            pattern,
                        });
                        frames.push(SolveFrame::Enter(Query::Type(projection)));
                        continue;
                    }
                    let requirements = implementation
                        .requirements
                        .iter()
                        .map(|requirement| instantiate_requirement(requirement, &mapping))
                        .collect::<Vec<_>>();
                    let actuals = goal
                        .bound
                        .associated
                        .keys()
                        .map(|member| {
                            instantiate_type(&implementation.associated[member], &mapping)
                        })
                        .collect::<Vec<_>>();
                    frames.push(SolveFrame::CheckAssociated {
                        identity,
                        mapping,
                        requirements,
                        expected: goal.bound.associated.into_values().collect(),
                    });
                    frames.extend(
                        actuals
                            .into_iter()
                            .rev()
                            .map(|ty| SolveFrame::Enter(Query::Type(ty))),
                    );
                }
                SolveFrame::InferAssociated {
                    identity,
                    mut mapping,
                    goal,
                    pattern,
                } => {
                    let actual = take_types(&mut values, 1).pop().unwrap();
                    let implementation = self
                        .environment
                        .implementations
                        .iter()
                        .find(|item| item.identity == identity)
                        .unwrap();
                    if !match_type(&pattern, &actual, &implementation.formals, &mut mapping) {
                        let pattern = instantiate_type(&pattern, &mapping);
                        frames.push(SolveFrame::CheckInferredBinding {
                            identity,
                            mapping,
                            goal,
                            actual,
                        });
                        frames.push(SolveFrame::Enter(Query::Type(pattern)));
                        continue;
                    }
                    frames.push(SolveFrame::ExpandImpl {
                        identity,
                        mapping,
                        goal,
                    });
                }
                SolveFrame::CheckAssociated {
                    identity,
                    mapping,
                    requirements,
                    expected,
                } => {
                    let actuals = take_types(&mut values, expected.len());
                    if actuals.iter().zip(&expected).any(|(actual, expected)| {
                        !inferred_types_equal(actual, expected, self.inference)
                    }) {
                        if actuals.iter().chain(&expected).all(closed_identity_type)
                            && reject_inapplicable(&mut frames, &mut values, &mut active)
                        {
                            continue;
                        }
                        return Err(self.diagnostic(
                            "impl associated assignment does not satisfy the requested binding",
                        ));
                    }
                    frames.push(SolveFrame::SourceEvidence {
                        identity,
                        mapping,
                        count: requirements.len(),
                    });
                    frames.extend(requirements.into_iter().rev().map(|requirement| {
                        SolveFrame::Enter(Query::evidence(TraitGoal {
                            subject: requirement.subject,
                            bound: requirement.bound,
                        }))
                    }));
                }
                SolveFrame::CheckInferredBinding {
                    identity,
                    mut mapping,
                    goal,
                    actual,
                } => {
                    let pattern = take_types(&mut values, 1).pop().unwrap();
                    let implementation = self
                        .environment
                        .implementations
                        .iter()
                        .find(|item| item.identity == identity)
                        .unwrap();
                    if !match_type(&pattern, &actual, &implementation.formals, &mut mapping) {
                        let instantiated = instantiate_type(&pattern, &mapping);
                        if instantiated != pattern {
                            frames.push(SolveFrame::CheckInferredBinding {
                                identity,
                                mapping,
                                goal,
                                actual,
                            });
                            frames.push(SolveFrame::Enter(Query::Type(instantiated)));
                            continue;
                        }
                        if closed_identity_type(&pattern)
                            && closed_identity_type(&actual)
                            && reject_inapplicable(&mut frames, &mut values, &mut active)
                        {
                            continue;
                        }
                        return Err(
                            self.diagnostic("associated binding conflicts with impl type actuals")
                        );
                    }
                    frames.push(SolveFrame::ExpandImpl {
                        identity,
                        mapping,
                        goal,
                    });
                }
                SolveFrame::SourceEvidence {
                    identity,
                    mapping,
                    count,
                } => {
                    let premises = values
                        .split_off(values.len() - count)
                        .into_iter()
                        .map(|answer| {
                            let Answer::Evidence(evidence) = answer else {
                                unreachable!()
                            };
                            *evidence
                        })
                        .collect();
                    values.push(Answer::evidence(Evidence::Source {
                        implementation: identity,
                        mapping,
                        premises,
                    }));
                }
            }
        }
        Ok(values.pop().expect("the root query produces one answer"))
    }

    fn projection_bounds(
        &mut self,
        projection: &ProjectionType,
    ) -> Result<(Vec<(EntityId, TraitUse)>, bool), CheckDiagnostic> {
        let caller = module_for_origin(self.project, &self.origin)
            .expect("projection has a real source scope");
        if let (Some(member), Some(bound)) = (&projection.member, &projection.bound) {
            if !member_accessible_in_module(member, &caller, self.project) {
                return Err(self.diagnostic("associated type is private in this scope"));
            }
            return Ok((vec![(member.clone(), bound.clone())], true));
        }
        let mut choices = BTreeSet::new();
        for given in self.bounds_for_type(&projection.receiver)? {
            for member in self.environment.traits[&given.bound.declaration]
                .associated
                .keys()
            {
                if member_accessible_in_module(member, &caller, self.project)
                    && member.name == projection.name
                    && projection
                        .member
                        .as_ref()
                        .is_none_or(|selected| selected == member)
                {
                    choices.insert((member.clone(), given.bound.clone()));
                }
            }
        }
        let fixed = !choices.is_empty();
        if choices.is_empty()
            && !matches!(
                projection.receiver,
                CheckedType::Infer(_) | CheckedType::Formal(_)
            )
        {
            for implementation in &self.environment.implementations {
                let Some(bound) = &implementation.trait_use else {
                    continue;
                };
                let mut mapping = BTreeMap::new();
                if !match_type(
                    &implementation.target,
                    &projection.receiver,
                    &implementation.formals,
                    &mut mapping,
                ) {
                    continue;
                }
                for member in self.environment.traits[&bound.declaration]
                    .associated
                    .keys()
                {
                    if member_accessible_in_module(member, &caller, self.project)
                        && member.name == projection.name
                        && projection
                            .member
                            .as_ref()
                            .is_none_or(|selected| selected == member)
                    {
                        choices.insert((member.clone(), instantiate_trait(bound, &mapping)));
                    }
                }
            }
        }
        Ok((choices.into_iter().collect(), fixed))
    }

    fn primitive_evidence(&self, goal: &TraitGoal) -> bool {
        if !goal.bound.arguments.is_empty() || !goal.bound.associated.is_empty() {
            return false;
        }
        let roles = &self.project.core_roles;
        let partial = goal.bound.declaration == roles.partial_eq.declaration
            || goal.bound.declaration == roles.partial_ord.declaration;
        let total =
            goal.bound.declaration == roles.eq || goal.bound.declaration == roles.ord.declaration;
        (partial
            && matches!(
                goal.subject,
                CheckedType::Int | CheckedType::Float | CheckedType::Bool | CheckedType::Unit
            ))
            || (total
                && matches!(
                    goal.subject,
                    CheckedType::Int | CheckedType::Bool | CheckedType::Unit
                ))
    }
}

pub(super) fn validate_public_requirements(
    traits: &TraitEnvironment,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    exports: &BTreeSet<EntityId>,
) -> Result<(), CheckDiagnostic> {
    let validate_bound = |bound: &TraitUse, origin: &OriginRef| -> Result<(), CheckDiagnostic> {
        if !exports.contains(&bound.declaration) {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "public bound exposes a private trait",
                origin.clone(),
                entity_origin(&bound.declaration).into_iter().collect(),
            ));
        }
        for ty in bound.arguments.iter().chain(bound.associated.values()) {
            validate_public_nominals(ty, exports, origin)?;
        }
        Ok(())
    };
    let validate =
        |requirements: &[Requirement], origin: &OriginRef| -> Result<(), CheckDiagnostic> {
            for requirement in requirements {
                validate_public_nominals(&requirement.subject, exports, origin)?;
                validate_bound(&requirement.bound, origin)?;
            }
            Ok(())
        };
    for (identity, requirements) in &traits.requirements {
        if exports.contains(identity) {
            validate(requirements, &entity_origin(identity).unwrap())?;
        }
    }
    for (identity, definition) in &traits.traits {
        if !exports.contains(identity) {
            continue;
        }
        for (member, (bounds, default)) in &definition.associated {
            let origin = entity_origin(member).unwrap();
            for bound in bounds {
                validate_bound(bound, &origin)?;
            }
            if let Some(ty) = default {
                validate_public_nominals(ty, exports, &origin)?;
            }
        }
    }
    for implementation in &traits.implementations {
        let Some(bound) = &implementation.trait_use else {
            continue;
        };
        if !exports.contains(&bound.declaration) || !type_is_public(&implementation.target, exports)
        {
            continue;
        }
        let origin = entity_origin(&implementation.identity).unwrap();
        validate_bound(bound, &origin)?;
        validate(&implementation.requirements, &origin)?;
        for ty in implementation.associated.values() {
            validate_public_nominals(ty, exports, &origin)?;
        }
    }
    for header in headers.values().filter(|header| header.public_export) {
        validate(&header.requirements, &header.origin)?;
        validate(&header.outer_requirements, &header.origin)?;
        for shape in header.shapes.values() {
            for ty in shape
                .parameters
                .iter()
                .map(|(ty, _)| ty)
                .chain(std::iter::once(&shape.result))
            {
                validate_public_nominals(ty, exports, &header.origin)?;
            }
        }
    }
    Ok(())
}

fn take_types(values: &mut Vec<Answer>, count: usize) -> Vec<CheckedType> {
    values
        .split_off(values.len() - count)
        .into_iter()
        .map(|answer| {
            let Answer::Type(ty) = answer else {
                unreachable!()
            };
            ty
        })
        .collect()
}

fn trait_mapping(
    definition: &TraitDefinition,
    subject: &CheckedType,
    arguments: &[CheckedType],
) -> BTreeMap<TypeFormal, CheckedType> {
    std::iter::once((definition.self_type.clone(), subject.clone()))
        .chain(
            definition
                .formals
                .iter()
                .cloned()
                .zip(arguments.iter().cloned()),
        )
        .collect()
}

pub(super) fn instantiate_trait(
    bound: &TraitUse,
    mapping: &BTreeMap<TypeFormal, CheckedType>,
) -> TraitUse {
    TraitUse {
        declaration: bound.declaration.clone(),
        arguments: bound
            .arguments
            .iter()
            .map(|ty| instantiate_type(ty, mapping))
            .collect(),
        associated: bound
            .associated
            .iter()
            .map(|(member, ty)| (member.clone(), instantiate_type(ty, mapping)))
            .collect(),
    }
}

fn instantiate_requirement(
    requirement: &Requirement,
    mapping: &BTreeMap<TypeFormal, CheckedType>,
) -> Requirement {
    Requirement {
        subject: instantiate_type(&requirement.subject, mapping),
        bound: instantiate_trait(&requirement.bound, mapping),
        origin: requirement.origin.clone(),
    }
}

fn fixed_formals(ty: &CheckedType) -> BTreeSet<TypeFormal> {
    let mut formals = BTreeSet::new();
    let mut pending = vec![ty];
    while let Some(ty) = pending.pop() {
        match ty {
            CheckedType::Formal(formal) => {
                formals.insert(formal.as_ref().clone());
            }
            CheckedType::Tuple(elements) => pending.extend(elements),
            CheckedType::Nominal(nominal) => pending.extend(&nominal.arguments),
            _ => {}
        }
    }
    formals
}

fn overlap_type(ty: &CheckedType, inference: &mut TypeInference) -> CheckedType {
    match ty {
        CheckedType::Projection(_) => inference.fresh(),
        CheckedType::Tuple(elements) => CheckedType::Tuple(
            elements
                .iter()
                .map(|ty| overlap_type(ty, inference))
                .collect(),
        ),
        CheckedType::Nominal(nominal) => CheckedType::Nominal(Box::new(NominalType {
            declaration: nominal.declaration.clone(),
            arguments: nominal
                .arguments
                .iter()
                .map(|ty| overlap_type(ty, inference))
                .collect(),
        })),
        other => other.clone(),
    }
}

fn match_type(
    pattern: &CheckedType,
    actual: &CheckedType,
    formals: &[TypeFormal],
    mapping: &mut BTreeMap<TypeFormal, CheckedType>,
) -> bool {
    let mut pending = vec![(pattern, actual)];
    // Keep other structural bindings when a projection is not yet comparable;
    // the worklist can normalize it with those actuals before deciding failure.
    let mut matched = true;
    while let Some((pattern, actual)) = pending.pop() {
        match (pattern, actual) {
            (CheckedType::Formal(formal), _) if formals.contains(formal) => {
                if let Some(prior) = mapping.get(formal.as_ref()) {
                    if prior != actual {
                        matched = false;
                    }
                } else {
                    mapping.insert(formal.as_ref().clone(), actual.clone());
                }
            }
            (CheckedType::Tuple(left), CheckedType::Tuple(right)) if left.len() == right.len() => {
                pending.extend(left.iter().zip(right))
            }
            (CheckedType::Nominal(left), CheckedType::Nominal(right))
                if left.declaration == right.declaration =>
            {
                pending.extend(left.arguments.iter().zip(&right.arguments))
            }
            _ if pattern == actual => {}
            _ => matched = false,
        }
    }
    matched
}

pub(super) fn collect_method_headers(
    project: &ResolvedProject,
    traits: &mut TraitEnvironment,
    normalizer: &mut SourceTypeNormalizer,
    inference: &mut TypeInference,
    public_exports: &BTreeSet<EntityId>,
    order: &mut Vec<EntityId>,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
) -> Result<(), CheckDiagnostic> {
    for (identity, header) in headers.iter_mut() {
        header.requirements = traits
            .requirements
            .get(identity)
            .cloned()
            .unwrap_or_default();
    }
    let core = core_role_declarations(&project.core_roles);
    let supported_core = [
        &project.core_roles.partial_eq.declaration,
        &project.core_roles.partial_ord.declaration,
        &project.core_roles.ord.declaration,
        &project.core_roles.clone.declaration,
    ];
    for module in project.modules.values() {
        for declaration in module.body.iter().flat_map(|body| &body.declarations) {
            let Some(owner) = declaration_identity(project, declaration) else {
                continue;
            };
            let context = SourceContext::from_origin(&declaration.origin);
            match &declaration.kind {
                ResolvedDeclarationKind::Trait {
                    members,
                    supertraits,
                    ..
                } => {
                    if core.contains(owner) && !supported_core.contains(&owner) {
                        continue;
                    }
                    if public_exports.contains(owner) {
                        for bound in supertraits {
                            validate_public_named_type(bound, public_exports, &normalizer.aliases)?;
                        }
                    }
                    for member in members {
                        if public_exports.contains(owner)
                            && let ResolvedTraitMemberKind::AssociatedType { bounds, default } =
                                &member.kind
                        {
                            for bound in bounds {
                                validate_public_named_type(
                                    bound,
                                    public_exports,
                                    &normalizer.aliases,
                                )?;
                            }
                            if let Some(default) = default {
                                validate_public_type_visibility(
                                    public_exports,
                                    default,
                                    &normalizer.aliases,
                                )?;
                            }
                        }

                        let ResolvedTraitMemberKind::Method(signature) = &member.kind else {
                            continue;
                        };
                        let origin = entity_origin(&member.identity).unwrap();
                        // Reuse signature normalization, then remove the body slot:
                        // this declaration never enters the executable inventory.
                        let function = crate::project::ResolvedFunction {
                            const_span: None,
                            type_parameters: signature.type_parameters.clone(),
                            effect_parameters: signature.effect_parameters.clone(),
                            parameters: signature.parameters.clone(),
                            return_type: signature
                                .return_type
                                .clone()
                                .map(|ty| Box::new(ResolvedReturnAnnotation::Type(ty))),
                            effects: signature.effects.clone(),
                            body: ResolvedBlock {
                                span: origin.span,
                                statements: Vec::new(),
                                tail: None,
                            },
                        };
                        let callable = ResolvedDeclaration {
                            origin: origin.clone(),
                            identity: Some(member.identity.clone()),
                            public: declaration.public,
                            kind: ResolvedDeclarationKind::Function(function.clone()),
                        };
                        let mut header = collect_function_header(
                            &callable,
                            &function,
                            &context,
                            normalizer,
                            inference,
                            public_exports.contains(owner),
                            public_exports,
                        )
                        .map_err(|diagnostics| diagnostics.into_iter().next().unwrap())?;
                        header.body = None;
                        if signature.return_type.is_none() {
                            header.return_type = CheckedType::Unit;
                        }
                        for parameter in &mut header.parameters {
                            if parameter.binding.name == "self" {
                                parameter.source_type_explicit = true;
                            }
                            if parameter.mode.is_none() {
                                parameter.mode = Some(SelectedMode {
                                    value: ParameterMode::Borrow,
                                    origin: CheckOrigin::Source(origin.clone()),
                                });
                            }
                        }
                        header.outer_formals = traits.owner_formals[owner].clone();
                        header.requirements =
                            source_requirements(&signature.type_parameters, normalizer)?;
                        header.outer_requirements = traits.requirements[owner].clone();
                        header.outer_requirements.push(Requirement {
                            subject: CheckedType::Formal(Box::new(
                                traits.traits[owner].self_type.clone(),
                            )),
                            bound: TraitUse {
                                declaration: owner.clone(),
                                arguments: traits.traits[owner]
                                    .formals
                                    .iter()
                                    .cloned()
                                    .map(|formal| CheckedType::Formal(Box::new(formal)))
                                    .collect(),
                                associated: BTreeMap::new(),
                            },
                            origin: CheckOrigin::Source(origin),
                        });
                        headers.insert(member.identity.clone(), header);
                    }
                }
                ResolvedDeclarationKind::InherentImpl(_)
                | ResolvedDeclarationKind::TraitImpl { .. } => {
                    let implementation = match &declaration.kind {
                        ResolvedDeclarationKind::InherentImpl(implementation) => implementation,
                        ResolvedDeclarationKind::TraitImpl { implementation, .. } => implementation,
                        _ => unreachable!(),
                    };
                    let checked_impl = traits
                        .implementations
                        .iter()
                        .find(|implementation| &implementation.identity == owner)
                        .unwrap();
                    let public_trait_impl = checked_impl.trait_use.as_ref().is_some_and(|bound| {
                        public_exports.contains(&bound.declaration)
                            && type_is_public(&checked_impl.target, public_exports)
                    });
                    if public_trait_impl {
                        validate_public_generic_types(
                            &implementation.type_parameters,
                            public_exports,
                            &normalizer.aliases,
                        )?;
                        if let ResolvedDeclarationKind::TraitImpl {
                            trait_type,
                            where_clause,
                            ..
                        } = &declaration.kind
                        {
                            validate_public_named_type(
                                trait_type,
                                public_exports,
                                &normalizer.aliases,
                            )?;
                            for predicate in
                                where_clause.iter().flat_map(|clause| &clause.predicates)
                            {
                                validate_public_type_visibility(
                                    public_exports,
                                    &predicate.subject,
                                    &normalizer.aliases,
                                )?;
                                for bound in &predicate.bounds {
                                    validate_public_named_type(
                                        bound,
                                        public_exports,
                                        &normalizer.aliases,
                                    )?;
                                }
                            }
                        }
                    }
                    for member in &implementation.members {
                        if (public_trait_impl
                            || (checked_impl.trait_use.is_none()
                                && member.public
                                && type_is_public(&checked_impl.target, public_exports)))
                            && let ResolvedImplMemberKind::AssociatedType(value) = &member.kind
                        {
                            validate_public_type_visibility(
                                public_exports,
                                value,
                                &normalizer.aliases,
                            )?;
                        }

                        let ResolvedImplMemberKind::Function(function) = &member.kind else {
                            continue;
                        };
                        let public = match &checked_impl.trait_use {
                            Some(bound) => {
                                public_exports.contains(&bound.declaration)
                                    && type_is_public(&checked_impl.target, public_exports)
                            }
                            None => {
                                member.public
                                    && type_is_public(&checked_impl.target, public_exports)
                            }
                        };
                        let callable = ResolvedDeclaration {
                            origin: entity_origin(&member.identity).unwrap(),
                            identity: Some(member.identity.clone()),
                            public,
                            kind: ResolvedDeclarationKind::Function(function.clone()),
                        };
                        let mut header = collect_function_header(
                            &callable,
                            function,
                            &context,
                            normalizer,
                            inference,
                            public,
                            public_exports,
                        )
                        .map_err(|diagnostics| diagnostics.into_iter().next().unwrap())?;
                        header.outer_formals = checked_impl.formals.clone();
                        header.requirements = traits.requirements[&member.identity].clone();
                        header.outer_requirements = checked_impl.requirements.clone();
                        order.push(member.identity.clone());
                        headers.insert(member.identity.clone(), header);
                    }
                }
                _ => {}
            }
        }
    }
    order.sort_by(|left, right| {
        left.module
            .cmp(&right.module)
            .then_with(|| headers[left].origin.span.cmp(&headers[right].origin.span))
            .then_with(|| left.cmp(right))
    });
    Ok(())
}

pub(super) fn type_is_public(ty: &CheckedType, exports: &BTreeSet<EntityId>) -> bool {
    match ty {
        CheckedType::Nominal(nominal) => exports.contains(&nominal.declaration),
        CheckedType::Int
        | CheckedType::Float
        | CheckedType::Bool
        | CheckedType::Unit
        | CheckedType::Never => true,
        _ => false,
    }
}

pub(super) fn validate_implementations(
    project: &ResolvedProject,
    traits: &mut TraitEnvironment,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    inference: &mut TypeInference,
    obligations: &mut Vec<TypeObligation>,
) -> Result<(), CheckDiagnostic> {
    let mut targets = Vec::new();
    for implementation in &traits.implementations {
        let origin = entity_origin(&implementation.identity).unwrap();
        push_owner_obligation(
            obligations,
            implementation.identity.clone(),
            origin.clone(),
            vec![LocatedInput {
                exposed: false,
                origin: CheckOrigin::Source(origin),
                value: SemanticInput::Type(implementation.target.clone(), TypeUse::Relation),
            }],
        );
        let mut solver = TraitSolver::new(
            traits,
            project,
            inference,
            &implementation.requirements,
            entity_origin(&implementation.identity).unwrap(),
        )?;
        targets.push(solver.normalize(&implementation.target)?);
    }
    for (implementation, target) in traits.implementations.iter_mut().zip(targets) {
        implementation.target = target;
    }
    for implementation in &mut traits.implementations {
        let origin = entity_origin(&implementation.identity).unwrap();
        let library = implementation.identity.module.library();
        let mut fixed = fixed_formals(&implementation.target);
        if let Some(bound) = &implementation.trait_use {
            for ty in &bound.arguments {
                fixed.extend(fixed_formals(ty));
            }
        }
        loop {
            let before = fixed.len();
            for requirement in &implementation.requirements {
                if fixed_formals(&requirement.subject).is_subset(&fixed)
                    && requirement
                        .bound
                        .arguments
                        .iter()
                        .all(|ty| fixed_formals(ty).is_subset(&fixed))
                {
                    for ty in requirement.bound.associated.values() {
                        fixed.extend(fixed_formals(ty));
                    }
                }
            }
            if fixed.len() == before {
                break;
            }
        }
        if implementation
            .formals
            .iter()
            .any(|formal| !fixed.contains(formal))
        {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "impl type formal is unconstrained by its target, trait or associated binding",
                origin,
                Vec::new(),
            ));
        }
        if let Some(bound) = &implementation.trait_use {
            let definition = &traits.traits[&bound.declaration];
            if bound.declaration.module.library() != library {
                let types = std::iter::once(&implementation.target)
                    .chain(&bound.arguments)
                    .collect::<Vec<_>>();
                let first_local = types.iter().position(|ty| matches!(ty, CheckedType::Nominal(nominal) if nominal.declaration.module.library() == library));
                if first_local
                    .is_none_or(|index| types[..index].iter().any(|ty| uncovered_formal(ty)))
                {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "orphan impl: a foreign trait needs a local nominal before any uncovered formal",
                        origin,
                        entity_origin(&bound.declaration).into_iter().collect(),
                    ));
                }
            }
            for (member, (_, default)) in &definition.associated {
                if implementation.associated.contains_key(member) {
                    continue;
                }
                let Some(default) = default else {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        format!("impl is missing associated type `{}`", member.name),
                        origin,
                        entity_origin(member).into_iter().collect(),
                    ));
                };
                implementation.associated.insert(
                    member.clone(),
                    instantiate_type(
                        default,
                        &trait_mapping(definition, &implementation.target, &bound.arguments),
                    ),
                );
            }
            for (name, member) in &definition.methods {
                if !implementation.methods.contains_key(name) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        format!("impl is missing method `{name}`"),
                        origin,
                        entity_origin(member).into_iter().collect(),
                    ));
                }
            }
            if let Some((name, member)) = implementation
                .methods
                .iter()
                .find(|(name, _)| !definition.methods.contains_key(*name))
            {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    format!("impl has extra method `{name}`"),
                    entity_origin(member).unwrap(),
                    vec![origin],
                ));
            }
        } else if !matches!(&implementation.target, CheckedType::Nominal(nominal) if nominal.declaration.module.library() == library)
        {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "inherent impl must belong to its nominal type's original library",
                origin,
                Vec::new(),
            ));
        }
    }
    for left in 0..traits.implementations.len() {
        for right in left + 1..traits.implementations.len() {
            let a = &traits.implementations[left];
            let b = &traits.implementations[right];
            let relevant = match (&a.trait_use, &b.trait_use) {
                (Some(a), Some(b)) => a.declaration == b.declaration,
                (None, None) => {
                    a.methods.keys().any(|name| b.methods.contains_key(name))
                        || a.associated.keys().any(|member| {
                            b.associated.keys().any(|other| other.name == member.name)
                        })
                }
                _ => false,
            };
            if !relevant {
                continue;
            }
            let mut overlap = TypeInference::default();
            let am = a
                .formals
                .iter()
                .cloned()
                .map(|formal| (formal, overlap.fresh()))
                .collect();
            let bm = b
                .formals
                .iter()
                .cloned()
                .map(|formal| (formal, overlap.fresh()))
                .collect();
            let at = overlap_type(&instantiate_type(&a.target, &am), &mut overlap);
            let bt = overlap_type(&instantiate_type(&b.target, &bm), &mut overlap);
            if overlap.unify(&at, &bt).is_err() {
                continue;
            }
            if let (Some(ab), Some(bb)) = (&a.trait_use, &b.trait_use)
                && ab.arguments.iter().zip(&bb.arguments).any(|(at, bt)| {
                    let at = overlap_type(&instantiate_type(at, &am), &mut overlap);
                    let bt = overlap_type(&instantiate_type(bt, &bm), &mut overlap);
                    overlap.unify(&at, &bt).is_err()
                })
            {
                continue;
            }
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "overlapping impl headers: the applicability domains cannot be proved disjoint",
                entity_origin(&b.identity).unwrap(),
                entity_origin(&a.identity).into_iter().collect(),
            ));
        }
    }
    for implementation in &traits.implementations {
        let Some(bound) = &implementation.trait_use else {
            continue;
        };
        let definition = &traits.traits[&bound.declaration];
        let owner_mapping = trait_mapping(definition, &implementation.target, &bound.arguments);
        let mut solver = TraitSolver::new(
            traits,
            project,
            inference,
            &implementation.requirements,
            entity_origin(&implementation.identity).unwrap(),
        )?;
        for requirement in &definition.requirements {
            solver.prove(&instantiate_requirement(requirement, &owner_mapping))?;
        }
        for (member, (bounds, _)) in &definition.associated {
            let ty = solver.normalize(&implementation.associated[member])?;
            for bound in bounds {
                solver.prove(&Requirement {
                    subject: ty.clone(),
                    bound: instantiate_trait(bound, &owner_mapping),
                    origin: CheckOrigin::Source(entity_origin(member).unwrap()),
                })?;
            }
        }
        for (name, member) in &implementation.methods {
            let trait_member = &definition.methods[name];
            let expected = headers.get(trait_member).ok_or_else(|| source_diagnostic(CheckDiagnosticKind::Unsupported,
                "this core method requires a type or resource operation outside the current Checker", entity_origin(member).unwrap(), entity_origin(trait_member).into_iter().collect()))?.clone();
            let actual = &headers[member];
            if expected.declared_formals.len() != actual.declared_formals.len()
                || expected.parameters.len() != actual.parameters.len()
            {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    "impl method generic/parameter arity differs from its trait",
                    actual.origin.clone(),
                    vec![expected.origin.clone()],
                ));
            }
            let mut mapping = owner_mapping.clone();
            mapping.extend(
                expected.declared_formals.iter().cloned().zip(
                    actual
                        .declared_formals
                        .iter()
                        .cloned()
                        .map(|formal| CheckedType::Formal(Box::new(formal))),
                ),
            );
            let contract_requirements = expected
                .requirements
                .iter()
                .map(|requirement| instantiate_requirement(requirement, &mapping))
                .collect::<Vec<_>>();
            let givens = implementation
                .requirements
                .iter()
                .cloned()
                .chain(contract_requirements.iter().cloned())
                .collect::<Vec<_>>();
            let mut solver =
                TraitSolver::new(traits, project, inference, &givens, actual.origin.clone())?;
            for requirement in &actual.requirements {
                solver.prove(requirement)?;
            }
            let types = expected
                .parameters
                .iter()
                .map(|parameter| &parameter.ty)
                .chain(std::iter::once(&expected.return_type))
                .map(|ty| solver.normalize(&instantiate_type(ty, &mapping)))
                .collect::<Result<Vec<_>, _>>()?;
            let actual_types = actual
                .parameters
                .iter()
                .map(|parameter| &parameter.ty)
                .chain(std::iter::once(&actual.return_type))
                .map(|ty| solver.normalize(ty))
                .collect::<Result<Vec<_>, _>>()?;
            drop(solver);
            let actual = headers.get_mut(member).unwrap();
            for (index, (parameter, expected_parameter)) in actual
                .parameters
                .iter_mut()
                .zip(&expected.parameters)
                .enumerate()
            {
                if (parameter.binding.name == "self") != (expected_parameter.binding.name == "self")
                {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "impl receiver position differs from trait",
                        actual.origin.clone(),
                        vec![expected.origin.clone()],
                    ));
                }
                inference
                    .unify(&actual_types[index], &types[index])
                    .map_err(|failure| {
                        source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            display_unification_failure(&failure),
                            actual.origin.clone(),
                            vec![expected.origin.clone()],
                        )
                    })?;
                let expected_mode = expected_parameter.mode.as_ref().unwrap();
                if parameter
                    .mode
                    .as_ref()
                    .is_some_and(|mode| mode.value != expected_mode.value)
                {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "impl parameter mode differs from its trait",
                        actual.origin.clone(),
                        vec![expected.origin.clone()],
                    ));
                }
                parameter.mode = Some(expected_mode.clone());
                parameter.source_type_explicit = true;
                parameter.ty = actual_types[index].clone();
            }
            inference
                .unify(actual_types.last().unwrap(), types.last().unwrap())
                .map_err(|failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        display_unification_failure(&failure),
                        actual.origin.clone(),
                        vec![expected.origin.clone()],
                    )
                })?;
            actual.return_type = actual_types.last().unwrap().clone();
            actual.requirements = contract_requirements;
        }
    }
    Ok(())
}

fn uncovered_formal(ty: &CheckedType) -> bool {
    match ty {
        CheckedType::Formal(_) | CheckedType::Infer(_) | CheckedType::Projection(_) => true,
        CheckedType::Tuple(elements) => elements.iter().any(uncovered_formal),
        _ => false,
    }
}

// A call keeps its input constraints until its actual dependency is known and
// the callee's binding group can close. The body that produced it is not rerun.
pub(super) struct DraftCall {
    pub(super) closed: bool,
    pub(super) caller: EntityId,
    pub(super) target: Option<EntityId>,
    pub(super) selection: Option<MethodSelection>,
    pub(super) owner_mapping: BTreeMap<TypeFormal, CheckedType>,
    pub(super) evidence: Option<Evidence>,
    pub(super) proofs: Vec<Evidence>,
    pub(super) effect_actuals: Vec<(EffectFormal, CheckedEffect)>,
    pub(super) effect_dependencies: Vec<EntityId>,
    pub(super) arguments: Vec<CheckedType>,
    pub(super) result: CheckedType,
    pub(super) origin: OriginRef,
    pub(super) instantiation: Option<CallInstantiation>,
    pub(super) diverges: bool,
}

pub(super) struct MethodSelection {
    pub(super) receiver: CheckedType,
    pub(super) member: ResolvedSelection,
    pub(super) has_receiver: bool,
}

pub(super) fn signature_schemes(
    headers: &BTreeMap<EntityId, FunctionHeader>,
    inference: &TypeInference,
) -> Result<BTreeMap<EntityId, CallableScheme>, CheckDiagnostic> {
    let mut schemes = BTreeMap::new();
    for (identity, header) in headers.iter().filter(|(_, header)| header.body.is_none()) {
        let mut variables = BTreeSet::new();
        for ty in header
            .parameters
            .iter()
            .map(|parameter| &parameter.ty)
            .chain(std::iter::once(&header.return_type))
        {
            inference.unresolved_variables(ty, &mut variables);
        }
        if !variables.is_empty() {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "a bodyless method signature must have closed input and output types",
                header.origin.clone(),
                Vec::new(),
            ));
        }
        let quantified = header
            .outer_formals
            .iter()
            .chain(&header.declared_formals)
            .cloned()
            .collect::<Vec<_>>();
        schemes.insert(
            identity.clone(),
            CallableScheme {
                instantiation_formals: quantified.iter().cloned().collect(),
                quantified,
                parameters: header
                    .parameters
                    .iter()
                    .map(|parameter| inference.resolve(&parameter.ty))
                    .collect(),
                return_type: inference.resolve(&header.return_type),
                effect: header.effect_upper.clone().unwrap_or_default(),
                effect_formals: header
                    .effect_formals
                    .iter()
                    .map(|(_, formal)| formal.clone())
                    .collect(),
                effect_caps: header.effect_caps.clone(),
                shapes: header.shapes.clone(),
                requirements: header
                    .requirements
                    .iter()
                    .chain(&header.outer_requirements)
                    .cloned()
                    .collect(),
            },
        );
    }
    Ok(schemes)
}

pub(super) fn contains_function_value(ty: &CheckedType) -> bool {
    let mut pending = vec![ty];
    while let Some(ty) = pending.pop() {
        match ty {
            CheckedType::Function(_) => return true,
            CheckedType::Tuple(elements) => pending.extend(elements),
            CheckedType::Nominal(nominal) => pending.extend(&nominal.arguments),
            _ => {}
        }
    }
    false
}

pub(super) fn normalize_headers(
    project: &ResolvedProject,
    traits: &TraitEnvironment,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    inference: &TypeInference,
) -> Result<(), CheckDiagnostic> {
    for header in headers.values_mut() {
        normalize_header(project, traits, header, inference)?;
    }
    Ok(())
}

pub(super) fn normalize_header(
    project: &ResolvedProject,
    traits: &TraitEnvironment,
    header: &mut FunctionHeader,
    inference: &TypeInference,
) -> Result<(), CheckDiagnostic> {
    let givens = header
        .requirements
        .iter()
        .chain(&header.outer_requirements)
        .cloned()
        .collect::<Vec<_>>();
    let mut solver = TraitSolver::new(traits, project, inference, &givens, header.origin.clone())?;
    for parameter in &mut header.parameters {
        parameter.ty = solver.normalize(&parameter.ty)?;
    }
    header.return_type = solver.normalize(&header.return_type)?;
    for parameter in &mut header.parameters {
        if let Some(ty) = &mut parameter.callable_operand {
            *ty = solver.normalize(ty)?;
        }
    }
    for requirement in header
        .requirements
        .iter_mut()
        .chain(&mut header.outer_requirements)
    {
        normalize_requirement(requirement, &mut solver)?;
    }
    for row in header
        .effect_upper
        .iter_mut()
        .chain(&mut header.trait_upper)
        .chain(&mut header.module_upper)
        .chain(header.effect_caps.values_mut().flatten())
    {
        *row = row.normalize_types(&mut solver)?;
    }
    for shape in header.shapes.values_mut() {
        shape.normalize_types(&mut solver)?;
    }
    Ok(())
}

type SelectedMethod = (EntityId, BTreeMap<TypeFormal, CheckedType>, Evidence);

fn method_accessible(
    member: &EntityId,
    caller: &EntityId,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    project: &ResolvedProject,
) -> bool {
    headers
        .get(member)
        .is_some_and(|header| header.public_export)
        || member_accessible_in_module(member, &caller.module, project)
}

fn member_accessible_in_module(
    member: &EntityId,
    caller: &ModuleRef,
    project: &ResolvedProject,
) -> bool {
    let entity = &project.entities[member];
    entity.public
        || (member.module.library() == caller.library()
            && caller.path().starts_with(member.module.path()))
        || entity
            .owner
            .as_ref()
            .is_some_and(|owner| actual_public_exports(project).contains(owner))
}

fn select_method(
    call: &DraftCall,
    selection: &MethodSelection,
    project: &ResolvedProject,
    traits: &TraitEnvironment,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    inference: &TypeInference,
) -> Result<Option<SelectedMethod>, CheckDiagnostic> {
    let caller = &headers[&call.caller];
    let givens = caller
        .requirements
        .iter()
        .chain(&caller.outer_requirements)
        .cloned()
        .collect::<Vec<_>>();
    let mut solver = TraitSolver::new(
        traits,
        project,
        inference,
        &givens,
        selection.member.origin.clone(),
    )?;
    let receiver = solver.normalize(&selection.receiver)?;
    if matches!(receiver, CheckedType::Infer(_)) {
        return Ok(None);
    }
    let mut choices = BTreeMap::new();
    let mut inaccessible = Vec::new();
    let mut fixed_dictionary = false;
    {
        for given in solver.bounds_for_type(&receiver)? {
            let definition = &traits.traits[&given.bound.declaration];
            if let Some(member) = definition.methods.get(&selection.member.name) {
                fixed_dictionary = true;
                if !method_accessible(member, &call.caller, headers, project) {
                    inaccessible.push(member.clone());
                    continue;
                }
                let mapping = trait_mapping(definition, &receiver, &given.bound.arguments);
                choices.insert(
                    (member.clone(), mapping, Some(given.bound.clone())),
                    Evidence::Given {
                        subject: receiver.clone(),
                        bound: given.bound.clone(),
                    },
                );
            }
        }
    }
    if !fixed_dictionary {
        for implementation in traits
            .implementations
            .iter()
            .filter(|implementation| implementation.trait_use.is_none())
        {
            let Some(member) = implementation.methods.get(&selection.member.name) else {
                continue;
            };
            if !method_accessible(member, &call.caller, headers, project) {
                inaccessible.push(member.clone());
                continue;
            }
            let mut mapping = BTreeMap::new();
            if match_type(
                &implementation.target,
                &receiver,
                &implementation.formals,
                &mut mapping,
            ) {
                let Some(evidence) = solver.applicable(Candidate::Inherent {
                    implementation: implementation.identity.clone(),
                    mapping: mapping.clone(),
                })?
                else {
                    continue;
                };
                choices.insert((member.clone(), mapping, None), evidence);
            }
        }
        if choices.is_empty() {
            for implementation in &traits.implementations {
                let Some(bound) = &implementation.trait_use else {
                    continue;
                };
                let Some(member) = implementation.methods.get(&selection.member.name) else {
                    continue;
                };
                if !method_accessible(member, &call.caller, headers, project) {
                    inaccessible.push(member.clone());
                    continue;
                }
                let mut mapping = BTreeMap::new();
                if !match_type(
                    &implementation.target,
                    &receiver,
                    &implementation.formals,
                    &mut mapping,
                ) {
                    continue;
                }
                let bound = instantiate_trait(bound, &mapping);
                let Some(evidence) = solver.applicable(Candidate::Trait(TraitGoal {
                    subject: receiver.clone(),
                    bound: bound.clone(),
                }))?
                else {
                    continue;
                };
                if let Evidence::Source {
                    mapping: actuals, ..
                } = &evidence
                {
                    mapping = actuals.clone();
                }
                choices.insert((member.clone(), mapping, Some(bound)), evidence);
            }
            let roles = &project.core_roles;
            for role in [&roles.partial_eq, &roles.partial_ord, &roles.ord] {
                if role.method.name != selection.member.name {
                    continue;
                }
                let bound = TraitUse {
                    declaration: role.declaration.clone(),
                    arguments: Vec::new(),
                    associated: BTreeMap::new(),
                };
                let goal = TraitGoal {
                    subject: receiver.clone(),
                    bound: bound.clone(),
                };
                if solver.primitive_evidence(&goal) {
                    choices.insert(
                        (
                            role.method.clone(),
                            trait_mapping(&traits.traits[&role.declaration], &receiver, &[]),
                            Some(bound),
                        ),
                        Evidence::Primitive {
                            subject: receiver.clone(),
                            declaration: role.declaration.clone(),
                        },
                    );
                }
            }
        }
    }
    if choices.len() != 1 {
        return Err(source_diagnostic(
            CheckDiagnosticKind::TypeMismatch,
            if choices.is_empty() && !inaccessible.is_empty() {
                "selected method is private in this scope"
            } else if choices.is_empty() {
                "method has no applicable evidence"
            } else {
                "ambiguous method selection"
            },
            selection.member.origin.clone(),
            choices
                .keys()
                .map(|(member, _, _)| member)
                .chain(&inaccessible)
                .filter_map(entity_origin)
                .collect(),
        ));
    }
    let ((member, mapping, _), evidence) = choices.into_iter().next().unwrap();
    let header = headers.get(&member).ok_or_else(|| {
        source_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "selected method has an unsupported signature",
            selection.member.origin.clone(),
            entity_origin(&member).into_iter().collect(),
        )
    })?;
    let has_receiver = header
        .parameters
        .first()
        .is_some_and(|parameter| parameter.binding.name == "self");
    if has_receiver != selection.has_receiver {
        return Err(source_diagnostic(
            CheckDiagnosticKind::CallMismatch,
            "receiver method and associated function entry forms do not match",
            selection.member.origin.clone(),
            vec![header.origin.clone()],
        ));
    }
    Ok(Some((member, mapping, evidence)))
}

pub(super) fn constrain_calls(
    calls: &mut [DraftCall],
    members: &BTreeSet<EntityId>,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    schemes: &BTreeMap<EntityId, CallableScheme>,
    inference: &mut TypeInference,
    traits: &TraitEnvironment,
    project: &ResolvedProject,
) -> Result<(), CheckDiagnostic> {
    for call in calls
        .iter_mut()
        .filter(|call| members.contains(&call.caller))
    {
        if call.closed {
            continue;
        }
        let Some(target) = &call.target else {
            continue;
        };
        if !members.contains(target) && !schemes.contains_key(target) {
            continue;
        }
        let header = &headers[target];
        let (parameters, result, instantiation) = if let Some(instantiation) = &call.instantiation {
            let mapping = match instantiation {
                CallInstantiation::Published(mapping) | CallInstantiation::Provisional(mapping) => {
                    mapping.iter().cloned().collect()
                }
                CallInstantiation::RecursiveBinding => BTreeMap::new(),
            };
            (
                header
                    .parameters
                    .iter()
                    .map(|parameter| instantiate_type(&parameter.ty, &mapping))
                    .collect::<Vec<_>>(),
                instantiate_type(&header.return_type, &mapping),
                instantiation.clone(),
            )
        } else if members.contains(target) {
            (
                header
                    .parameters
                    .iter()
                    .map(|parameter| parameter.ty.clone())
                    .collect::<Vec<_>>(),
                header.return_type.clone(),
                CallInstantiation::RecursiveBinding,
            )
        } else {
            let scheme = &schemes[target];
            let mapping = scheme
                .quantified
                .iter()
                .filter(|formal| scheme.instantiation_formals.contains(*formal))
                .cloned()
                .map(|formal| (formal, inference.fresh()))
                .collect::<Vec<_>>();
            let replacements = mapping.iter().cloned().collect();
            (
                scheme
                    .parameters
                    .iter()
                    .map(|ty| instantiate_type(ty, &replacements))
                    .collect(),
                instantiate_type(&scheme.return_type, &replacements),
                CallInstantiation::Published(mapping),
            )
        };
        let replacements = match &instantiation {
            CallInstantiation::Published(mapping) => {
                mapping.iter().cloned().collect::<BTreeMap<_, _>>()
            }
            _ => header
                .outer_formals
                .iter()
                .cloned()
                .map(|formal| (formal.clone(), CheckedType::Formal(Box::new(formal))))
                .collect(),
        };
        for (formal, actual) in &call.owner_mapping {
            if let Some(expected) = replacements.get(formal) {
                inference.unify(expected, actual).map_err(|failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::CallMismatch,
                        display_unification_failure(&failure),
                        call.origin.clone(),
                        vec![header.origin.clone()],
                    )
                })?;
            }
        }
        if call.arguments.len() != parameters.len() {
            return Err(source_diagnostic(
                CheckDiagnosticKind::CallMismatch,
                format!(
                    "call supplies {} argument(s), expected {}",
                    call.arguments.len(),
                    parameters.len()
                ),
                call.origin.clone(),
                vec![header.origin.clone()],
            ));
        }
        let caller = &headers[&call.caller];
        let givens = caller
            .requirements
            .iter()
            .chain(&caller.outer_requirements)
            .cloned()
            .collect::<Vec<_>>();
        for (actual, expected) in call.arguments.iter().zip(&parameters) {
            if matches!(expected, CheckedType::Projection(_)) {
                continue;
            }
            inference.satisfy(actual, expected).map_err(|failure| {
                source_diagnostic(
                    CheckDiagnosticKind::CallMismatch,
                    display_unification_failure(&failure),
                    call.origin.clone(),
                    vec![header.origin.clone()],
                )
            })?;
        }
        for (actual, expected) in call.arguments.iter().zip(&parameters) {
            let mut solver =
                TraitSolver::new(traits, project, inference, &givens, call.origin.clone())?;
            let expected = solver.normalize(expected)?;
            drop(solver);
            inference.satisfy(actual, &expected).map_err(|failure| {
                source_diagnostic(
                    CheckDiagnosticKind::CallMismatch,
                    display_unification_failure(&failure),
                    call.origin.clone(),
                    vec![header.origin.clone()],
                )
            })?;
        }
        call.instantiation = Some(instantiation.clone());
        if !matches!(result, CheckedType::Projection(_)) {
            inference
                .satisfy(&result, &call.result)
                .map_err(|failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::CallMismatch,
                        display_unification_failure(&failure),
                        call.origin.clone(),
                        vec![header.origin.clone()],
                    )
                })?;
        }
        let mut unresolved = BTreeSet::new();
        for requirement in header.requirements.iter().chain(&header.outer_requirements) {
            let subject = inference.resolve(&instantiate_type(&requirement.subject, &replacements));
            if matches!(subject, CheckedType::Function(_))
                && [
                    &project.core_roles.function,
                    &project.core_roles.fn_mut,
                    &project.core_roles.fn_once,
                ]
                .contains(&&requirement.bound.declaration)
            {
                continue;
            }
            for ty in std::iter::once(&requirement.subject)
                .chain(&requirement.bound.arguments)
                .chain(requirement.bound.associated.values())
            {
                inference
                    .unresolved_variables(&instantiate_type(ty, &replacements), &mut unresolved);
            }
        }
        for formal in header.shapes.keys() {
            if let Some(ty) = replacements.get(formal)
                && matches!(inference.resolve(ty), CheckedType::Infer(_))
            {
                inference.unresolved_variables(ty, &mut unresolved);
            }
        }
        if !unresolved.is_empty() {
            continue;
        }
        call.effect_actuals = solve_effect_actuals(
            header,
            caller,
            &replacements,
            BodyEnvironment {
                project,
                headers,
                traits,
            },
            schemes,
            inference,
            &call.origin,
        )?;
        let mut solver =
            TraitSolver::new(traits, project, inference, &givens, call.origin.clone())?;
        let result = solver.normalize(&result)?;
        if contains_function_value(&result) {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "general function value return is outside this Checker",
                call.origin.clone(),
                vec![header.origin.clone()],
            ));
        }
        for requirement in header.requirements.iter().chain(&header.outer_requirements) {
            call.proofs
                .push(solver.prove(&instantiate_requirement(requirement, &replacements))?);
        }
        drop(solver);
        call.diverges = result == CheckedType::Never;
        inference
            .satisfy(&result, &call.result)
            .map_err(|failure| {
                source_diagnostic(
                    CheckDiagnosticKind::CallMismatch,
                    display_unification_failure(&failure),
                    call.origin.clone(),
                    vec![header.origin.clone()],
                )
            })?;
        let row = effect_for_dependency(
            target,
            header,
            schemes.get(target),
            &replacements,
            &call.effect_actuals,
        );
        call.effect_dependencies =
            row.dependencies(traits, project, headers, inference, &givens, &call.origin)?;
        call.instantiation = Some(instantiation);
        call.closed = true;
    }
    Ok(())
}

pub(super) fn next_binding_group(
    order: &[EntityId],
    calls: &mut [DraftCall],
    headers: &BTreeMap<EntityId, FunctionHeader>,
    schemes: &BTreeMap<EntityId, CallableScheme>,
    inference: &mut TypeInference,
    obligations: &mut [TypeObligation],
    environment: TypeEnvironment<'_>,
) -> Result<Vec<EntityId>, CheckDiagnostic> {
    let TypeEnvironment {
        project,
        traits,
        nominals,
    } = environment;
    loop {
        let before = (
            inference.substitutions.len(),
            calls.iter().filter(|call| call.target.is_some()).count(),
            calls.iter().filter(|call| call.closed).count(),
            calls
                .iter()
                .map(|call| call.effect_dependencies.len())
                .sum::<usize>(),
        );
        for obligation in obligations
            .iter_mut()
            .filter(|obligation| order.contains(&obligation.owner))
        {
            let origin = obligation.source_origin();
            let receiver = match &obligation.kind {
                TypeObligationKind::TupleProjection { receiver, .. }
                | TypeObligationKind::FieldProjection { receiver, .. } => {
                    inference.resolve(receiver)
                }
                TypeObligationKind::Formation(_)
                | TypeObligationKind::Numeric(_)
                | TypeObligationKind::Semantic(_) => continue,
            };
            let resolved = match &mut obligation.kind {
                TypeObligationKind::FieldProjection {
                    field,
                    result,
                    selected,
                    ..
                } if selected.is_none() => nominal_field_type(&receiver, field, project, nominals)?
                    .map(|(identity, ty)| {
                        *selected = Some(Box::new(identity));
                        (ty, result)
                    }),
                TypeObligationKind::TupleProjection { index, result, .. }
                    if !matches!(receiver, CheckedType::Infer(_)) =>
                {
                    tuple_field_type(&receiver, *index, &origin, &obligation.related)?
                        .map(|ty| (ty, result))
                }
                _ => None,
            };
            if let Some((ty, result)) = resolved {
                inference.satisfy(&ty, result).map_err(|failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        display_unification_failure(&failure),
                        origin.clone(),
                        obligation.related.clone(),
                    )
                })?;
            }
        }
        for call in calls
            .iter_mut()
            .filter(|call| order.contains(&call.caller) && call.target.is_none())
        {
            let selection = call
                .selection
                .as_ref()
                .expect("a non-direct call retains its selection inputs");
            if let Some((member, mapping, evidence)) =
                select_method(call, selection, project, traits, headers, inference)?
            {
                call.target = Some(member);
                call.owner_mapping = mapping;
                call.evidence = Some(evidence);
            }
        }
        for group in function_binding_groups(order, calls, headers) {
            let members = group.iter().cloned().collect::<BTreeSet<_>>();
            for identity in &group {
                for (value, origin) in &headers[identity].value_uses {
                    if members.contains(&value.declaration) {
                        for (formal, actual) in &value.types {
                            inference.unify(&CheckedType::Formal(Box::new(formal.clone())), actual).map_err(|failure| source_diagnostic(CheckDiagnosticKind::TypeMismatch,
                                format!("recursive function value cannot introduce polymorphic recursion: {}", display_unification_failure(&failure)), origin.clone(), Vec::new()))?;
                        }
                    }
                }
            }
            constrain_calls(
                calls, &members, headers, schemes, inference, traits, project,
            )?;
            let ready = calls
                .iter()
                .filter(|call| members.contains(&call.caller))
                .all(|call| {
                    call.closed
                        && call
                            .effect_dependencies
                            .iter()
                            .all(|target| members.contains(target) || schemes.contains_key(target))
                })
                && group.iter().all(|identity| {
                    headers[identity]
                        .effect_dependencies
                        .iter()
                        .chain(
                            headers[identity]
                                .value_uses
                                .iter()
                                .map(|(value, _)| &value.declaration),
                        )
                        .all(|target| members.contains(target) || schemes.contains_key(target))
                });
            if ready {
                if let Some(identity) = group.iter().find(|identity| {
                    headers[*identity]
                        .effect_dependencies
                        .iter()
                        .any(|target| members.contains(target))
                }) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "explicit effect upper bound refers to its own callable dependency cycle",
                        headers[identity].origin.clone(),
                        Vec::new(),
                    ));
                }
                return Ok(group);
            }
        }
        let after = (
            inference.substitutions.len(),
            calls.iter().filter(|call| call.target.is_some()).count(),
            calls.iter().filter(|call| call.closed).count(),
            calls
                .iter()
                .map(|call| call.effect_dependencies.len())
                .sum::<usize>(),
        );
        if before == after {
            let call = calls
                .iter()
                .find(|call| order.contains(&call.caller) && !call.closed)
                .expect("an unclosed group has a pending call");
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "method selection remains undetermined after the available type constraints; an unknown receiver cannot be selected by method name",
                call.origin.clone(),
                Vec::new(),
            ));
        }
    }
}

impl BodyChecker<'_> {
    pub(super) fn normalize_body_type(
        &mut self,
        ty: &ResolvedType,
    ) -> Result<CheckedType, CheckDiagnostic> {
        let ty = self
            .normalizer
            .normalize_with_formals(ty, &self.function.formal_by_identity)?;
        let givens = self
            .function
            .requirements
            .iter()
            .chain(&self.function.outer_requirements)
            .cloned()
            .collect::<Vec<_>>();
        TraitSolver::new(
            self.environment.traits,
            self.environment.project,
            self.inference,
            &givens,
            self.function.origin.clone(),
        )?
        .normalize(&ty)
    }

    pub(super) fn check_associated_call(
        &mut self,
        origin: OriginRef,
        reference: &ResolvedReference,
        arguments: &[ResolvedCallArgument],
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let ResolvedReference::Selection {
            base,
            members,
            self_reference,
            ..
        } = reference
        else {
            unreachable!()
        };
        let [member] = members.as_slice() else {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "associated function base must be one supported type",
                origin,
                Vec::new(),
            ));
        };
        let receiver = if let Some(self_reference) = self_reference {
            self.normalizer.self_types[&self_reference.identity].clone()
        } else if let Some(definition) = self.normalizer.nominals.get(base) {
            CheckedType::Nominal(Box::new(NominalType {
                declaration: base.clone(),
                arguments: definition
                    .formals
                    .iter()
                    .map(|_| self.inference.fresh())
                    .collect(),
            }))
        } else {
            self.normalize_body_type(&ResolvedType {
                span: origin.span,
                kind: ResolvedTypeKind::Named(Box::new(ResolvedNamedType {
                    span: origin.span,
                    reference: ResolvedReference::Exact {
                        occurrence: origin.clone(),
                        target: base.clone(),
                        self_reference: None,
                    },
                    arguments: Vec::new(),
                })),
            })?
        };
        let selection = MethodSelection {
            receiver,
            member: member.clone(),
            has_receiver: false,
        };
        let mut typed = Vec::new();
        for argument in arguments {
            let ResolvedCallArgument::Expression(argument) = argument else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "call-site mode assertions are outside the current Checker",
                    origin,
                    Vec::new(),
                ));
            };
            typed.push(self.check_expr(argument)?);
        }
        Ok(self.defer_method(origin, selection, typed))
    }

    pub(super) fn check_method_expression(
        &mut self,
        origin: OriginRef,
        receiver: &ResolvedExpr,
        member: &ResolvedSelection,
        arguments: &[ResolvedCallArgument],
    ) -> Result<TypedExpr, CheckDiagnostic> {
        if let Some(operation) =
            self.check_effect_operation(&origin, receiver, member, arguments)?
        {
            return Ok(operation);
        }
        let receiver = self.check_expr(receiver)?;
        let selection = MethodSelection {
            receiver: receiver.ty.clone(),
            member: member.clone(),
            has_receiver: true,
        };
        let mut typed = vec![receiver];
        for argument in arguments {
            let ResolvedCallArgument::Expression(argument) = argument else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "call-site mode assertions are outside the current Checker",
                    origin,
                    Vec::new(),
                ));
            };
            typed.push(self.check_expr(argument)?);
        }
        Ok(self.defer_method(origin, selection, typed))
    }

    fn defer_method(
        &mut self,
        origin: OriginRef,
        selection: MethodSelection,
        arguments: Vec<TypedExpr>,
    ) -> TypedExpr {
        let result = self.inference.fresh();
        let ty = if arguments.iter().any(|argument| self.is_never(&argument.ty)) {
            CheckedType::Never
        } else {
            result.clone()
        };
        let index = self.calls.len();
        self.calls.push(DraftCall {
            closed: false,
            caller: self.function.identity.clone(),
            target: None,
            selection: Some(selection),
            owner_mapping: BTreeMap::new(),
            evidence: None,
            proofs: Vec::new(),
            effect_actuals: Vec::new(),
            effect_dependencies: Vec::new(),
            arguments: arguments
                .iter()
                .map(|argument| argument.ty.clone())
                .collect(),
            result,
            origin: origin.clone(),
            instantiation: None,
            diverges: false,
        });
        TypedExpr {
            span: origin.span,
            ty,
            kind: TypedExprKind::DeferredCall { index, arguments },
        }
    }
}

pub(super) fn close_evidence(evidence: Evidence, closure: &BodyClosure<'_>) -> Evidence {
    match evidence {
        Evidence::Given { subject, bound } => Evidence::Given {
            subject: closure.close_type(&subject),
            bound: TraitUse {
                declaration: bound.declaration,
                arguments: bound
                    .arguments
                    .iter()
                    .map(|ty| closure.close_type(ty))
                    .collect(),
                associated: bound
                    .associated
                    .into_iter()
                    .map(|(member, ty)| (member, closure.close_type(&ty)))
                    .collect(),
            },
        },
        Evidence::Source {
            implementation,
            mapping,
            premises,
        } => Evidence::Source {
            implementation,
            mapping: mapping
                .into_iter()
                .map(|(formal, ty)| (formal, closure.close_type(&ty)))
                .collect(),
            premises: premises
                .into_iter()
                .map(|premise| close_evidence(premise, closure))
                .collect(),
        },
        Evidence::Callable { value, declaration } => Evidence::Callable {
            value: FunctionValue {
                declaration: value.declaration,
                types: value
                    .types
                    .into_iter()
                    .map(|(formal, ty)| (formal, closure.close_type(&ty)))
                    .collect(),
            },
            declaration,
        },
        Evidence::Primitive {
            subject,
            declaration,
        } => Evidence::Primitive {
            subject: closure.close_type(&subject),
            declaration,
        },
    }
}

pub(super) fn close_requirement(
    requirement: Requirement,
    closure: &BodyClosure<'_>,
) -> Requirement {
    Requirement {
        subject: closure.close_type(&requirement.subject),
        bound: TraitUse {
            declaration: requirement.bound.declaration,
            arguments: requirement
                .bound
                .arguments
                .iter()
                .map(|ty| closure.close_type(ty))
                .collect(),
            associated: requirement
                .bound
                .associated
                .into_iter()
                .map(|(member, ty)| (member, closure.close_type(&ty)))
                .collect(),
        },
        origin: requirement.origin,
    }
}

pub(super) fn materialize_calls(block: &mut TypedBlock, calls: &mut [DraftCall]) {
    for statement in &mut block.statements {
        match &mut statement.kind {
            TypedStatementKind::Let { value, .. } | TypedStatementKind::Expression(value) => {
                materialize_call_expr(value, calls)
            }
            TypedStatementKind::Return(value) => {
                if let Some(value) = value {
                    materialize_call_expr(value, calls);
                }
            }
        }
    }
    if let Some(tail) = &mut block.tail {
        materialize_call_expr(tail, calls);
    }
    let stops = block
        .statements
        .iter()
        .any(|statement| match &statement.kind {
            TypedStatementKind::Return(_) => true,
            TypedStatementKind::Let { value, .. } | TypedStatementKind::Expression(value) => {
                value.ty == CheckedType::Never
            }
        });
    if stops
        || block
            .tail
            .as_ref()
            .is_some_and(|tail| tail.ty == CheckedType::Never)
    {
        block.ty = CheckedType::Never;
    }
}

fn materialize_call_expr(expression: &mut TypedExpr, calls: &mut [DraftCall]) {
    match &mut expression.kind {
        TypedExprKind::FunctionValue(_) => {}
        TypedExprKind::IndirectCall(call_details) => {
            let TypedIndirectCall {
                callee, arguments, ..
            } = call_details.as_mut();
            materialize_call_expr(callee, calls);
            for argument in arguments {
                materialize_call_expr(argument, calls);
            }
        }

        TypedExprKind::DeferredCall { index, arguments } => {
            for argument in arguments.iter_mut() {
                materialize_call_expr(argument, calls);
            }
            let call = &mut calls[*index];
            if call.diverges {
                expression.ty = CheckedType::Never;
            }
            expression.kind = TypedExprKind::Call(Box::new(TypedCall {
                callee: Box::new(call.target.clone().expect("method selection closed")),
                evidence: call.evidence.take().map(Box::new),
                effect: CheckedEffect::default(),
                effect_actuals: std::mem::take(&mut call.effect_actuals),
                proofs: std::mem::take(&mut call.proofs),
                arguments: std::mem::take(arguments),
                parameter_modes: Vec::new(),
                instantiation: call
                    .instantiation
                    .take()
                    .expect("the actual call dependency closed before its draft"),
            }));
        }
        TypedExprKind::Comparison {
            invocation: inner, ..
        }
        | TypedExprKind::Raise { payload: inner, .. }
        | TypedExprKind::Parenthesized(inner)
        | TypedExprKind::Unary { operand: inner, .. }
        | TypedExprKind::TupleField {
            receiver: inner, ..
        }
        | TypedExprKind::Field {
            receiver: inner, ..
        } => materialize_call_expr(inner, calls),
        TypedExprKind::Call(call) => {
            for argument in &mut call.arguments {
                materialize_call_expr(argument, calls);
            }
        }
        TypedExprKind::Tuple(elements) => {
            for element in elements {
                materialize_call_expr(element, calls);
            }
        }
        TypedExprKind::Construct(construction) => {
            for field in &mut construction.fields {
                materialize_call_expr(&mut field.value, calls);
            }
        }
        TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
            materialize_calls(block, calls)
        }
        TypedExprKind::If {
            condition,
            then_branch,
            else_branch,
        } => {
            materialize_call_expr(condition, calls);
            materialize_calls(then_branch, calls);
            if let Some(branch) = else_branch {
                materialize_call_expr(branch, calls);
            }
        }
        TypedExprKind::Binary { left, right, .. } => {
            materialize_call_expr(left, calls);
            materialize_call_expr(right, calls);
        }
        TypedExprKind::Integer { .. }
        | TypedExprKind::Float(_)
        | TypedExprKind::Boolean(_)
        | TypedExprKind::Unit
        | TypedExprKind::Reference { .. } => {}
    }
    let diverges = match &expression.kind {
        TypedExprKind::Comparison {
            invocation: inner, ..
        }
        | TypedExprKind::Parenthesized(inner)
        | TypedExprKind::Unary { operand: inner, .. }
        | TypedExprKind::TupleField {
            receiver: inner, ..
        }
        | TypedExprKind::Field {
            receiver: inner, ..
        } => inner.ty == CheckedType::Never,
        TypedExprKind::Call(call) => call
            .arguments
            .iter()
            .any(|argument| argument.ty == CheckedType::Never),
        TypedExprKind::IndirectCall(call) => {
            call.callee.ty == CheckedType::Never
                || call
                    .arguments
                    .iter()
                    .any(|argument| argument.ty == CheckedType::Never)
        }
        TypedExprKind::Tuple(elements) => elements
            .iter()
            .any(|element| element.ty == CheckedType::Never),
        TypedExprKind::Construct(construction) => construction
            .fields
            .iter()
            .any(|field| field.value.ty == CheckedType::Never),
        TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
            block.ty == CheckedType::Never
        }
        TypedExprKind::If {
            condition,
            then_branch,
            else_branch,
        } => {
            condition.ty == CheckedType::Never
                || (then_branch.ty == CheckedType::Never
                    && else_branch
                        .as_ref()
                        .is_some_and(|branch| branch.ty == CheckedType::Never))
        }
        TypedExprKind::Binary {
            left,
            right,
            operator,
            ..
        } => {
            left.ty == CheckedType::Never
                || (!matches!(operator, BinaryOperator::LogicAnd | BinaryOperator::LogicOr)
                    && right.ty == CheckedType::Never)
        }
        TypedExprKind::Raise { .. } => true,
        _ => false,
    };
    if diverges {
        expression.ty = CheckedType::Never;
    }
}
