use super::*;

impl BodyChecker<'_, '_> {
    pub(super) fn method_draft(
        &mut self,
        origin: OriginRef,
        receiver: Option<TypedExpr>,
        subject: CheckedType,
        member: ResolvedSelection,
        arguments: &[ResolvedCallArgument],
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let mut typed = Vec::new();
        for argument in arguments {
            let ResolvedCallArgument::Expression(argument) = argument else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "call-site resource assertions remain unsupported",
                    origin,
                    Vec::new(),
                ));
            };
            typed.push(self.check_expr(argument)?);
        }
        Ok(TypedExpr {
            span: origin.span,
            ty: self.inference.fresh(),
            kind: TypedExprKind::MethodDraft {
                receiver: receiver.map(Box::new),
                subject,
                member,
                arguments: typed,
            },
        })
    }
}

pub(super) struct CallBinder<'a, 'project> {
    pub(super) headers: &'a BTreeMap<EntityId, FunctionHeader>,
    pub(super) schemes: &'a BTreeMap<EntityId, CallableScheme>,
    pub(super) group: &'a BTreeSet<EntityId>,
    pub(super) function: &'a FunctionHeader,
    pub(super) normalizer: &'a SourceTypeNormalizer<'project>,
    pub(super) inference: &'a mut TypeInference,
    pub(super) changed: bool,
    pub(super) pending: Option<OriginRef>,
    pub(super) dependencies: BTreeSet<EntityId>,
}

impl CallBinder<'_, '_> {
    pub(super) fn block(&mut self, block: &mut TypedBlock) -> Result<(), CheckDiagnostic> {
        let mut continues = true;
        for statement in &mut block.statements {
            match &mut statement.kind {
                TypedStatementKind::Let { value, .. } | TypedStatementKind::Expression(value) => {
                    self.expression(value)?;
                    continues &= self.inference.resolve(&value.ty) != CheckedType::Never;
                }
                TypedStatementKind::Return(value) => {
                    if let Some(value) = value {
                        self.expression(value)?;
                    }
                    let actual = value
                        .as_ref()
                        .map_or(CheckedType::Unit, |value| value.ty.clone());
                    self.inference
                        .satisfy(&actual, &self.function.return_type)
                        .map_err(|failure| {
                            source_diagnostic(
                                CheckDiagnosticKind::ReturnMismatch,
                                display_unification_failure(&failure),
                                self.function.context.origin(statement.span),
                                vec![self.function.origin.clone()],
                            )
                        })?;
                    continues = false;
                }
            }
        }
        if let Some(tail) = &mut block.tail {
            self.expression(tail)?;
        }
        block.ty = if continues {
            block
                .tail
                .as_ref()
                .map_or(CheckedType::Unit, |tail| tail.ty.clone())
        } else {
            CheckedType::Never
        };
        Ok(())
    }

    pub(super) fn expression(&mut self, expression: &mut TypedExpr) -> Result<(), CheckDiagnostic> {
        if let TypedExprKind::MethodDraft {
            receiver,
            subject,
            member,
            arguments,
        } = &mut expression.kind
        {
            if let Some(receiver) = receiver {
                self.expression(receiver)?;
            }
            for argument in arguments.iter_mut() {
                self.expression(argument)?;
            }
            let subject = self.inference.receiver_type(subject);
            if matches!(subject, CheckedType::Infer(_)) {
                self.pending = Some(member.origin.clone());
                return Ok(());
            }
            let (selected, mapping) =
                self.normalizer
                    .select_method(&subject, member, self.function)?;
            let header = self.headers.get(&selected).ok_or_else(|| {
                source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "selected method uses unsupported input or resource types",
                    member.origin.clone(),
                    entity_origin(&selected).into_iter().collect(),
                )
            })?;
            if header
                .parameters
                .first()
                .is_some_and(|parameter| parameter.binding.name == "self")
                != receiver.is_some()
            {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::CallMismatch,
                    "instance method and associated function receiver forms do not match",
                    member.origin.clone(),
                    vec![header.origin.clone()],
                ));
            }
            let mut actuals = Vec::new();
            if let Some(receiver) = receiver.take() {
                actuals.push(*receiver);
            }
            actuals.append(arguments);
            expression.kind = TypedExprKind::Call {
                callee: Box::new(selected),
                arguments: actuals,
                parameter_modes: Vec::new(),
                instantiation: CallInstantiation::Pending(mapping),
                evidence: Vec::new(),
                return_type: expression.ty.clone(),
                effect: None,
            };
            self.changed = true;
        }
        match &mut expression.kind {
            TypedExprKind::FunctionValue(value) => {
                self.bind_function_value(value, &mut expression.ty, expression.span)?
            }
            TypedExprKind::Indirect(call) => {
                self.bind_indirect(call, &mut expression.ty, expression.span)?
            }
            TypedExprKind::Parenthesized(inner) => {
                self.expression(inner)?;
                expression.ty = inner.ty.clone();
            }
            TypedExprKind::Tuple(elements) => {
                for element in elements.iter_mut() {
                    self.expression(element)?;
                }
                if elements
                    .iter()
                    .any(|element| self.inference.resolve(&element.ty) == CheckedType::Never)
                {
                    expression.ty = CheckedType::Never;
                }
            }
            TypedExprKind::Construct(construction) => {
                for field in &mut construction.fields {
                    self.expression(&mut field.value)?;
                }
                if construction
                    .fields
                    .iter()
                    .any(|field| self.inference.resolve(&field.value.ty) == CheckedType::Never)
                {
                    expression.ty = CheckedType::Never;
                }
            }
            TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
                self.block(block)?;
                expression.ty = block.ty.clone();
            }
            TypedExprKind::Operation(operation) => {
                for argument in &mut operation.arguments {
                    self.expression(argument)?;
                }
                if let Some(header) = self.normalizer.operations.get(&operation.operation) {
                    let mapping = operation
                        .mapping
                        .types
                        .iter()
                        .map(|(formal, ty)| (formal.clone(), self.inference.canonical(ty)))
                        .collect();
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
                        CheckOrigin::Source(self.function.context.origin(expression.span)),
                    )?;
                    for requirement in &header.requirements {
                        solver.prove(&requirement.instantiate(&mapping))?;
                    }
                    operation.evidence = solver.evidence;
                }
                if operation
                    .arguments
                    .iter()
                    .any(|argument| self.inference.resolve(&argument.ty) == CheckedType::Never)
                {
                    expression.ty = CheckedType::Never;
                }
            }
            TypedExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => {
                self.expression(condition)?;
                self.block(then_branch)?;
                if let Some(branch) = else_branch {
                    self.expression(branch)?;
                }
                if self.inference.resolve(&condition.ty) == CheckedType::Never
                    || self.inference.resolve(&then_branch.ty) == CheckedType::Never
                        && else_branch.as_ref().is_some_and(|branch| {
                            self.inference.resolve(&branch.ty) == CheckedType::Never
                        })
                {
                    expression.ty = CheckedType::Never;
                }
            }
            TypedExprKind::Unary { operand, .. } => {
                self.expression(operand)?;
                if self.inference.resolve(&operand.ty) == CheckedType::Never {
                    expression.ty = CheckedType::Never;
                }
            }
            TypedExprKind::Binary {
                operator,
                left,
                right,
                ..
            } => {
                self.expression(left)?;
                self.expression(right)?;
                if self.inference.resolve(&left.ty) == CheckedType::Never
                    || !matches!(operator, BinaryOperator::LogicAnd | BinaryOperator::LogicOr)
                        && self.inference.resolve(&right.ty) == CheckedType::Never
                {
                    expression.ty = CheckedType::Never;
                }
            }
            TypedExprKind::Call {
                callee,
                arguments,
                instantiation,
                evidence,
                return_type,
                ..
            } => {
                for argument in arguments.iter_mut() {
                    self.expression(argument)?;
                }
                let CallInstantiation::Pending(owner_mapping) = instantiation else {
                    return Ok(());
                };
                if !self.group.contains(callee.as_ref())
                    && !self.schemes.contains_key(callee.as_ref())
                {
                    self.pending = Some(self.function.context.origin(expression.span));
                    return Ok(());
                }
                let header = &self.headers[callee.as_ref()];
                if header.parameters.len() != arguments.len() {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::CallMismatch,
                        "selected method receiver or argument count does not match its signature",
                        self.function.context.origin(expression.span),
                        vec![header.origin.clone()],
                    ));
                }
                let (parameters, result, mapping, requirements) =
                    if self.group.contains(callee.as_ref()) {
                        for (formal, actual) in owner_mapping.iter() {
                            self.inference
                                .unify(&CheckedType::Formal(Box::new(formal.clone())), actual)
                                .map_err(|failure| {
                                    source_diagnostic(
                                        CheckDiagnosticKind::CallMismatch,
                                        format!(
                                            "recursive method changes its owner domain: {}",
                                            display_unification_failure(&failure)
                                        ),
                                        self.function.context.origin(expression.span),
                                        vec![header.origin.clone()],
                                    )
                                })?;
                        }
                        (
                            header
                                .parameters
                                .iter()
                                .map(|parameter| parameter.ty.clone())
                                .collect::<Vec<_>>(),
                            header.return_type.clone(),
                            None,
                            &header.requirements,
                        )
                    } else {
                        let scheme = &self.schemes[callee.as_ref()];
                        let mapping = scheme
                            .quantified
                            .iter()
                            .filter(|formal| scheme.instantiation_formals.contains(*formal))
                            .cloned()
                            .map(|formal| {
                                let actual = owner_mapping
                                    .entry(formal.clone())
                                    .or_insert_with(|| self.inference.fresh())
                                    .clone();
                                (formal, actual)
                            })
                            .collect::<BTreeMap<_, _>>();
                        (
                            scheme
                                .parameters
                                .iter()
                                .map(|parameter| instantiate_type(parameter, &mapping))
                                .collect(),
                            instantiate_type(&scheme.return_type, &mapping),
                            Some(mapping),
                            &scheme.requirements,
                        )
                    };
                for (index, (argument, parameter)) in arguments.iter().zip(&parameters).enumerate()
                {
                    if !has_projection(parameter) {
                        self.inference
                            .satisfy(&argument.ty, parameter)
                            .map_err(|failure| {
                                source_diagnostic(
                                    CheckDiagnosticKind::CallMismatch,
                                    format!(
                                        "argument {index}: {}",
                                        display_unification_failure(&failure)
                                    ),
                                    self.function.context.origin(argument.span),
                                    vec![header.origin.clone()],
                                )
                            })?;
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
                    CheckOrigin::Source(self.function.context.origin(expression.span)),
                )?;
                for (index, (argument, parameter)) in arguments.iter().zip(&parameters).enumerate()
                {
                    if has_projection(parameter) {
                        let parameter = solver.normalize(&self.inference.canonical(parameter))?;
                        let actual = solver.normalize(&self.inference.canonical(&argument.ty))?;
                        self.inference
                            .satisfy(&actual, &parameter)
                            .map_err(|failure| {
                                source_diagnostic(
                                    CheckDiagnosticKind::CallMismatch,
                                    format!(
                                        "argument {index}: {}",
                                        display_unification_failure(&failure)
                                    ),
                                    self.function.context.origin(argument.span),
                                    vec![header.origin.clone()],
                                )
                            })?;
                    }
                }
                if !has_projection(&result) {
                    self.inference
                        .satisfy(&result, return_type)
                        .map_err(|failure| {
                            source_diagnostic(
                                CheckDiagnosticKind::CallMismatch,
                                format!("call result: {}", display_unification_failure(&failure)),
                                self.function.context.origin(expression.span),
                                vec![header.origin.clone()],
                            )
                        })?;
                }
                let substitutions = mapping
                    .as_ref()
                    .map(|mapping| {
                        mapping
                            .iter()
                            .map(|(formal, ty)| (formal.clone(), self.inference.canonical(ty)))
                            .collect()
                    })
                    .unwrap_or_default();
                let shape_requirements = if self.group.contains(callee.as_ref()) {
                    header.shapes.clone()
                } else {
                    self.schemes[callee.as_ref()].shapes.clone()
                };
                let effect_formals = header.effect_formals.clone();
                let Some(callback_actuals) = self.callback_actuals(
                    &shape_requirements,
                    &substitutions,
                    &effect_formals,
                    &CheckOrigin::Source(self.function.context.origin(expression.span)),
                )?
                else {
                    return Ok(());
                };
                for requirement in requirements {
                    solver.prove(
                        &requirement
                            .instantiate(&substitutions)
                            .map_types(|ty| self.inference.canonical(ty)),
                    )?;
                }
                let result = solver.normalize(&self.inference.resolve(&result))?;
                self.inference
                    .satisfy(&result, return_type)
                    .map_err(|failure| {
                        source_diagnostic(
                            CheckDiagnosticKind::CallMismatch,
                            format!("call result: {}", display_unification_failure(&failure)),
                            self.function.context.origin(expression.span),
                            vec![header.origin.clone()],
                        )
                    })?;
                *return_type = result;
                expression.ty = if arguments
                    .iter()
                    .any(|argument| self.inference.resolve(&argument.ty) == CheckedType::Never)
                {
                    CheckedType::Never
                } else {
                    return_type.clone()
                };
                *instantiation = if let Some(mapping) = mapping {
                    CallInstantiation::Published(CallMapping {
                        types: mapping.into_iter().collect(),
                        effects: callback_actuals.effects.into_iter().collect(),
                    })
                } else {
                    CallInstantiation::RecursiveBinding {
                        effects: callback_actuals.effects.into_iter().collect(),
                    }
                };
                append_evidence(&mut solver.evidence, callback_actuals.evidence);
                *evidence = solver.evidence;
                self.changed = true;
            }
            TypedExprKind::TupleField { receiver, .. } | TypedExprKind::Field { receiver, .. } => {
                self.expression(receiver)?;
                if self.inference.resolve(&receiver.ty) == CheckedType::Never {
                    expression.ty = CheckedType::Never;
                }
            }
            TypedExprKind::Integer { .. }
            | TypedExprKind::Float(_)
            | TypedExprKind::Boolean(_)
            | TypedExprKind::Unit
            | TypedExprKind::Reference { .. } => {}
            TypedExprKind::MethodDraft { .. } => {
                unreachable!("method drafts are selected before binding their call")
            }
        }
        Ok(())
    }
}

pub(super) fn call_dependencies(block: &TypedBlock) -> BTreeSet<EntityId> {
    fn block_expressions<'a>(block: &'a TypedBlock, pending: &mut Vec<&'a TypedExpr>) {
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
    block_expressions(block, &mut pending);
    let mut calls = BTreeSet::new();
    while let Some(expression) = pending.pop() {
        match &expression.kind {
            TypedExprKind::FunctionValue(value) => {
                calls.insert(value.function.clone());
            }
            TypedExprKind::Indirect(call) => {
                pending.push(&call.callable);
                pending.extend(&call.arguments);
            }
            TypedExprKind::Call {
                callee, arguments, ..
            } => {
                calls.insert(callee.as_ref().clone());
                pending.extend(arguments);
            }
            TypedExprKind::MethodDraft {
                receiver,
                arguments,
                ..
            } => {
                pending.extend(receiver.as_deref());
                pending.extend(arguments);
            }
            TypedExprKind::Parenthesized(inner)
            | TypedExprKind::Unary { operand: inner, .. }
            | TypedExprKind::Field {
                receiver: inner, ..
            }
            | TypedExprKind::TupleField {
                receiver: inner, ..
            } => pending.push(inner),
            TypedExprKind::Tuple(elements) => pending.extend(elements),
            TypedExprKind::Construct(construction) => {
                pending.extend(construction.fields.iter().map(|field| &field.value))
            }
            TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
                block_expressions(block, &mut pending)
            }
            TypedExprKind::Operation(operation) => pending.extend(&operation.arguments),
            TypedExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => {
                pending.push(condition);
                block_expressions(then_branch, &mut pending);
                pending.extend(else_branch.as_deref());
            }
            TypedExprKind::Binary { left, right, .. } => {
                pending.push(left);
                pending.push(right);
            }
            _ => {}
        }
    }
    calls
}

pub(super) fn has_projection(ty: &CheckedType) -> bool {
    let mut pending = vec![ty];
    while let Some(ty) = pending.pop() {
        match ty {
            CheckedType::Projection(_) => return true,
            CheckedType::Tuple(elements) => pending.extend(elements),
            CheckedType::Nominal(nominal) => pending.extend(&nominal.arguments),
            _ => {}
        }
    }
    false
}
