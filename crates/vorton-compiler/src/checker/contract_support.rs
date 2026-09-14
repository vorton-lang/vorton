use super::*;

pub(super) struct PendingEffectContract {
    pub(super) target: EntityId,
    pub(super) owner: LibraryId,
    pub(super) document_index: usize,
    pub(super) path: String,
    pub(super) record_index: usize,
}

pub(super) struct PendingRequirementsContract {
    pub(super) target: EntityId,
    pub(super) owner: LibraryId,
    pub(super) document_index: usize,
    pub(super) path: String,
    pub(super) record_index: usize,
}

#[derive(Clone)]
pub(super) struct ContractEffectLocation {
    pub(super) document_index: usize,
    pub(super) record_index: usize,
    pub(super) requirement_index: usize,
}

#[derive(Clone)]
pub(super) struct ContractShape {
    pub(super) subject: TypeFormal,
    pub(super) parameters: Vec<(CheckedType, ParameterMode)>,
    pub(super) result: CheckedType,
    pub(super) effect: Option<ContractEffectLocation>,
    pub(super) origin: CheckOrigin,
    pub(super) owner: LibraryId,
}

pub(super) fn apply_contract_requirements(
    project: &ResolvedProject,
    traits: &TraitEnvironment,
    normalizer: &SourceTypeNormalizer,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    selections: &mut ContractSelections,
    documents: &[ContractDocument],
) -> Result<(), CheckDiagnostic> {
    let mut selected = BTreeMap::<EntityId, Vec<Requirement>>::new();
    for pending in std::mem::take(&mut selections.pending_requirements) {
        let header = &headers[&pending.target];
        let context = ContractTypeContext {
            binding: ContractBindingContext {
                project,
                owner: pending.owner,
                document_index: pending.document_index,
                normalizer,
                traits,
                headers,
            },
            target: &pending.target,
            header,
        };
        let mut requirements = Vec::new();
        let mut shapes = Vec::new();
        let requirements_wire = documents[pending.document_index].0.records[pending.record_index]
            .set
            .as_ref()
            .unwrap()
            .generic_requirements
            .as_ref()
            .unwrap();
        for (index, requirement) in requirements_wire.iter().enumerate() {
            let path = format!("{}[{index}]", pending.path);
            match requirement {
                contract::GenericRequirement::Trait { subject, bound } => {
                    requirements.push(Requirement {
                        subject: normalize_contract_type(
                            &context,
                            &format!("{path}.subject"),
                            subject,
                        )?,
                        bound: contract_trait(&context, bound, &format!("{path}.bound"))?,
                        origin: CheckOrigin::Contract {
                            document_index: pending.document_index,
                            json_path: path,
                        },
                    })
                }
                contract::GenericRequirement::CallableShape { subject, shape } => {
                    let CheckedType::Formal(subject) =
                        normalize_contract_type(&context, &format!("{path}.subject"), subject)?
                    else {
                        return Err(contract_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "callback shape requirements must constrain a declared actual callable formal",
                            pending.document_index,
                            path,
                            Vec::new(),
                        ));
                    };
                    let mut parameters = Vec::new();
                    for (parameter_index, parameter) in shape.parameters.iter().enumerate() {
                        let parameter_path = format!("{path}.shape.parameters[{parameter_index}]");
                        let mode = match &parameter.mode {
                            contract::ModeRule::Fixed {
                                mode: contract::Mode::Borrow,
                            } => ParameterMode::Borrow,
                            contract::ModeRule::Fixed {
                                mode: contract::Mode::Move,
                            } => ParameterMode::Move,
                            _ => {
                                return Err(contract_diagnostic(
                                    CheckDiagnosticKind::Unsupported,
                                    "callback shape requires an unsupported entry mode",
                                    pending.document_index,
                                    parameter_path,
                                    Vec::new(),
                                ));
                            }
                        };
                        if matches!(parameter.escape, contract::EscapeRule::Noescape) {
                            return Err(contract_diagnostic(
                                CheckDiagnosticKind::Unsupported,
                                "scoped callback shapes are outside this Checker",
                                pending.document_index,
                                parameter_path,
                                Vec::new(),
                            ));
                        }
                        parameters.push((
                            normalize_contract_type(
                                &context,
                                &format!("{parameter_path}.type"),
                                &parameter.value_type,
                            )?,
                            mode,
                        ));
                    }
                    shapes.push(ContractShape {
                        subject: *subject,
                        parameters,
                        result: normalize_contract_type(
                            &context,
                            &format!("{path}.shape.result"),
                            &shape.result,
                        )?,
                        effect: shape.effect_upper.as_ref().map(|_| ContractEffectLocation {
                            document_index: pending.document_index,
                            record_index: pending.record_index,
                            requirement_index: index,
                        }),
                        origin: CheckOrigin::Contract {
                            document_index: pending.document_index,
                            json_path: format!("{path}.shape"),
                        },
                        owner: pending.owner,
                    });
                }
            }
        }
        let keys = |requirements: &[Requirement]| {
            requirements
                .iter()
                .map(|requirement| (requirement.subject.clone(), requirement.bound.clone()))
                .collect::<BTreeSet<_>>()
        };
        if let Some(previous) = selected.get(&pending.target) {
            if keys(previous) != keys(&requirements) {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::ContractConflict,
                    "partial records select different generic requirements",
                    pending.document_index,
                    pending.path,
                    previous
                        .iter()
                        .map(|requirement| requirement.origin.clone())
                        .collect(),
                ));
            }
        } else {
            if (!header.requirements.is_empty() || !header.source_shapes.is_empty())
                && keys(&header.requirements) != keys(&requirements)
            {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "different explicit source and contract generic requirements have no selected difference policy",
                    pending.document_index,
                    pending.path,
                    header
                        .requirements
                        .iter()
                        .map(|requirement| requirement.origin.clone())
                        .collect(),
                ));
            }
            selected.insert(pending.target.clone(), requirements.clone());
        }
        let header = headers.get_mut(&pending.target).unwrap();
        header.contract_shapes.push(shapes);
        selections
            .generic_requirements
            .entry(pending.target.clone())
            .or_insert(CheckOrigin::Contract {
                document_index: pending.document_index,
                json_path: pending.path,
            });
    }
    for (target, requirements) in selected {
        headers.get_mut(&target).unwrap().requirements = requirements;
    }
    Ok(())
}

pub(super) fn bind_entity(
    context: &ContractBindingContext<'_>,
    reference: &contract::EntityRef,
    path: &str,
) -> Result<EntityId, CheckDiagnostic> {
    let failure = |message: String| {
        contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            message,
            context.document_index,
            path,
            Vec::new(),
        )
    };
    match reference {
        contract::EntityRef::Declaration { declaration } => {
            let (namespace, kind) = match declaration.kind {
                contract::DeclarationKind::Function => (Namespace::Value, EntityKind::Function),
                contract::DeclarationKind::Trait => (Namespace::Type, EntityKind::Trait),
                contract::DeclarationKind::Struct => (Namespace::Type, EntityKind::Struct),
                contract::DeclarationKind::Enum => (Namespace::Type, EntityKind::Enum),
                _ => {
                    return Err(contract_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "this declaration record family is outside the current Checker",
                        context.document_index,
                        path,
                        Vec::new(),
                    ));
                }
            };
            let target = lookup_contract_path(
                context.project,
                context.owner,
                &declaration.library,
                &declaration.path,
                namespace,
            )
            .map_err(failure)?;
            if target.kind != kind {
                return Err(failure(
                    "declaration reference has the wrong kind".to_owned(),
                ));
            }
            Ok(target)
        }
        contract::EntityRef::TraitMember { owner, kind, name } => {
            let owner = bind_trait(context, owner, path)?;
            let expected = match kind {
                contract::MemberKind::Method => EntityKind::Method,
                contract::MemberKind::AssociatedType => EntityKind::AssociatedType,
            };
            context.project.entities[&owner]
                .members
                .get(&name.0)
                .into_iter()
                .flatten()
                .find(|member| member.kind == expected)
                .cloned()
                .ok_or_else(|| {
                    failure("trait member reference has no exact declaration".to_owned())
                })
        }
        contract::EntityRef::ImplMember { owner, kind, name } => {
            let implementation = bind_impl(context, owner, path)?;
            match kind {
                contract::MemberKind::Method => {
                    implementation.methods.get(&name.0).cloned().ok_or_else(|| {
                        failure("impl method reference has no exact declaration".to_owned())
                    })
                }
                contract::MemberKind::AssociatedType => context
                    .project
                    .entities
                    .keys()
                    .find(|member| {
                        member.kind == EntityKind::AssociatedType
                            && member.owner == implementation.identity.owner
                            && member.name == name.0
                    })
                    .cloned()
                    .ok_or_else(|| {
                        failure(
                            "impl associated type reference has no exact declaration".to_owned(),
                        )
                    }),
            }
        }
        contract::EntityRef::Impl { implementation } => {
            Ok(bind_impl(context, implementation, path)?.identity.clone())
        }
    }
}

fn bind_trait(
    context: &ContractBindingContext<'_>,
    reference: &contract::TraitRef,
    path: &str,
) -> Result<EntityId, CheckDiagnostic> {
    let target = lookup_contract_path(
        context.project,
        context.owner,
        &reference.library,
        &reference.path,
        Namespace::Type,
    )
    .map_err(|message| {
        contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            message,
            context.document_index,
            path,
            Vec::new(),
        )
    })?;
    if target.kind != EntityKind::Trait {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            "trait reference has the wrong declaration kind",
            context.document_index,
            path,
            Vec::new(),
        ));
    }
    Ok(target)
}

pub(super) fn bind_impl<'a>(
    context: &'a ContractBindingContext<'_>,
    reference: &contract::ImplRef,
    path: &str,
) -> Result<&'a ImplDefinition, CheckDiagnostic> {
    let library = match &reference.library {
        contract::LibraryRef::Current {} => context.owner,
        contract::LibraryRef::Dependency { alias } => context
            .project
            .dependencies
            .get(&context.owner)
            .and_then(|edges| edges.get(&alias.0))
            .copied()
            .ok_or_else(|| {
                contract_diagnostic(
                    CheckDiagnosticKind::ContractBinding,
                    "ImplRef dependency is not a direct library edge",
                    context.document_index,
                    path,
                    Vec::new(),
                )
            })?,
    };
    let mut candidates = Vec::new();
    for implementation in &context.traits.implementations {
        if implementation.identity.module.library() != library
            || u64::try_from(implementation.formals.len()).ok()
                != Some(reference.type_parameter_count.0)
        {
            continue;
        }
        let target = normalize_pattern(
            context,
            &reference.target,
            &implementation.formals,
            &format!("{path}.target"),
        )?;
        let bound = reference
            .trait_ref
            .as_ref()
            .map(|bound| {
                pattern_trait(
                    context,
                    bound,
                    &implementation.formals,
                    &format!("{path}.trait"),
                )
            })
            .transpose()?;
        let inference = TypeInference::default();
        let mut solver = TraitSolver::new(
            context.traits,
            context.project,
            &inference,
            &implementation.requirements,
            entity_origin(&implementation.identity).unwrap(),
        )?;
        if solver.normalize(&target)? == solver.normalize(&implementation.target)?
            && bound == implementation.trait_use
        {
            candidates.push(implementation);
        }
    }
    let [implementation] = candidates.as_slice() else {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            if candidates.is_empty() {
                "ImplRef does not identify an implementation"
            } else {
                "ImplRef is ambiguous: the library, arity and header patterns select multiple owners"
            },
            context.document_index,
            path,
            candidates
                .iter()
                .filter_map(|implementation| entity_origin(&implementation.identity))
                .map(CheckOrigin::Source)
                .collect(),
        ));
    };
    Ok(*implementation)
}

fn normalize_pattern(
    context: &ContractBindingContext<'_>,
    pattern: &contract::TypePattern,
    formals: &[TypeFormal],
    path: &str,
) -> Result<CheckedType, CheckDiagnostic> {
    match pattern {
        contract::TypePattern::Primitive { name } => match name {
            contract::PrimitiveType::Int => Ok(CheckedType::Int),
            contract::PrimitiveType::Float => Ok(CheckedType::Float),
            contract::PrimitiveType::Bool => Ok(CheckedType::Bool),
            contract::PrimitiveType::Unit => Ok(CheckedType::Unit),
            contract::PrimitiveType::Never => Ok(CheckedType::Never),
            _ => Err(contract_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "ImplRef primitive is outside the current Checker",
                context.document_index,
                path,
                Vec::new(),
            )),
        },
        contract::TypePattern::LocalTypeParameter { index } => usize::try_from(index.0)
            .ok()
            .and_then(|index| formals.get(index))
            .cloned()
            .map(|formal| CheckedType::Formal(Box::new(formal)))
            .ok_or_else(|| {
                contract_diagnostic(
                    CheckDiagnosticKind::ContractBinding,
                    "ImplRef local type parameter index is outside its header",
                    context.document_index,
                    path,
                    Vec::new(),
                )
            }),
        contract::TypePattern::Tuple { elements } => Ok(CheckedType::Tuple(
            elements
                .0
                .iter()
                .enumerate()
                .map(|(index, ty)| {
                    normalize_pattern(context, ty, formals, &format!("{path}.elements[{index}]"))
                })
                .collect::<Result<_, _>>()?,
        )),
        contract::TypePattern::Nominal {
            declaration,
            arguments,
        } => {
            let target = lookup_contract_path(
                context.project,
                context.owner,
                &declaration.library,
                &declaration.path,
                Namespace::Type,
            )
            .map_err(|message| {
                contract_diagnostic(
                    CheckDiagnosticKind::ContractBinding,
                    message,
                    context.document_index,
                    path,
                    Vec::new(),
                )
            })?;
            let expected = match declaration.kind {
                contract::DeclarationKind::Struct => EntityKind::Struct,
                contract::DeclarationKind::Enum => EntityKind::Enum,
                contract::DeclarationKind::TypeAlias => EntityKind::TypeAlias,
                _ => {
                    return Err(contract_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "ImplRef nominal pattern requires a supported nominal or alias",
                        context.document_index,
                        path,
                        Vec::new(),
                    ));
                }
            };
            if target.kind != expected
                || context.normalizer.arities.get(&target).copied() != Some(arguments.len())
            {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::ContractBinding,
                    "ImplRef nominal kind or arity does not match",
                    context.document_index,
                    path,
                    Vec::new(),
                ));
            }
            if target.kind == EntityKind::TypeAlias {
                return context
                    .normalizer
                    .normalized_aliases
                    .get(&target)
                    .cloned()
                    .ok_or_else(|| {
                        contract_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "ImplRef alias must be non-generic and normalized",
                            context.document_index,
                            path,
                            Vec::new(),
                        )
                    });
            }
            Ok(CheckedType::Nominal(Box::new(NominalType {
                declaration: target,
                arguments: arguments
                    .iter()
                    .enumerate()
                    .map(|(index, ty)| {
                        normalize_pattern(
                            context,
                            ty,
                            formals,
                            &format!("{path}.arguments[{index}]"),
                        )
                    })
                    .collect::<Result<_, _>>()?,
            })))
        }
        contract::TypePattern::Associated {
            base,
            trait_ref,
            name,
        } => {
            let bound = pattern_trait(context, trait_ref, formals, &format!("{path}.trait"))?;
            let member = associated_member(context, &bound.declaration, &name.0, path)?;
            Ok(CheckedType::Projection(Box::new(ProjectionType {
                receiver: normalize_pattern(context, base, formals, &format!("{path}.base"))?,
                member: Some(member),
                name: name.0.clone(),
                bound: Some(bound),
            })))
        }
        _ => Err(contract_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "ImplRef pattern requires an unsupported type",
            context.document_index,
            path,
            Vec::new(),
        )),
    }
}

fn pattern_trait(
    context: &ContractBindingContext<'_>,
    pattern: &contract::PatternTrait,
    formals: &[TypeFormal],
    path: &str,
) -> Result<TraitUse, CheckDiagnostic> {
    let declaration = bind_trait(context, &pattern.trait_ref, path)?;
    let arguments = pattern
        .arguments
        .iter()
        .enumerate()
        .map(|(index, ty)| {
            normalize_pattern(context, ty, formals, &format!("{path}.arguments[{index}]"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if arguments.len() != context.traits.traits[&declaration].formals.len() {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            "trait pattern type arity does not match",
            context.document_index,
            path,
            Vec::new(),
        ));
    }
    let mut associated = BTreeMap::new();
    for (index, binding) in pattern.associated_bindings.iter().enumerate() {
        let member = associated_member(context, &declaration, &binding.name.0, path)?;
        associated.insert(
            member,
            normalize_pattern(
                context,
                &binding.value_type,
                formals,
                &format!("{path}.associated_bindings[{index}].type"),
            )?,
        );
    }
    Ok(TraitUse {
        declaration,
        arguments,
        associated,
    })
}

fn associated_member(
    context: &ContractBindingContext<'_>,
    owner: &EntityId,
    name: &str,
    path: &str,
) -> Result<EntityId, CheckDiagnostic> {
    context.traits.traits[owner]
        .associated
        .keys()
        .find(|member| member.name == name)
        .cloned()
        .ok_or_else(|| {
            contract_diagnostic(
                CheckDiagnosticKind::ContractBinding,
                "associated type name does not belong to the exact trait",
                context.document_index,
                path,
                Vec::new(),
            )
        })
}

pub(super) fn contract_trait(
    context: &ContractTypeContext<'_>,
    reference: &contract::TraitUse,
    path: &str,
) -> Result<TraitUse, CheckDiagnostic> {
    let declaration = bind_trait(context, &reference.trait_ref, &format!("{path}.trait"))?;
    if context.header.public_export
        && !actual_public_exports(context.project).contains(&declaration)
    {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::TypeMismatch,
            "public contract bound references a private trait",
            context.document_index,
            format!("{path}.trait"),
            entity_origin(&declaration)
                .map(CheckOrigin::Source)
                .into_iter()
                .collect(),
        ));
    }
    let arguments = reference
        .arguments
        .iter()
        .enumerate()
        .map(|(index, ty)| {
            normalize_contract_type(context, &format!("{path}.arguments[{index}]"), ty)
        })
        .collect::<Result<Vec<_>, _>>()?;
    if arguments.len() != context.traits.traits[&declaration].formals.len() {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            "trait use has the wrong type arity",
            context.document_index,
            path,
            Vec::new(),
        ));
    }
    let mut associated = BTreeMap::new();
    for (index, binding) in reference.associated_bindings.iter().enumerate() {
        let member = associated_member(context, &declaration, &binding.name.0, path)?;
        let ty = normalize_contract_type(
            context,
            &format!("{path}.associated_bindings[{index}].type"),
            &binding.value_type,
        )?;
        if associated.insert(member, ty).is_some() {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::ContractConflict,
                "a trait use repeats an associated binding",
                context.document_index,
                path,
                Vec::new(),
            ));
        }
    }
    Ok(TraitUse {
        declaration,
        arguments,
        associated,
    })
}

pub(super) fn contract_formal(
    context: &ContractTypeContext<'_>,
    formal: &contract::TypeFormalRef,
    path: &str,
) -> Result<CheckedType, CheckDiagnostic> {
    let owner = bind_entity(context, &formal.owner, &format!("{path}.owner"))?;
    let pool = match (&formal.binder, &formal.owner) {
        (contract::Binder::Declaration, contract::EntityRef::Declaration { .. })
            if owner.kind == EntityKind::Function =>
        {
            context
                .headers
                .get(&owner)
                .map(|header| header.declared_formals.clone())
        }
        (contract::Binder::Declaration, contract::EntityRef::Declaration { .. })
            if owner.kind == EntityKind::Trait =>
        {
            context
                .traits
                .traits
                .get(&owner)
                .map(|definition| definition.formals.clone())
        }
        (
            contract::Binder::Method,
            contract::EntityRef::TraitMember { .. } | contract::EntityRef::ImplMember { .. },
        ) => context
            .headers
            .get(&owner)
            .map(|header| header.declared_formals.clone()),
        (contract::Binder::Impl, contract::EntityRef::Impl { .. }) => context
            .traits
            .implementations
            .iter()
            .find(|implementation| implementation.identity == owner)
            .map(|implementation| implementation.formals.clone()),
        _ => None,
    }
    .ok_or_else(|| {
        contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            "formal binder does not match its declaration family",
            context.document_index,
            path,
            Vec::new(),
        )
    })?;
    let selected = usize::try_from(formal.index.0)
        .ok()
        .and_then(|index| pool.get(index))
        .ok_or_else(|| {
            contract_diagnostic(
                CheckDiagnosticKind::ContractConflict,
                "formal index is outside the selected owner",
                context.document_index,
                path,
                Vec::new(),
            )
        })?;
    if !context.header.declared_formals.contains(selected)
        && !context.header.outer_formals.contains(selected)
    {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::ContractConflict,
            "formal belongs to a different lexical owner",
            context.document_index,
            path,
            entity_origin(&owner)
                .map(CheckOrigin::Source)
                .into_iter()
                .collect(),
        ));
    }
    Ok(CheckedType::Formal(Box::new(selected.clone())))
}

pub(super) fn contract_self(
    context: &ContractTypeContext<'_>,
    owner: &contract::SelfOwner,
    path: &str,
) -> Result<CheckedType, CheckDiagnostic> {
    let identity = match owner {
        contract::SelfOwner::Impl { implementation } => {
            bind_impl(context, implementation, path)?.identity.clone()
        }
        contract::SelfOwner::Declaration { declaration } => lookup_contract_path(
            context.project,
            context.owner,
            &declaration.library,
            &declaration.path,
            Namespace::Type,
        )
        .map_err(|message| {
            contract_diagnostic(
                CheckDiagnosticKind::ContractBinding,
                message,
                context.document_index,
                path,
                Vec::new(),
            )
        })?,
    };
    let ty = context
        .normalizer
        .self_types
        .iter()
        .find(|(self_id, _)| {
            *self_id == &identity
                || context
                    .project
                    .entities
                    .get(*self_id)
                    .is_some_and(|entity| entity.owner.as_ref() == Some(&identity))
        })
        .map(|(_, ty)| ty.clone())
        .ok_or_else(|| {
            contract_diagnostic(
                CheckDiagnosticKind::ContractBinding,
                "Self owner has no supported source identity",
                context.document_index,
                path,
                Vec::new(),
            )
        })?;
    let mut formals = BTreeSet::new();
    TypeInference::default().referenced_formals(&ty, &mut formals);
    if formals
        .iter()
        .any(|formal| !context.header.outer_formals.contains(formal))
    {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::ContractConflict,
            "Self reference requires a different outer environment",
            context.document_index,
            path,
            Vec::new(),
        ));
    }
    Ok(ty)
}

pub(super) fn contract_effect(
    context: &ContractTypeContext<'_>,
    row: &[contract::EffectTerm],
    path: &str,
    inputs: &mut Vec<LocatedInput>,
) -> Result<CheckedEffect, CheckDiagnostic> {
    let mut result = CheckedEffect::default();
    for (index, term) in row.iter().enumerate() {
        let path = format!("{path}[{index}]");
        let normalized = match term {
            contract::EffectTerm::System { name } => {
                let name = match name {
                    contract::SystemEffect::Console => "console",
                    contract::SystemEffect::Fs => "fs",
                    contract::SystemEffect::Process => "process",
                };
                let identity = context
                    .project
                    .entities
                    .keys()
                    .find(|identity| {
                        identity.kind == EntityKind::LanguageEffect && identity.name == name
                    })
                    .expect("language capability identity exists");
                EffectTerm::System(identity.clone())
            }
            contract::EffectTerm::Handled { effect, arguments } => {
                let identity = lookup_contract_path(
                    context.project,
                    context.owner,
                    &effect.library,
                    &effect.path,
                    Namespace::Effect,
                )
                .map_err(|message| {
                    contract_diagnostic(
                        CheckDiagnosticKind::ContractBinding,
                        message,
                        context.document_index,
                        &path,
                        Vec::new(),
                    )
                })?;
                if identity.kind != EntityKind::Effect
                    || context.normalizer.arities.get(&identity).copied() != Some(arguments.len())
                {
                    return Err(contract_diagnostic(
                        CheckDiagnosticKind::ContractBinding,
                        "handled effect kind or arity differs from its declaration",
                        context.document_index,
                        path,
                        Vec::new(),
                    ));
                }
                let arguments = arguments
                    .iter()
                    .enumerate()
                    .map(|(index, ty)| {
                        normalize_contract_type(context, &format!("{path}.arguments[{index}]"), ty)
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                EffectTerm::Handled(identity, arguments)
            }
            contract::EffectTerm::Fail { payload } => EffectTerm::Failure(normalize_contract_type(
                context,
                &format!("{path}.payload"),
                payload,
            )?),
            contract::EffectTerm::Mut {} => EffectTerm::Mut,
            contract::EffectTerm::Unsafe {} => EffectTerm::Unsafe,
            contract::EffectTerm::Formal { formal } => {
                let owner = bind_entity(context, &formal.owner, &format!("{path}.formal.owner"))?;
                let binder_matches = matches!(
                    (&formal.binder, owner.kind),
                    (contract::Binder::Declaration, EntityKind::Function)
                        | (contract::Binder::Method, EntityKind::Method)
                );
                if owner != *context.target || !binder_matches {
                    return Err(contract_diagnostic(
                        CheckDiagnosticKind::ContractBinding,
                        "effect formal must use this callable's own binder",
                        context.document_index,
                        path,
                        Vec::new(),
                    ));
                }
                let formal = usize::try_from(formal.index.0)
                    .ok()
                    .and_then(|index| context.header.effect_formals.get(index))
                    .map(|(_, formal)| formal.clone())
                    .ok_or_else(|| {
                        contract_diagnostic(
                            CheckDiagnosticKind::ContractBinding,
                            "effect formal ordinal is outside the callable scheme",
                            context.document_index,
                            &path,
                            Vec::new(),
                        )
                    })?;
                EffectTerm::Formal(formal)
            }
            contract::EffectTerm::MethodApplication {
                method,
                self_type,
                trait_type_arguments,
                method_type_arguments,
                effect_arguments,
            } => {
                let owner = bind_trait(context, &method.owner, &format!("{path}.method.owner"))?;
                let member = context.traits.traits[&owner]
                    .methods
                    .get(&method.name.0)
                    .ok_or_else(|| {
                        contract_diagnostic(
                            CheckDiagnosticKind::ContractBinding,
                            "method application has no exact trait member",
                            context.document_index,
                            &path,
                            Vec::new(),
                        )
                    })?;
                let header = context.headers.get(member).ok_or_else(|| {
                    contract_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "method application has an unsupported signature",
                        context.document_index,
                        &path,
                        Vec::new(),
                    )
                })?;
                if trait_type_arguments.len() != context.traits.traits[&owner].formals.len()
                    || method_type_arguments.len() != header.declared_formals.len()
                    || effect_arguments.len() != header.effect_formals.len()
                {
                    return Err(contract_diagnostic(
                        CheckDiagnosticKind::ContractBinding,
                        "method application owner, method or effect arity differs",
                        context.document_index,
                        path,
                        Vec::new(),
                    ));
                }
                let actuals = std::iter::once(normalize_contract_type(
                    context,
                    &format!("{path}.self"),
                    self_type,
                ))
                .chain(trait_type_arguments.iter().enumerate().map(|(index, ty)| {
                    normalize_contract_type(
                        context,
                        &format!("{path}.trait_type_arguments[{index}]"),
                        ty,
                    )
                }))
                .chain(method_type_arguments.iter().enumerate().map(|(index, ty)| {
                    normalize_contract_type(
                        context,
                        &format!("{path}.method_type_arguments[{index}]"),
                        ty,
                    )
                }))
                .collect::<Result<Vec<_>, _>>()?;
                EffectTerm::Method {
                    method: member.clone(),
                    types: header
                        .outer_formals
                        .iter()
                        .chain(&header.declared_formals)
                        .cloned()
                        .zip(actuals)
                        .collect(),
                    effects: effect_arguments
                        .iter()
                        .enumerate()
                        .map(|(index, row)| {
                            contract_effect(
                                context,
                                row,
                                &format!("{path}.effect_arguments[{index}]"),
                                inputs,
                            )
                        })
                        .collect::<Result<_, _>>()?,
                }
            }
            contract::EffectTerm::FullDestruction { value_type } => EffectTerm::Destruction(
                normalize_contract_type(context, &format!("{path}.type"), value_type)?,
            ),
            contract::EffectTerm::SelectedCall { callable } => {
                let ty = normalize_contract_type(context, &format!("{path}.callable"), callable)?;
                inputs.push(LocatedInput {
                    exposed: false,
                    origin: CheckOrigin::Contract {
                        document_index: context.document_index,
                        json_path: path.clone(),
                    },
                    value: SemanticInput::Effect(
                        CheckedEffect::singleton(EffectTerm::SelectedCall(ty.clone())),
                        EffectUse::Runtime,
                    ),
                });
                if let CheckedType::Formal(formal) = &ty
                    && let Some(shape) = context.header.shapes.get(formal.as_ref())
                    && !shape
                        .effect
                        .0
                        .contains(&EffectTerm::SelectedCall(ty.clone()))
                {
                    result.0.extend(shape.effect.0.iter().cloned());
                    continue;
                }
                EffectTerm::SelectedCall(ty)
            }
        };
        inputs.push(LocatedInput {
            exposed: false,
            origin: CheckOrigin::Contract {
                document_index: context.document_index,
                json_path: path.clone(),
            },
            value: SemanticInput::Effect(
                CheckedEffect::singleton(normalized.clone()),
                EffectUse::Runtime,
            ),
        });
        result.0.insert(normalized);
    }
    result.reduce_destruction(&context.normalizer.nominals, &context.header.origin)
}

pub(super) fn apply_contract_effects(
    project: &ResolvedProject,
    traits: &TraitEnvironment,
    normalizer: &SourceTypeNormalizer,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    selections: &mut ContractSelections,
    documents: &[ContractDocument],
    inference: &TypeInference,
) -> Result<(), CheckDiagnostic> {
    for pending in std::mem::take(&mut selections.pending_effects) {
        let context = ContractTypeContext {
            binding: ContractBindingContext {
                project,
                owner: pending.owner,
                document_index: pending.document_index,
                normalizer,
                traits,
                headers,
            },
            target: &pending.target,
            header: &headers[&pending.target],
        };
        let wire = documents[pending.document_index].0.records[pending.record_index]
            .set
            .as_ref()
            .unwrap()
            .effect_upper
            .as_ref()
            .unwrap();
        let mut inputs = Vec::new();
        let origin = CheckOrigin::Contract {
            document_index: pending.document_index,
            json_path: pending.path.clone(),
        };
        let row = contract_effect(&context, wire, &pending.path, &mut inputs)?;
        let givens = context
            .header
            .requirements
            .iter()
            .chain(&context.header.outer_requirements)
            .cloned()
            .collect::<Vec<_>>();
        let mut solver = TraitSolver::new(
            traits,
            project,
            inference,
            &givens,
            context.header.origin.clone(),
        )?;
        let row = row
            .normalize_types(&mut solver)
            .and_then(|row| row.reduce_destruction(&normalizer.nominals, &context.header.origin))
            .map_err(|mut diagnostic| {
                diagnostic.related.extend(diagnostic.primary.take());
                diagnostic.primary = Some(origin.clone());
                diagnostic
            })?;
        let source = context
            .header
            .effect_upper
            .as_ref()
            .map(|row| {
                row.normalize_types(&mut solver)?
                    .reduce_destruction(&normalizer.nominals, &context.header.origin)
            })
            .transpose()?;
        if let Some((previous, previous_origin)) = selections.effect_upper.get(&pending.target) {
            if previous != &row {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::ContractConflict,
                    "partial records select different effect upper bounds",
                    pending.document_index,
                    pending.path,
                    vec![previous_origin.clone()],
                ));
            }
        } else if let Some(source) = source
            && source != row
        {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "different explicit source and contract effect bounds have no selected difference policy",
                pending.document_index,
                pending.path,
                vec![CheckOrigin::Source(context.header.origin.clone())],
            ));
        }
        let header = headers.get_mut(&pending.target).unwrap();
        header.semantic_inputs.extend(inputs);
        header.effect_upper = Some(row.clone());
        header.effect_origin = Some(origin.clone());
        selections
            .effect_upper
            .entry(pending.target)
            .or_insert((row, origin));
    }
    Ok(())
}

pub(super) fn contract_function_item(
    context: &ContractTypeContext<'_>,
    function: &contract::FunctionRef,
    outer: &[contract::Type],
    own: &[contract::Type],
    effects: usize,
    path: &str,
) -> Result<CheckedType, CheckDiagnostic> {
    let failure = |message| {
        contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            message,
            context.document_index,
            path,
            Vec::new(),
        )
    };
    let target = match function {
        contract::FunctionRef::Declaration { declaration } => lookup_contract_path(
            context.project,
            context.owner,
            &declaration.library,
            &declaration.path,
            Namespace::Value,
        )
        .map_err(failure)?,
        contract::FunctionRef::TraitMember { owner, name, .. } => {
            let owner = bind_trait(context, owner, path)?;
            context.traits.traits[&owner]
                .methods
                .get(&name.0)
                .cloned()
                .ok_or_else(|| failure("function item has no exact trait member".to_owned()))?
        }
        contract::FunctionRef::ImplMember { owner, name, .. } => bind_impl(context, owner, path)?
            .methods
            .get(&name.0)
            .cloned()
            .ok_or_else(|| failure("function item has no exact impl member".to_owned()))?,
    };
    let header = context
        .headers
        .get(&target)
        .ok_or_else(|| failure("function item must select a supported callable".to_owned()))?;
    if outer.len() != header.outer_formals.len() || own.len() != header.declared_formals.len() {
        return Err(failure(
            "function item owner and method type arity must match".to_owned(),
        ));
    }
    if effects != 0 || !header.effect_formals.is_empty() {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "function value requires a closed effect header",
            context.document_index,
            path,
            Vec::new(),
        ));
    }
    let mut types = Vec::new();
    for (field, formals, actuals) in [
        ("owner_type_arguments", &header.outer_formals, outer),
        ("type_arguments", &header.declared_formals, own),
    ] {
        for (index, (formal, actual)) in formals.iter().zip(actuals).enumerate() {
            types.push((
                formal.clone(),
                normalize_contract_type(context, &format!("{path}.{field}[{index}]"), actual)?,
            ));
        }
    }
    Ok(CheckedType::Function(Box::new(FunctionValue {
        declaration: target,
        types,
    })))
}

pub(super) fn normalize_contract_types(
    project: &ResolvedProject,
    traits: &TraitEnvironment,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    selections: &mut ContractSelections,
    inference: &TypeInference,
) -> Result<(), CheckDiagnostic> {
    let mut inputs = Vec::new();
    let normalize = |identity: &EntityId,
                     ty: &CheckedType,
                     origin: &CheckOrigin|
     -> Result<CheckedType, CheckDiagnostic> {
        let header = &headers[identity];
        let givens = header
            .requirements
            .iter()
            .chain(&header.outer_requirements)
            .cloned()
            .collect::<Vec<_>>();
        TraitSolver::new(traits, project, inference, &givens, header.origin.clone())?
            .normalize(ty)
            .map_err(|mut diagnostic| {
                diagnostic.related.extend(diagnostic.primary.take());
                diagnostic.primary = Some(origin.clone());
                diagnostic
            })
    };
    for ((identity, _), (ty, origin)) in &mut selections.parameter_types {
        inputs.push((
            identity.clone(),
            LocatedInput {
                exposed: false,
                origin: origin.clone(),
                value: SemanticInput::Type(ty.clone(), TypeUse::Value),
            },
        ));
        *ty = normalize(identity, ty, origin)?;
    }
    for (identity, (ty, origin)) in &mut selections.return_types {
        inputs.push((
            identity.clone(),
            LocatedInput {
                exposed: false,
                origin: origin.clone(),
                value: SemanticInput::Type(ty.clone(), TypeUse::Return),
            },
        ));
        *ty = normalize(identity, ty, origin)?;
    }
    for (identity, parameter, ty, origin) in std::mem::take(&mut selections.type_alternatives) {
        inputs.push((
            identity.clone(),
            LocatedInput {
                exposed: false,
                origin: origin.clone(),
                value: SemanticInput::Type(
                    ty.clone(),
                    if parameter.is_some() {
                        TypeUse::Value
                    } else {
                        TypeUse::Return
                    },
                ),
            },
        ));
        let (selected, previous) = if let Some(parameter) = parameter {
            &selections.parameter_types[&(identity.clone(), parameter)]
        } else {
            &selections.return_types[&identity]
        };
        if *selected != normalize(&identity, &ty, &origin)? {
            return Err(CheckDiagnostic {
                kind: CheckDiagnosticKind::ContractConflict,
                message: "partial contract records select different normalized types".to_owned(),
                primary: Some(origin),
                related: vec![previous.clone()],
            });
        }
    }
    for (identity, input) in inputs {
        headers
            .get_mut(&identity)
            .unwrap()
            .semantic_inputs
            .push(input);
    }
    Ok(())
}
