use super::*;
use crate::project::{
    ResolvedGenericBound, ResolvedImpl, ResolvedImplMemberKind, ResolvedShape, ResolvedShapeKind,
    ResolvedTraitMemberKind, ResolvedTypeParameter,
};

// Declaration legality is consumed once for every retained declaration. The
// source view is still available here, before alias/projection erasure can hide
// an inaccessible name. EffectScope carries the actual declaration domain.
impl SourceTypeNormalizer<'_> {
    pub(super) fn validate_declarations(
        &self,
        headers: &BTreeMap<EntityId, FunctionHeader>,
        schemes: &BTreeMap<EntityId, CallableScheme>,
        exports: &BTreeSet<EntityId>,
        inference: &mut TypeInference,
    ) -> Result<(), CheckDiagnostic> {
        self.validate_source_surfaces(headers, exports)?;
        self.validate_declaration_formations(headers, inference)?;
        let mut surfaces = Vec::new();
        let mut conditions = Vec::new();
        for (identity, nominal) in &self.nominals {
            if !exports.contains(identity) {
                continue;
            }
            conditions.push((
                &nominal.requirements,
                entity_origin(identity).expect("nominal source"),
            ));
            for fields in nominal.constructors.values() {
                for field in &fields.fields {
                    if identity.kind == EntityKind::Enum
                        || self.project.entities[&field.identity].public
                    {
                        surfaces.push((
                            field.ty.clone(),
                            nominal.requirements.clone(),
                            field.origin.clone(),
                        ));
                    }
                }
            }
        }
        for (identity, ty) in &self.normalized_aliases {
            if exports.contains(identity) {
                surfaces.push((
                    ty.clone(),
                    Vec::new(),
                    entity_origin(identity).expect("source alias"),
                ));
            }
        }
        for implementation in self.selection.implementations.values() {
            let origin = entity_origin(&implementation.identity).expect("impl source");
            let mut solver = SelectionSolver::new(
                &self.selection,
                &self.project.core_roles,
                &implementation.requirements,
                CheckOrigin::Source(origin.clone()),
                inference,
            )?;
            let target = solver.normalize(&implementation.target)?;
            if validate_public_nominals(&target, exports, &origin).is_err() {
                continue;
            }
            let public_impl = implementation
                .trait_use
                .as_ref()
                .is_some_and(|bound| exports.contains(&bound.declaration));
            if public_impl
                || implementation
                    .methods
                    .values()
                    .chain(implementation.associated.keys())
                    .any(|member| self.project.entities[member].public)
            {
                conditions.push((&implementation.requirements, origin.clone()));
            }
            for (member, ty) in &implementation.associated {
                if public_impl || self.project.entities[member].public {
                    surfaces.push((
                        ty.clone(),
                        implementation.requirements.clone(),
                        origin.clone(),
                    ));
                }
            }
            if let Some(bound) = &implementation.trait_use
                && public_impl
            {
                for ty in std::iter::once(&implementation.target)
                    .chain(&bound.arguments)
                    .chain(bound.associated.values())
                {
                    surfaces.push((
                        ty.clone(),
                        implementation.requirements.clone(),
                        origin.clone(),
                    ));
                }
            }
        }
        for header in headers.values().filter(|header| header.public_export) {
            conditions.push((&header.requirements, header.origin.clone()));
            for ty in header.interface_types() {
                surfaces.push((
                    ty.clone(),
                    header.requirements.clone(),
                    header.origin.clone(),
                ));
            }
        }
        for (identity, definition) in &self.selection.traits {
            if !exports.contains(identity) {
                continue;
            }
            let origin = entity_origin(identity).expect("trait source");
            conditions.push((&definition.requirements, origin.clone()));
            let mut requirements = definition.requirements.clone();
            requirements.push(Requirement {
                subject: CheckedType::Formal(Box::new(definition.self_formal.clone())),
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
                origin: CheckOrigin::Source(origin.clone()),
            });
            for associated in definition.associated.values() {
                for bound in &associated.bounds {
                    if !exports.contains(&bound.declaration) {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            "public associated bound exposes a private trait",
                            origin.clone(),
                            entity_origin(&bound.declaration).into_iter().collect(),
                        ));
                    }
                }
                for ty in associated.default.iter().chain(
                    associated
                        .bounds
                        .iter()
                        .flat_map(|bound| bound.arguments.iter().chain(bound.associated.values())),
                ) {
                    surfaces.push((ty.clone(), requirements.clone(), origin.clone()));
                }
            }
        }
        for (identity, requirements) in &self.effect_requirements {
            if exports.contains(identity) {
                conditions.push((
                    requirements,
                    entity_origin(identity).expect("effect source"),
                ));
            }
        }
        for (identity, operation) in &self.operations {
            if exports.contains(&operation.owner) {
                for ty in operation
                    .parameters
                    .iter()
                    .map(|(ty, _)| ty)
                    .chain(std::iter::once(&operation.return_type))
                {
                    surfaces.push((
                        ty.clone(),
                        self.effect_requirements[&operation.owner].clone(),
                        entity_origin(identity).expect("operation source"),
                    ));
                }
            }
        }
        for (requirements, origin) in conditions {
            for requirement in requirements {
                if !exports.contains(&requirement.bound.declaration) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "public bound exposes a private trait",
                        origin.clone(),
                        entity_origin(&requirement.bound.declaration)
                            .into_iter()
                            .collect(),
                    ));
                }
                for ty in std::iter::once(&requirement.subject)
                    .chain(&requirement.bound.arguments)
                    .chain(requirement.bound.associated.values())
                {
                    surfaces.push((ty.clone(), requirements.clone(), origin.clone()));
                }
            }
        }
        for use_site in &self.effect_uses {
            if use_site.scope.as_ref().is_some_and(|scope| {
                exports.contains(scope)
                    || headers
                        .get(scope)
                        .is_some_and(|header| header.public_export)
            }) {
                if !exports.contains(&use_site.declaration) {
                    return Err(effect_diagnostic(
                        "public effect surface references a private declaration",
                        use_site.origin.clone(),
                    ));
                }
                let requirements = use_site
                    .scope
                    .as_ref()
                    .and_then(|scope| {
                        headers
                            .get(scope)
                            .map(|header| header.requirements.clone())
                            .or_else(|| self.effect_requirements.get(scope).cloned())
                    })
                    .unwrap_or_default();
                for ty in &use_site.types {
                    surfaces.push((
                        ty.clone(),
                        requirements.clone(),
                        origin_as_source(
                            &use_site.origin,
                            &self.project.modules[&use_site.declaration.module]
                                .body
                                .as_ref()
                                .expect("source module")
                                .origin,
                        ),
                    ));
                }
            }
        }
        for (ty, requirements, origin) in surfaces {
            let mut solver = SelectionSolver::new(
                &self.selection,
                &self.project.core_roles,
                &requirements,
                CheckOrigin::Source(origin.clone()),
                inference,
            )?;
            let ty = solver.normalize(&ty)?;
            validate_public_nominals(&ty, exports, &origin)?;
        }
        self.validate_declaration_rows(headers, schemes, exports, inference)
    }

    fn validate_declaration_rows(
        &self,
        headers: &BTreeMap<EntityId, FunctionHeader>,
        schemes: &BTreeMap<EntityId, CallableScheme>,
        exports: &BTreeSet<EntityId>,
        inference: &mut TypeInference,
    ) -> Result<(), CheckDiagnostic> {
        let environment = EffectEnvironment {
            normalizer: self,
            headers,
            schemes,
        };
        let rows = schemes
            .iter()
            .map(|(identity, scheme)| (identity.clone(), scheme.effect.clone()))
            .collect();
        let validate = |row: &EffectRow,
                        scope: &EffectScope,
                        runtime: bool,
                        public: bool,
                        inference: &mut TypeInference|
         -> Result<(), CheckDiagnostic> {
            let mut pending = vec![row];
            let mut work = 0;
            while let Some(row) = pending.pop() {
                work += row.0.len() + 1;
                if work > SELECTION_WORK_LIMIT {
                    return Err(effect_diagnostic(
                        "declaration row proof incomplete: deterministic work limit reached",
                        scope.origin.clone(),
                    ));
                }
                for term in &row.0 {
                    if let EffectTerm::Method { effects, .. } = term {
                        pending.extend(effects);
                    }
                }
                let mut needed = BTreeSet::new();
                let expanded =
                    environment.expand_scope(row, scope, &rows, inference, &mut needed)?;
                if !needed.is_empty() {
                    return Err(effect_diagnostic(
                        "declaration row retains an unproved concrete application",
                        scope.origin.clone(),
                    ));
                }
                if runtime {
                    expanded.validate_handled_identities(inference, &scope.origin)?;
                }
                if public {
                    self.validate_effect_visibility(
                        row,
                        exports,
                        &origin_as_source(
                            &scope.origin,
                            &self.project.modules[&ModuleRef::root(self.project.entry)]
                                .body
                                .as_ref()
                                .expect("entry source")
                                .origin,
                        ),
                    )?;
                    self.validate_effect_visibility(
                        &expanded,
                        exports,
                        &origin_as_source(
                            &scope.origin,
                            &self.project.modules[&ModuleRef::root(self.project.entry)]
                                .body
                                .as_ref()
                                .expect("entry source")
                                .origin,
                        ),
                    )?;
                    for ty in expanded.types() {
                        validate_public_nominals(
                            ty,
                            exports,
                            &origin_as_source(
                                &scope.origin,
                                &self.project.modules[&ModuleRef::root(self.project.entry)]
                                    .body
                                    .as_ref()
                                    .expect("entry source")
                                    .origin,
                            ),
                        )?;
                    }
                }
            }
            Ok(())
        };
        let core = core_role_declarations(&self.project.core_roles);
        for header in headers.values() {
            if header.body.is_none()
                && self.project.entities[&header.identity]
                    .owner
                    .as_ref()
                    .is_some_and(|owner| core.contains(owner))
            {
                continue;
            }
            let scope = EffectScope::from(header);
            for row in header.effect_upper.iter().chain(&header.trait_upper) {
                validate(row, &scope, true, header.public_export, inference)?;
            }
            for shape in &header.shapes {
                let scope = EffectScope {
                    callable: Some(&header.identity),
                    group: &[],
                    provisional: false,
                    requirements: &header.requirements,
                    shapes: &header.shapes,
                    origin: shape.origin.clone(),
                };
                validate(
                    &shape.shape.effect,
                    &scope,
                    true,
                    header.public_export,
                    inference,
                )?;
            }
            if let Some(scheme) = schemes.get(&header.identity) {
                validate(
                    &scheme.effect,
                    &scope,
                    true,
                    header.public_export,
                    inference,
                )?;
                for row in &scheme.row_constraints {
                    validate(row, &scope, false, false, inference)?;
                }
            }
        }
        for (identity, row) in &self.effect_alias_rows {
            let scope = EffectScope {
                callable: None,
                group: &[],
                provisional: false,
                requirements: &self.effect_requirements[identity],
                shapes: &[],
                origin: CheckOrigin::Source(entity_origin(identity).expect("effect alias")),
            };
            validate(row, &scope, false, exports.contains(identity), inference)?;
        }
        for (row, origin) in self.module_effects.values() {
            let scope = EffectScope {
                callable: None,
                group: &[],
                provisional: false,
                requirements: &[],
                shapes: &[],
                origin: CheckOrigin::Source(origin.clone()),
            };
            validate(row, &scope, true, false, inference)?;
        }
        Ok(())
    }

    fn validate_source_surfaces(
        &self,
        headers: &BTreeMap<EntityId, FunctionHeader>,
        exports: &BTreeSet<EntityId>,
    ) -> Result<(), CheckDiagnostic> {
        let core = core_role_declarations(&self.project.core_roles);
        let visitor = SourceSurfaces {
            normalizer: self,
            exports,
        };
        for module in self.project.modules.values() {
            let Some(body) = &module.body else {
                continue;
            };
            for declaration in &body.declarations {
                let Some(identity) = &declaration.identity else {
                    continue;
                };
                if core.contains(identity) {
                    continue;
                }
                let public = exports.contains(identity);
                let context = SourceContext::from_origin(&declaration.origin);
                match &declaration.kind {
                    ResolvedDeclarationKind::Function(function) => {
                        visitor.function(function, public, &context)?
                    }
                    ResolvedDeclarationKind::Struct {
                        type_parameters,
                        fields,
                    } => {
                        visitor.parameters(type_parameters, public, false, &context)?;
                        for field in fields {
                            visitor.ty(&field.ty, public && field.public)?;
                        }
                    }
                    ResolvedDeclarationKind::Enum {
                        type_parameters,
                        variants,
                    } => {
                        visitor.parameters(type_parameters, public, false, &context)?;
                        for variant in variants {
                            match &variant.fields {
                                ResolvedVariantFields::Unit => {}
                                ResolvedVariantFields::Positional(fields) => {
                                    for ty in fields {
                                        visitor.ty(ty, public)?;
                                    }
                                }
                                ResolvedVariantFields::Named(fields) => {
                                    for field in fields {
                                        visitor.ty(&field.ty, public)?;
                                    }
                                }
                            }
                        }
                    }
                    ResolvedDeclarationKind::Trait {
                        type_parameters,
                        supertraits,
                        members,
                    } => {
                        visitor.parameters(type_parameters, public, false, &context)?;
                        for bound in supertraits {
                            visitor.named(bound, public)?;
                        }
                        for member in members {
                            match &member.kind {
                                ResolvedTraitMemberKind::AssociatedType { bounds, default } => {
                                    for bound in bounds {
                                        visitor.named(bound, public)?;
                                    }
                                    if let Some(ty) = default {
                                        visitor.ty(ty, public)?;
                                    }
                                }
                                ResolvedTraitMemberKind::Method(signature) => {
                                    visitor.parameters(
                                        &signature.type_parameters,
                                        public,
                                        true,
                                        &context,
                                    )?;
                                    visitor.inputs(&signature.parameters, public, &context)?;
                                    if let Some(ty) = &signature.return_type {
                                        visitor.ty(ty, public)?;
                                    }
                                    if let Some(row) = &signature.effects {
                                        visitor.row(row, public)?;
                                    }
                                }
                            }
                        }
                    }
                    ResolvedDeclarationKind::InherentImpl(_)
                    | ResolvedDeclarationKind::TraitImpl { .. } => {
                        let implementation: &ResolvedImpl = match &declaration.kind {
                            ResolvedDeclarationKind::InherentImpl(implementation) => implementation,
                            ResolvedDeclarationKind::TraitImpl { implementation, .. } => {
                                implementation
                            }
                            _ => unreachable!(),
                        };
                        let typed = &self.selection.implementations[identity];
                        let target_public =
                            validate_public_nominals(&typed.target, exports, &declaration.origin)
                                .is_ok();
                        let public_impl = target_public
                            && typed
                                .trait_use
                                .as_ref()
                                .is_some_and(|bound| exports.contains(&bound.declaration));
                        let public_owner = public_impl
                            || target_public
                                && implementation.members.iter().any(|member| member.public);
                        visitor.parameters(
                            &implementation.type_parameters,
                            public_owner,
                            false,
                            &context,
                        )?;
                        visitor.named(&implementation.target, public_owner)?;
                        if let ResolvedDeclarationKind::TraitImpl {
                            trait_type,
                            where_clause,
                            ..
                        } = &declaration.kind
                        {
                            visitor.named(trait_type, public_impl)?;
                            if let Some(clause) = where_clause {
                                for predicate in &clause.predicates {
                                    visitor.ty(&predicate.subject, public_owner)?;
                                    for bound in &predicate.bounds {
                                        visitor.named(bound, public_owner)?;
                                    }
                                }
                            }
                        }
                        for member in &implementation.members {
                            let public = public_impl || target_public && member.public;
                            match &member.kind {
                                ResolvedImplMemberKind::AssociatedType(ty) => {
                                    visitor.ty(ty, public)?
                                }
                                ResolvedImplMemberKind::Function(function) => visitor.function(
                                    function,
                                    headers
                                        .get(&member.identity)
                                        .is_some_and(|header| header.public_export),
                                    &context,
                                )?,
                            }
                        }
                    }
                    ResolvedDeclarationKind::Effect {
                        type_parameters,
                        operations,
                    } => {
                        visitor.parameters(type_parameters, public, false, &context)?;
                        for operation in operations {
                            visitor.inputs(&operation.parameters, public, &context)?;
                            visitor.ty(&operation.return_type, public)?;
                        }
                    }
                    ResolvedDeclarationKind::EffectAlias {
                        type_parameters,
                        effects,
                    } => {
                        visitor.parameters(type_parameters, public, false, &context)?;
                        visitor.row(effects, public)?;
                    }
                    ResolvedDeclarationKind::TypeAlias { value, .. } => {
                        visitor.ty(value, public)?
                    }
                    _ => {}
                }
            }
        }
        Ok(())
    }
}

struct SourceSurfaces<'a, 'project> {
    normalizer: &'a SourceTypeNormalizer<'project>,
    exports: &'a BTreeSet<EntityId>,
}

impl SourceSurfaces<'_, '_> {
    fn ty(&self, ty: &ResolvedType, public: bool) -> Result<(), CheckDiagnostic> {
        if public {
            validate_public_type_visibility(self.exports, ty, &self.normalizer.aliases)?;
        }
        Ok(())
    }
    fn named(&self, named: &ResolvedNamedType, public: bool) -> Result<(), CheckDiagnostic> {
        if public
            && let ResolvedReference::Exact {
                target, occurrence, ..
            } = &named.reference
            && target.kind == EntityKind::Trait
            && !self.exports.contains(target)
        {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "public bound exposes a private trait",
                occurrence.clone(),
                entity_origin(target).into_iter().collect(),
            ));
        }
        self.ty(
            &ResolvedType {
                span: named.span,
                kind: ResolvedTypeKind::Named(Box::new(named.clone())),
            },
            public,
        )
    }
    fn row(&self, row: &ResolvedEffectSet, public: bool) -> Result<(), CheckDiagnostic> {
        let mut pending = vec![row];
        while let Some(row) = pending.pop() {
            for effect in &row.effects {
                if public
                    && let ResolvedReference::Exact {
                        target, occurrence, ..
                    } = &effect.reference
                {
                    let exposed = if target.kind == EntityKind::Method {
                        self.normalizer.project.entities[target]
                            .owner
                            .as_ref()
                            .unwrap_or(target)
                    } else {
                        target
                    };
                    if matches!(
                        target.kind,
                        EntityKind::Effect | EntityKind::EffectAlias | EntityKind::Method
                    ) && !self.exports.contains(exposed)
                    {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            "public effect source references a private declaration",
                            occurrence.clone(),
                            entity_origin(exposed).into_iter().collect(),
                        ));
                    }
                }
                for ty in &effect.arguments {
                    self.ty(ty, public)?;
                }
                pending.extend(
                    effect
                        .effect_arguments
                        .iter()
                        .map(|argument| &argument.effects),
                );
            }
        }
        Ok(())
    }
    fn parameters(
        &self,
        parameters: &[ResolvedTypeParameter],
        public: bool,
        callable: bool,
        context: &SourceContext,
    ) -> Result<(), CheckDiagnostic> {
        for parameter in parameters {
            for bound in &parameter.bounds {
                match bound {
                    ResolvedGenericBound::Named(named) => self.named(named, public)?,
                    ResolvedGenericBound::Shape(shape) => {
                        if !callable {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::Unsupported,
                                "callable-shape requirements on a non-callable owner are outside this Checker profile",
                                context.origin(shape.span),
                                Vec::new(),
                            ));
                        }
                        self.shape(shape, public)?;
                    }
                }
            }
        }
        Ok(())
    }
    fn inputs(
        &self,
        parameters: &[crate::project::ResolvedParameter],
        public: bool,
        _context: &SourceContext,
    ) -> Result<(), CheckDiagnostic> {
        for parameter in parameters {
            match &parameter.annotation {
                Some(ResolvedParameterAnnotation::Type(ty)) => self.ty(ty, public)?,
                Some(ResolvedParameterAnnotation::Shape(shape)) => self.shape(shape, public)?,
                None => {}
            }
        }
        Ok(())
    }
    fn shape(&self, shape: &ResolvedShape, public: bool) -> Result<(), CheckDiagnostic> {
        let mut pending = vec![shape];
        while let Some(shape) = pending.pop() {
            match &shape.kind {
                ResolvedShapeKind::Grouped(inner) => pending.push(inner),
                ResolvedShapeKind::Callable {
                    parameters,
                    return_type,
                    effects,
                } => {
                    for parameter in parameters {
                        self.ty(&parameter.ty, public)?;
                    }
                    self.ty(return_type, public)?;
                    if let Some(row) = effects {
                        self.row(row, public)?;
                    }
                }
            }
        }
        Ok(())
    }
    fn function(
        &self,
        function: &crate::project::ResolvedFunction,
        public: bool,
        context: &SourceContext,
    ) -> Result<(), CheckDiagnostic> {
        self.parameters(&function.type_parameters, public, true, context)?;
        self.inputs(&function.parameters, public, context)?;
        if let Some(result) = &function.return_type {
            match result.as_ref() {
                ResolvedReturnAnnotation::Type(ty) => self.ty(ty, public)?,
                ResolvedReturnAnnotation::Shape(shape) => self.shape(shape, public)?,
            }
        }
        if let Some(row) = &function.effects {
            self.row(row, public)?;
        }
        Ok(())
    }
}
