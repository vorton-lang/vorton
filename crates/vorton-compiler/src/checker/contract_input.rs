use super::*;

// Bind the selected input domain before source signatures select T::Item.
// Full records are still grouped and checked before any body constraints.
pub(super) fn prepare_contract_bound_lookup(
    project: &ResolvedProject,
    owners: &BTreeMap<String, LibraryId>,
    documents: &[ContractDocument],
    normalizer: &mut SourceTypeNormalizer<'_>,
) -> Result<(), CheckDiagnostic> {
    if documents.is_empty() {
        return Ok(());
    }
    for (identity, value) in normalizer
        .aliases
        .iter()
        .filter(|(_, alias)| alias.type_parameter_count == 0)
        .map(|(identity, alias)| (identity.clone(), alias.value.clone()))
        .collect::<Vec<_>>()
    {
        let ty = normalizer.normalize(&value)?;
        normalizer.normalized_aliases.insert(identity, ty);
    }
    let headers = BTreeMap::new();
    let mut selected = BTreeMap::<EntityId, (Vec<Requirement>, CheckOrigin)>::new();
    for (document_index, document) in documents.iter().enumerate() {
        let owner = owners
            .get(&document.0.owner)
            .copied()
            .filter(|owner| project.dependencies.contains_key(owner))
            .ok_or_else(|| {
                contract_diagnostic(
                    CheckDiagnosticKind::ContractBinding,
                    "contract owner is not a reachable source library",
                    document_index,
                    "$.owner",
                    Vec::new(),
                )
            })?;
        for (record_index, record) in document.0.records.iter().enumerate() {
            let Some(requirements) = record
                .set
                .as_ref()
                .and_then(|set| set.generic_requirements.as_ref())
            else {
                continue;
            };
            let target = contract_callable_target(
                project,
                owner,
                document_index,
                record_index,
                record,
                normalizer,
            )?;
            let path = format!("$.records[{record_index}].set.generic_requirements");
            let origin = CheckOrigin::Contract {
                document_index,
                json_path: path.clone(),
            };
            let source_origin = entity_origin(&target).expect("source callable");
            let context = ContractTypeContext {
                project,
                owner,
                target: &target,
                formals: &normalizer.owner_formals[&target],
                effect_formals: &[],
                source_origin: &source_origin,
                document_index,
                normalizer,
                headers: &headers,
            };
            let mut traits = Vec::new();
            for (index, requirement) in requirements.iter().enumerate() {
                if let contract::GenericRequirement::Trait { subject, bound } = requirement {
                    let path = format!("{path}[{index}]");
                    traits.push(Requirement {
                        subject: normalize_contract_type(
                            &context,
                            &format!("{path}.subject"),
                            subject,
                        )?,
                        bound: context.trait_use(bound, &format!("{path}.bound"))?,
                        origin: origin.clone(),
                    });
                }
            }
            if let Some((previous, previous_origin)) = selected.get(&target) {
                let keys = |values: &[Requirement]| {
                    values
                        .iter()
                        .map(|value| (value.subject.clone(), value.bound.clone()))
                        .collect::<BTreeSet<_>>()
                };
                if keys(previous) != keys(&traits) {
                    return Err(contract_diagnostic(
                        CheckDiagnosticKind::ContractConflict,
                        "partial records select different generic requirement sets",
                        document_index,
                        path,
                        vec![previous_origin.clone()],
                    ));
                }
            } else {
                selected.insert(target, (traits, origin));
            }
        }
    }
    normalizer.contract_bounds = selected
        .into_iter()
        .map(|(target, (requirements, _))| (target, requirements))
        .collect();
    Ok(())
}

#[derive(Clone, Default)]
pub(super) struct ContractRequirements {
    pub(super) traits: Vec<Requirement>,
    pub(super) shapes: Vec<ShapeRequirement>,
}

impl ContractRequirements {
    pub(super) fn same(&self, other: &Self) -> bool {
        let traits = |requirements: &[Requirement]| {
            requirements
                .iter()
                .map(|requirement| (requirement.subject.clone(), requirement.bound.clone()))
                .collect::<BTreeSet<_>>()
        };
        let shape_equal = |left: &ShapeRequirement, right: &ShapeRequirement| {
            left.subject == right.subject
                && left.shape.parameters == right.shape.parameters
                && left.shape.return_type == right.shape.return_type
                && left.shape.effect == right.shape.effect
        };
        traits(&self.traits) == traits(&other.traits)
            && self
                .shapes
                .iter()
                .all(|left| other.shapes.iter().any(|right| shape_equal(left, right)))
            && other
                .shapes
                .iter()
                .all(|right| self.shapes.iter().any(|left| shape_equal(left, right)))
    }
}

pub(super) fn contract_callable_target(
    project: &ResolvedProject,
    owner: LibraryId,
    document_index: usize,
    record_index: usize,
    record: &contract::Record,
    normalizer: &SourceTypeNormalizer<'_>,
) -> Result<EntityId, CheckDiagnostic> {
    let path = format!("$.records[{record_index}].target");
    if !matches!(&record.target, contract::EntityRef::Declaration { declaration } if matches!(declaration.kind, contract::DeclarationKind::Function))
        && !matches!(
            &record.target,
            contract::EntityRef::TraitMember {
                kind: contract::MemberKind::Method,
                ..
            } | contract::EntityRef::ImplMember {
                kind: contract::MemberKind::Method,
                ..
            }
        )
    {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "this Checker consumes callable records only",
            document_index,
            path,
            Vec::new(),
        ));
    }
    let target =
        bind_contract_entity(project, owner, &record.target, normalizer).map_err(|message| {
            contract_diagnostic(
                CheckDiagnosticKind::ContractBinding,
                message,
                document_index,
                path.clone(),
                Vec::new(),
            )
        })?;
    if target.module.source_library() != Some(owner) {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            "a contract record cannot change the original callable library owner",
            document_index,
            path,
            entity_origin(&target)
                .map(CheckOrigin::Source)
                .into_iter()
                .collect(),
        ));
    }
    Ok(target)
}

pub(super) fn prepare_contract_requirements(
    project: &ResolvedProject,
    owners: &BTreeMap<String, LibraryId>,
    documents: &[ContractDocument],
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    normalizer: &SourceTypeNormalizer<'_>,
) -> Result<BTreeMap<EntityId, (ContractRequirements, CheckOrigin)>, CheckDiagnostic> {
    let mut selected = BTreeMap::<EntityId, (ContractRequirements, CheckOrigin)>::new();
    for (document_index, document) in documents.iter().enumerate() {
        let owner = owners
            .get(&document.0.owner)
            .copied()
            .filter(|owner| project.dependencies.contains_key(owner))
            .ok_or_else(|| {
                contract_diagnostic(
                    CheckDiagnosticKind::ContractBinding,
                    "contract owner is not a reachable source library",
                    document_index,
                    "$.owner",
                    Vec::new(),
                )
            })?;
        for (record_index, record) in document.0.records.iter().enumerate() {
            let target = contract_callable_target(
                project,
                owner,
                document_index,
                record_index,
                record,
                normalizer,
            )?;
            let record_path = format!("$.records[{record_index}]");
            if let Some((path, message)) = first_unsupported_record_clause(record, &record_path) {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    message,
                    document_index,
                    path,
                    Vec::new(),
                ));
            }
            let Some(requirements) = record
                .set
                .as_ref()
                .and_then(|set| set.generic_requirements.as_ref())
            else {
                continue;
            };
            let path = format!("{record_path}.set.generic_requirements");
            let header = headers.get(&target).ok_or_else(|| {
                contract_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "callable signature is outside this Checker",
                    document_index,
                    path.clone(),
                    Vec::new(),
                )
            })?;
            let context = ContractTypeContext {
                project,
                owner,
                target: &target,
                formals: &header.formal_by_identity,
                effect_formals: &header.effect_formals,
                source_origin: &header.origin,
                document_index,
                normalizer,
                headers,
            };
            let requirements = context.requirements(requirements, &path)?;
            let origin = CheckOrigin::Contract {
                document_index,
                json_path: path.clone(),
            };
            if let Some((previous, previous_origin)) = selected.get(&target) {
                if !previous.same(&requirements) {
                    return Err(contract_diagnostic(
                        CheckDiagnosticKind::ContractConflict,
                        "partial records select different generic requirement sets",
                        document_index,
                        path,
                        vec![previous_origin.clone()],
                    ));
                }
            } else {
                selected.insert(target, (requirements, origin));
            }
        }
    }
    for (target, (requirements, origin)) in &selected {
        let header = headers.get_mut(target).expect("bound callable");
        let own = ContractRequirements {
            traits: header.requirements.iter().filter(|requirement| matches!(&requirement.subject, CheckedType::Formal(formal) if formal.owner == *target)).cloned().collect(),
            shapes: header.shapes.clone(),
        };
        if (!own.traits.is_empty() || !own.shapes.is_empty()) && !own.same(requirements) {
            return Err(CheckDiagnostic { kind: CheckDiagnosticKind::Unsupported, message: "different explicit source and contract generic requirements require a defined difference policy".to_owned(), primary: Some(origin.clone()), related: vec![CheckOrigin::Source(header.origin.clone())] });
        }
        header.requirements.retain(|requirement| !matches!(&requirement.subject, CheckedType::Formal(formal) if formal.owner == *target));
        header
            .requirements
            .extend(requirements.traits.iter().cloned());
        header.shapes = requirements.shapes.clone();
        header.inferable_effects.clear();
    }
    Ok(selected)
}

fn contract_library(
    project: &ResolvedProject,
    owner: LibraryId,
    library: &contract::LibraryRef,
) -> Result<LibraryId, String> {
    match library {
        contract::LibraryRef::Current {} => Ok(owner),
        contract::LibraryRef::Dependency { alias } => project.dependencies[&owner]
            .get(&alias.0)
            .copied()
            .ok_or_else(|| {
                format!(
                    "contract dependency alias `{}` is not a direct library edge",
                    alias.0
                )
            }),
    }
}

pub(super) fn bind_contract_entity(
    project: &ResolvedProject,
    owner: LibraryId,
    reference: &contract::EntityRef,
    normalizer: &SourceTypeNormalizer<'_>,
) -> Result<EntityId, String> {
    match reference {
        contract::EntityRef::Declaration { declaration } => {
            let (namespace, kind) = match declaration.kind {
                contract::DeclarationKind::Function => (Namespace::Value, EntityKind::Function),
                contract::DeclarationKind::Trait => (Namespace::Type, EntityKind::Trait),
                contract::DeclarationKind::Struct => (Namespace::Type, EntityKind::Struct),
                contract::DeclarationKind::Enum => (Namespace::Type, EntityKind::Enum),
                contract::DeclarationKind::TypeAlias => (Namespace::Type, EntityKind::TypeAlias),
                _ => return Err("contract declaration kind is outside callable binding".to_owned()),
            };
            let target = lookup_contract_path(
                project,
                owner,
                &declaration.library,
                &declaration.path,
                namespace,
            )?;
            if target.kind != kind {
                return Err(
                    "contract declaration kind differs from the exact source target".to_owned(),
                );
            }
            Ok(target)
        }
        contract::EntityRef::TraitMember {
            owner: trait_ref,
            kind,
            name,
        } => {
            let owner = bind_trait_ref(project, owner, trait_ref)?;
            let kind = match kind {
                contract::MemberKind::Method => EntityKind::Method,
                contract::MemberKind::AssociatedType => EntityKind::AssociatedType,
            };
            project.entities[&owner]
                .members
                .get(&name.0)
                .into_iter()
                .flatten()
                .find(|target| target.kind == kind)
                .cloned()
                .ok_or_else(|| "contract trait member does not exist with that kind".to_owned())
        }
        contract::EntityRef::Impl { implementation } => {
            bind_contract_impl(project, owner, implementation, normalizer)
        }
        contract::EntityRef::ImplMember {
            owner: implementation,
            kind,
            name,
        } => {
            let identity = bind_contract_impl(project, owner, implementation, normalizer)?;
            let kind = match kind {
                contract::MemberKind::Method => EntityKind::Method,
                contract::MemberKind::AssociatedType => EntityKind::AssociatedType,
            };
            let member = project.entities[&identity]
                .members
                .get(&name.0)
                .into_iter()
                .flatten()
                .find(|target| target.kind == kind)
                .cloned()
                .ok_or_else(|| "contract impl member does not exist with that kind".to_owned())?;
            if identity.module.source_library() != Some(owner)
                && normalizer.selection.implementations[&identity]
                    .trait_use
                    .is_none()
                && !project.entities[&member].public
            {
                return Err("contract cannot access a foreign private inherent member".to_owned());
            }
            Ok(member)
        }
    }
}

fn bind_trait_ref(
    project: &ResolvedProject,
    owner: LibraryId,
    reference: &contract::TraitRef,
) -> Result<EntityId, String> {
    let target = lookup_contract_path(
        project,
        owner,
        &reference.library,
        &reference.path,
        Namespace::Type,
    )?;
    if target.kind != EntityKind::Trait {
        return Err("contract trait reference does not select a trait".to_owned());
    }
    Ok(target)
}

fn bind_contract_impl(
    project: &ResolvedProject,
    owner: LibraryId,
    reference: &contract::ImplRef,
    normalizer: &SourceTypeNormalizer<'_>,
) -> Result<EntityId, String> {
    let library = contract_library(project, owner, &reference.library)?;
    let mut candidates = Vec::new();
    for implementation in normalizer.selection.implementations.values() {
        if implementation.identity.module.source_library() != Some(library)
            || u64::try_from(implementation.formals.len()).ok()
                != Some(reference.type_parameter_count.0)
        {
            continue;
        }
        let target = contract_pattern(
            project,
            owner,
            &reference.target,
            &implementation.formals,
            normalizer,
        )?;
        if target != implementation.target {
            continue;
        }
        let trait_use = reference
            .trait_ref
            .as_ref()
            .map(|bound| pattern_trait(project, owner, bound, &implementation.formals, normalizer))
            .transpose()?;
        if trait_use == implementation.trait_use {
            candidates.push(implementation.identity.clone());
        }
    }
    match candidates.as_slice() {
        [identity] => Ok(identity.clone()),
        [] => Err("ImplRef does not bind an impl with that library, arity and header pattern".to_owned()),
        _ => Err("ImplRef is ambiguous; where clauses and source spans are not part of its public identity".to_owned()),
    }
}

fn pattern_trait(
    project: &ResolvedProject,
    owner: LibraryId,
    bound: &contract::PatternTrait,
    formals: &[TypeFormal],
    normalizer: &SourceTypeNormalizer<'_>,
) -> Result<TraitUse, String> {
    let declaration = bind_trait_ref(project, owner, &bound.trait_ref)?;
    let arguments = bound
        .arguments
        .iter()
        .map(|ty| contract_pattern(project, owner, ty, formals, normalizer))
        .collect::<Result<Vec<_>, _>>()?;
    if normalizer.arities[&declaration] != arguments.len() {
        return Err("trait pattern arity differs from its declaration".to_owned());
    }
    let mut associated = BTreeMap::new();
    for binding in &bound.associated_bindings {
        let member = project.entities[&declaration]
            .members
            .get(&binding.name.0)
            .into_iter()
            .flatten()
            .find(|member| member.kind == EntityKind::AssociatedType)
            .cloned()
            .ok_or_else(|| "associated pattern member does not exist".to_owned())?;
        associated.insert(
            member,
            contract_pattern(project, owner, &binding.value_type, formals, normalizer)?,
        );
    }
    Ok(TraitUse {
        declaration,
        arguments,
        associated,
    })
}

fn contract_pattern(
    project: &ResolvedProject,
    owner: LibraryId,
    pattern: &contract::TypePattern,
    formals: &[TypeFormal],
    normalizer: &SourceTypeNormalizer<'_>,
) -> Result<CheckedType, String> {
    match pattern {
        contract::TypePattern::Primitive { name } => match name {
            contract::PrimitiveType::Int => Ok(CheckedType::Int),
            contract::PrimitiveType::Float => Ok(CheckedType::Float),
            contract::PrimitiveType::Bool => Ok(CheckedType::Bool),
            contract::PrimitiveType::Unit => Ok(CheckedType::Unit),
            contract::PrimitiveType::Never => Ok(CheckedType::Never),
            _ => Err("unsupported type in impl pattern".to_owned()),
        },
        contract::TypePattern::LocalTypeParameter { index } => usize::try_from(index.0)
            .ok()
            .and_then(|index| formals.get(index))
            .cloned()
            .map(|formal| CheckedType::Formal(Box::new(formal)))
            .ok_or_else(|| "impl pattern type parameter index is out of range".to_owned()),
        contract::TypePattern::Tuple { elements } => Ok(CheckedType::Tuple(
            elements
                .0
                .iter()
                .map(|ty| contract_pattern(project, owner, ty, formals, normalizer))
                .collect::<Result<_, _>>()?,
        )),
        contract::TypePattern::Nominal {
            declaration,
            arguments,
        } => {
            let identity = lookup_contract_path(
                project,
                owner,
                &declaration.library,
                &declaration.path,
                Namespace::Type,
            )?;
            let arguments = arguments
                .iter()
                .map(|ty| contract_pattern(project, owner, ty, formals, normalizer))
                .collect::<Result<Vec<_>, _>>()?;
            if identity.kind == EntityKind::TypeAlias && arguments.is_empty() {
                return normalizer
                    .normalized_aliases
                    .get(&identity)
                    .cloned()
                    .ok_or_else(|| "impl pattern alias has not normalized".to_owned());
            }
            let expected = match declaration.kind {
                contract::DeclarationKind::Struct => EntityKind::Struct,
                contract::DeclarationKind::Enum => EntityKind::Enum,
                _ => return Err("unsupported nominal kind in impl pattern".to_owned()),
            };
            if identity.kind != expected || normalizer.arities[&identity] != arguments.len() {
                return Err("impl pattern nominal kind or arity differs".to_owned());
            }
            Ok(CheckedType::Nominal(Box::new(NominalType {
                declaration: identity,
                arguments,
            })))
        }
        contract::TypePattern::Associated {
            base,
            trait_ref,
            name,
        } => {
            let subject = contract_pattern(project, owner, base, formals, normalizer)?;
            let bound = pattern_trait(project, owner, trait_ref, formals, normalizer)?;
            let member = project.entities[&bound.declaration]
                .members
                .get(&name.0)
                .into_iter()
                .flatten()
                .find(|member| member.kind == EntityKind::AssociatedType)
                .cloned()
                .ok_or_else(|| "impl pattern associated member is missing".to_owned())?;
            Ok(CheckedType::Projection(Box::new(Projection {
                subject,
                bound,
                member,
            })))
        }
        _ => Err("unsupported resource type in impl pattern".to_owned()),
    }
}

impl ContractTypeContext<'_> {
    pub(super) fn requirements(
        &self,
        requirements: &[contract::GenericRequirement],
        path: &str,
    ) -> Result<ContractRequirements, CheckDiagnostic> {
        let mut normalized = ContractRequirements::default();
        for (index, requirement) in requirements.iter().enumerate() {
            if let contract::GenericRequirement::Trait { subject, bound } = requirement {
                let path = format!("{path}[{index}]");
                normalized.traits.push(Requirement {
                    subject: normalize_contract_type(self, &format!("{path}.subject"), subject)?,
                    bound: self.trait_use(bound, &format!("{path}.bound"))?,
                    origin: CheckOrigin::Contract {
                        document_index: self.document_index,
                        json_path: path,
                    },
                });
            }
        }
        for (index, requirement) in requirements.iter().enumerate() {
            let path = format!("{path}[{index}]");
            let origin = CheckOrigin::Contract {
                document_index: self.document_index,
                json_path: path.clone(),
            };
            match requirement {
                contract::GenericRequirement::Trait { .. } => {}
                contract::GenericRequirement::CallableShape { subject, shape } => {
                    let subject =
                        normalize_contract_type(self, &format!("{path}.subject"), subject)?;
                    let mut parameters = Vec::new();
                    for (index, parameter) in shape.parameters.iter().enumerate() {
                        let parameter_path = format!("{path}.shape.parameters[{index}]");
                        if !matches!(parameter.escape, contract::EscapeRule::MayEscape) {
                            return Err(self.error(
                                CheckDiagnosticKind::Unsupported,
                                &format!("{parameter_path}.escape"),
                                "scoped callback parameters are not supported",
                            ));
                        }
                        let ty = normalize_contract_type(
                            self,
                            &format!("{parameter_path}.type"),
                            &parameter.value_type,
                        )?;
                        let mode = match &parameter.mode {
                            contract::ModeRule::Fixed { mode: contract::Mode::Borrow } => ParameterMode::Borrow,
                            contract::ModeRule::Fixed { mode: contract::Mode::Move } => ParameterMode::Move,
                            contract::ModeRule::CallableUse { callable } => {
                                let callable = normalize_contract_type(self, &format!("{parameter_path}.mode.callable"), callable)?;
                                if callable != ty { return Err(self.error(CheckDiagnosticKind::ContractConflict, &parameter_path, "shape callable_use selects a different input type")) }
                                self.normalizer.shared_callable(&ty, &normalized.traits, origin.clone()).map_err(|mut error| { error.kind = CheckDiagnosticKind::Unsupported; error })?;
                                ParameterMode::Borrow
                            }
                            _ => return Err(self.error(CheckDiagnosticKind::Unsupported, &format!("{parameter_path}.mode"), "callback shape requires fixed Borrow/Move or proven shared Fn inputs")),
                        };
                        parameters.push((ty, mode));
                    }
                    let effect = shape
                        .effect_upper
                        .as_ref()
                        .map(|row| self.effect_row(row, &format!("{path}.shape.effect_upper")))
                        .transpose()?
                        .unwrap_or_else(|| {
                            EffectRow(vec![EffectTerm::SelectedCall(subject.clone())])
                        });
                    normalized.shapes.push(ShapeRequirement {
                        subject,
                        shape: CallableShape {
                            parameters,
                            return_type: normalize_contract_type(
                                self,
                                &format!("{path}.shape.result"),
                                &shape.result,
                            )?,
                            effect,
                        },
                        origin,
                        inferred_row: None,
                    });
                }
            }
        }
        Ok(normalized)
    }
    pub(super) fn self_type(
        &self,
        owner: &contract::SelfOwner,
        path: &str,
    ) -> Result<CheckedType, CheckDiagnostic> {
        let owner = match owner {
            contract::SelfOwner::Declaration { declaration } => lookup_contract_path(
                self.project,
                self.owner,
                &declaration.library,
                &declaration.path,
                Namespace::Type,
            ),
            contract::SelfOwner::Impl { implementation } => {
                bind_contract_impl(self.project, self.owner, implementation, self.normalizer)
            }
        }
        .map_err(|message| self.error(CheckDiagnosticKind::ContractBinding, path, message))?;
        if self.project.entities[self.target].owner.as_ref() != Some(&owner) {
            return Err(self.error(
                CheckDiagnosticKind::ContractConflict,
                path,
                "Self reference does not belong to this callable's owner",
            ));
        }
        self.project
            .entities
            .iter()
            .find_map(|(identity, entity)| {
                (identity.kind == EntityKind::SelfType && entity.owner.as_ref() == Some(&owner))
                    .then(|| self.normalizer.self_types.get(identity).cloned())
                    .flatten()
            })
            .ok_or_else(|| {
                self.error(
                    CheckDiagnosticKind::ContractBinding,
                    path,
                    "owner has no supported Self type",
                )
            })
    }

    pub(super) fn effect_row(
        &self,
        effects: &[contract::EffectTerm],
        path: &str,
    ) -> Result<EffectRow, CheckDiagnostic> {
        let mut terms = Vec::new();
        for (index, effect) in effects.iter().enumerate() {
            let path = format!("{path}[{index}]");
            terms.push(match effect {
                contract::EffectTerm::System { name } => EffectTerm::System(match name {
                    contract::SystemEffect::Console => SystemEffect::Console,
                    contract::SystemEffect::Fs => SystemEffect::Fs,
                    contract::SystemEffect::Process => SystemEffect::Process,
                }),
                contract::EffectTerm::Mut {} => EffectTerm::Mut,
                contract::EffectTerm::Unsafe {} => EffectTerm::Unsafe,
                contract::EffectTerm::Fail { payload } => EffectTerm::Fail(
                    normalize_contract_type(self, &format!("{path}.payload"), payload)?,
                ),
                contract::EffectTerm::Handled { effect, arguments } => {
                    let target = lookup_contract_path(
                        self.project,
                        self.owner,
                        &effect.library,
                        &effect.path,
                        Namespace::Effect,
                    )
                    .map_err(|message| {
                        self.error(CheckDiagnosticKind::ContractBinding, &path, message)
                    })?;
                    if target.kind != EntityKind::Effect
                        || self.normalizer.arities[&target] != arguments.len()
                    {
                        return Err(self.error(
                            CheckDiagnosticKind::ContractBinding,
                            &path,
                            "handled effect identity or arity does not match",
                        ));
                    }
                    EffectTerm::Handled(
                        target,
                        arguments
                            .iter()
                            .enumerate()
                            .map(|(index, ty)| {
                                normalize_contract_type(
                                    self,
                                    &format!("{path}.arguments[{index}]"),
                                    ty,
                                )
                            })
                            .collect::<Result<_, _>>()?,
                    )
                }
                contract::EffectTerm::Formal { formal } => {
                    let owner = bind_contract_entity(
                        self.project,
                        self.owner,
                        &formal.owner,
                        self.normalizer,
                    )
                    .map_err(|message| {
                        self.error(CheckDiagnosticKind::ContractBinding, &path, message)
                    })?;
                    let binder = matches!(
                        (&formal.binder, owner.kind),
                        (contract::Binder::Declaration, EntityKind::Function)
                            | (contract::Binder::Method, EntityKind::Method)
                    );
                    let ordinal = usize::try_from(formal.index.0).ok();
                    let formal = self
                        .effect_formals
                        .iter()
                        .find(|formal| formal.owner == owner && Some(formal.ordinal) == ordinal)
                        .filter(|_| binder)
                        .ok_or_else(|| {
                            self.error(
                                CheckDiagnosticKind::ContractBinding,
                                &path,
                                "effect formal is outside this callable's owner/ordinal scope",
                            )
                        })?;
                    EffectTerm::Formal(formal.clone())
                }
                contract::EffectTerm::FullDestruction { value_type } => EffectTerm::Destruction(
                    normalize_contract_type(self, &format!("{path}.type"), value_type)?,
                ),
                contract::EffectTerm::SelectedCall { callable } => EffectTerm::SelectedCall(
                    normalize_contract_type(self, &format!("{path}.callable"), callable)?,
                ),
                contract::EffectTerm::MethodApplication {
                    method,
                    self_type,
                    trait_type_arguments,
                    method_type_arguments,
                    effect_arguments,
                } => {
                    let owner = bind_trait_ref(self.project, self.owner, &method.owner).map_err(
                        |message| self.error(CheckDiagnosticKind::ContractBinding, &path, message),
                    )?;
                    let method = self.normalizer.selection.traits[&owner]
                        .methods
                        .get(&method.name.0)
                        .cloned()
                        .ok_or_else(|| {
                            self.error(
                                CheckDiagnosticKind::ContractBinding,
                                &path,
                                "method application does not name the owner's exact method",
                            )
                        })?;
                    let header = self.headers.get(&method).ok_or_else(|| {
                        self.error(
                            CheckDiagnosticKind::Unsupported,
                            &path,
                            "method application requires an unsupported core signature",
                        )
                    })?;
                    if trait_type_arguments.len()
                        != self.normalizer.selection.traits[&owner].formals.len()
                        || method_type_arguments.len() != header.declared_formals.len()
                        || effect_arguments.len() != header.effect_formals.len()
                    {
                        return Err(self.error(
                            CheckDiagnosticKind::ContractBinding,
                            &path,
                            "method application type/effect arity differs",
                        ));
                    }
                    let mut types = vec![normalize_contract_type(
                        self,
                        &format!("{path}.self"),
                        self_type,
                    )?];
                    for (index, ty) in trait_type_arguments.iter().enumerate() {
                        types.push(normalize_contract_type(
                            self,
                            &format!("{path}.trait_type_arguments[{index}]"),
                            ty,
                        )?);
                    }
                    for (index, ty) in method_type_arguments.iter().enumerate() {
                        types.push(normalize_contract_type(
                            self,
                            &format!("{path}.method_type_arguments[{index}]"),
                            ty,
                        )?);
                    }
                    let effects = effect_arguments
                        .iter()
                        .enumerate()
                        .map(|(index, row)| {
                            self.effect_row(row, &format!("{path}.effect_arguments[{index}]"))
                        })
                        .collect::<Result<_, _>>()?;
                    EffectTerm::Method {
                        method,
                        types,
                        effects,
                    }
                }
            });
        }
        Ok(EffectRow(terms))
    }

    pub(super) fn error(
        &self,
        kind: CheckDiagnosticKind,
        path: &str,
        message: impl Into<String>,
    ) -> CheckDiagnostic {
        contract_diagnostic(
            kind,
            message,
            self.document_index,
            path,
            vec![CheckOrigin::Source(self.source_origin.clone())],
        )
    }

    pub(super) fn formal(
        &self,
        formal: &contract::TypeFormalRef,
        path: &str,
    ) -> Result<CheckedType, CheckDiagnostic> {
        let owner = bind_contract_entity(self.project, self.owner, &formal.owner, self.normalizer)
            .map_err(|message| self.error(CheckDiagnosticKind::ContractBinding, path, message))?;
        let valid_binder = match formal.binder {
            contract::Binder::Declaration => matches!(
                owner.kind,
                EntityKind::Function | EntityKind::Trait | EntityKind::Struct | EntityKind::Enum
            ),
            contract::Binder::Impl => {
                matches!(owner.kind, EntityKind::InherentImpl | EntityKind::TraitImpl)
            }
            contract::Binder::Method => owner.kind == EntityKind::Method,
        };
        if !valid_binder {
            return Err(self.error(
                CheckDiagnosticKind::ContractBinding,
                path,
                "formal binder does not match its actual owner kind",
            ));
        }
        let index = usize::try_from(formal.index.0).ok();
        let found = self
            .formals
            .values()
            .find(|formal| formal.owner == owner && Some(formal.ordinal) == index);
        found
            .cloned()
            .map(|formal| CheckedType::Formal(Box::new(formal)))
            .ok_or_else(|| {
                self.error(
                    CheckDiagnosticKind::ContractConflict,
                    path,
                    "formal owner or ordinal is outside this callable's own and outer scope",
                )
            })
    }

    pub(super) fn trait_use(
        &self,
        bound: &contract::TraitUse,
        path: &str,
    ) -> Result<TraitUse, CheckDiagnostic> {
        let declaration = bind_trait_ref(self.project, self.owner, &bound.trait_ref)
            .map_err(|message| self.error(CheckDiagnosticKind::ContractBinding, path, message))?;
        let arguments = bound
            .arguments
            .iter()
            .enumerate()
            .map(|(index, ty)| {
                normalize_contract_type(self, &format!("{path}.arguments[{index}]"), ty)
            })
            .collect::<Result<Vec<_>, _>>()?;
        if self.normalizer.arities[&declaration] != arguments.len() {
            return Err(self.error(
                CheckDiagnosticKind::ContractBinding,
                path,
                "trait argument arity differs from its declaration",
            ));
        }
        let mut associated = BTreeMap::new();
        for (index, binding) in bound.associated_bindings.iter().enumerate() {
            let member = self.project.entities[&declaration]
                .members
                .get(&binding.name.0)
                .into_iter()
                .flatten()
                .find(|member| member.kind == EntityKind::AssociatedType)
                .cloned()
                .ok_or_else(|| {
                    self.error(
                        CheckDiagnosticKind::ContractBinding,
                        path,
                        "associated binding member does not exist",
                    )
                })?;
            let ty = normalize_contract_type(
                self,
                &format!("{path}.associated_bindings[{index}].type"),
                &binding.value_type,
            )?;
            if associated.insert(member, ty).is_some() {
                return Err(self.error(
                    CheckDiagnosticKind::ContractConflict,
                    path,
                    "duplicate associated binding",
                ));
            }
        }
        Ok(TraitUse {
            declaration,
            arguments,
            associated,
        })
    }
}

pub(super) fn normalize_selected_contract_type(
    context: &ContractTypeContext<'_>,
    path: &str,
    ty: &contract::Type,
) -> Result<CheckedType, CheckDiagnostic> {
    let ty = normalize_contract_type(context, path, ty)?;
    let givens = &context.headers[context.target].requirements;
    let mut solver = SelectionSolver::new(
        &context.normalizer.selection,
        &context.project.core_roles,
        givens,
        CheckOrigin::Contract {
            document_index: context.document_index,
            json_path: path.to_owned(),
        },
    )?;
    solver.normalize(&ty)
}
