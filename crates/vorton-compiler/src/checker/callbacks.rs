use super::*;

#[derive(Clone)]
pub(super) struct StoredType {
    pub(super) ty: CheckedType,
    pub(super) origin: OriginRef,
}

pub(super) fn collect_storage_uses(block: &TypedBlock, context: &SourceContext) -> Vec<StoredType> {
    fn block_nodes<'a>(block: &'a TypedBlock, pending: &mut Vec<&'a TypedExpr>) {
        for statement in &block.statements {
            match &statement.kind {
                TypedStatementKind::Let { value, .. } | TypedStatementKind::Expression(value) => {
                    pending.push(value)
                }
                TypedStatementKind::Return(value) => pending.extend(value.as_deref()),
            }
        }
        pending.extend(block.tail.as_deref());
    }
    let mut pending = Vec::new();
    block_nodes(block, &mut pending);
    let mut stored = Vec::new();
    while let Some(expression) = pending.pop() {
        match &expression.kind {
            TypedExprKind::Tuple(elements) => {
                stored.extend(elements.iter().map(|element| StoredType {
                    ty: element.ty.clone(),
                    origin: context.origin(element.span),
                }));
                pending.extend(elements);
            }
            TypedExprKind::Construct(construction) => {
                for field in &construction.fields {
                    stored.push(StoredType {
                        ty: field.value.ty.clone(),
                        origin: field.origin.clone(),
                    });
                    pending.push(&field.value);
                }
            }
            TypedExprKind::Field { receiver, .. } | TypedExprKind::TupleField { receiver, .. } => {
                stored.push(StoredType {
                    ty: expression.ty.clone(),
                    origin: context.origin(expression.span),
                });
                pending.push(receiver);
            }
            TypedExprKind::Call { arguments, .. } => {
                stored.push(StoredType {
                    ty: expression.ty.clone(),
                    origin: context.origin(expression.span),
                });
                pending.extend(arguments);
            }
            TypedExprKind::Indirect(call) => {
                stored.push(StoredType {
                    ty: expression.ty.clone(),
                    origin: context.origin(expression.span),
                });
                pending.push(&call.callable);
                pending.extend(&call.arguments);
            }
            TypedExprKind::Operation(operation) => {
                if operation
                    .effect
                    .0
                    .iter()
                    .any(|term| matches!(term, EffectTerm::Fail(_)))
                {
                    stored.extend(operation.arguments.iter().map(|value| StoredType {
                        ty: value.ty.clone(),
                        origin: context.origin(value.span),
                    }));
                }
                pending.extend(&operation.arguments);
            }
            TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
                block_nodes(block, &mut pending)
            }
            TypedExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => {
                pending.push(condition);
                block_nodes(then_branch, &mut pending);
                pending.extend(else_branch.as_deref());
            }
            TypedExprKind::Parenthesized(inner) | TypedExprKind::Unary { operand: inner, .. } => {
                pending.push(inner)
            }
            TypedExprKind::Binary { left, right, .. } => {
                pending.push(left);
                pending.push(right);
            }
            _ => {}
        }
    }
    stored
}

pub(super) fn propagate_storage_uses(
    group: &[EntityId],
    equations: &BTreeMap<EntityId, EffectEquation>,
    schemes: &BTreeMap<EntityId, CallableScheme>,
    uses: &mut BTreeMap<EntityId, Vec<StoredType>>,
    inference: &TypeInference,
) {
    loop {
        let mut changed = false;
        for caller in group {
            for call in &equations[caller].calls {
                let requirements = schemes
                    .get(&call.callee)
                    .map(|scheme| &scheme.stored_types)
                    .or_else(|| uses.get(&call.callee))
                    .expect("callee support facts")
                    .clone();
                for requirement in requirements {
                    let ty = inference.canonical(&instantiate_type(&requirement.ty, &call.types));
                    if !uses[caller]
                        .iter()
                        .any(|stored| inference.canonical(&stored.ty) == ty)
                    {
                        uses.get_mut(caller)
                            .expect("caller support facts")
                            .push(StoredType {
                                ty,
                                origin: requirement.origin,
                            });
                        changed = true;
                    }
                }
            }
        }
        if !changed {
            break;
        }
    }
}

impl SourceTypeNormalizer<'_> {
    pub(super) fn callable_type(
        &self,
        ty: &CheckedType,
        requirements: &[Requirement],
        origin: &OriginRef,
    ) -> bool {
        if matches!(ty, CheckedType::Function(_)) {
            return true;
        }
        let origin = CheckOrigin::Source(origin.clone());
        SelectionSolver::new(
            &self.selection,
            &self.project.core_roles,
            requirements,
            origin.clone(),
        )
        .and_then(|mut solver| {
            solver.prove(&Requirement {
                subject: ty.clone(),
                bound: TraitUse {
                    declaration: self.project.core_roles.fn_once.clone(),
                    arguments: Vec::new(),
                    associated: BTreeMap::new(),
                },
                origin,
            })
        })
        .is_ok()
    }
}

pub(super) fn substitute_body_effects(
    block: &mut TypedBlock,
    replacements: &BTreeMap<EffectFormal, EffectRow>,
) {
    fn expression(value: &mut TypedExpr, replacements: &BTreeMap<EffectFormal, EffectRow>) {
        match &mut value.kind {
            TypedExprKind::Call {
                arguments,
                instantiation,
                effect,
                ..
            } => {
                for argument in arguments {
                    expression(argument, replacements);
                }
                if let CallInstantiation::Published(mapping)
                | CallInstantiation::Provisional(mapping) = instantiation
                {
                    for (_, row) in &mut mapping.effects {
                        *row = row.instantiate(&BTreeMap::new(), replacements);
                    }
                }
                if let CallInstantiation::RecursiveBinding { effects } = instantiation {
                    for (_, row) in effects {
                        *row = row.instantiate(&BTreeMap::new(), replacements);
                    }
                }
                if let Some(row) = effect {
                    *row = row.instantiate(&BTreeMap::new(), replacements);
                }
            }
            TypedExprKind::Indirect(call) => {
                expression(&mut call.callable, replacements);
                for argument in &mut call.arguments {
                    expression(argument, replacements);
                }
                if let Some(row) = &mut call.effect {
                    *row = row.instantiate(&BTreeMap::new(), replacements);
                }
            }
            TypedExprKind::FunctionValue(value) => {
                if let Some(mapping) = &mut value.mapping {
                    for (_, row) in &mut mapping.effects {
                        *row = row.instantiate(&BTreeMap::new(), replacements);
                    }
                }
            }
            TypedExprKind::Operation(operation) => {
                for argument in &mut operation.arguments {
                    expression(argument, replacements);
                }
                operation.effect = operation.effect.instantiate(&BTreeMap::new(), replacements);
            }
            TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
                substitute_body_effects(block, replacements)
            }
            TypedExprKind::Parenthesized(inner)
            | TypedExprKind::Unary { operand: inner, .. }
            | TypedExprKind::Field {
                receiver: inner, ..
            }
            | TypedExprKind::TupleField {
                receiver: inner, ..
            } => expression(inner, replacements),
            TypedExprKind::Tuple(elements) => {
                for element in elements {
                    expression(element, replacements);
                }
            }
            TypedExprKind::Construct(construction) => {
                for field in &mut construction.fields {
                    expression(&mut field.value, replacements);
                }
            }
            TypedExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => {
                expression(condition, replacements);
                substitute_body_effects(then_branch, replacements);
                if let Some(branch) = else_branch {
                    expression(branch, replacements);
                }
            }
            TypedExprKind::Binary { left, right, .. } => {
                expression(left, replacements);
                expression(right, replacements);
            }
            _ => {}
        }
    }
    for statement in &mut block.statements {
        match &mut statement.kind {
            TypedStatementKind::Let { value, .. } | TypedStatementKind::Expression(value) => {
                expression(value, replacements)
            }
            TypedStatementKind::Return(value) => {
                if let Some(value) = value {
                    expression(value, replacements);
                }
            }
        }
    }
    if let Some(tail) = &mut block.tail {
        expression(tail, replacements);
    }
}

pub(super) fn conform_callback_shapes(
    expected: &FunctionHeader,
    actual: &mut FunctionHeader,
    types: &BTreeMap<TypeFormal, CheckedType>,
    solver: &mut SelectionSolver<'_>,
    inference: &mut TypeInference,
) -> Result<(), CheckDiagnostic> {
    let explicit = actual.effect_formals.len()
        - actual
            .shapes
            .iter()
            .filter(|shape| shape.inferred_row.is_some())
            .count();
    if explicit > expected.effect_formals.len() {
        return Err(effect_diagnostic(
            "impl adds effect formals beyond its trait scheme",
            CheckOrigin::Source(actual.origin.clone()),
        ));
    }
    let formals = (0..expected.effect_formals.len())
        .map(|ordinal| EffectFormal {
            owner: actual.identity.clone(),
            ordinal,
        })
        .collect::<Vec<_>>();
    let expected_effects = expected
        .effect_formals
        .iter()
        .cloned()
        .zip(
            formals
                .iter()
                .cloned()
                .map(|formal| EffectRow(vec![EffectTerm::Formal(formal)])),
        )
        .collect();
    let expected_shapes = expected
        .shapes
        .iter()
        .map(|shape| ShapeRequirement {
            subject: instantiate_type(&shape.subject, types),
            shape: shape.shape.instantiate(types, &expected_effects),
            origin: shape.origin.clone(),
            inferred_row: None,
        })
        .collect::<Vec<_>>();
    let mut replacements = actual.effect_formals[..explicit]
        .iter()
        .cloned()
        .zip(
            formals[..explicit]
                .iter()
                .cloned()
                .map(|formal| EffectRow(vec![EffectTerm::Formal(formal)])),
        )
        .collect::<BTreeMap<_, _>>();
    if !actual.shapes.is_empty() {
        if actual.shapes.len() != expected_shapes.len() {
            return Err(effect_diagnostic(
                "impl callable-shape occurrences differ from its trait contract",
                CheckOrigin::Source(actual.origin.clone()),
            ));
        }
        for (actual_shape, expected_shape) in actual.shapes.iter().zip(&expected_shapes) {
            if actual_shape.subject != expected_shape.subject
                || actual_shape.shape.parameters.len() != expected_shape.shape.parameters.len()
            {
                return Err(effect_diagnostic(
                    "impl callable-shape owner or arity differs from the trait",
                    actual_shape.origin.clone(),
                ));
            }
            for ((left, left_mode), (right, right_mode)) in actual_shape
                .shape
                .parameters
                .iter()
                .zip(&expected_shape.shape.parameters)
            {
                if left_mode != right_mode {
                    return Err(effect_diagnostic(
                        "impl callable-shape parameter mode differs",
                        actual_shape.origin.clone(),
                    ));
                }
                inference
                    .unify(&solver.normalize(left)?, &solver.normalize(right)?)
                    .map_err(|failure| {
                        effect_diagnostic(
                            display_unification_failure(&failure),
                            actual_shape.origin.clone(),
                        )
                    })?;
            }
            inference
                .unify(
                    &solver.normalize(&actual_shape.shape.return_type)?,
                    &solver.normalize(&expected_shape.shape.return_type)?,
                )
                .map_err(|failure| {
                    effect_diagnostic(
                        display_unification_failure(&failure),
                        actual_shape.origin.clone(),
                    )
                })?;
            if let Some(formal) = &actual_shape.inferred_row {
                replacements.insert(formal.clone(), expected_shape.shape.effect.clone());
            } else {
                expected_shape.shape.effect.subset_of(
                    &actual_shape
                        .shape
                        .effect
                        .instantiate(&BTreeMap::new(), &replacements),
                    inference,
                    &actual_shape.origin,
                )?;
            }
        }
    }
    actual.effect_upper = actual
        .effect_upper
        .as_ref()
        .map(|row| row.instantiate(&BTreeMap::new(), &replacements));
    actual.trait_upper = expected
        .effect_upper
        .as_ref()
        .map(|row| row.instantiate(types, &expected_effects));
    actual.trait_effect_origin = expected
        .effect_upper
        .as_ref()
        .map(|_| expected.effect_origin.clone());
    actual.effect_formals = formals;
    actual.shapes = expected_shapes;
    actual.inferable_effects.clear();
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct FunctionItem {
    pub(super) function: EntityId,
    pub(super) mapping: CallMapping,
}

impl FunctionItem {
    pub(super) fn types(&self) -> impl Iterator<Item = &CheckedType> {
        self.mapping
            .types
            .iter()
            .map(|(_, ty)| ty)
            .chain(self.mapping.effects.iter().flat_map(|(_, row)| row.types()))
    }
    pub(super) fn map_types(&self, mut map: impl FnMut(&CheckedType) -> CheckedType) -> Self {
        Self {
            function: self.function.clone(),
            mapping: CallMapping {
                types: self
                    .mapping
                    .types
                    .iter()
                    .map(|(formal, ty)| (formal.clone(), map(ty)))
                    .collect(),
                effects: self
                    .mapping
                    .effects
                    .iter()
                    .map(|(formal, row)| (formal.clone(), row.map_types(&mut map)))
                    .collect(),
            },
        }
    }
}

#[derive(Clone)]
pub(super) struct CallableShape {
    pub(super) parameters: Vec<(CheckedType, ParameterMode)>,
    pub(super) return_type: CheckedType,
    pub(super) effect: EffectRow,
}

impl CallableShape {
    pub(super) fn instantiate(
        &self,
        types: &BTreeMap<TypeFormal, CheckedType>,
        effects: &BTreeMap<EffectFormal, EffectRow>,
    ) -> Self {
        Self {
            parameters: self
                .parameters
                .iter()
                .map(|(ty, mode)| (instantiate_type(ty, types), *mode))
                .collect(),
            return_type: instantiate_type(&self.return_type, types),
            effect: self.effect.instantiate(types, effects),
        }
    }
}

#[derive(Clone)]
pub(super) struct ShapeRequirement {
    pub(super) subject: CheckedType,
    pub(super) shape: CallableShape,
    pub(super) origin: CheckOrigin,
    pub(super) inferred_row: Option<EffectFormal>,
}

pub(super) struct TypedFunctionValue {
    pub(super) function: EntityId,
    pub(super) mapping: Option<CallMapping>,
}

pub(super) struct CallbackActuals {
    pub(super) effects: BTreeMap<EffectFormal, EffectRow>,
    pub(super) evidence: Vec<Evidence>,
}

pub(super) struct TypedIndirectCall {
    pub(super) callable: TypedExpr,
    pub(super) evidence: Vec<Evidence>,
    pub(super) arguments: Vec<TypedExpr>,
    pub(super) parameter_modes: Vec<ParameterMode>,
    pub(super) effect: Option<EffectRow>,
}

impl SourceTypeNormalizer<'_> {
    pub(super) fn callback_shapes(
        &mut self,
        identity: &EntityId,
        parameters: &[crate::project::ResolvedTypeParameter],
        formals: &BTreeMap<EntityId, TypeFormal>,
        effect_formals: &mut Vec<EffectFormal>,
        effect_names: &BTreeMap<EntityId, EffectFormal>,
    ) -> Result<Vec<ShapeRequirement>, CheckDiagnostic> {
        let mut shapes = Vec::new();
        let mut givens = Vec::new();
        for formal in formals.values() {
            for named in self.generic_bounds.get(formal).cloned().unwrap_or_default() {
                givens.push(Requirement {
                    subject: CheckedType::Formal(Box::new(formal.clone())),
                    bound: self.normalize_trait_use(&named, formals)?,
                    origin: CheckOrigin::Source(reference_origin(&named.reference).clone()),
                });
            }
        }
        if let Some(scope) = &self.contract_scope {
            givens.extend(
                self.contract_bounds
                    .get(scope)
                    .into_iter()
                    .flatten()
                    .cloned(),
            );
        }
        for parameter in parameters {
            for bound in &parameter.bounds {
                let crate::project::ResolvedGenericBound::Shape(shape) = bound else {
                    continue;
                };
                let origin = CheckOrigin::Source(parameter.binding.origin.clone());
                let mut shape = shape;
                while let crate::project::ResolvedShapeKind::Grouped(inner) = &shape.kind {
                    shape = inner;
                }
                let crate::project::ResolvedShapeKind::Callable {
                    parameters,
                    return_type,
                    effects,
                } = &shape.kind
                else {
                    unreachable!("grouped shapes are unwrapped")
                };
                let mut inputs = Vec::new();
                for input in parameters {
                    if input.escape.is_some()
                        || matches!(input.mode, Some((_, ParameterMode::MutBorrow)))
                    {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "callback shape requires an unsupported resource mode",
                            parameter.binding.origin.clone(),
                            Vec::new(),
                        ));
                    }
                    let ty = self.normalize_with_formals(&input.ty, formals)?;
                    let mode = input.mode.map_or(ParameterMode::Borrow, |(_, mode)| mode);
                    let mode = if mode == ParameterMode::Call {
                        self.shared_callable(&ty, &givens, origin.clone()).map_err(
                            |mut error| {
                                error.kind = CheckDiagnosticKind::Unsupported;
                                error
                            },
                        )?;
                        ParameterMode::Borrow
                    } else {
                        mode
                    };
                    inputs.push((ty, mode));
                }
                let mut inferred_row = None;
                let effect = if let Some(effects) = effects {
                    self.normalize_effects(effects, formals, effect_names)?
                } else {
                    let formal = EffectFormal {
                        owner: identity.clone(),
                        ordinal: effect_formals.len(),
                    };
                    effect_formals.push(formal.clone());
                    inferred_row = Some(formal.clone());
                    EffectRow(vec![EffectTerm::Formal(formal)])
                };
                shapes.push(ShapeRequirement {
                    subject: CheckedType::Formal(Box::new(
                        formals[&parameter.binding.identity].clone(),
                    )),
                    shape: CallableShape {
                        parameters: inputs,
                        return_type: self.normalize_with_formals(return_type, formals)?,
                        effect,
                    },
                    origin,
                    inferred_row,
                });
            }
        }
        Ok(shapes)
    }

    pub(super) fn shared_callable(
        &self,
        ty: &CheckedType,
        requirements: &[Requirement],
        origin: CheckOrigin,
    ) -> Result<(), CheckDiagnostic> {
        let mut solver = SelectionSolver::new(
            &self.selection,
            &self.project.core_roles,
            requirements,
            origin.clone(),
        )?;
        solver
            .prove(&Requirement {
                subject: ty.clone(),
                bound: TraitUse {
                    declaration: self.project.core_roles.function.clone(),
                    arguments: Vec::new(),
                    associated: BTreeMap::new(),
                },
                origin,
            })
            .map(|_| ())
    }
}

impl BodyChecker<'_, '_> {
    pub(super) fn function_value_draft(
        &mut self,
        function: &EntityId,
        origin: OriginRef,
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let header = &self.environment.headers[function];
        if function.module.source_library() == self.function.identity.module.source_library() {
            let closed = header.source_return_explicit
                && header
                    .parameters
                    .iter()
                    .all(|parameter| parameter.source_type_explicit && parameter.mode.is_some())
                && header.effect_upper.as_ref().is_some_and(|row| {
                    !row.0.iter().any(|term| {
                        matches!(
                            term,
                            EffectTerm::Formal(_)
                                | EffectTerm::SelectedCall(_)
                                | EffectTerm::Method { .. }
                        )
                    })
                });
            if !closed {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "same-unit named function value requires a closed declaration header",
                    origin,
                    vec![header.origin.clone()],
                ));
            }
        }
        Ok(TypedExpr {
            span: origin.span,
            ty: self.inference.fresh(),
            kind: TypedExprKind::FunctionValue(Box::new(TypedFunctionValue {
                function: function.clone(),
                mapping: None,
            })),
        })
    }

    pub(super) fn indirect_draft(
        &mut self,
        origin: OriginRef,
        callable: &ResolvedExpr,
        arguments: &[ResolvedCallArgument],
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let callable = self.check_expr(callable)?;
        let mut typed = Vec::new();
        for argument in arguments {
            let ResolvedCallArgument::Expression(argument) = argument else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "callback call-site resource assertions remain unsupported",
                    origin,
                    Vec::new(),
                ));
            };
            typed.push(self.check_expr(argument)?);
        }
        Ok(TypedExpr {
            span: origin.span,
            ty: self.inference.fresh(),
            kind: TypedExprKind::Indirect(Box::new(TypedIndirectCall {
                callable,
                evidence: Vec::new(),
                arguments: typed,
                parameter_modes: Vec::new(),
                effect: None,
            })),
        })
    }
}

impl CallBinder<'_, '_> {
    fn check_function_item_domain(
        &mut self,
        ty: &CheckedType,
        origin: &CheckOrigin,
    ) -> Result<Option<Vec<Evidence>>, CheckDiagnostic> {
        enum Frame {
            Enter(CheckedType),
            Finish(CheckedType),
        }
        let mut pending = vec![Frame::Enter(ty.clone())];
        let mut active = BTreeSet::new();
        let mut complete = BTreeSet::new();
        let mut evidence = Vec::new();
        let mut work = 0;
        while let Some(frame) = pending.pop() {
            work += 1;
            if work > SELECTION_WORK_LIMIT || active.len() > SELECTION_STATE_LIMIT {
                return Err(effect_diagnostic(
                    "callable domain proof incomplete: deterministic work/state limit reached",
                    origin.clone(),
                ));
            }
            match frame {
                Frame::Enter(ty) => {
                    let ty = self.inference.canonical(&ty);
                    let CheckedType::Function(item) = &ty else {
                        continue;
                    };
                    if complete.contains(&ty) {
                        continue;
                    }
                    if !active.insert(ty.clone()) {
                        return Err(effect_diagnostic(
                            "illegal recursive callable domain selection",
                            origin.clone(),
                        ));
                    }
                    let header = &self.headers[&item.function];
                    let shapes = self
                        .schemes
                        .get(&item.function)
                        .map_or(&header.shapes, |scheme| &scheme.shapes)
                        .clone();
                    let types = item.mapping.types.iter().cloned().collect();
                    pending.push(Frame::Finish(ty.clone()));
                    for required in &shapes {
                        let subject = instantiate_type(&required.subject, &types);
                        let actual = self.callable_shape(&subject, origin)?;
                        let expected = required.shape.instantiate(&types, &BTreeMap::new());
                        self.match_callback_types(&actual, &expected, origin)?;
                        pending.push(Frame::Enter(subject));
                    }
                }
                Frame::Finish(key) => {
                    let CheckedType::Function(item) = self.inference.canonical(&key) else {
                        unreachable!()
                    };
                    let header = &self.headers[&item.function];
                    let requirements = self
                        .schemes
                        .get(&item.function)
                        .map_or(&header.requirements, |scheme| &scheme.requirements)
                        .clone();
                    let shapes = self
                        .schemes
                        .get(&item.function)
                        .map_or(&header.shapes, |scheme| &scheme.shapes)
                        .clone();
                    let formals = header.effect_formals.clone();
                    let types = item.mapping.types.iter().cloned().collect();
                    let Some(actuals) =
                        self.callback_actuals_inner(&shapes, &types, &formals, origin, false)?
                    else {
                        return Ok(None);
                    };
                    for (formal, current) in &item.mapping.effects {
                        if !self
                            .inference
                            .unify_effect_actual(current, &actuals.effects[formal])
                        {
                            return Err(effect_diagnostic(
                                "named function effect actual does not satisfy its callback input domain",
                                origin.clone(),
                            ));
                        }
                    }
                    let givens = self
                        .function
                        .requirements
                        .iter()
                        .map(|requirement| requirement.map_types(|ty| self.inference.canonical(ty)))
                        .collect::<Vec<_>>();
                    let mut solver = SelectionSolver::new(
                        &self.normalizer.selection,
                        &self.normalizer.project.core_roles,
                        &givens,
                        origin.clone(),
                    )?;
                    for requirement in &requirements {
                        solver.prove(
                            &requirement
                                .instantiate(&types)
                                .map_types(|ty| self.inference.canonical(ty)),
                        )?;
                    }
                    if let Some(scheme) = self.schemes.get(&item.function) {
                        for stored in &scheme.stored_types {
                            if self.normalizer.callable_type(
                                &self
                                    .inference
                                    .canonical(&instantiate_type(&stored.ty, &types)),
                                &givens,
                                &stored.origin,
                            ) {
                                return Err(effect_diagnostic(
                                    "callable storage through a named function value requires later escape/resource analysis",
                                    origin.clone(),
                                ));
                            }
                        }
                    }
                    append_evidence(&mut evidence, solver.evidence);
                    active.remove(&key);
                    complete.insert(self.inference.canonical(&key));
                }
            }
        }
        Ok(Some(evidence))
    }

    fn match_callback_types(
        &mut self,
        actual: &CallableShape,
        expected: &CallableShape,
        origin: &CheckOrigin,
    ) -> Result<(), CheckDiagnostic> {
        EffectEnvironment {
            normalizer: self.normalizer,
            headers: self.headers,
            schemes: self.schemes,
        }
        .match_callback_types(actual, expected, self.function, self.inference, origin)
    }

    pub(super) fn bind_function_value(
        &mut self,
        value: &mut TypedFunctionValue,
        ty: &mut CheckedType,
        span: Span,
    ) -> Result<(), CheckDiagnostic> {
        if value.mapping.is_some() {
            return Ok(());
        }
        let mapping = if let Some(scheme) = self.schemes.get(&value.function) {
            CallMapping {
                types: scheme
                    .quantified
                    .iter()
                    .filter(|formal| scheme.instantiation_formals.contains(*formal))
                    .cloned()
                    .map(|formal| (formal, self.inference.fresh()))
                    .collect(),
                effects: scheme
                    .effect_formals
                    .iter()
                    .cloned()
                    .map(|formal| {
                        (
                            formal,
                            if scheme.shapes.is_empty() {
                                EffectRow::default()
                            } else {
                                self.inference.fresh_effect()
                            },
                        )
                    })
                    .collect(),
            }
        } else if self.group.contains(&value.function) {
            let header = &self.headers[&value.function];
            CallMapping {
                types: header
                    .outer_formals
                    .iter()
                    .chain(&header.declared_formals)
                    .cloned()
                    .map(|formal| (formal.clone(), CheckedType::Formal(Box::new(formal))))
                    .collect(),
                effects: header
                    .effect_formals
                    .iter()
                    .cloned()
                    .map(|formal| (formal.clone(), EffectRow(vec![EffectTerm::Formal(formal)])))
                    .collect(),
            }
        } else {
            self.pending = Some(self.function.context.origin(span));
            return Ok(());
        };
        let item = CheckedType::Function(Box::new(FunctionItem {
            function: value.function.clone(),
            mapping: mapping.clone(),
        }));
        self.inference.unify(ty, &item).map_err(|failure| {
            source_diagnostic(
                CheckDiagnosticKind::CallMismatch,
                display_unification_failure(&failure),
                self.function.context.origin(span),
                entity_origin(&value.function).into_iter().collect(),
            )
        })?;
        value.mapping = Some(mapping);
        self.changed = true;
        Ok(())
    }

    pub(super) fn callable_shape(
        &self,
        ty: &CheckedType,
        origin: &CheckOrigin,
    ) -> Result<CallableShape, CheckDiagnostic> {
        EffectEnvironment {
            normalizer: self.normalizer,
            headers: self.headers,
            schemes: self.schemes,
        }
        .callable_shape(ty, self.function, self.inference, origin)
    }

    pub(super) fn bind_indirect(
        &mut self,
        call: &mut TypedIndirectCall,
        ty: &mut CheckedType,
        span: Span,
    ) -> Result<(), CheckDiagnostic> {
        self.expression(&mut call.callable)?;
        for argument in &mut call.arguments {
            self.expression(argument)?;
        }
        if call.effect.is_some() {
            return Ok(());
        }
        if matches!(
            self.inference.resolve(&call.callable.ty),
            CheckedType::Infer(_)
        ) {
            self.pending = Some(self.function.context.origin(span));
            return Ok(());
        }
        let origin = CheckOrigin::Source(self.function.context.origin(span));
        let shape = self.callable_shape(&call.callable.ty, &origin)?;
        if shape.parameters.len() != call.arguments.len() {
            return Err(effect_diagnostic(
                "indirect call arity does not match its callable shape",
                origin,
            ));
        }
        for ((expected, _), actual) in shape.parameters.iter().zip(&call.arguments) {
            self.inference
                .satisfy(&actual.ty, expected)
                .map_err(|failure| {
                    effect_diagnostic(display_unification_failure(&failure), origin.clone())
                })?;
        }
        self.inference
            .satisfy(&shape.return_type, ty)
            .map_err(|failure| {
                effect_diagnostic(display_unification_failure(&failure), origin.clone())
            })?;
        let Some(evidence) = self.check_function_item_domain(&call.callable.ty, &origin)? else {
            return Ok(());
        };
        call.evidence = evidence;
        if call
            .arguments
            .iter()
            .any(|argument| self.inference.resolve(&argument.ty) == CheckedType::Never)
        {
            *ty = CheckedType::Never;
        }
        call.parameter_modes = shape.parameters.iter().map(|(_, mode)| *mode).collect();
        call.effect = Some(EffectRow(vec![EffectTerm::SelectedCall(
            self.inference.canonical(&call.callable.ty),
        )]));
        self.changed = true;
        Ok(())
    }

    pub(super) fn callback_actuals(
        &mut self,
        shapes: &[ShapeRequirement],
        types: &BTreeMap<TypeFormal, CheckedType>,
        formals: &[EffectFormal],
        origin: &CheckOrigin,
    ) -> Result<Option<CallbackActuals>, CheckDiagnostic> {
        self.callback_actuals_inner(shapes, types, formals, origin, true)
    }

    fn callback_actuals_inner(
        &mut self,
        shapes: &[ShapeRequirement],
        types: &BTreeMap<TypeFormal, CheckedType>,
        formals: &[EffectFormal],
        origin: &CheckOrigin,
        check_domain: bool,
    ) -> Result<Option<CallbackActuals>, CheckDiagnostic> {
        let mut lower = formals
            .iter()
            .cloned()
            .map(|formal| (formal, EffectRow::default()))
            .collect::<BTreeMap<_, _>>();
        let mut checks = Vec::new();
        let mut demands = Vec::new();
        let mut evidence = Vec::new();
        for required in shapes {
            let subject = instantiate_type(&required.subject, types);
            let mut actual = self.callable_shape(&subject, origin)?;
            let mut expected = required.shape.instantiate(types, &BTreeMap::new());
            self.match_callback_types(&actual, &expected, origin)?;
            if check_domain {
                let Some(proofs) = self.check_function_item_domain(&subject, origin)? else {
                    return Ok(None);
                };
                append_evidence(&mut evidence, proofs);
            }
            actual.effect = self.inference.resolve_effect(&actual.effect);
            expected.effect.0 = expected.effect.0.into_iter().flat_map(|term| {
                if matches!(&term, EffectTerm::SelectedCall(ty) if self.inference.canonical(ty) == self.inference.canonical(&subject)) { actual.effect.0.clone() } else { vec![term] }
            }).collect();
            let environment = EffectEnvironment {
                normalizer: self.normalizer,
                headers: self.headers,
                schemes: self.schemes,
            };
            let provisional = self
                .headers
                .iter()
                .filter_map(|(identity, header)| {
                    header
                        .trait_upper
                        .as_ref()
                        .or(header.effect_upper.as_ref())
                        .map(|row| (identity.clone(), row.clone()))
                })
                .collect();
            let mut needed = BTreeSet::new();
            actual.effect = environment.expand(
                &actual.effect,
                self.function,
                &provisional,
                self.inference,
                &mut needed,
            )?;
            expected.effect = environment.expand(
                &expected.effect,
                self.function,
                &provisional,
                self.inference,
                &mut needed,
            )?;
            if !needed.is_empty() {
                if needed.iter().any(|identity| self.group.contains(identity)) {
                    return Err(effect_diagnostic(
                        "callback effect selection depends on its own undetermined result",
                        origin.clone(),
                    ));
                }
                self.dependencies.extend(needed);
                self.pending = Some(origin_as_source(origin, &self.function.origin));
                return Ok(None);
            }
            let destinations = expected
                .effect
                .0
                .iter()
                .filter_map(|term| match term {
                    EffectTerm::Formal(formal) if lower.contains_key(formal) => {
                        Some(formal.clone())
                    }
                    _ => None,
                })
                .collect::<BTreeSet<_>>();
            let fixed = EffectRow(expected.effect.0.iter().filter(|term| !matches!(term, EffectTerm::Formal(formal) if lower.contains_key(formal))).cloned().collect());
            for term in &actual.effect.0 {
                if fixed.0.iter().any(|fixed| fixed.same_atom(term)) {
                    EffectRow(vec![term.clone()]).subset_of(&fixed, self.inference, origin)?;
                    continue;
                }
                if destinations.is_empty() {
                    return Err(effect_diagnostic(
                        "callback effect exceeds its shape row",
                        origin.clone(),
                    ));
                }
                demands.push((term.clone(), destinations.clone()));
            }
            checks.push((actual.effect, expected.effect));
        }
        // Each row actual must satisfy all callback lower bounds and remain a
        // legal row wherever that formal occurs, including unused callbacks.
        check_callback_rows(&checks, &lower, self.inference, origin)?;
        let mut work = 0;
        while !demands.is_empty() {
            let mut deferred = Vec::new();
            let mut changed = false;
            for (term, destinations) in demands {
                work += 1;
                if work > SELECTION_WORK_LIMIT {
                    return Err(effect_diagnostic(
                        "callback minimum proof incomplete: deterministic work limit reached",
                        origin.clone(),
                    ));
                }
                let mut available = EffectRow::default();
                for destination in &destinations {
                    available.union(&lower[destination], self.inference, origin)?;
                }
                if available
                    .0
                    .iter()
                    .any(|available| available.same_atom(&term))
                {
                    EffectRow(vec![term]).subset_of(&available, self.inference, origin)?;
                    changed = true;
                    continue;
                }
                let mut possible = BTreeSet::new();
                let mut failure = None;
                for destination in destinations {
                    work += checks.len() + 1;
                    if work > SELECTION_WORK_LIMIT {
                        return Err(effect_diagnostic(
                            "callback minimum proof incomplete: deterministic work limit reached",
                            origin.clone(),
                        ));
                    }
                    let mut trial = self.inference.clone();
                    let mut actuals = lower.clone();
                    let result = actuals
                        .get_mut(&destination)
                        .expect("effect actual")
                        .union(&EffectRow(vec![term.clone()]), &mut trial, origin)
                        .and_then(|()| check_callback_rows(&checks, &actuals, &mut trial, origin));
                    match result {
                        Ok(()) => {
                            possible.insert(destination);
                        }
                        Err(error) => failure = Some(error),
                    }
                }
                if possible.is_empty() {
                    return Err(failure.expect("every destination had a row conflict"));
                }
                if possible.len() == 1 {
                    lower
                        .get_mut(possible.first().expect("forced destination"))
                        .expect("effect actual")
                        .union(&EffectRow(vec![term]), self.inference, origin)?;
                    check_callback_rows(&checks, &lower, self.inference, origin)?;
                    changed = true;
                } else {
                    deferred.push((term, possible));
                }
            }
            if !deferred.is_empty() && !changed {
                return Err(effect_diagnostic(
                    "callback row has no unique minimal effect-actual solution",
                    origin.clone(),
                ));
            }
            demands = deferred;
        }
        check_callback_rows(&checks, &lower, self.inference, origin)?;
        for (actual, expected) in checks {
            actual.subset_of(
                &expected.instantiate(&BTreeMap::new(), &lower),
                self.inference,
                origin,
            )?;
        }
        Ok(Some(CallbackActuals {
            effects: lower,
            evidence,
        }))
    }
}

fn check_callback_rows(
    checks: &[(EffectRow, EffectRow)],
    actuals: &BTreeMap<EffectFormal, EffectRow>,
    inference: &mut TypeInference,
    origin: &CheckOrigin,
) -> Result<(), CheckDiagnostic> {
    for (_, expected) in checks {
        let expected = expected.instantiate(&BTreeMap::new(), actuals);
        EffectRow::default().union(&expected, inference, origin)?;
    }
    Ok(())
}

impl EffectEnvironment<'_, '_> {
    pub(super) fn match_callback_types(
        &self,
        actual: &CallableShape,
        expected: &CallableShape,
        caller: &FunctionHeader,
        inference: &mut TypeInference,
        origin: &CheckOrigin,
    ) -> Result<(), CheckDiagnostic> {
        if actual.parameters.len() != expected.parameters.len() {
            return Err(effect_diagnostic(
                "callback shape arity differs",
                origin.clone(),
            ));
        }
        for ((_, actual_mode), (_, expected_mode)) in
            actual.parameters.iter().zip(&expected.parameters)
        {
            if actual_mode != expected_mode {
                return Err(effect_diagnostic(
                    "callback parameter modes are invariant",
                    origin.clone(),
                ));
            }
        }
        let pairs = actual
            .parameters
            .iter()
            .map(|(ty, _)| ty)
            .zip(expected.parameters.iter().map(|(ty, _)| ty))
            .chain(std::iter::once((
                &actual.return_type,
                &expected.return_type,
            )))
            .collect::<Vec<_>>();
        for (actual, expected) in &pairs {
            if !has_projection(actual) && !has_projection(expected) {
                inference.unify(actual, expected).map_err(|failure| {
                    effect_diagnostic(
                        format!(
                            "callback input/result type is invariant: {}",
                            display_unification_failure(&failure)
                        ),
                        origin.clone(),
                    )
                })?;
            }
        }
        let givens = caller
            .requirements
            .iter()
            .map(|requirement| requirement.map_types(|ty| inference.canonical(ty)))
            .collect::<Vec<_>>();
        let mut solver = SelectionSolver::new(
            &self.normalizer.selection,
            &self.normalizer.project.core_roles,
            &givens,
            origin.clone(),
        )?;
        for (actual, expected) in pairs {
            let actual = solver.normalize(&inference.canonical(actual))?;
            let expected = solver.normalize(&inference.canonical(expected))?;
            inference.unify(&actual, &expected).map_err(|failure| {
                effect_diagnostic(
                    format!(
                        "callback input/result type is invariant: {}",
                        display_unification_failure(&failure)
                    ),
                    origin.clone(),
                )
            })?;
        }
        Ok(())
    }

    pub(super) fn callable_shape(
        &self,
        ty: &CheckedType,
        caller: &FunctionHeader,
        inference: &TypeInference,
        origin: &CheckOrigin,
    ) -> Result<CallableShape, CheckDiagnostic> {
        let ty = inference.canonical(ty);
        match &ty {
            CheckedType::Function(item) => {
                let header = &self.headers[&item.function];
                let (parameters, return_type, effect) =
                    if let Some(scheme) = self.schemes.get(&item.function) {
                        (
                            scheme.parameters.clone(),
                            scheme.return_type.clone(),
                            scheme.effect.clone(),
                        )
                    } else {
                        (
                            header
                                .parameters
                                .iter()
                                .map(|parameter| parameter.ty.clone())
                                .collect(),
                            header.return_type.clone(),
                            header
                                .trait_upper
                                .clone()
                                .or_else(|| header.effect_upper.clone())
                                .expect("an unpublished function value has a closed header"),
                        )
                    };
                let types = item.mapping.types.iter().cloned().collect();
                let effects = item.mapping.effects.iter().cloned().collect();
                Ok(CallableShape {
                    parameters: parameters
                        .iter()
                        .zip(&header.parameters)
                        .map(|(ty, parameter)| {
                            (
                                instantiate_type(ty, &types),
                                parameter
                                    .mode
                                    .as_ref()
                                    .expect("function value modes are closed")
                                    .value,
                            )
                        })
                        .collect(),
                    return_type: instantiate_type(&return_type, &types),
                    effect: effect.instantiate(&types, &effects),
                })
            }
            _ => {
                let requirements = caller
                    .requirements
                    .iter()
                    .map(|requirement| requirement.map_types(|ty| inference.canonical(ty)))
                    .collect::<Vec<_>>();
                self.normalizer
                    .shared_callable(&ty, &requirements, origin.clone())
                    .map_err(|mut diagnostic| {
                        diagnostic.kind = CheckDiagnosticKind::Unsupported;
                        diagnostic.message =
                            "indirect invocation requires retained shared Fn evidence".to_owned();
                        diagnostic
                    })?;
                let shapes = caller
                    .shapes
                    .iter()
                    .filter(|shape| inference.canonical(&shape.subject) == ty)
                    .collect::<Vec<_>>();
                let Some(shape) = shapes.first() else {
                    return Err(effect_diagnostic(
                        "shared Fn input has no callable shape",
                        origin.clone(),
                    ));
                };
                Ok(shape.shape.clone())
            }
        }
    }
}
