use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use crate::ast::{BinaryOperator, ParameterMode, Span, UnaryOperator};
use crate::contract;
use crate::contract::ContractDocument;
use crate::project::{
    EntityId, EntityKind, EntitySite, LibraryId, ModuleRef, Namespace, OriginRef,
    ProjectDiagnostic, ProjectDiagnosticKind, ProjectSources, ResolvedBlock, ResolvedCallArgument,
    ResolvedDeclaration, ResolvedDeclarationKind, ResolvedEffectSet, ResolvedExpr,
    ResolvedExprKind, ResolvedNamedType, ResolvedParameterAnnotation, ResolvedProject,
    ResolvedReference, ResolvedReturnAnnotation, ResolvedStatement, ResolvedStatementKind,
    ResolvedType, ResolvedTypeArgument, ResolvedTypeKind, SourceRef, SupertraitTargetKind,
};

/// An owned resolved project whose declaration graph invariants have been checked.
///
/// This type does not represent a fully checked program, effective signatures,
/// alias normalization, or typed HIR. Values can only be constructed by
/// [`crate::prepare_project`].
#[allow(
    dead_code,
    reason = "the opaque preparation state is the complete wrapped resolved project"
)]
pub struct PreparedProject(ResolvedProject);

/// An owned project whose supported source and selected contract inputs have
/// been checked together.
///
/// The result is intentionally opaque. It retains the exact resolved project,
/// normalized types, parameter conventions, pure-effect facts, interpreted
/// literals, exact direct callees, and one typed body for every supported
/// reachable function. It is the first narrow Checker result; it is not the
/// complete 0.1 interface, general-purpose query surface, or final `TypedHIR`.
#[allow(
    dead_code,
    reason = "the opaque checked result retains the complete narrow checker carrier"
)]
pub struct CheckedProject {
    prepared: PreparedProject,
    owners: BTreeMap<String, LibraryId>,
    documents: Vec<ContractDocument>,
    contract_selections: ContractSelections,
    aliases: BTreeMap<EntityId, CheckedType>,
    functions: BTreeMap<EntityId, CheckedFunction>,
}

impl fmt::Debug for CheckedProject {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CheckedProject")
            .field("entry", &self.prepared.0.entry)
            .field("core", &self.prepared.0.core)
            .field("contract_document_count", &self.documents.len())
            .field("selected_owner_count", &self.owners.len())
            .field("checked_alias_count", &self.aliases.len())
            .field("checked_function_count", &self.functions.len())
            .finish_non_exhaustive()
    }
}

/// A real source or contract location attached to a Checker diagnostic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckOrigin {
    Source(OriginRef),
    Contract {
        document_index: usize,
        json_path: String,
    },
}

/// Stable high-level categories for the initial Checker surface.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckDiagnosticKind {
    /// An unchanged failure from the existing project pipeline.
    Project(Box<ProjectDiagnosticKind>),
    /// Valid source or contract syntax outside this Checker's current subset.
    Unsupported,
    /// A source type rule, annotation, alias, condition, operator, or projection failed.
    TypeMismatch,
    /// A supported direct call has the wrong arity or argument type.
    CallMismatch,
    /// A normal or explicit return does not match the declared return type.
    ReturnMismatch,
    /// A contract owner, library edge, path, target, or parameter could not bind exactly.
    ContractBinding,
    /// Two selected contract facts, or a contract fact and source fact, conflict.
    ContractConflict,
    /// A source numeric literal cannot be represented by its language type.
    LiteralOutOfRange,
}

/// One deterministic failure from [`crate::check_project`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckDiagnostic {
    pub kind: CheckDiagnosticKind,
    pub message: String,
    pub primary: Option<CheckOrigin>,
    pub related: Vec<CheckOrigin>,
}

pub(crate) fn prepare_project(
    project: ResolvedProject,
) -> Result<PreparedProject, ProjectDiagnostic> {
    let traits = trait_declarations(&project);
    validate_supertrait_targets(&traits)?;
    validate_declaration_graph(
        &trait_graph(&traits),
        ProjectDiagnosticKind::TraitInheritanceCycle,
    )?;

    let aliases = effect_alias_declarations(&project);
    validate_declaration_graph(
        &effect_alias_graph(&aliases),
        ProjectDiagnosticKind::EffectAliasCycle,
    )?;

    Ok(PreparedProject(project))
}

struct TraitDeclaration<'a> {
    module: &'a ModuleRef,
    declaration: &'a ResolvedDeclaration,
    identity: &'a EntityId,
    supertraits: &'a [ResolvedNamedType],
}

fn trait_declarations(project: &ResolvedProject) -> Vec<TraitDeclaration<'_>> {
    let mut traits = Vec::new();
    for (module, resolved_module) in &project.modules {
        let Some(body) = &resolved_module.body else {
            continue;
        };
        for declaration in &body.declarations {
            let ResolvedDeclarationKind::Trait { supertraits, .. } = &declaration.kind else {
                continue;
            };
            traits.push(TraitDeclaration {
                module,
                declaration,
                identity: declaration
                    .identity
                    .as_ref()
                    .expect("every resolved trait has an exact declaration identity"),
                supertraits,
            });
        }
    }
    traits.sort_by(|left, right| {
        left.module
            .cmp(right.module)
            .then_with(|| {
                left.declaration
                    .origin
                    .span
                    .cmp(&right.declaration.origin.span)
            })
            .then_with(|| left.identity.cmp(right.identity))
    });
    traits
}

fn validate_supertrait_targets(traits: &[TraitDeclaration<'_>]) -> Result<(), ProjectDiagnostic> {
    let mut diagnostics = Vec::new();
    for declaration in traits {
        for supertrait in declaration.supertraits {
            let diagnostic = match &supertrait.reference {
                ResolvedReference::Exact {
                    occurrence, target, ..
                } if target.kind != EntityKind::Trait => Some(ProjectDiagnostic {
                    kind: ProjectDiagnosticKind::InvalidSupertrait {
                        actual: supertrait_target_kind(target),
                    },
                    primary: Some(occurrence.clone()),
                    related: entity_origin(target).into_iter().collect(),
                }),
                ResolvedReference::Selection {
                    occurrence,
                    members,
                    ..
                } => {
                    let known_target = members
                        .last()
                        .and_then(|member| member.declaration.as_ref());
                    Some(ProjectDiagnostic {
                        kind: ProjectDiagnosticKind::InvalidSupertrait {
                            actual: known_target.map_or(
                                SupertraitTargetKind::TypeDependentSelection,
                                supertrait_target_kind,
                            ),
                        },
                        primary: Some(occurrence.clone()),
                        related: known_target.and_then(entity_origin).into_iter().collect(),
                    })
                }
                ResolvedReference::Exact { .. } => None,
            };
            if let Some(diagnostic) = diagnostic {
                diagnostics.push((declaration.module.clone(), diagnostic));
            }
        }
    }

    if let Some((_, diagnostic)) =
        diagnostics
            .into_iter()
            .min_by(|(left_module, left), (right_module, right)| {
                left_module
                    .cmp(right_module)
                    .then_with(|| {
                        left.primary
                            .as_ref()
                            .expect("supertrait diagnostics have a source occurrence")
                            .span
                            .cmp(
                                &right
                                    .primary
                                    .as_ref()
                                    .expect("supertrait diagnostics have a source occurrence")
                                    .span,
                            )
                    })
                    .then_with(|| {
                        supertrait_diagnostic_rank(&left.kind)
                            .cmp(&supertrait_diagnostic_rank(&right.kind))
                    })
            })
    {
        return Err(diagnostic);
    }
    Ok(())
}

fn supertrait_target_kind(target: &EntityId) -> SupertraitTargetKind {
    match target.kind {
        EntityKind::Struct => SupertraitTargetKind::Struct,
        EntityKind::Enum => SupertraitTargetKind::Enum,
        EntityKind::TypeAlias => SupertraitTargetKind::TypeAlias,
        EntityKind::ExternType => SupertraitTargetKind::ExternType,
        EntityKind::TypeParameter => SupertraitTargetKind::TypeParameter,
        EntityKind::SelfType => SupertraitTargetKind::SelfType,
        EntityKind::AssociatedType => SupertraitTargetKind::AssociatedType,
        EntityKind::LanguageType => SupertraitTargetKind::LanguageType,
        EntityKind::Trait => unreachable!("valid trait targets are filtered before diagnostics"),
        _ => unreachable!("the resolver only admits type entities in a supertrait position"),
    }
}

fn supertrait_diagnostic_rank(kind: &ProjectDiagnosticKind) -> u8 {
    let ProjectDiagnosticKind::InvalidSupertrait { actual } = kind else {
        unreachable!("only invalid-supertrait diagnostics are ranked here")
    };
    match actual {
        SupertraitTargetKind::Struct => 0,
        SupertraitTargetKind::Enum => 1,
        SupertraitTargetKind::TypeAlias => 2,
        SupertraitTargetKind::ExternType => 3,
        SupertraitTargetKind::TypeParameter => 4,
        SupertraitTargetKind::SelfType => 5,
        SupertraitTargetKind::AssociatedType => 6,
        SupertraitTargetKind::LanguageType => 7,
        SupertraitTargetKind::TypeDependentSelection => 8,
    }
}

struct EffectAliasDeclaration<'a> {
    module: &'a ModuleRef,
    declaration: &'a ResolvedDeclaration,
    identity: &'a EntityId,
    effects: &'a ResolvedEffectSet,
}

fn effect_alias_declarations(project: &ResolvedProject) -> Vec<EffectAliasDeclaration<'_>> {
    let mut aliases = Vec::new();
    for (module, resolved_module) in &project.modules {
        let Some(body) = &resolved_module.body else {
            continue;
        };
        for declaration in &body.declarations {
            let ResolvedDeclarationKind::EffectAlias { effects, .. } = &declaration.kind else {
                continue;
            };
            aliases.push(EffectAliasDeclaration {
                module,
                declaration,
                identity: declaration
                    .identity
                    .as_ref()
                    .expect("every resolved effect alias has an exact declaration identity"),
                effects,
            });
        }
    }
    aliases.sort_by(|left, right| {
        left.module
            .cmp(right.module)
            .then_with(|| {
                left.declaration
                    .origin
                    .span
                    .cmp(&right.declaration.origin.span)
            })
            .then_with(|| left.identity.cmp(right.identity))
    });
    aliases
}

struct DeclarationGraphNode {
    declaration: OriginRef,
    edges: Vec<DeclarationGraphEdge>,
}

#[derive(Clone)]
struct DeclarationGraphEdge {
    target: usize,
    reference: OriginRef,
}

fn trait_graph(traits: &[TraitDeclaration<'_>]) -> Vec<DeclarationGraphNode> {
    let indices = traits
        .iter()
        .enumerate()
        .map(|(index, declaration)| (declaration.identity.clone(), index))
        .collect::<BTreeMap<_, _>>();
    traits
        .iter()
        .map(|declaration| {
            let mut edges = declaration
                .supertraits
                .iter()
                .map(|supertrait| match &supertrait.reference {
                    ResolvedReference::Exact {
                        occurrence, target, ..
                    } => DeclarationGraphEdge {
                        target: *indices
                            .get(target)
                            .expect("every validated supertrait is a reachable trait declaration"),
                        reference: occurrence.clone(),
                    },
                    ResolvedReference::Selection { .. } => {
                        unreachable!(
                            "type-dependent supertraits were rejected before graph building"
                        )
                    }
                })
                .collect::<Vec<_>>();
            sort_edges(&mut edges);
            DeclarationGraphNode {
                declaration: declaration.declaration.origin.clone(),
                edges,
            }
        })
        .collect()
}

fn effect_alias_graph(aliases: &[EffectAliasDeclaration<'_>]) -> Vec<DeclarationGraphNode> {
    let indices = aliases
        .iter()
        .enumerate()
        .map(|(index, declaration)| (declaration.identity.clone(), index))
        .collect::<BTreeMap<_, _>>();
    aliases
        .iter()
        .map(|declaration| {
            let mut edges = Vec::new();
            collect_effect_alias_edges(declaration.effects, &indices, &mut edges);
            sort_edges(&mut edges);
            DeclarationGraphNode {
                declaration: declaration.declaration.origin.clone(),
                edges,
            }
        })
        .collect()
}

fn collect_effect_alias_edges(
    effects: &ResolvedEffectSet,
    indices: &BTreeMap<EntityId, usize>,
    edges: &mut Vec<DeclarationGraphEdge>,
) {
    for effect in &effects.effects {
        if let ResolvedReference::Exact {
            occurrence, target, ..
        } = &effect.reference
            && target.kind == EntityKind::EffectAlias
        {
            edges.push(DeclarationGraphEdge {
                target: *indices
                    .get(target)
                    .expect("every resolved effect alias reference has a reachable declaration"),
                reference: occurrence.clone(),
            });
        }
        for argument in &effect.effect_arguments {
            collect_effect_alias_edges(&argument.effects, indices, edges);
        }
    }
}

fn sort_edges(edges: &mut [DeclarationGraphEdge]) {
    edges.sort_by(|left, right| {
        left.reference
            .cmp(&right.reference)
            .then_with(|| left.target.cmp(&right.target))
    });
}

struct DeclarationCycle {
    nodes: Vec<usize>,
    edges: Vec<OriginRef>,
}

struct DfsFrame {
    node: usize,
    next_edge: usize,
    incoming: Option<OriginRef>,
}

fn first_declaration_cycle(graph: &[DeclarationGraphNode]) -> Option<DeclarationCycle> {
    let mut state = vec![0_u8; graph.len()];
    let mut active_position = vec![None; graph.len()];

    for root in 0..graph.len() {
        if state[root] != 0 {
            continue;
        }
        state[root] = 1;
        active_position[root] = Some(0);
        let mut stack = vec![DfsFrame {
            node: root,
            next_edge: 0,
            incoming: None,
        }];

        while let Some(frame) = stack.last_mut() {
            let node = frame.node;
            let Some(edge) = graph[node].edges.get(frame.next_edge).cloned() else {
                state[node] = 2;
                active_position[node] = None;
                stack.pop();
                continue;
            };
            frame.next_edge += 1;

            match state[edge.target] {
                0 => {
                    state[edge.target] = 1;
                    active_position[edge.target] = Some(stack.len());
                    stack.push(DfsFrame {
                        node: edge.target,
                        next_edge: 0,
                        incoming: Some(edge.reference),
                    });
                }
                1 => {
                    let start = active_position[edge.target]
                        .expect("active declaration nodes retain their stack position");
                    let mut cycle = DeclarationCycle {
                        nodes: stack[start..].iter().map(|frame| frame.node).collect(),
                        edges: stack[start + 1..]
                            .iter()
                            .map(|frame| {
                                frame
                                    .incoming
                                    .clone()
                                    .expect("non-root DFS frames retain their incoming edge")
                            })
                            .chain(std::iter::once(edge.reference))
                            .collect(),
                    };
                    let first = cycle
                        .nodes
                        .iter()
                        .enumerate()
                        .min_by_key(|(_, node)| *node)
                        .map(|(index, _)| index)
                        .expect("a cycle contains at least one declaration");
                    cycle.nodes.rotate_left(first);
                    cycle.edges.rotate_left(first);
                    return Some(cycle);
                }
                2 => {}
                _ => unreachable!("declaration graph DFS state is finite"),
            }
        }
    }
    None
}

fn validate_declaration_graph(
    graph: &[DeclarationGraphNode],
    kind: ProjectDiagnosticKind,
) -> Result<(), ProjectDiagnostic> {
    let Some(cycle) = first_declaration_cycle(graph) else {
        return Ok(());
    };
    let mut related = vec![graph[cycle.nodes[0]].declaration.clone()];
    for index in 1..cycle.nodes.len() {
        related.push(graph[cycle.nodes[index]].declaration.clone());
        related.push(cycle.edges[index].clone());
    }
    Err(ProjectDiagnostic {
        kind,
        primary: Some(cycle.edges[0].clone()),
        related,
    })
}

fn entity_origin(entity: &EntityId) -> Option<OriginRef> {
    match &entity.site {
        EntitySite::Source(origin) => Some(origin.clone()),
        EntitySite::Language | EntitySite::Module(_) => None,
    }
}

pub(crate) fn check_project(
    sources: &ProjectSources,
    owners: &BTreeMap<String, LibraryId>,
    documents: Vec<ContractDocument>,
) -> Result<CheckedProject, CheckDiagnostic> {
    let resolved = crate::resolver::resolve_project(sources).map_err(check_project_diagnostic)?;
    let prepared = prepare_project(resolved).map_err(check_project_diagnostic)?;
    check_prepared_project(prepared, owners, documents)
}

fn check_project_diagnostic(diagnostic: ProjectDiagnostic) -> CheckDiagnostic {
    CheckDiagnostic {
        kind: CheckDiagnosticKind::Project(Box::new(diagnostic.kind)),
        message: "project resolution or declaration preparation failed before Checker semantics were applied"
            .to_owned(),
        primary: diagnostic.primary.map(CheckOrigin::Source),
        related: diagnostic
            .related
            .into_iter()
            .map(CheckOrigin::Source)
            .collect(),
    }
}

fn check_prepared_project(
    prepared: PreparedProject,
    owners: &BTreeMap<String, LibraryId>,
    documents: Vec<ContractDocument>,
) -> Result<CheckedProject, CheckDiagnostic> {
    let project = &prepared.0;
    let mut normalizer = SourceTypeNormalizer::new(project);
    let (function_order, mut headers) = collect_supported_headers(project, &mut normalizer)?;
    let contract_selections =
        apply_contract_documents(project, owners, &documents, &mut headers, &normalizer)?;
    finalize_parameter_modes(&function_order, &mut headers)?;

    let mut functions = BTreeMap::new();
    for identity in function_order {
        let header = headers
            .get(&identity)
            .expect("source-ordered supported function remains indexed");
        let mut checker = BodyChecker::new(project, &headers, header, &mut normalizer);
        let body = checker.check_block(&header.body)?;
        if !type_satisfies(&body.ty, &header.return_type) {
            return Err(source_diagnostic(
                CheckDiagnosticKind::ReturnMismatch,
                format!(
                    "function body has type {} but the declared return type is {}",
                    display_type(&body.ty),
                    display_type(&header.return_type)
                ),
                header.context.origin(header.body.span),
                vec![header.return_origin.clone()],
            ));
        }
        functions.insert(
            identity.clone(),
            CheckedFunction {
                identity,
                origin: header.origin.clone(),
                parameters: header
                    .parameters
                    .iter()
                    .map(|parameter| CheckedParameter {
                        binding: parameter.binding.clone(),
                        ty: parameter.ty.clone(),
                        mode: parameter
                            .mode
                            .as_ref()
                            .expect("parameter modes are finalized before body checking")
                            .value,
                    })
                    .collect(),
                return_type: header.return_type.clone(),
                effect: CheckedEffect::Pure,
                body,
            },
        );
    }

    let selected_owners = documents
        .iter()
        .map(|document| {
            let label = document.0.owner.clone();
            let library = owners
                .get(&label)
                .copied()
                .expect("every selected contract owner was validated before body checking");
            (label, library)
        })
        .collect();
    let aliases = std::mem::take(&mut normalizer.normalized_aliases);
    drop(normalizer);
    Ok(CheckedProject {
        prepared,
        owners: selected_owners,
        documents,
        contract_selections,
        aliases,
        functions,
    })
}

#[derive(Clone)]
struct SourceContext {
    library: LibraryId,
    source: SourceRef,
}

impl SourceContext {
    fn from_origin(origin: &OriginRef) -> Self {
        Self {
            library: origin.library,
            source: origin.source.clone(),
        }
    }

    fn origin(&self, span: Span) -> OriginRef {
        OriginRef {
            library: self.library,
            source: self.source.clone(),
            span,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum CheckedType {
    Int,
    Float,
    Bool,
    Unit,
    Never,
    Tuple(Vec<CheckedType>),
}

#[derive(Clone)]
struct SelectedMode {
    value: ParameterMode,
    origin: CheckOrigin,
}

#[derive(Clone)]
struct HeaderParameter {
    binding: EntityId,
    span: Span,
    ty: CheckedType,
    type_origin: OriginRef,
    mode: Option<SelectedMode>,
}

#[derive(Clone)]
struct FunctionHeader {
    context: SourceContext,
    origin: OriginRef,
    public: bool,
    parameters: Vec<HeaderParameter>,
    return_type: CheckedType,
    return_origin: OriginRef,
    body: ResolvedBlock,
}

#[derive(Clone)]
struct AliasDefinition {
    context: SourceContext,
    origin: OriginRef,
    type_parameter_count: usize,
    value: ResolvedType,
}

struct SourceTypeNormalizer {
    aliases: BTreeMap<EntityId, AliasDefinition>,
    arities: BTreeMap<EntityId, usize>,
    normalized_aliases: BTreeMap<EntityId, CheckedType>,
    active_aliases: Vec<EntityId>,
}

impl SourceTypeNormalizer {
    fn new(project: &ResolvedProject) -> Self {
        let mut aliases = BTreeMap::new();
        let mut arities = BTreeMap::new();

        for identity in project.entities.keys() {
            if identity.kind == EntityKind::LanguageType {
                let arity = match identity.name.as_str() {
                    "List" | "Range" | "Ptr" => 1,
                    _ => 0,
                };
                arities.insert(identity.clone(), arity);
            }
        }

        for resolved_module in project.modules.values() {
            let Some(body) = &resolved_module.body else {
                continue;
            };
            let context = SourceContext::from_origin(&body.origin);
            for declaration in &body.declarations {
                let Some(identity) = &declaration.identity else {
                    continue;
                };
                let arity = match &declaration.kind {
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
                    }
                    | ResolvedDeclarationKind::ExternType { type_parameters } => {
                        Some(type_parameters.len())
                    }
                    ResolvedDeclarationKind::TypeAlias {
                        type_parameters,
                        value,
                    } => {
                        aliases.insert(
                            identity.clone(),
                            AliasDefinition {
                                context: context.clone(),
                                origin: declaration.origin.clone(),
                                type_parameter_count: type_parameters.len(),
                                value: value.clone(),
                            },
                        );
                        Some(type_parameters.len())
                    }
                    _ => None,
                };
                if let Some(arity) = arity {
                    arities.insert(identity.clone(), arity);
                }
            }
        }

        Self {
            aliases,
            arities,
            normalized_aliases: BTreeMap::new(),
            active_aliases: Vec::new(),
        }
    }

    fn normalize(
        &mut self,
        ty: &ResolvedType,
        context: &SourceContext,
    ) -> Result<CheckedType, CheckDiagnostic> {
        match &ty.kind {
            ResolvedTypeKind::Grouped(inner) => self.normalize(inner, context),
            ResolvedTypeKind::Tuple(elements) => {
                let mut normalized = Vec::with_capacity(elements.len());
                for element in elements {
                    normalized.push(self.normalize(element, context)?);
                }
                Ok(CheckedType::Tuple(normalized))
            }
            ResolvedTypeKind::Named(named) => self.normalize_named(named, context),
        }
    }

    fn normalize_named(
        &mut self,
        named: &ResolvedNamedType,
        context: &SourceContext,
    ) -> Result<CheckedType, CheckDiagnostic> {
        let (occurrence, target) = match &named.reference {
            ResolvedReference::Exact {
                occurrence, target, ..
            } => (occurrence, target),
            ResolvedReference::Selection { occurrence, .. } => {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "type-dependent or associated type selection is outside the initial Checker subset",
                    occurrence.clone(),
                    Vec::new(),
                ));
            }
        };

        let mut positional_count = 0;
        for argument in &named.arguments {
            match argument {
                ResolvedTypeArgument::Type(_) => positional_count += 1,
                ResolvedTypeArgument::AssociatedType { member, .. } => {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "associated type bindings are outside the initial Checker subset",
                        context.origin(member.origin.span),
                        Vec::new(),
                    ));
                }
            }
        }
        if let Some(expected) = self.arities.get(target)
            && *expected != positional_count
        {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                format!(
                    "type constructor `{}` expects {expected} argument(s) but received {positional_count}",
                    target.name
                ),
                occurrence.clone(),
                entity_origin(target).into_iter().collect(),
            ));
        }

        if target.kind == EntityKind::LanguageType {
            return match target.name.as_str() {
                "Int" => Ok(CheckedType::Int),
                "Float" => Ok(CheckedType::Float),
                "Bool" => Ok(CheckedType::Bool),
                "Unit" => Ok(CheckedType::Unit),
                "Never" => Ok(CheckedType::Never),
                _ => Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    format!(
                        "language type `{}` is outside the initial Checker subset",
                        target.name
                    ),
                    occurrence.clone(),
                    Vec::new(),
                )),
            };
        }

        if target.kind != EntityKind::TypeAlias {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                format!(
                    "nominal type `{}` is outside the initial Checker subset",
                    target.name
                ),
                occurrence.clone(),
                entity_origin(target).into_iter().collect(),
            ));
        }

        let definition = self
            .aliases
            .get(target)
            .cloned()
            .expect("every reachable type-alias entity has a resolved declaration");
        if definition.type_parameter_count != 0 {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "generic type aliases are outside the initial Checker subset",
                occurrence.clone(),
                vec![definition.origin],
            ));
        }
        if let Some(normalized) = self.normalized_aliases.get(target) {
            return Ok(normalized.clone());
        }
        if let Some(cycle_start) = self
            .active_aliases
            .iter()
            .position(|identity| identity == target)
        {
            let related = self.active_aliases[cycle_start..]
                .iter()
                .filter_map(|identity| self.aliases.get(identity))
                .map(|alias| alias.origin.clone())
                .collect();
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "non-generic type aliases form a cycle",
                occurrence.clone(),
                related,
            ));
        }

        self.active_aliases.push(target.clone());
        let normalized = self.normalize(&definition.value, &definition.context);
        self.active_aliases.pop();
        let normalized = normalized?;
        self.normalized_aliases
            .insert(target.clone(), normalized.clone());
        Ok(normalized)
    }
}

fn collect_supported_headers(
    project: &ResolvedProject,
    normalizer: &mut SourceTypeNormalizer,
) -> Result<(Vec<EntityId>, BTreeMap<EntityId, FunctionHeader>), CheckDiagnostic> {
    let core_declarations = core_role_declarations(&project.core_roles);
    let mut order = Vec::new();
    let mut headers = BTreeMap::new();
    let mut diagnostics = Vec::new();

    for (module, resolved_module) in &project.modules {
        let Some(body) = &resolved_module.body else {
            continue;
        };
        let context = SourceContext::from_origin(&body.origin);
        if let Some(requires) = &body.requires
            && !requires.effects.is_empty()
        {
            push_header_diagnostic(
                project,
                module,
                &mut diagnostics,
                source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "non-empty module `requires` is outside the initial Checker subset",
                    context.origin(requires.span),
                    Vec::new(),
                ),
            );
        }

        for declaration in &body.declarations {
            if declaration
                .identity
                .as_ref()
                .is_some_and(|identity| core_declarations.contains(identity))
            {
                continue;
            }
            match &declaration.kind {
                ResolvedDeclarationKind::Module(_) => {}
                ResolvedDeclarationKind::TypeAlias {
                    type_parameters,
                    value,
                } => {
                    if let Some(parameter) = type_parameters.first() {
                        push_header_diagnostic(
                            project,
                            module,
                            &mut diagnostics,
                            source_diagnostic(
                                CheckDiagnosticKind::Unsupported,
                                "generic type aliases are outside the initial Checker subset",
                                parameter.binding.origin.clone(),
                                Vec::new(),
                            ),
                        );
                    } else if let Err(diagnostic) = normalizer.normalize(value, &context) {
                        push_header_diagnostic(project, module, &mut diagnostics, diagnostic);
                    } else if declaration.public
                        && let Err(diagnostic) =
                            validate_public_type_visibility(project, value, &normalizer.aliases)
                    {
                        push_header_diagnostic(project, module, &mut diagnostics, diagnostic);
                    }
                }
                ResolvedDeclarationKind::Function(function) => {
                    let identity = declaration
                        .identity
                        .as_ref()
                        .expect("every resolved function has an exact identity")
                        .clone();
                    match collect_function_header(
                        project,
                        declaration,
                        function,
                        &context,
                        normalizer,
                    ) {
                        Ok(header) => {
                            order.push(identity.clone());
                            headers.insert(identity, header);
                        }
                        Err(found) => {
                            for diagnostic in found {
                                push_header_diagnostic(
                                    project,
                                    module,
                                    &mut diagnostics,
                                    diagnostic,
                                );
                            }
                        }
                    }
                }
                _ => {
                    push_header_diagnostic(
                        project,
                        module,
                        &mut diagnostics,
                        source_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "reachable declaration is outside the initial Checker subset",
                            declaration.origin.clone(),
                            Vec::new(),
                        ),
                    );
                }
            }
        }
    }
    if let Some(diagnostic) = diagnostics
        .into_iter()
        .min_by(|left, right| left.key.cmp(&right.key))
    {
        return Err(diagnostic.diagnostic);
    }
    Ok((order, headers))
}

struct HeaderDiagnosticCandidate {
    key: (ModuleRef, Span, u8),
    diagnostic: CheckDiagnostic,
}

fn push_header_diagnostic(
    project: &ResolvedProject,
    fallback_module: &ModuleRef,
    diagnostics: &mut Vec<HeaderDiagnosticCandidate>,
    diagnostic: CheckDiagnostic,
) {
    let origin = match diagnostic.primary.as_ref() {
        Some(CheckOrigin::Source(origin)) => origin,
        _ => unreachable!("declaration/header diagnostics always have a source origin"),
    };
    let module = module_for_origin(project, origin).unwrap_or_else(|| fallback_module.clone());
    diagnostics.push(HeaderDiagnosticCandidate {
        key: (module, origin.span, check_diagnostic_rank(&diagnostic.kind)),
        diagnostic,
    });
}

fn module_for_origin(project: &ResolvedProject, origin: &OriginRef) -> Option<ModuleRef> {
    project
        .modules
        .iter()
        .filter_map(|(module, resolved_module)| {
            let body = resolved_module.body.as_ref()?;
            (body.origin.library == origin.library
                && body.origin.source == origin.source
                && body.origin.span.start <= origin.span.start
                && origin.span.end <= body.origin.span.end)
                .then_some(module)
        })
        .max_by_key(|module| module.path().len())
        .cloned()
}

fn check_diagnostic_rank(kind: &CheckDiagnosticKind) -> u8 {
    match kind {
        CheckDiagnosticKind::Project(_) => 0,
        CheckDiagnosticKind::Unsupported => 1,
        CheckDiagnosticKind::TypeMismatch => 2,
        CheckDiagnosticKind::CallMismatch => 3,
        CheckDiagnosticKind::ReturnMismatch => 4,
        CheckDiagnosticKind::ContractBinding => 5,
        CheckDiagnosticKind::ContractConflict => 6,
        CheckDiagnosticKind::LiteralOutOfRange => 7,
    }
}

fn validate_public_type_visibility(
    project: &ResolvedProject,
    ty: &ResolvedType,
    aliases: &BTreeMap<EntityId, AliasDefinition>,
) -> Result<(), CheckDiagnostic> {
    fn visit(
        project: &ResolvedProject,
        ty: &ResolvedType,
        aliases: &BTreeMap<EntityId, AliasDefinition>,
        visited_aliases: &mut BTreeSet<EntityId>,
    ) -> Result<(), CheckDiagnostic> {
        match &ty.kind {
            ResolvedTypeKind::Grouped(inner) => visit(project, inner, aliases, visited_aliases),
            ResolvedTypeKind::Tuple(elements) => {
                for element in elements {
                    visit(project, element, aliases, visited_aliases)?;
                }
                Ok(())
            }
            ResolvedTypeKind::Named(named) => {
                let ResolvedReference::Exact {
                    occurrence, target, ..
                } = &named.reference
                else {
                    return Ok(());
                };
                if target.kind != EntityKind::TypeAlias {
                    return Ok(());
                }
                let metadata = project
                    .entities
                    .get(target)
                    .expect("every exact type alias has entity metadata");
                if !metadata.public {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        format!(
                            "public type surface references private type alias `{}`",
                            target.name
                        ),
                        occurrence.clone(),
                        entity_origin(target).into_iter().collect(),
                    ));
                }
                if visited_aliases.insert(target.clone()) {
                    let definition = aliases
                        .get(target)
                        .expect("every exact type alias has a resolved definition");
                    if definition.type_parameter_count == 0 {
                        visit(project, &definition.value, aliases, visited_aliases)?;
                    }
                }
                Ok(())
            }
        }
    }

    visit(project, ty, aliases, &mut BTreeSet::new())
}

fn collect_function_header(
    project: &ResolvedProject,
    declaration: &ResolvedDeclaration,
    function: &crate::project::ResolvedFunction,
    context: &SourceContext,
    normalizer: &mut SourceTypeNormalizer,
) -> Result<FunctionHeader, Vec<CheckDiagnostic>> {
    if let Some(span) = function.const_span {
        return Err(vec![source_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "const functions are outside the initial Checker subset",
            context.origin(span),
            Vec::new(),
        )]);
    }
    let first_generic = function
        .type_parameters
        .iter()
        .map(|parameter| parameter.binding.origin.clone())
        .chain(
            function
                .effect_parameters
                .iter()
                .map(|parameter| parameter.binding.origin.clone()),
        )
        .min_by_key(|origin| origin.span);
    if let Some(origin) = first_generic {
        return Err(vec![source_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "generic or effect-parameterized functions are outside the initial Checker subset",
            origin,
            Vec::new(),
        )]);
    }

    let mut diagnostics = Vec::new();
    let mut parameters = Vec::with_capacity(function.parameters.len());
    for parameter in &function.parameters {
        if parameter.binding.identity.name == "self" {
            diagnostics.push(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "module-level function receivers are outside the initial Checker subset",
                parameter.binding.origin.clone(),
                Vec::new(),
            ));
        }
        if let Some(span) = parameter.escape {
            diagnostics.push(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "scoped parameters are outside the initial Checker subset",
                context.origin(span),
                Vec::new(),
            ));
        }
        let mode = match parameter.mode {
            Some((span, ParameterMode::Borrow)) => Some(SelectedMode {
                value: ParameterMode::Borrow,
                origin: CheckOrigin::Source(context.origin(span)),
            }),
            Some((span, ParameterMode::Move)) => Some(SelectedMode {
                value: ParameterMode::Move,
                origin: CheckOrigin::Source(context.origin(span)),
            }),
            Some((span, ParameterMode::MutBorrow | ParameterMode::Call)) => {
                diagnostics.push(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "mutable-borrow and callable-selected parameter modes are outside the initial Checker subset",
                    context.origin(span),
                    Vec::new(),
                ));
                None
            }
            None => None,
        };
        let annotation = match &parameter.annotation {
            Some(ResolvedParameterAnnotation::Type(annotation)) => Some(annotation),
            Some(ResolvedParameterAnnotation::Shape(shape)) => {
                diagnostics.push(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "callable parameter shapes are outside the initial Checker subset",
                    context.origin(shape.span),
                    Vec::new(),
                ));
                None
            }
            None => {
                diagnostics.push(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "every parameter needs an explicit type annotation in the initial Checker subset",
                    parameter.binding.origin.clone(),
                    Vec::new(),
                ));
                None
            }
        };
        if let Some(annotation) = annotation {
            if declaration.public
                && let Err(diagnostic) =
                    validate_public_type_visibility(project, annotation, &normalizer.aliases)
            {
                diagnostics.push(diagnostic);
            }
            match normalizer.normalize(annotation, context) {
                Ok(ty) => parameters.push(HeaderParameter {
                    binding: parameter.binding.identity.clone(),
                    span: parameter.span,
                    ty,
                    type_origin: context.origin(annotation.span),
                    mode,
                }),
                Err(diagnostic) => diagnostics.push(diagnostic),
            }
        }
    }

    let return_annotation = match function.return_type.as_deref() {
        Some(ResolvedReturnAnnotation::Type(annotation)) => Some(annotation),
        Some(ResolvedReturnAnnotation::Shape(shape)) => {
            diagnostics.push(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "callable return shapes are outside the initial Checker subset",
                context.origin(shape.span),
                Vec::new(),
            ));
            None
        }
        None => {
            diagnostics.push(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "every function needs an explicit return type in the initial Checker subset",
                context.origin(function.body.span),
                Vec::new(),
            ));
            None
        }
    };
    if let Some(effects) = &function.effects
        && !effects.effects.is_empty()
    {
        diagnostics.push(source_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "non-empty source effect rows are outside the initial Checker subset",
            context.origin(effects.span),
            Vec::new(),
        ));
    }

    let return_type = return_annotation.and_then(|annotation| {
        if declaration.public
            && let Err(diagnostic) =
                validate_public_type_visibility(project, annotation, &normalizer.aliases)
        {
            diagnostics.push(diagnostic);
        }
        match normalizer.normalize(annotation, context) {
            Ok(ty) => Some((ty, context.origin(annotation.span))),
            Err(diagnostic) => {
                diagnostics.push(diagnostic);
                None
            }
        }
    });
    if !diagnostics.is_empty() {
        return Err(diagnostics);
    }
    let (return_type, return_origin) =
        return_type.expect("a diagnostic is retained when the return type is unavailable");

    Ok(FunctionHeader {
        context: context.clone(),
        origin: declaration.origin.clone(),
        public: declaration.public,
        parameters,
        return_type,
        return_origin,
        body: function.body.clone(),
    })
}

fn core_role_declarations(roles: &crate::project::CoreRoles) -> BTreeSet<EntityId> {
    [
        &roles.option.declaration,
        &roles.ordering.declaration,
        &roles.partial_eq.declaration,
        &roles.eq,
        &roles.partial_ord.declaration,
        &roles.ord.declaration,
        &roles.clone.declaration,
        &roles.copy,
        &roles.drop.declaration,
        &roles.display.declaration,
        &roles.debug.declaration,
        &roles.hash.declaration,
        &roles.fn_once,
        &roles.fn_mut,
        &roles.function,
        &roles.iterator.declaration,
        &roles.iterable.declaration,
    ]
    .into_iter()
    .cloned()
    .collect()
}

fn source_diagnostic(
    kind: CheckDiagnosticKind,
    message: impl Into<String>,
    primary: OriginRef,
    related: Vec<OriginRef>,
) -> CheckDiagnostic {
    CheckDiagnostic {
        kind,
        message: message.into(),
        primary: Some(CheckOrigin::Source(primary)),
        related: related.into_iter().map(CheckOrigin::Source).collect(),
    }
}

fn contract_diagnostic(
    kind: CheckDiagnosticKind,
    message: impl Into<String>,
    document_index: usize,
    json_path: impl Into<String>,
    related: Vec<CheckOrigin>,
) -> CheckDiagnostic {
    CheckDiagnostic {
        kind,
        message: message.into(),
        primary: Some(CheckOrigin::Contract {
            document_index,
            json_path: json_path.into(),
        }),
        related,
    }
}

fn display_type(ty: &CheckedType) -> String {
    match ty {
        CheckedType::Int => "Int".to_owned(),
        CheckedType::Float => "Float".to_owned(),
        CheckedType::Bool => "Bool".to_owned(),
        CheckedType::Unit => "Unit".to_owned(),
        CheckedType::Never => "Never".to_owned(),
        CheckedType::Tuple(elements) => format!(
            "({})",
            elements
                .iter()
                .map(display_type)
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

fn type_satisfies(actual: &CheckedType, expected: &CheckedType) -> bool {
    match (actual, expected) {
        (CheckedType::Never, _) => true,
        (CheckedType::Tuple(actual), CheckedType::Tuple(expected))
            if actual.len() == expected.len() =>
        {
            actual
                .iter()
                .zip(expected)
                .all(|(actual, expected)| type_satisfies(actual, expected))
        }
        _ => actual == expected,
    }
}

#[allow(dead_code)]
#[derive(Default)]
struct ContractSelections {
    parameter_types: BTreeMap<(EntityId, usize), (CheckedType, CheckOrigin)>,
    return_types: BTreeMap<EntityId, (CheckedType, CheckOrigin)>,
    parameter_modes: BTreeMap<(EntityId, usize), (ParameterMode, CheckOrigin)>,
    effect_upper: BTreeMap<EntityId, CheckOrigin>,
    generic_requirements: BTreeMap<EntityId, CheckOrigin>,
}

struct ContractValue<T> {
    value: T,
    path: String,
}

struct ContractRecordUpdate {
    target: EntityId,
    parameter_types: Vec<(usize, ContractValue<CheckedType>)>,
    return_type: Option<ContractValue<CheckedType>>,
    parameter_modes: Vec<(usize, ContractValue<ParameterMode>)>,
    effect_upper: Option<String>,
    generic_requirements: Option<String>,
}

fn apply_contract_documents(
    project: &ResolvedProject,
    owners: &BTreeMap<String, LibraryId>,
    documents: &[ContractDocument],
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    normalizer: &SourceTypeNormalizer,
) -> Result<ContractSelections, CheckDiagnostic> {
    let mut selections = ContractSelections::default();
    for (document_index, document) in documents.iter().enumerate() {
        let document = &document.0;
        let Some(owner) = owners.get(&document.owner).copied() else {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::ContractBinding,
                format!(
                    "contract owner label {:?} has no supplied library binding",
                    document.owner
                ),
                document_index,
                "$.owner",
                Vec::new(),
            ));
        };
        if !project.dependencies.contains_key(&owner) {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::ContractBinding,
                format!(
                    "contract owner label {:?} names library {:?}, which is not reachable in this project",
                    document.owner, owner
                ),
                document_index,
                "$.owner",
                Vec::new(),
            ));
        }

        for (record_index, record) in document.records.iter().enumerate() {
            let update = validate_contract_record(
                project,
                owner,
                document_index,
                record_index,
                record,
                headers,
                normalizer,
            )?;
            apply_contract_record_update(document_index, update, headers, &mut selections)?;
        }
    }
    Ok(selections)
}

fn validate_contract_record(
    project: &ResolvedProject,
    owner: LibraryId,
    document_index: usize,
    record_index: usize,
    record: &contract::Record,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    normalizer: &SourceTypeNormalizer,
) -> Result<ContractRecordUpdate, CheckDiagnostic> {
    let record_path = format!("$.records[{record_index}]");
    let target_path = format!("{record_path}.target");
    let declaration = match &record.target {
        contract::EntityRef::Declaration { declaration }
            if matches!(declaration.kind, contract::DeclarationKind::Function) =>
        {
            declaration
        }
        _ => {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "only ordinary function declaration records are supported by the initial Checker",
                document_index,
                target_path,
                Vec::new(),
            ));
        }
    };
    let target = lookup_contract_path(
        project,
        owner,
        &declaration.library,
        &declaration.path,
        Namespace::Value,
    )
    .map_err(|message| {
        contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            message,
            document_index,
            target_path.clone(),
            Vec::new(),
        )
    })?;
    if target.kind != EntityKind::Function {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            format!(
                "contract target resolves to {:?}, not an ordinary function declaration",
                target.kind
            ),
            document_index,
            target_path,
            entity_origin(&target)
                .map(CheckOrigin::Source)
                .into_iter()
                .collect(),
        ));
    }
    if target.module.source_library() != Some(owner) {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            "a contract record may only target a function owned by its document library",
            document_index,
            target_path,
            entity_origin(&target)
                .map(CheckOrigin::Source)
                .into_iter()
                .collect(),
        ));
    }
    let header = headers.get(&target).expect(
        "declaration/header validation completes before contracts bind an ordinary function",
    );

    if record
        .type_parameters
        .as_ref()
        .is_some_and(|parameters| !parameters.is_empty())
    {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "non-empty record type parameters are outside the initial Checker subset",
            document_index,
            format!("{record_path}.type_parameters"),
            Vec::new(),
        ));
    }
    if let Some((path, message)) = first_unsupported_record_clause(record, &record_path) {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::Unsupported,
            message,
            document_index,
            path,
            Vec::new(),
        ));
    }

    let mut update = ContractRecordUpdate {
        target,
        parameter_types: Vec::new(),
        return_type: None,
        parameter_modes: Vec::new(),
        effect_upper: None,
        generic_requirements: None,
    };
    if let Some(set) = &record.set {
        if let Some(parameter_types) = &set.parameter_types {
            for (clause_index, clause) in parameter_types.0.iter().enumerate() {
                let clause_path = format!("{record_path}.set.parameter_types[{clause_index}]");
                let parameter_index = contract_parameter_index(
                    &clause.parameter,
                    header.parameters.len(),
                    document_index,
                    &format!("{clause_path}.parameter"),
                )?;
                let ty = normalize_contract_type(
                    project,
                    owner,
                    document_index,
                    &format!("{clause_path}.type"),
                    &clause.value_type,
                    normalizer,
                )?;
                update.parameter_types.push((
                    parameter_index,
                    ContractValue {
                        value: ty,
                        path: format!("{clause_path}.type"),
                    },
                ));
            }
        }
        if let Some(return_type) = &set.return_type {
            let path = format!("{record_path}.set.return_type");
            update.return_type = Some(ContractValue {
                value: normalize_contract_type(
                    project,
                    owner,
                    document_index,
                    &path,
                    return_type,
                    normalizer,
                )?,
                path,
            });
        }
        if let Some(parameter_modes) = &set.parameter_modes {
            for (clause_index, clause) in parameter_modes.0.iter().enumerate() {
                let clause_path = format!("{record_path}.set.parameter_modes[{clause_index}]");
                let parameter_index = contract_parameter_index(
                    &clause.parameter,
                    header.parameters.len(),
                    document_index,
                    &format!("{clause_path}.parameter"),
                )?;
                let mode = match &clause.mode {
                    contract::ModeRule::Fixed {
                        mode: contract::Mode::Borrow,
                    } => ParameterMode::Borrow,
                    contract::ModeRule::Fixed {
                        mode: contract::Mode::Move,
                    } => ParameterMode::Move,
                    contract::ModeRule::Fixed {
                        mode: contract::Mode::Mut,
                    }
                    | contract::ModeRule::CallableUse { .. } => {
                        return Err(contract_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "only fixed Borrow and Move contract modes are supported",
                            document_index,
                            format!("{clause_path}.mode"),
                            Vec::new(),
                        ));
                    }
                };
                update.parameter_modes.push((
                    parameter_index,
                    ContractValue {
                        value: mode,
                        path: format!("{clause_path}.mode"),
                    },
                ));
            }
        }
        if set.parameter_escape.is_some() {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "parameter_escape clauses are outside the initial Checker subset",
                document_index,
                format!("{record_path}.set.parameter_escape"),
                Vec::new(),
            ));
        }
        if let Some(effect_upper) = &set.effect_upper {
            if !effect_upper.is_empty() {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "non-empty contract effect rows are outside the initial Checker subset",
                    document_index,
                    format!("{record_path}.set.effect_upper"),
                    Vec::new(),
                ));
            }
            update.effect_upper = Some(format!("{record_path}.set.effect_upper"));
        }
        if let Some(requirements) = &set.generic_requirements {
            if !requirements.is_empty() {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "non-empty generic requirements are outside the initial Checker subset",
                    document_index,
                    format!("{record_path}.set.generic_requirements"),
                    Vec::new(),
                ));
            }
            update.generic_requirements = Some(format!("{record_path}.set.generic_requirements"));
        }
    }
    if let Some(check) = &record.check {
        let field = if check.return_traits.is_some() {
            "return_traits"
        } else if check.structure.is_some() {
            "structure"
        } else if check.visibility.is_some() {
            "visibility"
        } else if check.exports.is_some() {
            "exports"
        } else {
            debug_assert!(check.reject_new.is_some());
            "reject_new"
        };
        return Err(contract_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "contract check clauses are outside the initial Checker subset",
            document_index,
            format!("{record_path}.check.{field}"),
            Vec::new(),
        ));
    }

    Ok(update)
}

fn first_unsupported_record_clause(
    record: &contract::Record,
    record_path: &str,
) -> Option<(String, &'static str)> {
    if let Some(set) = &record.set {
        if let Some(parameter_types) = &set.parameter_types {
            for (index, clause) in parameter_types.0.iter().enumerate() {
                let path = format!("{record_path}.set.parameter_types[{index}]");
                if matches!(&clause.parameter, contract::ParameterRef::Receiver {}) {
                    return Some((
                        format!("{path}.parameter"),
                        "receiver parameters are outside the initial Checker subset",
                    ));
                }
                if let Some(path) =
                    unsupported_contract_type_path(&clause.value_type, &format!("{path}.type"))
                {
                    return Some((path, "contract type is outside the initial Checker subset"));
                }
            }
        }
        if let Some(return_type) = &set.return_type
            && let Some(path) = unsupported_contract_type_path(
                return_type,
                &format!("{record_path}.set.return_type"),
            )
        {
            return Some((path, "contract type is outside the initial Checker subset"));
        }
        if let Some(parameter_modes) = &set.parameter_modes {
            for (index, clause) in parameter_modes.0.iter().enumerate() {
                let path = format!("{record_path}.set.parameter_modes[{index}]");
                if matches!(&clause.parameter, contract::ParameterRef::Receiver {}) {
                    return Some((
                        format!("{path}.parameter"),
                        "receiver parameters are outside the initial Checker subset",
                    ));
                }
                if !matches!(
                    &clause.mode,
                    contract::ModeRule::Fixed {
                        mode: contract::Mode::Borrow | contract::Mode::Move
                    }
                ) {
                    return Some((
                        format!("{path}.mode"),
                        "only fixed Borrow and Move contract modes are supported",
                    ));
                }
            }
        }
        if set.parameter_escape.is_some() {
            return Some((
                format!("{record_path}.set.parameter_escape"),
                "parameter_escape clauses are outside the initial Checker subset",
            ));
        }
        if set
            .effect_upper
            .as_ref()
            .is_some_and(|effects| !effects.is_empty())
        {
            return Some((
                format!("{record_path}.set.effect_upper"),
                "non-empty contract effect rows are outside the initial Checker subset",
            ));
        }
        if set
            .generic_requirements
            .as_ref()
            .is_some_and(|requirements| !requirements.is_empty())
        {
            return Some((
                format!("{record_path}.set.generic_requirements"),
                "non-empty generic requirements are outside the initial Checker subset",
            ));
        }
    }
    if let Some(check) = &record.check {
        let field = if check.return_traits.is_some() {
            "return_traits"
        } else if check.structure.is_some() {
            "structure"
        } else if check.visibility.is_some() {
            "visibility"
        } else if check.exports.is_some() {
            "exports"
        } else {
            "reject_new"
        };
        return Some((
            format!("{record_path}.check.{field}"),
            "contract check clauses are outside the initial Checker subset",
        ));
    }
    None
}

fn unsupported_contract_type_path(ty: &contract::Type, path: &str) -> Option<String> {
    match ty {
        contract::Type::Primitive {
            name:
                contract::PrimitiveType::Int
                | contract::PrimitiveType::Float
                | contract::PrimitiveType::Bool
                | contract::PrimitiveType::Unit
                | contract::PrimitiveType::Never,
        } => None,
        contract::Type::Tuple { elements } => {
            elements.0.iter().enumerate().find_map(|(index, element)| {
                unsupported_contract_type_path(element, &format!("{path}.elements[{index}]"))
            })
        }
        contract::Type::Nominal { declaration, .. }
            if matches!(declaration.kind, contract::DeclarationKind::TypeAlias) =>
        {
            None
        }
        _ => Some(path.to_owned()),
    }
}

fn contract_parameter_index(
    parameter: &contract::ParameterRef,
    parameter_count: usize,
    document_index: usize,
    path: &str,
) -> Result<usize, CheckDiagnostic> {
    let contract::ParameterRef::Position { index } = parameter else {
        return Err(contract_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "receiver parameters are outside the initial Checker subset",
            document_index,
            path,
            Vec::new(),
        ));
    };
    let wire_index = index.0;
    let index = usize::try_from(wire_index).ok();
    match index.filter(|index| *index < parameter_count) {
        Some(index) => Ok(index),
        None => Err(contract_diagnostic(
            CheckDiagnosticKind::ContractBinding,
            format!(
                "contract parameter index {} does not name one of the function's {parameter_count} parameter(s)",
                wire_index
            ),
            document_index,
            path,
            Vec::new(),
        )),
    }
}

fn normalize_contract_type(
    project: &ResolvedProject,
    owner: LibraryId,
    document_index: usize,
    path: &str,
    ty: &contract::Type,
    normalizer: &SourceTypeNormalizer,
) -> Result<CheckedType, CheckDiagnostic> {
    match ty {
        contract::Type::Primitive { name } => match name {
            contract::PrimitiveType::Int => Ok(CheckedType::Int),
            contract::PrimitiveType::Float => Ok(CheckedType::Float),
            contract::PrimitiveType::Bool => Ok(CheckedType::Bool),
            contract::PrimitiveType::Unit => Ok(CheckedType::Unit),
            contract::PrimitiveType::Never => Ok(CheckedType::Never),
            contract::PrimitiveType::Str => Err(contract_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "contract type Str is outside the initial Checker subset",
                document_index,
                path,
                Vec::new(),
            )),
        },
        contract::Type::Tuple { elements } => {
            let mut normalized = Vec::with_capacity(elements.0.len());
            for (index, element) in elements.0.iter().enumerate() {
                normalized.push(normalize_contract_type(
                    project,
                    owner,
                    document_index,
                    &format!("{path}.elements[{index}]"),
                    element,
                    normalizer,
                )?);
            }
            Ok(CheckedType::Tuple(normalized))
        }
        contract::Type::Nominal {
            declaration,
            arguments,
        } => {
            if !matches!(declaration.kind, contract::DeclarationKind::TypeAlias) {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "only non-generic type aliases are supported as nominal contract types",
                    document_index,
                    path,
                    Vec::new(),
                ));
            }
            let target = lookup_contract_path(
                project,
                owner,
                &declaration.library,
                &declaration.path,
                Namespace::Type,
            )
            .map_err(|message| {
                contract_diagnostic(
                    CheckDiagnosticKind::ContractBinding,
                    message,
                    document_index,
                    path,
                    Vec::new(),
                )
            })?;
            if target.kind != EntityKind::TypeAlias {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::ContractBinding,
                    "nominal contract type does not resolve to a type alias",
                    document_index,
                    path,
                    entity_origin(&target)
                        .map(CheckOrigin::Source)
                        .into_iter()
                        .collect(),
                ));
            }
            let Some(definition) = normalizer.aliases.get(&target) else {
                unreachable!("every resolved type alias is indexed by the source normalizer")
            };
            if definition.type_parameter_count != arguments.len() {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::ContractBinding,
                    format!(
                        "type alias expects {} argument(s) but the contract supplied {}",
                        definition.type_parameter_count,
                        arguments.len()
                    ),
                    document_index,
                    path,
                    vec![CheckOrigin::Source(definition.origin.clone())],
                ));
            }
            if definition.type_parameter_count != 0 {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "generic type aliases are outside the initial Checker subset",
                    document_index,
                    path,
                    vec![CheckOrigin::Source(definition.origin.clone())],
                ));
            }
            Ok(normalizer
                .normalized_aliases
                .get(&target)
                .expect("every supported alias is normalized during declaration checking")
                .clone())
        }
        _ => Err(contract_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "contract type is outside the initial Checker subset",
            document_index,
            path,
            Vec::new(),
        )),
    }
}

fn lookup_contract_path(
    project: &ResolvedProject,
    owner: LibraryId,
    library: &contract::LibraryRef,
    path: &[contract::Identifier],
    terminal_namespace: Namespace,
) -> Result<EntityId, String> {
    if path.is_empty() {
        return Err("contract declaration path is empty".to_owned());
    }
    let library = match library {
        contract::LibraryRef::Current {} => owner,
        contract::LibraryRef::Dependency { alias } => project
            .dependencies
            .get(&owner)
            .and_then(|dependencies| dependencies.get(&alias.0))
            .copied()
            .ok_or_else(|| {
                format!(
                    "contract dependency alias {:?} is not a direct edge of library {:?}",
                    alias.0, owner
                )
            })?,
    };

    let mut module = ModuleRef::root(library);
    for (index, segment) in path.iter().enumerate() {
        let terminal = index + 1 == path.len();
        let namespace = if terminal {
            terminal_namespace
        } else {
            Namespace::Type
        };
        let require_public = module.source_library() != Some(owner);
        let mut targets = project
            .name_bindings
            .get(&module)
            .and_then(|table| table.get(&(namespace, segment.0.clone())))
            .into_iter()
            .flatten()
            .filter(|binding| !require_public || binding.public)
            .filter(|binding| terminal || binding.target.kind == EntityKind::Module)
            .filter(|binding| {
                terminal
                    || binding.target.module.source_library() == Some(library)
                    || binding.public
            })
            .map(|binding| binding.target.clone())
            .collect::<Vec<_>>();
        targets.sort();
        targets.dedup();
        let target = match targets.as_slice() {
            [target] => target.clone(),
            [] => {
                return Err(format!(
                    "contract path segment {:?} has no accessible {:?} binding",
                    segment.0, namespace
                ));
            }
            _ => {
                return Err(format!(
                    "contract path segment {:?} has more than one exact binding",
                    segment.0
                ));
            }
        };
        if terminal {
            return Ok(target);
        }
        module = target.module.clone();
    }
    unreachable!("a non-empty contract path has a terminal segment")
}

fn apply_contract_record_update(
    document_index: usize,
    update: ContractRecordUpdate,
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    selections: &mut ContractSelections,
) -> Result<(), CheckDiagnostic> {
    let header = headers
        .get_mut(&update.target)
        .expect("validated contract targets remain in the supported header set");

    for (parameter_index, selected) in update.parameter_types {
        let origin = CheckOrigin::Contract {
            document_index,
            json_path: selected.path.clone(),
        };
        let key = (update.target.clone(), parameter_index);
        if let Some((previous, previous_origin)) = selections.parameter_types.get(&key)
            && previous != &selected.value
        {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::ContractConflict,
                "partial contract records select different parameter types",
                document_index,
                selected.path,
                vec![previous_origin.clone()],
            ));
        }
        let source = &header.parameters[parameter_index];
        if source.ty != selected.value {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::ContractConflict,
                format!(
                    "contract parameter type {} conflicts with source type {}",
                    display_type(&selected.value),
                    display_type(&source.ty)
                ),
                document_index,
                selected.path,
                vec![CheckOrigin::Source(source.type_origin.clone())],
            ));
        }
        selections
            .parameter_types
            .entry(key)
            .or_insert((selected.value, origin));
    }

    if let Some(selected) = update.return_type {
        let origin = CheckOrigin::Contract {
            document_index,
            json_path: selected.path.clone(),
        };
        if let Some((previous, previous_origin)) = selections.return_types.get(&update.target)
            && previous != &selected.value
        {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::ContractConflict,
                "partial contract records select different return types",
                document_index,
                selected.path,
                vec![previous_origin.clone()],
            ));
        }
        if header.return_type != selected.value {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::ContractConflict,
                format!(
                    "contract return type {} conflicts with source type {}",
                    display_type(&selected.value),
                    display_type(&header.return_type)
                ),
                document_index,
                selected.path,
                vec![CheckOrigin::Source(header.return_origin.clone())],
            ));
        }
        selections
            .return_types
            .entry(update.target.clone())
            .or_insert((selected.value, origin));
    }

    for (parameter_index, selected) in update.parameter_modes {
        let origin = CheckOrigin::Contract {
            document_index,
            json_path: selected.path.clone(),
        };
        let key = (update.target.clone(), parameter_index);
        if let Some((previous, previous_origin)) = selections.parameter_modes.get(&key)
            && previous != &selected.value
        {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::ContractConflict,
                "partial contract records select different parameter modes",
                document_index,
                selected.path,
                vec![previous_origin.clone()],
            ));
        }
        let parameter = &mut header.parameters[parameter_index];
        if let Some(source) = &parameter.mode {
            if matches!(source.origin, CheckOrigin::Source(_)) && source.value != selected.value {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "different explicit source and contract parameter modes require the later mode-difference policy",
                    document_index,
                    selected.path,
                    vec![source.origin.clone()],
                ));
            }
        } else {
            parameter.mode = Some(SelectedMode {
                value: selected.value,
                origin: origin.clone(),
            });
        }
        selections
            .parameter_modes
            .entry(key)
            .or_insert((selected.value, origin));
    }

    if let Some(path) = update.effect_upper {
        selections
            .effect_upper
            .entry(update.target.clone())
            .or_insert(CheckOrigin::Contract {
                document_index,
                json_path: path,
            });
    }
    if let Some(path) = update.generic_requirements {
        selections
            .generic_requirements
            .entry(update.target)
            .or_insert(CheckOrigin::Contract {
                document_index,
                json_path: path,
            });
    }
    Ok(())
}

fn finalize_parameter_modes(
    function_order: &[EntityId],
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
) -> Result<(), CheckDiagnostic> {
    for identity in function_order {
        let header = headers
            .get_mut(identity)
            .expect("source-ordered function remains indexed");
        for parameter in &mut header.parameters {
            if parameter.mode.is_none() {
                if header.public {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "every public input mode must be explicit in source or a supported contract",
                        header.context.origin(parameter.span),
                        Vec::new(),
                    ));
                }
                parameter.mode = Some(SelectedMode {
                    value: ParameterMode::Borrow,
                    origin: CheckOrigin::Source(header.context.origin(parameter.span)),
                });
            }
        }
    }
    Ok(())
}

#[allow(dead_code)]
struct CheckedFunction {
    identity: EntityId,
    origin: OriginRef,
    parameters: Vec<CheckedParameter>,
    return_type: CheckedType,
    effect: CheckedEffect,
    body: TypedBlock,
}

#[allow(dead_code)]
struct CheckedParameter {
    binding: EntityId,
    ty: CheckedType,
    mode: ParameterMode,
}

#[allow(dead_code)]
enum CheckedEffect {
    Pure,
}

#[allow(dead_code)]
struct TypedBlock {
    span: Span,
    statements: Vec<TypedStatement>,
    tail: Option<Box<TypedExpr>>,
    ty: CheckedType,
}

#[allow(dead_code)]
struct TypedStatement {
    span: Span,
    kind: TypedStatementKind,
}

#[allow(dead_code)]
enum TypedStatementKind {
    Let {
        binding: Box<EntityId>,
        ty: CheckedType,
        value: Box<TypedExpr>,
    },
    Return(Option<Box<TypedExpr>>),
    Expression(Box<TypedExpr>),
}

#[allow(dead_code)]
struct TypedExpr {
    span: Span,
    ty: CheckedType,
    kind: TypedExprKind,
}

#[allow(dead_code)]
enum TypedExprKind {
    Integer {
        value: i64,
        literal_span: Span,
    },
    Float(u64),
    Boolean(bool),
    Unit,
    Reference(Box<EntityId>),
    Parenthesized(Box<TypedExpr>),
    Tuple(Vec<TypedExpr>),
    Block(Box<TypedBlock>),
    If {
        condition: Box<TypedExpr>,
        then_branch: Box<TypedBlock>,
        else_branch: Option<Box<TypedExpr>>,
    },
    Unary {
        operator: UnaryOperator,
        operand: Box<TypedExpr>,
    },
    Binary {
        operator: BinaryOperator,
        left: Box<TypedExpr>,
        right: Box<TypedExpr>,
        comparison: Option<Box<ComparisonEvidence>>,
    },
    Call {
        callee: Box<EntityId>,
        arguments: Vec<TypedExpr>,
        parameter_modes: Vec<ParameterMode>,
    },
    TupleField {
        receiver: Box<TypedExpr>,
        index: usize,
    },
}

#[allow(dead_code)]
struct ComparisonEvidence {
    trait_declaration: EntityId,
    method: EntityId,
    result_carriers: Option<(EntityId, EntityId)>,
}

struct BodyChecker<'project, 'borrow> {
    project: &'project ResolvedProject,
    headers: &'borrow BTreeMap<EntityId, FunctionHeader>,
    function: &'borrow FunctionHeader,
    normalizer: &'borrow mut SourceTypeNormalizer,
    values: BTreeMap<EntityId, CheckedType>,
}

impl<'project, 'borrow> BodyChecker<'project, 'borrow> {
    fn new(
        project: &'project ResolvedProject,
        headers: &'borrow BTreeMap<EntityId, FunctionHeader>,
        function: &'borrow FunctionHeader,
        normalizer: &'borrow mut SourceTypeNormalizer,
    ) -> Self {
        let values = function
            .parameters
            .iter()
            .map(|parameter| (parameter.binding.clone(), parameter.ty.clone()))
            .collect();
        Self {
            project,
            headers,
            function,
            normalizer,
            values,
        }
    }

    fn origin(&self, span: Span) -> OriginRef {
        self.function.context.origin(span)
    }

    fn check_block(&mut self, block: &ResolvedBlock) -> Result<TypedBlock, CheckDiagnostic> {
        let mut statements = Vec::with_capacity(block.statements.len());
        let mut continues = true;
        for statement in &block.statements {
            let (typed, statement_continues) = self.check_statement(statement)?;
            if continues && !statement_continues {
                continues = false;
            }
            statements.push(typed);
        }
        let tail = block
            .tail
            .as_deref()
            .map(|expression| self.check_expr(expression))
            .transpose()?
            .map(Box::new);
        let ty = if continues {
            tail.as_ref()
                .map_or(CheckedType::Unit, |expression| expression.ty.clone())
        } else {
            CheckedType::Never
        };
        Ok(TypedBlock {
            span: block.span,
            statements,
            tail,
            ty,
        })
    }

    fn check_statement(
        &mut self,
        statement: &ResolvedStatement,
    ) -> Result<(TypedStatement, bool), CheckDiagnostic> {
        let origin = self.origin(statement.span);
        match &statement.kind {
            ResolvedStatementKind::Let {
                bindings,
                mutable,
                annotation,
                value,
            } => {
                if let Some(span) = mutable {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "let mut is outside the initial Checker subset",
                        self.origin(*span),
                        Vec::new(),
                    ));
                }
                let [binding] = bindings.as_slice() else {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "destructuring let is outside the initial Checker subset",
                        origin,
                        Vec::new(),
                    ));
                };
                if binding.identity.kind != EntityKind::Local {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "destructuring let is outside the initial Checker subset",
                        origin,
                        Vec::new(),
                    ));
                }
                let value = self.check_expr(value)?;
                let ty = if let Some(annotation) = annotation {
                    let annotated = self
                        .normalizer
                        .normalize(annotation, &self.function.context)?;
                    if !type_satisfies(&value.ty, &annotated) {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            format!(
                                "let annotation {} does not match value type {}",
                                display_type(&annotated),
                                display_type(&value.ty)
                            ),
                            self.origin(annotation.span),
                            vec![self.origin(value.span)],
                        ));
                    }
                    annotated
                } else {
                    value.ty.clone()
                };
                self.values.insert(binding.identity.clone(), ty.clone());
                let continues = value.ty != CheckedType::Never;
                Ok((
                    TypedStatement {
                        span: statement.span,
                        kind: TypedStatementKind::Let {
                            binding: Box::new(binding.identity.clone()),
                            ty,
                            value: Box::new(value),
                        },
                    },
                    continues,
                ))
            }
            ResolvedStatementKind::Return(value) => {
                let value = value
                    .as_ref()
                    .map(|value| self.check_expr(value))
                    .transpose()?;
                let actual = value
                    .as_ref()
                    .map_or(CheckedType::Unit, |value| value.ty.clone());
                if !type_satisfies(&actual, &self.function.return_type) {
                    let primary = value
                        .as_ref()
                        .map_or_else(|| origin.clone(), |value| self.origin(value.span));
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::ReturnMismatch,
                        format!(
                            "return has type {} but the function declares {}",
                            display_type(&actual),
                            display_type(&self.function.return_type)
                        ),
                        primary,
                        vec![self.function.return_origin.clone()],
                    ));
                }
                Ok((
                    TypedStatement {
                        span: statement.span,
                        kind: TypedStatementKind::Return(value.map(Box::new)),
                    },
                    false,
                ))
            }
            ResolvedStatementKind::Expression(expression) => {
                let expression = self.check_expr(expression)?;
                let continues = expression.ty != CheckedType::Never;
                Ok((
                    TypedStatement {
                        span: statement.span,
                        kind: TypedStatementKind::Expression(Box::new(expression)),
                    },
                    continues,
                ))
            }
            _ => Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "statement form is outside the initial Checker subset",
                origin,
                Vec::new(),
            )),
        }
    }

    fn check_expr(&mut self, expression: &ResolvedExpr) -> Result<TypedExpr, CheckDiagnostic> {
        let origin = self.origin(expression.span);
        match &expression.kind {
            ResolvedExprKind::Integer(spelling) => {
                let value = spelling
                    .parse::<u64>()
                    .ok()
                    .and_then(|value| (value <= i64::MAX as u64).then_some(value as i64));
                let Some(value) = value else {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::LiteralOutOfRange,
                        format!("integer literal `{spelling}` is outside the Int range"),
                        origin,
                        Vec::new(),
                    ));
                };
                Ok(TypedExpr {
                    span: expression.span,
                    ty: CheckedType::Int,
                    kind: TypedExprKind::Integer {
                        value,
                        literal_span: expression.span,
                    },
                })
            }
            ResolvedExprKind::Float(spelling) => {
                let value = spelling.parse::<f64>().ok();
                let Some(value) = value.filter(|value| value.is_finite()) else {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::LiteralOutOfRange,
                        format!(
                            "float literal `{spelling}` rounds outside the finite binary64 range"
                        ),
                        origin,
                        Vec::new(),
                    ));
                };
                Ok(TypedExpr {
                    span: expression.span,
                    ty: CheckedType::Float,
                    kind: TypedExprKind::Float(value.to_bits()),
                })
            }
            ResolvedExprKind::Boolean(value) => Ok(TypedExpr {
                span: expression.span,
                ty: CheckedType::Bool,
                kind: TypedExprKind::Boolean(*value),
            }),
            ResolvedExprKind::Unit => Ok(TypedExpr {
                span: expression.span,
                ty: CheckedType::Unit,
                kind: TypedExprKind::Unit,
            }),
            ResolvedExprKind::Path(reference) => self.check_value_reference(reference, origin),
            ResolvedExprKind::Parenthesized(inner) => {
                let inner = self.check_expr(inner)?;
                Ok(TypedExpr {
                    span: expression.span,
                    ty: inner.ty.clone(),
                    kind: TypedExprKind::Parenthesized(Box::new(inner)),
                })
            }
            ResolvedExprKind::Tuple(elements) => {
                let mut typed = Vec::with_capacity(elements.len());
                let mut diverges = false;
                for element in elements {
                    let element = self.check_expr(element)?;
                    diverges |= element.ty == CheckedType::Never;
                    typed.push(element);
                }
                let ty = if diverges {
                    CheckedType::Never
                } else {
                    CheckedType::Tuple(typed.iter().map(|element| element.ty.clone()).collect())
                };
                Ok(TypedExpr {
                    span: expression.span,
                    ty,
                    kind: TypedExprKind::Tuple(typed),
                })
            }
            ResolvedExprKind::Block(block) => {
                let block = self.check_block(block)?;
                Ok(TypedExpr {
                    span: expression.span,
                    ty: block.ty.clone(),
                    kind: TypedExprKind::Block(Box::new(block)),
                })
            }
            ResolvedExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => self.check_if_expression(origin, condition, then_branch, else_branch.as_deref()),
            ResolvedExprKind::Unary { operator, operand } => {
                self.check_unary_expression(origin, *operator, operand)
            }
            ResolvedExprKind::Binary {
                left,
                operator,
                right,
            } => self.check_binary_expression(origin, left, *operator, right),
            ResolvedExprKind::Call { callee, arguments } => {
                self.check_call_expression(origin, callee, arguments)
            }
            ResolvedExprKind::TupleField {
                receiver,
                index,
                origin: index_origin,
            } => self.check_tuple_field(origin, receiver, index, index_origin),
            _ => Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "expression form is outside the initial Checker subset",
                origin,
                Vec::new(),
            )),
        }
    }

    fn check_value_reference(
        &self,
        reference: &ResolvedReference,
        origin: OriginRef,
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let ResolvedReference::Exact { target, .. } = reference else {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "type-dependent value selection is outside the initial Checker subset",
                origin,
                Vec::new(),
            ));
        };
        let Some(ty) = self.values.get(target) else {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "only local and parameter value references are supported in this position",
                origin,
                entity_origin(target).into_iter().collect(),
            ));
        };
        Ok(TypedExpr {
            span: origin.span,
            ty: ty.clone(),
            kind: TypedExprKind::Reference(Box::new(target.clone())),
        })
    }

    fn check_if_expression(
        &mut self,
        origin: OriginRef,
        condition: &ResolvedExpr,
        then_branch: &ResolvedBlock,
        else_branch: Option<&ResolvedExpr>,
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let condition = self.check_expr(condition)?;
        if !type_satisfies(&condition.ty, &CheckedType::Bool) {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                format!(
                    "if condition has type {}, expected Bool",
                    display_type(&condition.ty)
                ),
                self.origin(condition.span),
                Vec::new(),
            ));
        }
        let then_branch = self.check_block(then_branch)?;
        let else_branch = else_branch
            .map(|branch| self.check_expr(branch))
            .transpose()?
            .map(Box::new);

        let branch_type = if let Some(else_branch) = &else_branch {
            join_types(&then_branch.ty, &else_branch.ty).map_err(|()| {
                source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    format!(
                        "if branches have incompatible types {} and {}",
                        display_type(&then_branch.ty),
                        display_type(&else_branch.ty)
                    ),
                    self.origin(else_branch.span),
                    vec![self.origin(then_branch.span)],
                )
            })?
        } else {
            CheckedType::Unit
        };
        let ty = if condition.ty == CheckedType::Never {
            CheckedType::Never
        } else {
            branch_type
        };
        Ok(TypedExpr {
            span: origin.span,
            ty,
            kind: TypedExprKind::If {
                condition: Box::new(condition),
                then_branch: Box::new(then_branch),
                else_branch,
            },
        })
    }

    fn check_unary_expression(
        &mut self,
        origin: OriginRef,
        operator: (Span, UnaryOperator),
        operand: &ResolvedExpr,
    ) -> Result<TypedExpr, CheckDiagnostic> {
        if operator.1 == UnaryOperator::Negate
            && let Some(literal_span) = minimum_integer_literal(operand)
        {
            return Ok(TypedExpr {
                span: origin.span,
                ty: CheckedType::Int,
                kind: TypedExprKind::Integer {
                    value: i64::MIN,
                    literal_span,
                },
            });
        }
        let operand = self.check_expr(operand)?;
        let valid = match operator.1 {
            UnaryOperator::Negate => matches!(
                operand.ty,
                CheckedType::Int | CheckedType::Float | CheckedType::Never
            ),
            UnaryOperator::Not => {
                matches!(operand.ty, CheckedType::Bool | CheckedType::Never)
            }
        };
        if !valid {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                format!(
                    "unary operator {:?} does not accept {}",
                    operator.1,
                    display_type(&operand.ty)
                ),
                self.origin(operator.0),
                vec![self.origin(operand.span)],
            ));
        }
        Ok(TypedExpr {
            span: origin.span,
            ty: operand.ty.clone(),
            kind: TypedExprKind::Unary {
                operator: operator.1,
                operand: Box::new(operand),
            },
        })
    }

    fn check_binary_expression(
        &mut self,
        origin: OriginRef,
        left: &ResolvedExpr,
        operator: (Span, BinaryOperator),
        right: &ResolvedExpr,
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let left = self.check_expr(left)?;
        let right = self.check_expr(right)?;
        let operand_type = common_non_never_type(&left.ty, &right.ty);
        let diverges = left.ty == CheckedType::Never || right.ty == CheckedType::Never;
        let (ty, comparison) = match operator.1 {
            BinaryOperator::Add
            | BinaryOperator::Subtract
            | BinaryOperator::Multiply
            | BinaryOperator::Divide
            | BinaryOperator::Remainder => {
                let valid = operand_type
                    .as_ref()
                    .is_some_and(|ty| matches!(ty, CheckedType::Int | CheckedType::Float))
                    || (left.ty == CheckedType::Never && right.ty == CheckedType::Never);
                if !valid {
                    return Err(self.binary_type_diagnostic(operator.0, &left, &right));
                }
                (
                    if diverges {
                        CheckedType::Never
                    } else {
                        operand_type.expect("normal arithmetic operands have one common type")
                    },
                    None,
                )
            }
            BinaryOperator::LogicAnd | BinaryOperator::LogicOr => {
                let valid = operand_type
                    .as_ref()
                    .is_some_and(|ty| ty == &CheckedType::Bool)
                    || (left.ty == CheckedType::Never && right.ty == CheckedType::Never);
                if !valid {
                    return Err(self.binary_type_diagnostic(operator.0, &left, &right));
                }
                (
                    if left.ty == CheckedType::Never {
                        CheckedType::Never
                    } else {
                        CheckedType::Bool
                    },
                    None,
                )
            }
            BinaryOperator::Equal | BinaryOperator::NotEqual => {
                if matches!(&operand_type, Some(CheckedType::Tuple(_))) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "tuple trait comparison is outside the initial Checker subset",
                        self.origin(operator.0),
                        Vec::new(),
                    ));
                }
                let Some(_) = operand_type.filter(is_comparable_primitive) else {
                    return Err(self.binary_type_diagnostic(operator.0, &left, &right));
                };
                let roles = &self.project.core_roles;
                (
                    if diverges {
                        CheckedType::Never
                    } else {
                        CheckedType::Bool
                    },
                    Some(Box::new(ComparisonEvidence {
                        trait_declaration: roles.partial_eq.declaration.clone(),
                        method: roles.partial_eq.method.clone(),
                        result_carriers: None,
                    })),
                )
            }
            BinaryOperator::Less
            | BinaryOperator::Greater
            | BinaryOperator::LessEqual
            | BinaryOperator::GreaterEqual => {
                if matches!(&operand_type, Some(CheckedType::Tuple(_))) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "tuple trait comparison is outside the initial Checker subset",
                        self.origin(operator.0),
                        Vec::new(),
                    ));
                }
                let Some(_) = operand_type.filter(is_comparable_primitive) else {
                    return Err(self.binary_type_diagnostic(operator.0, &left, &right));
                };
                let roles = &self.project.core_roles;
                (
                    if diverges {
                        CheckedType::Never
                    } else {
                        CheckedType::Bool
                    },
                    Some(Box::new(ComparisonEvidence {
                        trait_declaration: roles.partial_ord.declaration.clone(),
                        method: roles.partial_ord.method.clone(),
                        result_carriers: Some((
                            roles.option.declaration.clone(),
                            roles.ordering.declaration.clone(),
                        )),
                    })),
                )
            }
            BinaryOperator::RangeExclusive | BinaryOperator::RangeInclusive => {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "range expressions are outside the initial Checker subset",
                    self.origin(operator.0),
                    Vec::new(),
                ));
            }
        };
        Ok(TypedExpr {
            span: origin.span,
            ty,
            kind: TypedExprKind::Binary {
                operator: operator.1,
                left: Box::new(left),
                right: Box::new(right),
                comparison,
            },
        })
    }

    fn binary_type_diagnostic(
        &self,
        operator_span: Span,
        left: &TypedExpr,
        right: &TypedExpr,
    ) -> CheckDiagnostic {
        source_diagnostic(
            CheckDiagnosticKind::TypeMismatch,
            format!(
                "binary operands have unsupported or incompatible types {} and {}",
                display_type(&left.ty),
                display_type(&right.ty)
            ),
            self.origin(operator_span),
            vec![self.origin(left.span), self.origin(right.span)],
        )
    }

    fn check_call_expression(
        &mut self,
        origin: OriginRef,
        callee: &ResolvedExpr,
        arguments: &[ResolvedCallArgument],
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let target = direct_function_callee(callee).ok_or_else(|| {
            source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "only exact direct calls to ordinary functions are supported",
                self.origin(callee.span),
                Vec::new(),
            )
        })?;
        let signature = self.headers.get(&target).ok_or_else(|| {
            source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "the direct callee is not a supported ordinary function declaration",
                self.origin(callee.span),
                entity_origin(&target).into_iter().collect(),
            )
        })?;
        if arguments.len() != signature.parameters.len() {
            return Err(source_diagnostic(
                CheckDiagnosticKind::CallMismatch,
                format!(
                    "direct call supplies {} argument(s) but the callee expects {}",
                    arguments.len(),
                    signature.parameters.len()
                ),
                origin,
                vec![signature.origin.clone()],
            ));
        }

        let mut typed_arguments = Vec::with_capacity(arguments.len());
        let mut diverges = false;
        for (index, (argument, parameter)) in
            arguments.iter().zip(&signature.parameters).enumerate()
        {
            let ResolvedCallArgument::Expression(argument) = argument else {
                let span = match argument {
                    ResolvedCallArgument::Mode { span, .. } => *span,
                    ResolvedCallArgument::Expression(_) => unreachable!(),
                };
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "call-site mut/move assertions are outside the initial Checker subset",
                    self.origin(span),
                    Vec::new(),
                ));
            };
            let argument = self.check_expr(argument)?;
            if !type_satisfies(&argument.ty, &parameter.ty) {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::CallMismatch,
                    format!(
                        "argument {index} has type {} but the callee expects {}",
                        display_type(&argument.ty),
                        display_type(&parameter.ty)
                    ),
                    self.origin(argument.span),
                    vec![parameter.type_origin.clone(), signature.origin.clone()],
                ));
            }
            diverges |= argument.ty == CheckedType::Never;
            typed_arguments.push(argument);
        }
        let return_type = signature.return_type.clone();
        let ty = if diverges || return_type == CheckedType::Never {
            CheckedType::Never
        } else {
            return_type
        };
        Ok(TypedExpr {
            span: origin.span,
            ty,
            kind: TypedExprKind::Call {
                callee: Box::new(target),
                arguments: typed_arguments,
                parameter_modes: signature
                    .parameters
                    .iter()
                    .map(|parameter| {
                        parameter
                            .mode
                            .as_ref()
                            .expect("direct callees have finalized parameter modes")
                            .value
                    })
                    .collect(),
            },
        })
    }

    fn check_tuple_field(
        &mut self,
        origin: OriginRef,
        receiver: &ResolvedExpr,
        index: &str,
        index_origin: &OriginRef,
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let receiver = self.check_expr(receiver)?;
        let index = index
            .parse::<u64>()
            .ok()
            .and_then(|index| usize::try_from(index).ok())
            .ok_or_else(|| {
                source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    "tuple projection index is outside the platform-independent index range",
                    index_origin.clone(),
                    Vec::new(),
                )
            })?;
        let ty = match &receiver.ty {
            CheckedType::Tuple(elements) => elements.get(index).cloned().ok_or_else(|| {
                source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    format!(
                        "tuple projection index {index} is outside a {}-element tuple",
                        elements.len()
                    ),
                    index_origin.clone(),
                    vec![self.origin(receiver.span)],
                )
            })?,
            CheckedType::Never => CheckedType::Never,
            other => {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    format!(
                        "tuple projection requires a tuple, found {}",
                        display_type(other)
                    ),
                    index_origin.clone(),
                    vec![self.origin(receiver.span)],
                ));
            }
        };
        Ok(TypedExpr {
            span: origin.span,
            ty,
            kind: TypedExprKind::TupleField {
                receiver: Box::new(receiver),
                index,
            },
        })
    }
}

fn minimum_integer_literal(expression: &ResolvedExpr) -> Option<Span> {
    match &expression.kind {
        ResolvedExprKind::Parenthesized(inner) => minimum_integer_literal(inner),
        ResolvedExprKind::Integer(spelling)
            if spelling
                .parse::<u128>()
                .is_ok_and(|value| value == (i64::MAX as u128) + 1) =>
        {
            Some(expression.span)
        }
        _ => None,
    }
}

fn join_types(left: &CheckedType, right: &CheckedType) -> Result<CheckedType, ()> {
    if left == &CheckedType::Never {
        Ok(right.clone())
    } else if right == &CheckedType::Never || left == right {
        Ok(left.clone())
    } else if let (CheckedType::Tuple(left), CheckedType::Tuple(right)) = (left, right)
        && left.len() == right.len()
    {
        left.iter()
            .zip(right)
            .map(|(left, right)| join_types(left, right))
            .collect::<Result<Vec<_>, _>>()
            .map(CheckedType::Tuple)
    } else {
        Err(())
    }
}

fn common_non_never_type(left: &CheckedType, right: &CheckedType) -> Option<CheckedType> {
    join_types(left, right)
        .ok()
        .filter(|ty| ty != &CheckedType::Never)
}

fn is_comparable_primitive(ty: &CheckedType) -> bool {
    matches!(
        ty,
        CheckedType::Int | CheckedType::Float | CheckedType::Bool | CheckedType::Unit
    )
}

fn direct_function_callee(expression: &ResolvedExpr) -> Option<EntityId> {
    match &expression.kind {
        ResolvedExprKind::Parenthesized(inner) => direct_function_callee(inner),
        ResolvedExprKind::Path(ResolvedReference::Exact { target, .. })
            if target.kind == EntityKind::Function =>
        {
            Some(target.clone())
        }
        _ => None,
    }
}

#[cfg(test)]
mod checking_tests {
    use super::*;
    use crate::project::LibrarySources;

    const APP: LibraryId = LibraryId(0);
    const CORE: LibraryId = LibraryId(u32::MAX);
    const CORE_SOURCE: &str = include_str!("../../../core/root.vorton");

    fn sources(root: &str) -> ProjectSources {
        ProjectSources {
            entry: APP,
            core: CORE,
            libraries: BTreeMap::from([
                (
                    APP,
                    LibrarySources {
                        root: root.to_owned(),
                        modules: BTreeMap::new(),
                        dependencies: BTreeMap::from([("vorton_core".to_owned(), CORE)]),
                    },
                ),
                (
                    CORE,
                    LibrarySources {
                        root: CORE_SOURCE.to_owned(),
                        modules: BTreeMap::new(),
                        dependencies: BTreeMap::new(),
                    },
                ),
            ]),
        }
    }

    fn comparison<'a>(checked: &'a CheckedProject, name: &str) -> &'a ComparisonEvidence {
        let function = checked
            .functions
            .values()
            .find(|function| function.identity.name == name)
            .expect("comparison function");
        let TypedExprKind::Binary {
            comparison: Some(evidence),
            ..
        } = &function.body.tail.as_deref().expect("comparison tail").kind
        else {
            panic!("comparison body retains evidence")
        };
        evidence
    }

    #[test]
    fn opaque_result_retains_real_typed_literal_callee_mode_and_origin_facts() {
        let source = "type Number = Int; \
                      fn callee(value: move Number) -> Number { value } \
                      fn caller() -> Number { callee(-((9223372036854775808))) }";
        let checked = check_project(
            &sources(source),
            &BTreeMap::from([("unused".to_owned(), LibraryId(99))]),
            Vec::new(),
        )
        .expect("supported source checks");
        assert!(
            checked.owners.is_empty(),
            "unused owner mappings are not selected"
        );
        assert_eq!(checked.aliases.len(), 1);
        assert!(checked.aliases.values().all(|ty| ty == &CheckedType::Int));

        let callee = checked
            .functions
            .values()
            .find(|function| function.identity.name == "callee")
            .expect("callee fact");
        let caller = checked
            .functions
            .values()
            .find(|function| function.identity.name == "caller")
            .expect("caller fact");
        assert!(matches!(callee.effect, CheckedEffect::Pure));
        assert_eq!(callee.parameters[0].mode, ParameterMode::Move);
        assert_eq!(callee.parameters[0].ty, CheckedType::Int);

        let tail = caller.body.tail.as_deref().expect("caller tail");
        let TypedExprKind::Call {
            callee: exact_callee,
            arguments,
            parameter_modes,
        } = &tail.kind
        else {
            panic!("caller tail should be a typed direct call")
        };
        assert_eq!(exact_callee.as_ref(), &callee.identity);
        assert_eq!(parameter_modes, &[ParameterMode::Move]);
        assert_eq!(arguments[0].ty, CheckedType::Int);
        assert!(matches!(
            &arguments[0].kind,
            TypedExprKind::Integer { value, .. } if *value == i64::MIN
        ));
        let TypedExprKind::Integer { literal_span, .. } = &arguments[0].kind else {
            unreachable!()
        };
        assert_eq!(
            &source[literal_span.start..literal_span.end],
            "9223372036854775808"
        );
        assert_eq!(caller.origin.library, APP);
        assert_eq!(caller.return_type, CheckedType::Int);
    }

    #[test]
    fn opaque_result_retains_normalized_contract_selections_and_exact_target() {
        let contract = crate::decode_contract(
            br#"{
                "format":"vorton.contract",
                "format_version":1,
                "semantics_version":"0.1",
                "owner":"app",
                "records":[{
                    "target":{"tag":"declaration","declaration":{"library":{"tag":"self"},"path":["expose"],"kind":"function"}},
                    "set":{
                        "parameter_types":[{"parameter":{"tag":"position","index":0},"type":{"tag":"primitive","name":"Int"}}],
                        "return_type":{"tag":"primitive","name":"Int"},
                        "parameter_modes":[{"parameter":{"tag":"position","index":0},"mode":{"tag":"fixed","mode":"move"}}],
                        "effect_upper":[],
                        "generic_requirements":[]
                    }
                }]
            }"#,
        )
        .expect("contract structure");
        let checked = check_project(
            &sources("pub fn expose(value: Int) -> Int { value }"),
            &BTreeMap::from([("app".to_owned(), APP)]),
            vec![contract],
        )
        .expect("contract closes the public parameter mode before body checking");

        let function = checked
            .functions
            .values()
            .find(|function| function.identity.name == "expose")
            .expect("checked expose function");
        assert_eq!(function.parameters[0].mode, ParameterMode::Move);
        assert_eq!(checked.contract_selections.parameter_types.len(), 1);
        assert_eq!(checked.contract_selections.return_types.len(), 1);
        assert_eq!(checked.contract_selections.parameter_modes.len(), 1);
        assert_eq!(checked.contract_selections.effect_upper.len(), 1);
        assert_eq!(checked.contract_selections.generic_requirements.len(), 1);
        assert!(
            checked
                .contract_selections
                .return_types
                .contains_key(&function.identity)
        );
    }

    #[test]
    fn primitive_comparisons_retain_the_actual_core_method_and_carrier_identities() {
        let checked = check_project(
            &sources(
                "fn equal() -> Bool { 1 == 1 } \
                 fn ordered() -> Bool { 1 < 2 }",
            ),
            &BTreeMap::new(),
            Vec::new(),
        )
        .expect("primitive comparisons check");
        let roles = &checked.prepared.0.core_roles;

        let equality = comparison(&checked, "equal");
        assert_eq!(equality.trait_declaration, roles.partial_eq.declaration);
        assert_eq!(equality.method, roles.partial_eq.method);
        assert!(equality.result_carriers.is_none());

        let ordering = comparison(&checked, "ordered");
        assert_eq!(ordering.trait_declaration, roles.partial_ord.declaration);
        assert_eq!(ordering.method, roles.partial_ord.method);
        assert_eq!(
            ordering.result_carriers.as_ref(),
            Some(&(
                roles.option.declaration.clone(),
                roles.ordering.declaration.clone()
            ))
        );
    }
}
