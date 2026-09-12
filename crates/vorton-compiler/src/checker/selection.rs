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
    pub(super) bound: TraitUse,
    pub(super) member: EntityId,
}

#[derive(Clone)]
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

impl SourceTypeNormalizer<'_> {
    pub(super) fn normalize_header_types(
        &self,
        headers: &mut BTreeMap<EntityId, FunctionHeader>,
        inference: &TypeInference,
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
            )?;
            for parameter in &mut header.parameters {
                parameter.ty = solver.normalize(&inference.canonical(&parameter.ty))?;
            }
            header.return_type = solver.normalize(&inference.canonical(&header.return_type))?;
            for shape in &mut header.shapes {
                shape.subject = solver.normalize(&inference.canonical(&shape.subject))?;
                for (ty, _) in &mut shape.shape.parameters {
                    *ty = solver.normalize(&inference.canonical(ty))?;
                }
                shape.shape.return_type =
                    solver.normalize(&inference.canonical(&shape.shape.return_type))?;
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
    ) -> Result<(), CheckDiagnostic> {
        let mut solver = SelectionSolver::new(
            &self.selection,
            &self.project.core_roles,
            givens,
            origin.clone(),
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
                _ => {}
            }
        }
        Ok(())
    }

    pub(super) fn validate_declaration_formations(
        &self,
        headers: &BTreeMap<EntityId, FunctionHeader>,
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
            )?;
        }
        for (identity, definition) in &self.selection.traits {
            let origin = CheckOrigin::Source(entity_origin(identity).expect("trait declaration"));
            let subject = CheckedType::Formal(Box::new(definition.self_formal.clone()));
            let mut givens = definition.requirements.clone();
            givens.push(Requirement {
                subject,
                bound: TraitUse {
                    declaration: identity.clone(),
                    arguments: definition
                        .formals
                        .iter()
                        .cloned()
                        .map(|formal| CheckedType::Formal(Box::new(formal)))
                        .collect(),
                    associated: BTreeMap::new(),
                },
                origin: origin.clone(),
            });
            let mut solver = SelectionSolver::new(
                &self.selection,
                &self.project.core_roles,
                &givens,
                origin.clone(),
            )?;
            for associated in definition.associated.values() {
                if let Some(default) = &associated.default {
                    self.validate_formation(
                        std::slice::from_ref(default),
                        &givens,
                        origin.clone(),
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
            self.validate_formation(
                std::slice::from_ref(&implementation.target),
                &implementation.requirements,
                CheckOrigin::Source(
                    entity_origin(&implementation.identity).expect("impl declaration"),
                ),
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
            )?;
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

    pub(super) fn validate_surfaces(
        &self,
        headers: &BTreeMap<EntityId, FunctionHeader>,
        exports: &BTreeSet<EntityId>,
    ) -> Result<(), CheckDiagnostic> {
        let bound = |bound: &TraitUse, origin: &OriginRef| -> Result<(), CheckDiagnostic> {
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
        let requirements =
            |requirements: &[Requirement], origin: &OriginRef| -> Result<(), CheckDiagnostic> {
                for requirement in requirements {
                    validate_public_nominals(&requirement.subject, exports, origin)?;
                    bound(&requirement.bound, origin)?;
                }
                Ok(())
            };
        for (identity, definition) in &self.selection.traits {
            if !exports.contains(identity) {
                continue;
            }
            let origin = entity_origin(identity).expect("trait declaration");
            requirements(&definition.requirements, &origin)?;
            for associated in definition.associated.values() {
                for requirement in &associated.bounds {
                    bound(requirement, &origin)?;
                }
                if let Some(ty) = &associated.default {
                    validate_public_nominals(ty, exports, &origin)?;
                }
            }
        }
        for (identity, definition) in &self.nominals {
            if exports.contains(identity) {
                requirements(
                    &definition.requirements,
                    &entity_origin(identity).expect("nominal declaration"),
                )?;
            }
        }
        for implementation in self.selection.implementations.values() {
            let origin = entity_origin(&implementation.identity).expect("impl declaration");
            if validate_public_nominals(&implementation.target, exports, &origin).is_err() {
                continue;
            }
            let exposed = implementation
                .trait_use
                .as_ref()
                .is_some_and(|bound| exports.contains(&bound.declaration));
            if exposed {
                requirements(&implementation.requirements, &origin)?;
                for ty in implementation.associated.values() {
                    validate_public_nominals(ty, exports, &origin)?;
                }
            }
        }
        for header in headers.values().filter(|header| header.public_export) {
            requirements(&header.requirements, &header.origin)?;
            let mut rows = header
                .effect_upper
                .iter()
                .chain(&header.trait_upper)
                .collect::<Vec<_>>();
            for shape in &header.shapes {
                validate_public_nominals(&shape.subject, exports, &header.origin)?;
                for (ty, _) in &shape.shape.parameters {
                    validate_public_nominals(ty, exports, &header.origin)?;
                }
                validate_public_nominals(&shape.shape.return_type, exports, &header.origin)?;
                rows.push(&shape.shape.effect);
            }
            for row in rows {
                self.validate_effect_visibility(row, exports, &header.origin)?;
            }
        }
        Ok(())
    }

    pub(super) fn select_method(
        &self,
        subject: &CheckedType,
        member: &ResolvedSelection,
        caller: &FunctionHeader,
    ) -> Result<(EntityId, BTreeMap<TypeFormal, CheckedType>), CheckDiagnostic> {
        let mut solver = SelectionSolver::new(
            &self.selection,
            &self.project.core_roles,
            &caller.requirements,
            CheckOrigin::Source(member.origin.clone()),
        )?;
        let subject = solver.normalize(subject)?;
        let mut candidates = Vec::new();
        if matches!(subject, CheckedType::Formal(_) | CheckedType::Projection(_)) {
            let mut givens = solver.givens.clone();
            if let CheckedType::Projection(projection) = &subject {
                let definition = &self.selection.traits[&projection.bound.declaration];
                let mapping = definition.mapping(&projection.subject, &projection.bound);
                let associated = definition.associated[&projection.member]
                    .bounds
                    .iter()
                    .map(|bound| Requirement {
                        subject: subject.clone(),
                        bound: bound.instantiate(&mapping),
                        origin: CheckOrigin::Source(member.origin.clone()),
                    })
                    .collect::<Vec<_>>();
                let derived = SelectionSolver::new(
                    &self.selection,
                    &self.project.core_roles,
                    &associated,
                    CheckOrigin::Source(member.origin.clone()),
                )?;
                givens.extend(derived.givens);
            }
            for given in &givens {
                if given.subject != subject {
                    continue;
                }
                let definition = &self.selection.traits[&given.bound.declaration];
                if let Some(method) = definition.methods.get(&member.name) {
                    candidates.push((method.clone(), definition.mapping(&subject, &given.bound)));
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
                let mut mapping = BTreeMap::new();
                if solver.matches(
                    &implementation.target,
                    &subject,
                    &implementation.formals,
                    &mut mapping,
                )? {
                    for requirement in &implementation.requirements {
                        solver.prove(&requirement.instantiate(&mapping))?;
                    }
                    candidates.push((method.clone(), mapping));
                }
            }
            if candidates.is_empty() {
                for (trait_id, definition) in &self.selection.traits {
                    let Some(method) = definition.methods.get(&member.name) else {
                        continue;
                    };
                    if !self.project.entities[trait_id].public
                        && !caller.identity.module.is_descendant_of(&trait_id.module)
                    {
                        continue;
                    }
                    // Trait actuals come from applicable headers, never from the
                    // spelling of a receiver or from a method result type.
                    let mut bounds = Vec::new();
                    for implementation in self.selection.implementations.values() {
                        let Some(bound) = &implementation.trait_use else {
                            continue;
                        };
                        if bound.declaration != *trait_id {
                            continue;
                        }
                        let mut mapping = BTreeMap::new();
                        if !solver.matches(
                            &implementation.target,
                            &subject,
                            &implementation.formals,
                            &mut mapping,
                        )? {
                            continue;
                        }
                        let mut referenced = BTreeSet::new();
                        let inference = TypeInference::default();
                        for ty in &bound.arguments {
                            inference.referenced_formals(ty, &mut referenced);
                        }
                        if referenced.iter().any(|formal| {
                            implementation.formals.contains(formal) && !mapping.contains_key(formal)
                        }) {
                            // This uniquely named impl still has ordinary type
                            // actuals to infer from the call's shared mapping.
                            candidates
                                .push((implementation.methods[&member.name].clone(), mapping));
                        } else {
                            bounds.push(bound.instantiate(&mapping));
                        }
                    }
                    if definition.formals.is_empty() {
                        bounds.push(TraitUse {
                            declaration: trait_id.clone(),
                            arguments: Vec::new(),
                            associated: BTreeMap::new(),
                        });
                    }
                    bounds.sort();
                    bounds.dedup();
                    for bound in bounds {
                        let requirement = Requirement {
                            subject: subject.clone(),
                            bound: bound.clone(),
                            origin: CheckOrigin::Source(member.origin.clone()),
                        };
                        let index = match solver.prove(&requirement) {
                            Ok(index) => index,
                            Err(diagnostic)
                                if diagnostic.message.starts_with("no evidence for ") =>
                            {
                                continue;
                            }
                            Err(diagnostic) => return Err(diagnostic),
                        };
                        match &solver.evidence[index] {
                            Evidence::Implementation {
                                identity, mapping, ..
                            } => candidates.push((
                                self.selection.implementations[identity].methods[&member.name]
                                    .clone(),
                                mapping.clone(),
                            )),
                            Evidence::Primitive { .. }
                            | Evidence::Given(_)
                            | Evidence::Associated { .. } => candidates
                                .push((method.clone(), definition.mapping(&subject, &bound))),
                        }
                    }
                }
            }
        }
        candidates.sort();
        candidates.dedup();
        let [(method, mapping)] = candidates.as_slice() else {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                if candidates.is_empty() {
                    "method has no evidence in the declared receiver domain"
                } else {
                    "method selection is ambiguous"
                },
                member.origin.clone(),
                candidates
                    .iter()
                    .filter_map(|(method, _)| entity_origin(method))
                    .collect(),
            ));
        };
        Ok((method.clone(), mapping.clone()))
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
                let mut solver = SelectionSolver::new(
                    &self.selection,
                    &self.project.core_roles,
                    &implementation.requirements,
                    CheckOrigin::Source(origin.clone()),
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
                let mut pairs = vec![(
                    instantiate_type(&left.target, &mapping),
                    instantiate_type(&right.target, &mapping),
                )];
                if let (Some(left), Some(right)) = (&left.trait_use, &right.trait_use) {
                    pairs.extend(left.arguments.iter().zip(&right.arguments).map(
                        |(left, right)| {
                            (
                                instantiate_type(left, &mapping),
                                instantiate_type(right, &mapping),
                            )
                        },
                    ));
                }
                let mut disjoint = false;
                let mut projection = false;
                while let Some((left_type, right_type)) = pairs.pop() {
                    let left_type = inference.resolve(&left_type);
                    let right_type = inference.resolve(&right_type);
                    match (&left_type, &right_type) {
                        (CheckedType::Projection(_), _) | (_, CheckedType::Projection(_))
                            if left_type != right_type =>
                        {
                            projection = true
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
                        (CheckedType::Tuple(left), CheckedType::Tuple(right))
                            if left.len() == right.len() =>
                        {
                            pairs.extend(left.iter().cloned().zip(right.iter().cloned()))
                        }
                        _ => {
                            if inference.unify(&left_type, &right_type).is_err() {
                                disjoint = true;
                                break;
                            }
                        }
                    }
                }
                if disjoint {
                    continue;
                }
                // A shared associated type cannot equal incompatible rigid
                // values. Absence of an impl is never a disjointness proof.
                let predicates = left
                    .requirements
                    .iter()
                    .chain(&right.requirements)
                    .map(|requirement| {
                        requirement
                            .instantiate(&mapping)
                            .map_types(|ty| inference.resolve(ty))
                    })
                    .collect::<Vec<_>>();
                for (index, first) in predicates.iter().enumerate() {
                    for second in &predicates[index + 1..] {
                        if first.subject == second.subject
                            && first.bound.declaration == second.bound.declaration
                            && first.bound.arguments == second.bound.arguments
                        {
                            for (member, first_type) in &first.bound.associated {
                                if let Some(second_type) = second.bound.associated.get(member) {
                                    let mut variables = BTreeSet::new();
                                    inference.unresolved_variables(first_type, &mut variables);
                                    inference.unresolved_variables(second_type, &mut variables);
                                    if variables.is_empty()
                                        && first_type != second_type
                                        && !matches!(first_type, CheckedType::Projection(_))
                                        && !matches!(second_type, CheckedType::Projection(_))
                                    {
                                        disjoint = true;
                                    }
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
                )?;
                conform_callback_shapes(&expected, actual, &mapping, &mut solver, inference)?;
                for requirement in &actual.requirements {
                    solver.prove(requirement)?;
                }
                for (parameter, required) in actual.parameters.iter_mut().zip(&expected.parameters)
                {
                    let ty = solver.normalize(&instantiate_type(&required.ty, &mapping))?;
                    if parameter.source_type_explicit {
                        let actual_type = solver.normalize(&parameter.ty)?;
                        inference.unify(&actual_type, &ty).map_err(|failure| {
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
                    .expect("associated member has an owner")
                    .clone();
                if let Some(definition) = self.selection.traits.get(&owner) {
                    return Ok(CheckedType::Projection(Box::new(Projection {
                        subject: CheckedType::Formal(Box::new(definition.self_formal.clone())),
                        bound: TraitUse {
                            declaration: owner,
                            arguments: definition
                                .formals
                                .iter()
                                .cloned()
                                .map(|formal| CheckedType::Formal(Box::new(formal)))
                                .collect(),
                            associated: BTreeMap::new(),
                        },
                        member: target.clone(),
                    })));
                }
                let implementation = &self.selection.implementations[&owner];
                let subject = implementation.target.clone();
                let bound = implementation.trait_use.clone().unwrap_or(TraitUse {
                    declaration: owner,
                    arguments: Vec::new(),
                    associated: BTreeMap::new(),
                });
                let member =
                    self.associated_member(&bound.declaration, &target.name, occurrence.clone())?;
                Ok(CheckedType::Projection(Box::new(Projection {
                    subject,
                    bound,
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
                                    .map(|requirement| requirement.bound.clone()),
                            );
                        }
                        let bounds = self
                            .generic_bounds
                            .get(formal.as_ref())
                            .cloned()
                            .unwrap_or_default();
                        for named in bounds {
                            candidates.push(self.normalize_trait_use(&named, formals)?);
                        }
                        if let Some((identity, definition)) = self
                            .selection
                            .traits
                            .iter()
                            .find(|(_, definition)| &definition.self_formal == formal.as_ref())
                        {
                            candidates.push(TraitUse {
                                declaration: identity.clone(),
                                arguments: definition
                                    .formals
                                    .iter()
                                    .cloned()
                                    .map(|formal| CheckedType::Formal(Box::new(formal)))
                                    .collect(),
                                associated: BTreeMap::new(),
                            });
                        }
                    } else if let CheckedType::Projection(projection) = &subject {
                        if let Some(definition) =
                            self.selection.traits.get(&projection.bound.declaration)
                        {
                            let mapping =
                                definition.mapping(&projection.subject, &projection.bound);
                            if let Some(associated) = definition.associated.get(&projection.member)
                            {
                                candidates.extend(
                                    associated
                                        .bounds
                                        .iter()
                                        .map(|bound| bound.instantiate(&mapping)),
                                );
                            }
                        }
                    } else {
                        for implementation in self.selection.implementations.values() {
                            let mut solver = SelectionSolver::new(
                                &self.selection,
                                &self.project.core_roles,
                                &[],
                                CheckOrigin::Source(member.origin.clone()),
                            )?;
                            let mut mapping = BTreeMap::new();
                            if solver.matches(
                                &implementation.target,
                                &subject,
                                &implementation.formals,
                                &mut mapping,
                            )? {
                                candidates.push(
                                    implementation
                                        .trait_use
                                        .as_ref()
                                        .map(|bound| bound.instantiate(&mapping))
                                        .unwrap_or(TraitUse {
                                            declaration: implementation.identity.clone(),
                                            arguments: Vec::new(),
                                            associated: BTreeMap::new(),
                                        }),
                                );
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
                        let bound = candidates[next].clone();
                        next += 1;
                        if let Some(definition) = self.selection.traits.get(&bound.declaration) {
                            let mapping = definition.mapping(&subject, &bound);
                            for requirement in &definition.requirements {
                                let requirement = requirement.instantiate(&mapping);
                                if requirement.subject == subject
                                    && !candidates.contains(&requirement.bound)
                                {
                                    candidates.push(requirement.bound);
                                }
                            }
                        }
                    }
                    candidates.retain(|bound| {
                        self.project.entities[&bound.declaration]
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
                    let [bound] = candidates.as_slice() else {
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
                                .filter_map(|bound| entity_origin(&bound.declaration))
                                .collect(),
                        ));
                    };
                    let exact = self.associated_member(
                        &bound.declaration,
                        &member.name,
                        member.origin.clone(),
                    )?;
                    subject = CheckedType::Projection(Box::new(Projection {
                        subject,
                        bound: bound.clone(),
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
    InherentProjection(SelectionGoal, CheckedType, usize),
    Choose(SelectionGoal, TraitUse, usize),
    Derived(SelectionGoal, Requirement),
    Candidate(EntityId, BTreeMap<TypeFormal, CheckedType>, TraitUse, usize),
    Bindings(
        EntityId,
        BTreeMap<TypeFormal, CheckedType>,
        Vec<usize>,
        usize,
    ),
    Candidates(SelectionGoal, usize),
}

#[derive(Clone)]
pub(super) enum SelectionValue {
    Type(CheckedType),
    Evidence(usize),
}

pub(super) struct SelectionSolver<'a> {
    pub(super) declarations: &'a TraitSelection,
    pub(super) core: &'a crate::project::CoreRoles,
    pub(super) givens: Vec<Requirement>,
    pub(super) origin: CheckOrigin,
    pub(super) work: usize,
    pub(super) evidence: Vec<Evidence>,
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
        std::iter::once(&self.subject)
            .chain(&self.bound.arguments)
            .chain(self.bound.associated.values())
    }

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
    ) -> Result<Self, CheckDiagnostic> {
        let mut solver = Self {
            declarations,
            core,
            givens: givens.to_vec(),
            origin,
            work: 0,
            evidence: Vec::new(),
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

    pub(super) fn diagnostic(
        &self,
        message: impl Into<String>,
        related: Vec<CheckOrigin>,
    ) -> CheckDiagnostic {
        CheckDiagnostic {
            kind: CheckDiagnosticKind::TypeMismatch,
            message: message.into(),
            primary: Some(self.origin.clone()),
            related,
        }
    }

    pub(super) fn charge(&mut self, count: usize) -> Result<(), CheckDiagnostic> {
        self.work = self.work.saturating_add(count);
        if self.work > SELECTION_WORK_LIMIT {
            return Err(self.diagnostic(format!("selection proof incomplete: logical work limit {SELECTION_WORK_LIMIT} exceeded at work {}", self.work), Vec::new()));
        }
        Ok(())
    }

    pub(super) fn normalize(&mut self, ty: &CheckedType) -> Result<CheckedType, CheckDiagnostic> {
        match self.solve(SelectionGoal::Type(ty.clone()))? {
            SelectionValue::Type(ty) => Ok(ty),
            SelectionValue::Evidence(_) => unreachable!("a type query returns a type"),
        }
    }

    pub(super) fn normalize_row(&mut self, row: &EffectRow) -> Result<EffectRow, CheckDiagnostic> {
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

    pub(super) fn prove(&mut self, requirement: &Requirement) -> Result<usize, CheckDiagnostic> {
        match self
            .solve(SelectionGoal::evidence(
                requirement.subject.clone(),
                requirement.bound.clone(),
            ))
            .map_err(|mut diagnostic| {
                if requirement.origin != self.origin
                    && !diagnostic.related.contains(&requirement.origin)
                {
                    diagnostic.related.push(requirement.origin.clone());
                }
                diagnostic
            })? {
            SelectionValue::Evidence(index) => Ok(index),
            SelectionValue::Type(_) => unreachable!("an evidence query returns evidence"),
        }
    }

    pub(super) fn solve(&mut self, root: SelectionGoal) -> Result<SelectionValue, CheckDiagnostic> {
        let mut frames = vec![SelectionFrame::Enter(root)];
        let mut active = BTreeSet::new();
        let mut complete: BTreeMap<SelectionGoal, SelectionValue> = BTreeMap::new();
        let mut values: Vec<Result<SelectionValue, CheckDiagnostic>> = Vec::new();
        while let Some(frame) = frames.pop() {
            self.charge(1)?;
            if active.len() > SELECTION_STATE_LIMIT {
                return Err(self.diagnostic(format!("selection proof incomplete: active state limit {SELECTION_STATE_LIMIT} exceeded after {} logical steps", self.work), Vec::new()));
            }
            let mut finished = None;
            match frame {
                SelectionFrame::Enter(goal) => {
                    if let Some(value) = complete.get(&goal) {
                        values.push(Ok(value.clone()));
                        continue;
                    }
                    if let SelectionGoal::Evidence(subject, bound) = &goal
                        && let Some(given) = self.givens.iter().find(|given| {
                            &given.subject == subject
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
                        values.push(Err(self.diagnostic(
                            "illegal selection or associated-projection cycle without a base fact",
                            Vec::new(),
                        )));
                        continue;
                    }
                    match &goal {
                        SelectionGoal::Type(CheckedType::Tuple(elements)) => {
                            frames.push(SelectionFrame::FinishType(
                                goal.clone(),
                                CheckedType::Tuple(Vec::new()),
                                elements.len(),
                            ));
                            frames.extend(
                                elements
                                    .iter()
                                    .rev()
                                    .cloned()
                                    .map(|ty| SelectionFrame::Enter(SelectionGoal::Type(ty))),
                            );
                        }
                        SelectionGoal::Type(CheckedType::Nominal(nominal)) => {
                            frames.push(SelectionFrame::FinishType(
                                goal.clone(),
                                CheckedType::Nominal(nominal.clone()),
                                nominal.arguments.len(),
                            ));
                            frames.extend(
                                nominal
                                    .arguments
                                    .iter()
                                    .rev()
                                    .cloned()
                                    .map(|ty| SelectionFrame::Enter(SelectionGoal::Type(ty))),
                            );
                        }
                        SelectionGoal::Type(CheckedType::Projection(projection)) => {
                            if let Some(implementation) = self
                                .declarations
                                .implementations
                                .get(&projection.bound.declaration)
                            {
                                let mut mapping = BTreeMap::new();
                                if self.matches(
                                    &implementation.target,
                                    &projection.subject,
                                    &implementation.formals,
                                    &mut mapping,
                                )? {
                                    let selected = instantiate_type(
                                        &implementation.associated[&projection.member],
                                        &mapping,
                                    );
                                    let requirements = implementation
                                        .requirements
                                        .iter()
                                        .map(|requirement| requirement.instantiate(&mapping))
                                        .collect::<Vec<_>>();
                                    frames.push(SelectionFrame::InherentProjection(
                                        goal.clone(),
                                        selected,
                                        requirements.len(),
                                    ));
                                    frames.extend(requirements.into_iter().rev().map(
                                        |requirement| {
                                            SelectionFrame::Enter(SelectionGoal::evidence(
                                                requirement.subject,
                                                requirement.bound,
                                            ))
                                        },
                                    ));
                                } else {
                                    finished = Some((
                                        goal.clone(),
                                        Err(self.diagnostic(
                                            "no evidence for inherent associated owner",
                                            Vec::new(),
                                        )),
                                    ));
                                }
                            } else {
                                frames.push(SelectionFrame::Project(
                                    goal.clone(),
                                    projection.as_ref().clone(),
                                ));
                                frames.push(SelectionFrame::Enter(SelectionGoal::evidence(
                                    projection.subject.clone(),
                                    projection.bound.clone(),
                                )));
                            }
                        }
                        SelectionGoal::Type(ty) => {
                            finished = Some((goal.clone(), Ok(SelectionValue::Type(ty.clone()))))
                        }
                        SelectionGoal::Evidence(subject, bound) => {
                            if let CheckedType::Projection(projection) = subject {
                                let definition =
                                    &self.declarations.traits[&projection.bound.declaration];
                                let mapping =
                                    definition.mapping(&projection.subject, &projection.bound);
                                let associated = &definition.associated[&projection.member];
                                let givens = associated
                                    .bounds
                                    .iter()
                                    .map(|bound| Requirement {
                                        subject: subject.clone(),
                                        bound: bound.instantiate(&mapping),
                                        origin: self.origin.clone(),
                                    })
                                    .collect::<Vec<_>>();
                                let derived = Self::new(
                                    self.declarations,
                                    self.core,
                                    &givens,
                                    self.origin.clone(),
                                )?;
                                self.charge(derived.work)?;
                                if derived.givens.iter().any(|given| {
                                    given.bound.declaration == bound.declaration
                                        && given.bound.arguments == bound.arguments
                                        && bound.associated.iter().all(|(member, ty)| {
                                            given.bound.associated.get(member) == Some(ty)
                                        })
                                }) {
                                    frames.push(SelectionFrame::Derived(
                                        goal.clone(),
                                        Requirement {
                                            subject: subject.clone(),
                                            bound: bound.as_ref().clone(),
                                            origin: self.origin.clone(),
                                        },
                                    ));
                                    frames.push(SelectionFrame::Enter(SelectionGoal::evidence(
                                        projection.subject.clone(),
                                        projection.bound.clone(),
                                    )));
                                    continue;
                                }
                            }
                            let children = std::iter::once(subject)
                                .chain(&bound.arguments)
                                .chain(bound.associated.values())
                                .cloned()
                                .collect::<Vec<_>>();
                            frames.push(SelectionFrame::Choose(
                                goal.clone(),
                                bound.as_ref().clone(),
                                children.len(),
                            ));
                            frames.extend(
                                children
                                    .into_iter()
                                    .rev()
                                    .map(|ty| SelectionFrame::Enter(SelectionGoal::Type(ty))),
                            );
                        }
                    }
                }
                SelectionFrame::FinishType(goal, mut ty, count) => {
                    let operands = values
                        .split_off(values.len() - count)
                        .into_iter()
                        .collect::<Result<Vec<_>, _>>();
                    let result = operands.map(|operands| {
                        let children = operands
                            .into_iter()
                            .map(|value| match value {
                                SelectionValue::Type(ty) => ty,
                                _ => unreachable!(),
                            })
                            .collect();
                        match &mut ty {
                            CheckedType::Tuple(elements) => *elements = children,
                            CheckedType::Nominal(nominal) => nominal.arguments = children,
                            _ => unreachable!(),
                        }
                        SelectionValue::Type(ty)
                    });
                    finished = Some((goal, result));
                }
                SelectionFrame::Project(goal, mut projection) => {
                    match values.pop().expect("projection operand") {
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
                                finished = Some((goal, Err(self.diagnostic("selected evidence has no required associated type assignment", Vec::new()))));
                            }
                        }
                        _ => unreachable!(),
                    }
                }
                SelectionFrame::InherentProjection(goal, selected, count) => {
                    let prerequisites = values
                        .split_off(values.len() - count)
                        .into_iter()
                        .collect::<Result<Vec<_>, _>>();
                    match prerequisites {
                        Err(error) => finished = Some((goal, Err(error))),
                        Ok(_) => {
                            frames.push(SelectionFrame::FinishProjection(goal));
                            frames.push(SelectionFrame::Enter(SelectionGoal::Type(selected)));
                        }
                    }
                }
                SelectionFrame::FinishProjection(goal) => {
                    let result = values.pop().expect("projection value");
                    finished = Some((goal, result));
                }
                SelectionFrame::Derived(goal, requirement) => {
                    let result = values.pop().expect("associated parent").map(|parent| {
                        let SelectionValue::Evidence(parent) = parent else {
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
                SelectionFrame::Choose(goal, mut bound, count) => {
                    let operands = values
                        .split_off(values.len() - count)
                        .into_iter()
                        .collect::<Result<Vec<_>, _>>();
                    match operands {
                        Err(error) => finished = Some((goal, Err(error))),
                        Ok(operands) => {
                            let mut operands = operands.into_iter().map(|value| match value {
                                SelectionValue::Type(ty) => ty,
                                _ => unreachable!(),
                            });
                            let subject = operands.next().expect("receiver type");
                            for ty in bound
                                .arguments
                                .iter_mut()
                                .chain(bound.associated.values_mut())
                            {
                                *ty = operands.next().expect("bound type");
                            }
                            if let Some(given) = self.givens.iter().find(|given| {
                                given.subject == subject
                                    && given.bound.declaration == bound.declaration
                                    && given.bound.arguments == bound.arguments
                                    && bound.associated.iter().all(|(member, ty)| {
                                        given.bound.associated.get(member) == Some(ty)
                                    })
                            }) {
                                let index = self.evidence.len();
                                self.evidence.push(Evidence::Given(given.clone()));
                                finished = Some((goal, Ok(SelectionValue::Evidence(index))));
                            } else if self.primitive_evidence(&subject, &bound) {
                                let index = self.evidence.len();
                                self.evidence.push(Evidence::Primitive {
                                    subject,
                                    declaration: bound.declaration,
                                });
                                finished = Some((goal, Ok(SelectionValue::Evidence(index))));
                            } else {
                                let mut candidates = Vec::new();
                                for implementation in self.declarations.implementations.values() {
                                    let Some(implemented) = &implementation.trait_use else {
                                        continue;
                                    };
                                    if implemented.declaration != bound.declaration {
                                        continue;
                                    }
                                    let mut mapping = BTreeMap::new();
                                    if !self.matches(
                                        &implementation.target,
                                        &subject,
                                        &implementation.formals,
                                        &mut mapping,
                                    )? {
                                        continue;
                                    }
                                    let mut matches = true;
                                    for (pattern, actual) in
                                        implemented.arguments.iter().zip(&bound.arguments)
                                    {
                                        if !self.matches(
                                            pattern,
                                            actual,
                                            &implementation.formals,
                                            &mut mapping,
                                        )? {
                                            matches = false;
                                            break;
                                        }
                                    }
                                    if matches {
                                        candidates.push((implementation.identity.clone(), mapping));
                                    }
                                }
                                if candidates.is_empty() {
                                    let message = if matches!(
                                        subject,
                                        CheckedType::Infer(_) | CheckedType::Projection(_)
                                    ) {
                                        "selection proof incomplete: receiver or associated dependency is not determined".to_owned()
                                    } else {
                                        format!(
                                            "no evidence for {}: {}",
                                            display_type(&subject),
                                            bound.declaration.name
                                        )
                                    };
                                    finished =
                                        Some((goal, Err(self.diagnostic(message, Vec::new()))));
                                } else {
                                    frames.push(SelectionFrame::Candidates(goal, candidates.len()));
                                    for (identity, mapping) in candidates.into_iter().rev() {
                                        let requirements = self.declarations.implementations
                                            [&identity]
                                            .requirements
                                            .iter()
                                            .map(|requirement| requirement.instantiate(&mapping))
                                            .collect::<Vec<_>>();
                                        frames.push(SelectionFrame::Candidate(
                                            identity,
                                            mapping,
                                            bound.clone(),
                                            requirements.len(),
                                        ));
                                        frames.extend(requirements.into_iter().rev().map(
                                            |requirement| {
                                                SelectionFrame::Enter(SelectionGoal::evidence(
                                                    requirement.subject,
                                                    requirement.bound,
                                                ))
                                            },
                                        ));
                                    }
                                }
                            }
                        }
                    }
                }
                SelectionFrame::Candidate(identity, mapping, bound, count) => {
                    let prerequisites = values
                        .split_off(values.len() - count)
                        .into_iter()
                        .collect::<Result<Vec<_>, _>>();
                    match prerequisites {
                        Err(error) => values.push(Err(error)),
                        Ok(prerequisites) => {
                            let requirements = prerequisites
                                .into_iter()
                                .map(|value| match value {
                                    SelectionValue::Evidence(index) => index,
                                    _ => unreachable!(),
                                })
                                .collect();
                            let implementation = &self.declarations.implementations[&identity];
                            let mut pairs = Vec::new();
                            for (member, expected) in &bound.associated {
                                let actual = &implementation.associated[member];
                                pairs.push(instantiate_type(actual, &mapping));
                                pairs.push(expected.clone());
                            }
                            frames.push(SelectionFrame::Bindings(
                                identity,
                                mapping,
                                requirements,
                                pairs.len(),
                            ));
                            frames.extend(
                                pairs
                                    .into_iter()
                                    .rev()
                                    .map(|ty| SelectionFrame::Enter(SelectionGoal::Type(ty))),
                            );
                        }
                    }
                }
                SelectionFrame::Bindings(identity, mapping, requirements, count) => {
                    let operands = values
                        .split_off(values.len() - count)
                        .into_iter()
                        .collect::<Result<Vec<_>, _>>();
                    let result = operands.and_then(|operands| {
                        if operands.as_chunks::<2>().0.iter().any(|pair| !matches!((&pair[0], &pair[1]), (SelectionValue::Type(left), SelectionValue::Type(right)) if left == right)) { return Err(self.diagnostic("no evidence: selected impl does not satisfy the required associated binding", entity_origin(&identity).map(CheckOrigin::Source).into_iter().collect())); }
                        let index = self.evidence.len(); self.evidence.push(Evidence::Implementation { identity, mapping, requirements }); Ok(SelectionValue::Evidence(index))
                    });
                    values.push(result);
                }
                SelectionFrame::Candidates(goal, count) => {
                    let results = values.split_off(values.len() - count);
                    let mut selected = None;
                    let mut negative = None;
                    let mut unresolved = None;
                    for result in results {
                        match result {
                            Ok(value) if selected.is_none() => selected = Some(value),
                            Ok(_) => {
                                unresolved = Some(self.diagnostic("conflicting applicable impls prevent unique evidence selection", Vec::new()));
                            }
                            Err(error) if error.message.starts_with("no evidence") => {
                                negative = Some(error)
                            }
                            Err(error) => unresolved = Some(error),
                        }
                    }
                    let result = if let Some(error) = unresolved {
                        Err(error)
                    } else if let Some(value) = selected {
                        Ok(value)
                    } else {
                        Err(negative.expect("every candidate failed"))
                    };
                    finished = Some((goal, result));
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
        assert_eq!(values.len(), 1, "one selection query returns one value");
        values.pop().expect("one result")
    }

    pub(super) fn matches(
        &mut self,
        pattern: &CheckedType,
        actual: &CheckedType,
        formals: &[TypeFormal],
        mapping: &mut BTreeMap<TypeFormal, CheckedType>,
    ) -> Result<bool, CheckDiagnostic> {
        let mut pending = vec![(pattern, actual)];
        while let Some((pattern, actual)) = pending.pop() {
            self.charge(1)?;
            if let CheckedType::Formal(formal) = pattern
                && formals.contains(formal)
            {
                match mapping.get(formal.as_ref()) {
                    Some(previous) if previous != actual => return Ok(false),
                    Some(_) => {}
                    None => {
                        mapping.insert(formal.as_ref().clone(), actual.clone());
                    }
                }
                continue;
            }
            match (pattern, actual) {
                (CheckedType::Tuple(left), CheckedType::Tuple(right))
                    if left.len() == right.len() =>
                {
                    pending.extend(left.iter().zip(right))
                }
                (CheckedType::Nominal(left), CheckedType::Nominal(right))
                    if left.declaration == right.declaration =>
                {
                    pending.extend(left.arguments.iter().zip(&right.arguments))
                }
                _ if pattern == actual => {}
                _ => return Ok(false),
            }
        }
        Ok(true)
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
