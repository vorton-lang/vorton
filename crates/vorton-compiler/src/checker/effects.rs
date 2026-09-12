use super::*;

pub(super) fn validate_method_effect_contracts(
    headers: &BTreeMap<EntityId, FunctionHeader>,
    inference: &TypeInference,
) -> Result<(), CheckDiagnostic> {
    let mut edges = BTreeMap::new();
    for (identity, header) in headers {
        if header.body.is_some() {
            continue;
        }
        let Some(row) = &header.effect_upper else {
            continue;
        };
        row.validate_handled_identities(inference, &header.effect_origin)?;
        let mut pending = vec![row];
        let mut dependencies = BTreeSet::new();
        while let Some(row) = pending.pop() {
            for term in &row.0 {
                if let EffectTerm::Method {
                    method, effects, ..
                } = term
                {
                    dependencies.insert(method.clone());
                    pending.extend(effects);
                }
            }
        }
        edges.insert(identity.clone(), dependencies);
    }
    let mut done = BTreeSet::new();
    let mut active = BTreeSet::new();
    for identity in edges.keys() {
        let mut pending = vec![(identity.clone(), false)];
        while let Some((current, leave)) = pending.pop() {
            if leave {
                active.remove(&current);
                done.insert(current);
                continue;
            }
            if done.contains(&current) {
                continue;
            }
            if !active.insert(current.clone()) {
                return Err(effect_diagnostic(
                    "illegal recursive public method-effect contract",
                    headers[&current].effect_origin.clone(),
                ));
            }
            pending.push((current.clone(), true));
            pending.extend(
                edges[&current]
                    .iter()
                    .filter(|dependency| edges.contains_key(*dependency))
                    .rev()
                    .map(|dependency| (dependency.clone(), false)),
            );
        }
    }
    Ok(())
}

pub(super) struct OperationHeader {
    pub(super) owner: EntityId,
    pub(super) formals: Vec<TypeFormal>,
    pub(super) requirements: Vec<Requirement>,
    pub(super) parameters: Vec<(CheckedType, ParameterMode)>,
    pub(super) return_type: CheckedType,
}

pub(super) struct TypedOperation {
    pub(super) operation: EntityId,
    pub(super) arguments: Vec<TypedExpr>,
    pub(super) parameter_modes: Vec<ParameterMode>,
    pub(super) mapping: CallMapping,
    pub(super) effect: EffectRow,
    pub(super) evidence: Vec<Evidence>,
}

impl SourceTypeNormalizer<'_> {
    pub(super) fn collect_operations(
        &mut self,
        owner: &EntityId,
        parameters: &[crate::project::ResolvedTypeParameter],
        operations: &[crate::project::ResolvedEffectOperation],
    ) -> Result<(), CheckDiagnostic> {
        let formals = self.owner_formals[owner].clone();
        let requirements = self.parameter_requirements(parameters, &formals)?;
        for operation in operations {
            let mut inputs = Vec::new();
            for parameter in &operation.parameters {
                let Some(ResolvedParameterAnnotation::Type(ty)) = &parameter.annotation else {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "effect operation input requires a supported type",
                        parameter.binding.origin.clone(),
                        Vec::new(),
                    ));
                };
                let mode = parameter
                    .mode
                    .map_or(ParameterMode::Borrow, |(_, mode)| mode);
                if parameter.escape.is_some()
                    || !matches!(mode, ParameterMode::Borrow | ParameterMode::Move)
                {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "effect operation resource or callback mode is unsupported",
                        parameter.binding.origin.clone(),
                        Vec::new(),
                    ));
                }
                inputs.push((self.normalize_with_formals(ty, &formals)?, mode));
            }
            let return_type = self.normalize_with_formals(&operation.return_type, &formals)?;
            self.operations.insert(
                operation.identity.clone(),
                OperationHeader {
                    owner: owner.clone(),
                    formals: parameters
                        .iter()
                        .map(|parameter| formals[&parameter.binding.identity].clone())
                        .collect(),
                    requirements: requirements.clone(),
                    parameters: inputs,
                    return_type,
                },
            );
        }
        Ok(())
    }
}

impl BodyChecker<'_, '_> {
    pub(super) fn operation_draft(
        &mut self,
        origin: OriginRef,
        owner: &EntityId,
        member: &ResolvedSelection,
        arguments: &[ResolvedCallArgument],
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let operation = member
            .declaration
            .as_ref()
            .expect("Resolver closes operation identity")
            .clone();
        let failure = owner.kind == EntityKind::LanguageEffect && owner.name == "fail";
        let (mapping, parameters, return_type, effect) = if failure {
            let formal = TypeFormal {
                owner: operation.clone(),
                ordinal: 0,
                name: "Payload".to_owned(),
            };
            let payload = self.inference.fresh();
            (
                vec![(formal, payload.clone())],
                vec![(payload.clone(), ParameterMode::Move)],
                CheckedType::Never,
                EffectRow(vec![EffectTerm::Fail(payload)]),
            )
        } else {
            let header = &self.normalizer.operations[&operation];
            let mapping = header
                .formals
                .iter()
                .cloned()
                .map(|formal| (formal, self.inference.fresh()))
                .collect::<BTreeMap<_, _>>();
            let effect = EffectRow(vec![EffectTerm::Handled(
                header.owner.clone(),
                header
                    .formals
                    .iter()
                    .map(|formal| mapping[formal].clone())
                    .collect(),
            )]);
            let parameters = header
                .parameters
                .iter()
                .map(|(ty, mode)| (instantiate_type(ty, &mapping), *mode))
                .collect();
            let return_type = instantiate_type(&header.return_type, &mapping);
            (
                mapping.into_iter().collect(),
                parameters,
                return_type,
                effect,
            )
        };
        if arguments.len() != parameters.len() {
            return Err(source_diagnostic(
                CheckDiagnosticKind::CallMismatch,
                "operation argument arity does not match its exact declaration",
                origin,
                entity_origin(&operation).into_iter().collect(),
            ));
        }
        let mut typed = Vec::new();
        for (argument, (expected, _)) in arguments.iter().zip(&parameters) {
            let ResolvedCallArgument::Expression(argument) = argument else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "operation call-site resource assertions are unsupported",
                    origin,
                    Vec::new(),
                ));
            };
            let value = self.check_expr(argument)?;
            self.inference
                .satisfy(&value.ty, expected)
                .map_err(|failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::CallMismatch,
                        display_unification_failure(&failure),
                        self.origin(argument.span),
                        entity_origin(&operation).into_iter().collect(),
                    )
                })?;
            typed.push(value);
        }
        let ty = if typed.iter().any(|argument| self.is_never(&argument.ty)) {
            CheckedType::Never
        } else {
            return_type
        };
        Ok(TypedExpr {
            span: origin.span,
            ty,
            kind: TypedExprKind::Operation(Box::new(TypedOperation {
                operation,
                arguments: typed,
                parameter_modes: parameters.into_iter().map(|(_, mode)| mode).collect(),
                mapping: CallMapping {
                    types: mapping,
                    effects: Vec::new(),
                },
                effect,
                evidence: Vec::new(),
            })),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum SystemEffect {
    Console,
    Fs,
    Process,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct EffectFormal {
    pub(super) owner: EntityId,
    pub(super) ordinal: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Default)]
pub(super) struct EffectRow(pub(super) Vec<EffectTerm>);

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum EffectTerm {
    System(SystemEffect),
    Handled(EntityId, Vec<CheckedType>),
    Fail(CheckedType),
    Mut,
    Unsafe,
    Formal(EffectFormal),
    Variable(u32),
    Method {
        method: EntityId,
        types: Vec<CheckedType>,
        effects: Vec<EffectRow>,
    },
    Destruction(CheckedType),
    SelectedCall(CheckedType),
}

impl EffectTerm {
    pub(super) fn same_atom(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Fail(_), Self::Fail(_)) => true,
            (Self::Handled(left, _), Self::Handled(right, _)) => left == right,
            _ => self == other,
        }
    }
}

pub(super) struct EffectEquation {
    pub(super) calls: Vec<EffectCall>,
    pub(super) rows: Vec<(EffectRow, bool)>,
}

pub(super) struct EffectCall {
    pub(super) callee: EntityId,
    pub(super) types: BTreeMap<TypeFormal, CheckedType>,
    pub(super) effects: BTreeMap<EffectFormal, EffectRow>,
    pub(super) discharge_unsafe: bool,
}

pub(super) struct EffectClosure {
    pub(super) rows: BTreeMap<EntityId, EffectRow>,
    pub(super) dependencies: BTreeMap<EntityId, BTreeSet<EntityId>>,
    pub(super) inferences: BTreeMap<EffectFormal, EffectRow>,
}

pub(super) struct EffectEnvironment<'a, 'project> {
    pub(super) normalizer: &'a SourceTypeNormalizer<'project>,
    pub(super) headers: &'a BTreeMap<EntityId, FunctionHeader>,
    pub(super) schemes: &'a BTreeMap<EntityId, CallableScheme>,
}

impl EffectEquation {
    pub(super) fn substitute(&mut self, replacements: &BTreeMap<EffectFormal, EffectRow>) {
        for (row, _) in &mut self.rows {
            *row = row.instantiate(&BTreeMap::new(), replacements);
        }
        for call in &mut self.calls {
            for row in call.effects.values_mut() {
                *row = row.instantiate(&BTreeMap::new(), replacements);
            }
        }
    }
    pub(super) fn from_body(block: &TypedBlock) -> Self {
        enum Node<'a> {
            Block(&'a TypedBlock, bool),
            Expr(&'a TypedExpr, bool),
        }
        let mut pending = vec![Node::Block(block, false)];
        let mut equation = Self {
            calls: Vec::new(),
            rows: Vec::new(),
        };
        while let Some(node) = pending.pop() {
            match node {
                Node::Block(block, discharge) => {
                    let mut continues = true;
                    for statement in &block.statements {
                        if !continues {
                            break;
                        }
                        let expression = match &statement.kind {
                            TypedStatementKind::Let { value, .. }
                            | TypedStatementKind::Expression(value) => Some(value.as_ref()),
                            TypedStatementKind::Return(value) => {
                                continues = false;
                                value.as_deref()
                            }
                        };
                        if let Some(expression) = expression {
                            pending.push(Node::Expr(expression, discharge));
                            continues &= expression.ty != CheckedType::Never;
                        }
                    }
                    if continues && let Some(tail) = &block.tail {
                        pending.push(Node::Expr(tail, discharge));
                    }
                }
                Node::Expr(expression, discharge) => match &expression.kind {
                    TypedExprKind::Indirect(call) => {
                        pending.push(Node::Expr(&call.callable, discharge));
                        let mut enters = call.callable.ty != CheckedType::Never;
                        for argument in &call.arguments {
                            if !enters {
                                break;
                            }
                            pending.push(Node::Expr(argument, discharge));
                            enters &= argument.ty != CheckedType::Never;
                        }
                        if enters {
                            equation.rows.push((
                                call.effect.clone().expect("indirect row is selected"),
                                discharge,
                            ));
                        }
                    }
                    TypedExprKind::Call {
                        callee,
                        arguments,
                        instantiation,
                        ..
                    } => {
                        let mut enters = true;
                        for argument in arguments {
                            if !enters {
                                break;
                            }
                            pending.push(Node::Expr(argument, discharge));
                            enters &= argument.ty != CheckedType::Never;
                        }
                        if enters {
                            let (types, effects) = match instantiation {
                                CallInstantiation::Published(mapping)
                                | CallInstantiation::Provisional(mapping) => (
                                    mapping.types.iter().cloned().collect(),
                                    mapping.effects.iter().cloned().collect(),
                                ),
                                CallInstantiation::RecursiveBinding { effects } => {
                                    (BTreeMap::new(), effects.iter().cloned().collect())
                                }
                                CallInstantiation::Pending(_) => {
                                    unreachable!("effect equations consume bound calls")
                                }
                            };
                            equation.calls.push(EffectCall {
                                callee: callee.as_ref().clone(),
                                types,
                                effects,
                                discharge_unsafe: discharge,
                            });
                        }
                    }
                    TypedExprKind::MethodDraft { .. } => {
                        unreachable!("method selection precedes effect equations")
                    }
                    TypedExprKind::Parenthesized(inner)
                    | TypedExprKind::Unary { operand: inner, .. }
                    | TypedExprKind::Field {
                        receiver: inner, ..
                    }
                    | TypedExprKind::TupleField {
                        receiver: inner, ..
                    } => pending.push(Node::Expr(inner, discharge)),
                    TypedExprKind::Tuple(elements) => {
                        for element in elements {
                            pending.push(Node::Expr(element, discharge));
                            if element.ty == CheckedType::Never {
                                break;
                            }
                        }
                    }
                    TypedExprKind::Construct(construction) => {
                        for field in &construction.fields {
                            pending.push(Node::Expr(&field.value, discharge));
                            if field.value.ty == CheckedType::Never {
                                break;
                            }
                        }
                    }
                    TypedExprKind::Block(block) => pending.push(Node::Block(block, discharge)),
                    TypedExprKind::Unsafe(block) => pending.push(Node::Block(block, true)),
                    TypedExprKind::Operation(operation) => {
                        let mut enters = true;
                        for argument in &operation.arguments {
                            if !enters {
                                break;
                            }
                            pending.push(Node::Expr(argument, discharge));
                            enters &= argument.ty != CheckedType::Never;
                        }
                        if enters {
                            equation.rows.push((operation.effect.clone(), discharge));
                        }
                    }
                    TypedExprKind::If {
                        condition,
                        then_branch,
                        else_branch,
                    } => {
                        pending.push(Node::Expr(condition, discharge));
                        if condition.ty != CheckedType::Never {
                            pending.push(Node::Block(then_branch, discharge));
                            if let Some(branch) = else_branch {
                                pending.push(Node::Expr(branch, discharge));
                            }
                        }
                    }
                    TypedExprKind::Binary { left, right, .. } => {
                        pending.push(Node::Expr(left, discharge));
                        if left.ty != CheckedType::Never {
                            pending.push(Node::Expr(right, discharge));
                        }
                    }
                    _ => {}
                },
            }
        }
        equation
    }
}

impl EffectEnvironment<'_, '_> {
    pub(super) fn populate_calls(
        &self,
        block: &mut TypedBlock,
        header: &FunctionHeader,
        rows: &BTreeMap<EntityId, EffectRow>,
        inference: &mut TypeInference,
    ) -> Result<(), CheckDiagnostic> {
        for statement in &mut block.statements {
            match &mut statement.kind {
                TypedStatementKind::Let { value, .. } | TypedStatementKind::Expression(value) => {
                    self.populate_expression(value, header, rows, inference)?
                }
                TypedStatementKind::Return(value) => {
                    if let Some(value) = value {
                        self.populate_expression(value, header, rows, inference)?;
                    }
                }
            }
        }
        if let Some(tail) = &mut block.tail {
            self.populate_expression(tail, header, rows, inference)?;
        }
        Ok(())
    }

    fn populate_expression(
        &self,
        expression: &mut TypedExpr,
        header: &FunctionHeader,
        rows: &BTreeMap<EntityId, EffectRow>,
        inference: &mut TypeInference,
    ) -> Result<(), CheckDiagnostic> {
        match &mut expression.kind {
            TypedExprKind::Indirect(call) => {
                self.populate_expression(&mut call.callable, header, rows, inference)?;
                for argument in &mut call.arguments {
                    self.populate_expression(argument, header, rows, inference)?;
                }
                let mut needed = BTreeSet::new();
                call.effect = Some(self.expand(
                    call.effect.as_ref().expect("bound indirect effect"),
                    header,
                    rows,
                    inference,
                    &mut needed,
                )?);
                if !needed.is_empty() {
                    return Err(effect_diagnostic(
                        "callback effect dependency remained after closure",
                        CheckOrigin::Source(header.origin.clone()),
                    ));
                }
            }
            TypedExprKind::Call {
                callee,
                arguments,
                instantiation,
                effect,
                ..
            } => {
                for argument in arguments {
                    self.populate_expression(argument, header, rows, inference)?;
                }
                let source = rows
                    .get(callee.as_ref())
                    .or_else(|| {
                        self.schemes
                            .get(callee.as_ref())
                            .map(|scheme| &scheme.effect)
                    })
                    .expect("callee row is closed in its binding group");
                let row = match instantiation {
                    CallInstantiation::Published(mapping)
                    | CallInstantiation::Provisional(mapping) => source.instantiate(
                        &mapping.types.iter().cloned().collect(),
                        &mapping.effects.iter().cloned().collect(),
                    ),
                    CallInstantiation::RecursiveBinding { effects } => {
                        source.instantiate(&BTreeMap::new(), &effects.iter().cloned().collect())
                    }
                    CallInstantiation::Pending(_) => {
                        unreachable!("call application precedes effect closure")
                    }
                };
                let mut needed = BTreeSet::new();
                *effect = Some(self.expand(&row, header, rows, inference, &mut needed)?);
                if !needed.is_empty() {
                    return Err(effect_diagnostic(
                        "effect dependency remained after joint closure",
                        CheckOrigin::Source(header.origin.clone()),
                    ));
                }
            }
            TypedExprKind::Operation(operation) => {
                for argument in &mut operation.arguments {
                    self.populate_expression(argument, header, rows, inference)?;
                }
                operation.effect = operation
                    .effect
                    .map_types(&mut |ty| inference.canonical(ty));
            }
            TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
                self.populate_calls(block, header, rows, inference)?
            }
            TypedExprKind::Parenthesized(inner)
            | TypedExprKind::Unary { operand: inner, .. }
            | TypedExprKind::Field {
                receiver: inner, ..
            }
            | TypedExprKind::TupleField {
                receiver: inner, ..
            } => self.populate_expression(inner, header, rows, inference)?,
            TypedExprKind::Tuple(elements) => {
                for element in elements {
                    self.populate_expression(element, header, rows, inference)?;
                }
            }
            TypedExprKind::Construct(construction) => {
                for field in &mut construction.fields {
                    self.populate_expression(&mut field.value, header, rows, inference)?;
                }
            }
            TypedExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => {
                self.populate_expression(condition, header, rows, inference)?;
                self.populate_calls(then_branch, header, rows, inference)?;
                if let Some(branch) = else_branch {
                    self.populate_expression(branch, header, rows, inference)?;
                }
            }
            TypedExprKind::Binary { left, right, .. } => {
                self.populate_expression(left, header, rows, inference)?;
                self.populate_expression(right, header, rows, inference)?;
            }
            _ => {}
        }
        Ok(())
    }
    pub(super) fn close_group(
        &self,
        group: &[EntityId],
        equations: &BTreeMap<EntityId, EffectEquation>,
        inference: &mut TypeInference,
    ) -> Result<EffectClosure, CheckDiagnostic> {
        let mut rows = group
            .iter()
            .map(|identity| {
                (
                    identity.clone(),
                    self.headers[identity]
                        .trait_upper
                        .clone()
                        .or_else(|| self.headers[identity].effect_upper.clone())
                        .unwrap_or_default(),
                )
            })
            .collect::<BTreeMap<_, _>>();
        let mut work = 0_usize;
        loop {
            let mut changed = false;
            let mut dependencies = BTreeMap::new();
            for identity in group {
                work += 1;
                let header = &self.headers[identity];
                let origin = CheckOrigin::Source(header.origin.clone());
                if work > SELECTION_WORK_LIMIT {
                    return Err(effect_diagnostic(
                        format!(
                            "recursive effect proof incomplete: work limit {SELECTION_WORK_LIMIT} exceeded"
                        ),
                        origin,
                    ));
                }
                let mut needed = BTreeSet::new();
                let mut actual = EffectRow::default();
                for (row, discharge) in &equations[identity].rows {
                    let mut row = self.expand(row, header, &rows, inference, &mut needed)?;
                    if *discharge {
                        row.0.retain(|term| *term != EffectTerm::Unsafe);
                    }
                    actual.union(&row, inference, &origin)?;
                }
                for call in &equations[identity].calls {
                    let row = rows
                        .get(&call.callee)
                        .or_else(|| self.schemes.get(&call.callee).map(|scheme| &scheme.effect))
                        .expect("type closure provides callee schemes or same-group bindings");
                    let row = row
                        .instantiate(&call.types, &call.effects)
                        .map_types(&mut |ty| inference.canonical(ty));
                    let mut row = self.expand(&row, header, &rows, inference, &mut needed)?;
                    if call.discharge_unsafe {
                        row.0.retain(|term| *term != EffectTerm::Unsafe);
                    }
                    actual.union(&row, inference, &origin)?;
                }
                let own_upper = header
                    .effect_upper
                    .as_ref()
                    .map(|row| self.expand(row, header, &rows, inference, &mut needed))
                    .transpose()?;
                let trait_upper = header
                    .trait_upper
                    .as_ref()
                    .map(|row| self.expand(row, header, &rows, inference, &mut needed))
                    .transpose()?;
                if !needed.is_empty() {
                    dependencies.insert(identity.clone(), needed);
                    continue;
                }
                if let Some(upper) = &own_upper {
                    let mut inferences = BTreeMap::new();
                    for term in &actual.0 {
                        if upper.0.contains(term) {
                            continue;
                        }
                        let formal = match term {
                            EffectTerm::Formal(formal) => Some(formal),
                            EffectTerm::SelectedCall(ty) => {
                                header.shapes.iter().find_map(|shape| {
                                    if inference.canonical(&shape.subject)
                                        != inference.canonical(ty)
                                    {
                                        return None;
                                    }
                                    match shape.shape.effect.0.as_slice() {
                                        [EffectTerm::Formal(formal)]
                                            if !upper
                                                .0
                                                .contains(&EffectTerm::Formal(formal.clone())) =>
                                        {
                                            Some(formal)
                                        }
                                        _ => None,
                                    }
                                })
                            }
                            _ => None,
                        };
                        if let Some(formal) = formal
                            && header.inferable_effects.contains(formal)
                        {
                            inferences.insert(formal.clone(), upper.clone());
                        }
                    }
                    if !inferences.is_empty() {
                        return Ok(EffectClosure {
                            rows,
                            dependencies,
                            inferences,
                        });
                    }
                }
                if let Some(upper) = &own_upper {
                    self.subset(&actual, upper, header, inference, &header.effect_origin)?;
                }
                if let Some(upper) = &trait_upper {
                    self.subset(
                        own_upper.as_ref().unwrap_or(&actual),
                        upper,
                        header,
                        inference,
                        header.trait_effect_origin.as_ref().unwrap_or(&origin),
                    )?;
                }
                let published = trait_upper.or(own_upper).unwrap_or(actual);
                published.validate_handled_identities(inference, &origin)?;
                if let Some((ceiling, ceiling_origin)) =
                    self.normalizer.module_effects.get(&identity.module)
                {
                    let ceiling = self.expand(ceiling, header, &rows, inference, &mut needed)?;
                    self.subset(
                        &published,
                        &ceiling,
                        header,
                        inference,
                        &CheckOrigin::Source(ceiling_origin.clone()),
                    )?;
                }
                if identity.kind == EntityKind::Function
                    && identity.name == "main"
                    && identity.module == ModuleRef::root(self.normalizer.project.entry)
                    && published.0.iter().any(|term| {
                        matches!(
                            term,
                            EffectTerm::Handled(_, _)
                                | EffectTerm::Formal(_)
                                | EffectTerm::Variable(_)
                                | EffectTerm::Method { .. }
                                | EffectTerm::SelectedCall(_)
                        )
                    })
                {
                    return Err(effect_diagnostic(
                        "an unhandled user effect may escape main",
                        origin,
                    ));
                }
                if rows[identity] != published {
                    rows.insert(identity.clone(), published);
                    changed = true;
                }
            }
            if !dependencies.is_empty() || !changed {
                return Ok(EffectClosure {
                    rows,
                    dependencies,
                    inferences: BTreeMap::new(),
                });
            }
        }
    }

    pub(super) fn expand(
        &self,
        row: &EffectRow,
        header: &FunctionHeader,
        rows: &BTreeMap<EntityId, EffectRow>,
        inference: &mut TypeInference,
        needed: &mut BTreeSet<EntityId>,
    ) -> Result<EffectRow, CheckDiagnostic> {
        enum Frame {
            Term(EffectTerm),
            End(EffectTerm),
        }
        let givens = header
            .requirements
            .iter()
            .map(|requirement| requirement.map_types(|ty| inference.canonical(ty)))
            .collect::<Vec<_>>();
        let mut solver = SelectionSolver::new(
            &self.normalizer.selection,
            &self.normalizer.project.core_roles,
            &givens,
            CheckOrigin::Source(header.origin.clone()),
        )?;
        let row = solver.normalize_row(&row.map_types(&mut |ty| inference.canonical(ty)))?;
        let mut pending = row
            .0
            .iter()
            .rev()
            .cloned()
            .map(Frame::Term)
            .collect::<Vec<_>>();
        let mut active = BTreeSet::new();
        let mut result = EffectRow::default();
        let origin = CheckOrigin::Source(header.origin.clone());
        let mut work = 0_usize;
        while let Some(frame) = pending.pop() {
            work += 1;
            if work > SELECTION_WORK_LIMIT || active.len() > SELECTION_STATE_LIMIT {
                return Err(effect_diagnostic(
                    "effect selection proof incomplete: deterministic work/state limit reached",
                    origin,
                ));
            }
            let term = match frame {
                Frame::End(term) => {
                    active.remove(&term);
                    continue;
                }
                Frame::Term(term) => term,
            };
            match &term {
                EffectTerm::Variable(_) => {
                    let resolved = inference.resolve_effect(&EffectRow(vec![term.clone()]));
                    if resolved == EffectRow(vec![term.clone()]) {
                        return Err(effect_diagnostic(
                            "effect actual remains undetermined at row closure",
                            origin,
                        ));
                    }
                    pending.extend(resolved.0.into_iter().rev().map(Frame::Term));
                }
                EffectTerm::SelectedCall(ty) => {
                    let ty = inference.canonical(ty);
                    let replacement = if let CheckedType::Function(item) = &ty {
                        match rows.get(&item.function).or_else(|| {
                            self.schemes
                                .get(&item.function)
                                .map(|scheme| &scheme.effect)
                        }) {
                            Some(row) => Some(row.instantiate(
                                &item.mapping.types.iter().cloned().collect(),
                                &item.mapping.effects.iter().cloned().collect(),
                            )),
                            None => {
                                needed.insert(item.function.clone());
                                None
                            }
                        }
                    } else {
                        let givens = header
                            .requirements
                            .iter()
                            .map(|requirement| requirement.map_types(|ty| inference.canonical(ty)))
                            .collect::<Vec<_>>();
                        self.normalizer
                            .shared_callable(&ty, &givens, origin.clone())?;
                        header
                            .shapes
                            .iter()
                            .find(|shape| {
                                inference.canonical(&shape.subject) == ty
                                    && shape.shape.effect.0.is_empty()
                            })
                            .map(|_| EffectRow::default())
                    };
                    if let Some(replacement) = replacement {
                        if !active.insert(term.clone()) {
                            return Err(effect_diagnostic(
                                "illegal selected-call effect cycle",
                                origin,
                            ));
                        }
                        pending.push(Frame::End(term));
                        pending.extend(replacement.0.into_iter().rev().map(Frame::Term));
                    } else {
                        result.union(
                            &EffectRow(vec![EffectTerm::SelectedCall(ty)]),
                            inference,
                            &origin,
                        )?;
                    }
                }
                EffectTerm::Destruction(ty) => {
                    let row = self.destruction(ty, header, inference)?;
                    result.union(&row, inference, &origin)?;
                }
                EffectTerm::Method {
                    method,
                    types,
                    effects,
                } => {
                    let owner = self.normalizer.project.entities[method]
                        .owner
                        .as_ref()
                        .expect("trait method owner");
                    let definition = &self.normalizer.selection.traits[owner];
                    let method_header = self.headers.get(method).ok_or_else(|| {
                        effect_diagnostic(
                            "method scheme requires unsupported callable inputs",
                            origin.clone(),
                        )
                    })?;
                    if types.len()
                        != 1 + definition.formals.len() + method_header.declared_formals.len()
                        || effects.len() != method_header.effect_formals.len()
                    {
                        return Err(effect_diagnostic(
                            "method scheme type/effect actual arity does not match its exact owner",
                            origin,
                        ));
                    }
                    let bound = TraitUse {
                        declaration: owner.clone(),
                        arguments: types[1..1 + definition.formals.len()].to_vec(),
                        associated: BTreeMap::new(),
                    };
                    let givens = header
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
                    let subject = solver.normalize(&inference.canonical(&types[0]))?;
                    let evidence = solver.prove(&Requirement {
                        subject: subject.clone(),
                        bound: bound.clone(),
                        origin: origin.clone(),
                    })?;
                    let mut mapping = definition.mapping(&subject, &bound);
                    mapping.extend(
                        method_header
                            .declared_formals
                            .iter()
                            .cloned()
                            .zip(types[1 + definition.formals.len()..].iter().cloned()),
                    );
                    let effect_mapping = method_header
                        .effect_formals
                        .iter()
                        .cloned()
                        .zip(effects.iter().cloned())
                        .collect();
                    let replacement = if let Some(upper) = &method_header.effect_upper {
                        Some(upper.instantiate(&mapping, &effect_mapping))
                    } else {
                        match &solver.evidence[evidence] {
                            Evidence::Given(_) | Evidence::Associated { .. } => None,
                            Evidence::Primitive { .. } => Some(EffectRow::default()),
                            Evidence::Implementation {
                                identity,
                                mapping: outer,
                                ..
                            } => {
                                let selected = &self.normalizer.selection.implementations[identity]
                                    .methods[&method.name];
                                let selected_header = &self.headers[selected];
                                let mut mapping = outer.clone();
                                mapping.extend(
                                    selected_header
                                        .declared_formals
                                        .iter()
                                        .cloned()
                                        .zip(types[1 + definition.formals.len()..].iter().cloned()),
                                );
                                let effects = selected_header
                                    .effect_formals
                                    .iter()
                                    .cloned()
                                    .zip(effects.iter().cloned())
                                    .collect();
                                match rows.get(selected).or_else(|| {
                                    self.schemes.get(selected).map(|scheme| &scheme.effect)
                                }) {
                                    Some(row) => Some(row.instantiate(&mapping, &effects)),
                                    None => {
                                        needed.insert(selected.clone());
                                        None
                                    }
                                }
                            }
                        }
                    };
                    if let Some(replacement) = replacement {
                        if !active.insert(term.clone()) {
                            return Err(effect_diagnostic(
                                "illegal recursive public method-effect contract",
                                origin,
                            ));
                        }
                        pending.push(Frame::End(term));
                        pending.extend(replacement.0.into_iter().rev().map(Frame::Term));
                    } else {
                        result.union(&EffectRow(vec![term]), inference, &origin)?;
                    }
                }
                _ => result.union(&EffectRow(vec![term]), inference, &origin)?,
            }
        }
        Ok(result)
    }

    fn destruction(
        &self,
        ty: &CheckedType,
        header: &FunctionHeader,
        inference: &TypeInference,
    ) -> Result<EffectRow, CheckDiagnostic> {
        enum Frame {
            Type(CheckedType),
            Combine(usize),
            Enter(NominalType),
            Leave(EntityId, usize),
        }
        let origin = CheckOrigin::Source(header.origin.clone());
        let givens = header
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
        let ty = solver.normalize(&inference.canonical(ty))?;
        if cleanup_is_empty(std::slice::from_ref(&ty), &self.normalizer.nominals) {
            return Ok(EffectRow::default());
        }
        let mut frames = vec![Frame::Type(ty)];
        let mut values: Vec<EffectRow> = Vec::new();
        let mut environments: Vec<BTreeMap<TypeFormal, (CheckedType, EffectRow)>> =
            vec![BTreeMap::new()];
        let mut active = BTreeSet::new();
        let mut work = 0_usize;
        while let Some(frame) = frames.pop() {
            work += 1;
            if work > SELECTION_WORK_LIMIT {
                return Err(effect_diagnostic(
                    "full destruction proof incomplete: deterministic work limit reached",
                    origin,
                ));
            }
            match frame {
                Frame::Type(ty) => match ty {
                    CheckedType::Int
                    | CheckedType::Float
                    | CheckedType::Bool
                    | CheckedType::Unit
                    | CheckedType::Never
                    | CheckedType::Function(_) => values.push(EffectRow::default()),
                    CheckedType::Formal(formal) => values.push(
                        environments
                            .last()
                            .expect("destruction environment")
                            .get(formal.as_ref())
                            .map_or_else(
                                || {
                                    EffectRow(vec![EffectTerm::Destruction(CheckedType::Formal(
                                        formal,
                                    ))])
                                },
                                |(_, row)| row.clone(),
                            ),
                    ),
                    CheckedType::Infer(_) => {
                        values.push(EffectRow(vec![EffectTerm::Destruction(ty)]))
                    }
                    CheckedType::Tuple(elements) => {
                        frames.push(Frame::Combine(elements.len()));
                        frames.extend(elements.into_iter().rev().map(Frame::Type));
                    }
                    CheckedType::Nominal(nominal) => {
                        let mapping = environments
                            .last()
                            .expect("destruction environment")
                            .iter()
                            .map(|(formal, (ty, _))| (formal.clone(), ty.clone()))
                            .collect();
                        let CheckedType::Nominal(actual) =
                            instantiate_type(&CheckedType::Nominal(nominal.clone()), &mapping)
                        else {
                            unreachable!("nominal substitution preserves its constructor")
                        };
                        if active.contains(&nominal.declaration) {
                            // This is a defined structural destruction relation,
                            // not coinductive trait evidence or a pure answer.
                            values.push(EffectRow(vec![EffectTerm::Destruction(
                                CheckedType::Nominal(actual),
                            )]));
                        } else {
                            frames.push(Frame::Enter(*actual));
                            frames.extend(nominal.arguments.into_iter().rev().map(Frame::Type));
                        }
                    }
                    CheckedType::Projection(projection) => {
                        let mapping = environments
                            .last()
                            .expect("destruction environment")
                            .iter()
                            .map(|(formal, (ty, _))| (formal.clone(), ty.clone()))
                            .collect();
                        let projected =
                            instantiate_type(&CheckedType::Projection(projection), &mapping);
                        let resolved = solver.normalize(&projected)?;
                        if resolved == projected {
                            values.push(EffectRow(vec![EffectTerm::Destruction(resolved)]));
                        } else {
                            frames.push(Frame::Type(resolved));
                        }
                    }
                },
                Frame::Combine(count) => {
                    let first = values.len() - count;
                    let terms = values
                        .drain(first..)
                        .flat_map(|row| row.0)
                        .collect::<BTreeSet<_>>();
                    values.push(EffectRow(terms.into_iter().collect()));
                }
                Frame::Enter(nominal) => {
                    let definition = &self.normalizer.nominals[&nominal.declaration];
                    let first = values.len() - nominal.arguments.len();
                    environments.push(
                        definition
                            .formals
                            .iter()
                            .cloned()
                            .zip(nominal.arguments.into_iter().zip(values.drain(first..)))
                            .collect(),
                    );
                    active.insert(nominal.declaration.clone());
                    let fields = definition
                        .constructors
                        .values()
                        .flat_map(|constructor| &constructor.fields)
                        .collect::<Vec<_>>();
                    frames.push(Frame::Leave(nominal.declaration, fields.len()));
                    frames.extend(
                        fields
                            .into_iter()
                            .rev()
                            .map(|field| Frame::Type(field.ty.clone())),
                    );
                }
                Frame::Leave(declaration, count) => {
                    active.remove(&declaration);
                    environments.pop();
                    frames.push(Frame::Combine(count));
                }
            }
        }
        Ok(values.pop().expect("one destruction result"))
    }

    pub(super) fn subset(
        &self,
        actual: &EffectRow,
        upper: &EffectRow,
        header: &FunctionHeader,
        inference: &mut TypeInference,
        origin: &CheckOrigin,
    ) -> Result<(), CheckDiagnostic> {
        for term in &actual.0 {
            if let EffectTerm::SelectedCall(ty) = term
                && !upper.0.contains(term)
            {
                let ty = inference.canonical(ty);
                let caps = header
                    .shapes
                    .iter()
                    .filter(|shape| inference.canonical(&shape.subject) == ty)
                    .collect::<Vec<_>>();
                if let Some(shape) = caps.first() {
                    shape.shape.effect.subset_of(upper, inference, origin)?;
                    continue;
                }
            }
            EffectRow(vec![term.clone()]).subset_of(upper, inference, origin)?;
        }
        Ok(())
    }
}

impl EffectRow {
    pub(super) fn types(&self) -> Vec<&CheckedType> {
        let mut types = Vec::new();
        let mut rows = vec![self];
        while let Some(row) = rows.pop() {
            for term in &row.0 {
                match term {
                    EffectTerm::Handled(_, arguments) => types.extend(arguments),
                    EffectTerm::Fail(ty)
                    | EffectTerm::Destruction(ty)
                    | EffectTerm::SelectedCall(ty) => types.push(ty),
                    EffectTerm::Method {
                        types: actuals,
                        effects,
                        ..
                    } => {
                        types.extend(actuals);
                        rows.extend(effects);
                    }
                    _ => {}
                }
            }
        }
        types
    }
    pub(super) fn map_types(&self, map: &mut impl FnMut(&CheckedType) -> CheckedType) -> Self {
        Self(
            self.0
                .iter()
                .map(|term| match term {
                    EffectTerm::Handled(effect, arguments) => EffectTerm::Handled(
                        effect.clone(),
                        arguments.iter().map(&mut *map).collect(),
                    ),
                    EffectTerm::Fail(ty) => EffectTerm::Fail(map(ty)),
                    EffectTerm::Destruction(ty) => EffectTerm::Destruction(map(ty)),
                    EffectTerm::SelectedCall(ty) => EffectTerm::SelectedCall(map(ty)),
                    EffectTerm::Method {
                        method,
                        types,
                        effects,
                    } => EffectTerm::Method {
                        method: method.clone(),
                        types: types.iter().map(&mut *map).collect(),
                        effects: effects.iter().map(|row| row.map_types(map)).collect(),
                    },
                    term => term.clone(),
                })
                .collect(),
        )
    }

    pub(super) fn instantiate(
        &self,
        types: &BTreeMap<TypeFormal, CheckedType>,
        effects: &BTreeMap<EffectFormal, EffectRow>,
    ) -> Self {
        let row = self.map_types(&mut |ty| instantiate_type(ty, types));
        Self(
            row.0
                .into_iter()
                .flat_map(|term| match term {
                    EffectTerm::Formal(formal) => effects
                        .get(&formal)
                        .cloned()
                        .map_or_else(|| vec![EffectTerm::Formal(formal)], |row| row.0),
                    EffectTerm::Method {
                        method,
                        types: actuals,
                        effects: actual_effects,
                    } => vec![EffectTerm::Method {
                        method,
                        types: actuals,
                        effects: actual_effects
                            .iter()
                            .map(|row| row.instantiate(&BTreeMap::new(), effects))
                            .collect(),
                    }],
                    term => vec![term],
                })
                .collect(),
        )
    }

    pub(super) fn may_exit(&self) -> bool {
        // A handled operation can leave its suspended computation when the
        // dynamically selected arm fails. Its own row need not contain fail.
        self.0.iter().any(|term| {
            matches!(
                term,
                EffectTerm::Handled(_, _)
                    | EffectTerm::Fail(_)
                    | EffectTerm::Formal(_)
                    | EffectTerm::Variable(_)
                    | EffectTerm::Method { .. }
                    | EffectTerm::SelectedCall(_)
            )
        })
    }

    pub(super) fn union(
        &mut self,
        other: &Self,
        inference: &mut TypeInference,
        origin: &CheckOrigin,
    ) -> Result<(), CheckDiagnostic> {
        for term in &other.0 {
            let matching = self.0.iter().find(|existing| existing.same_atom(term));
            if let Some(existing) = matching {
                let pairs = match (existing, term) {
                    (EffectTerm::Fail(left), EffectTerm::Fail(right)) => vec![(left, right)],
                    (EffectTerm::Handled(_, left), EffectTerm::Handled(_, right)) => {
                        left.iter().zip(right).collect()
                    }
                    _ => Vec::new(),
                };
                for (left, right) in pairs {
                    inference.unify(left, right).map_err(|failure| {
                        effect_diagnostic(
                            format!(
                                "effect payload conflict: {}",
                                display_unification_failure(&failure)
                            ),
                            origin.clone(),
                        )
                    })?;
                }
            } else {
                self.0.push(term.clone());
            }
        }
        *self = self.map_types(&mut |ty| inference.canonical(ty));
        self.0.sort();
        self.0.dedup();
        Ok(())
    }

    pub(super) fn subset_of(
        &self,
        upper: &Self,
        inference: &mut TypeInference,
        origin: &CheckOrigin,
    ) -> Result<(), CheckDiagnostic> {
        for term in &self.0 {
            let matching = upper.0.iter().find(|expected| expected.same_atom(term));
            let Some(matching) = matching else {
                return Err(effect_diagnostic(
                    format!(
                        "effect upper bound does not contain {}",
                        display_effect(term)
                    ),
                    origin.clone(),
                ));
            };
            let mut one = Self(vec![matching.clone()]);
            one.union(&Self(vec![term.clone()]), inference, origin)?;
        }
        Ok(())
    }

    pub(super) fn validate_handled_identities(
        &self,
        inference: &TypeInference,
        origin: &CheckOrigin,
    ) -> Result<(), CheckDiagnostic> {
        let mut rows = vec![self];
        while let Some(row) = rows.pop() {
            for term in &row.0 {
                match term {
                    EffectTerm::Handled(_, arguments) => {
                        for ty in arguments {
                            let mut pending = vec![inference.resolve(ty)];
                            while let Some(ty) = pending.pop() {
                                match ty {
                                    CheckedType::Formal(_)
                                    | CheckedType::Infer(_)
                                    | CheckedType::Projection(_) => {
                                        return Err(effect_diagnostic(
                                            "handled-effect runtime identity requires closed type arguments",
                                            origin.clone(),
                                        ));
                                    }
                                    CheckedType::Nominal(nominal) => {
                                        pending.extend(nominal.arguments)
                                    }
                                    CheckedType::Tuple(elements) => pending.extend(elements),
                                    _ => {}
                                }
                            }
                        }
                    }
                    EffectTerm::Method { effects, .. } => rows.extend(effects),
                    _ => {}
                }
            }
        }
        Ok(())
    }
}

pub(super) fn effect_diagnostic(
    message: impl Into<String>,
    origin: CheckOrigin,
) -> CheckDiagnostic {
    CheckDiagnostic {
        kind: CheckDiagnosticKind::TypeMismatch,
        message: message.into(),
        primary: Some(origin),
        related: Vec::new(),
    }
}

fn display_effect(term: &EffectTerm) -> String {
    match term {
        EffectTerm::System(effect) => match effect {
            SystemEffect::Console => "console",
            SystemEffect::Fs => "fs",
            SystemEffect::Process => "process",
        }
        .to_owned(),
        EffectTerm::Handled(effect, _) => effect.name.clone(),
        EffectTerm::Fail(payload) => format!("fail<{}>", display_type(payload)),
        EffectTerm::Mut => "mut".to_owned(),
        EffectTerm::Unsafe => "unsafe".to_owned(),
        EffectTerm::Formal(formal) => {
            format!("effect formal {}::{}", formal.owner.name, formal.ordinal)
        }
        EffectTerm::Method { method, .. } => format!("method scheme {}", method.name),
        EffectTerm::Variable(variable) => format!("?effect{variable}"),
        EffectTerm::Destruction(ty) => format!("full_destruction({})", display_type(ty)),
        EffectTerm::SelectedCall(ty) => format!("selected_call({})", display_type(ty)),
    }
}

impl SourceTypeNormalizer<'_> {
    pub(super) fn signature_effect(&self, header: &FunctionHeader) -> EffectRow {
        if let Some(upper) = &header.effect_upper {
            return upper.clone();
        }
        let owner = self.project.entities[&header.identity]
            .owner
            .as_ref()
            .expect("trait method owner");
        let definition = &self.selection.traits[owner];
        let types = std::iter::once(&definition.self_formal)
            .chain(&definition.formals)
            .chain(&header.declared_formals)
            .cloned()
            .map(|formal| CheckedType::Formal(Box::new(formal)))
            .collect();
        EffectRow(vec![EffectTerm::Method {
            method: header.identity.clone(),
            types,
            effects: header
                .effect_formals
                .iter()
                .cloned()
                .map(|formal| EffectRow(vec![EffectTerm::Formal(formal)]))
                .collect(),
        }])
    }
    pub(super) fn normalize_effects(
        &mut self,
        effects: &ResolvedEffectSet,
        formals: &BTreeMap<EntityId, TypeFormal>,
        effect_formals: &BTreeMap<EntityId, EffectFormal>,
    ) -> Result<EffectRow, CheckDiagnostic> {
        let mut pending = effects
            .effects
            .iter()
            .rev()
            .map(|effect| {
                (
                    effect.clone(),
                    formals.clone(),
                    BTreeMap::<TypeFormal, CheckedType>::new(),
                )
            })
            .collect::<Vec<_>>();
        let mut row = EffectRow::default();
        let mut work = 0_usize;
        while let Some((effect, environment, mapping)) = pending.pop() {
            work += 1;
            let origin = CheckOrigin::Source(reference_origin(&effect.reference).clone());
            if work > SELECTION_WORK_LIMIT {
                return Err(effect_diagnostic(
                    format!(
                        "effect expansion incomplete: logical work limit {SELECTION_WORK_LIMIT} exceeded"
                    ),
                    origin,
                ));
            }
            let ResolvedReference::Exact { target, .. } = &effect.reference else {
                unreachable!("Resolver freezes effect references")
            };
            let types = effect
                .arguments
                .iter()
                .map(|ty| {
                    self.normalize_with_formals(ty, &environment)
                        .map(|ty| instantiate_type(&ty, &mapping))
                })
                .collect::<Result<Vec<_>, _>>()?;
            let term = match target.kind {
                EntityKind::EffectParameter => {
                    let formal = effect_formals.get(target).ok_or_else(|| {
                        effect_diagnostic(
                            "effect formal is outside this callable owner",
                            origin.clone(),
                        )
                    })?;
                    EffectTerm::Formal(formal.clone())
                }
                EntityKind::LanguageEffect => match target.name.as_str() {
                    "console" if types.is_empty() => EffectTerm::System(SystemEffect::Console),
                    "fs" if types.is_empty() => EffectTerm::System(SystemEffect::Fs),
                    "process" if types.is_empty() => EffectTerm::System(SystemEffect::Process),
                    "mut" if types.is_empty() => EffectTerm::Mut,
                    "unsafe" if types.is_empty() => EffectTerm::Unsafe,
                    "fail" if types.len() == 1 => EffectTerm::Fail(types[0].clone()),
                    _ => {
                        return Err(effect_diagnostic(
                            "language effect has invalid type argument arity",
                            origin,
                        ));
                    }
                },
                EntityKind::Effect => {
                    if self.arities[target] != types.len() {
                        return Err(effect_diagnostic(
                            "handled effect argument arity does not match its declaration",
                            origin,
                        ));
                    }
                    EffectTerm::Handled(target.clone(), types)
                }
                EntityKind::EffectAlias => {
                    let declaration = self
                        .project
                        .modules
                        .values()
                        .filter_map(|module| module.body.as_ref())
                        .flat_map(|body| &body.declarations)
                        .find(|declaration| declaration.identity.as_ref() == Some(target))
                        .expect("reachable effect alias");
                    let ResolvedDeclarationKind::EffectAlias {
                        type_parameters,
                        effects,
                    } = &declaration.kind
                    else {
                        unreachable!("effect alias kind")
                    };
                    if types.len() != type_parameters.len() {
                        return Err(effect_diagnostic(
                            "effect alias argument arity does not match its declaration",
                            origin,
                        ));
                    }
                    let environment = self.owner_formals[target].clone();
                    let mapping = type_parameters
                        .iter()
                        .map(|parameter| environment[&parameter.binding.identity].clone())
                        .zip(types)
                        .collect::<BTreeMap<_, _>>();
                    pending.extend(
                        effects
                            .effects
                            .iter()
                            .rev()
                            .map(|effect| (effect.clone(), environment.clone(), mapping.clone())),
                    );
                    continue;
                }
                EntityKind::Method => {
                    let rows = effect
                        .effect_arguments
                        .iter()
                        .map(|argument| {
                            self.normalize_effects(&argument.effects, &environment, effect_formals)
                                .map(|row| row.instantiate(&mapping, &BTreeMap::new()))
                        })
                        .collect::<Result<Vec<_>, _>>()?;
                    EffectTerm::Method {
                        method: target.clone(),
                        types,
                        effects: rows,
                    }
                }
                _ => {
                    return Err(effect_diagnostic(
                        "effect input does not name a supported effect or exact method scheme",
                        origin,
                    ));
                }
            };
            row.0.push(term);
        }
        Ok(row)
    }
}
