use super::*;
use crate::project::{
    ResolvedGenericBound, ResolvedImplMemberKind, ResolvedTraitMemberKind, ResolvedTypeParameter,
};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct TraitUse {
    pub(super) declaration: EntityId,
    pub(super) arguments: Vec<CheckedType>,
    pub(super) associated: BTreeMap<EntityId, CheckedType>,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct Projection {
    pub(super) subject: CheckedType,
    pub(super) owner: ProjectionOwner,
    pub(super) member: EntityId,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum ProjectionOwner {
    Trait(TraitUse),
    Inherent(EntityId),
}

impl ProjectionOwner {
    fn declaration(&self) -> &EntityId {
        match self {
            Self::Trait(bound) => &bound.declaration,
            Self::Inherent(owner) => owner,
        }
    }
    fn trait_use(&self) -> Option<&TraitUse> {
        match self {
            Self::Trait(bound) => Some(bound),
            Self::Inherent(_) => None,
        }
    }
}

#[derive(Debug, Clone)]
pub(super) struct Requirement {
    pub(super) subject: CheckedType,
    pub(super) bound: TraitUse,
    pub(super) origin: CheckOrigin,
}

pub(super) struct TraitDefinition {
    pub(super) self_formal: TypeFormal,
    pub(super) formals: Vec<TypeFormal>,
    pub(super) requirements: Vec<Requirement>,
    pub(super) associated: BTreeMap<EntityId, AssociatedDefinition>,
    pub(super) methods: BTreeMap<String, EntityId>,
}

pub(super) struct AssociatedDefinition {
    pub(super) bounds: Vec<TraitUse>,
    pub(super) default: Option<CheckedType>,
}

pub(super) struct Implementation {
    pub(super) identity: EntityId,
    pub(super) formals: Vec<TypeFormal>,
    pub(super) target: CheckedType,
    pub(super) trait_use: Option<TraitUse>,
    pub(super) requirements: Vec<Requirement>,
    pub(super) associated: BTreeMap<EntityId, CheckedType>,
    pub(super) methods: BTreeMap<String, EntityId>,
}

#[derive(Default)]
pub(super) struct TraitSelection {
    pub(super) traits: BTreeMap<EntityId, TraitDefinition>,
    pub(super) implementations: BTreeMap<EntityId, Implementation>,
}

pub(super) struct MethodInputs<'a> {
    pub(super) arguments: Vec<CheckedType>,
    pub(super) result: CheckedType,
    pub(super) headers: &'a BTreeMap<EntityId, FunctionHeader>,
    pub(super) schemes: &'a BTreeMap<EntityId, CallableScheme>,
}

impl SourceTypeNormalizer<'_> {
    pub(super) fn normalize_header_types(
        &self,
        headers: &mut BTreeMap<EntityId, FunctionHeader>,
        inference: &mut TypeInference,
    ) -> Result<(), CheckDiagnostic> {
        for header in headers.values_mut() {
            let givens = header
                .requirements
                .iter()
                .map(|requirement| requirement.map_types(|ty| inference.canonical(ty)))
                .collect::<Vec<_>>();
            let mut solver = SelectionSolver::new(
                &self.selection,
                &self.project.core_roles,
                &givens,
                CheckOrigin::Source(header.origin.clone()),
                inference,
            )?;
            for parameter in &mut header.parameters {
                parameter.ty = solver.normalize(&parameter.ty)?;
            }
            header.return_type = solver.normalize(&header.return_type)?;
            for shape in &mut header.shapes {
                shape.subject = solver.normalize(&shape.subject)?;
                for (ty, _) in &mut shape.shape.parameters {
                    *ty = solver.normalize(ty)?;
                }
                shape.shape.return_type = solver.normalize(&shape.shape.return_type)?;
                shape.shape.effect = solver.normalize_row(&shape.shape.effect)?;
            }
            header.effect_upper = header
                .effect_upper
                .as_ref()
                .map(|row| solver.normalize_row(row))
                .transpose()?;
            header.trait_upper = header
                .trait_upper
                .as_ref()
                .map(|row| solver.normalize_row(row))
                .transpose()?;
        }
        Ok(())
    }

    pub(super) fn validate_formation(
        &self,
        types: &[CheckedType],
        givens: &[Requirement],
        origin: CheckOrigin,
        inference: &mut TypeInference,
    ) -> Result<(), CheckDiagnostic> {
        let mut solver = SelectionSolver::new(
            &self.selection,
            &self.project.core_roles,
            givens,
            origin.clone(),
            inference,
        )?;
        let mut pending = types.to_vec();
        for requirement in givens {
            pending.push(requirement.subject.clone());
            pending.extend(requirement.bound.arguments.iter().cloned());
            pending.extend(requirement.bound.associated.values().cloned());
            let definition = &self.selection.traits[&requirement.bound.declaration];
            let mapping = definition.mapping(&requirement.subject, &requirement.bound);
            for condition in &definition.requirements {
                if condition.subject
                    != CheckedType::Formal(Box::new(definition.self_formal.clone()))
                {
                    solver.prove(&condition.instantiate(&mapping))?;
                }
            }
            for (member, actual) in &requirement.bound.associated {
                for bound in &definition.associated[member].bounds {
                    solver.prove(&Requirement {
                        subject: actual.clone(),
                        bound: bound.instantiate(&mapping),
                        origin: origin.clone(),
                    })?;
                }
            }
        }
        let mut visited = BTreeSet::new();
        while let Some(ty) = pending.pop() {
            solver.charge(1)?;
            if !visited.insert(ty.clone()) {
                continue;
            }
            match ty {
                CheckedType::Tuple(elements) => pending.extend(elements),
                CheckedType::Nominal(nominal) => {
                    let definition = &self.nominals[&nominal.declaration];
                    let mapping = definition
                        .formals
                        .iter()
                        .cloned()
                        .zip(nominal.arguments.iter().cloned())
                        .collect();
                    for requirement in &definition.requirements {
                        solver.prove(&requirement.instantiate(&mapping))?;
                    }
                    pending.extend(nominal.arguments);
                }
                CheckedType::Projection(projection) => {
                    let normalized =
                        solver.normalize(&CheckedType::Projection(projection.clone()))?;
                    pending.extend(projection.types().cloned());
                    if normalized != CheckedType::Projection(projection) {
                        pending.push(normalized);
                    }
                }
                CheckedType::Function(item) => pending.extend(item.types().cloned()),
                _ => {}
            }
        }
        Ok(())
    }

    pub(super) fn validate_declaration_formations(
        &self,
        headers: &BTreeMap<EntityId, FunctionHeader>,
        inference: &mut TypeInference,
    ) -> Result<(), CheckDiagnostic> {
        for (identity, definition) in &self.nominals {
            let fields = definition
                .constructors
                .values()
                .flat_map(|constructor| &constructor.fields)
                .map(|field| field.ty.clone())
                .collect::<Vec<_>>();
            self.validate_formation(
                &fields,
                &definition.requirements,
                CheckOrigin::Source(entity_origin(identity).expect("nominal declaration")),
                inference,
            )?;
        }
        for (identity, definition) in &self.selection.traits {
            let origin = CheckOrigin::Source(entity_origin(identity).expect("trait declaration"));
            let subject = CheckedType::Formal(Box::new(definition.self_formal.clone()));
            let mut givens = definition.requirements.clone();
            let bound = TraitUse {
                declaration: identity.clone(),
                arguments: definition
                    .formals
                    .iter()
                    .cloned()
                    .map(|formal| CheckedType::Formal(Box::new(formal)))
                    .collect(),
                associated: BTreeMap::new(),
            };
            givens.push(Requirement {
                subject: subject.clone(),
                bound: bound.clone(),
                origin: origin.clone(),
            });
            for (member, associated) in &definition.associated {
                for associated_bound in &associated.bounds {
                    givens.push(Requirement {
                        subject: CheckedType::Projection(Box::new(Projection {
                            subject: subject.clone(),
                            owner: ProjectionOwner::Trait(bound.clone()),
                            member: member.clone(),
                        })),
                        bound: associated_bound.clone(),
                        origin: origin.clone(),
                    });
                }
            }
            self.validate_formation(&[], &givens, origin.clone(), inference)?;
            let mut solver = SelectionSolver::new(
                &self.selection,
                &self.project.core_roles,
                &givens,
                origin.clone(),
                inference,
            )?;
            for associated in definition.associated.values() {
                if let Some(default) = &associated.default {
                    self.validate_formation(
                        std::slice::from_ref(default),
                        &givens,
                        origin.clone(),
                        solver.inference,
                    )?;
                    for bound in &associated.bounds {
                        solver.prove(&Requirement {
                            subject: default.clone(),
                            bound: bound.clone(),
                            origin: origin.clone(),
                        })?;
                    }
                }
            }
        }
        for implementation in self.selection.implementations.values() {
            let mut types = std::iter::once(&implementation.target)
                .chain(implementation.associated.values())
                .cloned()
                .collect::<Vec<_>>();
            if let Some(bound) = &implementation.trait_use {
                types.extend(bound.arguments.iter().cloned());
                types.extend(bound.associated.values().cloned());
            }
            self.validate_formation(
                &types,
                &implementation.requirements,
                CheckOrigin::Source(
                    entity_origin(&implementation.identity).expect("impl declaration"),
                ),
                inference,
            )?;
        }
        for header in headers.values() {
            let mut types = header
                .parameters
                .iter()
                .map(|parameter| parameter.ty.clone())
                .chain(std::iter::once(header.return_type.clone()))
                .collect::<Vec<_>>();
            for shape in &header.shapes {
                types.push(shape.subject.clone());
                types.extend(shape.shape.parameters.iter().map(|(ty, _)| ty.clone()));
                types.push(shape.shape.return_type.clone());
                types.extend(shape.shape.effect.types().into_iter().cloned());
            }
            if let Some(row) = &header.effect_upper {
                types.extend(row.types().into_iter().cloned());
            }
            self.validate_formation(
                &types,
                &header.requirements,
                CheckOrigin::Source(header.origin.clone()),
                inference,
            )?;
        }
        for (identity, ty) in &self.normalized_aliases {
            self.validate_formation(
                std::slice::from_ref(ty),
                &[],
                CheckOrigin::Source(entity_origin(identity).expect("alias declaration")),
                inference,
            )?;
        }
        for (identity, operation) in &self.operations {
            let types = operation
                .parameters
                .iter()
                .map(|(ty, _)| ty.clone())
                .chain(std::iter::once(operation.return_type.clone()))
                .collect::<Vec<_>>();
            self.validate_formation(
                &types,
                &self.effect_requirements[&operation.owner],
                CheckOrigin::Source(entity_origin(identity).expect("operation declaration")),
                inference,
            )?;
        }
        for (identity, requirements) in &self.effect_requirements {
            self.validate_formation(
                &[],
                requirements,
                CheckOrigin::Source(entity_origin(identity).expect("effect declaration")),
                inference,
            )?;
        }
        for use_site in &self.effect_uses {
            let givens = use_site
                .scope
                .as_ref()
                .and_then(|scope| {
                    headers
                        .get(scope)
                        .map(|header| &header.requirements)
                        .or_else(|| self.effect_requirements.get(scope))
                })
                .map_or(&[][..], Vec::as_slice);
            self.validate_formation(&use_site.types, givens, use_site.origin.clone(), inference)?;
            let mut solver = SelectionSolver::new(
                &self.selection,
                &self.project.core_roles,
                givens,
                use_site.origin.clone(),
                inference,
            )?;
            for requirement in &use_site.requirements {
                solver.prove(requirement)?;
            }
        }
        Ok(())
    }

    pub(super) fn validate_effect_visibility(
        &self,
        row: &EffectRow,
        exports: &BTreeSet<EntityId>,
        origin: &OriginRef,
    ) -> Result<(), CheckDiagnostic> {
        let mut rows = vec![row];
        while let Some(row) = rows.pop() {
            for ty in row.types() {
                validate_public_nominals(ty, exports, origin)?;
            }
            for term in &row.0 {
                let entity = match term {
                    EffectTerm::Handled(entity, _) => Some(entity),
                    EffectTerm::Method {
                        method, effects, ..
                    } => {
                        rows.extend(effects);
                        self.project.entities[method].owner.as_ref()
                    }
                    _ => None,
                };
                if let Some(entity) = entity
                    && !exports.contains(entity)
                    && !self.selection.implementations.contains_key(entity)
                {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "public effect contract exposes a private declaration",
                        origin.clone(),
                        entity_origin(entity).into_iter().collect(),
                    ));
                }
            }
        }
        Ok(())
    }

    pub(super) fn select_method(
        &self,
        subject: &CheckedType,
        member: &ResolvedSelection,
        caller: &FunctionHeader,
        inference: &mut TypeInference,
        inputs: &MethodInputs<'_>,
    ) -> SelectionResult<(EntityId, BTreeMap<TypeFormal, CheckedType>)> {
        let origin = CheckOrigin::Source(member.origin.clone());
        let mut solver = SelectionSolver::new(
            &self.selection,
            &self.project.core_roles,
            &caller.requirements,
            origin.clone(),
            inference,
        )?;
        let subject = solver.normalize(subject)?;
        let base = solver.snapshot();
        let mut candidates = Vec::new();
        let mut unresolved = None;
        let mut possible_traits = BTreeSet::new();
        if matches!(subject, CheckedType::Formal(_) | CheckedType::Projection(_)) {
            let mut givens = solver.givens.clone();
            if let CheckedType::Projection(projection) = &subject
                && let ProjectionOwner::Trait(bound) = &projection.owner
            {
                let definition = &self.selection.traits[&bound.declaration];
                let mapping = definition.mapping(&projection.subject, bound);
                let associated = definition.associated[&projection.member]
                    .bounds
                    .iter()
                    .map(|bound| Requirement {
                        subject: subject.clone(),
                        bound: bound.instantiate(&mapping),
                        origin: origin.clone(),
                    })
                    .collect::<Vec<_>>();
                let mut derived_inference = solver.inference.clone();
                let derived = SelectionSolver::new(
                    &self.selection,
                    &self.project.core_roles,
                    &associated,
                    origin.clone(),
                    &mut derived_inference,
                )?;
                givens.extend(derived.givens);
            }
            for given in givens {
                solver.restore(base.clone());
                let given = solver.normalize_requirement(&given)?;
                if given.subject != subject {
                    continue;
                }
                let definition = &self.selection.traits[&given.bound.declaration];
                if let Some(method) = definition.methods.get(&member.name) {
                    candidates.push((
                        method.clone(),
                        definition.mapping(&subject, &given.bound),
                        solver.snapshot(),
                    ));
                }
            }
        } else {
            for implementation in self
                .selection
                .implementations
                .values()
                .filter(|implementation| implementation.trait_use.is_none())
            {
                let Some(method) = implementation.methods.get(&member.name) else {
                    continue;
                };
                if !self.project.entities[method].public
                    && !caller.identity.module.is_descendant_of(&method.module)
                {
                    continue;
                }
                solver.restore(base.clone());
                match solver.match_implementation(&implementation.identity, &subject, None) {
                    Ok(Some(mapping)) => {
                        candidates.push((method.clone(), mapping, solver.snapshot()))
                    }
                    Ok(None) => {}
                    Err(error) => {
                        unresolved.get_or_insert(error);
                    }
                }
            }
            if candidates.is_empty() && unresolved.is_none() {
                for (trait_id, definition) in &self.selection.traits {
                    let Some(method) = definition.methods.get(&member.name) else {
                        continue;
                    };
                    if !self.project.entities[trait_id].public
                        && !caller.identity.module.is_descendant_of(&trait_id.module)
                    {
                        continue;
                    }
                    solver.restore(base.clone());
                    let bound = TraitUse {
                        declaration: trait_id.clone(),
                        arguments: definition
                            .formals
                            .iter()
                            .map(|_| solver.inference.fresh())
                            .collect(),
                        associated: BTreeMap::new(),
                    };
                    let requirement = Requirement {
                        subject: subject.clone(),
                        bound: bound.clone(),
                        origin: origin.clone(),
                    };
                    let nomination = solver.snapshot();
                    if matches!(solver.prove(&requirement), Err(ref error) if error.kind == SelectionFailureKind::NotApplicable)
                    {
                        continue;
                    }
                    solver.restore(nomination);
                    possible_traits.insert(trait_id.clone());
                    let mut mapping = definition.mapping(&subject, &bound);
                    let mut own_actuals = Vec::new();
                    let mut equations = Vec::new();
                    if !definition.formals.is_empty() {
                        let Some(header) = inputs.headers.get(method) else {
                            continue;
                        };
                        for formal in &header.declared_formals {
                            let actual = solver.inference.fresh();
                            mapping.insert(formal.clone(), actual.clone());
                            own_actuals.push(actual);
                        }
                        equations.extend(inputs.arguments.iter().zip(&header.parameters).map(
                            |(actual, parameter)| TypeEquation {
                                actual: actual.clone(),
                                expected: instantiate_type(&parameter.ty, &mapping),
                                widening: true,
                            },
                        ));
                        equations.push(TypeEquation {
                            actual: instantiate_type(&header.return_type, &mapping),
                            expected: inputs.result.clone(),
                            widening: true,
                        });
                        // Collect direct type information before asking for a
                        // dictionary. Impl-local binders never participate in
                        // this signature instantiation.
                        for equation in &equations {
                            let state = solver.snapshot();
                            if solver.constrain_equation(equation, true).is_err() {
                                solver.restore(state);
                            }
                        }
                        let environment = EffectEnvironment {
                            normalizer: self,
                            headers: inputs.headers,
                            schemes: inputs.schemes,
                        };
                        for shape in &header.shapes {
                            let actual_type = instantiate_type(&shape.subject, &mapping);
                            if matches!(
                                solver.inference.canonical(&actual_type),
                                CheckedType::Infer(_)
                            ) {
                                continue;
                            }
                            let actual = environment
                                .callable_shape(&actual_type, caller, solver.inference, &origin)
                                .map_err(|diagnostic| SelectionFailure {
                                    kind: SelectionFailureKind::Conflict,
                                    diagnostic: Box::new(diagnostic),
                                })?;
                            let expected = shape.shape.instantiate(&mapping, &BTreeMap::new());
                            equations.extend(
                                actual.parameters.iter().zip(&expected.parameters).map(
                                    |((actual, _), (expected, _))| TypeEquation {
                                        actual: actual.clone(),
                                        expected: expected.clone(),
                                        widening: false,
                                    },
                                ),
                            );
                            equations.push(TypeEquation {
                                actual: actual.return_type,
                                expected: expected.return_type,
                                widening: false,
                            });
                            equations
                                .extend(effect_payload_equations(&actual.effect, &expected.effect));
                        }
                        for row in header.effect_upper.iter().chain(&header.trait_upper) {
                            let actual = row.instantiate(&mapping, &BTreeMap::new());
                            for ceiling in
                                caller.effect_upper.iter().chain(&caller.trait_upper).chain(
                                    self.module_effects
                                        .get(&caller.identity.module)
                                        .map(|(row, _)| row),
                                )
                            {
                                equations.extend(effect_payload_equations(&actual, ceiling));
                            }
                        }
                    }
                    let requirement = Requirement {
                        subject: subject.clone(),
                        bound: bound.clone(),
                        origin: origin.clone(),
                    };
                    match solver.constrain_application(equations, vec![requirement.clone()]) {
                        Ok(()) => {}
                        Err(error) if error.kind == SelectionFailureKind::NotApplicable => continue,
                        Err(error) => {
                            unresolved.get_or_insert(error);
                            continue;
                        }
                    }
                    let index = solver.prove(&requirement)?;
                    let (selected, mut selected_mapping) = match &solver.evidence[index] {
                        Evidence::Implementation {
                            identity, mapping, ..
                        } => (
                            self.selection.implementations[identity].methods[&member.name].clone(),
                            mapping.clone(),
                        ),
                        _ => (method.clone(), definition.mapping(&subject, &bound)),
                    };
                    if let Some(header) = inputs.headers.get(&selected) {
                        for (formal, actual) in header.declared_formals.iter().zip(&own_actuals) {
                            selected_mapping
                                .insert(formal.clone(), solver.inference.canonical(actual));
                        }
                    }
                    selected_mapping = selected_mapping
                        .iter()
                        .map(|(formal, actual)| {
                            (formal.clone(), solver.inference.canonical(actual))
                        })
                        .collect();
                    candidates.push((selected, selected_mapping, solver.snapshot()));
                }
            }
        }
        solver.restore(base);
        if possible_traits.len() > 1 {
            return Err(solver.failure(
                SelectionFailureKind::Conflict,
                "method selection is ambiguous",
                possible_traits
                    .iter()
                    .filter_map(|trait_id| entity_origin(trait_id).map(CheckOrigin::Source))
                    .collect(),
            ));
        }
        if let Some(error) = unresolved {
            return Err(error);
        }
        let mut seen = BTreeSet::new();
        candidates.retain(|(method, mapping, _)| seen.insert((method.clone(), mapping.clone())));
        if candidates.len() != 1 {
            return Err(solver.failure(
                if candidates.is_empty() {
                    SelectionFailureKind::NotApplicable
                } else {
                    SelectionFailureKind::Conflict
                },
                if candidates.is_empty() {
                    "method has no evidence in the declared receiver domain"
                } else {
                    "method selection is ambiguous"
                },
                candidates
                    .iter()
                    .filter_map(|(method, _, _)| entity_origin(method).map(CheckOrigin::Source))
                    .collect(),
            ));
        }
        let (method, mapping, state) = candidates.pop().expect("one method");
        solver.restore(state);
        Ok((method, mapping))
    }

    pub(super) fn validate_implementations(&self) -> Result<(), CheckDiagnostic> {
        for implementation in self.selection.implementations.values() {
            let origin = entity_origin(&implementation.identity).expect("impl source");
            let library = implementation.identity.module.library();
            if let Some(bound) = &implementation.trait_use {
                let closed = [
                    &self.project.core_roles.function,
                    &self.project.core_roles.fn_mut,
                    &self.project.core_roles.fn_once,
                    &self.project.core_roles.copy,
                    &self.project.core_roles.drop.declaration,
                ];
                if closed.contains(&&bound.declaration) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "source impl requests a closed callable capability or an unsupported Copy/Drop resource capability",
                        origin,
                        entity_origin(&bound.declaration).into_iter().collect(),
                    ));
                }
                if bound.declaration.module.source_library() != Some(library) {
                    let mut local = false;
                    for ty in std::iter::once(&implementation.target).chain(&bound.arguments) {
                        if let CheckedType::Nominal(nominal) = ty
                            && nominal.declaration.module.source_library() == Some(library)
                        {
                            local = true;
                            break;
                        }
                        if matches!(ty, CheckedType::Formal(_) | CheckedType::Projection(_)) {
                            break;
                        }
                    }
                    if !local {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            "orphan impl: neither the trait nor an eligible header type belongs to this library",
                            origin,
                            entity_origin(&bound.declaration).into_iter().collect(),
                        ));
                    }
                }
                let mut selection_inference = TypeInference::default();
                let mut solver = SelectionSolver::new(
                    &self.selection,
                    &self.project.core_roles,
                    &implementation.requirements,
                    CheckOrigin::Source(origin.clone()),
                    &mut selection_inference,
                )?;
                if solver.primitive_evidence(&implementation.target, bound) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "source impl overlaps compiler-provided primitive evidence",
                        origin,
                        entity_origin(&bound.declaration).into_iter().collect(),
                    ));
                }
                let definition = &self.selection.traits[&bound.declaration];
                let mapping = definition.mapping(&implementation.target, bound);
                for requirement in &definition.requirements {
                    solver.prove(&requirement.instantiate(&mapping))?;
                }
                for (member, value) in &implementation.associated {
                    let actual = solver.normalize(value)?;
                    for bound in &definition.associated[member].bounds {
                        solver.prove(&Requirement {
                            subject: actual.clone(),
                            bound: bound.instantiate(&mapping),
                            origin: CheckOrigin::Source(origin.clone()),
                        })?;
                    }
                }
            } else if !matches!(&implementation.target, CheckedType::Nominal(nominal) if nominal.declaration.module.source_library() == Some(library))
            {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    "inherent impl target must be a nominal declaration owned by this library",
                    origin,
                    Vec::new(),
                ));
            }
        }
        let implementations = self.selection.implementations.values().collect::<Vec<_>>();
        for (index, left) in implementations.iter().enumerate() {
            for right in &implementations[index + 1..] {
                let relevant = match (&left.trait_use, &right.trait_use) {
                    (Some(left), Some(right)) => left.declaration == right.declaration,
                    (None, None) => {
                        left.methods
                            .keys()
                            .any(|name| right.methods.contains_key(name))
                            || left.associated.keys().any(|member| {
                                right
                                    .associated
                                    .keys()
                                    .any(|other| member.name == other.name)
                            })
                    }
                    _ => false,
                };
                if !relevant {
                    continue;
                }
                let mut inference = TypeInference::default();
                let mut mapping = BTreeMap::new();
                for formal in left.formals.iter().chain(&right.formals) {
                    mapping.insert(formal.clone(), inference.fresh());
                }
                let origin =
                    CheckOrigin::Source(entity_origin(&right.identity).expect("impl source"));
                let mut left_selection_inference = TypeInference::default();
                let mut left_solver = SelectionSolver::new(
                    &self.selection,
                    &self.project.core_roles,
                    &left.requirements,
                    origin.clone(),
                    &mut left_selection_inference,
                )?;
                let mut right_selection_inference = TypeInference::default();
                let mut right_solver = SelectionSolver::new(
                    &self.selection,
                    &self.project.core_roles,
                    &right.requirements,
                    origin,
                    &mut right_selection_inference,
                )?;
                let mut projection = false;
                let left_target =
                    coherence_operand(&mut left_solver, &left.target, &mapping, &mut projection)?;
                let right_target =
                    coherence_operand(&mut right_solver, &right.target, &mapping, &mut projection)?;
                let mut pairs = vec![(left_target, right_target)];
                if let (Some(left), Some(right)) = (&left.trait_use, &right.trait_use) {
                    for (left, right) in left.arguments.iter().zip(&right.arguments) {
                        pairs.push((
                            coherence_operand(&mut left_solver, left, &mapping, &mut projection)?,
                            coherence_operand(&mut right_solver, right, &mapping, &mut projection)?,
                        ));
                    }
                }
                let mut disjoint = false;
                for (left, right) in pairs {
                    match compare_coherence_types(&left, &right, &mut inference) {
                        CoherenceRelation::Disjoint => {
                            disjoint = true;
                            break;
                        }
                        CoherenceRelation::Incomplete => projection = true,
                        CoherenceRelation::Compatible => {}
                    }
                }
                if disjoint {
                    continue;
                }
                let mut predicates = Vec::new();
                for (implementation, solver) in
                    [(left, &mut left_solver), (right, &mut right_solver)]
                {
                    for requirement in &implementation.requirements {
                        let subject = coherence_operand(
                            solver,
                            &requirement.subject,
                            &mapping,
                            &mut projection,
                        )?;
                        let mut arguments = Vec::new();
                        for ty in &requirement.bound.arguments {
                            arguments.push(coherence_operand(
                                solver,
                                ty,
                                &mapping,
                                &mut projection,
                            )?);
                        }
                        let mut associated = BTreeMap::new();
                        for (member, ty) in &requirement.bound.associated {
                            associated.insert(
                                member.clone(),
                                coherence_operand(solver, ty, &mapping, &mut projection)?,
                            );
                        }
                        predicates.push(Requirement {
                            subject,
                            bound: TraitUse {
                                declaration: requirement.bound.declaration.clone(),
                                arguments,
                                associated,
                            },
                            origin: requirement.origin.clone(),
                        });
                    }
                }
                // Only incompatible rigid structure after shared reduction
                // proves disjointness. Unknown projections never prove it.
                for (index, first) in predicates.iter().enumerate() {
                    for second in &predicates[index + 1..] {
                        if inference.canonical(&first.subject)
                            != inference.canonical(&second.subject)
                            || first.bound.declaration != second.bound.declaration
                            || first
                                .bound
                                .arguments
                                .iter()
                                .map(|ty| inference.canonical(ty))
                                .collect::<Vec<_>>()
                                != second
                                    .bound
                                    .arguments
                                    .iter()
                                    .map(|ty| inference.canonical(ty))
                                    .collect::<Vec<_>>()
                        {
                            continue;
                        }
                        for (member, left_type) in &first.bound.associated {
                            if let Some(right_type) = second.bound.associated.get(member) {
                                match compare_coherence_types(left_type, right_type, &mut inference)
                                {
                                    CoherenceRelation::Disjoint => disjoint = true,
                                    CoherenceRelation::Incomplete => projection = true,
                                    CoherenceRelation::Compatible => {}
                                }
                            }
                        }
                    }
                }
                if !disjoint {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        if projection {
                            "coherence proof incomplete: associated header dependencies do not establish disjointness"
                        } else {
                            "overlapping impl domains prevent a unique selection"
                        },
                        entity_origin(&right.identity).expect("impl source"),
                        entity_origin(&left.identity).into_iter().collect(),
                    ));
                }
            }
        }
        Ok(())
    }

    pub(super) fn trait_method_header(
        &mut self,
        owner: &EntityId,
        signature: &crate::project::ResolvedFunctionSignature,
        public_export: bool,
        public_exports: &BTreeSet<EntityId>,
    ) -> Result<FunctionHeader, CheckDiagnostic> {
        let identity = &signature.identity;
        self.contract_scope = Some(identity.clone());
        let origin = entity_origin(identity).expect("source method");
        let context = SourceContext::from_origin(&origin);
        let formal_by_identity = self.owner_formals[identity].clone();
        let declared_formals = signature
            .type_parameters
            .iter()
            .map(|parameter| formal_by_identity[&parameter.binding.identity].clone())
            .collect();
        let outer_formals = formal_by_identity
            .values()
            .filter(|formal| formal.owner != *identity)
            .cloned()
            .collect();
        let mut requirements =
            self.parameter_requirements(&signature.type_parameters, &formal_by_identity)?;
        let mut effect_formals = signature
            .effect_parameters
            .iter()
            .enumerate()
            .map(|(ordinal, _)| EffectFormal {
                owner: identity.clone(),
                ordinal,
            })
            .collect::<Vec<_>>();
        let effect_by_identity = signature
            .effect_parameters
            .iter()
            .zip(&effect_formals)
            .map(|(parameter, formal)| (parameter.binding.identity.clone(), formal.clone()))
            .collect::<BTreeMap<_, _>>();
        let effect_upper = signature
            .effects
            .as_ref()
            .map(|row| self.normalize_effects(row, &formal_by_identity, &effect_by_identity))
            .transpose()?;
        let shapes = self.callback_shapes(
            identity,
            &signature.type_parameters,
            &formal_by_identity,
            &mut effect_formals,
            &effect_by_identity,
        )?;
        let definition = &self.selection.traits[owner];
        let self_type = CheckedType::Formal(Box::new(definition.self_formal.clone()));
        requirements.extend(definition.requirements.iter().cloned());
        requirements.push(Requirement {
            subject: self_type.clone(),
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
            origin: CheckOrigin::Source(origin.clone()),
        });
        let mut parameters = Vec::new();
        for parameter in &signature.parameters {
            if parameter.escape.is_some()
                || matches!(parameter.mode, Some((_, ParameterMode::MutBorrow)))
            {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "the method requires a callback or resource mode outside the current supported inputs",
                    parameter.binding.origin.clone(),
                    Vec::new(),
                ));
            }
            let ty = match &parameter.annotation {
                Some(ResolvedParameterAnnotation::Type(ty)) => {
                    if public_export {
                        validate_public_type_visibility(public_exports, ty, &self.aliases)?;
                    }
                    self.normalize_with_formals(ty, &formal_by_identity)?
                }
                None if parameter.binding.identity.name == "self" => self_type.clone(),
                _ => {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "method input requires a supported explicit type",
                        parameter.binding.origin.clone(),
                        Vec::new(),
                    ));
                }
            };
            parameters.push(HeaderParameter {
                binding: parameter.binding.identity.clone(),
                span: parameter.span,
                ty,
                type_origin: CheckOrigin::Source(parameter.binding.origin.clone()),
                source_type_explicit: true,
                mode: Some(SelectedMode {
                    value: parameter.mode.map_or(ParameterMode::Borrow, |(_, mode)| {
                        if mode == ParameterMode::Call {
                            ParameterMode::Borrow
                        } else {
                            mode
                        }
                    }),
                    origin: CheckOrigin::Source(parameter.binding.origin.clone()),
                }),
                callable_use: matches!(parameter.mode, Some((_, ParameterMode::Call))),
            });
        }
        let return_type = if let Some(ty) = &signature.return_type {
            if public_export {
                validate_public_type_visibility(public_exports, ty, &self.aliases)?;
            }
            self.normalize_with_formals(ty, &formal_by_identity)?
        } else {
            CheckedType::Unit
        };
        Ok(FunctionHeader {
            identity: identity.clone(),
            effect_formals,
            effect_upper,
            effect_origin: CheckOrigin::Source(
                context.origin(
                    signature
                        .effects
                        .as_ref()
                        .map_or(origin.span, |effects| effects.span),
                ),
            ),
            trait_upper: None,
            trait_effect_origin: None,
            shapes,
            inferable_effects: BTreeSet::new(),
            context,
            origin: origin.clone(),
            public_export,
            declared_formals,
            outer_formals,
            requirements,
            formal_by_identity,
            parameters,
            return_type,
            return_origin: CheckOrigin::Source(origin),
            source_return_explicit: true,
            body: None,
        })
    }

    pub(super) fn conform_methods(
        &self,
        headers: &mut BTreeMap<EntityId, FunctionHeader>,
        inference: &mut TypeInference,
    ) -> Result<(), CheckDiagnostic> {
        for implementation in self.selection.implementations.values() {
            let Some(bound) = &implementation.trait_use else {
                continue;
            };
            let definition = &self.selection.traits[&bound.declaration];
            let impl_origin = entity_origin(&implementation.identity).expect("impl source");
            for name in definition
                .methods
                .keys()
                .chain(implementation.methods.keys())
            {
                if !definition.methods.contains_key(name)
                    || !implementation.methods.contains_key(name)
                {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        format!("trait impl method set differs at `{name}`"),
                        impl_origin.clone(),
                        entity_origin(&bound.declaration).into_iter().collect(),
                    ));
                }
            }
            for (name, trait_method) in &definition.methods {
                let Some(expected) = headers.get(trait_method).cloned() else {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "the selected core method signature needs types or resource capabilities outside this Checker",
                        impl_origin.clone(),
                        entity_origin(trait_method).into_iter().collect(),
                    ));
                };
                let actual = headers
                    .get_mut(&implementation.methods[name])
                    .expect("impl body has a header");
                if expected.has_receiver() != actual.has_receiver() {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "trait and impl method receiver forms do not match",
                        actual.origin.clone(),
                        vec![expected.origin.clone()],
                    ));
                }
                if expected.declared_formals.len() != actual.declared_formals.len()
                    || expected.parameters.len() != actual.parameters.len()
                {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "trait and impl method generic or parameter arity differs",
                        actual.origin.clone(),
                        vec![expected.origin],
                    ));
                }
                let mut mapping = definition.mapping(&implementation.target, bound);
                mapping.extend(
                    expected.declared_formals.iter().cloned().zip(
                        actual
                            .declared_formals
                            .iter()
                            .cloned()
                            .map(|formal| CheckedType::Formal(Box::new(formal))),
                    ),
                );
                let expected_requirements = expected
                    .requirements
                    .iter()
                    .map(|requirement| requirement.instantiate(&mapping))
                    .collect::<Vec<_>>();
                let mut givens = implementation.requirements.clone();
                givens.extend(expected_requirements);
                for given in &mut givens {
                    if given.subject == implementation.target
                        && given.bound.declaration == bound.declaration
                        && given.bound.arguments == bound.arguments
                    {
                        given
                            .bound
                            .associated
                            .extend(implementation.associated.clone());
                    }
                }
                let mut solver = SelectionSolver::new(
                    &self.selection,
                    &self.project.core_roles,
                    &givens,
                    CheckOrigin::Source(actual.origin.clone()),
                    inference,
                )?;
                conform_callback_shapes(&expected, actual, &mapping, &mut solver)?;
                for requirement in &actual.requirements {
                    solver.prove(requirement)?;
                }
                for (parameter, required) in actual.parameters.iter_mut().zip(&expected.parameters)
                {
                    let ty = solver.normalize(&instantiate_type(&required.ty, &mapping))?;
                    if parameter.source_type_explicit {
                        let actual_type = solver.normalize(&parameter.ty)?;
                        solver
                            .inference
                            .unify(&actual_type, &ty)
                            .map_err(|failure| {
                                source_diagnostic(
                                    CheckDiagnosticKind::TypeMismatch,
                                    format!(
                                        "impl parameter does not conform: {}",
                                        display_unification_failure(&failure)
                                    ),
                                    actual.context.origin(parameter.span),
                                    vec![expected.origin.clone()],
                                )
                            })?;
                    }
                    parameter.ty = ty;
                    let expected_mode = required.mode.as_ref().expect("signature mode fixed");
                    if let Some(mode) = &parameter.mode
                        && mode.value != expected_mode.value
                    {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            "impl strengthens or changes the trait parameter mode",
                            actual.context.origin(parameter.span),
                            vec![expected.origin.clone()],
                        ));
                    }
                    parameter.mode = Some(expected_mode.clone());
                    parameter.callable_use = required.callable_use;
                    parameter.source_type_explicit = true;
                }
                let return_type =
                    solver.normalize(&instantiate_type(&expected.return_type, &mapping))?;
                if actual.source_return_explicit {
                    let actual_type = solver.normalize(&actual.return_type)?;
                    inference
                        .unify(&actual_type, &return_type)
                        .map_err(|failure| {
                            source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                format!(
                                    "impl result does not conform: {}",
                                    display_unification_failure(&failure)
                                ),
                                actual.origin.clone(),
                                vec![expected.origin.clone()],
                            )
                        })?;
                }
                actual.return_type = return_type;
                actual.source_return_explicit = true;
                actual.requirements = givens;
            }
        }
        Ok(())
    }

    pub(super) fn index_formals(
        &mut self,
        identity: &EntityId,
        parameters: &[ResolvedTypeParameter],
    ) {
        let mut formals = self.project.entities[identity]
            .owner
            .as_ref()
            .and_then(|owner| self.owner_formals.get(owner))
            .cloned()
            .unwrap_or_default();
        for (ordinal, parameter) in parameters.iter().enumerate() {
            let formal = TypeFormal {
                owner: identity.clone(),
                ordinal,
                name: parameter.binding.identity.name.clone(),
            };
            self.generic_bounds.insert(
                formal.clone(),
                parameter
                    .bounds
                    .iter()
                    .filter_map(|bound| match bound {
                        ResolvedGenericBound::Named(named) => Some(named.as_ref().clone()),
                        ResolvedGenericBound::Shape(_) => None,
                    })
                    .collect(),
            );
            formals.insert(parameter.binding.identity.clone(), formal);
        }
        self.owner_formals.insert(identity.clone(), formals);
    }

    pub(super) fn prepare_selection(&mut self) -> Result<(), CheckDiagnostic> {
        let declarations = self
            .project
            .modules
            .values()
            .filter_map(|module| module.body.as_ref())
            .flat_map(|body| &body.declarations)
            .cloned()
            .collect::<Vec<_>>();
        for declaration in &declarations {
            let Some(identity) = &declaration.identity else {
                continue;
            };
            let parameters = match &declaration.kind {
                ResolvedDeclarationKind::Function(function) => &function.type_parameters,
                ResolvedDeclarationKind::Struct {
                    type_parameters, ..
                }
                | ResolvedDeclarationKind::Enum {
                    type_parameters, ..
                }
                | ResolvedDeclarationKind::Trait {
                    type_parameters, ..
                }
                | ResolvedDeclarationKind::Effect {
                    type_parameters, ..
                }
                | ResolvedDeclarationKind::EffectAlias {
                    type_parameters, ..
                } => type_parameters,
                ResolvedDeclarationKind::InherentImpl(_)
                | ResolvedDeclarationKind::TraitImpl { .. } => {
                    // The two source variants share the same owner binder model.
                    let implementation = match &declaration.kind {
                        ResolvedDeclarationKind::InherentImpl(value) => value,
                        ResolvedDeclarationKind::TraitImpl { implementation, .. } => implementation,
                        _ => unreachable!(),
                    };
                    &implementation.type_parameters
                }
                _ => continue,
            };
            self.index_formals(identity, parameters);
            if let ResolvedDeclarationKind::Trait { members, .. } = &declaration.kind {
                let self_identity = self
                    .project
                    .entities
                    .iter()
                    .find_map(|(id, entity)| {
                        (id.kind == EntityKind::SelfType && entity.owner.as_ref() == Some(identity))
                            .then_some(id)
                    })
                    .expect("trait owner has exact Self")
                    .clone();
                let self_formal = TypeFormal {
                    owner: self_identity.clone(),
                    ordinal: 0,
                    name: "Self".to_owned(),
                };
                self.self_types.insert(
                    self_identity.clone(),
                    CheckedType::Formal(Box::new(self_formal.clone())),
                );
                self.owner_formals
                    .get_mut(identity)
                    .expect("owner formals indexed")
                    .insert(self_identity, self_formal.clone());
                let formals = parameters
                    .iter()
                    .map(|parameter| {
                        self.owner_formals[identity][&parameter.binding.identity].clone()
                    })
                    .collect();
                self.selection.traits.insert(
                    identity.clone(),
                    TraitDefinition {
                        self_formal,
                        formals,
                        requirements: Vec::new(),
                        associated: BTreeMap::new(),
                        methods: members
                            .iter()
                            .filter_map(|member| {
                                matches!(member.kind, ResolvedTraitMemberKind::Method(_)).then_some(
                                    (member.identity.name.clone(), member.identity.clone()),
                                )
                            })
                            .collect(),
                    },
                );
            }
        }
        // All headers are present before any where-clause or assignment can
        // reference an impl declared later in the source.
        for declaration in &declarations {
            let (implementation, trait_type) = match &declaration.kind {
                ResolvedDeclarationKind::InherentImpl(implementation) => (implementation, None),
                ResolvedDeclarationKind::TraitImpl {
                    implementation,
                    trait_type,
                    ..
                } => (implementation.as_ref(), Some(trait_type)),
                _ => continue,
            };
            let identity = declaration.identity.as_ref().expect("impl identity");
            let formals = self.owner_formals[identity].clone();
            let target = self.normalize_with_formals(
                &ResolvedType {
                    span: implementation.target.span,
                    kind: ResolvedTypeKind::Named(Box::new(implementation.target.clone())),
                },
                &formals,
            )?;
            let trait_use = trait_type
                .map(|named| self.normalize_trait_use(named, &formals))
                .transpose()?;
            for (self_identity, entity) in &self.project.entities {
                if self_identity.kind == EntityKind::SelfType
                    && entity.owner.as_ref() == Some(identity)
                {
                    self.self_types
                        .insert(self_identity.clone(), target.clone());
                }
            }
            self.selection.implementations.insert(
                identity.clone(),
                Implementation {
                    identity: identity.clone(),
                    formals: implementation
                        .type_parameters
                        .iter()
                        .map(|parameter| formals[&parameter.binding.identity].clone())
                        .collect(),
                    target,
                    trait_use,
                    requirements: Vec::new(),
                    associated: BTreeMap::new(),
                    methods: implementation
                        .members
                        .iter()
                        .filter_map(|member| {
                            matches!(member.kind, ResolvedImplMemberKind::Function(_))
                                .then_some((member.identity.name.clone(), member.identity.clone()))
                        })
                        .collect(),
                },
            );
        }
        for declaration in &declarations {
            let Some(identity) = &declaration.identity else {
                continue;
            };
            if let ResolvedDeclarationKind::Trait {
                type_parameters,
                supertraits,
                ..
            } = &declaration.kind
            {
                let formals = self.owner_formals[identity].clone();
                let self_type = CheckedType::Formal(Box::new(
                    self.selection.traits[identity].self_formal.clone(),
                ));
                let mut requirements = self.parameter_requirements(type_parameters, &formals)?;
                for named in supertraits {
                    requirements.push(Requirement {
                        subject: self_type.clone(),
                        bound: self.normalize_trait_use(named, &formals)?,
                        origin: CheckOrigin::Source(reference_origin(&named.reference).clone()),
                    });
                }
                self.selection
                    .traits
                    .get_mut(identity)
                    .expect("trait indexed")
                    .requirements = requirements;
            }
        }
        for declaration in &declarations {
            let Some(identity) = &declaration.identity else {
                continue;
            };
            if let ResolvedDeclarationKind::Trait { members, .. } = &declaration.kind {
                let formals = self.owner_formals[identity].clone();
                let mut associated = BTreeMap::new();
                for member in members {
                    match &member.kind {
                        ResolvedTraitMemberKind::Method(signature) => {
                            self.index_formals(&member.identity, &signature.type_parameters)
                        }
                        ResolvedTraitMemberKind::AssociatedType { bounds, default } => {
                            associated.insert(
                                member.identity.clone(),
                                AssociatedDefinition {
                                    bounds: bounds
                                        .iter()
                                        .map(|bound| self.normalize_trait_use(bound, &formals))
                                        .collect::<Result<_, _>>()?,
                                    default: default
                                        .as_ref()
                                        .map(|ty| self.normalize_with_formals(ty, &formals))
                                        .transpose()?,
                                },
                            );
                        }
                    }
                }
                self.selection
                    .traits
                    .get_mut(identity)
                    .expect("trait indexed")
                    .associated = associated;
            }
        }
        for declaration in &declarations {
            let (implementation, where_clause) = match &declaration.kind {
                ResolvedDeclarationKind::InherentImpl(implementation) => (implementation, None),
                ResolvedDeclarationKind::TraitImpl {
                    implementation,
                    where_clause,
                    ..
                } => (implementation.as_ref(), where_clause.as_ref()),
                _ => continue,
            };
            let identity = declaration.identity.as_ref().expect("impl identity");
            let formals = self.owner_formals[identity].clone();
            let mut requirements =
                self.parameter_requirements(&implementation.type_parameters, &formals)?;
            if let Some(clause) = where_clause {
                for predicate in &clause.predicates {
                    let subject = self.normalize_with_formals(&predicate.subject, &formals)?;
                    for bound in &predicate.bounds {
                        requirements.push(Requirement {
                            subject: subject.clone(),
                            bound: self.normalize_trait_use(bound, &formals)?,
                            origin: CheckOrigin::Source(reference_origin(&bound.reference).clone()),
                        });
                    }
                }
            }
            let mut associated = BTreeMap::new();
            let trait_use = self.selection.implementations[identity].trait_use.clone();
            for member in &implementation.members {
                match &member.kind {
                    ResolvedImplMemberKind::Function(function) => {
                        self.index_formals(&member.identity, &function.type_parameters)
                    }
                    ResolvedImplMemberKind::AssociatedType(value) => {
                        let canonical = if let Some(bound) = &trait_use {
                            self.associated_member(
                                &bound.declaration,
                                &member.identity.name,
                                entity_origin(&member.identity).expect("source member"),
                            )?
                        } else {
                            member.identity.clone()
                        };
                        associated.insert(canonical, self.normalize_with_formals(value, &formals)?);
                    }
                }
            }
            if let Some(bound) = &trait_use {
                let definition = &self.selection.traits[&bound.declaration];
                let mapping =
                    definition.mapping(&self.selection.implementations[identity].target, bound);
                for (member, definition) in &definition.associated {
                    if !associated.contains_key(member) {
                        let Some(default) = &definition.default else {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                format!("impl is missing associated type `{}`", member.name),
                                declaration.origin.clone(),
                                entity_origin(member).into_iter().collect(),
                            ));
                        };
                        associated.insert(member.clone(), instantiate_type(default, &mapping));
                    }
                }
            }
            let typed = self
                .selection
                .implementations
                .get_mut(identity)
                .expect("impl indexed");
            typed.requirements = requirements;
            typed.associated = associated;
        }
        for declaration in &declarations {
            let parameters = match &declaration.kind {
                ResolvedDeclarationKind::Effect {
                    type_parameters, ..
                }
                | ResolvedDeclarationKind::EffectAlias {
                    type_parameters, ..
                } => type_parameters,
                _ => continue,
            };
            let owner = declaration.identity.as_ref().expect("effect owner");
            let formals = self.owner_formals[owner].clone();
            let requirements = self.parameter_requirements(parameters, &formals)?;
            self.effect_requirements.insert(owner.clone(), requirements);
        }
        Ok(())
    }

    pub(super) fn parameter_requirements(
        &mut self,
        parameters: &[ResolvedTypeParameter],
        formals: &BTreeMap<EntityId, TypeFormal>,
    ) -> Result<Vec<Requirement>, CheckDiagnostic> {
        let mut requirements = Vec::new();
        for parameter in parameters {
            let subject =
                CheckedType::Formal(Box::new(formals[&parameter.binding.identity].clone()));
            for bound in &parameter.bounds {
                if let ResolvedGenericBound::Named(named) = bound {
                    requirements.push(Requirement {
                        subject: subject.clone(),
                        bound: self.normalize_trait_use(named, formals)?,
                        origin: CheckOrigin::Source(reference_origin(&named.reference).clone()),
                    });
                }
            }
        }
        Ok(requirements)
    }

    pub(super) fn associated_member(
        &self,
        owner: &EntityId,
        name: &str,
        origin: OriginRef,
    ) -> Result<EntityId, CheckDiagnostic> {
        self.project.entities[owner]
            .members
            .get(name)
            .into_iter()
            .flatten()
            .find(|member| member.kind == EntityKind::AssociatedType)
            .cloned()
            .ok_or_else(|| {
                source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    format!("`{}` has no associated type `{name}`", owner.name),
                    origin,
                    entity_origin(owner).into_iter().collect(),
                )
            })
    }

    pub(super) fn normalize_trait_use(
        &mut self,
        named: &ResolvedNamedType,
        formals: &BTreeMap<EntityId, TypeFormal>,
    ) -> Result<TraitUse, CheckDiagnostic> {
        let ResolvedReference::Exact {
            occurrence, target, ..
        } = &named.reference
        else {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "a bound must select an exact named trait",
                reference_origin(&named.reference).clone(),
                Vec::new(),
            ));
        };
        if target.kind != EntityKind::Trait {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "a bound must name a trait declaration",
                occurrence.clone(),
                entity_origin(target).into_iter().collect(),
            ));
        }
        let mut arguments = Vec::new();
        let mut associated = BTreeMap::new();
        for argument in &named.arguments {
            match argument {
                ResolvedTypeArgument::Type(ty) => {
                    arguments.push(self.normalize_with_formals(ty, formals)?)
                }
                ResolvedTypeArgument::AssociatedType { member, value } => {
                    let member_id =
                        self.associated_member(target, &member.name, member.origin.clone())?;
                    let ty = self.normalize_with_formals(value, formals)?;
                    if associated.insert(member_id, ty).is_some() {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            "duplicate associated type binding",
                            member.origin.clone(),
                            Vec::new(),
                        ));
                    }
                }
            }
        }
        if self.arities[target] != arguments.len() {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "trait argument arity does not match its declaration",
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

    pub(super) fn normalize_associated_reference(
        &mut self,
        reference: &ResolvedReference,
        formals: &BTreeMap<EntityId, TypeFormal>,
    ) -> Result<CheckedType, CheckDiagnostic> {
        match reference {
            ResolvedReference::Exact {
                target, occurrence, ..
            } => {
                let owner = self.project.entities[target]
                    .owner
                    .as_ref()
                    .expect("associated member owner")
                    .clone();
                if let Some(definition) = self.selection.traits.get(&owner) {
                    return Ok(CheckedType::Projection(Box::new(Projection {
                        subject: CheckedType::Formal(Box::new(definition.self_formal.clone())),
                        owner: ProjectionOwner::Trait(TraitUse {
                            declaration: owner,
                            arguments: definition
                                .formals
                                .iter()
                                .cloned()
                                .map(|formal| CheckedType::Formal(Box::new(formal)))
                                .collect(),
                            associated: BTreeMap::new(),
                        }),
                        member: target.clone(),
                    })));
                }
                let implementation = &self.selection.implementations[&owner];
                let subject = implementation.target.clone();
                let owner = implementation
                    .trait_use
                    .clone()
                    .map_or(ProjectionOwner::Inherent(owner), ProjectionOwner::Trait);
                let member =
                    self.associated_member(owner.declaration(), &target.name, occurrence.clone())?;
                Ok(CheckedType::Projection(Box::new(Projection {
                    subject,
                    owner,
                    member,
                })))
            }
            ResolvedReference::Selection {
                occurrence,
                base,
                members,
                self_reference,
                ..
            } => {
                let base_type = ResolvedType {
                    span: occurrence.span,
                    kind: ResolvedTypeKind::Named(Box::new(ResolvedNamedType {
                        span: occurrence.span,
                        reference: ResolvedReference::Exact {
                            occurrence: occurrence.clone(),
                            target: self_reference.as_ref().map_or_else(
                                || base.clone(),
                                |reference| reference.identity.clone(),
                            ),
                            self_reference: None,
                        },
                        arguments: Vec::new(),
                    })),
                };
                let mut subject = self.normalize_with_formals(&base_type, formals)?;
                for member in members {
                    let mut candidates = Vec::new();
                    if let CheckedType::Formal(formal) = &subject {
                        if let Some(scope) = &self.contract_scope {
                            candidates.extend(
                                self.contract_bounds
                                    .get(scope)
                                    .into_iter()
                                    .flatten()
                                    .filter(|requirement| requirement.subject == subject)
                                    .map(|requirement| {
                                        ProjectionOwner::Trait(requirement.bound.clone())
                                    }),
                            );
                        }
                        for mut named in self
                            .generic_bounds
                            .get(formal.as_ref())
                            .cloned()
                            .unwrap_or_default()
                        {
                            // The projection selects a trait member. Associated
                            // equalities are checked through the owning requirement.
                            named.arguments.retain(|argument| {
                                matches!(argument, ResolvedTypeArgument::Type(_))
                            });
                            candidates.push(ProjectionOwner::Trait(
                                self.normalize_trait_use(&named, formals)?,
                            ));
                        }
                        if let Some((identity, definition)) = self
                            .selection
                            .traits
                            .iter()
                            .find(|(_, definition)| &definition.self_formal == formal.as_ref())
                        {
                            candidates.push(ProjectionOwner::Trait(TraitUse {
                                declaration: identity.clone(),
                                arguments: definition
                                    .formals
                                    .iter()
                                    .cloned()
                                    .map(|formal| CheckedType::Formal(Box::new(formal)))
                                    .collect(),
                                associated: BTreeMap::new(),
                            }));
                        }
                    } else if let CheckedType::Projection(projection) = &subject {
                        if let ProjectionOwner::Trait(bound) = &projection.owner {
                            let definition = &self.selection.traits[&bound.declaration];
                            let mapping = definition.mapping(&projection.subject, bound);
                            if let Some(associated) = definition.associated.get(&projection.member)
                            {
                                candidates.extend(associated.bounds.iter().map(|bound| {
                                    ProjectionOwner::Trait(bound.instantiate(&mapping))
                                }));
                            }
                        }
                    } else {
                        for implementation in self.selection.implementations.values() {
                            let owner = implementation
                                .trait_use
                                .as_ref()
                                .map_or(&implementation.identity, |bound| &bound.declaration);
                            if !self.project.entities[owner]
                                .members
                                .get(&member.name)
                                .is_some_and(|members| {
                                    members
                                        .iter()
                                        .any(|member| member.kind == EntityKind::AssociatedType)
                                })
                            {
                                continue;
                            }
                            let mut selection_inference = TypeInference::default();
                            let mut solver = SelectionSolver::new(
                                &self.selection,
                                &self.project.core_roles,
                                &[],
                                CheckOrigin::Source(member.origin.clone()),
                                &mut selection_inference,
                            )?;
                            if let Some(mapping) = solver.match_implementation(
                                &implementation.identity,
                                &subject,
                                None,
                            )? {
                                candidates.push(implementation.trait_use.as_ref().map_or_else(
                                    || ProjectionOwner::Inherent(implementation.identity.clone()),
                                    |bound| ProjectionOwner::Trait(bound.instantiate(&mapping)),
                                ));
                            }
                        }
                    }
                    let mut next = 0;
                    while next < candidates.len() {
                        if next > SELECTION_STATE_LIMIT {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                "associated lookup proof incomplete: declaration-state limit reached",
                                member.origin.clone(),
                                Vec::new(),
                            ));
                        }
                        let owner = candidates[next].clone();
                        next += 1;
                        if let ProjectionOwner::Trait(bound) = owner {
                            let definition = &self.selection.traits[&bound.declaration];
                            let mapping = definition.mapping(&subject, &bound);
                            for requirement in &definition.requirements {
                                let requirement = requirement.instantiate(&mapping);
                                let owner = ProjectionOwner::Trait(requirement.bound);
                                if requirement.subject == subject && !candidates.contains(&owner) {
                                    candidates.push(owner);
                                }
                            }
                        }
                    }
                    for owner in &mut candidates {
                        if let ProjectionOwner::Trait(bound) = owner {
                            bound.associated.clear();
                        }
                    }
                    candidates.retain(|owner| {
                        self.project.entities[owner.declaration()]
                            .members
                            .get(&member.name)
                            .is_some_and(|members| {
                                members
                                    .iter()
                                    .any(|member| member.kind == EntityKind::AssociatedType)
                            })
                    });
                    candidates.sort();
                    candidates.dedup();
                    let [owner] = candidates.as_slice() else {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            if candidates.is_empty() {
                                "associated selection has no evidence from the declared input domain"
                            } else {
                                "associated selection is ambiguous"
                            },
                            member.origin.clone(),
                            candidates
                                .iter()
                                .filter_map(|owner| entity_origin(owner.declaration()))
                                .collect(),
                        ));
                    };
                    let exact = self.associated_member(
                        owner.declaration(),
                        &member.name,
                        member.origin.clone(),
                    )?;
                    subject = CheckedType::Projection(Box::new(Projection {
                        subject,
                        owner: owner.clone(),
                        member: exact,
                    }));
                }
                Ok(subject)
            }
        }
    }
}

pub(super) fn reference_origin(reference: &ResolvedReference) -> &OriginRef {
    match reference {
        ResolvedReference::Exact { occurrence, .. }
        | ResolvedReference::Selection { occurrence, .. } => occurrence,
    }
}

#[derive(Clone)]
pub(super) enum Evidence {
    Given(Requirement),
    Associated {
        requirement: Requirement,
        parent: usize,
    },
    Primitive {
        subject: CheckedType,
        declaration: EntityId,
    },
    Implementation {
        identity: EntityId,
        mapping: BTreeMap<TypeFormal, CheckedType>,
        requirements: Vec<usize>,
    },
}

// Every query owns its work/state allowance. Failure never changes the limit
// or becomes a negative impl fact. Selection and projection share this stack.
pub(super) const SELECTION_WORK_LIMIT: usize = 16_384;
pub(super) const SELECTION_STATE_LIMIT: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum SelectionGoal {
    Type(CheckedType),
    Evidence(CheckedType, Box<TraitUse>),
    NormalizeRequirement(CheckedType, Box<TraitUse>),
    Applicable(Box<ImplementationRequest>),
    Constraints(Box<ConstraintRequest>),
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct TypeEquation {
    pub(super) actual: CheckedType,
    pub(super) expected: CheckedType,
    pub(super) widening: bool,
}

#[derive(Debug, Clone)]
pub(super) struct ConstraintRequest {
    equalities: Vec<TypeEquation>,
    requirements: Vec<Requirement>,
}

impl PartialEq for ConstraintRequest {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other).is_eq()
    }
}
impl Eq for ConstraintRequest {}
impl PartialOrd for ConstraintRequest {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for ConstraintRequest {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.equalities.cmp(&other.equalities).then_with(|| {
            self.requirements
                .iter()
                .map(|r| (&r.subject, &r.bound))
                .cmp(other.requirements.iter().map(|r| (&r.subject, &r.bound)))
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct ImplementationRequest {
    identity: EntityId,
    subject: CheckedType,
    bound: Option<TraitUse>,
}

impl SelectionGoal {
    fn evidence(subject: CheckedType, bound: TraitUse) -> Self {
        Self::Evidence(subject, Box::new(bound))
    }
}

pub(super) enum SelectionFrame {
    Enter(SelectionGoal),
    FinishType(SelectionGoal, CheckedType, usize),
    Project(SelectionGoal, Projection),
    FinishProjection(SelectionGoal),
    Choose(SelectionGoal, TraitUse, usize),
    FinishRequirement(SelectionGoal, TraitUse, usize),
    Givens(SelectionGoal, CheckedType, TraitUse, Vec<GivenCandidate>),
    Implementations(SelectionGoal, CheckedType, TraitUse),
    Derived(SelectionGoal, Requirement),
    Candidate(Box<CandidateWork>),
    BeginTrial(ImplementationRequest),
    EndTrial(Box<SelectionSnapshot>),
    Candidates(SelectionGoal, usize),
}

pub(super) struct CandidateWork {
    goal: SelectionGoal,
    identity: Option<EntityId>,
    mapping: BTreeMap<TypeFormal, CheckedType>,
    equalities: Vec<TypeEquation>,
    requirements: Vec<Requirement>,
    progress: Vec<CheckedType>,
}

#[derive(Clone)]
pub(super) struct SelectionSnapshot {
    inference: TypeInference,
    evidence: Vec<Evidence>,
}

#[derive(Clone)]
pub(super) struct CandidateSolution {
    state: SelectionSnapshot,
    evidence: usize,
}

#[derive(Clone)]
pub(super) enum SelectionValue {
    Type(CheckedType),
    Evidence(usize),
    Requirement(CheckedType, Box<TraitUse>),
    Candidate(Box<CandidateSolution>),
    Constraints,
}

pub(super) struct GivenCandidate {
    requirement: Requirement,
    parent: Option<Requirement>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum SelectionFailureKind {
    NotApplicable,
    Conflict,
    Cycle,
    Incomplete,
}

#[derive(Debug)]
pub(super) struct SelectionFailure {
    pub(super) kind: SelectionFailureKind,
    diagnostic: Box<CheckDiagnostic>,
}

impl From<SelectionFailure> for CheckDiagnostic {
    fn from(failure: SelectionFailure) -> Self {
        *failure.diagnostic
    }
}

pub(super) type SelectionResult<T> = Result<T, SelectionFailure>;

pub(super) struct SelectionSolver<'a> {
    pub(super) declarations: &'a TraitSelection,
    pub(super) core: &'a crate::project::CoreRoles,
    pub(super) givens: Vec<Requirement>,
    pub(super) origin: CheckOrigin,
    pub(super) work: usize,
    pub(super) evidence: Vec<Evidence>,
    pub(super) inference: &'a mut TypeInference,
}

impl TraitUse {
    pub(super) fn instantiate(&self, mapping: &BTreeMap<TypeFormal, CheckedType>) -> Self {
        Self {
            declaration: self.declaration.clone(),
            arguments: self
                .arguments
                .iter()
                .map(|ty| instantiate_type(ty, mapping))
                .collect(),
            associated: self
                .associated
                .iter()
                .map(|(member, ty)| (member.clone(), instantiate_type(ty, mapping)))
                .collect(),
        }
    }
}

impl Projection {
    pub(super) fn types(&self) -> impl Iterator<Item = &CheckedType> {
        std::iter::once(&self.subject).chain(
            self.owner
                .trait_use()
                .into_iter()
                .flat_map(|bound| bound.arguments.iter().chain(bound.associated.values())),
        )
    }
    pub(super) fn map_types(&self, mut map: impl FnMut(&CheckedType) -> CheckedType) -> Self {
        let owner = match &self.owner {
            ProjectionOwner::Trait(bound) => ProjectionOwner::Trait(TraitUse {
                declaration: bound.declaration.clone(),
                arguments: bound.arguments.iter().map(&mut map).collect(),
                associated: bound
                    .associated
                    .iter()
                    .map(|(member, ty)| (member.clone(), map(ty)))
                    .collect(),
            }),
            ProjectionOwner::Inherent(owner) => ProjectionOwner::Inherent(owner.clone()),
        };
        Self {
            subject: map(&self.subject),
            owner,
            member: self.member.clone(),
        }
    }
}

impl Requirement {
    pub(super) fn map_types(&self, mut map: impl FnMut(&CheckedType) -> CheckedType) -> Self {
        Self {
            subject: map(&self.subject),
            bound: TraitUse {
                declaration: self.bound.declaration.clone(),
                arguments: self.bound.arguments.iter().map(&mut map).collect(),
                associated: self
                    .bound
                    .associated
                    .iter()
                    .map(|(member, ty)| (member.clone(), map(ty)))
                    .collect(),
            },
            origin: self.origin.clone(),
        }
    }
    pub(super) fn instantiate(&self, mapping: &BTreeMap<TypeFormal, CheckedType>) -> Self {
        Self {
            subject: instantiate_type(&self.subject, mapping),
            bound: self.bound.instantiate(mapping),
            origin: self.origin.clone(),
        }
    }
}

impl Evidence {
    pub(super) fn types(&self) -> Vec<&CheckedType> {
        match self {
            Self::Given(requirement) | Self::Associated { requirement, .. } => {
                std::iter::once(&requirement.subject)
                    .chain(&requirement.bound.arguments)
                    .chain(requirement.bound.associated.values())
                    .collect()
            }
            Self::Primitive { subject, .. } => vec![subject],
            Self::Implementation { mapping, .. } => mapping.values().collect(),
        }
    }

    pub(super) fn map_types(self, mut map: impl FnMut(&CheckedType) -> CheckedType) -> Self {
        match self {
            Self::Given(requirement) => Self::Given(requirement.map_types(map)),
            Self::Associated {
                requirement,
                parent,
            } => Self::Associated {
                requirement: requirement.map_types(map),
                parent,
            },
            Self::Primitive {
                subject,
                declaration,
            } => Self::Primitive {
                subject: map(&subject),
                declaration,
            },
            Self::Implementation {
                identity,
                mapping,
                requirements,
            } => Self::Implementation {
                identity,
                mapping: mapping
                    .into_iter()
                    .map(|(formal, ty)| (formal, map(&ty)))
                    .collect(),
                requirements,
            },
        }
    }
}

pub(super) fn append_evidence(target: &mut Vec<Evidence>, incoming: Vec<Evidence>) {
    let offset = target.len();
    target.extend(incoming.into_iter().map(|mut evidence| {
        match &mut evidence {
            Evidence::Implementation { requirements, .. } => {
                for index in requirements {
                    *index += offset;
                }
            }
            Evidence::Associated { parent, .. } => *parent += offset,
            _ => {}
        }
        evidence
    }));
}

impl TraitDefinition {
    pub(super) fn mapping(
        &self,
        subject: &CheckedType,
        bound: &TraitUse,
    ) -> BTreeMap<TypeFormal, CheckedType> {
        std::iter::once((self.self_formal.clone(), subject.clone()))
            .chain(
                self.formals
                    .iter()
                    .cloned()
                    .zip(bound.arguments.iter().cloned()),
            )
            .collect()
    }
}

impl<'a> SelectionSolver<'a> {
    pub(super) fn new(
        declarations: &'a TraitSelection,
        core: &'a crate::project::CoreRoles,
        givens: &[Requirement],
        origin: CheckOrigin,
        inference: &'a mut TypeInference,
    ) -> SelectionResult<Self> {
        let mut solver = Self {
            declarations,
            core,
            givens: givens.to_vec(),
            origin,
            work: 0,
            evidence: Vec::new(),
            inference,
        };
        let mut next = 0;
        while next < solver.givens.len() {
            solver.charge(1)?;
            let given = solver.givens[next].clone();
            next += 1;
            let declaration = &declarations.traits[&given.bound.declaration];
            let mapping = declaration.mapping(&given.subject, &given.bound);
            for requirement in &declaration.requirements {
                if requirement.subject
                    != CheckedType::Formal(Box::new(declaration.self_formal.clone()))
                {
                    continue;
                }
                let requirement = requirement.instantiate(&mapping);
                if !solver.givens.iter().any(|other| {
                    other.subject == requirement.subject && other.bound == requirement.bound
                }) {
                    solver.givens.push(requirement);
                }
            }
        }
        Ok(solver)
    }

    fn constrain(
        &mut self,
        left: &CheckedType,
        right: &CheckedType,
        defer_projection: bool,
    ) -> SelectionResult<()> {
        let mut pending = vec![(left.clone(), right.clone())];
        while let Some((left, right)) = pending.pop() {
            self.charge(1)?;
            let left = self.inference.canonical(&left);
            let right = self.inference.canonical(&right);
            if left == right {
                continue;
            }
            match (&left, &right) {
                (CheckedType::Infer(_), _) | (_, CheckedType::Infer(_)) => {
                    self.inference.unify(&left, &right).map_err(|failure| {
                        self.failure(
                            SelectionFailureKind::NotApplicable,
                            format!("no evidence: {}", display_unification_failure(&failure)),
                            Vec::new(),
                        )
                    })?;
                }
                (CheckedType::Projection(_), _) | (_, CheckedType::Projection(_))
                    if defer_projection => {}
                (CheckedType::Projection(_), _) | (_, CheckedType::Projection(_)) => {
                    return Err(self.failure(
                        SelectionFailureKind::Incomplete,
                        "selection proof incomplete: associated equality remains undetermined",
                        Vec::new(),
                    ));
                }
                (CheckedType::Tuple(left), CheckedType::Tuple(right))
                    if left.len() == right.len() =>
                {
                    pending.extend(left.iter().cloned().zip(right.iter().cloned()))
                }
                (CheckedType::Nominal(left), CheckedType::Nominal(right))
                    if left.declaration == right.declaration =>
                {
                    pending.extend(
                        left.arguments
                            .iter()
                            .cloned()
                            .zip(right.arguments.iter().cloned()),
                    )
                }
                (CheckedType::Formal(_), CheckedType::Formal(_)) => {
                    return Err(self.failure(
                        SelectionFailureKind::NotApplicable,
                        "no evidence: distinct caller formals are rigid",
                        Vec::new(),
                    ));
                }
                _ => self.inference.unify(&left, &right).map_err(|failure| {
                    self.failure(
                        SelectionFailureKind::NotApplicable,
                        format!("no evidence: {}", display_unification_failure(&failure)),
                        Vec::new(),
                    )
                })?,
            }
        }
        Ok(())
    }

    fn failure(
        &self,
        kind: SelectionFailureKind,
        message: impl Into<String>,
        related: Vec<CheckOrigin>,
    ) -> SelectionFailure {
        SelectionFailure {
            kind,
            diagnostic: Box::new(CheckDiagnostic {
                kind: CheckDiagnosticKind::TypeMismatch,
                message: message.into(),
                primary: Some(self.origin.clone()),
                related,
            }),
        }
    }

    pub(super) fn charge(&mut self, count: usize) -> SelectionResult<()> {
        self.work = self.work.saturating_add(count);
        if self.work > SELECTION_WORK_LIMIT {
            return Err(self.failure(SelectionFailureKind::Incomplete, format!("selection proof incomplete: logical work limit {SELECTION_WORK_LIMIT} exceeded at work {}", self.work), Vec::new()));
        }
        Ok(())
    }

    pub(super) fn normalize(&mut self, ty: &CheckedType) -> SelectionResult<CheckedType> {
        match self.solve(SelectionGoal::Type(ty.clone()))? {
            SelectionValue::Type(ty) => Ok(ty),
            _ => unreachable!("a type query returns a type"),
        }
    }

    pub(super) fn normalize_row(&mut self, row: &EffectRow) -> SelectionResult<EffectRow> {
        let mut failure = None;
        let row = row.map_types(&mut |ty| match self.normalize(ty) {
            Ok(ty) => ty,
            Err(error) => {
                failure.get_or_insert(error);
                ty.clone()
            }
        });
        if let Some(failure) = failure {
            Err(failure)
        } else {
            Ok(row)
        }
    }

    pub(super) fn prove(&mut self, requirement: &Requirement) -> SelectionResult<usize> {
        match self
            .solve(SelectionGoal::evidence(
                requirement.subject.clone(),
                requirement.bound.clone(),
            ))
            .map_err(|mut diagnostic| {
                if requirement.origin != self.origin
                    && !diagnostic.diagnostic.related.contains(&requirement.origin)
                {
                    diagnostic
                        .diagnostic
                        .related
                        .push(requirement.origin.clone());
                }
                diagnostic
            })? {
            SelectionValue::Evidence(index) => Ok(index),
            _ => unreachable!("an evidence query returns evidence"),
        }
    }

    pub(super) fn normalize_requirement(
        &mut self,
        requirement: &Requirement,
    ) -> SelectionResult<Requirement> {
        match self.solve(SelectionGoal::NormalizeRequirement(
            requirement.subject.clone(),
            Box::new(requirement.bound.clone()),
        ))? {
            SelectionValue::Requirement(subject, bound) => Ok(Requirement {
                subject,
                bound: *bound,
                origin: requirement.origin.clone(),
            }),
            _ => unreachable!("normalized requirement"),
        }
    }

    fn match_implementation(
        &mut self,
        identity: &EntityId,
        subject: &CheckedType,
        arguments: Option<&[CheckedType]>,
    ) -> SelectionResult<Option<BTreeMap<TypeFormal, CheckedType>>> {
        let bound = arguments.map(|arguments| TraitUse {
            declaration: self.declarations.implementations[identity]
                .trait_use
                .as_ref()
                .expect("trait header")
                .declaration
                .clone(),
            arguments: arguments.to_vec(),
            associated: BTreeMap::new(),
        });
        match self.solve(SelectionGoal::Applicable(Box::new(ImplementationRequest {
            identity: identity.clone(),
            subject: subject.clone(),
            bound,
        }))) {
            Ok(SelectionValue::Evidence(index)) => match &self.evidence[index] {
                Evidence::Implementation { mapping, .. } => Ok(Some(mapping.clone())),
                _ => unreachable!("implementation query"),
            },
            Err(error) if error.kind == SelectionFailureKind::NotApplicable => Ok(None),
            Err(error) => Err(error),
            _ => unreachable!("implementation evidence"),
        }
    }

    fn require_owner_actuals(
        &self,
        identity: &EntityId,
        mapping: &BTreeMap<TypeFormal, CheckedType>,
    ) -> SelectionResult<()> {
        if let Some(formal) = self.declarations.implementations[identity]
            .formals
            .iter()
            .find(|formal| {
                mapping.get(*formal).is_none_or(|actual| {
                    let mut variables = BTreeSet::new();
                    self.inference.unresolved_variables(actual, &mut variables);
                    !variables.is_empty()
                })
            })
        {
            return Err(self.failure(
                SelectionFailureKind::Incomplete,
                format!(
                    "selection proof incomplete: impl owner actual `{}` is not uniquely determined",
                    formal.name
                ),
                entity_origin(identity)
                    .map(CheckOrigin::Source)
                    .into_iter()
                    .collect(),
            ));
        }
        Ok(())
    }

    pub(super) fn constrain_application(
        &mut self,
        equalities: Vec<TypeEquation>,
        mut requirements: Vec<Requirement>,
    ) -> SelectionResult<()> {
        for equation in &equalities {
            let left = self.inference.canonical(&equation.actual);
            let right = self.inference.canonical(&equation.expected);
            if left == right
                || matches!(left, CheckedType::Infer(_))
                || matches!(right, CheckedType::Infer(_))
            {
                continue;
            }
            let (projection, expected) = match (&left, &right) {
                (CheckedType::Projection(projection), other) => (projection, other),
                (other, CheckedType::Projection(projection))
                    if !(equation.widening && *other == CheckedType::Never) =>
                {
                    (projection, other)
                }
                _ => continue,
            };
            if let ProjectionOwner::Trait(bound) = &projection.owner {
                let mut bound = bound.clone();
                bound
                    .associated
                    .insert(projection.member.clone(), expected.clone());
                requirements.push(Requirement {
                    subject: projection.subject.clone(),
                    bound,
                    origin: self.origin.clone(),
                });
            }
        }
        match self.solve(SelectionGoal::Constraints(Box::new(ConstraintRequest {
            equalities,
            requirements,
        })))? {
            SelectionValue::Constraints => Ok(()),
            _ => unreachable!("application constraint result"),
        }
    }

    fn constrain_equation(
        &mut self,
        equation: &TypeEquation,
        defer_projection: bool,
    ) -> SelectionResult<()> {
        let mut pending = vec![(equation.actual.clone(), equation.expected.clone())];
        while let Some((actual, expected)) = pending.pop() {
            let actual = self.inference.canonical(&actual);
            let expected = self.inference.canonical(&expected);
            if equation.widening {
                if actual == CheckedType::Never {
                    continue;
                }
                if let (CheckedType::Tuple(left), CheckedType::Tuple(right)) = (&actual, &expected)
                    && left.len() == right.len()
                {
                    pending.extend(left.iter().cloned().zip(right.iter().cloned()));
                    continue;
                }
            }
            self.constrain(&actual, &expected, defer_projection)?;
        }
        Ok(())
    }

    fn snapshot(&self) -> SelectionSnapshot {
        SelectionSnapshot {
            inference: self.inference.clone(),
            evidence: self.evidence.clone(),
        }
    }

    fn restore(&mut self, state: SelectionSnapshot) {
        *self.inference = state.inference;
        self.evidence = state.evidence;
    }

    fn canonical_goal(&self, goal: SelectionGoal) -> SelectionGoal {
        match goal {
            SelectionGoal::Type(ty) => SelectionGoal::Type(self.inference.canonical(&ty)),
            SelectionGoal::Evidence(subject, bound) => {
                let requirement = Requirement {
                    subject,
                    bound: *bound,
                    origin: self.origin.clone(),
                }
                .map_types(|ty| self.inference.canonical(ty));
                SelectionGoal::evidence(requirement.subject, requirement.bound)
            }
            SelectionGoal::NormalizeRequirement(subject, bound) => {
                let requirement = Requirement {
                    subject,
                    bound: *bound,
                    origin: self.origin.clone(),
                }
                .map_types(|ty| self.inference.canonical(ty));
                SelectionGoal::NormalizeRequirement(
                    requirement.subject,
                    Box::new(requirement.bound),
                )
            }
            SelectionGoal::Applicable(mut request) => {
                request.subject = self.inference.canonical(&request.subject);
                request.bound = request.bound.map(|bound| {
                    Requirement {
                        subject: CheckedType::Unit,
                        bound,
                        origin: self.origin.clone(),
                    }
                    .map_types(|ty| self.inference.canonical(ty))
                    .bound
                });
                SelectionGoal::Applicable(request)
            }
            SelectionGoal::Constraints(mut request) => {
                for equation in &mut request.equalities {
                    equation.actual = self.inference.canonical(&equation.actual);
                    equation.expected = self.inference.canonical(&equation.expected);
                }
                request.requirements = request
                    .requirements
                    .iter()
                    .map(|requirement| requirement.map_types(|ty| self.inference.canonical(ty)))
                    .collect();
                SelectionGoal::Constraints(request)
            }
        }
    }

    fn candidate_progress(&self, work: &CandidateWork) -> Vec<CheckedType> {
        work.mapping
            .values()
            .chain(
                work.equalities
                    .iter()
                    .flat_map(|equation| [&equation.actual, &equation.expected]),
            )
            .chain(work.requirements.iter().flat_map(|requirement| {
                std::iter::once(&requirement.subject)
                    .chain(&requirement.bound.arguments)
                    .chain(requirement.bound.associated.values())
            }))
            .map(|ty| self.inference.canonical(ty))
            .collect()
    }

    fn schedule_candidate(&self, mut work: CandidateWork, frames: &mut Vec<SelectionFrame>) {
        work.progress = self.candidate_progress(&work);
        let mut tasks = work
            .equalities
            .iter()
            .flat_map(|equation| {
                [
                    SelectionGoal::Type(equation.actual.clone()),
                    SelectionGoal::Type(equation.expected.clone()),
                ]
            })
            .collect::<Vec<_>>();
        tasks.extend(work.requirements.iter().map(|requirement| {
            SelectionGoal::evidence(requirement.subject.clone(), requirement.bound.clone())
        }));
        frames.push(SelectionFrame::Candidate(Box::new(work)));
        frames.extend(tasks.into_iter().rev().map(SelectionFrame::Enter));
    }

    pub(super) fn solve(&mut self, root: SelectionGoal) -> SelectionResult<SelectionValue> {
        // Reserve the external variable namespace even for declaration-only
        // callers that have no shared inference state to import.
        let mut inputs = Vec::new();
        match &root {
            SelectionGoal::Type(ty) => inputs.push(ty),
            SelectionGoal::Evidence(subject, bound)
            | SelectionGoal::NormalizeRequirement(subject, bound) => {
                inputs.push(subject);
                inputs.extend(&bound.arguments);
                inputs.extend(bound.associated.values());
            }
            SelectionGoal::Applicable(request) => {
                inputs.push(&request.subject);
                if let Some(bound) = &request.bound {
                    inputs.extend(&bound.arguments);
                    inputs.extend(bound.associated.values());
                }
            }
            SelectionGoal::Constraints(request) => {
                inputs.extend(
                    request
                        .equalities
                        .iter()
                        .flat_map(|equation| [&equation.actual, &equation.expected]),
                );
                inputs.extend(request.requirements.iter().flat_map(|requirement| {
                    std::iter::once(&requirement.subject)
                        .chain(&requirement.bound.arguments)
                        .chain(requirement.bound.associated.values())
                }));
            }
        }
        let mut variables = BTreeSet::new();
        for ty in inputs {
            self.inference.unresolved_variables(ty, &mut variables);
        }
        if let Some(variable) = variables.last() {
            self.inference.next_variable = self.inference.next_variable.max(variable.0 + 1);
        }
        let baseline = self.snapshot();
        let result = self.solve_machine(root);
        if result.is_err() {
            self.restore(baseline);
        } else {
            self.evidence = self
                .evidence
                .iter()
                .cloned()
                .map(|evidence| evidence.map_types(|ty| self.inference.canonical(ty)))
                .collect();
        }
        result
    }

    fn solve_machine(&mut self, root: SelectionGoal) -> SelectionResult<SelectionValue> {
        let mut frames = vec![SelectionFrame::Enter(root)];
        let mut active = BTreeSet::new();
        let mut complete = BTreeMap::<SelectionGoal, SelectionValue>::new();
        let mut cache_revision = self.inference.revision;
        let mut values = Vec::<SelectionResult<SelectionValue>>::new();
        while let Some(frame) = frames.pop() {
            self.charge(1)?;
            if active.len() > SELECTION_STATE_LIMIT {
                return Err(self.failure(SelectionFailureKind::Incomplete,
                    format!("selection proof incomplete: active state limit {SELECTION_STATE_LIMIT} exceeded after {} logical steps", self.work), Vec::new()));
            }
            if cache_revision != self.inference.revision {
                complete.clear();
                cache_revision = self.inference.revision;
            }
            let mut finished = None;
            match frame {
                SelectionFrame::Enter(goal) => {
                    let goal = self.canonical_goal(goal);
                    if let Some(value) = complete.get(&goal) {
                        values.push(Ok(value.clone()));
                        continue;
                    }
                    if let SelectionGoal::Evidence(subject, bound) = &goal
                        && let Some(given) = self.givens.iter().find(|given| {
                            given.subject == *subject
                                && given.bound.declaration == bound.declaration
                                && given.bound.arguments == bound.arguments
                                && bound.associated.iter().all(|(member, ty)| {
                                    given.bound.associated.get(member) == Some(ty)
                                })
                        })
                    {
                        let index = self.evidence.len();
                        self.evidence.push(Evidence::Given(given.clone()));
                        complete.insert(goal, SelectionValue::Evidence(index));
                        values.push(Ok(SelectionValue::Evidence(index)));
                        continue;
                    }
                    if !active.insert(goal.clone()) {
                        values.push(Err(self.failure(
                            SelectionFailureKind::Cycle,
                            "illegal selection or associated-projection cycle without a base fact",
                            Vec::new(),
                        )));
                        continue;
                    }
                    if matches!(&goal, SelectionGoal::Evidence(CheckedType::Infer(_), _)) {
                        active.remove(&goal);
                        values.push(Err(self.failure(
                            SelectionFailureKind::Incomplete,
                            "selection proof incomplete: receiver dependencies remain undetermined",
                            Vec::new(),
                        )));
                        continue;
                    }
                    match &goal {
                        SelectionGoal::Type(ty) => {
                            match ty {
                                CheckedType::Tuple(elements) => {
                                    frames.push(SelectionFrame::FinishType(
                                        goal.clone(),
                                        ty.clone(),
                                        elements.len(),
                                    ));
                                    frames.extend(
                                        elements.iter().rev().cloned().map(|ty| {
                                            SelectionFrame::Enter(SelectionGoal::Type(ty))
                                        }),
                                    );
                                }
                                CheckedType::Nominal(nominal) => {
                                    frames.push(SelectionFrame::FinishType(
                                        goal.clone(),
                                        ty.clone(),
                                        nominal.arguments.len(),
                                    ));
                                    frames.extend(
                                        nominal.arguments.iter().rev().cloned().map(|ty| {
                                            SelectionFrame::Enter(SelectionGoal::Type(ty))
                                        }),
                                    );
                                }
                                CheckedType::Function(item) => {
                                    let mut types = Vec::new();
                                    item.map_types(|ty| {
                                        types.push(ty.clone());
                                        ty.clone()
                                    });
                                    frames.push(SelectionFrame::FinishType(
                                        goal.clone(),
                                        ty.clone(),
                                        types.len(),
                                    ));
                                    frames.extend(
                                        types.into_iter().rev().map(|ty| {
                                            SelectionFrame::Enter(SelectionGoal::Type(ty))
                                        }),
                                    );
                                }
                                CheckedType::Projection(projection) => {
                                    frames.push(SelectionFrame::Project(
                                        goal.clone(),
                                        projection.as_ref().clone(),
                                    ));
                                    frames.push(SelectionFrame::Enter(match &projection.owner {
                                        ProjectionOwner::Trait(bound) => SelectionGoal::evidence(
                                            projection.subject.clone(),
                                            bound.clone(),
                                        ),
                                        ProjectionOwner::Inherent(identity) => {
                                            SelectionGoal::Applicable(Box::new(
                                                ImplementationRequest {
                                                    identity: identity.clone(),
                                                    subject: projection.subject.clone(),
                                                    bound: None,
                                                },
                                            ))
                                        }
                                    }));
                                }
                                _ => {
                                    finished =
                                        Some((goal.clone(), Ok(SelectionValue::Type(ty.clone()))))
                                }
                            }
                        }
                        SelectionGoal::Evidence(subject, bound)
                        | SelectionGoal::NormalizeRequirement(subject, bound) => {
                            let types = std::iter::once(subject)
                                .chain(&bound.arguments)
                                .chain(bound.associated.values())
                                .cloned()
                                .collect::<Vec<_>>();
                            frames.push(if matches!(goal, SelectionGoal::Evidence(_, _)) {
                                SelectionFrame::Choose(
                                    goal.clone(),
                                    bound.as_ref().clone(),
                                    types.len(),
                                )
                            } else {
                                SelectionFrame::FinishRequirement(
                                    goal.clone(),
                                    bound.as_ref().clone(),
                                    types.len(),
                                )
                            });
                            frames.extend(
                                types
                                    .into_iter()
                                    .rev()
                                    .map(|ty| SelectionFrame::Enter(SelectionGoal::Type(ty))),
                            );
                        }
                        SelectionGoal::Applicable(request) => {
                            let implementation =
                                &self.declarations.implementations[&request.identity];
                            let mapping = implementation
                                .formals
                                .iter()
                                .cloned()
                                .map(|formal| (formal, self.inference.fresh()))
                                .collect::<BTreeMap<_, _>>();
                            let mut equalities = vec![TypeEquation {
                                actual: instantiate_type(&implementation.target, &mapping),
                                expected: request.subject.clone(),
                                widening: false,
                            }];
                            if let Some(bound) = &request.bound {
                                let implemented =
                                    implementation.trait_use.as_ref().expect("trait candidate");
                                equalities.extend(
                                    implemented.arguments.iter().zip(&bound.arguments).map(
                                        |(pattern, actual)| TypeEquation {
                                            actual: instantiate_type(pattern, &mapping),
                                            expected: actual.clone(),
                                            widening: false,
                                        },
                                    ),
                                );
                                for (member, expected) in &bound.associated {
                                    equalities.push(TypeEquation {
                                        actual: instantiate_type(
                                            &implementation.associated[member],
                                            &mapping,
                                        ),
                                        expected: expected.clone(),
                                        widening: false,
                                    });
                                }
                            }
                            let requirements = implementation
                                .requirements
                                .iter()
                                .map(|requirement| requirement.instantiate(&mapping))
                                .collect();
                            let structural = equalities
                                .iter()
                                .try_for_each(|equation| self.constrain_equation(equation, true));
                            match structural {
                                Err(error) => finished = Some((goal.clone(), Err(error))),
                                Ok(()) => self.schedule_candidate(
                                    CandidateWork {
                                        goal: goal.clone(),
                                        identity: Some(request.identity.clone()),
                                        mapping,
                                        equalities,
                                        requirements,
                                        progress: Vec::new(),
                                    },
                                    &mut frames,
                                ),
                            }
                        }
                        SelectionGoal::Constraints(request) => {
                            match request
                                .equalities
                                .iter()
                                .try_for_each(|equation| self.constrain_equation(equation, true))
                            {
                                Err(error) => finished = Some((goal.clone(), Err(error))),
                                Ok(()) => self.schedule_candidate(
                                    CandidateWork {
                                        goal: goal.clone(),
                                        identity: None,
                                        mapping: BTreeMap::new(),
                                        equalities: request.equalities.clone(),
                                        requirements: request.requirements.clone(),
                                        progress: Vec::new(),
                                    },
                                    &mut frames,
                                ),
                            }
                        }
                    }
                }
                SelectionFrame::FinishType(goal, mut ty, count) => {
                    let operands = values
                        .split_off(values.len() - count)
                        .into_iter()
                        .collect::<Result<Vec<_>, _>>();
                    finished = Some((
                        goal,
                        operands.map(|operands| {
                            let children = operands
                                .into_iter()
                                .map(|value| match value {
                                    SelectionValue::Type(ty) => ty,
                                    _ => unreachable!(),
                                })
                                .collect::<Vec<_>>();
                            match &mut ty {
                                CheckedType::Tuple(elements) => *elements = children,
                                CheckedType::Nominal(nominal) => nominal.arguments = children,
                                CheckedType::Function(item) => {
                                    let mut children = children.into_iter();
                                    **item = item
                                        .map_types(|_| children.next().expect("function actual"));
                                }
                                _ => unreachable!(),
                            }
                            SelectionValue::Type(ty)
                        }),
                    ));
                }
                SelectionFrame::Project(goal, mut projection) => {
                    match values.pop().expect("projection evidence") {
                        Err(error) => finished = Some((goal, Err(error))),
                        Ok(SelectionValue::Evidence(index)) => {
                            let (selected, abstract_evidence) = match &self.evidence[index] {
                                Evidence::Given(given)
                                | Evidence::Associated {
                                    requirement: given, ..
                                } => {
                                    projection.subject = given.subject.clone();
                                    (
                                        given.bound.associated.get(&projection.member).cloned(),
                                        true,
                                    )
                                }
                                Evidence::Implementation {
                                    identity, mapping, ..
                                } => (
                                    self.declarations.implementations[identity]
                                        .associated
                                        .get(&projection.member)
                                        .map(|ty| instantiate_type(ty, mapping)),
                                    false,
                                ),
                                Evidence::Primitive { .. } => (None, false),
                            };
                            if let Some(selected) = selected {
                                frames.push(SelectionFrame::FinishProjection(goal));
                                frames.push(SelectionFrame::Enter(SelectionGoal::Type(selected)));
                            } else if abstract_evidence {
                                finished = Some((
                                    goal,
                                    Ok(SelectionValue::Type(CheckedType::Projection(Box::new(
                                        projection,
                                    )))),
                                ));
                            } else {
                                finished = Some((goal, Err(self.failure(SelectionFailureKind::Conflict,
                                "selected evidence has no required associated type assignment", Vec::new()))));
                            }
                        }
                        _ => unreachable!(),
                    }
                }
                SelectionFrame::FinishProjection(goal) => {
                    finished = Some((goal, values.pop().expect("projection value")))
                }
                SelectionFrame::Choose(goal, mut bound, count)
                | SelectionFrame::FinishRequirement(goal, mut bound, count) => {
                    match values
                        .split_off(values.len() - count)
                        .into_iter()
                        .collect::<Result<Vec<_>, _>>()
                    {
                        Err(error) => finished = Some((goal, Err(error))),
                        Ok(operands) => {
                            let mut operands = operands.into_iter().map(|value| match value {
                                SelectionValue::Type(ty) => ty,
                                _ => unreachable!(),
                            });
                            let subject = operands.next().expect("requirement subject");
                            for ty in bound
                                .arguments
                                .iter_mut()
                                .chain(bound.associated.values_mut())
                            {
                                *ty = operands.next().expect("requirement operand");
                            }
                            if matches!(goal, SelectionGoal::NormalizeRequirement(_, _)) {
                                finished = Some((
                                    goal,
                                    Ok(SelectionValue::Requirement(subject, Box::new(bound))),
                                ));
                            } else if self.primitive_evidence(&subject, &bound) {
                                let index = self.evidence.len();
                                self.evidence.push(Evidence::Primitive {
                                    subject,
                                    declaration: bound.declaration,
                                });
                                finished = Some((goal, Ok(SelectionValue::Evidence(index))));
                            } else {
                                let mut candidates = self
                                    .givens
                                    .iter()
                                    .filter(|given| given.bound.declaration == bound.declaration)
                                    .cloned()
                                    .map(|requirement| GivenCandidate {
                                        requirement,
                                        parent: None,
                                    })
                                    .collect::<Vec<_>>();
                                if let SelectionGoal::Evidence(
                                    CheckedType::Projection(projection),
                                    _,
                                ) = &goal
                                    && let ProjectionOwner::Trait(projected_trait) =
                                        &projection.owner
                                {
                                    let definition =
                                        &self.declarations.traits[&projected_trait.declaration];
                                    let mapping =
                                        definition.mapping(&projection.subject, projected_trait);
                                    let givens = definition.associated[&projection.member]
                                        .bounds
                                        .iter()
                                        .map(|bound| Requirement {
                                            subject: subject.clone(),
                                            bound: bound.instantiate(&mapping),
                                            origin: self.origin.clone(),
                                        })
                                        .collect::<Vec<_>>();
                                    let mut derived_inference = self.inference.clone();
                                    let derived = SelectionSolver::new(
                                        self.declarations,
                                        self.core,
                                        &givens,
                                        self.origin.clone(),
                                        &mut derived_inference,
                                    )?;
                                    self.charge(derived.work)?;
                                    candidates.extend(
                                        derived
                                            .givens
                                            .into_iter()
                                            .filter(|given| {
                                                given.bound.declaration == bound.declaration
                                            })
                                            .map(|requirement| GivenCandidate {
                                                requirement,
                                                parent: Some(Requirement {
                                                    subject: projection.subject.clone(),
                                                    bound: projected_trait.clone(),
                                                    origin: self.origin.clone(),
                                                }),
                                            }),
                                    );
                                }
                                let tasks = candidates
                                    .iter()
                                    .rev()
                                    .map(|candidate| {
                                        SelectionFrame::Enter(SelectionGoal::NormalizeRequirement(
                                            candidate.requirement.subject.clone(),
                                            Box::new(candidate.requirement.bound.clone()),
                                        ))
                                    })
                                    .collect::<Vec<_>>();
                                frames
                                    .push(SelectionFrame::Givens(goal, subject, bound, candidates));
                                frames.extend(tasks);
                            }
                        }
                    }
                }
                SelectionFrame::Givens(goal, subject, bound, candidates) => {
                    let operands = values.split_off(values.len() - candidates.len());
                    let base = self.inference.clone();
                    let mut selected = None;
                    let mut failure = None;
                    for (candidate, operand) in candidates.into_iter().zip(operands) {
                        *self.inference = base.clone();
                        match operand {
                            Ok(SelectionValue::Requirement(actual, normalized)) => {
                                if bound
                                    .associated
                                    .keys()
                                    .any(|member| !normalized.associated.contains_key(member))
                                {
                                    continue;
                                }
                                let pairs =
                                    std::iter::once((&actual, &subject))
                                        .chain(normalized.arguments.iter().zip(&bound.arguments))
                                        .chain(bound.associated.iter().map(|(member, ty)| {
                                            (&normalized.associated[member], ty)
                                        }));
                                match pairs
                                    .into_iter()
                                    .try_for_each(|(a, b)| self.constrain(a, b, false))
                                {
                                    Ok(()) => {
                                        let solved = self.canonical_goal(SelectionGoal::evidence(
                                            subject.clone(),
                                            bound.clone(),
                                        ));
                                        if let Some((_, _, _, previous)) = &selected
                                            && *previous != solved
                                        {
                                            failure = Some(self.failure(SelectionFailureKind::Incomplete, "selection proof incomplete: given evidence leaves multiple possible actuals", Vec::new()));
                                            selected = None;
                                            break;
                                        }
                                        selected.get_or_insert((
                                            Requirement {
                                                subject: actual,
                                                bound: *normalized,
                                                origin: candidate.requirement.origin,
                                            },
                                            candidate.parent,
                                            self.inference.clone(),
                                            solved,
                                        ));
                                    }
                                    Err(error)
                                        if error.kind == SelectionFailureKind::NotApplicable => {}
                                    Err(error) => {
                                        failure.get_or_insert(error);
                                    }
                                }
                            }
                            Err(error) => {
                                failure.get_or_insert(error);
                            }
                            _ => unreachable!(),
                        }
                    }
                    *self.inference = base;
                    complete.clear();
                    if let Some((requirement, parent, inference, _)) = selected {
                        *self.inference = inference;
                        let requirement = requirement.map_types(|ty| self.inference.canonical(ty));
                        if let Some(parent) = parent {
                            frames.push(SelectionFrame::Derived(goal, requirement));
                            frames.push(SelectionFrame::Enter(SelectionGoal::evidence(
                                parent.subject,
                                parent.bound,
                            )));
                        } else {
                            let index = self.evidence.len();
                            self.evidence.push(Evidence::Given(requirement));
                            finished = Some((goal, Ok(SelectionValue::Evidence(index))));
                        }
                    } else if let Some(error) = failure {
                        finished = Some((goal, Err(error)));
                    } else {
                        frames.push(SelectionFrame::Implementations(goal, subject, bound));
                    }
                }
                SelectionFrame::Derived(goal, requirement) => {
                    let result = values.pop().expect("associated parent").map(|value| {
                        let SelectionValue::Evidence(parent) = value else {
                            unreachable!()
                        };
                        let index = self.evidence.len();
                        self.evidence.push(Evidence::Associated {
                            requirement,
                            parent,
                        });
                        SelectionValue::Evidence(index)
                    });
                    finished = Some((goal, result));
                }
                SelectionFrame::Implementations(goal, subject, bound) => {
                    if matches!(self.inference.canonical(&subject), CheckedType::Infer(_)) {
                        finished = Some((goal, Err(self.failure(SelectionFailureKind::Incomplete,
                            "selection proof incomplete: receiver dependencies remain undetermined", Vec::new()))));
                    } else {
                        let candidates = self
                            .declarations
                            .implementations
                            .values()
                            .filter(|implementation| {
                                implementation
                                    .trait_use
                                    .as_ref()
                                    .is_some_and(|implemented| {
                                        implemented.declaration == bound.declaration
                                    })
                            })
                            .map(|implementation| implementation.identity.clone())
                            .collect::<Vec<_>>();
                        if candidates.is_empty() {
                            let kind = if matches!(subject, CheckedType::Projection(_)) {
                                SelectionFailureKind::Incomplete
                            } else {
                                SelectionFailureKind::NotApplicable
                            };
                            finished = Some((
                                goal,
                                Err(self.failure(
                                    kind,
                                    format!(
                                        "no evidence for {}: {}",
                                        display_type(&subject),
                                        bound.declaration.name
                                    ),
                                    Vec::new(),
                                )),
                            ));
                        } else {
                            frames.push(SelectionFrame::Candidates(goal, candidates.len()));
                            frames.extend(candidates.into_iter().rev().map(|identity| {
                                SelectionFrame::BeginTrial(ImplementationRequest {
                                    identity,
                                    subject: subject.clone(),
                                    bound: Some(bound.clone()),
                                })
                            }));
                        }
                    }
                }
                SelectionFrame::BeginTrial(request) => {
                    frames.push(SelectionFrame::EndTrial(Box::new(self.snapshot())));
                    frames.push(SelectionFrame::Enter(SelectionGoal::Applicable(Box::new(
                        request,
                    ))));
                }
                SelectionFrame::EndTrial(base) => {
                    let result = values.pop().expect("candidate result").map(|value| {
                        let SelectionValue::Evidence(evidence) = value else {
                            unreachable!()
                        };
                        SelectionValue::Candidate(Box::new(CandidateSolution {
                            state: self.snapshot(),
                            evidence,
                        }))
                    });
                    self.restore(*base);
                    complete.clear();
                    values.push(result);
                }
                SelectionFrame::Candidate(work) => {
                    let mut operands = values
                        .split_off(
                            values.len() - work.equalities.len() * 2 - work.requirements.len(),
                        )
                        .into_iter();
                    let mut pending = None;
                    let mut failed = None;
                    for equation in &work.equalities {
                        match (
                            operands.next().expect("left"),
                            operands.next().expect("right"),
                        ) {
                            (Ok(SelectionValue::Type(left)), Ok(SelectionValue::Type(right))) => {
                                if let Err(error) = self.constrain_equation(
                                    &TypeEquation {
                                        actual: left,
                                        expected: right,
                                        widening: equation.widening,
                                    },
                                    false,
                                ) {
                                    if error.kind == SelectionFailureKind::NotApplicable
                                        || error.kind == SelectionFailureKind::Conflict
                                    {
                                        failed.get_or_insert(error);
                                    } else {
                                        pending.get_or_insert(error);
                                    }
                                }
                            }
                            (Err(error), _) | (_, Err(error)) => {
                                if error.kind == SelectionFailureKind::NotApplicable
                                    || error.kind == SelectionFailureKind::Conflict
                                {
                                    failed.get_or_insert(error);
                                } else {
                                    pending.get_or_insert(error);
                                }
                            }
                            _ => unreachable!(),
                        }
                    }
                    let mut proofs = Vec::new();
                    for operand in operands {
                        match operand {
                            Ok(SelectionValue::Evidence(index)) => proofs.push(index),
                            Err(error) => {
                                if error.kind == SelectionFailureKind::NotApplicable
                                    || error.kind == SelectionFailureKind::Conflict
                                {
                                    failed.get_or_insert(error);
                                } else {
                                    pending.get_or_insert(error);
                                }
                            }
                            _ => unreachable!(),
                        }
                    }
                    if let Some(error) = failed {
                        finished = Some((work.goal, Err(error)));
                    } else if let Some(error) = pending {
                        if self.candidate_progress(&work) != work.progress {
                            self.schedule_candidate(*work, &mut frames);
                        } else {
                            finished = Some((work.goal, Err(error)));
                        }
                    } else if let Some(identity) = &work.identity {
                        let mapping = work
                            .mapping
                            .iter()
                            .map(|(formal, ty)| (formal.clone(), self.inference.canonical(ty)))
                            .collect();
                        match self.require_owner_actuals(identity, &mapping) {
                            Err(error) => finished = Some((work.goal, Err(error))),
                            Ok(()) => {
                                let index = self.evidence.len();
                                self.evidence.push(Evidence::Implementation {
                                    identity: identity.clone(),
                                    mapping,
                                    requirements: proofs,
                                });
                                finished = Some((work.goal, Ok(SelectionValue::Evidence(index))));
                            }
                        }
                    } else {
                        finished = Some((work.goal, Ok(SelectionValue::Constraints)));
                    }
                }
                SelectionFrame::Candidates(goal, count) => {
                    let operands = values.split_off(values.len() - count);
                    let mut selected = None;
                    let mut unresolved = None;
                    let mut negative = None;
                    let mut multiple = false;
                    for operand in operands {
                        match operand {
                            Ok(SelectionValue::Candidate(candidate)) => {
                                if selected.is_some() {
                                    multiple = true;
                                } else {
                                    selected = Some(candidate);
                                }
                            }
                            Err(error) if error.kind == SelectionFailureKind::NotApplicable => {
                                negative = Some(error)
                            }
                            Err(error) => {
                                unresolved.get_or_insert(error);
                            }
                            _ => unreachable!(),
                        }
                    }
                    if multiple {
                        finished = Some((
                            goal,
                            Err(self.failure(
                                SelectionFailureKind::Conflict,
                                "conflicting applicable impls prevent unique evidence selection",
                                Vec::new(),
                            )),
                        ));
                    } else if let Some(error) = unresolved {
                        finished = Some((goal, Err(error)));
                    } else if let Some(candidate) = selected {
                        let index = candidate.evidence;
                        self.restore(candidate.state);
                        complete.clear();
                        finished = Some((goal, Ok(SelectionValue::Evidence(index))));
                    } else {
                        finished = Some((goal, Err(negative.expect("no applicable candidate"))));
                    }
                }
            }
            if let Some((goal, result)) = finished {
                active.remove(&goal);
                if let Ok(value) = &result {
                    complete.insert(goal, value.clone());
                }
                values.push(result);
            }
        }
        assert_eq!(values.len(), 1);
        values.pop().expect("one query result")
    }
    pub(super) fn primitive_evidence(&self, subject: &CheckedType, bound: &TraitUse) -> bool {
        if !bound.arguments.is_empty() || !bound.associated.is_empty() {
            return false;
        }
        if matches!(subject, CheckedType::Function(_))
            && [&self.core.function, &self.core.fn_mut, &self.core.fn_once]
                .contains(&&bound.declaration)
        {
            return true;
        }
        let partial = bound.declaration == self.core.partial_eq.declaration
            || bound.declaration == self.core.partial_ord.declaration;
        let total =
            bound.declaration == self.core.eq || bound.declaration == self.core.ord.declaration;
        matches!(
            subject,
            CheckedType::Int | CheckedType::Bool | CheckedType::Unit
        ) && (partial || total)
            || matches!(subject, CheckedType::Float) && partial
    }
}

#[derive(Clone, Copy)]
enum CoherenceRelation {
    Compatible,
    Disjoint,
    Incomplete,
}

fn coherence_operand(
    solver: &mut SelectionSolver<'_>,
    ty: &CheckedType,
    mapping: &BTreeMap<TypeFormal, CheckedType>,
    incomplete: &mut bool,
) -> SelectionResult<CheckedType> {
    let normalized = match solver.normalize(ty) {
        Ok(ty) => ty,
        Err(failure)
            if matches!(
                failure.kind,
                SelectionFailureKind::NotApplicable | SelectionFailureKind::Incomplete
            ) =>
        {
            *incomplete = true;
            ty.clone()
        }
        Err(failure) => return Err(failure),
    };
    Ok(instantiate_type(&normalized, mapping))
}

fn compare_coherence_types(
    left: &CheckedType,
    right: &CheckedType,
    inference: &mut TypeInference,
) -> CoherenceRelation {
    let mut pairs = vec![(left.clone(), right.clone())];
    let mut incomplete = false;
    while let Some((left, right)) = pairs.pop() {
        let left = inference.resolve(&left);
        let right = inference.resolve(&right);
        if left == right {
            continue;
        }
        match (&left, &right) {
            (CheckedType::Projection(_) | CheckedType::Formal(_) | CheckedType::Function(_), _)
            | (_, CheckedType::Projection(_) | CheckedType::Formal(_) | CheckedType::Function(_)) => {
                incomplete = true
            }
            (CheckedType::Nominal(left), CheckedType::Nominal(right))
                if left.declaration == right.declaration =>
            {
                pairs.extend(
                    left.arguments
                        .iter()
                        .cloned()
                        .zip(right.arguments.iter().cloned()),
                )
            }
            (CheckedType::Tuple(left), CheckedType::Tuple(right)) if left.len() == right.len() => {
                pairs.extend(left.iter().cloned().zip(right.iter().cloned()))
            }
            (CheckedType::Infer(_), _) | (_, CheckedType::Infer(_)) => {
                if opaque_coherence_type(&left) || opaque_coherence_type(&right) {
                    incomplete = true;
                } else if inference.unify(&left, &right).is_err() {
                    return CoherenceRelation::Disjoint;
                }
            }
            _ => return CoherenceRelation::Disjoint,
        }
    }
    if incomplete {
        CoherenceRelation::Incomplete
    } else {
        CoherenceRelation::Compatible
    }
}

fn opaque_coherence_type(ty: &CheckedType) -> bool {
    let mut types = vec![ty];
    while let Some(ty) = types.pop() {
        match ty {
            CheckedType::Projection(_) | CheckedType::Formal(_) | CheckedType::Function(_) => {
                return true;
            }
            CheckedType::Tuple(elements) => types.extend(elements),
            CheckedType::Nominal(nominal) => types.extend(&nominal.arguments),
            _ => {}
        }
    }
    false
}
