use super::*;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct EffectFormal {
    pub(super) owner: EntityId,
    pub(super) ordinal: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Default)]
pub(super) struct CheckedEffect(pub(super) BTreeSet<EffectTerm>);

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum EffectTerm {
    System(EntityId),
    Handled(EntityId, Vec<CheckedType>),
    Failure(CheckedType),
    Mut,
    Unsafe,
    Formal(EffectFormal),
    Method {
        method: EntityId,
        types: Vec<(TypeFormal, CheckedType)>,
        effects: Vec<CheckedEffect>,
    },
    Destruction(CheckedType),
    SelectedCall(CheckedType),
}

impl CheckedEffect {
    pub(super) fn normalize_types(
        &self,
        solver: &mut TraitSolver<'_>,
    ) -> Result<Self, CheckDiagnostic> {
        enum Step<'a> {
            Row(&'a CheckedEffect),
            Term(&'a EffectTerm),
            Join(usize),
            Method(&'a EntityId, Vec<(TypeFormal, CheckedType)>, usize),
        }
        let mut work = vec![Step::Row(self)];
        let mut values: Vec<CheckedEffect> = Vec::new();
        while let Some(step) = work.pop() {
            match step {
                Step::Row(row) => {
                    work.push(Step::Join(row.0.len()));
                    work.extend(row.0.iter().rev().map(Step::Term));
                }
                Step::Join(count) => {
                    let rows = values.split_off(values.len() - count);
                    values.push(Self(rows.into_iter().flat_map(|row| row.0).collect()));
                }
                Step::Method(method, types, count) => {
                    let effects = values.split_off(values.len() - count);
                    values.push(Self::singleton(EffectTerm::Method {
                        method: method.clone(),
                        types,
                        effects,
                    }));
                }
                Step::Term(term) => {
                    let term = match term {
                        EffectTerm::Failure(ty) => EffectTerm::Failure(solver.normalize(ty)?),
                        EffectTerm::Destruction(ty) => {
                            EffectTerm::Destruction(solver.normalize(ty)?)
                        }
                        EffectTerm::SelectedCall(ty) => {
                            EffectTerm::SelectedCall(solver.normalize(ty)?)
                        }
                        EffectTerm::Handled(identity, arguments) => EffectTerm::Handled(
                            identity.clone(),
                            arguments
                                .iter()
                                .map(|ty| solver.normalize(ty))
                                .collect::<Result<_, _>>()?,
                        ),
                        EffectTerm::Method {
                            method,
                            types,
                            effects,
                        } => {
                            let types = types
                                .iter()
                                .map(|(formal, ty)| Ok((formal.clone(), solver.normalize(ty)?)))
                                .collect::<Result<_, CheckDiagnostic>>()?;
                            work.push(Step::Method(method, types, effects.len()));
                            work.extend(effects.iter().rev().map(Step::Row));
                            continue;
                        }
                        EffectTerm::System(_)
                        | EffectTerm::Mut
                        | EffectTerm::Unsafe
                        | EffectTerm::Formal(_) => term.clone(),
                    };
                    values.push(Self::singleton(term));
                }
            }
        }
        Ok(values.pop().expect("each row produces one normalized row"))
    }

    pub(super) fn singleton(term: EffectTerm) -> Self {
        Self(BTreeSet::from([term]))
    }

    pub(super) fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub(super) fn may_fail(&self) -> bool {
        self.0.iter().any(|term| {
            matches!(
                term,
                EffectTerm::Failure(_)
                    | EffectTerm::Formal(_)
                    | EffectTerm::Method { .. }
                    | EffectTerm::SelectedCall(_)
            )
        })
    }

    pub(super) fn may_fail_under(&self, caps: &BTreeMap<EffectFormal, Vec<CheckedEffect>>) -> bool {
        self.0.iter().any(|term| match term {
            EffectTerm::Formal(formal) => caps
                .get(formal)
                .is_none_or(|bounds| bounds.iter().all(Self::may_fail)),
            EffectTerm::Failure(_) | EffectTerm::Method { .. } | EffectTerm::SelectedCall(_) => {
                true
            }
            _ => false,
        })
    }

    fn reduce_empty_caps(mut self, caps: &BTreeMap<EffectFormal, Vec<CheckedEffect>>) -> Self {
        self.0.retain(|term| !matches!(term, EffectTerm::Formal(formal) if caps.get(formal).is_some_and(|bounds| bounds.iter().any(Self::is_empty))));
        self
    }

    fn without_unsafe(mut self) -> Self {
        self.0.remove(&EffectTerm::Unsafe);
        self
    }

    fn normalized(&self, inference: &TypeInference) -> Self {
        Self(
            self.0
                .iter()
                .map(|term| match term {
                    EffectTerm::Failure(ty) => EffectTerm::Failure(inference.resolve(ty)),
                    EffectTerm::Destruction(ty) => EffectTerm::Destruction(inference.resolve(ty)),
                    EffectTerm::SelectedCall(ty) => EffectTerm::SelectedCall(inference.resolve(ty)),
                    EffectTerm::Handled(identity, arguments) => EffectTerm::Handled(
                        identity.clone(),
                        arguments.iter().map(|ty| inference.resolve(ty)).collect(),
                    ),
                    EffectTerm::Method {
                        method,
                        types,
                        effects,
                    } => EffectTerm::Method {
                        method: method.clone(),
                        types: types
                            .iter()
                            .map(|(formal, ty)| (formal.clone(), inference.resolve(ty)))
                            .collect(),
                        effects: effects
                            .iter()
                            .map(|row| row.normalized(inference))
                            .collect(),
                    },
                    other => other.clone(),
                })
                .collect(),
        )
    }

    pub(super) fn instantiate(
        &self,
        types: &BTreeMap<TypeFormal, CheckedType>,
        effects: &BTreeMap<EffectFormal, CheckedEffect>,
    ) -> Self {
        let mut result = BTreeSet::new();
        for term in &self.0 {
            match term {
                EffectTerm::Formal(formal) if effects.contains_key(formal) => {
                    result.extend(effects[formal].0.iter().cloned())
                }
                EffectTerm::Handled(identity, arguments) => {
                    result.insert(EffectTerm::Handled(
                        identity.clone(),
                        arguments
                            .iter()
                            .map(|ty| instantiate_type(ty, types))
                            .collect(),
                    ));
                }
                EffectTerm::Failure(ty) => {
                    result.insert(EffectTerm::Failure(instantiate_type(ty, types)));
                }
                EffectTerm::Destruction(ty) => {
                    result.insert(EffectTerm::Destruction(instantiate_type(ty, types)));
                }
                EffectTerm::SelectedCall(ty) => {
                    result.insert(EffectTerm::SelectedCall(instantiate_type(ty, types)));
                }
                EffectTerm::Method {
                    method,
                    types: actuals,
                    effects: rows,
                } => {
                    result.insert(EffectTerm::Method {
                        method: method.clone(),
                        types: actuals
                            .iter()
                            .map(|(formal, ty)| (formal.clone(), instantiate_type(ty, types)))
                            .collect(),
                        effects: rows
                            .iter()
                            .map(|row| row.instantiate(types, effects))
                            .collect(),
                    });
                }
                other => {
                    result.insert(other.clone());
                }
            }
        }
        Self(result)
    }

    fn merge(
        &mut self,
        other: &Self,
        inference: &mut TypeInference,
        origin: &OriginRef,
    ) -> Result<(), CheckDiagnostic> {
        for term in &other.0 {
            for present in &self.0 {
                let pairs = match (present, term) {
                    (EffectTerm::Failure(left), EffectTerm::Failure(right)) => vec![(left, right)],
                    (EffectTerm::Handled(left, la), EffectTerm::Handled(right, ra))
                        if left == right =>
                    {
                        la.iter().zip(ra).collect()
                    }
                    _ => Vec::new(),
                };
                for (left, right) in pairs {
                    inference.unify(left, right).map_err(|failure| {
                        source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            format!(
                                "effect payload conflict: {}",
                                display_unification_failure(&failure)
                            ),
                            origin.clone(),
                            Vec::new(),
                        )
                    })?;
                }
            }
            self.0.insert(term.clone());
        }
        *self = self.normalized(inference);
        Ok(())
    }

    fn subset(&self, upper: &Self, origin: &CheckOrigin) -> Result<(), CheckDiagnostic> {
        if self.0.is_subset(&upper.0) {
            return Ok(());
        }
        Err(CheckDiagnostic {
            kind: CheckDiagnosticKind::TypeMismatch,
            message: "actual effect row exceeds its declared upper bound".to_owned(),
            primary: Some(origin.clone()),
            related: Vec::new(),
        })
    }

    fn subset_inferred(
        &self,
        upper: &Self,
        caps: &BTreeMap<EffectFormal, Vec<CheckedEffect>>,
        origin: (&CheckOrigin, &OriginRef),
        inference: &mut TypeInference,
    ) -> Result<(), CheckDiagnostic> {
        let (origin, source) = origin;
        let mut merged = Self::default();
        merged
            .merge(self, inference, source)
            .and_then(|()| merged.merge(upper, inference, source))
            .map_err(|mut diagnostic| {
                diagnostic.primary = Some(origin.clone());
                diagnostic
            })?;
        let caps = caps
            .iter()
            .map(|(formal, bounds)| {
                (
                    formal.clone(),
                    bounds.iter().map(|row| row.normalized(inference)).collect(),
                )
            })
            .collect();
        self.normalized(inference)
            .subset_under(&upper.normalized(inference), &caps, origin)
    }

    fn validate_identity(&self, origin: &OriginRef) -> Result<(), CheckDiagnostic> {
        let mut pending = vec![self];
        while let Some(row) = pending.pop() {
            for term in &row.0 {
                match term {
                    EffectTerm::Handled(_, arguments)
                        if arguments.iter().any(|ty| !closed_identity_type(ty)) =>
                    {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            "handled effect runtime identity requires closed concrete type actuals",
                            origin.clone(),
                            Vec::new(),
                        ));
                    }
                    EffectTerm::Failure(ty) if contains_function_value(ty) => {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "function value failure payload is outside this Checker",
                            origin.clone(),
                            Vec::new(),
                        ));
                    }
                    EffectTerm::Method { effects, .. } => pending.extend(effects),
                    _ => {}
                }
            }
        }
        Ok(())
    }

    fn subset_under(
        &self,
        upper: &Self,
        caps: &BTreeMap<EffectFormal, Vec<CheckedEffect>>,
        origin: &CheckOrigin,
    ) -> Result<(), CheckDiagnostic> {
        if self.0.iter().all(|term| upper.0.contains(term) || matches!(term, EffectTerm::Formal(formal) if caps.get(formal).is_some_and(|bounds| bounds.iter().any(|cap| cap.0.is_subset(&upper.0))))) { return Ok(()); }
        self.subset(upper, origin)
    }

    pub(super) fn reduce_destruction(
        mut self,
        nominals: &BTreeMap<EntityId, NominalDefinition>,
        origin: &OriginRef,
    ) -> Result<Self, CheckDiagnostic> {
        let mut terms = BTreeSet::new();
        for term in self.0 {
            if let EffectTerm::Destruction(ty) = term {
                terms.extend(destruction_effect(&[ty], nominals, origin)?.0);
            } else {
                terms.insert(term);
            }
        }
        self.0 = terms;
        Ok(self)
    }

    pub(super) fn close(&self, closure: &BodyClosure<'_>) -> Self {
        Self(
            self.0
                .iter()
                .map(|term| match term {
                    EffectTerm::Handled(identity, arguments) => EffectTerm::Handled(
                        identity.clone(),
                        arguments.iter().map(|ty| closure.close_type(ty)).collect(),
                    ),
                    EffectTerm::Failure(ty) => EffectTerm::Failure(closure.close_type(ty)),
                    EffectTerm::Destruction(ty) => EffectTerm::Destruction(closure.close_type(ty)),
                    EffectTerm::SelectedCall(ty) => {
                        EffectTerm::SelectedCall(closure.close_type(ty))
                    }
                    EffectTerm::Method {
                        method,
                        types,
                        effects,
                    } => EffectTerm::Method {
                        method: method.clone(),
                        types: types
                            .iter()
                            .map(|(formal, ty)| (formal.clone(), closure.close_type(ty)))
                            .collect(),
                        effects: effects.iter().map(|row| row.close(closure)).collect(),
                    },
                    other => other.clone(),
                })
                .collect(),
        )
    }
}

#[derive(Clone)]
pub(super) enum CleanupExit {
    Scope,
    Return,
    Failure,
    Temporary,
}

#[derive(Clone)]
pub(super) struct CleanupFact {
    pub(super) origin: OriginRef,
    #[allow(
        dead_code,
        reason = "the opaque cleanup receipt retains its control-flow exit kind"
    )]
    pub(super) exit: CleanupExit,
    pub(super) state: UsageState,
    pub(super) bindings: Vec<EntityId>,
    pub(super) temporaries: Vec<usize>,
}

impl CleanupFact {
    pub(super) fn close(mut self, closure: &BodyClosure<'_>) -> Self {
        for usage in self.state.bindings.values_mut() {
            usage.ty = closure.close_type(&usage.ty);
            usage.cleanup = usage
                .cleanup
                .iter()
                .map(|ty| closure.close_type(ty))
                .collect();
        }
        for temporary in &mut self.state.temporaries {
            temporary.owner = closure.close_type(&temporary.owner);
            temporary.types = temporary
                .types
                .iter()
                .map(|ty| closure.close_type(ty))
                .collect();
        }
        self
    }

    fn types(&self) -> Vec<CheckedType> {
        self.bindings
            .iter()
            .filter_map(|binding| self.state.bindings.get(binding))
            .filter(|usage| {
                usage.ownership == OwnershipKind::Owned && usage.availability != Availability::Moved
            })
            .flat_map(|usage| usage.cleanup.iter().cloned())
            .chain(
                self.temporaries
                    .iter()
                    .flat_map(|index| self.state.temporaries[*index].types.iter().cloned()),
            )
            .collect()
    }
}

pub(super) fn record_cleanup(
    state: &UsageState,
    bindings: Vec<EntityId>,
    temporaries: Vec<usize>,
    origin: OriginRef,
    exit: CleanupExit,
    facts: &mut Vec<CleanupFact>,
) {
    if bindings.is_empty() && temporaries.is_empty() {
        return;
    }
    facts.push(CleanupFact {
        origin,
        exit,
        state: state.clone(),
        bindings,
        temporaries,
    });
}

pub(super) fn destruction_effect(
    types: &[CheckedType],
    nominals: &BTreeMap<EntityId, NominalDefinition>,
    origin: &OriginRef,
) -> Result<CheckedEffect, CheckDiagnostic> {
    let mut row = CheckedEffect::default();
    let mut pending = types.to_vec();
    let mut work = 0;
    while let Some(ty) = pending.pop() {
        work += 1;
        if work > 8192 {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "incomplete destruction solve: 8192 type states exhausted",
                origin.clone(),
                Vec::new(),
            ));
        }
        match ty {
            CheckedType::Infer(_) | CheckedType::Formal(_) | CheckedType::Projection(_) => {
                row.0.insert(EffectTerm::Destruction(ty));
            }
            CheckedType::Tuple(elements) => pending.extend(elements),
            CheckedType::Nominal(nominal) => {
                let definition = &nominals[&nominal.declaration];
                if definition.destruction.projection {
                    row.0
                        .insert(EffectTerm::Destruction(CheckedType::Nominal(nominal)));
                } else {
                    pending.extend(
                        definition
                            .destruction
                            .parameters
                            .iter()
                            .map(|index| nominal.arguments[*index].clone()),
                    );
                }
            }
            CheckedType::Int
            | CheckedType::Float
            | CheckedType::Bool
            | CheckedType::Unit
            | CheckedType::Never
            | CheckedType::Function(_) => {}
        }
    }
    Ok(row)
}

pub(super) fn infer_group_effects(
    group: &[EntityId],
    headers: &BTreeMap<EntityId, FunctionHeader>,
    schemes: &BTreeMap<EntityId, CallableScheme>,
    bodies: &mut BTreeMap<EntityId, TypedBlock>,
    inference: &mut TypeInference,
    environment: TypeEnvironment<'_>,
    calls: &[DraftCall],
) -> Result<BTreeMap<EntityId, CheckedEffect>, CheckDiagnostic> {
    let TypeEnvironment {
        project,
        traits,
        nominals,
    } = environment;
    let members = group.iter().cloned().collect::<BTreeSet<_>>();
    let mut callers = BTreeMap::<EntityId, BTreeSet<EntityId>>::new();
    for identity in group {
        for dependency in calls
            .iter()
            .filter(|call| &call.caller == identity)
            .flat_map(|call| call.target.iter().chain(&call.effect_dependencies))
            .chain(&headers[identity].effect_dependencies)
        {
            if members.contains(dependency) {
                callers
                    .entry(dependency.clone())
                    .or_default()
                    .insert(identity.clone());
            }
        }
    }
    let mut rows = group
        .iter()
        .map(|identity| {
            (
                identity.clone(),
                headers[identity]
                    .trait_upper
                    .clone()
                    .or_else(|| headers[identity].effect_upper.clone())
                    .unwrap_or_default()
                    .normalized(inference),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let mut pending = group.iter().cloned().collect::<VecDeque<_>>();
    let mut queued = members;
    let mut work = 0;
    while let Some(identity) = pending.pop_front() {
        queued.remove(&identity);
        work += 1;
        let header = &headers[&identity];
        if work > 8192 {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "incomplete effect solve: 8192 callable-summary steps exhausted",
                header.origin.clone(),
                Vec::new(),
            ));
        }
        let actual = block_effect(
            bodies.get_mut(&identity).unwrap(),
            &EffectContext {
                headers,
                schemes,
                rows: &rows,
                header,
                nominals,
                traits,
                project,
            },
            inference,
        )?;
        let published = header
            .trait_upper
            .clone()
            .or_else(|| header.effect_upper.clone())
            .unwrap_or(actual)
            .normalized(inference);
        if rows[&identity] != published {
            rows.insert(identity.clone(), published);
            for caller in callers.get(&identity).into_iter().flatten() {
                if queued.insert(caller.clone()) {
                    pending.push_back(caller.clone());
                }
            }
        }
    }
    Ok(rows)
}

struct EffectContext<'a> {
    headers: &'a BTreeMap<EntityId, FunctionHeader>,
    schemes: &'a BTreeMap<EntityId, CallableScheme>,
    rows: &'a BTreeMap<EntityId, CheckedEffect>,
    header: &'a FunctionHeader,
    nominals: &'a BTreeMap<EntityId, NominalDefinition>,
    traits: &'a TraitEnvironment,
    project: &'a ResolvedProject,
}

enum EffectWalk<'a> {
    Block(&'a mut TypedBlock, bool),
    Expression(&'a mut TypedExpr, bool),
    Unsafe,
    Call {
        callee: &'a EntityId,
        instantiation: &'a CallInstantiation,
        actuals: &'a [(EffectFormal, CheckedEffect)],
        effect: &'a mut CheckedEffect,
        span: Span,
        active: bool,
    },
    Indirect {
        effect: &'a mut CheckedEffect,
        span: Span,
        active: bool,
    },
    Raise {
        payload: CheckedType,
        span: Span,
        active: bool,
    },
}

fn block_effect(
    block: &mut TypedBlock,
    context: &EffectContext<'_>,
    inference: &mut TypeInference,
) -> Result<CheckedEffect, CheckDiagnostic> {
    let mut work = vec![EffectWalk::Block(block, true)];
    let mut rows = vec![CheckedEffect::default()];
    while let Some(step) = work.pop() {
        match step {
            EffectWalk::Block(block, mut active) => {
                if active {
                    for fact in &block.cleanups {
                        let row =
                            destruction_effect(&fact.types(), context.nominals, &fact.origin)?;
                        rows.last_mut().unwrap().merge(
                            &joint_destruction(&row, context, inference, &fact.origin)?,
                            inference,
                            &fact.origin,
                        )?;
                    }
                }
                let mut children = Vec::new();
                for statement in &mut block.statements {
                    match &mut statement.kind {
                        TypedStatementKind::Let { value, .. }
                        | TypedStatementKind::Expression(value) => {
                            let next = active && inference.resolve(&value.ty) != CheckedType::Never;
                            children.push((value.as_mut(), active));
                            active = next;
                        }
                        TypedStatementKind::Return(value) => {
                            if let Some(value) = value {
                                children.push((value.as_mut(), active));
                            }
                            active = false;
                        }
                    }
                }
                if let Some(tail) = &mut block.tail {
                    children.push((tail.as_mut(), active));
                }
                work.extend(
                    children
                        .into_iter()
                        .rev()
                        .map(|(expression, active)| EffectWalk::Expression(expression, active)),
                );
            }
            EffectWalk::Expression(expression, active) => {
                let span = expression.span;
                match &mut expression.kind {
                    TypedExprKind::Call(call) => {
                        let mut next = active;
                        let children = call
                            .arguments
                            .iter_mut()
                            .map(|argument| {
                                let here = next;
                                next &= inference.resolve(&argument.ty) != CheckedType::Never;
                                (argument, here)
                            })
                            .collect::<Vec<_>>();
                        work.push(EffectWalk::Call {
                            callee: &call.callee,
                            instantiation: &call.instantiation,
                            actuals: &call.effect_actuals,
                            effect: &mut call.effect,
                            span,
                            active: next,
                        });
                        work.extend(
                            children
                                .into_iter()
                                .rev()
                                .map(|(argument, active)| EffectWalk::Expression(argument, active)),
                        );
                    }
                    TypedExprKind::IndirectCall(call) => {
                        let mut next =
                            active && inference.resolve(&call.callee.ty) != CheckedType::Never;
                        let children = call
                            .arguments
                            .iter_mut()
                            .map(|argument| {
                                let here = next;
                                next &= inference.resolve(&argument.ty) != CheckedType::Never;
                                (argument, here)
                            })
                            .collect::<Vec<_>>();
                        work.push(EffectWalk::Indirect {
                            effect: &mut call.effect,
                            span,
                            active: next,
                        });
                        work.extend(
                            children
                                .into_iter()
                                .rev()
                                .map(|(argument, active)| EffectWalk::Expression(argument, active)),
                        );
                        work.push(EffectWalk::Expression(&mut call.callee, active));
                    }
                    TypedExprKind::Raise { payload, .. } => {
                        let next = active && inference.resolve(&payload.ty) != CheckedType::Never;
                        work.push(EffectWalk::Raise {
                            payload: payload.ty.clone(),
                            span,
                            active: next,
                        });
                        work.push(EffectWalk::Expression(payload, active));
                    }
                    TypedExprKind::Block(block) => work.push(EffectWalk::Block(block, active)),
                    TypedExprKind::Unsafe(block) => {
                        rows.push(CheckedEffect::default());
                        work.push(EffectWalk::Unsafe);
                        work.push(EffectWalk::Block(block, active));
                    }
                    TypedExprKind::If {
                        condition,
                        then_branch,
                        else_branch,
                    } => {
                        let branches =
                            active && inference.resolve(&condition.ty) != CheckedType::Never;
                        if let Some(branch) = else_branch {
                            work.push(EffectWalk::Expression(branch, branches));
                        }
                        work.push(EffectWalk::Block(then_branch, branches));
                        work.push(EffectWalk::Expression(condition, active));
                    }
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
                    } => work.push(EffectWalk::Expression(inner, active)),
                    TypedExprKind::Tuple(elements) => {
                        let mut next = active;
                        let children = elements
                            .iter_mut()
                            .map(|element| {
                                let here = next;
                                next &= inference.resolve(&element.ty) != CheckedType::Never;
                                (element, here)
                            })
                            .collect::<Vec<_>>();
                        work.extend(
                            children
                                .into_iter()
                                .rev()
                                .map(|(element, active)| EffectWalk::Expression(element, active)),
                        );
                    }
                    TypedExprKind::Construct(construction) => {
                        let mut next = active;
                        let children = construction
                            .fields
                            .iter_mut()
                            .map(|field| {
                                let here = next;
                                next &= inference.resolve(&field.value.ty) != CheckedType::Never;
                                (&mut field.value, here)
                            })
                            .collect::<Vec<_>>();
                        work.extend(
                            children
                                .into_iter()
                                .rev()
                                .map(|(value, active)| EffectWalk::Expression(value, active)),
                        );
                    }
                    TypedExprKind::Binary { left, right, .. } => {
                        work.push(EffectWalk::Expression(
                            right,
                            active && inference.resolve(&left.ty) != CheckedType::Never,
                        ));
                        work.push(EffectWalk::Expression(left, active));
                    }
                    TypedExprKind::DeferredCall { .. } => {
                        unreachable!("call constraints precede effect closure")
                    }
                    TypedExprKind::Integer { .. }
                    | TypedExprKind::Float(_)
                    | TypedExprKind::Boolean(_)
                    | TypedExprKind::Unit
                    | TypedExprKind::Reference { .. }
                    | TypedExprKind::FunctionValue(_) => {}
                }
            }
            EffectWalk::Unsafe => {
                let row = rows.pop().unwrap().without_unsafe();
                rows.last_mut()
                    .unwrap()
                    .merge(&row, inference, &context.header.origin)?;
            }
            EffectWalk::Call {
                callee,
                instantiation,
                actuals,
                effect,
                span,
                active,
            } => {
                let types = match instantiation {
                    CallInstantiation::Published(mapping)
                    | CallInstantiation::Provisional(mapping) => mapping
                        .iter()
                        .map(|(formal, ty)| (formal.clone(), inference.resolve(ty)))
                        .collect(),
                    CallInstantiation::RecursiveBinding => BTreeMap::new(),
                };
                let header = &context.headers[callee];
                *effect = if header.body.is_none() && header.effect_upper.is_none() {
                    CheckedEffect::singleton(EffectTerm::Method {
                        method: callee.clone(),
                        types: types.into_iter().collect(),
                        effects: actuals.iter().map(|(_, row)| row.clone()).collect(),
                    })
                } else {
                    context
                        .schemes
                        .get(callee)
                        .map(|scheme| &scheme.effect)
                        .or_else(|| context.rows.get(callee))
                        .unwrap()
                        .instantiate(&types, &actuals.iter().cloned().collect())
                };
                finish_call_effect(effect, span, active, &mut rows, context, inference)?;
            }
            EffectWalk::Indirect {
                effect,
                span,
                active,
            } => finish_call_effect(effect, span, active, &mut rows, context, inference)?,
            EffectWalk::Raise {
                payload,
                span,
                active,
            } => {
                if active {
                    rows.last_mut().unwrap().merge(
                        &CheckedEffect::singleton(EffectTerm::Failure(inference.resolve(&payload))),
                        inference,
                        &context.header.context.origin(span),
                    )?;
                }
            }
        }
    }
    Ok(rows
        .pop()
        .unwrap()
        .reduce_empty_caps(&context.header.effect_caps))
}

fn joint_destruction(
    row: &CheckedEffect,
    context: &EffectContext<'_>,
    inference: &TypeInference,
    origin: &OriginRef,
) -> Result<CheckedEffect, CheckDiagnostic> {
    let givens = context
        .header
        .requirements
        .iter()
        .chain(&context.header.outer_requirements)
        .cloned()
        .collect::<Vec<_>>();
    let mut solver = TraitSolver::new(
        context.traits,
        context.project,
        inference,
        &givens,
        origin.clone(),
    )?;
    let mut result = CheckedEffect::default();
    let mut pending = Vec::new();
    for term in &row.0 {
        if let EffectTerm::Destruction(ty) = term {
            pending.push(ty.clone());
        } else {
            result.0.insert(term.clone());
        }
    }
    let mut visited = BTreeSet::new();
    while let Some(ty) = pending.pop() {
        if visited.len() >= 8192 {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "incomplete destruction solve: 8192 owner states exhausted",
                origin.clone(),
                Vec::new(),
            ));
        }
        let ty = solver.normalize(&ty)?;
        if !visited.insert(ty.clone()) {
            continue;
        }
        match ty {
            CheckedType::Nominal(nominal)
                if context.nominals[&nominal.declaration]
                    .destruction
                    .projection =>
            {
                let mapping = nominal.replacements(context.nominals);
                pending.extend(
                    context.nominals[&nominal.declaration]
                        .constructors
                        .values()
                        .flat_map(|constructor| {
                            constructor
                                .fields
                                .iter()
                                .map(|field| instantiate_type(&field.ty, &mapping))
                        }),
                );
            }
            CheckedType::Tuple(elements) => pending.extend(elements),
            other => result
                .0
                .extend(destruction_effect(&[other], context.nominals, origin)?.0),
        }
    }
    Ok(result)
}

fn finish_call_effect(
    effect: &mut CheckedEffect,
    span: Span,
    active: bool,
    rows: &mut [CheckedEffect],
    context: &EffectContext<'_>,
    inference: &mut TypeInference,
) -> Result<(), CheckDiagnostic> {
    let origin = context.header.context.origin(span);
    let givens = context
        .header
        .requirements
        .iter()
        .chain(&context.header.outer_requirements)
        .cloned()
        .collect::<Vec<_>>();
    *effect = effect.normalize_types(&mut TraitSolver::new(
        context.traits,
        context.project,
        inference,
        &givens,
        origin.clone(),
    )?)?;
    *effect = effect
        .reduce_methods(
            BodyEnvironment {
                project: context.project,
                headers: context.headers,
                traits: context.traits,
            },
            context.schemes,
            context.rows,
            inference,
            &origin,
            context.header,
        )?
        .reduce_destruction(context.nominals, &origin)?;
    *effect = joint_destruction(effect, context, inference, &origin)?;
    *effect = effect.normalize_types(&mut TraitSolver::new(
        context.traits,
        context.project,
        inference,
        &givens,
        origin.clone(),
    )?)?;
    effect.validate_identity(&origin)?;
    if active {
        rows.last_mut().unwrap().merge(effect, inference, &origin)?;
    }
    Ok(())
}

pub(super) fn validate_group_effects(
    group: &[EntityId],
    headers: &BTreeMap<EntityId, FunctionHeader>,
    schemes: &BTreeMap<EntityId, CallableScheme>,
    bodies: &mut BTreeMap<EntityId, TypedBlock>,
    rows: &BTreeMap<EntityId, CheckedEffect>,
    inference: &mut TypeInference,
    environment: TypeEnvironment<'_>,
) -> Result<(), CheckDiagnostic> {
    let TypeEnvironment {
        project,
        traits,
        nominals,
    } = environment;
    for identity in group {
        let header = &headers[identity];
        let actual = block_effect(
            bodies.get_mut(identity).unwrap(),
            &EffectContext {
                headers,
                schemes,
                rows,
                header,
                nominals,
                traits,
                project,
            },
            inference,
        )?;
        actual
            .normalized(inference)
            .validate_identity(&header.origin)?;
        let origin = header
            .effect_origin
            .clone()
            .unwrap_or_else(|| CheckOrigin::Source(header.origin.clone()));
        let context = EffectContext {
            headers,
            schemes,
            rows,
            header,
            nominals,
            traits,
            project,
        };
        let normalize = |row: &CheckedEffect,
                         inference: &mut TypeInference|
         -> Result<CheckedEffect, CheckDiagnostic> {
            let givens = header
                .requirements
                .iter()
                .chain(&header.outer_requirements)
                .cloned()
                .collect::<Vec<_>>();
            let row = row.normalize_types(&mut TraitSolver::new(
                traits,
                project,
                inference,
                &givens,
                header.origin.clone(),
            )?)?;
            let row = row
                .reduce_methods(
                    BodyEnvironment {
                        project,
                        headers,
                        traits,
                    },
                    schemes,
                    rows,
                    inference,
                    &header.origin,
                    header,
                )?
                .reduce_destruction(nominals, &header.origin)?;
            joint_destruction(&row, &context, inference, &header.origin)?.normalize_types(
                &mut TraitSolver::new(traits, project, inference, &givens, header.origin.clone())?,
            )
        };
        if let Some(upper) = &header.effect_upper {
            actual.subset_inferred(
                &normalize(upper, inference)?,
                &header.effect_caps,
                (&origin, &header.origin),
                inference,
            )?;
        }
        if let Some(upper) = &header.trait_upper {
            normalize(header.effect_upper.as_ref().unwrap_or(&actual), inference)?
                .subset_inferred(
                    &normalize(upper, inference)?,
                    &header.effect_caps,
                    (&origin, &header.origin),
                    inference,
                )?;
        }
        if let Some(upper) = &header.module_upper {
            actual.subset_inferred(
                &normalize(upper, inference)?,
                &header.effect_caps,
                (&origin, &header.origin),
                inference,
            )?;
        }
        if identity.kind == EntityKind::Function
            && identity.name == "main"
            && identity.module.library() == project.entry
            && normalize(&rows[identity], inference)?
                .0
                .iter()
                .any(|term| matches!(term, EffectTerm::Handled(_, _)))
        {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "an unhandled user effect cannot escape main",
                header.origin.clone(),
                Vec::new(),
            ));
        }
    }
    Ok(())
}

pub(super) fn constrain_flexible_effects(
    group: &[EntityId],
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    schemes: &BTreeMap<EntityId, CallableScheme>,
    bodies: &mut BTreeMap<EntityId, TypedBlock>,
    rows: &BTreeMap<EntityId, CheckedEffect>,
    inference: &mut TypeInference,
    environment: TypeEnvironment<'_>,
) -> Result<(), CheckDiagnostic> {
    let TypeEnvironment {
        project,
        traits,
        nominals,
    } = environment;
    for identity in group {
        let header = headers.get_mut(identity).unwrap();
        for formal in &header.flexible_effects {
            if let Some(bounds) = inference.effect_caps.get(formal) {
                header.effect_caps.insert(formal.clone(), bounds.clone());
            }
        }

        let header = &headers[identity];
        let Some(upper) = &header.effect_upper else {
            continue;
        };
        let actual = block_effect(
            bodies.get_mut(identity).unwrap(),
            &EffectContext {
                headers,
                schemes,
                rows,
                header,
                nominals,
                traits,
                project,
            },
            inference,
        )?;
        let caps = actual
            .0
            .iter()
            .filter_map(|term| match term {
                EffectTerm::Formal(formal)
                    if header.flexible_effects.contains(formal) && !upper.0.contains(term) =>
                {
                    Some((formal.clone(), upper.clone()))
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        let header = headers.get_mut(identity).unwrap();
        for formal in &header.flexible_effects {
            if let Some(bounds) = inference.effect_caps.get(formal) {
                header.effect_caps.insert(formal.clone(), bounds.clone());
            }
        }
        for (formal, upper) in caps {
            header.effect_caps.entry(formal).or_default().push(upper);
        }
    }
    Ok(())
}

pub(super) fn normalize_effect_headers(
    project: &ResolvedProject,
    normalizer: &mut SourceTypeNormalizer,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    _traits: &TraitEnvironment,
) -> Result<(), CheckDiagnostic> {
    let sources = headers
        .iter()
        .map(|(identity, header)| (identity.clone(), header.source_effects.clone()))
        .collect::<Vec<_>>();
    for (identity, source) in sources {
        let mut inputs = Vec::new();
        if let Some(module) = module_for_origin(project, &headers[&identity].origin)
            && let Some(requires) = project.modules[&module]
                .body
                .as_ref()
                .and_then(|body| body.requires.as_ref())
        {
            let row = source_effect_row(
                requires,
                SourceEffectScope {
                    origin: &headers[&identity].origin,
                    effect_formals: &headers[&identity].effect_formals,
                    use_kind: EffectUse::Runtime,
                },
                normalizer,
                project,
                headers,
                &mut inputs,
            )?;
            headers.get_mut(&identity).unwrap().module_upper = Some(row);
        }
        if let Some(source) = source {
            let row = source_effect_row(
                &source,
                SourceEffectScope {
                    origin: &headers[&identity].origin,
                    effect_formals: &headers[&identity].effect_formals,
                    use_kind: EffectUse::Runtime,
                },
                normalizer,
                project,
                headers,
                &mut inputs,
            )?;
            headers.get_mut(&identity).unwrap().effect_upper = Some(row);
        }
        headers
            .get_mut(&identity)
            .unwrap()
            .semantic_inputs
            .extend(inputs);
    }
    Ok(())
}

pub(super) fn finalize_effect_headers(
    project: &ResolvedProject,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    traits: &TraitEnvironment,
    inference: &mut TypeInference,
) -> Result<(), CheckDiagnostic> {
    for header in headers.values() {
        for row in header
            .effect_upper
            .iter()
            .chain(header.shapes.values().map(|shape| &shape.effect))
        {
            if header.identity.kind != EntityKind::EffectOperation {
                row.validate_identity(&header.origin)
                    .map_err(|mut diagnostic| {
                        if let Some(origin) = &header.effect_origin {
                            diagnostic.related.extend(diagnostic.primary.take());
                            diagnostic.primary = Some(origin.clone());
                        }
                        diagnostic
                    })?;
            }
            row.subset_inferred(
                row,
                &header.effect_caps,
                (
                    &header
                        .effect_origin
                        .clone()
                        .unwrap_or_else(|| CheckOrigin::Source(header.origin.clone())),
                    &header.origin,
                ),
                inference,
            )?;
        }
    }
    for implementation in &traits.implementations {
        let Some(bound) = &implementation.trait_use else {
            continue;
        };
        let definition = &traits.traits[&bound.declaration];
        for (name, member) in &implementation.methods {
            let expected = &headers[&definition.methods[name]];
            let actual = &headers[member];
            let Some(upper) = &expected.effect_upper else {
                continue;
            };
            let mut types =
                std::iter::once((definition.self_type.clone(), implementation.target.clone()))
                    .chain(
                        definition
                            .formals
                            .iter()
                            .cloned()
                            .zip(bound.arguments.iter().cloned()),
                    )
                    .collect::<BTreeMap<_, _>>();
            types.extend(
                expected.declared_formals.iter().cloned().zip(
                    actual
                        .declared_formals
                        .iter()
                        .cloned()
                        .map(|formal| CheckedType::Formal(Box::new(formal))),
                ),
            );
            let effects = expected
                .effect_formals
                .iter()
                .zip(&actual.effect_formals)
                .map(|((_, expected), (_, actual))| {
                    (
                        expected.clone(),
                        CheckedEffect::singleton(EffectTerm::Formal(actual.clone())),
                    )
                })
                .collect();
            let upper = upper.instantiate(&types, &effects);
            headers.get_mut(member).unwrap().trait_upper = Some(upper);
        }
    }
    let dependencies = headers
        .iter()
        .map(|(identity, header)| {
            let givens = header
                .requirements
                .iter()
                .chain(&header.outer_requirements)
                .cloned()
                .collect::<Vec<_>>();
            let dependencies = header
                .effect_upper
                .as_ref()
                .map(|row| {
                    row.dependencies(traits, project, headers, inference, &givens, &header.origin)
                })
                .transpose()?
                .unwrap_or_default();
            Ok((identity.clone(), dependencies))
        })
        .collect::<Result<Vec<_>, CheckDiagnostic>>()?;
    for (identity, dependencies) in dependencies {
        headers.get_mut(&identity).unwrap().effect_dependencies = dependencies;
    }
    let indices = headers
        .keys()
        .enumerate()
        .map(|(index, identity)| (identity.clone(), index))
        .collect::<BTreeMap<_, _>>();
    let graph = headers
        .values()
        .map(|header| DeclarationGraphNode {
            declaration: header.origin.clone(),
            edges: header
                .effect_dependencies
                .iter()
                .filter_map(|target| indices.get(target))
                .map(|target| DeclarationGraphEdge {
                    target: *target,
                    reference: header.source_effects.as_ref().map_or_else(
                        || header.origin.clone(),
                        |effects| header.context.origin(effects.span),
                    ),
                })
                .collect(),
        })
        .collect::<Vec<_>>();
    if let Some(cycle) = first_declaration_cycle(&graph) {
        return Err(source_diagnostic(
            CheckDiagnosticKind::TypeMismatch,
            "explicit effect contract forms a self-reference cycle",
            cycle.edges[0].clone(),
            cycle
                .nodes
                .iter()
                .map(|node| graph[*node].declaration.clone())
                .collect(),
        ));
    }
    Ok(())
}

pub(super) fn normalize_callable_shapes(
    project: &ResolvedProject,
    normalizer: &mut SourceTypeNormalizer,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    traits: &TraitEnvironment,
    inference: &mut TypeInference,
    documents: &[ContractDocument],
) -> Result<(), CheckDiagnostic> {
    let mut implicit = BTreeMap::new();
    for (identity, header) in headers.iter_mut() {
        for (index, (_, source)) in header.source_shapes.iter().enumerate() {
            let crate::project::ResolvedShapeKind::Callable { effects, .. } = shape_kind(source)
            else {
                unreachable!()
            };
            if effects.is_none() {
                let formal = EffectFormal {
                    owner: identity.clone(),
                    ordinal: header.effect_formals.len(),
                };
                implicit.insert((identity.clone(), index), formal.clone());
                if header.body.is_some()
                    && !identity
                        .owner
                        .as_ref()
                        .is_some_and(|owner| owner.kind == EntityKind::TraitImpl)
                {
                    header.flexible_effects.insert(formal.clone());
                }
                header.effect_formals.push((None, formal));
            }
        }
    }
    for identity in headers.keys().cloned().collect::<Vec<_>>() {
        let header = &headers[&identity];
        let mut inputs = Vec::new();
        let mut shapes = BTreeMap::new();
        for (index, (formal, source)) in header.source_shapes.iter().enumerate() {
            let crate::project::ResolvedShapeKind::Callable {
                parameters,
                return_type,
                effects,
            } = shape_kind(source)
            else {
                unreachable!()
            };
            let mut typed = Vec::new();
            for parameter in parameters {
                if parameter.escape.is_some()
                    || parameter.mode.is_some_and(|(_, mode)| {
                        matches!(mode, ParameterMode::MutBorrow | ParameterMode::Call)
                    })
                {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "callback shape requires an unsupported scoped or mutable entry",
                        header.context.origin(parameter.span),
                        Vec::new(),
                    ));
                }
                typed.push((
                    normalizer.normalize_with_formals(&parameter.ty, &header.formal_by_identity)?,
                    parameter
                        .mode
                        .map_or(ParameterMode::Borrow, |(_, mode)| mode),
                ));
            }
            let effect = if let Some(effects) = effects {
                source_effect_row(
                    effects,
                    SourceEffectScope {
                        origin: &header.origin,
                        effect_formals: &header.effect_formals,
                        use_kind: EffectUse::Runtime,
                    },
                    normalizer,
                    project,
                    headers,
                    &mut inputs,
                )?
            } else {
                CheckedEffect::singleton(EffectTerm::Formal(
                    implicit[&(identity.clone(), index)].clone(),
                ))
            };
            let shape = CallableShape {
                parameters: typed,
                result: normalizer
                    .normalize_with_formals(return_type, &header.formal_by_identity)?,
                effect,
            };
            inputs.push(LocatedInput {
                exposed: false,
                origin: CheckOrigin::Source(header.context.origin(source.span)),
                value: SemanticInput::Shape(shape.clone()),
            });
            if shapes.insert(formal.clone(), shape).is_some() {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    "one actual callable must have a unique callable shape",
                    header.context.origin(source.span),
                    Vec::new(),
                ));
            }
        }
        headers
            .get_mut(&identity)
            .unwrap()
            .semantic_inputs
            .extend(inputs);
        headers.get_mut(&identity).unwrap().shapes = shapes;
    }
    merge_contract_shapes(project, normalizer, headers, traits, documents, inference)?;
    for implementation in &traits.implementations {
        let Some(bound) = &implementation.trait_use else {
            continue;
        };
        let definition = &traits.traits[&bound.declaration];
        for (name, member) in &implementation.methods {
            let expected = headers[&definition.methods[name]].clone();
            let actual = &headers[member];
            let mut types =
                std::iter::once((definition.self_type.clone(), implementation.target.clone()))
                    .chain(
                        definition
                            .formals
                            .iter()
                            .cloned()
                            .zip(bound.arguments.iter().cloned()),
                    )
                    .collect::<BTreeMap<_, _>>();
            types.extend(
                expected.declared_formals.iter().cloned().zip(
                    actual
                        .declared_formals
                        .iter()
                        .cloned()
                        .map(|formal| CheckedType::Formal(Box::new(formal))),
                ),
            );
            let explicit = actual
                .effect_formals
                .iter()
                .filter(|(source, _)| source.is_some())
                .collect::<Vec<_>>();
            if explicit.len() > expected.effect_formals.len() {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    "impl adds effect binders to its trait contract",
                    actual.origin.clone(),
                    vec![expected.origin.clone()],
                ));
            }
            let mut effects = explicit
                .iter()
                .enumerate()
                .map(|(index, (_, formal))| {
                    (
                        (*formal).clone(),
                        CheckedEffect::singleton(EffectTerm::Formal(
                            expected.effect_formals[index].1.clone(),
                        )),
                    )
                })
                .collect::<BTreeMap<_, _>>();
            let mut shapes = BTreeMap::new();
            for (formal, shape) in &expected.shapes {
                let CheckedType::Formal(actual_formal) = &types[formal] else {
                    unreachable!()
                };
                let mut mapped = CallableShape {
                    parameters: shape
                        .parameters
                        .iter()
                        .map(|(ty, mode)| (instantiate_type(ty, &types), *mode))
                        .collect(),
                    result: instantiate_type(&shape.result, &types),
                    effect: shape.effect.instantiate(&types, &BTreeMap::new()),
                };
                let givens = actual
                    .requirements
                    .iter()
                    .chain(&actual.outer_requirements)
                    .cloned()
                    .collect::<Vec<_>>();
                let mut solver =
                    TraitSolver::new(traits, project, inference, &givens, actual.origin.clone())?;
                mapped.normalize_types(&mut solver)?;
                if let Some(mut provided) = actual.shapes.get(actual_formal.as_ref()).cloned() {
                    provided.normalize_types(&mut solver)?;
                    drop(solver);
                    for term in &provided.effect.0 {
                        if let EffectTerm::Formal(formal) = term
                            && actual
                                .effect_formals
                                .iter()
                                .any(|(source, item)| source.is_none() && item == formal)
                        {
                            effects.insert(formal.clone(), mapped.effect.clone());
                        }
                    }
                    if provided.parameters.len() != mapped.parameters.len() {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            "impl callback shape arity differs from its trait",
                            actual.origin.clone(),
                            vec![expected.origin.clone()],
                        ));
                    }
                    for ((provided, mode), (expected_type, expected_mode)) in
                        provided.parameters.iter().zip(&mapped.parameters)
                    {
                        if mode != expected_mode {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                "impl callback shape mode differs from its trait",
                                actual.origin.clone(),
                                vec![expected.origin.clone()],
                            ));
                        }
                        inference
                            .unify(provided, expected_type)
                            .map_err(|failure| {
                                source_diagnostic(
                                    CheckDiagnosticKind::TypeMismatch,
                                    display_unification_failure(&failure),
                                    actual.origin.clone(),
                                    vec![expected.origin.clone()],
                                )
                            })?;
                    }
                    inference
                        .unify(&provided.result, &mapped.result)
                        .map_err(|failure| {
                            source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                display_unification_failure(&failure),
                                actual.origin.clone(),
                                vec![expected.origin.clone()],
                            )
                        })?;
                    if provided.effect.instantiate(&BTreeMap::new(), &effects) != mapped.effect {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            "impl callback row relationships differ from its trait",
                            actual.origin.clone(),
                            vec![expected.origin.clone()],
                        ));
                    }
                }
                shapes.insert(actual_formal.as_ref().clone(), mapped);
            }
            if actual
                .shapes
                .keys()
                .any(|formal| !shapes.contains_key(formal))
            {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    "impl adds a callback shape requirement",
                    actual.origin.clone(),
                    vec![expected.origin.clone()],
                ));
            }
            let formals = expected
                .effect_formals
                .iter()
                .enumerate()
                .map(|(index, (_, formal))| {
                    (
                        explicit
                            .get(index)
                            .and_then(|(source, _)| (*source).clone()),
                        formal.clone(),
                    )
                })
                .collect();
            let actual = headers.get_mut(member).unwrap();
            actual.effect_formals = formals;
            actual.shapes = shapes;
            actual.flexible_effects.clear();
        }
    }
    for header in headers.values_mut() {
        for parameter in &header.parameters {
            if let Some(operand) = &parameter.callable_operand {
                inference
                    .unify(&parameter.ty, operand)
                    .map_err(|failure| CheckDiagnostic {
                        kind: CheckDiagnosticKind::ContractConflict,
                        message: format!(
                            "callable_use must refer to the parameter's own actual type: {}",
                            display_unification_failure(&failure)
                        ),
                        primary: parameter.mode.as_ref().map(|mode| mode.origin.clone()),
                        related: vec![parameter.type_origin.clone()],
                    })?;
            }
        }
    }
    for header in headers.values() {
        let givens = header
            .requirements
            .iter()
            .chain(&header.outer_requirements)
            .cloned()
            .collect::<Vec<_>>();
        for parameter in &header.parameters {
            if !parameter.callable_use {
                continue;
            }
            if parameter.binding.name == "self" {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "call is not a receiver mode",
                    header.context.origin(parameter.span),
                    Vec::new(),
                ));
            }
            require_shared_callable(
                &parameter.ty,
                header,
                BodyEnvironment {
                    project,
                    headers,
                    traits,
                },
                inference,
                &givens,
                &header.context.origin(parameter.span),
            )?;
        }
    }
    Ok(())
}

fn shape_kind(shape: &crate::project::ResolvedShape) -> &crate::project::ResolvedShapeKind {
    let mut shape = shape;
    while let crate::project::ResolvedShapeKind::Grouped(inner) = &shape.kind {
        shape = inner;
    }
    &shape.kind
}

fn merge_contract_shapes(
    project: &ResolvedProject,
    normalizer: &SourceTypeNormalizer,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    traits: &TraitEnvironment,
    documents: &[ContractDocument],
    inference: &TypeInference,
) -> Result<(), CheckDiagnostic> {
    let mut implicit = BTreeMap::new();
    for (identity, header) in headers.iter_mut() {
        let missing = header
            .contract_shapes
            .first()
            .into_iter()
            .flatten()
            .filter(|shape| shape.effect.is_none())
            .map(|shape| shape.subject.clone())
            .collect::<BTreeSet<_>>();
        for subject in missing {
            let source_implicit = header
                .source_shapes
                .iter()
                .find(|(formal, _)| formal == &subject)
                .is_some_and(|(_, source)| {
                    matches!(
                        shape_kind(source),
                        crate::project::ResolvedShapeKind::Callable { effects: None, .. }
                    )
                });
            let row = if source_implicit {
                header.shapes[&subject].effect.clone()
            } else {
                let formal = EffectFormal {
                    owner: identity.clone(),
                    ordinal: header.effect_formals.len(),
                };
                header.effect_formals.push((None, formal.clone()));
                if header.body.is_some()
                    && !identity
                        .owner
                        .as_ref()
                        .is_some_and(|owner| owner.kind == EntityKind::TraitImpl)
                {
                    header.flexible_effects.insert(formal.clone());
                }
                CheckedEffect::singleton(EffectTerm::Formal(formal))
            };
            implicit.insert((identity.clone(), subject), row);
        }
    }
    for implementation in &traits.implementations {
        let Some(bound) = &implementation.trait_use else {
            continue;
        };
        for (name, method) in &implementation.methods {
            if headers[method].effect_formals.is_empty() && headers[method].source_shapes.is_empty()
            {
                let expected = &traits.traits[&bound.declaration].methods[name];
                let formals = headers[expected]
                    .effect_formals
                    .iter()
                    .map(|(_, formal)| (None, formal.clone()))
                    .collect();
                headers.get_mut(method).unwrap().effect_formals = formals;
            }
        }
    }
    for identity in headers.keys().cloned().collect::<Vec<_>>() {
        let header = &headers[&identity];
        if header.contract_shapes.is_empty() {
            continue;
        }
        let mut inputs = Vec::new();
        let givens = header
            .requirements
            .iter()
            .chain(&header.outer_requirements)
            .cloned()
            .collect::<Vec<_>>();
        let mut solver =
            TraitSolver::new(traits, project, inference, &givens, header.origin.clone())?;
        let mut source_shapes = header.shapes.clone();
        for shape in source_shapes.values_mut() {
            shape.normalize_types(&mut solver)?;
            shape.effect = shape
                .effect
                .clone()
                .reduce_destruction(&normalizer.nominals, &header.origin)?;
        }
        let mut selected: Option<BTreeMap<TypeFormal, CallableShape>> = None;
        for specs in &header.contract_shapes {
            let mut shapes = BTreeMap::new();
            for spec in specs {
                let CheckOrigin::Contract {
                    document_index,
                    json_path,
                } = &spec.origin
                else {
                    unreachable!()
                };
                let context = ContractTypeContext {
                    binding: ContractBindingContext {
                        project,
                        owner: spec.owner,
                        document_index: *document_index,
                        normalizer,
                        traits,
                        headers,
                    },
                    target: &identity,
                    header,
                };
                let effect = if let Some(location) = &spec.effect {
                    let requirement = &documents[location.document_index].0.records
                        [location.record_index]
                        .set
                        .as_ref()
                        .unwrap()
                        .generic_requirements
                        .as_ref()
                        .unwrap()[location.requirement_index];
                    let contract::GenericRequirement::CallableShape { shape, .. } = requirement
                    else {
                        unreachable!()
                    };
                    contract_effect(
                        &context,
                        shape.effect_upper.as_ref().unwrap(),
                        &format!("{json_path}.effect_upper"),
                        &mut inputs,
                    )?
                } else {
                    implicit[&(identity.clone(), spec.subject.clone())].clone()
                };
                let mut shape = CallableShape {
                    parameters: spec.parameters.clone(),
                    result: spec.result.clone(),
                    effect,
                };
                inputs.push(LocatedInput {
                    exposed: false,
                    origin: spec.origin.clone(),
                    value: SemanticInput::Shape(shape.clone()),
                });
                shape
                    .normalize_types(&mut solver)
                    .map_err(|mut diagnostic| {
                        diagnostic.related.extend(diagnostic.primary.take());
                        diagnostic.primary = Some(spec.origin.clone());
                        diagnostic
                    })?;
                shape.effect = shape
                    .effect
                    .reduce_destruction(&normalizer.nominals, &header.origin)?;
                if shapes.insert(spec.subject.clone(), shape).is_some() {
                    return Err(contract_diagnostic(
                        CheckDiagnosticKind::ContractConflict,
                        "generic requirements repeat a callable shape",
                        *document_index,
                        json_path,
                        Vec::new(),
                    ));
                }
            }
            if let Some(previous) = &selected {
                if previous != &shapes {
                    return Err(CheckDiagnostic {
                        kind: CheckDiagnosticKind::ContractConflict,
                        message: "partial records select different callback shapes".to_owned(),
                        primary: specs.first().map(|shape| shape.origin.clone()),
                        related: Vec::new(),
                    });
                }
            } else {
                if header.source_requirements_explicit && source_shapes != shapes {
                    return Err(CheckDiagnostic { kind: CheckDiagnosticKind::Unsupported, message: "different explicit source and contract callback requirements have no selected difference policy".to_owned(), primary: specs.first().map(|shape| shape.origin.clone()), related: vec![CheckOrigin::Source(header.origin.clone())] });
                }
                selected = Some(shapes);
            }
        }
        headers
            .get_mut(&identity)
            .unwrap()
            .semantic_inputs
            .extend(inputs);
        headers.get_mut(&identity).unwrap().shapes = selected.unwrap();
    }
    Ok(())
}

fn closed_value_header(header: &FunctionHeader, inference: &TypeInference) -> bool {
    header.parameters.iter().all(|parameter| {
        parameter.source_type_explicit
            && (parameter.mode.is_some() || is_copy_type(&inference.resolve(&parameter.ty)))
    }) && header.source_return_explicit
        && header.effect_formals.is_empty()
        && header.effect_upper.is_some()
}

pub(super) fn require_shared_callable(
    ty: &CheckedType,
    header: &FunctionHeader,
    environment: BodyEnvironment<'_>,
    inference: &TypeInference,
    givens: &[Requirement],
    origin: &OriginRef,
) -> Result<(CallableShape, Evidence), CheckDiagnostic> {
    let BodyEnvironment {
        project,
        headers,
        traits,
    } = environment;
    let ty = inference.resolve(ty);
    let shape = match &ty {
        CheckedType::Function(value) => {
            let provider = &headers[&value.declaration];
            if !closed_value_header(provider, inference) {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "same-unit named function value requires a closed type, mode and effect header",
                    origin.clone(),
                    vec![provider.origin.clone()],
                ));
            }
            let mapping = value.types.iter().cloned().collect::<BTreeMap<_, _>>();
            let mut unresolved = BTreeSet::new();
            for actual in mapping.values() {
                inference.unresolved_variables(actual, &mut unresolved);
            }
            if unresolved.is_empty() {
                let mut solver =
                    TraitSolver::new(traits, project, inference, givens, origin.clone())?;
                for requirement in provider
                    .requirements
                    .iter()
                    .chain(&provider.outer_requirements)
                {
                    solver.prove(&Requirement {
                        subject: instantiate_type(&requirement.subject, &mapping),
                        bound: instantiate_trait(&requirement.bound, &mapping),
                        origin: requirement.origin.clone(),
                    })?;
                }
            }
            CallableShape {
                parameters: provider
                    .parameters
                    .iter()
                    .map(|parameter| {
                        (
                            instantiate_type(&parameter.ty, &mapping),
                            parameter
                                .mode
                                .as_ref()
                                .map_or(ParameterMode::Borrow, |mode| mode.value),
                        )
                    })
                    .collect(),
                result: instantiate_type(&provider.return_type, &mapping),
                effect: provider
                    .effect_upper
                    .as_ref()
                    .unwrap()
                    .instantiate(&mapping, &BTreeMap::new()),
            }
        }
        CheckedType::Formal(formal) => header
            .shapes
            .iter()
            .find(|(known, _)| inference.formals_equivalent(known, formal))
            .map(|(_, shape)| shape.clone())
            .ok_or_else(|| {
                source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "shared callback requires a known callable shape",
                    origin.clone(),
                    Vec::new(),
                )
            })?,
        _ => {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "indirect calls require a named function value or a shared Fn formal",
                origin.clone(),
                Vec::new(),
            ));
        }
    };
    let requirement = Requirement {
        subject: ty,
        bound: TraitUse {
            declaration: project.core_roles.function.clone(),
            arguments: Vec::new(),
            associated: BTreeMap::new(),
        },
        origin: CheckOrigin::Source(origin.clone()),
    };
    let evidence = TraitSolver::new(traits, project, inference, givens, origin.clone())?.prove(&requirement).map_err(|_| source_diagnostic(CheckDiagnosticKind::Unsupported, "this callback has no guaranteed shared Fn entry; FnMut/FnOnce specialization is not supported", origin.clone(), Vec::new()))?;
    Ok((shape, evidence))
}

pub(super) fn solve_effect_actuals(
    callee: &FunctionHeader,
    caller: &FunctionHeader,
    types: &BTreeMap<TypeFormal, CheckedType>,
    environment: BodyEnvironment<'_>,
    schemes: &BTreeMap<EntityId, CallableScheme>,
    inference: &mut TypeInference,
    origin: &OriginRef,
) -> Result<Vec<(EffectFormal, CheckedEffect)>, CheckDiagnostic> {
    let givens = caller
        .requirements
        .iter()
        .chain(&caller.outer_requirements)
        .cloned()
        .collect::<Vec<_>>();
    let mut constraints = Vec::new();
    let mut actuals = callee
        .effect_formals
        .iter()
        .map(|(_, formal)| (formal.clone(), CheckedEffect::default()))
        .collect::<BTreeMap<_, _>>();
    for (formal, shape) in &callee.shapes {
        let ty = types
            .get(formal)
            .cloned()
            .unwrap_or_else(|| CheckedType::Formal(Box::new(formal.clone())));
        let (mut actual, _) =
            require_shared_callable(&ty, caller, environment, inference, &givens, origin)?;
        let mut shape = CallableShape {
            parameters: shape
                .parameters
                .iter()
                .map(|(ty, mode)| (instantiate_type(ty, types), *mode))
                .collect(),
            result: instantiate_type(&shape.result, types),
            effect: shape.effect.instantiate(types, &BTreeMap::new()),
        };
        let mut solver = TraitSolver::new(
            environment.traits,
            environment.project,
            inference,
            &givens,
            origin.clone(),
        )?;
        actual.normalize_types(&mut solver)?;
        shape.normalize_types(&mut solver)?;
        drop(solver);
        if actual.parameters.len() != shape.parameters.len() {
            return Err(source_diagnostic(
                CheckDiagnosticKind::CallMismatch,
                "callback parameter arity differs from its expected shape",
                origin.clone(),
                Vec::new(),
            ));
        }
        for ((actual, actual_mode), (expected, expected_mode)) in
            actual.parameters.iter().zip(&shape.parameters)
        {
            if actual_mode != expected_mode {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::CallMismatch,
                    "callback parameter modes are invariant",
                    origin.clone(),
                    Vec::new(),
                ));
            }
            inference.unify(actual, expected).map_err(|failure| {
                source_diagnostic(
                    CheckDiagnosticKind::CallMismatch,
                    display_unification_failure(&failure),
                    origin.clone(),
                    Vec::new(),
                )
            })?;
        }
        inference
            .unify(&actual.result, &shape.result)
            .map_err(|failure| {
                source_diagnostic(
                    CheckDiagnosticKind::CallMismatch,
                    display_unification_failure(&failure),
                    origin.clone(),
                    Vec::new(),
                )
            })?;
        let actual = actual.effect.reduce_methods(
            environment,
            schemes,
            &BTreeMap::new(),
            inference,
            origin,
            caller,
        )?;
        let expected = shape.effect.reduce_methods(
            environment,
            schemes,
            &BTreeMap::new(),
            inference,
            origin,
            caller,
        )?;
        constraints.push((actual, expected));
    }
    let mut work = 0;
    loop {
        let before = actuals.clone();
        let revision = inference.revision;
        let mut pending = constraints.clone();
        for (formal, bounds) in &callee.effect_caps {
            for bound in bounds {
                pending.push((
                    actuals[formal].clone(),
                    bound.instantiate(types, &BTreeMap::new()),
                ));
            }
        }
        for (actual, expected) in &pending {
            work += 1;
            if work > 8192 {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "incomplete callback effect solve: 8192 row constraints exhausted",
                    origin.clone(),
                    Vec::new(),
                ));
            }
            // Unify payload/type actuals before subtracting the fixed heads.
            // This uses the same TypeInference and call mapping as the signature.
            let expanded = expected.instantiate(&BTreeMap::new(), &actuals);
            let mut payloads = actual.clone();
            payloads.merge(&expanded, inference, origin)?;
            let actual = actual.normalized(inference);
            let expected = expected.normalized(inference);
            let tails = expected
                .0
                .iter()
                .filter_map(|term| match term {
                    EffectTerm::Formal(formal) if actuals.contains_key(formal) => Some(formal),
                    _ => None,
                })
                .collect::<Vec<_>>();
            if let [formal] = tails.as_slice() {
                let fixed = expected.0.iter().filter(|term| !matches!(term, EffectTerm::Formal(formal) if actuals.contains_key(formal))).cloned().collect::<BTreeSet<_>>();
                let remainder = CheckedEffect(actual.0.difference(&fixed).cloned().collect());
                actuals
                    .get_mut(*formal)
                    .unwrap()
                    .merge(&remainder, inference, origin)?;
            }
        }
        if revision != inference.revision {
            // A newly solved payload can remove an earlier lower bound. Restart
            // row closure at bottom; retain every solved type constraint.
            for row in actuals.values_mut() {
                *row = CheckedEffect::default();
            }
            continue;
        }
        if before == actuals {
            break;
        }
    }
    let mut caller_caps = caller.effect_caps.clone();
    for (formal, bounds) in &inference.effect_caps {
        caller_caps
            .entry(formal.clone())
            .or_default()
            .extend(bounds.iter().cloned());
    }
    for (formal, bounds) in &callee.effect_caps {
        for upper in bounds {
            constraints.push((actuals[formal].clone(), upper.instantiate(types, &actuals)));
        }
    }
    for (actual, expected) in &constraints {
        let expected = expected.instantiate(&BTreeMap::new(), &actuals);
        for term in &actual.0 {
            if let EffectTerm::Formal(formal) = term
                && caller.flexible_effects.contains(formal)
                && !expected.0.contains(term)
            {
                caller_caps
                    .entry(formal.clone())
                    .or_default()
                    .push(expected.clone());
                inference
                    .effect_caps
                    .entry(formal.clone())
                    .or_default()
                    .push(expected.clone());
            }
        }
        actual
            .subset_inferred(
                &expected,
                &caller_caps,
                (&CheckOrigin::Source(origin.clone()), origin),
                inference,
            )
            .map_err(|_| {
                source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    "callback rows have no unique legal minimum satisfying the expected row",
                    origin.clone(),
                    Vec::new(),
                )
            })?;
    }
    for (formal, bounds) in &callee.effect_caps {
        for upper in bounds {
            actuals[formal].subset_inferred(
                &upper.instantiate(types, &actuals),
                &caller_caps,
                (&CheckOrigin::Source(origin.clone()), origin),
                inference,
            )?;
        }
    }
    Ok(callee
        .effect_formals
        .iter()
        .map(|(_, formal)| (formal.clone(), actuals[formal].clone()))
        .collect())
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct FunctionValue {
    pub(super) declaration: EntityId,
    pub(super) types: Vec<(TypeFormal, CheckedType)>,
}

#[derive(Clone, PartialEq, Eq)]
pub(super) struct CallableShape {
    pub(super) parameters: Vec<(CheckedType, ParameterMode)>,
    pub(super) result: CheckedType,
    pub(super) effect: CheckedEffect,
}

impl CallableShape {
    pub(super) fn normalize_types(
        &mut self,
        solver: &mut TraitSolver<'_>,
    ) -> Result<(), CheckDiagnostic> {
        for (ty, _) in &mut self.parameters {
            *ty = solver.normalize(ty)?;
        }
        self.result = solver.normalize(&self.result)?;
        self.effect = self.effect.normalize_types(solver)?;
        Ok(())
    }
}

#[derive(Clone, Default, PartialEq, Eq)]
pub(super) struct DestructionShape {
    parameters: BTreeSet<usize>,
    projection: bool,
}

pub(super) fn close_destruction_shapes(nominals: &mut BTreeMap<EntityId, NominalDefinition>) {
    let mut reverse = BTreeMap::<EntityId, BTreeSet<EntityId>>::new();
    for (identity, definition) in nominals.iter() {
        let mut pending = definition
            .constructors
            .values()
            .flat_map(|constructor| constructor.fields.iter().map(|field| &field.ty))
            .collect::<Vec<_>>();
        while let Some(ty) = pending.pop() {
            match ty {
                CheckedType::Nominal(nominal) => {
                    reverse
                        .entry(nominal.declaration.clone())
                        .or_default()
                        .insert(identity.clone());
                    pending.extend(&nominal.arguments);
                }
                CheckedType::Tuple(elements) => pending.extend(elements),
                _ => {}
            }
        }
    }
    let mut pending = nominals.keys().cloned().collect::<VecDeque<_>>();
    let mut queued = nominals.keys().cloned().collect::<BTreeSet<_>>();
    while let Some(identity) = pending.pop_front() {
        queued.remove(&identity);
        let definition = &nominals[&identity];
        let mut shape = DestructionShape::default();
        let mut types = definition
            .constructors
            .values()
            .flat_map(|constructor| constructor.fields.iter().map(|field| &field.ty))
            .collect::<Vec<_>>();
        while let Some(ty) = types.pop() {
            match ty {
                CheckedType::Formal(formal) => {
                    if let Some(index) = definition
                        .formals
                        .iter()
                        .position(|candidate| candidate == formal.as_ref())
                    {
                        shape.parameters.insert(index);
                    } else {
                        shape.projection = true;
                    }
                }
                CheckedType::Projection(_) => shape.projection = true,
                CheckedType::Tuple(elements) => types.extend(elements),
                CheckedType::Nominal(nominal) => {
                    let child = &nominals[&nominal.declaration].destruction;
                    shape.projection |= child.projection;
                    types.extend(
                        child
                            .parameters
                            .iter()
                            .map(|index| &nominal.arguments[*index]),
                    );
                }
                _ => {}
            }
        }
        if definition.destruction != shape {
            nominals.get_mut(&identity).unwrap().destruction = shape;
            for caller in reverse.get(&identity).into_iter().flatten() {
                if queued.insert(caller.clone()) {
                    pending.push_back(caller.clone());
                }
            }
        }
    }
}

impl CallableShape {
    pub(super) fn close(&self, closure: &BodyClosure<'_>) -> Self {
        Self {
            parameters: self
                .parameters
                .iter()
                .map(|(ty, mode)| (closure.close_type(ty), *mode))
                .collect(),
            result: closure.close_type(&self.result),
            effect: self.effect.close(closure),
        }
    }
}

pub(super) fn collect_header_inputs(
    header: &FunctionHeader,
    inference: &TypeInference,
    variables: &mut BTreeSet<TypeVariable>,
    formals: &mut BTreeSet<TypeFormal>,
) {
    for requirement in header.requirements.iter().chain(&header.outer_requirements) {
        for ty in std::iter::once(&requirement.subject)
            .chain(&requirement.bound.arguments)
            .chain(requirement.bound.associated.values())
        {
            collect_inference_inputs(inference, ty, variables, formals);
        }
    }
    for shape in header.shapes.values() {
        for ty in shape
            .parameters
            .iter()
            .map(|(ty, _)| ty)
            .chain(std::iter::once(&shape.result))
        {
            collect_inference_inputs(inference, ty, variables, formals);
        }
        collect_effect_inputs(&shape.effect, inference, variables, formals);
    }
    for row in header.effect_upper.iter().chain(&header.trait_upper) {
        collect_effect_inputs(row, inference, variables, formals);
    }
}

fn collect_effect_inputs(
    row: &CheckedEffect,
    inference: &TypeInference,
    variables: &mut BTreeSet<TypeVariable>,
    formals: &mut BTreeSet<TypeFormal>,
) {
    for term in &row.0 {
        match term {
            EffectTerm::Handled(_, arguments) => {
                for ty in arguments {
                    collect_inference_inputs(inference, ty, variables, formals);
                }
            }
            EffectTerm::Failure(ty)
            | EffectTerm::Destruction(ty)
            | EffectTerm::SelectedCall(ty) => {
                collect_inference_inputs(inference, ty, variables, formals)
            }
            EffectTerm::Method { types, effects, .. } => {
                for (_, ty) in types {
                    collect_inference_inputs(inference, ty, variables, formals);
                }
                for row in effects {
                    collect_effect_inputs(row, inference, variables, formals);
                }
            }
            _ => {}
        }
    }
}

pub(super) fn effect_for_dependency(
    target: &EntityId,
    header: &FunctionHeader,
    scheme: Option<&CallableScheme>,
    types: &BTreeMap<TypeFormal, CheckedType>,
    effects: &[(EffectFormal, CheckedEffect)],
) -> CheckedEffect {
    if header.body.is_none() && header.effect_upper.is_none() {
        CheckedEffect::singleton(EffectTerm::Method {
            method: target.clone(),
            types: types
                .iter()
                .map(|(formal, ty)| (formal.clone(), ty.clone()))
                .collect(),
            effects: effects.iter().map(|(_, row)| row.clone()).collect(),
        })
    } else {
        scheme
            .map(|scheme| &scheme.effect)
            .or(header.trait_upper.as_ref())
            .or(header.effect_upper.as_ref())
            .cloned()
            .unwrap_or_default()
            .instantiate(types, &effects.iter().cloned().collect())
    }
}

impl CheckedEffect {
    pub(super) fn dependencies(
        &self,
        traits: &TraitEnvironment,
        project: &ResolvedProject,
        headers: &BTreeMap<EntityId, FunctionHeader>,
        inference: &TypeInference,
        givens: &[Requirement],
        origin: &OriginRef,
    ) -> Result<Vec<EntityId>, CheckDiagnostic> {
        let mut dependencies = BTreeSet::new();
        for term in &self.0 {
            if let EffectTerm::SelectedCall(CheckedType::Function(value)) = term {
                dependencies.insert(value.declaration.clone());
            }

            if let EffectTerm::Method {
                method,
                types,
                effects,
            } = term
            {
                let selected = method_actual(
                    method,
                    types,
                    effects,
                    BodyEnvironment {
                        project,
                        headers,
                        traits,
                    },
                    inference,
                    givens,
                    origin,
                )?;
                if headers[method].effect_upper.is_some() {
                    dependencies.insert(method.clone());
                } else if let Some((target, _, _)) = selected {
                    dependencies.insert(target);
                }
            }
        }
        Ok(dependencies.into_iter().collect())
    }

    fn reduce_methods(
        &self,
        environment: BodyEnvironment<'_>,
        schemes: &BTreeMap<EntityId, CallableScheme>,
        rows: &BTreeMap<EntityId, CheckedEffect>,
        inference: &mut TypeInference,
        origin: &OriginRef,
        caller: &FunctionHeader,
    ) -> Result<Self, CheckDiagnostic> {
        let BodyEnvironment {
            project,
            headers,
            traits,
        } = environment;
        let givens = &caller
            .requirements
            .iter()
            .chain(&caller.outer_requirements)
            .cloned()
            .collect::<Vec<_>>();
        let mut result = Self::default();
        let mut pending = self.0.iter().cloned().collect::<Vec<_>>();
        let mut work = 0;
        while let Some(term) = pending.pop() {
            work += 1;
            if work > 8192 {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "incomplete method effect solve: 8192 expansion steps exhausted",
                    origin.clone(),
                    Vec::new(),
                ));
            }
            if let EffectTerm::SelectedCall(ty) = &term {
                let (shape, _) =
                    require_shared_callable(ty, caller, environment, inference, givens, origin)?;
                if !shape.effect.0.contains(&term) {
                    pending.extend(shape.effect.0);
                    continue;
                }
            }
            if let EffectTerm::Method {
                method,
                types,
                effects,
            } = &term
            {
                let selected = method_actual(
                    method,
                    types,
                    effects,
                    BodyEnvironment {
                        project,
                        headers,
                        traits,
                    },
                    inference,
                    givens,
                    origin,
                )?;
                if let Some(upper) = &headers[method].effect_upper {
                    let effect_mapping = headers[method]
                        .effect_formals
                        .iter()
                        .map(|(_, formal)| formal.clone())
                        .zip(effects.iter().cloned())
                        .collect();
                    pending.extend(
                        upper
                            .instantiate(&types.iter().cloned().collect(), &effect_mapping)
                            .0,
                    );
                    continue;
                }
                if let Some((target, mapping, effect_mapping)) = selected {
                    let row = schemes
                        .get(&target)
                        .map(|scheme| &scheme.effect)
                        .or_else(|| rows.get(&target))
                        .ok_or_else(|| {
                            source_diagnostic(
                                CheckDiagnosticKind::Unsupported,
                                "method effect dependency has not closed",
                                origin.clone(),
                                entity_origin(&target).into_iter().collect(),
                            )
                        })?;
                    pending.extend(row.instantiate(&mapping, &effect_mapping).0);
                    continue;
                }
            }
            result.merge(&Self::singleton(term), inference, origin)?;
        }
        Ok(result)
    }
}

type MethodActual = (
    EntityId,
    BTreeMap<TypeFormal, CheckedType>,
    BTreeMap<EffectFormal, CheckedEffect>,
);

fn method_actual(
    method: &EntityId,
    types: &[(TypeFormal, CheckedType)],
    effects: &[CheckedEffect],
    environment: BodyEnvironment<'_>,
    inference: &TypeInference,
    givens: &[Requirement],
    origin: &OriginRef,
) -> Result<Option<MethodActual>, CheckDiagnostic> {
    let BodyEnvironment {
        project,
        headers,
        traits,
    } = environment;
    let (owner, definition) = traits
        .traits
        .iter()
        .find(|(_, definition)| definition.methods.values().any(|member| member == method))
        .expect("method effect belongs to an exact trait");
    let actuals = types.iter().cloned().collect::<BTreeMap<_, _>>();
    let subject = actuals[&definition.self_type].clone();
    let arguments = definition
        .formals
        .iter()
        .map(|formal| actuals[formal].clone())
        .collect();
    let requirement = Requirement {
        subject,
        bound: TraitUse {
            declaration: owner.clone(),
            arguments,
            associated: BTreeMap::new(),
        },
        origin: CheckOrigin::Source(origin.clone()),
    };
    let mut solver = TraitSolver::new(traits, project, inference, givens, origin.clone())?;
    let evidence = solver.prove(&requirement)?;
    let Evidence::Source {
        implementation,
        mut mapping,
        ..
    } = evidence
    else {
        return Ok(None);
    };
    let implementation = traits
        .implementations
        .iter()
        .find(|item| item.identity == implementation)
        .unwrap();
    let target = implementation.methods[&method.name].clone();
    mapping.extend(
        headers[method]
            .declared_formals
            .iter()
            .zip(&headers[&target].declared_formals)
            .map(|(formal, target)| (target.clone(), actuals[formal].clone())),
    );
    let effect_mapping = headers[&target]
        .effect_formals
        .iter()
        .map(|(_, formal)| formal.clone())
        .zip(effects.iter().cloned())
        .collect();
    Ok(Some((target, mapping, effect_mapping)))
}

enum SourceEffectFrame<'a> {
    Row(&'a ResolvedEffectSet, BTreeMap<TypeFormal, CheckedType>),
    Atom(
        &'a crate::project::ResolvedEffect,
        BTreeMap<TypeFormal, CheckedType>,
    ),
    Union(usize),
    Method {
        method: Box<EntityId>,
        types: Vec<(TypeFormal, CheckedType)>,
        count: usize,
    },
}

pub(super) struct SourceEffectScope<'a> {
    pub(super) origin: &'a OriginRef,
    pub(super) effect_formals: &'a [(Option<EntityId>, EffectFormal)],
    pub(super) use_kind: EffectUse,
}

pub(super) fn source_effect_row(
    source: &ResolvedEffectSet,
    scope: SourceEffectScope<'_>,
    normalizer: &mut SourceTypeNormalizer,
    project: &ResolvedProject,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    inputs: &mut Vec<LocatedInput>,
) -> Result<CheckedEffect, CheckDiagnostic> {
    let aliases = project
        .modules
        .values()
        .flat_map(|module| module.body.iter().flat_map(|body| &body.declarations))
        .filter_map(|declaration| match &declaration.kind {
            ResolvedDeclarationKind::EffectAlias {
                type_parameters,
                effects,
            } => Some((
                declaration.identity.as_ref().unwrap(),
                (type_parameters, effects),
            )),
            _ => None,
        })
        .collect::<BTreeMap<_, _>>();
    let mut work = vec![SourceEffectFrame::Row(source, BTreeMap::new())];
    let mut values = Vec::<CheckedEffect>::new();
    let mut steps = 0;
    while let Some(frame) = work.pop() {
        steps += 1;
        if steps > 8192 {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "incomplete source effect solve: 8192 expansion steps exhausted",
                scope.origin.clone(),
                Vec::new(),
            ));
        }
        match frame {
            SourceEffectFrame::Row(row, mapping) => {
                work.push(SourceEffectFrame::Union(row.effects.len()));
                work.extend(
                    row.effects
                        .iter()
                        .rev()
                        .map(|effect| SourceEffectFrame::Atom(effect, mapping.clone())),
                );
            }
            SourceEffectFrame::Union(count) => {
                let rows = values.split_off(values.len() - count);
                values.push(CheckedEffect(
                    rows.into_iter().flat_map(|row| row.0).collect(),
                ));
            }
            SourceEffectFrame::Method {
                method,
                types,
                count,
            } => {
                let effects = values.split_off(values.len() - count);
                values.push(CheckedEffect::singleton(EffectTerm::Method {
                    method: *method,
                    types,
                    effects,
                }));
            }
            SourceEffectFrame::Atom(effect, mapping) => {
                let target = match &effect.reference {
                    ResolvedReference::Exact { target, .. } => target,
                    ResolvedReference::Selection { members, .. } => members
                        .last()
                        .and_then(|member| member.declaration.as_ref())
                        .expect("method effect references are exact"),
                };
                let origin = SourceContext::from_origin(reference_origin(&effect.reference))
                    .origin(effect.span);
                let arguments = effect
                    .arguments
                    .iter()
                    .map(|ty| {
                        normalizer
                            .normalize(ty)
                            .map(|ty| instantiate_type(&ty, &mapping))
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                if matches!(target.kind, EntityKind::Effect | EntityKind::EffectAlias) {
                    inputs.push(LocatedInput {
                        exposed: false,
                        origin: CheckOrigin::Source(origin.clone()),
                        value: SemanticInput::EffectApplication(target.clone(), arguments.clone()),
                    });
                }
                let term = match target.kind {
                    EntityKind::LanguageEffect => match target.name.as_str() {
                        "console" | "fs" | "process" if arguments.is_empty() => {
                            EffectTerm::System(target.clone())
                        }
                        "mut" if arguments.is_empty() => EffectTerm::Mut,
                        "unsafe" if arguments.is_empty() => EffectTerm::Unsafe,
                        "fail" if arguments.len() == 1 => EffectTerm::Failure(arguments[0].clone()),
                        _ => {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                "effect atom has the wrong type arity",
                                origin,
                                Vec::new(),
                            ));
                        }
                    },
                    EntityKind::Effect => {
                        if normalizer.arities[target] != arguments.len() {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                "handled effect has the wrong type arity",
                                origin,
                                Vec::new(),
                            ));
                        }
                        EffectTerm::Handled(target.clone(), arguments)
                    }
                    EntityKind::EffectParameter => {
                        let formal = scope
                            .effect_formals
                            .iter()
                            .find(|(identity, _)| identity.as_ref() == Some(target))
                            .map(|(_, formal)| formal.clone())
                            .ok_or_else(|| {
                                source_diagnostic(
                                    CheckDiagnosticKind::TypeMismatch,
                                    "effect formal does not belong to this callable",
                                    origin.clone(),
                                    Vec::new(),
                                )
                            })?;
                        EffectTerm::Formal(formal)
                    }
                    EntityKind::EffectAlias => {
                        let (parameters, effects) = aliases[target];
                        if parameters.len() != arguments.len() {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                "effect alias has the wrong type arity",
                                origin,
                                Vec::new(),
                            ));
                        }
                        let mapping = parameters
                            .iter()
                            .map(|parameter| {
                                normalizer.source_formals[&parameter.binding.identity].clone()
                            })
                            .zip(arguments)
                            .collect();
                        work.push(SourceEffectFrame::Row(effects, mapping));
                        continue;
                    }
                    EntityKind::Method => {
                        let method = headers.get(target).ok_or_else(|| {
                            source_diagnostic(
                                CheckDiagnosticKind::Unsupported,
                                "method effect reference requires a supported callable",
                                origin.clone(),
                                Vec::new(),
                            )
                        })?;
                        let formals = method
                            .outer_formals
                            .iter()
                            .chain(&method.declared_formals)
                            .cloned()
                            .collect::<Vec<_>>();
                        if formals.len() != arguments.len()
                            || method.effect_formals.len() != effect.effect_arguments.len()
                        {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                "method effect actual arity differs from its owner scheme",
                                origin,
                                Vec::new(),
                            ));
                        }
                        work.push(SourceEffectFrame::Method {
                            method: Box::new(target.clone()),
                            types: formals.into_iter().zip(arguments).collect(),
                            count: effect.effect_arguments.len(),
                        });
                        work.extend(effect.effect_arguments.iter().rev().map(|argument| {
                            SourceEffectFrame::Row(&argument.effects, mapping.clone())
                        }));
                        continue;
                    }
                    _ => {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            "invalid effect term identity",
                            origin,
                            Vec::new(),
                        ));
                    }
                };
                values.push(CheckedEffect::singleton(term));
            }
        }
    }
    let row = values.pop().expect("one expanded source row");
    inputs.push(LocatedInput {
        exposed: false,
        origin: CheckOrigin::Source(scope.origin.clone()),
        value: SemanticInput::Effect(row.clone(), scope.use_kind),
    });
    Ok(row)
}

pub(super) fn closed_identity_type(ty: &CheckedType) -> bool {
    match ty {
        CheckedType::Infer(_) | CheckedType::Formal(_) | CheckedType::Projection(_) => false,
        CheckedType::Tuple(elements) => elements.iter().all(closed_identity_type),
        CheckedType::Nominal(nominal) => nominal.arguments.iter().all(closed_identity_type),
        CheckedType::Function(value) => value.types.iter().all(|(_, ty)| closed_identity_type(ty)),
        _ => true,
    }
}

pub(super) fn collect_operation_headers(
    project: &ResolvedProject,
    normalizer: &mut SourceTypeNormalizer,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    traits: &TraitEnvironment,
    public_exports: &BTreeSet<EntityId>,
) -> Result<(), CheckDiagnostic> {
    for module in project.modules.values() {
        for declaration in module.body.iter().flat_map(|body| &body.declarations) {
            let ResolvedDeclarationKind::Effect {
                type_parameters,
                operations,
            } = &declaration.kind
            else {
                continue;
            };
            let owner = declaration.identity.as_ref().unwrap();
            let public_export = public_exports.contains(owner);
            if public_export {
                validate_public_generic_types(
                    type_parameters,
                    public_exports,
                    &normalizer.aliases,
                )?;
            }
            let outer_formals = type_parameters
                .iter()
                .map(|parameter| normalizer.source_formals[&parameter.binding.identity].clone())
                .collect::<Vec<_>>();
            let formal_by_identity = type_parameters
                .iter()
                .zip(&outer_formals)
                .map(|(parameter, formal)| (parameter.binding.identity.clone(), formal.clone()))
                .collect::<BTreeMap<_, _>>();
            for operation in operations {
                let origin = entity_origin(&operation.identity).unwrap();
                let context = SourceContext::from_origin(&origin);
                let mut parameters = Vec::new();
                for parameter in &operation.parameters {
                    if parameter.escape.is_some()
                        || parameter.mode.is_some_and(|(_, mode)| {
                            !matches!(mode, ParameterMode::Borrow | ParameterMode::Move)
                        })
                    {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "operation requires an unsupported parameter convention",
                            parameter.binding.origin.clone(),
                            Vec::new(),
                        ));
                    }
                    let Some(ResolvedParameterAnnotation::Type(ty)) = &parameter.annotation else {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "operation requires a closed supported parameter type",
                            parameter.binding.origin.clone(),
                            Vec::new(),
                        ));
                    };
                    if public_export {
                        validate_public_type_visibility(public_exports, ty, &normalizer.aliases)?;
                    }
                    parameters.push(HeaderParameter {
                        binding: parameter.binding.identity.clone(),
                        span: parameter.span,
                        ty: normalizer.normalize_with_formals(ty, &formal_by_identity)?,
                        type_origin: CheckOrigin::Source(parameter.binding.origin.clone()),
                        source_type_explicit: true,
                        callable_use: false,
                        callable_operand: None,
                        mode: Some(SelectedMode {
                            value: parameter
                                .mode
                                .map_or(ParameterMode::Borrow, |(_, mode)| mode),
                            origin: CheckOrigin::Source(parameter.binding.origin.clone()),
                        }),
                    });
                }
                if public_export {
                    validate_public_type_visibility(
                        public_exports,
                        &operation.return_type,
                        &normalizer.aliases,
                    )?;
                }
                headers.insert(
                    operation.identity.clone(),
                    FunctionHeader {
                        identity: operation.identity.clone(),
                        context,
                        origin: origin.clone(),
                        public_export,
                        declared_formals: Vec::new(),
                        outer_formals: outer_formals.clone(),
                        formal_by_identity: formal_by_identity.clone(),
                        parameters,
                        return_type: normalizer
                            .normalize_with_formals(&operation.return_type, &formal_by_identity)?,
                        return_origin: CheckOrigin::Source(origin),
                        source_return_explicit: true,
                        semantic_inputs: Vec::new(),
                        body: None,
                        requirements: Vec::new(),
                        outer_requirements: traits
                            .requirements
                            .get(owner)
                            .cloned()
                            .unwrap_or_default(),
                        source_effects: None,
                        module_upper: None,
                        effect_upper: Some(CheckedEffect::singleton(EffectTerm::Handled(
                            owner.clone(),
                            outer_formals
                                .iter()
                                .cloned()
                                .map(|formal| CheckedType::Formal(Box::new(formal)))
                                .collect(),
                        ))),
                        trait_upper: None,
                        effect_formals: Vec::new(),
                        effect_dependencies: Vec::new(),
                        source_shapes: Vec::new(),
                        shapes: BTreeMap::new(),
                        flexible_effects: BTreeSet::new(),
                        effect_caps: BTreeMap::new(),
                        value_uses: Vec::new(),
                        contract_shapes: Vec::new(),
                        effect_origin: None,
                        source_requirements_explicit: false,
                    },
                );
            }
        }
    }
    Ok(())
}

impl BodyChecker<'_> {
    pub(super) fn check_function_value(
        &mut self,
        target: &EntityId,
        origin: OriginRef,
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let header = &self.environment.headers[target];
        if !closed_value_header(header, self.inference) {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "same-unit named function value requires a closed type, mode and effect header",
                origin,
                vec![header.origin.clone()],
            ));
        }
        let mut used = BTreeSet::new();
        let mut variables = BTreeSet::new();
        for ty in header
            .parameters
            .iter()
            .map(|parameter| &parameter.ty)
            .chain(std::iter::once(&header.return_type))
        {
            self.inference.referenced_formals(ty, &mut used);
        }
        collect_header_inputs(header, self.inference, &mut variables, &mut used);
        let types = header
            .outer_formals
            .iter()
            .chain(&header.declared_formals)
            .filter(|formal| used.contains(*formal))
            .cloned()
            .map(|formal| (formal, self.inference.fresh()))
            .collect();
        let value = FunctionValue {
            declaration: target.clone(),
            types,
        };
        self.value_uses.push((value.clone(), origin.clone()));
        Ok(TypedExpr {
            span: origin.span,
            ty: CheckedType::Function(Box::new(value.clone())),
            kind: TypedExprKind::FunctionValue(Box::new(value)),
        })
    }

    pub(super) fn check_indirect_call(
        &mut self,
        origin: OriginRef,
        callee: &ResolvedExpr,
        arguments: &[ResolvedCallArgument],
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let callee = self.check_expr(callee)?;
        let givens = self
            .function
            .requirements
            .iter()
            .chain(&self.function.outer_requirements)
            .cloned()
            .collect::<Vec<_>>();
        let (shape, evidence) = require_shared_callable(
            &callee.ty,
            self.function,
            self.environment,
            self.inference,
            &givens,
            &origin,
        )?;
        if shape.parameters.len() != arguments.len() {
            return Err(source_diagnostic(
                CheckDiagnosticKind::CallMismatch,
                "indirect call argument count differs from its shape",
                origin,
                Vec::new(),
            ));
        }
        let mut typed = Vec::new();
        for (argument, (expected, _)) in arguments.iter().zip(&shape.parameters) {
            let ResolvedCallArgument::Expression(argument) = argument else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "indirect call-site mode assertions are outside the current Checker",
                    origin,
                    Vec::new(),
                ));
            };
            let argument = self.check_expr(argument)?;
            self.inference
                .satisfy(&argument.ty, expected)
                .map_err(|failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::CallMismatch,
                        display_unification_failure(&failure),
                        self.origin(argument.span),
                        Vec::new(),
                    )
                })?;
            typed.push(argument);
        }
        let ty = if self.is_never(&callee.ty)
            || typed.iter().any(|argument| self.is_never(&argument.ty))
        {
            CheckedType::Never
        } else {
            shape.result
        };
        Ok(TypedExpr {
            span: origin.span,
            ty,
            kind: TypedExprKind::IndirectCall(Box::new(TypedIndirectCall {
                callee: Box::new(callee),
                arguments: typed,
                parameter_modes: shape.parameters.iter().map(|(_, mode)| *mode).collect(),
                effect: shape.effect,
                evidence: Box::new(evidence),
            })),
        })
    }
}

impl BodyChecker<'_> {
    pub(super) fn check_unsafe_expression(
        &mut self,
        origin: OriginRef,
        block: &ResolvedBlock,
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let module = module_for_origin(self.environment.project, &self.function.origin).unwrap();
        let authorized = self.environment.project.modules[&module].body.as_ref().and_then(|body| body.requires.as_ref()).is_some_and(|requires| requires.effects.iter().any(|effect| {
            matches!(&effect.reference, ResolvedReference::Exact { target, .. } if target.kind == EntityKind::LanguageEffect && target.name == "unsafe")
        }));
        if !authorized {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "unsafe discharge requires explicit module authorization",
                origin,
                Vec::new(),
            ));
        }
        let block = self.check_block(block)?;
        Ok(TypedExpr {
            span: origin.span,
            ty: block.ty.clone(),
            kind: TypedExprKind::Unsafe(Box::new(block)),
        })
    }

    pub(super) fn check_effect_operation(
        &mut self,
        origin: &OriginRef,
        receiver: &ResolvedExpr,
        member: &ResolvedSelection,
        arguments: &[ResolvedCallArgument],
    ) -> Result<Option<TypedExpr>, CheckDiagnostic> {
        let ResolvedExprKind::Path(ResolvedReference::Exact { target, .. }) = &receiver.kind else {
            return Ok(None);
        };
        if !matches!(target.kind, EntityKind::Effect | EntityKind::LanguageEffect) {
            return Ok(None);
        }
        let operation = member
            .declaration
            .as_ref()
            .expect("resolved operation lookup has an exact owner member");
        if target.kind == EntityKind::LanguageEffect {
            if target.name != "fail"
                || operation.name != "raise"
                || operation.site != EntitySite::Language
            {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "this language effect has no supported operation",
                    origin.clone(),
                    Vec::new(),
                ));
            }
            let [ResolvedCallArgument::Expression(payload)] = arguments else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::CallMismatch,
                    "fail.raise requires exactly one owned payload",
                    origin.clone(),
                    Vec::new(),
                ));
            };
            let payload = self.check_expr(payload)?;
            return Ok(Some(TypedExpr {
                span: origin.span,
                ty: CheckedType::Never,
                kind: TypedExprKind::Raise {
                    operation: Box::new(operation.clone()),
                    payload: Box::new(payload),
                },
            }));
        }
        let mut typed = Vec::new();
        for argument in arguments {
            let ResolvedCallArgument::Expression(argument) = argument else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "operation call-site assertions are outside the current Checker",
                    origin.clone(),
                    Vec::new(),
                ));
            };
            typed.push(self.check_expr(argument)?);
        }
        let result = self.inference.fresh();
        let index = self.calls.len();
        self.calls.push(DraftCall {
            closed: false,
            caller: self.function.identity.clone(),
            target: Some(operation.clone()),
            selection: None,
            owner_mapping: BTreeMap::new(),
            evidence: None,
            proofs: Vec::new(),
            effect_actuals: Vec::new(),
            effect_dependencies: Vec::new(),
            arguments: typed.iter().map(|argument| argument.ty.clone()).collect(),
            result: result.clone(),
            origin: origin.clone(),
            instantiation: None,
            diverges: false,
        });
        Ok(Some(TypedExpr {
            span: origin.span,
            ty: result,
            kind: TypedExprKind::DeferredCall {
                index,
                arguments: typed,
            },
        }))
    }
}

pub(super) fn validate_public_effects(
    headers: &BTreeMap<EntityId, FunctionHeader>,
    exports: &BTreeSet<EntityId>,
) -> Result<(), CheckDiagnostic> {
    for header in headers.values().filter(|header| header.public_export) {
        for row in header
            .effect_upper
            .iter()
            .chain(header.shapes.values().map(|shape| &shape.effect))
        {
            validate_public_effect_row(row, exports, &header.origin)?;
        }
    }
    Ok(())
}

pub(super) fn validate_public_effect_row(
    row: &CheckedEffect,
    exports: &BTreeSet<EntityId>,
    origin: &OriginRef,
) -> Result<(), CheckDiagnostic> {
    let mut pending = vec![row];
    while let Some(row) = pending.pop() {
        for term in &row.0 {
            match term {
                EffectTerm::Handled(identity, arguments) => {
                    if !exports.contains(identity) {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            "public effect row exposes a private handled identity",
                            origin.clone(),
                            entity_origin(identity).into_iter().collect(),
                        ));
                    }
                    for ty in arguments {
                        validate_public_nominals(ty, exports, origin)?;
                    }
                }
                EffectTerm::Failure(ty)
                | EffectTerm::Destruction(ty)
                | EffectTerm::SelectedCall(ty) => validate_public_nominals(ty, exports, origin)?,
                EffectTerm::Method {
                    method,
                    types,
                    effects,
                } => {
                    if method.owner.as_ref().is_some_and(|owner| owner.kind == EntityKind::Trait) && !exports.iter().any(|identity| identity.kind == EntityKind::Trait && method.owner.as_ref().is_some_and(|owner| owner.module == identity.module && matches!(&identity.site, EntitySite::Source(site) if owner.source == site.source && owner.span == site.span))) { return Err(source_diagnostic(CheckDiagnosticKind::TypeMismatch, "public effect application exposes a private trait", origin.clone(), entity_origin(method).into_iter().collect())); }
                    for (_, ty) in types {
                        validate_public_nominals(ty, exports, origin)?;
                    }
                    pending.extend(effects);
                }
                _ => {}
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::checker::checking_tests::sources;

    #[test]
    fn failure_facts_distinguish_live_owner_staged_move_and_transferred_payload() {
        let source = r#"
trait Tick { fn tick(self: &Self) -> Int; }
trait PureTick { fn tick(self: &Self) -> Int with {}; }
fn keep<T, R: Tick>(value: move T, runner: &R) -> T { runner.tick(); value }
fn pass<T>(value: move T, n: Int) -> T { value }
fn staged<T, R: Tick>(value: move T, runner: &R) -> T { pass(value, runner.tick()) }
fn consume<T>(value: move T) {}
fn transferred<T, R: Tick>(value: move T, runner: &R) { consume(value); runner.tick(); }
fn pure_keep<T, R: PureTick>(value: move T, runner: &R) -> T { runner.tick(); value }
fn raise_payload<T>(value: move T) -> Never { fail.raise(value) }
fn early<T>(value: move T) -> Int { pass(value, { return 1; }); 0 }
struct Empty {}
fn accept_empty(value: move Empty, step: Int) {}
fn empty_staged<R: Tick>(runner: &R) { accept_empty(Empty {}, runner.tick()); }
"#;
        let checked = check_project(&sources(source), &BTreeMap::new(), Vec::new()).unwrap();
        let function = |name: &str| {
            checked
                .functions
                .values()
                .find(|function| function.identity.name == name)
                .unwrap()
        };
        let destruction = |function: &CheckedFunction| {
            function.effect.0.iter().any(|term| matches!(term, EffectTerm::Destruction(CheckedType::Formal(formal)) if formal.name == "T"))
        };
        assert!(destruction(function("keep")));
        assert!(destruction(function("staged")));
        assert!(!destruction(function("pure_keep")));
        assert!(function("pure_keep").effect.is_empty());

        let keep = function("keep")
            .body
            .cleanups
            .iter()
            .find(|fact| matches!(fact.exit, CleanupExit::Failure))
            .unwrap();
        let (_, value) = keep
            .state
            .bindings
            .iter()
            .find(|(binding, _)| binding.name == "value")
            .unwrap();
        assert_eq!(value.ownership, OwnershipKind::Owned);
        assert!(value.availability == Availability::Live);

        let staged = function("staged")
            .body
            .cleanups
            .iter()
            .find(|fact| matches!(fact.exit, CleanupExit::Failure))
            .unwrap();
        let (_, value) = staged
            .state
            .bindings
            .iter()
            .find(|(binding, _)| binding.name == "value")
            .unwrap();
        assert!(value.availability == Availability::Moved);
        assert!(staged.state.temporaries.iter().any(|temporary| {
            temporary.transfer
                && temporary
                    .types
                    .iter()
                    .any(|ty| matches!(ty, CheckedType::Formal(formal) if formal.name == "T"))
                && &source[temporary.origin.span.start..temporary.origin.span.end] == "value"
        }));

        let transferred = function("transferred")
            .body
            .cleanups
            .iter()
            .find(|fact| matches!(fact.exit, CleanupExit::Failure))
            .unwrap();
        assert!(transferred.types().is_empty());
        assert!(
            function("raise_payload")
                .effect
                .0
                .iter()
                .any(|term| matches!(term, EffectTerm::Failure(_)))
        );
        assert!(!destruction(function("raise_payload")));
        assert!(
            function("raise_payload")
                .body
                .cleanups
                .iter()
                .filter(|fact| matches!(fact.exit, CleanupExit::Failure))
                .all(|fact| fact.types().is_empty())
        );
        assert!(function("early").body.cleanups.iter().any(|fact| matches!(
            fact.exit,
            CleanupExit::Return
        )
            && !fact.temporaries.is_empty()));
        assert!(destruction(function("early")));
        let empty = function("empty_staged")
            .body
            .cleanups
            .iter()
            .find(|fact| matches!(fact.exit, CleanupExit::Failure))
            .unwrap();
        assert!(empty.state.temporaries.iter().any(|temporary| temporary.transfer && temporary.types.is_empty() && matches!(&temporary.owner, CheckedType::Nominal(nominal) if nominal.declaration.name == "Empty") && &source[temporary.origin.span.start..temporary.origin.span.end] == "Empty {}"));
    }
}
