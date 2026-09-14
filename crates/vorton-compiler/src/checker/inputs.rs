use super::*;

#[derive(Clone)]
pub(super) struct LocatedInput {
    pub(super) exposed: bool,
    pub(super) origin: CheckOrigin,
    pub(super) value: SemanticInput,
}

#[derive(Clone, Copy)]
pub(super) enum TypeUse {
    Value,
    Return,
    Storage,
    Relation,
}

#[derive(Clone, Copy)]
pub(super) enum EffectUse {
    Runtime,
    Template,
}

#[derive(Clone)]
pub(super) enum SemanticInput {
    Type(CheckedType, TypeUse),
    Requirement(Requirement),
    Proof(Requirement),
    Effect(CheckedEffect, EffectUse),
    EffectApplication(EntityId, Vec<CheckedType>),
    Shape(CallableShape),
    Evidence(Evidence),
}

pub(super) enum ObligationState {
    Pending,
    Solved {
        revision: usize,
        evidence: Vec<Evidence>,
    },
    Closed(Vec<Evidence>),
}

impl LocatedInput {
    // This is the structural walk for both semantic checking and publication.
    // In particular, callers visit these operands before normalizing the parent.
    fn children(&self) -> Vec<Self> {
        let mut children = Vec::new();
        let mut push = |value| {
            children.push(Self {
                exposed: self.exposed,
                origin: self.origin.clone(),
                value,
            })
        };
        match &self.value {
            SemanticInput::Type(ty, _) => match ty {
                CheckedType::Tuple(elements) => {
                    for ty in elements {
                        push(SemanticInput::Type(ty.clone(), TypeUse::Storage));
                    }
                }
                CheckedType::Nominal(nominal) => {
                    for ty in &nominal.arguments {
                        push(SemanticInput::Type(ty.clone(), TypeUse::Storage));
                    }
                }
                CheckedType::Projection(projection) => {
                    push(SemanticInput::Type(
                        projection.receiver.clone(),
                        TypeUse::Relation,
                    ));
                    if let Some(bound) = &projection.bound {
                        push(SemanticInput::Requirement(Requirement {
                            subject: projection.receiver.clone(),
                            bound: bound.clone(),
                            origin: self.origin.clone(),
                        }));
                    }
                }
                CheckedType::Function(value) => {
                    for (_, ty) in &value.types {
                        push(SemanticInput::Type(ty.clone(), TypeUse::Relation));
                    }
                }
                CheckedType::Int
                | CheckedType::Float
                | CheckedType::Bool
                | CheckedType::Unit
                | CheckedType::Never
                | CheckedType::Formal(_)
                | CheckedType::Infer(_) => {}
            },
            SemanticInput::Proof(requirement) => {
                push(SemanticInput::Requirement(requirement.clone()))
            }
            SemanticInput::Requirement(requirement) => {
                push(SemanticInput::Type(
                    requirement.subject.clone(),
                    TypeUse::Relation,
                ));
                for ty in requirement
                    .bound
                    .arguments
                    .iter()
                    .chain(requirement.bound.associated.values())
                {
                    push(SemanticInput::Type(ty.clone(), TypeUse::Relation));
                }
            }
            SemanticInput::Effect(row, use_kind) => {
                for term in &row.0 {
                    match term {
                        EffectTerm::Handled(identity, arguments) => push(
                            SemanticInput::EffectApplication(identity.clone(), arguments.clone()),
                        ),
                        EffectTerm::Failure(ty)
                        | EffectTerm::Destruction(ty)
                        | EffectTerm::SelectedCall(ty) => {
                            push(SemanticInput::Type(ty.clone(), TypeUse::Relation))
                        }
                        EffectTerm::Method {
                            method: _,
                            types,
                            effects,
                        } => {
                            for (_, ty) in types {
                                push(SemanticInput::Type(ty.clone(), TypeUse::Relation));
                            }
                            for row in effects {
                                push(SemanticInput::Effect(row.clone(), *use_kind));
                            }
                        }
                        EffectTerm::System(_)
                        | EffectTerm::Mut
                        | EffectTerm::Unsafe
                        | EffectTerm::Formal(_) => {}
                    }
                }
            }
            SemanticInput::EffectApplication(_, arguments) => {
                for ty in arguments {
                    push(SemanticInput::Type(ty.clone(), TypeUse::Relation));
                }
            }
            SemanticInput::Shape(shape) => {
                for (ty, _) in &shape.parameters {
                    push(SemanticInput::Type(ty.clone(), TypeUse::Value));
                }
                push(SemanticInput::Type(shape.result.clone(), TypeUse::Value));
                push(SemanticInput::Effect(
                    shape.effect.clone(),
                    EffectUse::Runtime,
                ));
            }
            SemanticInput::Evidence(proof) => match proof {
                Evidence::Given { subject, bound } => {
                    push(SemanticInput::Requirement(Requirement {
                        subject: subject.clone(),
                        bound: bound.clone(),
                        origin: self.origin.clone(),
                    }))
                }
                Evidence::Source {
                    implementation: _,
                    mapping,
                    premises,
                } => {
                    for ty in mapping.values() {
                        push(SemanticInput::Type(ty.clone(), TypeUse::Relation));
                    }
                    for proof in premises {
                        push(SemanticInput::Evidence(proof.clone()));
                    }
                }
                Evidence::Primitive { subject, .. } => {
                    push(SemanticInput::Type(subject.clone(), TypeUse::Relation))
                }
                Evidence::Callable { value, .. } => push(SemanticInput::Type(
                    CheckedType::Function(Box::new(value.clone())),
                    TypeUse::Relation,
                )),
            },
        }
        children
    }
}

impl TypeObligation {
    pub(super) fn source_origin(&self) -> OriginRef {
        match &self.primary {
            CheckOrigin::Source(origin) => origin.clone(),
            CheckOrigin::Contract { .. } => entity_origin(&self.owner)
                .expect("each checked source owner has a real declaration site"),
        }
    }

    pub(super) fn solved_evidence(&self, revision: usize) -> Result<&[Evidence], CheckDiagnostic> {
        match &self.evidence {
            ObligationState::Solved { revision: solved, evidence } if *solved == revision => Ok(evidence),
            ObligationState::Closed(evidence) => Ok(evidence),
            ObligationState::Pending | ObligationState::Solved { .. } => Err(CheckDiagnostic {
                kind: CheckDiagnosticKind::Unsupported,
                message: "incomplete solve: an owner obligation has not closed at the final type constraints".to_owned(),
                primary: Some(self.primary.clone()),
                related: Vec::new(),
            }),
        }
    }
}

pub(super) fn owner_givens(
    owner: &EntityId,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    traits: &TraitEnvironment,
    project: &ResolvedProject,
) -> Result<Vec<Requirement>, CheckDiagnostic> {
    if let Some(header) = headers.get(owner) {
        return Ok(header
            .requirements
            .iter()
            .chain(&header.outer_requirements)
            .cloned()
            .collect());
    }
    let mut givens = if let Some(givens) = traits.requirements.get(owner) {
        givens.clone()
    } else if project.entities.contains_key(owner)
        && matches!(owner.kind, EntityKind::TypeAlias | EntityKind::Module)
    {
        Vec::new()
    } else {
        return Err(CheckDiagnostic {
            kind: CheckDiagnosticKind::Unsupported,
            message: "incomplete solve: source owner has no supported input environment".to_owned(),
            primary: entity_origin(owner).map(CheckOrigin::Source),
            related: Vec::new(),
        });
    };
    if let Some(definition) = traits.traits.get(owner) {
        givens.push(Requirement {
            subject: CheckedType::Formal(Box::new(definition.self_type.clone())),
            bound: TraitUse {
                declaration: owner.clone(),
                arguments: definition
                    .formals
                    .iter()
                    .cloned()
                    .map(|formal| CheckedType::Formal(Box::new(formal)))
                    .collect(),
                associated: BTreeMap::new(),
            },
            origin: CheckOrigin::Source(entity_origin(owner).unwrap()),
        });
    }
    Ok(givens)
}

pub(super) fn check_semantic_inputs(
    owner: &EntityId,
    inputs: &[LocatedInput],
    environment: TypeEnvironment<'_>,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    inference: &TypeInference,
) -> Result<Vec<Evidence>, CheckDiagnostic> {
    let TypeEnvironment {
        project,
        traits,
        nominals,
    } = environment;
    let givens = owner_givens(owner, headers, traits, project)?;
    let source = inputs
        .iter()
        .find_map(|input| match &input.origin {
            CheckOrigin::Source(origin) => Some(origin.clone()),
            CheckOrigin::Contract { .. } => None,
        })
        .or_else(|| entity_origin(owner))
        .expect("semantic inputs retain their real owner or module body origin");
    let mut solver = TraitSolver::new(traits, project, inference, &givens, source.clone())?;
    let mut pending = inputs.iter().rev().cloned().collect::<Vec<_>>();
    let mut evidence = Vec::new();
    while let Some(input) = pending.pop() {
        let origin = &input.origin;
        solver.set_public_surface(input.exposed);
        // Visit original operands even if normalization erases their parent.
        pending.extend(input.children());
        let checked = (|| -> Result<(), CheckDiagnostic> {
            match &input.value {
                SemanticInput::Type(original, use_kind) => {
                    let normalized = solver.normalize(original)?;
                    if &normalized != original {
                        pending.extend(
                            LocatedInput {
                                exposed: input.exposed,
                                origin: origin.clone(),
                                value: SemanticInput::Type(normalized.clone(), *use_kind),
                            }
                            .children(),
                        );
                    }
                    match normalized {
                        CheckedType::Nominal(nominal) => {
                            let mapping = nominal.replacements(nominals);
                            for requirement in traits
                                .requirements
                                .get(&nominal.declaration)
                                .into_iter()
                                .flatten()
                            {
                                evidence.push(solver.prove(&Requirement {
                                    subject: instantiate_type(&requirement.subject, &mapping),
                                    bound: instantiate_trait(&requirement.bound, &mapping),
                                    origin: origin.clone(),
                                })?);
                            }
                        }
                        CheckedType::Projection(projection) => {
                            let bound = projection.bound.ok_or_else(|| {
                                incomplete_input(origin, "projection has no exact bound")
                            })?;
                            evidence.push(solver.prove(&Requirement {
                                subject: projection.receiver,
                                bound,
                                origin: origin.clone(),
                            })?);
                        }
                        CheckedType::Function(value) => {
                            if matches!(use_kind, TypeUse::Storage | TypeUse::Return) {
                                return Err(CheckDiagnostic { kind: CheckDiagnosticKind::Unsupported, message: "general function value return or aggregate storage is outside this Checker".to_owned(), primary: Some(origin.clone()), related: Vec::new() });
                            }
                            let provider = headers.get(&value.declaration).ok_or_else(|| {
                                incomplete_input(origin, "function value has no supported provider")
                            })?;
                            let mapping = value.types.iter().cloned().collect();
                            for requirement in provider
                                .requirements
                                .iter()
                                .chain(&provider.outer_requirements)
                            {
                                pending.push(LocatedInput {
                                    exposed: false,
                                    origin: origin.clone(),
                                    value: SemanticInput::Proof(Requirement {
                                        subject: instantiate_type(&requirement.subject, &mapping),
                                        bound: instantiate_trait(&requirement.bound, &mapping),
                                        origin: origin.clone(),
                                    }),
                                });
                            }
                        }
                        CheckedType::Tuple(_)
                        | CheckedType::Int
                        | CheckedType::Float
                        | CheckedType::Bool
                        | CheckedType::Unit
                        | CheckedType::Never
                        | CheckedType::Formal(_)
                        | CheckedType::Infer(_) => {}
                    }
                }
                SemanticInput::Proof(requirement) => evidence.push(solver.prove(requirement)?),
                SemanticInput::Requirement(requirement) => {
                    let definition = &traits.traits[&requirement.bound.declaration];
                    let mapping = std::iter::once((
                        definition.self_type.clone(),
                        requirement.subject.clone(),
                    ))
                    .chain(
                        definition
                            .formals
                            .iter()
                            .cloned()
                            .zip(requirement.bound.arguments.iter().cloned()),
                    )
                    .collect();
                    for condition in &definition.requirements {
                        // Supertrait dictionaries are given with Self; generic type
                        // formation conditions still need a proof in this owner.
                        if !matches!(&condition.subject, CheckedType::Formal(formal) if formal.as_ref() == &definition.self_type)
                        {
                            evidence.push(solver.prove(&Requirement {
                                subject: instantiate_type(&condition.subject, &mapping),
                                bound: instantiate_trait(&condition.bound, &mapping),
                                origin: origin.clone(),
                            })?);
                        }
                    }
                }
                SemanticInput::Effect(row, use_kind) => {
                    for term in &row.0 {
                        match term {
                            EffectTerm::Handled(_, arguments) => {
                                let arguments = arguments
                                    .iter()
                                    .map(|ty| solver.normalize(ty))
                                    .collect::<Result<Vec<_>, _>>()?;
                                if matches!(use_kind, EffectUse::Runtime)
                                    && arguments.iter().any(|ty| !closed_identity_type(ty))
                                {
                                    return Err(CheckDiagnostic { kind: CheckDiagnosticKind::TypeMismatch, message: "handled effect runtime identity requires closed concrete type actuals".to_owned(), primary: Some(origin.clone()), related: Vec::new() });
                                }
                            }
                            EffectTerm::SelectedCall(ty) => {
                                let header = headers.get(owner).ok_or_else(|| {
                                    incomplete_input(
                                        origin,
                                        "selected_call has no supported callable owner",
                                    )
                                })?;
                                let (_, proof) = require_shared_callable(
                                    ty,
                                    header,
                                    BodyEnvironment {
                                        project,
                                        headers,
                                        traits,
                                    },
                                    inference,
                                    &givens,
                                    &source,
                                )?;
                                evidence.push(proof);
                            }
                            EffectTerm::Method {
                                method,
                                types,
                                effects,
                            } => {
                                let header = &headers[method];
                                if effects.len() != header.effect_formals.len() {
                                    return Err(incomplete_input(
                                        origin,
                                        "method Effect actuals do not match the selected owner",
                                    ));
                                }
                                let mapping = types.iter().cloned().collect();
                                for requirement in
                                    header.requirements.iter().chain(&header.outer_requirements)
                                {
                                    evidence.push(solver.prove(&Requirement {
                                        subject: instantiate_type(&requirement.subject, &mapping),
                                        bound: instantiate_trait(&requirement.bound, &mapping),
                                        origin: origin.clone(),
                                    })?);
                                }
                            }
                            EffectTerm::Failure(_)
                            | EffectTerm::Destruction(_)
                            | EffectTerm::System(_)
                            | EffectTerm::Mut
                            | EffectTerm::Unsafe
                            | EffectTerm::Formal(_) => {}
                        }
                    }
                }
                SemanticInput::EffectApplication(identity, arguments) => {
                    let mapping = traits.owner_formals[identity]
                        .iter()
                        .cloned()
                        .zip(arguments.iter().cloned())
                        .collect();
                    for requirement in &traits.requirements[identity] {
                        evidence.push(solver.prove(&Requirement {
                            subject: instantiate_type(&requirement.subject, &mapping),
                            bound: instantiate_trait(&requirement.bound, &mapping),
                            origin: origin.clone(),
                        })?);
                    }
                }
                SemanticInput::Shape(_) | SemanticInput::Evidence(_) => {}
            }
            Ok(())
        })();
        checked.map_err(|mut diagnostic| {
            if let Some(previous) = diagnostic.primary.take()
                && &previous != origin
                && !diagnostic.related.contains(&previous)
            {
                diagnostic.related.push(previous);
            }
            diagnostic.primary = Some(origin.clone());
            diagnostic
        })?;
    }
    Ok(evidence)
}

fn incomplete_input(origin: &CheckOrigin, message: &str) -> CheckDiagnostic {
    CheckDiagnostic {
        kind: CheckDiagnosticKind::Unsupported,
        message: format!("incomplete solve: {message}"),
        primary: Some(origin.clone()),
        related: Vec::new(),
    }
}

pub(super) fn require_closed_inputs(
    inputs: Vec<LocatedInput>,
    formals: &BTreeSet<TypeFormal>,
    effects: &BTreeSet<EffectFormal>,
) -> Result<(), CheckDiagnostic> {
    let mut pending = inputs;
    while let Some(input) = pending.pop() {
        match &input.value {
            SemanticInput::Type(ty, _) => match ty {
                CheckedType::Infer(_) => {
                    return Err(incomplete_input(
                        &input.origin,
                        "published type still contains an inference variable",
                    ));
                }
                CheckedType::Formal(formal) if !formals.contains(formal.as_ref()) => {
                    return Err(incomplete_input(
                        &input.origin,
                        "published type uses a foreign callable formal",
                    ));
                }
                CheckedType::Projection(projection)
                    if projection.member.is_none() || projection.bound.is_none() =>
                {
                    return Err(incomplete_input(
                        &input.origin,
                        "published projection has no exact member and bound",
                    ));
                }
                _ => {}
            },
            SemanticInput::Effect(row, _)
                if row.0.iter().any(
                    |term| matches!(term, EffectTerm::Formal(formal) if !effects.contains(formal)),
                ) =>
            {
                return Err(incomplete_input(
                    &input.origin,
                    "published row uses a foreign Effect formal",
                ));
            }
            _ => {}
        }
        pending.extend(input.children());
    }
    Ok(())
}

pub(super) fn scheme_inputs(scheme: &CallableScheme, origin: &OriginRef) -> Vec<LocatedInput> {
    let CallableScheme {
        quantified: _,
        instantiation_formals: _,
        parameters,
        return_type,
        effect,
        effect_formals: _,
        effect_caps,
        shapes,
        requirements,
    } = scheme;
    let origin = CheckOrigin::Source(origin.clone());
    let mut inputs = parameters
        .iter()
        .cloned()
        .map(|ty| LocatedInput {
            exposed: false,
            origin: origin.clone(),
            value: SemanticInput::Type(ty, TypeUse::Value),
        })
        .collect::<Vec<_>>();
    inputs.push(LocatedInput {
        exposed: false,
        origin: origin.clone(),
        value: SemanticInput::Type(return_type.clone(), TypeUse::Return),
    });
    inputs.push(LocatedInput {
        exposed: false,
        origin: origin.clone(),
        value: SemanticInput::Effect(effect.clone(), EffectUse::Runtime),
    });
    inputs.extend(
        effect_caps
            .values()
            .flatten()
            .cloned()
            .map(|row| LocatedInput {
                exposed: false,
                origin: origin.clone(),
                value: SemanticInput::Effect(row, EffectUse::Runtime),
            }),
    );
    inputs.extend(shapes.values().cloned().map(|shape| LocatedInput {
        exposed: false,
        origin: origin.clone(),
        value: SemanticInput::Shape(shape),
    }));
    inputs.extend(
        requirements
            .iter()
            .cloned()
            .map(|requirement| LocatedInput {
                exposed: false,
                origin: requirement.origin.clone(),
                value: SemanticInput::Requirement(requirement),
            }),
    );
    inputs
}

pub(super) fn require_closed_scheme(
    scheme: &CallableScheme,
    origin: &OriginRef,
) -> Result<(), CheckDiagnostic> {
    let formals = scheme.quantified.iter().cloned().collect::<BTreeSet<_>>();
    if !scheme.instantiation_formals.is_subset(&formals)
        || scheme.shapes.keys().any(|formal| !formals.contains(formal))
    {
        return Err(incomplete_input(
            &CheckOrigin::Source(origin.clone()),
            "callable binders do not own their signature inputs",
        ));
    }
    require_closed_inputs(
        scheme_inputs(scheme, origin),
        &formals,
        &scheme.effect_formals.iter().cloned().collect(),
    )
}

pub(super) fn normalize_requirement(
    requirement: &mut Requirement,
    solver: &mut TraitSolver<'_>,
) -> Result<(), CheckDiagnostic> {
    requirement.subject = solver.normalize(&requirement.subject)?;
    for ty in requirement
        .bound
        .arguments
        .iter_mut()
        .chain(requirement.bound.associated.values_mut())
    {
        *ty = solver.normalize(ty)?;
    }
    Ok(())
}

pub(super) fn header_inputs(header: &FunctionHeader) -> Vec<LocatedInput> {
    let FunctionHeader {
        identity,
        context,
        origin,
        parameters,
        return_type,
        return_origin,
        requirements,
        outer_requirements,
        module_upper,
        effect_upper,
        trait_upper,
        shapes,
        effect_caps,
        value_uses,
        effect_origin,
        semantic_inputs,
        public_export: _,
        declared_formals: _,
        outer_formals: _,
        formal_by_identity: _,
        source_return_explicit: _,
        body: _,
        source_effects: _,
        effect_formals: _,
        effect_dependencies: _,
        source_shapes: _,
        flexible_effects: _,
        contract_shapes: _,
        source_requirements_explicit: _,
    } = header;
    let mut inputs = semantic_inputs.clone();
    for parameter in parameters {
        let HeaderParameter {
            ty,
            type_origin,
            callable_operand,
            binding: _,
            span: _,
            source_type_explicit: _,
            callable_use: _,
            mode: _,
        } = parameter;
        inputs.push(LocatedInput {
            exposed: false,
            origin: type_origin.clone(),
            value: SemanticInput::Type(ty.clone(), TypeUse::Value),
        });
        if let Some(ty) = callable_operand {
            inputs.push(LocatedInput {
                exposed: false,
                origin: type_origin.clone(),
                value: SemanticInput::Type(ty.clone(), TypeUse::Relation),
            });
        }
    }
    inputs.push(LocatedInput {
        exposed: false,
        origin: return_origin.clone(),
        value: SemanticInput::Type(return_type.clone(), TypeUse::Return),
    });
    inputs.extend(
        requirements
            .iter()
            .chain(outer_requirements)
            .cloned()
            .map(|requirement| LocatedInput {
                exposed: false,
                origin: requirement.origin.clone(),
                value: SemanticInput::Requirement(requirement),
            }),
    );
    let upper_origin = effect_origin
        .clone()
        .unwrap_or_else(|| CheckOrigin::Source(origin.clone()));
    if let Some(row) = effect_upper {
        inputs.push(LocatedInput {
            exposed: false,
            origin: upper_origin.clone(),
            value: SemanticInput::Effect(
                row.clone(),
                if identity.kind == EntityKind::EffectOperation {
                    EffectUse::Template
                } else {
                    EffectUse::Runtime
                },
            ),
        });
    }
    for row in trait_upper.iter().chain(module_upper) {
        inputs.push(LocatedInput {
            exposed: false,
            origin: CheckOrigin::Source(origin.clone()),
            value: SemanticInput::Effect(row.clone(), EffectUse::Runtime),
        });
    }
    for (formal, shape) in shapes {
        let source = header
            .source_shapes
            .iter()
            .find(|(candidate, _)| candidate == formal)
            .map(|(_, shape)| CheckOrigin::Source(context.origin(shape.span)));
        let selected = header
            .contract_shapes
            .iter()
            .flatten()
            .find(|shape| &shape.subject == formal)
            .map(|shape| shape.origin.clone());
        inputs.push(LocatedInput {
            exposed: false,
            origin: selected
                .or(source)
                .unwrap_or_else(|| CheckOrigin::Source(origin.clone())),
            value: SemanticInput::Shape(shape.clone()),
        });
    }
    for row in effect_caps.values().flatten() {
        inputs.push(LocatedInput {
            exposed: false,
            origin: upper_origin.clone(),
            value: SemanticInput::Effect(row.clone(), EffectUse::Runtime),
        });
    }
    if header.public_export {
        for input in &mut inputs {
            input.exposed = true;
        }
    }
    for (value, origin) in value_uses {
        inputs.push(LocatedInput {
            exposed: false,
            origin: CheckOrigin::Source(origin.clone()),
            value: SemanticInput::Type(
                CheckedType::Function(Box::new(value.clone())),
                TypeUse::Relation,
            ),
        });
    }
    inputs
}

pub(super) struct ClosedDeclarations {
    pub(super) signatures: BTreeMap<EntityId, CallableScheme>,
}

pub(super) struct DeclarationClosure<'a> {
    pub(super) project: &'a ResolvedProject,
    pub(super) traits: &'a TraitEnvironment,
    pub(super) normalizer: &'a mut SourceTypeNormalizer,
    pub(super) headers: &'a mut BTreeMap<EntityId, FunctionHeader>,
    pub(super) inference: &'a mut TypeInference,
    pub(super) selections: &'a ContractSelections,
    pub(super) exports: &'a BTreeSet<EntityId>,
    pub(super) obligations: &'a mut Vec<TypeObligation>,
}

impl DeclarationClosure<'_> {
    pub(super) fn close(self) -> Result<ClosedDeclarations, CheckDiagnostic> {
        let Self {
            project,
            traits,
            normalizer,
            headers,
            inference,
            selections,
            exports,
            obligations,
        } = self;
        let core = core_role_declarations(&project.core_roles);
        let mut owners = BTreeSet::new();
        for (module_id, module) in &project.modules {
            let Some(body) = &module.body else {
                continue;
            };
            if let Some(row) = &body.requires {
                let owner = project
                    .entities
                    .keys()
                    .find(|identity| {
                        identity.kind == EntityKind::Module && &identity.module == module_id
                    })
                    .expect("resolved modules retain their exact entity")
                    .clone();
                let origin = body.origin.clone();
                let mut inputs = Vec::new();
                let row = source_effect_row(
                    row,
                    SourceEffectScope {
                        origin: &origin,
                        effect_formals: &[],
                        use_kind: EffectUse::Runtime,
                    },
                    normalizer,
                    project,
                    headers,
                    &mut inputs,
                )?;
                inputs.push(LocatedInput {
                    exposed: false,
                    origin: CheckOrigin::Source(origin.clone()),
                    value: SemanticInput::Effect(row, EffectUse::Runtime),
                });
                push_owner_obligation(obligations, owner.clone(), origin, inputs);
                owners.insert(owner);
            }
            for declaration in &body.declarations {
                let owner = declaration_identity(project, declaration)
                    .cloned()
                    .ok_or_else(|| {
                        source_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "incomplete solve: declaration has no exact supported owner",
                            declaration.origin.clone(),
                            Vec::new(),
                        )
                    })?;
                let origin = declaration.origin.clone();
                let mut inputs = Vec::new();
                match &declaration.kind {
                    ResolvedDeclarationKind::Struct { .. }
                    | ResolvedDeclarationKind::Enum { .. } => {
                        let definition = &normalizer.nominals[&owner];
                        inputs.push(LocatedInput {
                            exposed: false,
                            origin: CheckOrigin::Source(origin.clone()),
                            value: SemanticInput::Type(
                                CheckedType::Nominal(Box::new(NominalType {
                                    declaration: owner.clone(),
                                    arguments: definition
                                        .formals
                                        .iter()
                                        .cloned()
                                        .map(|formal| CheckedType::Formal(Box::new(formal)))
                                        .collect(),
                                })),
                                TypeUse::Relation,
                            ),
                        });
                        for constructor in definition.constructors.values() {
                            for field in &constructor.fields {
                                inputs.push(LocatedInput {
                                    exposed: exports.contains(&owner)
                                        && (owner.kind == EntityKind::Enum
                                            || project.entities[&field.identity].public),
                                    origin: CheckOrigin::Source(field.origin.clone()),
                                    value: SemanticInput::Type(field.ty.clone(), TypeUse::Storage),
                                });
                            }
                        }
                    }
                    ResolvedDeclarationKind::TypeAlias { .. } => inputs.push(LocatedInput {
                        exposed: exports.contains(&owner),
                        origin: CheckOrigin::Source(origin.clone()),
                        value: SemanticInput::Type(
                            normalizer.normalized_aliases[&owner].clone(),
                            TypeUse::Relation,
                        ),
                    }),
                    ResolvedDeclarationKind::Trait { .. } => {
                        // Core protocol profiles stay Resolver-owned; their supported
                        // method signatures are checked individually below.
                        if core.contains(&owner) {
                            continue;
                        }
                        let definition = &traits.traits[&owner];
                        let self_type = CheckedType::Formal(Box::new(definition.self_type.clone()));
                        for (member, (bounds, default)) in &definition.associated {
                            let member_origin = CheckOrigin::Source(entity_origin(member).unwrap());
                            let subject = default.clone().unwrap_or_else(|| {
                                CheckedType::Projection(Box::new(ProjectionType {
                                    receiver: self_type.clone(),
                                    member: Some(member.clone()),
                                    name: member.name.clone(),
                                    bound: Some(TraitUse {
                                        declaration: owner.clone(),
                                        arguments: definition
                                            .formals
                                            .iter()
                                            .cloned()
                                            .map(|formal| CheckedType::Formal(Box::new(formal)))
                                            .collect(),
                                        associated: BTreeMap::new(),
                                    }),
                                }))
                            });
                            inputs.push(LocatedInput {
                                exposed: exports.contains(&owner),
                                origin: member_origin.clone(),
                                value: SemanticInput::Type(subject.clone(), TypeUse::Relation),
                            });
                            for bound in bounds {
                                let requirement = Requirement {
                                    subject: subject.clone(),
                                    bound: bound.clone(),
                                    origin: member_origin.clone(),
                                };
                                inputs.push(LocatedInput {
                                    exposed: exports.contains(&owner),
                                    origin: member_origin.clone(),
                                    value: if default.is_some() {
                                        SemanticInput::Proof(requirement)
                                    } else {
                                        SemanticInput::Requirement(requirement)
                                    },
                                });
                            }
                        }
                    }
                    ResolvedDeclarationKind::InherentImpl(_)
                    | ResolvedDeclarationKind::TraitImpl { .. } => {
                        let implementation = traits
                            .implementations
                            .iter()
                            .find(|implementation| implementation.identity == owner)
                            .unwrap();
                        inputs.push(LocatedInput {
                            exposed: false,
                            origin: CheckOrigin::Source(origin.clone()),
                            value: SemanticInput::Type(
                                implementation.target.clone(),
                                TypeUse::Relation,
                            ),
                        });
                        if let Some(bound) = &implementation.trait_use {
                            inputs.push(LocatedInput {
                                exposed: false,
                                origin: CheckOrigin::Source(origin.clone()),
                                value: SemanticInput::Requirement(Requirement {
                                    subject: implementation.target.clone(),
                                    bound: bound.clone(),
                                    origin: CheckOrigin::Source(origin.clone()),
                                }),
                            });
                        }
                        for (member, ty) in &implementation.associated {
                            inputs.push(LocatedInput {
                                exposed: match &implementation.trait_use {
                                    Some(bound) => {
                                        exports.contains(&bound.declaration)
                                            && type_is_public(&implementation.target, exports)
                                    }
                                    None => {
                                        project.entities[member].public
                                            && type_is_public(&implementation.target, exports)
                                    }
                                },
                                origin: CheckOrigin::Source(entity_origin(member).unwrap()),
                                value: SemanticInput::Type(ty.clone(), TypeUse::Relation),
                            });
                        }
                    }
                    ResolvedDeclarationKind::Effect { .. } => {}
                    ResolvedDeclarationKind::EffectAlias { effects, .. } => {
                        let row = source_effect_row(
                            effects,
                            SourceEffectScope {
                                origin: &origin,
                                effect_formals: &[],
                                use_kind: EffectUse::Template,
                            },
                            normalizer,
                            project,
                            headers,
                            &mut inputs,
                        )?;
                        inputs.push(LocatedInput {
                            exposed: exports.contains(&owner),
                            origin: CheckOrigin::Source(origin.clone()),
                            value: SemanticInput::Effect(row, EffectUse::Template),
                        });
                    }
                    ResolvedDeclarationKind::Function(_) | ResolvedDeclarationKind::Module(_) => {
                        continue;
                    }
                    ResolvedDeclarationKind::ExternFunction(_)
                    | ResolvedDeclarationKind::ExternType { .. }
                    | ResolvedDeclarationKind::Const { .. } => {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "declaration family is outside the current Checker",
                            origin,
                            Vec::new(),
                        ));
                    }
                }
                inputs.extend(
                    traits
                        .requirements
                        .get(&owner)
                        .into_iter()
                        .flatten()
                        .cloned()
                        .map(|requirement| LocatedInput {
                            exposed: exports.contains(&owner),
                            origin: requirement.origin.clone(),
                            value: SemanticInput::Requirement(requirement),
                        }),
                );
                push_owner_obligation(obligations, owner.clone(), origin, inputs);
                owners.insert(owner);
            }
        }
        for (identity, header) in headers.iter_mut() {
            let inputs = header_inputs(header);
            header.semantic_inputs = inputs.clone();
            push_owner_obligation(obligations, identity.clone(), header.origin.clone(), inputs);
            if header.body.is_none() {
                owners.insert(identity.clone());
            }
        }
        let signatures = headers
            .iter()
            .filter_map(|(identity, header)| header.body.is_none().then_some(identity.clone()))
            .collect::<Vec<_>>();
        apply_contract_type_constraints(&signatures, headers, selections, inference)?;
        validate_type_obligations(
            obligations,
            inference,
            project,
            &normalizer.nominals,
            &owners,
            traits,
            headers,
        )?;
        normalize_headers(project, traits, headers, inference)?;
        for obligation in obligations
            .iter_mut()
            .filter(|obligation| owners.contains(&obligation.owner))
        {
            let evidence = obligation.solved_evidence(inference.revision)?.to_vec();
            let mut formals = if let Some(header) = headers.get(&obligation.owner) {
                header
                    .declared_formals
                    .iter()
                    .chain(&header.outer_formals)
                    .cloned()
                    .collect::<BTreeSet<_>>()
            } else {
                traits
                    .owner_formals
                    .get(&obligation.owner)
                    .into_iter()
                    .flatten()
                    .cloned()
                    .collect()
            };
            if let Some(definition) = traits.traits.get(&obligation.owner) {
                formals.insert(definition.self_type.clone());
            }
            let effects = headers
                .get(&obligation.owner)
                .into_iter()
                .flat_map(|header| &header.effect_formals)
                .map(|(_, formal)| formal.clone())
                .collect();
            require_closed_inputs(
                evidence
                    .iter()
                    .cloned()
                    .map(|proof| LocatedInput {
                        exposed: false,
                        origin: obligation.primary.clone(),
                        value: SemanticInput::Evidence(proof),
                    })
                    .collect(),
                &formals,
                &effects,
            )?;
            obligation.evidence = ObligationState::Closed(evidence);
        }
        // Fields are normalized under their declaration's fixed environment;
        // the pre-body destruction summary has an existing contract consumer.
        for (identity, definition) in &mut normalizer.nominals {
            let givens = owner_givens(identity, headers, traits, project)?;
            let mut solver = TraitSolver::new(
                traits,
                project,
                inference,
                &givens,
                entity_origin(identity).unwrap(),
            )?;
            for constructor in definition.constructors.values_mut() {
                for field in &mut constructor.fields {
                    field.ty = solver.normalize(&field.ty)?;
                }
            }
            let inputs = definition
                .constructors
                .values()
                .flat_map(|constructor| &constructor.fields)
                .map(|field| LocatedInput {
                    exposed: false,
                    origin: CheckOrigin::Source(field.origin.clone()),
                    value: SemanticInput::Type(field.ty.clone(), TypeUse::Storage),
                })
                .collect();
            require_closed_inputs(
                inputs,
                &definition.formals.iter().cloned().collect(),
                &BTreeSet::new(),
            )?;
        }
        for (identity, ty) in &mut normalizer.normalized_aliases {
            let givens = owner_givens(identity, headers, traits, project)?;
            let origin = entity_origin(identity).unwrap();
            *ty = TraitSolver::new(traits, project, inference, &givens, origin.clone())?
                .normalize(ty)?;
            require_closed_inputs(
                vec![LocatedInput {
                    exposed: false,
                    origin: CheckOrigin::Source(origin),
                    value: SemanticInput::Type(ty.clone(), TypeUse::Relation),
                }],
                &BTreeSet::new(),
                &BTreeSet::new(),
            )?;
        }
        close_destruction_shapes(&mut normalizer.nominals);
        validate_public_requirements(traits, headers, exports)?;
        validate_public_effects(headers, exports)?;
        let bodies = headers
            .iter()
            .filter_map(|(identity, header)| header.body.is_some().then_some(identity.clone()))
            .collect::<Vec<_>>();
        validate_public_inputs(&bodies, headers, selections)?;
        let signatures = signature_schemes(headers, inference)?;
        for (identity, scheme) in &signatures {
            require_closed_scheme(scheme, &headers[identity].origin)?;
        }
        Ok(ClosedDeclarations { signatures })
    }
}

pub(super) fn push_owner_obligation(
    obligations: &mut Vec<TypeObligation>,
    owner: EntityId,
    origin: OriginRef,
    inputs: Vec<LocatedInput>,
) {
    obligations.push(TypeObligation {
        owner,
        primary: CheckOrigin::Source(origin),
        related: Vec::new(),
        kind: TypeObligationKind::Semantic(inputs),
        evidence: ObligationState::Pending,
    });
}

#[allow(
    dead_code,
    reason = "the opaque result retains completed owner checks from the sole obligation stream"
)]
pub(super) struct ClosedCheck {
    pub(super) owner: EntityId,
    pub(super) origin: CheckOrigin,
    pub(super) evidence: Vec<Evidence>,
}

impl TypeObligation {
    pub(super) fn into_closed(self) -> Result<ClosedCheck, CheckDiagnostic> {
        let ObligationState::Closed(evidence) = self.evidence else {
            return Err(CheckDiagnostic {
                kind: CheckDiagnosticKind::Unsupported,
                message: "incomplete solve: a source owner has pending checks at project assembly"
                    .to_owned(),
                primary: Some(self.primary),
                related: Vec::new(),
            });
        };
        Ok(ClosedCheck {
            owner: self.owner,
            origin: self.primary,
            evidence,
        })
    }
}

pub(super) fn body_inputs(
    body: &TypedBlock,
    header: &FunctionHeader,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    pending: Option<&[TypeObligation]>,
) -> Result<Vec<LocatedInput>, CheckDiagnostic> {
    enum Walk<'a> {
        Block(&'a TypedBlock),
        Expr(&'a TypedExpr),
    }
    let mut work = vec![Walk::Block(body)];
    let mut inputs = Vec::new();
    let fail = |span, message: &str| {
        source_diagnostic(
            CheckDiagnosticKind::Unsupported,
            format!("incomplete body closure: {message}"),
            header.context.origin(span),
            Vec::new(),
        )
    };
    while let Some(step) = work.pop() {
        match step {
            Walk::Block(block) => {
                let TypedBlock {
                    cleanups,
                    span,
                    statements,
                    tail,
                    ty,
                } = block;
                let origin = CheckOrigin::Source(header.context.origin(*span));
                inputs.push(LocatedInput {
                    exposed: false,
                    origin: origin.clone(),
                    value: SemanticInput::Type(ty.clone(), TypeUse::Value),
                });
                for cleanup in cleanups {
                    for binding in cleanup.state.bindings.values() {
                        inputs.push(LocatedInput {
                            exposed: false,
                            origin: CheckOrigin::Source(binding.origin.clone()),
                            value: SemanticInput::Type(binding.ty.clone(), TypeUse::Value),
                        });
                        inputs.extend(binding.cleanup.iter().cloned().map(|ty| LocatedInput {
                            exposed: false,
                            origin: CheckOrigin::Source(cleanup.origin.clone()),
                            value: SemanticInput::Type(ty, TypeUse::Relation),
                        }));
                    }
                    for temporary in &cleanup.state.temporaries {
                        inputs.push(LocatedInput {
                            exposed: false,
                            origin: CheckOrigin::Source(temporary.origin.clone()),
                            value: SemanticInput::Type(temporary.owner.clone(), TypeUse::Value),
                        });
                        inputs.extend(temporary.types.iter().cloned().map(|ty| LocatedInput {
                            exposed: false,
                            origin: CheckOrigin::Source(temporary.origin.clone()),
                            value: SemanticInput::Type(ty, TypeUse::Relation),
                        }));
                    }
                }
                if let Some(tail) = tail {
                    work.push(Walk::Expr(tail));
                }
                for statement in statements.iter().rev() {
                    match &statement.kind {
                        TypedStatementKind::Let { ty, value, .. } => {
                            inputs.push(LocatedInput {
                                exposed: false,
                                origin: CheckOrigin::Source(header.context.origin(statement.span)),
                                value: SemanticInput::Type(ty.clone(), TypeUse::Value),
                            });
                            work.push(Walk::Expr(value));
                        }
                        TypedStatementKind::Return(Some(value))
                        | TypedStatementKind::Expression(value) => work.push(Walk::Expr(value)),
                        TypedStatementKind::Return(None) => {}
                    }
                }
            }
            Walk::Expr(expression) => {
                let TypedExpr { span, ty, kind } = expression;
                let origin = CheckOrigin::Source(header.context.origin(*span));
                inputs.push(LocatedInput {
                    exposed: false,
                    origin: origin.clone(),
                    value: SemanticInput::Type(
                        ty.clone(),
                        if matches!(
                            kind,
                            TypedExprKind::Call(_) | TypedExprKind::IndirectCall(_)
                        ) {
                            TypeUse::Return
                        } else {
                            TypeUse::Value
                        },
                    ),
                });
                match kind {
                    TypedExprKind::DeferredCall { .. } => {
                        return Err(fail(*span, "call target is still deferred"));
                    }
                    TypedExprKind::FunctionValue(value) => inputs.push(LocatedInput {
                        exposed: false,
                        origin,
                        value: SemanticInput::Type(
                            CheckedType::Function(value.clone()),
                            TypeUse::Value,
                        ),
                    }),
                    TypedExprKind::IndirectCall(call) => {
                        let TypedIndirectCall {
                            callee,
                            arguments,
                            parameter_modes,
                            effect,
                            evidence,
                        } = call.as_ref();
                        if arguments.len() != parameter_modes.len() {
                            return Err(fail(*span, "indirect call modes are not closed"));
                        }
                        inputs.push(LocatedInput {
                            exposed: false,
                            origin: origin.clone(),
                            value: SemanticInput::Effect(effect.clone(), EffectUse::Runtime),
                        });
                        inputs.push(LocatedInput {
                            exposed: false,
                            origin,
                            value: SemanticInput::Evidence(evidence.as_ref().clone()),
                        });
                        work.extend(arguments.iter().rev().map(Walk::Expr));
                        work.push(Walk::Expr(callee));
                    }
                    TypedExprKind::Call(call) => {
                        let TypedCall {
                            callee,
                            evidence,
                            effect,
                            effect_actuals,
                            proofs,
                            arguments,
                            parameter_modes,
                            instantiation,
                        } = call.as_ref();
                        let provider = &headers[callee.as_ref()];
                        if arguments.len() != parameter_modes.len()
                            || parameter_modes.iter().zip(&provider.parameters).any(
                                |(mode, parameter)| {
                                    parameter
                                        .mode
                                        .as_ref()
                                        .is_none_or(|expected| mode != &expected.value)
                                },
                            )
                        {
                            return Err(fail(
                                *span,
                                "direct call modes do not match its exact callee",
                            ));
                        }
                        if effect_actuals.len() != provider.effect_formals.len()
                            || effect_actuals
                                .iter()
                                .zip(&provider.effect_formals)
                                .any(|((actual, _), (_, expected))| actual != expected)
                        {
                            return Err(fail(
                                *span,
                                "effect actuals do not belong to the exact callee formals",
                            ));
                        }
                        let mapping = match instantiation {
                            CallInstantiation::Published(mapping)
                            | CallInstantiation::Provisional(mapping) => {
                                mapping.iter().cloned().collect()
                            }
                            CallInstantiation::RecursiveBinding if pending.is_some() => {
                                BTreeMap::new()
                            }
                            CallInstantiation::RecursiveBinding => {
                                return Err(fail(*span, "recursive instantiation is not frozen"));
                            }
                        };
                        if pending.is_some() {
                            for requirement in provider
                                .requirements
                                .iter()
                                .chain(&provider.outer_requirements)
                            {
                                inputs.push(LocatedInput {
                                    exposed: false,
                                    origin: origin.clone(),
                                    value: SemanticInput::Proof(Requirement {
                                        subject: instantiate_type(&requirement.subject, &mapping),
                                        bound: instantiate_trait(&requirement.bound, &mapping),
                                        origin: origin.clone(),
                                    }),
                                });
                            }
                            for parameter in &provider.parameters {
                                inputs.push(LocatedInput {
                                    exposed: false,
                                    origin: origin.clone(),
                                    value: SemanticInput::Type(
                                        instantiate_type(&parameter.ty, &mapping),
                                        TypeUse::Value,
                                    ),
                                });
                            }
                            inputs.push(LocatedInput {
                                exposed: false,
                                origin: origin.clone(),
                                value: SemanticInput::Type(
                                    instantiate_type(&provider.return_type, &mapping),
                                    TypeUse::Return,
                                ),
                            });
                        }
                        inputs.extend(mapping.into_values().map(|ty| LocatedInput {
                            exposed: false,
                            origin: origin.clone(),
                            value: SemanticInput::Type(ty, TypeUse::Relation),
                        }));
                        inputs.push(LocatedInput {
                            exposed: false,
                            origin: origin.clone(),
                            value: SemanticInput::Effect(effect.clone(), EffectUse::Runtime),
                        });
                        inputs.extend(effect_actuals.iter().map(|(_, row)| LocatedInput {
                            exposed: false,
                            origin: origin.clone(),
                            value: SemanticInput::Effect(row.clone(), EffectUse::Runtime),
                        }));
                        inputs.extend(
                            proofs
                                .iter()
                                .cloned()
                                .chain(evidence.iter().map(|evidence| evidence.as_ref().clone()))
                                .map(|proof| LocatedInput {
                                    exposed: false,
                                    origin: origin.clone(),
                                    value: SemanticInput::Evidence(proof),
                                }),
                        );
                        work.extend(arguments.iter().rev().map(Walk::Expr));
                    }
                    TypedExprKind::Reference { use_kind, .. } => {
                        if use_kind.is_none() {
                            return Err(fail(*span, "binding use has no ownership fact"));
                        }
                    }
                    TypedExprKind::Parenthesized(inner)
                    | TypedExprKind::Unary { operand: inner, .. }
                    | TypedExprKind::Comparison {
                        invocation: inner, ..
                    }
                    | TypedExprKind::TupleField {
                        receiver: inner, ..
                    } => work.push(Walk::Expr(inner)),
                    TypedExprKind::Tuple(elements) => {
                        work.extend(elements.iter().rev().map(Walk::Expr))
                    }
                    TypedExprKind::Construct(construction) => {
                        match &construction.formation {
                            ObligationEvidence::Pending(index)
                                if pending.and_then(|items| items.get(*index)).is_some_and(
                                    |obligation| {
                                        obligation.owner == header.identity
                                            && matches!(
                                                obligation.kind,
                                                TypeObligationKind::Formation(_)
                                            )
                                    },
                                ) => {}
                            ObligationEvidence::Closed(proofs) => {
                                inputs.extend(proofs.iter().cloned().map(|proof| LocatedInput {
                                    exposed: false,
                                    origin: origin.clone(),
                                    value: SemanticInput::Evidence(proof),
                                }))
                            }
                            ObligationEvidence::Pending(_) => {
                                return Err(fail(
                                    *span,
                                    "construction has no completed formation receipt",
                                ));
                            }
                        }
                        inputs.push(LocatedInput {
                            exposed: false,
                            origin,
                            value: SemanticInput::Type(
                                CheckedType::Nominal(Box::new(construction.nominal.clone())),
                                TypeUse::Value,
                            ),
                        });
                        work.extend(
                            construction
                                .fields
                                .iter()
                                .rev()
                                .map(|field| Walk::Expr(&field.value)),
                        );
                    }
                    TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
                        work.push(Walk::Block(block))
                    }
                    TypedExprKind::Raise { payload, .. } => work.push(Walk::Expr(payload)),
                    TypedExprKind::If {
                        condition,
                        then_branch,
                        else_branch,
                    } => {
                        if let Some(branch) = else_branch {
                            work.push(Walk::Expr(branch));
                        }
                        work.push(Walk::Block(then_branch));
                        work.push(Walk::Expr(condition));
                    }
                    TypedExprKind::Binary { left, right, .. } => {
                        work.push(Walk::Expr(right));
                        work.push(Walk::Expr(left));
                    }
                    TypedExprKind::Field {
                        receiver,
                        selection,
                        use_kind,
                    } => {
                        let selected = match selection {
                            FieldSelection::Exact(..) => true,
                            FieldSelection::Pending(index) => pending
                                .and_then(|items| items.get(*index))
                                .is_some_and(|obligation| {
                                    matches!(
                                        &obligation.kind,
                                        TypeObligationKind::FieldProjection {
                                            selected: Some(_),
                                            ..
                                        }
                                    )
                                }),
                        };
                        if !selected || use_kind.is_none() {
                            return Err(fail(*span, "field selection or ownership is not closed"));
                        }
                        work.push(Walk::Expr(receiver));
                    }
                    TypedExprKind::Integer { .. }
                    | TypedExprKind::Float(_)
                    | TypedExprKind::Boolean(_)
                    | TypedExprKind::Unit => {}
                }
            }
        }
    }
    Ok(inputs)
}
