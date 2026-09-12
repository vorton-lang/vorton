use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt;

mod selection;
use selection::*;
mod calls;
use calls::*;
mod effects;
use effects::*;
mod callbacks;
use callbacks::*;
mod contract_input;
use contract_input::*;

use crate::ast::{BinaryOperator, ParameterMode, Span, UnaryOperator};
use crate::contract;
use crate::contract::ContractDocument;
use crate::project::{
    EntityId, EntityKind, EntityShape, EntitySite, LibraryId, ModuleRef, Namespace, OriginRef,
    ProjectDiagnostic, ProjectDiagnosticKind, ProjectSources, ResolvedBlock, ResolvedCallArgument,
    ResolvedConstructEntry, ResolvedDeclaration, ResolvedDeclarationKind, ResolvedEffectSet,
    ResolvedExpr, ResolvedExprKind, ResolvedNamedType, ResolvedParameterAnnotation,
    ResolvedProject, ResolvedReference, ResolvedReturnAnnotation, ResolvedSelection,
    ResolvedStatement, ResolvedStatementKind, ResolvedType, ResolvedTypeArgument, ResolvedTypeKind,
    ResolvedVariantFields, SourceRef, SupertraitTargetKind,
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
/// closed callable schemes, normalized nominal definitions and actuals, typed
/// construction and field identities, call mappings, parameter
/// conventions, whole-binding use facts, effect rows, interpreted
/// literals, exact callees and dictionaries, type/effect actual mappings, and one
/// typed body plus whole-value cleanup obligations for every checked callable.
/// It is not the complete 0.1 interface, a query surface, or final `TypedHIR`.
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
    nominals: BTreeMap<EntityId, NominalDefinition>,
    selection: TraitSelection,
    signatures: BTreeMap<EntityId, CallableScheme>,
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

/// Stable high-level categories for the current Checker surface.
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
    let mut inference = TypeInference::default();
    let mut normalizer = SourceTypeNormalizer::new(project);
    normalizer.prepare_selection()?;
    normalizer.validate_implementations()?;
    prepare_contract_bound_lookup(project, owners, &documents, &mut normalizer)?;
    let public_exports = actual_public_exports(project);
    let (function_order, mut headers) =
        collect_supported_headers(project, &mut normalizer, &mut inference, &public_exports)?;
    let contract_selections =
        apply_contract_documents(project, owners, &documents, &mut headers, &normalizer)?;
    for ((identity, index), (ty, _)) in &contract_selections.parameter_types {
        if let CheckedType::Infer(variable) = &headers[identity].parameters[*index].ty {
            inference.receiver_hints.insert(*variable, ty.clone());
        }
    }
    let signatures = headers
        .iter()
        .filter_map(|(identity, header)| header.body.is_none().then_some(identity.clone()))
        .collect::<Vec<_>>();
    apply_contract_type_constraints(
        &signatures,
        &mut headers,
        &contract_selections,
        &mut inference,
    )?;
    normalizer.conform_methods(&mut headers, &mut inference)?;
    normalizer.normalize_header_types(&mut headers, &inference)?;
    validate_method_effect_contracts(&headers, &inference)?;
    normalizer.validate_surfaces(&headers, &public_exports)?;
    normalizer.validate_declaration_formations(&headers)?;
    for header in headers.values() {
        for parameter in &header.parameters {
            if parameter.callable_use {
                normalizer
                    .shared_callable(
                        &parameter.ty,
                        &header.requirements,
                        parameter.type_origin.clone(),
                    )
                    .map_err(|mut diagnostic| {
                        diagnostic.kind = CheckDiagnosticKind::Unsupported;
                        diagnostic.message =
                            "callable_use requires shared Fn evidence in the declared input domain"
                                .to_owned();
                        diagnostic
                    })?;
            }
        }
    }
    validate_public_inputs(&function_order, &headers, &contract_selections)?;

    let mut drafts = BTreeMap::new();
    let mut obligations = Vec::new();
    for identity in &function_order {
        normalizer.contract_scope = Some(identity.clone());
        let header = &headers[identity];
        let mut checker = BodyChecker::new(
            project,
            BodyEnvironment { headers: &headers },
            header,
            &mut normalizer,
            &mut inference,
            &mut obligations,
        );
        let body = checker.check_block(header.body.as_ref().expect("body callable"))?;
        if header.source_return_explicit {
            inference
                .satisfy(&body.ty, &header.return_type)
                .map_err(|failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::ReturnMismatch,
                        display_unification_failure(&failure),
                        header.context.origin(body.span),
                        vec![header.origin.clone()],
                    )
                })?;
        }
        drafts.insert(identity.clone(), body);
    }
    let mut schemes = BTreeMap::new();
    for (identity, header) in &headers {
        if header.body.is_some() {
            continue;
        }
        let generalized = function_generalization(identity, header, &mut inference);
        let quantified = generalized
            .bindings
            .iter()
            .map(|(formal, _)| formal.clone())
            .collect::<Vec<_>>();
        schemes.insert(
            identity.clone(),
            CallableScheme {
                instantiation_formals: quantified.iter().cloned().collect(),
                quantified,
                parameters: header
                    .parameters
                    .iter()
                    .map(|parameter| parameter.ty.clone())
                    .collect(),
                return_type: header.return_type.clone(),
                requirements: header.requirements.clone(),
                effect_formals: header.effect_formals.clone(),
                effect: normalizer.signature_effect(header),
                shapes: header.shapes.clone(),
                stored_types: Vec::new(),
            },
        );
    }
    let mut closed_bodies = BTreeMap::new();
    let mut closed_cleanups = BTreeMap::new();
    let mut effect_equations = BTreeMap::new();
    let mut effect_dependencies = BTreeMap::<EntityId, BTreeSet<EntityId>>::new();
    let mut remaining = function_order.clone();
    while !remaining.is_empty() {
        let group = function_binding_groups(&remaining, &drafts, &effect_dependencies).remove(0);
        let members = group.iter().cloned().collect::<BTreeSet<_>>();
        let mut regroup = false;
        let mut group_effects = None;
        loop {
            let mut changed = false;
            let mut pending = None;
            validate_type_obligations(
                &mut obligations,
                &members,
                true,
                &mut inference,
                &normalizer,
                &headers,
            )?;
            for identity in &group {
                let header = &headers[identity];
                let mut binder = CallBinder {
                    headers: &headers,
                    schemes: &schemes,
                    group: &members,
                    function: header,
                    normalizer: &normalizer,
                    inference: &mut inference,
                    changed: false,
                    pending: None,
                    dependencies: BTreeSet::new(),
                };
                binder.block(drafts.get_mut(identity).expect("one draft per callable"))?;
                changed |= binder.changed;
                pending = pending.or(binder.pending);
                if !binder.dependencies.is_empty() {
                    effect_dependencies
                        .entry(identity.clone())
                        .or_default()
                        .extend(binder.dependencies);
                    regroup = true;
                }
            }
            if regroup {
                break;
            }
            if group.iter().any(|identity| {
                call_dependencies(&drafts[identity])
                    .iter()
                    .any(|callee| !members.contains(callee) && !schemes.contains_key(callee))
            }) {
                regroup = true;
                break;
            }
            if pending.is_none() {
                for identity in &group {
                    let header = &headers[identity];
                    inference
                        .satisfy(&drafts[identity].ty, &header.return_type)
                        .map_err(|failure| {
                            source_diagnostic(
                                CheckDiagnosticKind::ReturnMismatch,
                                display_unification_failure(&failure),
                                header.origin.clone(),
                                Vec::new(),
                            )
                        })?;
                    effect_equations
                        .entry(identity.clone())
                        .or_insert_with(|| EffectEquation::from_body(&drafts[identity]));
                }
                let closure = EffectEnvironment {
                    normalizer: &normalizer,
                    headers: &headers,
                    schemes: &schemes,
                }
                .close_group(&group, &effect_equations, &mut inference)?;
                if !closure.inferences.is_empty() {
                    for identity in &group {
                        let header = headers.get_mut(identity).expect("unpublished header");
                        for shape in &mut header.shapes {
                            shape.shape.effect = shape
                                .shape
                                .effect
                                .instantiate(&BTreeMap::new(), &closure.inferences);
                        }
                        header.effect_upper = header
                            .effect_upper
                            .as_ref()
                            .map(|row| row.instantiate(&BTreeMap::new(), &closure.inferences));
                        header
                            .inferable_effects
                            .retain(|formal| !closure.inferences.contains_key(formal));
                        effect_equations
                            .get_mut(identity)
                            .expect("one equation")
                            .substitute(&closure.inferences);
                        substitute_body_effects(
                            drafts.get_mut(identity).expect("one draft"),
                            &closure.inferences,
                        );
                    }
                    continue;
                }
                if !closure.dependencies.is_empty() {
                    for (identity, dependencies) in closure.dependencies {
                        effect_dependencies
                            .entry(identity)
                            .or_default()
                            .extend(dependencies);
                    }
                    regroup = true;
                } else {
                    group_effects = Some(closure.rows);
                }
                break;
            }
            let before = inference.substitutions.len();
            validate_type_obligations(
                &mut obligations,
                &members,
                true,
                &mut inference,
                &normalizer,
                &headers,
            )?;
            changed |= before != inference.substitutions.len();
            if !changed {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    "method selection proof incomplete: receiver dependencies remain undetermined",
                    pending.expect("pending call"),
                    Vec::new(),
                ));
            }
        }
        if regroup {
            continue;
        }
        let group_effects =
            group_effects.expect("effect dependencies are closed before publication");
        let mut group_drafts = group
            .iter()
            .map(|identity| {
                (
                    identity.clone(),
                    drafts.remove(identity).expect("one draft per callable"),
                )
            })
            .collect::<BTreeMap<_, _>>();
        for identity in &group {
            let header = &headers[identity];
            let body = &group_drafts[identity];
            inference
                .satisfy(&body.ty, &header.return_type)
                .map_err(|failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::ReturnMismatch,
                        format!(
                            "function body cannot satisfy its return type: {}",
                            display_unification_failure(&failure)
                        ),
                        header.context.origin(body.span),
                        vec![origin_as_source(&header.return_origin, &header.origin)],
                    )
                })?;
        }
        validate_type_obligations(
            &mut obligations,
            &members,
            false,
            &mut inference,
            &normalizer,
            &headers,
        )?;
        apply_contract_type_constraints(
            &group,
            &mut headers,
            &contract_selections,
            &mut inference,
        )?;
        validate_contracted_inference_is_explicit(
            &group,
            &headers,
            &contract_selections,
            &inference,
        )?;

        infer_parameter_modes(&group, &mut headers, &group_drafts, &inference)?;
        for identity in &group {
            EffectEnvironment {
                normalizer: &normalizer,
                headers: &headers,
                schemes: &schemes,
            }
            .populate_calls(
                group_drafts.get_mut(identity).expect("group body"),
                &headers[identity],
                &group_effects,
                &mut inference,
            )?;
        }
        let mut group_cleanups =
            validate_whole_value_use(&group, &headers, &mut group_drafts, &inference)?;
        let mut storage_uses = group
            .iter()
            .map(|identity| {
                (
                    identity.clone(),
                    collect_storage_uses(&group_drafts[identity], &headers[identity].context),
                )
            })
            .collect::<BTreeMap<_, _>>();
        propagate_storage_uses(
            &group,
            &effect_equations,
            &schemes,
            &mut storage_uses,
            &inference,
        );
        for identity in &group {
            let header = &headers[identity];
            let requirements = header
                .requirements
                .iter()
                .map(|requirement| requirement.map_types(|ty| inference.canonical(ty)))
                .collect::<Vec<_>>();
            if normalizer.callable_type(
                &inference.canonical(&header.return_type),
                &requirements,
                &header.origin,
            ) {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "general callable value returns are outside this Checker profile",
                    header.origin.clone(),
                    Vec::new(),
                ));
            }
            for stored in &storage_uses[identity] {
                if normalizer.callable_type(
                    &inference.canonical(&stored.ty),
                    &requirements,
                    &stored.origin,
                ) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "callable storage or failure payload requires the later escape/resource checker",
                        stored.origin.clone(),
                        vec![header.origin.clone()],
                    ));
                }
            }
        }
        for (identity, cleanups) in &group_cleanups {
            effect_equations
                .get_mut(identity)
                .expect("one effect equation per body")
                .rows
                .extend(cleanups.iter().map(|cleanup| (cleanup.effect(), false)));
        }
        let effect_closure = EffectEnvironment {
            normalizer: &normalizer,
            headers: &headers,
            schemes: &schemes,
        }
        .close_group(&group, &effect_equations, &mut inference)?;
        if !effect_closure.dependencies.is_empty() {
            return Err(effect_diagnostic(
                "cleanup introduced an unresolved effect dependency",
                CheckOrigin::Source(headers[&group[0]].origin.clone()),
            ));
        }
        let group_effects = effect_closure.rows;
        for identity in &group {
            EffectEnvironment {
                normalizer: &normalizer,
                headers: &headers,
                schemes: &schemes,
            }
            .populate_calls(
                group_drafts.get_mut(identity).expect("group body"),
                &headers[identity],
                &group_effects,
                &mut inference,
            )?;
        }

        // Close demands in the shared monotype graph before introducing any
        // generalized scheme binders. Calls refer to exact group bindings.
        let mut requirements = BTreeMap::new();
        let mut callers: BTreeMap<EntityId, Vec<(EntityId, Span)>> = BTreeMap::new();
        for identity in &group {
            let header = &headers[identity];
            let body = &group_drafts[identity];
            let mut variables = BTreeSet::new();
            let mut formals = BTreeSet::new();
            for ty in header.interface_types() {
                collect_inference_inputs(&inference, ty, &mut variables, &mut formals);
            }
            let mut scope = type_dependencies(&inference, &variables, &formals);
            scope.extend(
                header
                    .declared_formals
                    .iter()
                    .map(|formal| CheckedType::Formal(Box::new(inference.formal_root(formal)))),
            );
            let mut recursive_calls = Vec::new();
            collect_typed_variables(
                body,
                &inference,
                &mut variables,
                &mut formals,
                &mut recursive_calls,
            );
            let required = type_dependencies(&inference, &variables, &formals);
            if !required.is_subset(&scope) {
                return Err(unbound_body_type(
                    header.context.origin(body.span),
                    Vec::new(),
                ));
            }
            requirements.insert(identity.clone(), GroupTypeRequirements { scope, required });
            for (callee, span) in recursive_calls {
                callers
                    .entry(callee)
                    .or_default()
                    .push((identity.clone(), span));
            }
        }

        // Propagate each actual type demand to every recursive caller. The
        // finite worklist contains shared inference identities, not new types.
        let mut pending = requirements
            .iter()
            .flat_map(|(identity, member)| {
                member
                    .required
                    .iter()
                    .map(|shared| (identity.clone(), shared.clone()))
            })
            .collect::<VecDeque<_>>();
        while let Some((callee, shared)) = pending.pop_front() {
            for (caller, span) in callers.get(&callee).into_iter().flatten() {
                let member = requirements
                    .get_mut(caller)
                    .expect("recursive caller is in the group");
                if !member.scope.contains(&shared) {
                    return Err(unbound_body_type(
                        headers[caller].context.origin(*span),
                        vec![headers[&callee].origin.clone()],
                    ));
                }
                if member.required.insert(shared.clone()) {
                    pending.push_back((caller.clone(), shared.clone()));
                }
            }
        }

        // Generalize the now-closed group. Keep each binder's original shared
        // type identity so recursive actuals are never inferred from final types.
        let mut group_members = BTreeMap::new();
        for identity in &group {
            let generalization =
                function_generalization(identity, &headers[identity], &mut inference);
            let required = requirements[identity]
                .required
                .iter()
                .map(|shared| {
                    generalization
                        .formal_for(shared, &inference)
                        .expect("every closed group demand has a binder in the function scope")
                        .clone()
                })
                .collect();
            group_members.insert(
                identity.clone(),
                GroupMember {
                    generalization,
                    required,
                },
            );
        }

        let mut group_schemes = BTreeMap::new();
        let mut group_bodies = BTreeMap::new();
        for identity in &group {
            let header = &headers[identity];
            let member = &group_members[identity];
            let closure = BodyClosure {
                inference: &inference,
                function: &member.generalization,
                group: &group_members,
                obligations: &obligations,
            };
            closed_cleanups.insert(
                identity.clone(),
                group_cleanups
                    .remove(identity)
                    .expect("one cleanup ledger per body")
                    .into_iter()
                    .map(|cleanup| cleanup.close(&closure))
                    .collect::<Vec<_>>(),
            );
            group_schemes.insert(
                identity.clone(),
                CallableScheme {
                    quantified: member
                        .generalization
                        .bindings
                        .iter()
                        .map(|(formal, _)| formal.clone())
                        .collect(),
                    instantiation_formals: member.required.clone(),
                    parameters: header
                        .parameters
                        .iter()
                        .map(|parameter| closure.close_type(&parameter.ty))
                        .collect(),
                    return_type: closure.close_type(&header.return_type),
                    requirements: header
                        .requirements
                        .iter()
                        .map(|requirement| requirement.map_types(|ty| closure.close_type(ty)))
                        .collect(),
                    effect_formals: header.effect_formals.clone(),
                    effect: group_effects[identity].map_types(&mut |ty| closure.close_type(ty)),
                    shapes: header
                        .shapes
                        .iter()
                        .map(|shape| ShapeRequirement {
                            subject: closure.close_type(&shape.subject),
                            shape: CallableShape {
                                parameters: shape
                                    .shape
                                    .parameters
                                    .iter()
                                    .map(|(ty, mode)| (closure.close_type(ty), *mode))
                                    .collect(),
                                return_type: closure.close_type(&shape.shape.return_type),
                                effect: shape
                                    .shape
                                    .effect
                                    .map_types(&mut |ty| closure.close_type(ty)),
                            },
                            origin: shape.origin.clone(),
                            inferred_row: shape.inferred_row.clone(),
                        })
                        .collect(),
                    stored_types: storage_uses[identity]
                        .iter()
                        .map(|stored| StoredType {
                            ty: closure.close_type(&stored.ty),
                            origin: stored.origin.clone(),
                        })
                        .collect(),
                },
            );
            group_bodies.insert(
                identity.clone(),
                close_typed_block(
                    group_drafts
                        .remove(identity)
                        .expect("every member has one typed draft"),
                    &closure,
                ),
            );
        }

        for (identity, scheme) in &group_schemes {
            let types = scheme
                .parameters
                .iter()
                .cloned()
                .chain(std::iter::once(scheme.return_type.clone()))
                .chain(scheme.effect.types().into_iter().cloned())
                .collect::<Vec<_>>();
            normalizer.validate_formation(
                &types,
                &scheme.requirements,
                CheckOrigin::Source(headers[identity].origin.clone()),
            )?;
            let header = headers
                .get_mut(identity)
                .expect("a closed group scheme retains its source header");
            if header.public_export {
                normalizer.validate_effect_visibility(
                    &scheme.effect,
                    &public_exports,
                    &header.origin,
                )?;
                for ty in scheme
                    .parameters
                    .iter()
                    .chain(std::iter::once(&scheme.return_type))
                {
                    validate_public_nominals(ty, &public_exports, &header.origin)?;
                }
            }
            for (parameter, closed) in header.parameters.iter_mut().zip(&scheme.parameters) {
                parameter.ty = closed.clone();
            }
            header.return_type = scheme.return_type.clone();
        }
        schemes.extend(group_schemes);
        closed_bodies.extend(group_bodies);
        remaining.retain(|identity| !members.contains(identity));
    }

    let mut functions = BTreeMap::new();
    for identity in function_order {
        let header = headers
            .get(&identity)
            .expect("source-ordered supported function remains indexed");
        let scheme = schemes
            .remove(&identity)
            .expect("every checked function has one published callable scheme");
        let body = closed_bodies
            .remove(&identity)
            .expect("every checked function has one closed typed body");
        let cleanups = closed_cleanups
            .remove(&identity)
            .expect("closed cleanup obligations");
        functions.insert(
            identity.clone(),
            CheckedFunction {
                identity,
                origin: header.origin.clone(),
                parameters: header
                    .parameters
                    .iter()
                    .zip(&scheme.parameters)
                    .map(|(parameter, ty)| CheckedParameter {
                        binding: parameter.binding.clone(),
                        ty: ty.clone(),
                        mode: parameter
                            .mode
                            .as_ref()
                            .expect("parameter modes are finalized after typed drafts close")
                            .value,
                        callable_use: parameter.callable_use,
                    })
                    .collect(),
                scheme: scheme.quantified,
                instantiation_formals: scheme.instantiation_formals,
                effect_formals: scheme.effect_formals,
                shapes: scheme.shapes,
                stored_types: scheme.stored_types,
                return_type: scheme.return_type,
                requirements: scheme.requirements,
                effect: scheme.effect,
                cleanups,
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
    let nominals = std::mem::take(&mut normalizer.nominals);
    let selection = std::mem::take(&mut normalizer.selection);
    drop(normalizer);
    Ok(CheckedProject {
        prepared,
        owners: selected_owners,
        documents,
        contract_selections,
        aliases,
        nominals,
        selection,
        signatures: schemes,
        functions,
    })
}

fn origin_as_source(origin: &CheckOrigin, fallback: &OriginRef) -> OriginRef {
    match origin {
        CheckOrigin::Source(origin) => origin.clone(),
        CheckOrigin::Contract { .. } => fallback.clone(),
    }
}

fn display_unification_failure(failure: &UnificationFailure) -> String {
    match failure {
        UnificationFailure::Mismatch(left, right) => format!(
            "{} and {} are incompatible",
            display_type(left),
            display_type(right)
        ),
        UnificationFailure::Infinite(variable, ty) => format!(
            "?{} would contain itself through {}",
            variable.0,
            display_type(ty)
        ),
    }
}

#[derive(Clone)]
struct CallableScheme {
    quantified: Vec<TypeFormal>,
    // Vacuous declaration binders remain part of the public scheme, but no
    // parameter, result or body consumes an actual for them at a call site.
    instantiation_formals: BTreeSet<TypeFormal>,
    parameters: Vec<CheckedType>,
    return_type: CheckedType,
    requirements: Vec<Requirement>,
    effect_formals: Vec<EffectFormal>,
    effect: EffectRow,
    shapes: Vec<ShapeRequirement>,
    stored_types: Vec<StoredType>,
}

fn instantiate_type(
    ty: &CheckedType,
    replacements: &BTreeMap<TypeFormal, CheckedType>,
) -> CheckedType {
    match ty {
        CheckedType::Function(item) => CheckedType::Function(Box::new(
            item.map_types(|ty| instantiate_type(ty, replacements)),
        )),
        CheckedType::Formal(formal) => replacements
            .get(formal.as_ref())
            .cloned()
            .unwrap_or_else(|| ty.clone()),
        CheckedType::Tuple(elements) => CheckedType::Tuple(
            elements
                .iter()
                .map(|element| instantiate_type(element, replacements))
                .collect(),
        ),
        CheckedType::Nominal(nominal) => CheckedType::Nominal(Box::new(NominalType {
            declaration: nominal.declaration.clone(),
            arguments: nominal
                .arguments
                .iter()
                .map(|ty| instantiate_type(ty, replacements))
                .collect(),
        })),
        CheckedType::Projection(projection) => CheckedType::Projection(Box::new(
            projection.map_types(|ty| instantiate_type(ty, replacements)),
        )),
        _ => ty.clone(),
    }
}

struct FunctionGeneralization {
    // Forward receipt created when each scheme binder is introduced. The source
    // is the shared inference identity, not a reconstructed finalized type.
    bindings: Vec<(TypeFormal, CheckedType)>,
}

impl FunctionGeneralization {
    fn formal_for(&self, shared: &CheckedType, inference: &TypeInference) -> Option<&TypeFormal> {
        self.bindings.iter().find_map(|(formal, source)| {
            inferred_types_equal(shared, source, inference).then_some(formal)
        })
    }
}

struct GroupTypeRequirements {
    scope: BTreeSet<CheckedType>,
    required: BTreeSet<CheckedType>,
}

struct GroupMember {
    generalization: FunctionGeneralization,
    required: BTreeSet<TypeFormal>,
}

fn type_dependencies(
    inference: &TypeInference,
    variables: &BTreeSet<TypeVariable>,
    formals: &BTreeSet<TypeFormal>,
) -> BTreeSet<CheckedType> {
    variables
        .iter()
        .copied()
        .map(CheckedType::Infer)
        .chain(
            formals
                .iter()
                .map(|formal| CheckedType::Formal(Box::new(inference.formal_root(formal)))),
        )
        .collect()
}

fn unbound_body_type(origin: OriginRef, related: Vec<OriginRef>) -> CheckDiagnostic {
    source_diagnostic(
        CheckDiagnosticKind::Unsupported,
        "a body type cannot be inferred in this callable scope; unresolved or foreign call actuals cannot add callable type parameters",
        origin,
        related,
    )
}

fn function_generalization(
    identity: &EntityId,
    header: &FunctionHeader,
    inference: &mut TypeInference,
) -> FunctionGeneralization {
    let mut variables = BTreeSet::new();
    let mut referenced_formals = BTreeSet::new();
    for ty in header.interface_types() {
        collect_inference_inputs(inference, ty, &mut variables, &mut referenced_formals);
    }
    let mut generalized = FunctionGeneralization {
        bindings: header
            .outer_formals
            .iter()
            .chain(&header.declared_formals)
            .map(|formal| {
                (
                    formal.clone(),
                    CheckedType::Formal(Box::new(formal.clone())),
                )
            })
            .collect(),
    };
    for variable in variables {
        let ordinal = generalized.bindings.len();
        generalized.bindings.push((
            TypeFormal {
                owner: identity.clone(),
                ordinal,
                name: format!("T{ordinal}"),
            },
            CheckedType::Infer(variable),
        ));
    }
    let foreign_roots = referenced_formals
        .into_iter()
        .map(|formal| inference.formal_root(&formal))
        .collect::<BTreeSet<_>>();
    for foreign in foreign_roots {
        let shared = CheckedType::Formal(Box::new(foreign.clone()));
        if generalized.formal_for(&shared, inference).is_some() {
            continue;
        }
        let ordinal = generalized.bindings.len();
        let local = TypeFormal {
            owner: identity.clone(),
            ordinal,
            name: format!("T{ordinal}"),
        };
        inference
            .unify_formals(foreign, local.clone())
            .expect("a foreign signature formal has no binder owned by this function");
        generalized.bindings.push((local, shared));
    }
    generalized
}

fn collect_inference_inputs(
    inference: &TypeInference,
    ty: &CheckedType,
    variables: &mut BTreeSet<TypeVariable>,
    formals: &mut BTreeSet<TypeFormal>,
) {
    inference.unresolved_variables(ty, variables);
    inference.referenced_formals(ty, formals);
}

fn collect_typed_variables(
    block: &TypedBlock,
    inference: &TypeInference,
    variables: &mut BTreeSet<TypeVariable>,
    formals: &mut BTreeSet<TypeFormal>,
    recursive_calls: &mut Vec<(EntityId, Span)>,
) {
    collect_inference_inputs(inference, &block.ty, variables, formals);
    for statement in &block.statements {
        match &statement.kind {
            TypedStatementKind::Let { ty, value, .. } => {
                collect_inference_inputs(inference, ty, variables, formals);
                collect_expr_variables(value, inference, variables, formals, recursive_calls);
            }
            TypedStatementKind::Return(Some(value)) | TypedStatementKind::Expression(value) => {
                collect_expr_variables(value, inference, variables, formals, recursive_calls);
            }
            TypedStatementKind::Return(None) => {}
        }
    }
    if let Some(tail) = &block.tail {
        collect_expr_variables(tail, inference, variables, formals, recursive_calls);
    }
}

fn collect_expr_variables(
    expression: &TypedExpr,
    inference: &TypeInference,
    variables: &mut BTreeSet<TypeVariable>,
    formals: &mut BTreeSet<TypeFormal>,
    recursive_calls: &mut Vec<(EntityId, Span)>,
) {
    collect_inference_inputs(inference, &expression.ty, variables, formals);
    match &expression.kind {
        TypedExprKind::FunctionValue(value) => {
            let mapping = value.mapping.as_ref().expect("function item mapping");
            for actual in mapping
                .types
                .iter()
                .map(|(_, ty)| ty)
                .chain(mapping.effects.iter().flat_map(|(_, row)| row.types()))
            {
                collect_inference_inputs(inference, actual, variables, formals);
            }
        }
        TypedExprKind::Indirect(call) => {
            collect_expr_variables(
                &call.callable,
                inference,
                variables,
                formals,
                recursive_calls,
            );
            for argument in &call.arguments {
                collect_expr_variables(argument, inference, variables, formals, recursive_calls);
            }
        }
        TypedExprKind::MethodDraft { .. } => {
            unreachable!("method selection closes before this phase")
        }
        TypedExprKind::Operation(operation) => {
            for argument in &operation.arguments {
                collect_expr_variables(argument, inference, variables, formals, recursive_calls);
            }
            for (_, ty) in &operation.mapping.types {
                collect_inference_inputs(inference, ty, variables, formals);
            }
        }
        TypedExprKind::Parenthesized(inner)
        | TypedExprKind::Unary { operand: inner, .. }
        | TypedExprKind::TupleField {
            receiver: inner, ..
        }
        | TypedExprKind::Field {
            receiver: inner, ..
        } => collect_expr_variables(inner, inference, variables, formals, recursive_calls),
        TypedExprKind::Tuple(elements) => {
            for element in elements {
                collect_expr_variables(element, inference, variables, formals, recursive_calls);
            }
        }
        TypedExprKind::Construct(construction) => {
            for actual in &construction.nominal.arguments {
                collect_inference_inputs(inference, actual, variables, formals);
            }
            for field in &construction.fields {
                collect_expr_variables(
                    &field.value,
                    inference,
                    variables,
                    formals,
                    recursive_calls,
                );
            }
        }
        TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
            collect_typed_variables(block, inference, variables, formals, recursive_calls);
        }
        TypedExprKind::If {
            condition,
            then_branch,
            else_branch,
        } => {
            collect_expr_variables(condition, inference, variables, formals, recursive_calls);
            collect_typed_variables(then_branch, inference, variables, formals, recursive_calls);
            if let Some(else_branch) = else_branch {
                collect_expr_variables(else_branch, inference, variables, formals, recursive_calls);
            }
        }
        TypedExprKind::Binary { left, right, .. } => {
            collect_expr_variables(left, inference, variables, formals, recursive_calls);
            collect_expr_variables(right, inference, variables, formals, recursive_calls);
        }
        TypedExprKind::Call {
            callee,
            arguments,
            instantiation,
            ..
        } => {
            for argument in arguments {
                collect_expr_variables(argument, inference, variables, formals, recursive_calls);
            }
            match instantiation {
                CallInstantiation::Pending(_) => {
                    unreachable!("call constraints close before generalization")
                }
                CallInstantiation::Published(mapping) | CallInstantiation::Provisional(mapping) => {
                    for actual in mapping
                        .types
                        .iter()
                        .map(|(_, ty)| ty)
                        .chain(mapping.effects.iter().flat_map(|(_, row)| row.types()))
                    {
                        collect_inference_inputs(inference, actual, variables, formals);
                    }
                }
                CallInstantiation::RecursiveBinding { effects } => {
                    for (_, row) in effects {
                        for actual in row.types() {
                            collect_inference_inputs(inference, actual, variables, formals);
                        }
                    }
                    recursive_calls.push((callee.as_ref().clone(), expression.span));
                }
            }
        }
        TypedExprKind::Integer { .. }
        | TypedExprKind::Float(_)
        | TypedExprKind::Boolean(_)
        | TypedExprKind::Unit
        | TypedExprKind::Reference { .. } => {}
    }
}

struct BodyClosure<'a> {
    inference: &'a TypeInference,
    function: &'a FunctionGeneralization,
    group: &'a BTreeMap<EntityId, GroupMember>,
    obligations: &'a [TypeObligation],
}

impl BodyClosure<'_> {
    fn close_effect(&self, row: &EffectRow) -> EffectRow {
        self.inference
            .resolve_effect(row)
            .map_types(&mut |ty| self.close_type(ty))
    }

    fn close_type(&self, ty: &CheckedType) -> CheckedType {
        self.inference.close_type(ty, self.function)
    }

    fn close_instantiation(
        &self,
        callee: &EntityId,
        instantiation: CallInstantiation,
    ) -> CallInstantiation {
        match instantiation {
            CallInstantiation::Pending(_) => unreachable!("only selected calls are frozen"),
            CallInstantiation::Published(mapping) => CallInstantiation::Published(CallMapping {
                types: mapping
                    .types
                    .into_iter()
                    .map(|(formal, actual)| (formal, self.close_type(&actual)))
                    .collect(),
                effects: mapping
                    .effects
                    .into_iter()
                    .map(|(formal, row)| (formal, self.close_effect(&row)))
                    .collect(),
            }),
            CallInstantiation::RecursiveBinding { effects } => {
                let member = self
                    .group
                    .get(callee)
                    .expect("a recursive draft references its exact unpublished group binding");
                CallInstantiation::Provisional(CallMapping {
                    types: member
                        .generalization
                        .bindings
                        .iter()
                        .filter(|(formal, _)| member.required.contains(formal))
                        .map(|(formal, shared)| (formal.clone(), self.close_type(shared)))
                        .collect(),
                    effects: effects
                        .into_iter()
                        .map(|(formal, row)| (formal, self.close_effect(&row)))
                        .collect(),
                })
            }
            CallInstantiation::Provisional(_) => {
                unreachable!("a recursive call is frozen exactly once from its group binding")
            }
        }
    }
}

fn close_typed_block(block: TypedBlock, closure: &BodyClosure<'_>) -> TypedBlock {
    TypedBlock {
        span: block.span,
        statements: block
            .statements
            .into_iter()
            .map(|statement| close_typed_statement(statement, closure))
            .collect(),
        tail: block
            .tail
            .map(|tail| Box::new(close_typed_expr(*tail, closure))),
        ty: closure.close_type(&block.ty),
    }
}

fn close_typed_statement(statement: TypedStatement, closure: &BodyClosure<'_>) -> TypedStatement {
    let kind = match statement.kind {
        TypedStatementKind::Let { binding, ty, value } => TypedStatementKind::Let {
            binding,
            ty: closure.close_type(&ty),
            value: Box::new(close_typed_expr(*value, closure)),
        },
        TypedStatementKind::Return(value) => TypedStatementKind::Return(
            value.map(|value| Box::new(close_typed_expr(*value, closure))),
        ),
        TypedStatementKind::Expression(expression) => {
            TypedStatementKind::Expression(Box::new(close_typed_expr(*expression, closure)))
        }
    };
    TypedStatement {
        span: statement.span,
        kind,
    }
}

fn close_typed_expr(expression: TypedExpr, closure: &BodyClosure<'_>) -> TypedExpr {
    let kind = match expression.kind {
        TypedExprKind::FunctionValue(value) => {
            TypedExprKind::FunctionValue(Box::new(TypedFunctionValue {
                function: value.function,
                mapping: value.mapping.map(|mapping| CallMapping {
                    types: mapping
                        .types
                        .into_iter()
                        .map(|(formal, ty)| (formal, closure.close_type(&ty)))
                        .collect(),
                    effects: mapping
                        .effects
                        .into_iter()
                        .map(|(formal, row)| (formal, closure.close_effect(&row)))
                        .collect(),
                }),
            }))
        }
        TypedExprKind::Indirect(call) => TypedExprKind::Indirect(Box::new(TypedIndirectCall {
            evidence: call
                .evidence
                .into_iter()
                .map(|evidence| evidence.map_types(|ty| closure.close_type(ty)))
                .collect(),
            callable: close_typed_expr(call.callable, closure),
            arguments: call
                .arguments
                .into_iter()
                .map(|argument| close_typed_expr(argument, closure))
                .collect(),
            parameter_modes: call.parameter_modes,
            effect: call.effect.map(|row| closure.close_effect(&row)),
        })),
        TypedExprKind::MethodDraft { .. } => {
            unreachable!("method selection closes before this phase")
        }
        TypedExprKind::Unsafe(block) => {
            TypedExprKind::Unsafe(Box::new(close_typed_block(*block, closure)))
        }
        TypedExprKind::Operation(operation) => TypedExprKind::Operation(Box::new(TypedOperation {
            operation: operation.operation,
            arguments: operation
                .arguments
                .into_iter()
                .map(|argument| close_typed_expr(argument, closure))
                .collect(),
            parameter_modes: operation.parameter_modes,
            mapping: CallMapping {
                types: operation
                    .mapping
                    .types
                    .into_iter()
                    .map(|(formal, ty)| (formal, closure.close_type(&ty)))
                    .collect(),
                effects: Vec::new(),
            },
            effect: operation.effect.map_types(&mut |ty| closure.close_type(ty)),
            evidence: operation
                .evidence
                .into_iter()
                .map(|evidence| evidence.map_types(|ty| closure.close_type(ty)))
                .collect(),
        })),
        TypedExprKind::Parenthesized(inner) => {
            TypedExprKind::Parenthesized(Box::new(close_typed_expr(*inner, closure)))
        }
        TypedExprKind::Tuple(elements) => TypedExprKind::Tuple(
            elements
                .into_iter()
                .map(|element| close_typed_expr(element, closure))
                .collect(),
        ),
        TypedExprKind::Block(block) => {
            TypedExprKind::Block(Box::new(close_typed_block(*block, closure)))
        }
        TypedExprKind::If {
            condition,
            then_branch,
            else_branch,
        } => TypedExprKind::If {
            condition: Box::new(close_typed_expr(*condition, closure)),
            then_branch: Box::new(close_typed_block(*then_branch, closure)),
            else_branch: else_branch.map(|branch| Box::new(close_typed_expr(*branch, closure))),
        },
        TypedExprKind::Unary { operator, operand } => TypedExprKind::Unary {
            operator,
            operand: Box::new(close_typed_expr(*operand, closure)),
        },
        TypedExprKind::Binary {
            operator,
            left,
            right,
            comparison,
        } => TypedExprKind::Binary {
            operator,
            left: Box::new(close_typed_expr(*left, closure)),
            right: Box::new(close_typed_expr(*right, closure)),
            comparison: comparison.map(|mut comparison| {
                let index = comparison.obligation.take().expect("one comparison proof");
                let TypeObligationKind::Comparison { evidence, .. } =
                    &closure.obligations[index].kind
                else {
                    unreachable!()
                };
                comparison.selection = evidence
                    .iter()
                    .cloned()
                    .map(|evidence| evidence.map_types(|ty| closure.close_type(ty)))
                    .collect();
                comparison.mapping.types = comparison
                    .mapping
                    .types
                    .into_iter()
                    .map(|(formal, ty)| (formal, closure.close_type(&ty)))
                    .collect();
                comparison
            }),
        },
        TypedExprKind::Call {
            callee,
            arguments,
            parameter_modes,
            instantiation,
            evidence,
            return_type,
            effect,
        } => {
            let instantiation = closure.close_instantiation(&callee, instantiation);
            TypedExprKind::Call {
                callee,
                arguments: arguments
                    .into_iter()
                    .map(|argument| close_typed_expr(argument, closure))
                    .collect(),
                parameter_modes,
                instantiation,
                evidence: evidence
                    .into_iter()
                    .map(|evidence| evidence.map_types(|ty| closure.close_type(ty)))
                    .collect(),
                return_type: closure.close_type(&return_type),
                effect: effect.map(|row| closure.close_effect(&row)),
            }
        }
        TypedExprKind::TupleField { receiver, index } => TypedExprKind::TupleField {
            receiver: Box::new(close_typed_expr(*receiver, closure)),
            index,
        },
        TypedExprKind::Field {
            receiver,
            selection,
            use_kind,
        } => {
            let selection = match selection {
                FieldSelection::Pending(index) => {
                    let obligation = &closure.obligations[index];
                    let TypeObligationKind::FieldProjection {
                        selected: Some(identity),
                        ..
                    } = &obligation.kind
                    else {
                        unreachable!("every field selection closes before publication")
                    };
                    FieldSelection::Exact(identity.clone(), obligation.primary.clone())
                }
                exact => exact,
            };
            TypedExprKind::Field {
                receiver: Box::new(close_typed_expr(*receiver, closure)),
                selection,
                use_kind,
            }
        }
        TypedExprKind::Construct(construction) => {
            TypedExprKind::Construct(Box::new(TypedConstruction {
                formation: None,
                evidence: match &closure.obligations[construction
                    .formation
                    .expect("one construction formation proof")]
                .kind
                {
                    TypeObligationKind::Formation { evidence } => evidence
                        .iter()
                        .cloned()
                        .map(|evidence| evidence.map_types(|ty| closure.close_type(ty)))
                        .collect(),
                    _ => unreachable!("construction formation obligation"),
                },
                nominal: NominalType {
                    declaration: construction.nominal.declaration,
                    arguments: construction
                        .nominal
                        .arguments
                        .iter()
                        .map(|actual| closure.close_type(actual))
                        .collect(),
                },
                constructor: construction.constructor,
                fields: construction
                    .fields
                    .into_iter()
                    .map(|field| TypedConstructField {
                        declaration: field.declaration,
                        origin: field.origin,
                        value: close_typed_expr(field.value, closure),
                    })
                    .collect(),
            }))
        }
        other => other,
    };
    TypedExpr {
        span: expression.span,
        ty: closure.close_type(&expression.ty),
        kind,
    }
}

fn function_binding_groups(
    function_order: &[EntityId],
    bodies: &BTreeMap<EntityId, TypedBlock>,
    effect_dependencies: &BTreeMap<EntityId, BTreeSet<EntityId>>,
) -> Vec<Vec<EntityId>> {
    let indices = function_order
        .iter()
        .enumerate()
        .map(|(index, identity)| (identity.clone(), index))
        .collect::<BTreeMap<_, _>>();
    let adjacency = function_order
        .iter()
        .map(|identity| {
            let mut calls = call_dependencies(&bodies[identity]);
            calls.extend(
                effect_dependencies
                    .get(identity)
                    .into_iter()
                    .flatten()
                    .cloned(),
            );
            calls
                .into_iter()
                .filter_map(|callee| indices.get(&callee).copied())
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();

    let mut visited = vec![false; function_order.len()];
    let mut finish = Vec::with_capacity(function_order.len());
    for root in 0..function_order.len() {
        if visited[root] {
            continue;
        }
        visited[root] = true;
        let mut stack = vec![(root, 0_usize)];
        while let Some((node, next)) = stack.last_mut() {
            if let Some(target) = adjacency[*node].get(*next).copied() {
                *next += 1;
                if !visited[target] {
                    visited[target] = true;
                    stack.push((target, 0));
                }
            } else {
                finish.push(*node);
                stack.pop();
            }
        }
    }

    let mut reverse = vec![Vec::new(); function_order.len()];
    for (source, targets) in adjacency.iter().enumerate() {
        for target in targets {
            reverse[*target].push(source);
        }
    }
    for sources in &mut reverse {
        sources.sort_unstable();
        sources.dedup();
    }

    visited.fill(false);
    let mut groups = Vec::new();
    for root in finish.into_iter().rev() {
        if visited[root] {
            continue;
        }
        visited[root] = true;
        let mut pending = vec![root];
        let mut group = Vec::new();
        while let Some(node) = pending.pop() {
            group.push(node);
            for source in reverse[node].iter().rev() {
                if !visited[*source] {
                    visited[*source] = true;
                    pending.push(*source);
                }
            }
        }
        group.sort_unstable();
        groups.push(
            group
                .into_iter()
                .map(|index| function_order[index].clone())
                .collect::<Vec<_>>(),
        );
    }
    groups.reverse();
    groups
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
    Infer(TypeVariable),
    Formal(Box<TypeFormal>),
    Tuple(Vec<CheckedType>),
    Nominal(Box<NominalType>),
    Projection(Box<Projection>),
    Function(Box<FunctionItem>),
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct NominalType {
    declaration: EntityId,
    arguments: Vec<CheckedType>,
}

struct NominalDefinition {
    formals: Vec<TypeFormal>,
    requirements: Vec<Requirement>,
    constructors: BTreeMap<EntityId, NominalFields>,
}

#[derive(Clone)]
struct NominalFields {
    shape: EntityShape,
    fields: Vec<NominalField>,
}

#[derive(Clone)]
struct NominalField {
    identity: EntityId,
    origin: OriginRef,
    ty: CheckedType,
}

impl NominalType {
    fn replacements(
        &self,
        definitions: &BTreeMap<EntityId, NominalDefinition>,
    ) -> BTreeMap<TypeFormal, CheckedType> {
        definitions[&self.declaration]
            .formals
            .iter()
            .cloned()
            .zip(self.arguments.iter().cloned())
            .collect()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct TypeVariable(u32);

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct TypeFormal {
    owner: EntityId,
    ordinal: usize,
    name: String,
}

#[derive(Default)]
struct TypeInference {
    next_variable: u32,
    substitutions: BTreeMap<TypeVariable, CheckedType>,
    formal_parents: BTreeMap<TypeFormal, TypeFormal>,
    receiver_hints: BTreeMap<TypeVariable, CheckedType>,
    next_effect_variable: u32,
    effect_substitutions: BTreeMap<u32, EffectRow>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum UnificationFailure {
    Mismatch(Box<CheckedType>, Box<CheckedType>),
    Infinite(TypeVariable, Box<CheckedType>),
}

impl TypeInference {
    fn fresh_effect(&mut self) -> EffectRow {
        let variable = self.next_effect_variable;
        self.next_effect_variable += 1;
        EffectRow(vec![EffectTerm::Variable(variable)])
    }

    fn resolve_effect(&self, row: &EffectRow) -> EffectRow {
        let mut pending = row.0.iter().rev().cloned().collect::<Vec<_>>();
        let mut result = Vec::new();
        while let Some(term) = pending.pop() {
            match term {
                EffectTerm::Variable(variable)
                    if self.effect_substitutions.contains_key(&variable) =>
                {
                    pending.extend(self.effect_substitutions[&variable].0.iter().rev().cloned())
                }
                EffectTerm::Method {
                    method,
                    types,
                    effects,
                } => result.push(EffectTerm::Method {
                    method,
                    types,
                    effects: effects.iter().map(|row| self.resolve_effect(row)).collect(),
                }),
                term => result.push(term),
            }
        }
        result.sort();
        result.dedup();
        EffectRow(result)
    }

    fn unify_effect_actual(&mut self, left: &EffectRow, right: &EffectRow) -> bool {
        let left = self
            .resolve_effect(left)
            .map_types(&mut |ty| self.canonical(ty));
        let right = self
            .resolve_effect(right)
            .map_types(&mut |ty| self.canonical(ty));
        if left == right {
            return true;
        }
        let (variable, row) = match (left.0.as_slice(), right.0.as_slice()) {
            ([EffectTerm::Variable(variable)], _) => (*variable, right),
            (_, [EffectTerm::Variable(variable)]) => (*variable, left),
            _ => return false,
        };
        let mut pending = vec![&row];
        while let Some(row) = pending.pop() {
            for term in &row.0 {
                match term {
                    EffectTerm::Variable(found) if *found == variable => return false,
                    EffectTerm::Method { effects, .. } => pending.extend(effects),
                    _ => {}
                }
            }
        }
        self.effect_substitutions.insert(variable, row);
        true
    }

    fn receiver_type(&self, ty: &CheckedType) -> CheckedType {
        let receiver = self.canonical(ty);
        if matches!(receiver, CheckedType::Infer(_)) {
            for (variable, hint) in &self.receiver_hints {
                if self.canonical(&CheckedType::Infer(*variable)) == receiver {
                    return self.canonical(hint);
                }
            }
        }
        receiver
    }
    fn canonical(&self, ty: &CheckedType) -> CheckedType {
        match self.resolve(ty) {
            CheckedType::Function(item) => {
                CheckedType::Function(Box::new(item.map_types(|ty| self.canonical(ty))))
            }
            CheckedType::Formal(formal) => CheckedType::Formal(Box::new(self.formal_root(&formal))),
            CheckedType::Tuple(elements) => {
                CheckedType::Tuple(elements.iter().map(|ty| self.canonical(ty)).collect())
            }
            CheckedType::Nominal(nominal) => CheckedType::Nominal(Box::new(NominalType {
                declaration: nominal.declaration,
                arguments: nominal
                    .arguments
                    .iter()
                    .map(|ty| self.canonical(ty))
                    .collect(),
            })),
            CheckedType::Projection(projection) => {
                CheckedType::Projection(Box::new(projection.map_types(|ty| self.canonical(ty))))
            }
            ty => ty,
        }
    }
    fn fresh(&mut self) -> CheckedType {
        let variable = TypeVariable(self.next_variable);
        self.next_variable = self
            .next_variable
            .checked_add(1)
            .expect("one Checker invocation cannot exhaust type-variable identities");
        CheckedType::Infer(variable)
    }

    fn resolve(&self, ty: &CheckedType) -> CheckedType {
        let mut ty = ty;
        while let CheckedType::Infer(variable) = ty {
            let Some(bound) = self.substitutions.get(variable) else {
                return ty.clone();
            };
            ty = bound;
        }
        match ty {
            CheckedType::Function(item) => {
                let mut item = item.map_types(|ty| self.resolve(ty));
                for (_, row) in &mut item.mapping.effects {
                    *row = self.resolve_effect(row);
                }
                CheckedType::Function(Box::new(item))
            }
            CheckedType::Tuple(elements) => CheckedType::Tuple(
                elements
                    .iter()
                    .map(|element| self.resolve(element))
                    .collect(),
            ),
            CheckedType::Nominal(nominal) => CheckedType::Nominal(Box::new(NominalType {
                declaration: nominal.declaration.clone(),
                arguments: nominal
                    .arguments
                    .iter()
                    .map(|ty| self.resolve(ty))
                    .collect(),
            })),
            CheckedType::Projection(projection) => {
                CheckedType::Projection(Box::new(projection.map_types(|ty| self.resolve(ty))))
            }
            _ => ty.clone(),
        }
    }

    fn register_formal(&mut self, formal: &TypeFormal) {
        self.formal_parents
            .entry(formal.clone())
            .or_insert_with(|| formal.clone());
    }

    fn formal_root(&self, formal: &TypeFormal) -> TypeFormal {
        let mut current = formal.clone();
        while let Some(parent) = self.formal_parents.get(&current)
            && parent != &current
        {
            current = parent.clone();
        }
        current
    }

    fn formals_equivalent(&self, left: &TypeFormal, right: &TypeFormal) -> bool {
        left == right || self.formal_root(left) == self.formal_root(right)
    }

    fn unify_formals(
        &mut self,
        left: TypeFormal,
        right: TypeFormal,
    ) -> Result<(), UnificationFailure> {
        self.register_formal(&left);
        self.register_formal(&right);
        let left_root = self.formal_root(&left);
        let right_root = self.formal_root(&right);
        if left_root == right_root {
            return Ok(());
        }
        let known = self.formal_parents.keys().cloned().collect::<Vec<_>>();
        let left_members = known
            .iter()
            .filter(|formal| self.formal_root(formal) == left_root)
            .collect::<Vec<_>>();
        let right_members = known
            .iter()
            .filter(|formal| self.formal_root(formal) == right_root)
            .collect::<Vec<_>>();
        if left_members
            .iter()
            .any(|left| right_members.iter().any(|right| left.owner == right.owner))
        {
            return Err(UnificationFailure::Mismatch(
                Box::new(CheckedType::Formal(Box::new(left))),
                Box::new(CheckedType::Formal(Box::new(right))),
            ));
        }
        let (root, child) = if left_root <= right_root {
            (left_root, right_root)
        } else {
            (right_root, left_root)
        };
        self.formal_parents.insert(child, root);
        Ok(())
    }

    fn unify(&mut self, left: &CheckedType, right: &CheckedType) -> Result<(), UnificationFailure> {
        let left = self.resolve(left);
        let right = self.resolve(right);
        if left == right {
            return Ok(());
        }
        match (left, right) {
            (CheckedType::Function(left), CheckedType::Function(right))
                if left.function == right.function
                    && left.mapping.types.len() == right.mapping.types.len()
                    && left.mapping.effects.len() == right.mapping.effects.len() =>
            {
                for ((_, left_row), (_, right_row)) in
                    left.mapping.effects.iter().zip(&right.mapping.effects)
                {
                    if !self.unify_effect_actual(left_row, right_row) {
                        return Err(UnificationFailure::Mismatch(
                            Box::new(CheckedType::Function(left)),
                            Box::new(CheckedType::Function(right)),
                        ));
                    }
                }
                for ((_, left), (_, right)) in left.mapping.types.iter().zip(&right.mapping.types) {
                    self.unify(left, right)?;
                }
                Ok(())
            }
            (CheckedType::Infer(variable), ty) | (ty, CheckedType::Infer(variable)) => {
                if contains_variable(&ty, variable, self) {
                    return Err(UnificationFailure::Infinite(variable, Box::new(ty)));
                }
                self.substitutions.insert(variable, ty);
                Ok(())
            }
            (CheckedType::Tuple(left), CheckedType::Tuple(right)) if left.len() == right.len() => {
                for (left, right) in left.iter().zip(&right) {
                    self.unify(left, right)?;
                }
                Ok(())
            }
            (CheckedType::Formal(left), CheckedType::Formal(right)) => {
                self.unify_formals(*left, *right)
            }
            (CheckedType::Nominal(left), CheckedType::Nominal(right))
                if left.declaration == right.declaration =>
            {
                debug_assert_eq!(left.arguments.len(), right.arguments.len());
                for (left, right) in left.arguments.iter().zip(&right.arguments) {
                    self.unify(left, right)?;
                }
                Ok(())
            }
            (left, right) => Err(UnificationFailure::Mismatch(
                Box::new(left),
                Box::new(right),
            )),
        }
    }

    fn satisfy(
        &mut self,
        actual: &CheckedType,
        expected: &CheckedType,
    ) -> Result<(), UnificationFailure> {
        let actual = self.resolve(actual);
        let expected = self.resolve(expected);
        if actual == CheckedType::Never {
            return Ok(());
        }
        if let (CheckedType::Tuple(actual), CheckedType::Tuple(expected)) = (&actual, &expected)
            && actual.len() == expected.len()
        {
            for (actual, expected) in actual.iter().zip(expected) {
                self.satisfy(actual, expected)?;
            }
            Ok(())
        } else {
            self.unify(&actual, &expected)
        }
    }

    fn unresolved_variables(&self, ty: &CheckedType, variables: &mut BTreeSet<TypeVariable>) {
        match self.resolve(ty) {
            CheckedType::Function(item) => {
                for ty in item.types() {
                    self.unresolved_variables(ty, variables);
                }
            }
            CheckedType::Projection(projection) => {
                for ty in projection.types() {
                    self.unresolved_variables(ty, variables);
                }
            }
            CheckedType::Infer(variable) => {
                variables.insert(variable);
            }
            CheckedType::Tuple(elements) => {
                for element in &elements {
                    self.unresolved_variables(element, variables);
                }
            }
            CheckedType::Nominal(nominal) => {
                for argument in &nominal.arguments {
                    self.unresolved_variables(argument, variables);
                }
            }
            _ => {}
        }
    }

    fn referenced_formals(&self, ty: &CheckedType, formals: &mut BTreeSet<TypeFormal>) {
        match self.resolve(ty) {
            CheckedType::Function(item) => {
                for ty in item.types() {
                    self.referenced_formals(ty, formals);
                }
            }
            CheckedType::Projection(projection) => {
                for ty in projection.types() {
                    self.referenced_formals(ty, formals);
                }
            }
            CheckedType::Formal(formal) => {
                formals.insert(*formal);
            }
            CheckedType::Tuple(elements) => {
                for element in &elements {
                    self.referenced_formals(element, formals);
                }
            }
            CheckedType::Nominal(nominal) => {
                for argument in &nominal.arguments {
                    self.referenced_formals(argument, formals);
                }
            }
            _ => {}
        }
    }

    fn close_type(&self, ty: &CheckedType, generalized: &FunctionGeneralization) -> CheckedType {
        match self.resolve(ty) {
            CheckedType::Function(item) => CheckedType::Function(Box::new(
                item.map_types(|ty| self.close_type(ty, generalized)),
            )),
            CheckedType::Projection(projection) => CheckedType::Projection(Box::new(
                projection.map_types(|ty| self.close_type(ty, generalized)),
            )),
            shared @ (CheckedType::Infer(_) | CheckedType::Formal(_)) => {
                CheckedType::Formal(Box::new(
                    generalized
                        .formal_for(&shared, self)
                        .expect("every published type is bound by its recorded callable binder")
                        .clone(),
                ))
            }
            CheckedType::Tuple(elements) => CheckedType::Tuple(
                elements
                    .iter()
                    .map(|element| self.close_type(element, generalized))
                    .collect(),
            ),
            CheckedType::Nominal(nominal) => CheckedType::Nominal(Box::new(NominalType {
                declaration: nominal.declaration,
                arguments: nominal
                    .arguments
                    .iter()
                    .map(|ty| self.close_type(ty, generalized))
                    .collect(),
            })),
            resolved => resolved,
        }
    }
}

fn contains_variable(ty: &CheckedType, needle: TypeVariable, inference: &TypeInference) -> bool {
    match inference.resolve(ty) {
        CheckedType::Function(item) => item
            .types()
            .any(|ty| contains_variable(ty, needle, inference)),
        CheckedType::Projection(projection) => projection
            .types()
            .any(|ty| contains_variable(ty, needle, inference)),
        CheckedType::Infer(variable) => variable == needle,
        CheckedType::Tuple(elements) => elements
            .iter()
            .any(|element| contains_variable(element, needle, inference)),
        CheckedType::Nominal(nominal) => nominal
            .arguments
            .iter()
            .any(|ty| contains_variable(ty, needle, inference)),
        _ => false,
    }
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
    type_origin: CheckOrigin,
    source_type_explicit: bool,
    mode: Option<SelectedMode>,
    callable_use: bool,
}

#[derive(Clone)]
struct FunctionHeader {
    identity: EntityId,
    context: SourceContext,
    origin: OriginRef,
    public_export: bool,
    declared_formals: Vec<TypeFormal>,
    outer_formals: Vec<TypeFormal>,
    requirements: Vec<Requirement>,
    effect_formals: Vec<EffectFormal>,
    effect_upper: Option<EffectRow>,
    effect_origin: CheckOrigin,
    trait_upper: Option<EffectRow>,
    trait_effect_origin: Option<CheckOrigin>,
    shapes: Vec<ShapeRequirement>,
    inferable_effects: BTreeSet<EffectFormal>,
    formal_by_identity: BTreeMap<EntityId, TypeFormal>,
    parameters: Vec<HeaderParameter>,
    return_type: CheckedType,
    return_origin: CheckOrigin,
    source_return_explicit: bool,
    body: Option<ResolvedBlock>,
}

impl FunctionHeader {
    fn interface_types(&self) -> Vec<&CheckedType> {
        let mut types = self
            .parameters
            .iter()
            .map(|parameter| &parameter.ty)
            .chain(std::iter::once(&self.return_type))
            .collect::<Vec<_>>();
        for requirement in &self.requirements {
            types.push(&requirement.subject);
            types.extend(&requirement.bound.arguments);
            types.extend(requirement.bound.associated.values());
        }
        for shape in &self.shapes {
            types.push(&shape.subject);
            types.extend(shape.shape.parameters.iter().map(|(ty, _)| ty));
            types.push(&shape.shape.return_type);
            types.extend(shape.shape.effect.types());
        }
        for row in self.effect_upper.iter().chain(&self.trait_upper) {
            types.extend(row.types());
        }
        types
    }
}

#[derive(Clone)]
struct AliasDefinition {
    origin: OriginRef,
    type_parameter_count: usize,
    value: ResolvedType,
}

struct SourceTypeNormalizer<'a> {
    project: &'a ResolvedProject,
    aliases: BTreeMap<EntityId, AliasDefinition>,
    arities: BTreeMap<EntityId, usize>,
    normalized_aliases: BTreeMap<EntityId, CheckedType>,
    nominals: BTreeMap<EntityId, NominalDefinition>,
    self_types: BTreeMap<EntityId, CheckedType>,
    selection: TraitSelection,
    owner_formals: BTreeMap<EntityId, BTreeMap<EntityId, TypeFormal>>,
    generic_bounds: BTreeMap<TypeFormal, Vec<ResolvedNamedType>>,
    contract_bounds: BTreeMap<EntityId, Vec<Requirement>>,
    contract_scope: Option<EntityId>,
    module_effects: BTreeMap<ModuleRef, (EffectRow, OriginRef)>,
    operations: BTreeMap<EntityId, OperationHeader>,
}

enum NormalizeFrame {
    Type(ResolvedType),
    FinishTuple(usize),
    FinishAlias(EntityId),
    FinishNominal(EntityId, usize),
}

impl<'a> SourceTypeNormalizer<'a> {
    fn new(project: &'a ResolvedProject) -> Self {
        let mut aliases = BTreeMap::new();
        let mut arities = BTreeMap::new();
        let mut nominals = BTreeMap::new();

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
                    } => {
                        nominals.insert(
                            identity.clone(),
                            NominalDefinition {
                                requirements: Vec::new(),
                                formals: type_parameters
                                    .iter()
                                    .enumerate()
                                    .map(|(ordinal, parameter)| TypeFormal {
                                        owner: identity.clone(),
                                        ordinal,
                                        name: parameter.binding.identity.name.clone(),
                                    })
                                    .collect(),
                                constructors: BTreeMap::new(),
                            },
                        );
                        Some(type_parameters.len())
                    }
                    ResolvedDeclarationKind::Trait {
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

        let self_types = project
            .entities
            .iter()
            .filter_map(|(identity, entity)| {
                if identity.kind != EntityKind::SelfType {
                    return None;
                }
                let owner = entity.owner.as_ref()?;
                let definition = nominals.get(owner)?;
                Some((
                    identity.clone(),
                    CheckedType::Nominal(Box::new(NominalType {
                        declaration: owner.clone(),
                        arguments: definition
                            .formals
                            .iter()
                            .cloned()
                            .map(|formal| CheckedType::Formal(Box::new(formal)))
                            .collect(),
                    })),
                ))
            })
            .collect();
        Self {
            project,
            aliases,
            arities,
            normalized_aliases: BTreeMap::new(),
            nominals,
            self_types,
            selection: TraitSelection::default(),
            owner_formals: BTreeMap::new(),
            generic_bounds: BTreeMap::new(),
            contract_bounds: BTreeMap::new(),
            contract_scope: None,
            module_effects: BTreeMap::new(),
            operations: BTreeMap::new(),
        }
    }

    fn normalize(&mut self, ty: &ResolvedType) -> Result<CheckedType, CheckDiagnostic> {
        self.normalize_with_formals(ty, &BTreeMap::new())
    }

    fn normalize_with_formals(
        &mut self,
        ty: &ResolvedType,
        formals: &BTreeMap<EntityId, TypeFormal>,
    ) -> Result<CheckedType, CheckDiagnostic> {
        let mut frames = vec![NormalizeFrame::Type(ty.clone())];
        let mut values = Vec::new();
        let mut active_aliases = Vec::new();

        while let Some(frame) = frames.pop() {
            match frame {
                NormalizeFrame::Type(ty) => match ty.kind {
                    ResolvedTypeKind::Grouped(inner) => {
                        frames.push(NormalizeFrame::Type(*inner));
                    }
                    ResolvedTypeKind::Tuple(elements) => {
                        frames.push(NormalizeFrame::FinishTuple(elements.len()));
                        frames.extend(elements.into_iter().rev().map(NormalizeFrame::Type));
                    }
                    ResolvedTypeKind::Named(named) => {
                        let (occurrence, target) = match named.reference {
                            ResolvedReference::Exact {
                                occurrence, target, ..
                            } => (occurrence, target),
                            selection @ ResolvedReference::Selection { .. } => {
                                if !named.arguments.is_empty() {
                                    return Err(source_diagnostic(
                                        CheckDiagnosticKind::Unsupported,
                                        "associated types do not accept generic arguments",
                                        reference_origin(&selection).clone(),
                                        Vec::new(),
                                    ));
                                }
                                values.push(
                                    self.normalize_associated_reference(&selection, formals)?,
                                );
                                continue;
                            }
                        };

                        if target.kind == EntityKind::AssociatedType {
                            values.push(self.normalize_associated_reference(
                                &ResolvedReference::Exact {
                                    occurrence,
                                    target,
                                    self_reference: None,
                                },
                                formals,
                            )?);
                            continue;
                        }

                        let mut positional_count = 0;
                        for argument in &named.arguments {
                            match argument {
                                ResolvedTypeArgument::Type(_) => positional_count += 1,
                                ResolvedTypeArgument::AssociatedType { member, .. } => {
                                    return Err(source_diagnostic(
                                        CheckDiagnosticKind::Unsupported,
                                        "associated type bindings are outside the initial Checker subset",
                                        member.origin.clone(),
                                        Vec::new(),
                                    ));
                                }
                            }
                        }
                        if let Some(expected) = self.arities.get(&target)
                            && *expected != positional_count
                        {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                format!(
                                    "type constructor `{}` expects {expected} argument(s) but received {positional_count}",
                                    target.name
                                ),
                                occurrence,
                                entity_origin(&target).into_iter().collect(),
                            ));
                        }

                        if target.kind == EntityKind::LanguageType {
                            let normalized = match target.name.as_str() {
                                "Int" => CheckedType::Int,
                                "Float" => CheckedType::Float,
                                "Bool" => CheckedType::Bool,
                                "Unit" => CheckedType::Unit,
                                "Never" => CheckedType::Never,
                                _ => {
                                    return Err(source_diagnostic(
                                        CheckDiagnosticKind::Unsupported,
                                        format!(
                                            "language type `{}` is outside the initial Checker subset",
                                            target.name
                                        ),
                                        occurrence,
                                        Vec::new(),
                                    ));
                                }
                            };
                            values.push(normalized);
                            continue;
                        }

                        if target.kind == EntityKind::SelfType {
                            if positional_count != 0 {
                                return Err(source_diagnostic(
                                    CheckDiagnosticKind::TypeMismatch,
                                    "Self does not accept type arguments",
                                    occurrence,
                                    Vec::new(),
                                ));
                            }
                            if let Some(ty) = self.self_types.get(&target) {
                                values.push(ty.clone());
                                continue;
                            }
                        }
                        if matches!(target.kind, EntityKind::Struct | EntityKind::Enum) {
                            frames.push(NormalizeFrame::FinishNominal(target, positional_count));
                            frames.extend(named.arguments.into_iter().rev().map(|argument| {
                                let ResolvedTypeArgument::Type(ty) = argument else {
                                    unreachable!("associated arguments are rejected above")
                                };
                                NormalizeFrame::Type(*ty)
                            }));
                            continue;
                        }
                        if target.kind == EntityKind::TypeParameter {
                            if positional_count != 0 {
                                return Err(source_diagnostic(
                                    CheckDiagnosticKind::TypeMismatch,
                                    "a type formal does not accept type arguments",
                                    occurrence,
                                    entity_origin(&target).into_iter().collect(),
                                ));
                            }
                            let Some(formal) = formals.get(&target) else {
                                return Err(source_diagnostic(
                                    CheckDiagnosticKind::Unsupported,
                                    "a type formal outside the checked function is not supported",
                                    occurrence,
                                    entity_origin(&target).into_iter().collect(),
                                ));
                            };
                            values.push(CheckedType::Formal(Box::new(formal.clone())));
                            continue;
                        }

                        if target.kind != EntityKind::TypeAlias {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::Unsupported,
                                format!(
                                    "nominal type `{}` is outside the initial Checker subset",
                                    target.name
                                ),
                                occurrence,
                                entity_origin(&target).into_iter().collect(),
                            ));
                        }

                        let definition =
                            self.aliases.get(&target).cloned().expect(
                                "every reachable type-alias entity has a resolved declaration",
                            );
                        if definition.type_parameter_count != 0 {
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::Unsupported,
                                "generic type aliases are outside the initial Checker subset",
                                occurrence,
                                vec![definition.origin],
                            ));
                        }
                        if let Some(normalized) = self.normalized_aliases.get(&target) {
                            values.push(normalized.clone());
                            continue;
                        }
                        if let Some(cycle_start) = active_aliases
                            .iter()
                            .position(|identity| identity == &target)
                        {
                            let related = active_aliases[cycle_start..]
                                .iter()
                                .filter_map(|identity| self.aliases.get(identity))
                                .map(|alias| alias.origin.clone())
                                .collect();
                            return Err(source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                "non-generic type aliases form a cycle",
                                occurrence,
                                related,
                            ));
                        }

                        active_aliases.push(target.clone());
                        frames.push(NormalizeFrame::FinishAlias(target));
                        frames.push(NormalizeFrame::Type(definition.value));
                    }
                },
                NormalizeFrame::FinishTuple(element_count) => {
                    let first = values
                        .len()
                        .checked_sub(element_count)
                        .expect("tuple elements each produce one normalized type");
                    let elements = values.split_off(first);
                    values.push(CheckedType::Tuple(elements));
                }
                NormalizeFrame::FinishNominal(declaration, argument_count) => {
                    let first = values
                        .len()
                        .checked_sub(argument_count)
                        .expect("each actual produces one type");
                    let arguments = values.split_off(first);
                    values.push(CheckedType::Nominal(Box::new(NominalType {
                        declaration,
                        arguments,
                    })));
                }
                NormalizeFrame::FinishAlias(identity) => {
                    let normalized = values
                        .last()
                        .expect("an alias value produces one normalized type")
                        .clone();
                    let active = active_aliases
                        .pop()
                        .expect("a finishing alias remains active");
                    debug_assert_eq!(active, identity);
                    self.normalized_aliases.insert(identity, normalized);
                }
            }
        }

        let [normalized] = values.as_slice() else {
            unreachable!("one source type produces exactly one normalized type")
        };
        Ok(normalized.clone())
    }
}

fn collect_nominal_definition(
    project: &ResolvedProject,
    declaration: &ResolvedDeclaration,
    normalizer: &mut SourceTypeNormalizer,
    public_exports: &BTreeSet<EntityId>,
) -> Result<(), CheckDiagnostic> {
    let identity = declaration
        .identity
        .as_ref()
        .expect("nominal declaration has an identity");
    let (parameters, constructors) = match &declaration.kind {
        ResolvedDeclarationKind::Struct {
            type_parameters,
            fields,
        } => (
            type_parameters,
            vec![(
                identity.clone(),
                EntityShape::Plain,
                fields
                    .iter()
                    .map(|field| (field.identity.clone(), field.public, &field.ty))
                    .collect::<Vec<_>>(),
            )],
        ),
        ResolvedDeclarationKind::Enum {
            type_parameters,
            variants,
        } => (
            type_parameters,
            variants
                .iter()
                .map(|variant| {
                    let fields = match &variant.fields {
                        ResolvedVariantFields::Unit => Vec::new(),
                        ResolvedVariantFields::Named(fields) => fields
                            .iter()
                            .map(|field| (field.identity.clone(), true, &field.ty))
                            .collect(),
                        ResolvedVariantFields::Positional(fields) => fields
                            .iter()
                            .enumerate()
                            .map(|(index, ty)| {
                                let field = &project.entities[&variant.identity].members
                                    [&format!("#{index}")][0];
                                (field.clone(), true, ty)
                            })
                            .collect(),
                    };
                    (
                        variant.identity.clone(),
                        project.entities[&variant.identity].shape,
                        fields,
                    )
                })
                .collect(),
        ),
        _ => unreachable!("only nominal declarations enter this collector"),
    };
    let formals = parameters
        .iter()
        .zip(&normalizer.nominals[identity].formals)
        .map(|(parameter, formal)| (parameter.binding.identity.clone(), formal.clone()))
        .collect();
    let context = SourceContext::from_origin(&declaration.origin);
    let requirements = normalizer.parameter_requirements(parameters, &formals)?;
    normalizer
        .nominals
        .get_mut(identity)
        .expect("nominal indexed")
        .requirements = requirements;
    let mut normalized = BTreeMap::new();
    for (constructor, shape, fields) in constructors {
        let mut typed_fields = Vec::new();
        for (field, public, ty) in fields {
            if public && public_exports.contains(identity) {
                validate_public_type_visibility(public_exports, ty, &normalizer.aliases)?;
            }
            typed_fields.push(NominalField {
                identity: field,
                origin: context.origin(ty.span),
                ty: normalizer.normalize_with_formals(ty, &formals)?,
            });
        }
        normalized.insert(
            constructor,
            NominalFields {
                shape,
                fields: typed_fields,
            },
        );
    }
    normalizer
        .nominals
        .get_mut(identity)
        .expect("nominal formals were indexed")
        .constructors = normalized;
    Ok(())
}

fn actual_public_exports(project: &ResolvedProject) -> BTreeSet<EntityId> {
    let mut pending_modules = project
        .dependencies
        .keys()
        .copied()
        .map(ModuleRef::root)
        .collect::<Vec<_>>();
    let mut visited_modules = BTreeSet::new();
    let mut exports = BTreeSet::new();

    while let Some(module) = pending_modules.pop() {
        if !visited_modules.insert(module.clone()) {
            continue;
        }
        let Some(bindings) = project.name_bindings.get(&module) else {
            continue;
        };
        for binding in bindings.values().flatten().filter(|binding| binding.public) {
            exports.insert(binding.target.clone());
            if binding.target.kind == EntityKind::Module {
                pending_modules.push(binding.target.module.clone());
            }
        }
    }
    exports
}

fn collect_supported_headers(
    project: &ResolvedProject,
    normalizer: &mut SourceTypeNormalizer,
    inference: &mut TypeInference,
    public_exports: &BTreeSet<EntityId>,
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
        if let Some(requires) = &body.requires {
            match normalizer.normalize_effects(requires, &BTreeMap::new(), &BTreeMap::new()) {
                Ok(row) => {
                    normalizer
                        .module_effects
                        .insert(module.clone(), (row, context.origin(requires.span)));
                }
                Err(diagnostic) => {
                    push_header_diagnostic(project, module, &mut diagnostics, diagnostic)
                }
            }
        }
        for declaration in &body.declarations {
            match &declaration.kind {
                ResolvedDeclarationKind::Module(_) => {}
                ResolvedDeclarationKind::Effect {
                    type_parameters,
                    operations,
                } => {
                    let owner = declaration.identity.as_ref().expect("effect owner");
                    if let Err(diagnostic) =
                        normalizer.collect_operations(owner, type_parameters, operations)
                    {
                        push_header_diagnostic(project, module, &mut diagnostics, diagnostic);
                    }
                }
                ResolvedDeclarationKind::EffectAlias { effects, .. } => {
                    let formals = normalizer.owner_formals
                        [declaration.identity.as_ref().expect("alias owner")]
                    .clone();
                    if let Err(diagnostic) =
                        normalizer.normalize_effects(effects, &formals, &BTreeMap::new())
                    {
                        push_header_diagnostic(project, module, &mut diagnostics, diagnostic);
                    }
                }
                ResolvedDeclarationKind::Trait { members, .. } => {
                    let owner = declaration.identity.as_ref().expect("trait identity");
                    for member in members {
                        if let crate::project::ResolvedTraitMemberKind::Method(signature) =
                            &member.kind
                        {
                            match normalizer.trait_method_header(
                                owner,
                                signature,
                                public_exports.contains(owner),
                                public_exports,
                            ) {
                                Ok(header) => {
                                    headers.insert(member.identity.clone(), header);
                                }
                                Err(diagnostic)
                                    if core_declarations.contains(owner)
                                        && diagnostic.kind == CheckDiagnosticKind::Unsupported => {}
                                Err(diagnostic) => push_header_diagnostic(
                                    project,
                                    module,
                                    &mut diagnostics,
                                    diagnostic,
                                ),
                            }
                        }
                    }
                }
                ResolvedDeclarationKind::InherentImpl(_)
                | ResolvedDeclarationKind::TraitImpl { .. } => {
                    let implementation = match &declaration.kind {
                        ResolvedDeclarationKind::InherentImpl(implementation) => implementation,
                        ResolvedDeclarationKind::TraitImpl { implementation, .. } => {
                            implementation.as_ref()
                        }
                        _ => unreachable!(),
                    };
                    let impl_id = declaration.identity.as_ref().expect("impl identity");
                    for member in &implementation.members {
                        if let crate::project::ResolvedImplMemberKind::Function(function) =
                            &member.kind
                        {
                            let member_declaration = ResolvedDeclaration {
                                identity: Some(member.identity.clone()),
                                origin: entity_origin(&member.identity).expect("method origin"),
                                public: member.public,
                                kind: ResolvedDeclarationKind::Function(function.clone()),
                            };
                            let owner = &normalizer.selection.implementations[impl_id];
                            let exposed = validate_public_nominals(
                                &owner.target,
                                public_exports,
                                &declaration.origin,
                            )
                            .is_ok()
                                && owner.trait_use.as_ref().map_or(member.public, |bound| {
                                    public_exports.contains(&bound.declaration)
                                });
                            match collect_function_header(
                                &member_declaration,
                                function,
                                &context,
                                normalizer,
                                inference,
                                exposed,
                                public_exports,
                            ) {
                                Ok(mut header) => {
                                    header.requirements.extend(
                                        normalizer.selection.implementations[impl_id]
                                            .requirements
                                            .iter()
                                            .cloned(),
                                    );
                                    order.push(member.identity.clone());
                                    headers.insert(member.identity.clone(), header);
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
                    }
                }
                ResolvedDeclarationKind::Struct { .. } | ResolvedDeclarationKind::Enum { .. } => {
                    if let Err(diagnostic) =
                        collect_nominal_definition(project, declaration, normalizer, public_exports)
                    {
                        push_header_diagnostic(project, module, &mut diagnostics, diagnostic);
                    }
                }
                ResolvedDeclarationKind::TypeAlias {
                    type_parameters,
                    value,
                } => {
                    let identity = declaration
                        .identity
                        .as_ref()
                        .expect("every resolved type alias has an exact identity");
                    let public_export = public_exports.contains(identity);
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
                    } else {
                        match normalizer.normalize(value) {
                            Ok(normalized) => {
                                normalizer
                                    .normalized_aliases
                                    .insert(identity.clone(), normalized);
                                if public_export
                                    && let Err(diagnostic) = validate_public_type_visibility(
                                        public_exports,
                                        value,
                                        &normalizer.aliases,
                                    )
                                {
                                    push_header_diagnostic(
                                        project,
                                        module,
                                        &mut diagnostics,
                                        diagnostic,
                                    );
                                }
                            }
                            Err(diagnostic) => {
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
                ResolvedDeclarationKind::Function(function) => {
                    let identity = declaration
                        .identity
                        .as_ref()
                        .expect("every resolved function has an exact identity")
                        .clone();
                    let public_export = public_exports.contains(&identity);
                    match collect_function_header(
                        declaration,
                        function,
                        &context,
                        normalizer,
                        inference,
                        public_export,
                        public_exports,
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
    public_exports: &BTreeSet<EntityId>,
    ty: &ResolvedType,
    aliases: &BTreeMap<EntityId, AliasDefinition>,
) -> Result<(), CheckDiagnostic> {
    let mut pending = vec![ty.clone()];
    let mut visited_aliases = BTreeSet::new();
    while let Some(ty) = pending.pop() {
        match ty.kind {
            ResolvedTypeKind::Grouped(inner) => pending.push(*inner),
            ResolvedTypeKind::Tuple(elements) => pending.extend(elements.into_iter().rev()),
            ResolvedTypeKind::Named(named) => {
                for argument in named.arguments.into_iter().rev() {
                    if let ResolvedTypeArgument::Type(ty) = argument {
                        pending.push(*ty);
                    }
                }
                let ResolvedReference::Exact {
                    occurrence, target, ..
                } = named.reference
                else {
                    continue;
                };
                if !matches!(
                    target.kind,
                    EntityKind::TypeAlias | EntityKind::Struct | EntityKind::Enum
                ) {
                    continue;
                }
                if !public_exports.contains(&target) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        format!(
                            "public type surface references private type `{}`",
                            target.name
                        ),
                        occurrence,
                        entity_origin(&target).into_iter().collect(),
                    ));
                }
                if target.kind == EntityKind::TypeAlias && visited_aliases.insert(target.clone()) {
                    let definition = aliases
                        .get(&target)
                        .expect("every exact type alias has a resolved definition");
                    if definition.type_parameter_count == 0 {
                        pending.push(definition.value.clone());
                    }
                }
            }
        }
    }
    Ok(())
}

fn validate_public_nominals(
    ty: &CheckedType,
    public_exports: &BTreeSet<EntityId>,
    origin: &OriginRef,
) -> Result<(), CheckDiagnostic> {
    let mut pending = vec![ty];
    while let Some(ty) = pending.pop() {
        match ty {
            CheckedType::Tuple(elements) => pending.extend(elements),
            CheckedType::Nominal(nominal) => {
                if !public_exports.contains(&nominal.declaration) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "public function exposes a private nominal type",
                        origin.clone(),
                        entity_origin(&nominal.declaration).into_iter().collect(),
                    ));
                }
                pending.extend(&nominal.arguments);
            }
            CheckedType::Projection(projection) => {
                if !public_exports.contains(&projection.bound.declaration) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "public associated result exposes a private trait",
                        origin.clone(),
                        entity_origin(&projection.bound.declaration)
                            .into_iter()
                            .collect(),
                    ));
                }
                pending.extend(projection.types());
            }
            CheckedType::Function(item) => {
                if !public_exports.contains(&item.function) {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        "public callable type exposes a private function",
                        origin.clone(),
                        entity_origin(&item.function).into_iter().collect(),
                    ));
                }
                pending.extend(item.mapping.types.iter().map(|(_, ty)| ty));
            }
            _ => {}
        }
    }
    Ok(())
}

fn collect_function_header(
    declaration: &ResolvedDeclaration,
    function: &crate::project::ResolvedFunction,
    context: &SourceContext,
    normalizer: &mut SourceTypeNormalizer,
    inference: &mut TypeInference,
    public_export: bool,
    public_exports: &BTreeSet<EntityId>,
) -> Result<FunctionHeader, Vec<CheckDiagnostic>> {
    if let Some(span) = function.const_span {
        return Err(vec![source_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "const functions are outside the initial Checker subset",
            context.origin(span),
            Vec::new(),
        )]);
    }
    let function_identity = declaration
        .identity
        .as_ref()
        .expect("every resolved function has an exact identity")
        .clone();
    normalizer.contract_scope = Some(function_identity.clone());
    let declared_formals = function
        .type_parameters
        .iter()
        .enumerate()
        .map(|(ordinal, parameter)| TypeFormal {
            owner: function_identity.clone(),
            ordinal,
            name: parameter.binding.identity.name.clone(),
        })
        .collect::<Vec<_>>();
    let formal_by_identity = normalizer.owner_formals[&function_identity].clone();
    let outer_formals = formal_by_identity
        .values()
        .filter(|formal| formal.owner != function_identity)
        .cloned()
        .collect();
    let requirements = normalizer
        .parameter_requirements(&function.type_parameters, &formal_by_identity)
        .map_err(|diagnostic| vec![diagnostic])?;
    let mut effect_formals = function
        .effect_parameters
        .iter()
        .enumerate()
        .map(|(ordinal, _)| EffectFormal {
            owner: function_identity.clone(),
            ordinal,
        })
        .collect::<Vec<_>>();
    let effect_by_identity = function
        .effect_parameters
        .iter()
        .zip(&effect_formals)
        .map(|(parameter, formal)| (parameter.binding.identity.clone(), formal.clone()))
        .collect::<BTreeMap<_, _>>();
    let effect_upper = function
        .effects
        .as_ref()
        .map(|row| normalizer.normalize_effects(row, &formal_by_identity, &effect_by_identity))
        .transpose()
        .map_err(|diagnostic| vec![diagnostic])?;
    let shapes = normalizer
        .callback_shapes(
            &function_identity,
            &function.type_parameters,
            &formal_by_identity,
            &mut effect_formals,
            &effect_by_identity,
        )
        .map_err(|diagnostic| vec![diagnostic])?;
    let inferable_effects = shapes
        .iter()
        .filter_map(|shape| shape.inferred_row.clone())
        .collect();

    let mut diagnostics = Vec::new();
    let mut parameters = Vec::with_capacity(function.parameters.len());
    for parameter in &function.parameters {
        if parameter.binding.identity.name == "self" && function_identity.kind != EntityKind::Method
        {
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
            Some((span, ParameterMode::Call)) => Some(SelectedMode {
                value: ParameterMode::Borrow,
                origin: CheckOrigin::Source(context.origin(span)),
            }),
            Some((span, ParameterMode::MutBorrow)) => {
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
            None => None,
        };
        if let Some(annotation) = annotation {
            if public_export
                && let Err(diagnostic) =
                    validate_public_type_visibility(public_exports, annotation, &normalizer.aliases)
            {
                diagnostics.push(diagnostic);
            }
            match normalizer.normalize_with_formals(annotation, &formal_by_identity) {
                Ok(ty) => parameters.push(HeaderParameter {
                    binding: parameter.binding.identity.clone(),
                    span: parameter.span,
                    ty,
                    type_origin: CheckOrigin::Source(context.origin(annotation.span)),
                    source_type_explicit: true,
                    mode,
                    callable_use: matches!(parameter.mode, Some((_, ParameterMode::Call))),
                }),
                Err(diagnostic) => diagnostics.push(diagnostic),
            }
        } else if !matches!(
            parameter.annotation.as_ref(),
            Some(ResolvedParameterAnnotation::Shape(_))
        ) {
            parameters.push(HeaderParameter {
                binding: parameter.binding.identity.clone(),
                span: parameter.span,
                ty: if parameter.binding.identity.name == "self" {
                    let owner = normalizer.project.entities[&function_identity]
                        .owner
                        .as_ref()
                        .expect("method owner");
                    if let Some(implementation) = normalizer.selection.implementations.get(owner) {
                        implementation.target.clone()
                    } else {
                        inference.fresh()
                    }
                } else {
                    inference.fresh()
                },
                type_origin: CheckOrigin::Source(parameter.binding.origin.clone()),
                source_type_explicit: false,
                mode,
                callable_use: matches!(parameter.mode, Some((_, ParameterMode::Call))),
            });
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
        None => None,
    };
    let return_type = return_annotation.and_then(|annotation| {
        if public_export
            && let Err(diagnostic) =
                validate_public_type_visibility(public_exports, annotation, &normalizer.aliases)
        {
            diagnostics.push(diagnostic);
        }
        match normalizer.normalize_with_formals(annotation, &formal_by_identity) {
            Ok(ty) => Some((
                ty,
                CheckOrigin::Source(context.origin(annotation.span)),
                true,
            )),
            Err(diagnostic) => {
                diagnostics.push(diagnostic);
                None
            }
        }
    });
    if !diagnostics.is_empty() {
        return Err(diagnostics);
    }
    let (return_type, return_origin, source_return_explicit) = return_type.unwrap_or_else(|| {
        (
            inference.fresh(),
            CheckOrigin::Source(context.origin(function.body.span)),
            false,
        )
    });

    Ok(FunctionHeader {
        identity: function_identity,
        context: context.clone(),
        origin: declaration.origin.clone(),
        public_export,
        declared_formals,
        outer_formals,
        requirements,
        effect_formals,
        effect_upper,
        effect_origin: CheckOrigin::Source(
            context.origin(
                function
                    .effects
                    .as_ref()
                    .map_or(function.body.span, |effects| effects.span),
            ),
        ),
        trait_upper: None,
        trait_effect_origin: None,
        shapes,
        inferable_effects,
        formal_by_identity,
        parameters,
        return_type,
        return_origin,
        source_return_explicit,
        body: Some(function.body.clone()),
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
        CheckedType::Function(item) => format!("function item {}", item.function.name),
        CheckedType::Projection(projection) => format!(
            "{}::{}",
            display_type(&projection.subject),
            projection.member.name
        ),
        CheckedType::Int => "Int".to_owned(),
        CheckedType::Float => "Float".to_owned(),
        CheckedType::Bool => "Bool".to_owned(),
        CheckedType::Unit => "Unit".to_owned(),
        CheckedType::Never => "Never".to_owned(),
        CheckedType::Infer(variable) => format!("?{}", variable.0),
        CheckedType::Formal(formal) => formal.name.clone(),
        CheckedType::Tuple(elements) => format!(
            "({})",
            elements
                .iter()
                .map(display_type)
                .collect::<Vec<_>>()
                .join(", ")
        ),
        CheckedType::Nominal(nominal) => format!(
            "{}<{}>",
            nominal.declaration.name,
            nominal
                .arguments
                .iter()
                .map(display_type)
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

fn is_copy_type(ty: &CheckedType) -> bool {
    match ty {
        CheckedType::Int
        | CheckedType::Float
        | CheckedType::Bool
        | CheckedType::Unit
        | CheckedType::Never => true,
        CheckedType::Tuple(elements) => elements.iter().all(is_copy_type),
        CheckedType::Infer(_)
        | CheckedType::Formal(_)
        | CheckedType::Nominal(_)
        | CheckedType::Projection(_)
        | CheckedType::Function(_) => false,
    }
}

fn cleanup_is_empty(
    requirements: &[CheckedType],
    nominals: &BTreeMap<EntityId, NominalDefinition>,
) -> bool {
    enum Frame<'a> {
        Type(&'a CheckedType),
        Combine(usize),
        EnterNominal(&'a NominalType),
        ExitNominal(&'a EntityId, usize),
    }

    // This proof runs only at an owning cleanup boundary. All traversal state
    // lives in these work vectors, including nominal fields and actuals.
    let mut frames = vec![Frame::Combine(requirements.len())];
    frames.extend(requirements.iter().rev().map(Frame::Type));
    let mut values = Vec::new();
    let mut environments = vec![BTreeMap::new()];
    let mut active = BTreeSet::new();
    while let Some(frame) = frames.pop() {
        match frame {
            Frame::Type(ty) => match ty {
                CheckedType::Formal(formal) => values.push(
                    environments
                        .last()
                        .expect("a cleanup formal has a current environment")
                        .get(formal.as_ref())
                        .copied()
                        .unwrap_or(false),
                ),
                CheckedType::Tuple(elements) => {
                    frames.push(Frame::Combine(elements.len()));
                    frames.extend(elements.iter().rev().map(Frame::Type));
                }
                CheckedType::Nominal(nominal) => {
                    if active.contains(&nominal.declaration) {
                        values.push(false);
                    } else {
                        // Finite actual operands close before this declaration
                        // enters the active field path. This keeps Box<Box<Int>>
                        // distinct from a recursive declaration edge.
                        frames.push(Frame::EnterNominal(nominal));
                        frames.extend(nominal.arguments.iter().rev().map(Frame::Type));
                    }
                }
                CheckedType::Function(_) => values.push(true),
                CheckedType::Infer(_) | CheckedType::Projection(_) => values.push(false),
                CheckedType::Int
                | CheckedType::Float
                | CheckedType::Bool
                | CheckedType::Unit
                | CheckedType::Never => values.push(true),
            },
            Frame::Combine(count) => {
                let start = values
                    .len()
                    .checked_sub(count)
                    .expect("each cleanup operand produces one fact");
                let empty = values[start..].iter().all(|empty| *empty);
                values.truncate(start);
                values.push(empty);
            }
            Frame::EnterNominal(nominal) => {
                let definition = &nominals[&nominal.declaration];
                let first = values
                    .len()
                    .checked_sub(nominal.arguments.len())
                    .expect("nominal actuals have closed cleanup facts");
                environments.push(
                    definition
                        .formals
                        .iter()
                        .cloned()
                        .zip(values.drain(first..))
                        .collect(),
                );
                active.insert(nominal.declaration.clone());
                let field_count = definition
                    .constructors
                    .values()
                    .map(|constructor| constructor.fields.len())
                    .sum();
                frames.push(Frame::ExitNominal(&nominal.declaration, field_count));
                for constructor in definition.constructors.values().rev() {
                    frames.extend(
                        constructor
                            .fields
                            .iter()
                            .rev()
                            .map(|field| Frame::Type(&field.ty)),
                    );
                }
            }
            Frame::ExitNominal(declaration, count) => {
                active.remove(declaration);
                environments.pop();
                frames.push(Frame::Combine(count));
            }
        }
    }
    let [empty] = values.as_slice() else {
        unreachable!("a cleanup demand produces one final fact")
    };
    *empty
}

#[allow(dead_code)]
#[derive(Default)]
struct ContractSelections {
    targets: BTreeMap<EntityId, CheckOrigin>,
    type_parameters: BTreeMap<EntityId, CheckOrigin>,
    parameter_types: BTreeMap<(EntityId, usize), (CheckedType, CheckOrigin)>,
    return_types: BTreeMap<EntityId, (CheckedType, CheckOrigin)>,
    parameter_modes: BTreeMap<(EntityId, usize), (ParameterMode, CheckOrigin)>,
    effect_upper: BTreeMap<EntityId, (EffectRow, CheckOrigin)>,
    generic_requirements: BTreeMap<EntityId, (ContractRequirements, CheckOrigin)>,
}

struct ContractValue<T> {
    value: T,
    path: String,
}

struct ContractRecordUpdate {
    target: EntityId,
    target_path: String,
    type_parameters: Option<String>,
    parameter_types: Vec<(usize, ContractValue<CheckedType>)>,
    return_type: Option<ContractValue<CheckedType>>,
    parameter_modes: Vec<(usize, ContractValue<(ParameterMode, bool)>)>,
    effect_upper: Option<ContractValue<EffectRow>>,
}

fn apply_contract_documents(
    project: &ResolvedProject,
    owners: &BTreeMap<String, LibraryId>,
    documents: &[ContractDocument],
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    normalizer: &SourceTypeNormalizer,
) -> Result<ContractSelections, CheckDiagnostic> {
    let mut selections = ContractSelections {
        generic_requirements: prepare_contract_requirements(
            project, owners, documents, headers, normalizer,
        )?,
        ..ContractSelections::default()
    };
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
    validate_contract_generic_structure(headers, &selections)?;
    Ok(selections)
}

fn validate_contract_generic_structure(
    headers: &BTreeMap<EntityId, FunctionHeader>,
    selections: &ContractSelections,
) -> Result<(), CheckDiagnostic> {
    for (target, target_origin) in &selections.targets {
        let header = headers
            .get(target)
            .expect("every selected contract target remains a checked function");
        if header.declared_formals.is_empty() {
            continue;
        }
        let Some(_) = selections.type_parameters.get(target) else {
            return Err(CheckDiagnostic {
                kind: CheckDiagnosticKind::ContractConflict,
                message: "a generic source function requires an explicit matching contract type-parameter list"
                    .to_owned(),
                primary: Some(target_origin.clone()),
                related: vec![CheckOrigin::Source(header.origin.clone())],
            });
        };
    }
    Ok(())
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
    let target = contract_callable_target(
        project,
        owner,
        document_index,
        record_index,
        record,
        normalizer,
    )?;
    let header = headers.get(&target).expect(
        "declaration/header validation completes before contracts bind an ordinary function",
    );

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
        target_path: target_path.clone(),
        type_parameters: None,
        parameter_types: Vec::new(),
        return_type: None,
        parameter_modes: Vec::new(),
        effect_upper: None,
    };
    if let Some(parameters) = &record.type_parameters {
        let path = format!("{record_path}.type_parameters");
        let unique = parameters
            .iter()
            .map(|parameter| parameter.0.as_str())
            .collect::<BTreeSet<_>>();
        if unique.len() != parameters.len() {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::ContractConflict,
                "a contract type-parameter list cannot contain duplicate binders",
                document_index,
                path,
                vec![CheckOrigin::Source(header.origin.clone())],
            ));
        }
        if parameters.len() != header.declared_formals.len() {
            return Err(contract_diagnostic(
                CheckDiagnosticKind::ContractConflict,
                format!(
                    "contract declares {} type parameter(s) but source declares {}",
                    parameters.len(),
                    header.declared_formals.len()
                ),
                document_index,
                path,
                vec![CheckOrigin::Source(header.origin.clone())],
            ));
        }
        update.type_parameters = Some(format!("{record_path}.type_parameters"));
    }
    let type_context = ContractTypeContext {
        project,
        owner,
        target: &update.target,
        formals: &header.formal_by_identity,
        effect_formals: &header.effect_formals,
        source_origin: &header.origin,
        document_index,
        normalizer,
        headers,
    };
    if let Some(set) = &record.set {
        if let Some(parameter_types) = &set.parameter_types {
            for (clause_index, clause) in parameter_types.0.iter().enumerate() {
                let clause_path = format!("{record_path}.set.parameter_types[{clause_index}]");
                let parameter_index = contract_parameter_index(
                    &clause.parameter,
                    header,
                    document_index,
                    &format!("{clause_path}.parameter"),
                )?;
                let ty = normalize_selected_contract_type(
                    &type_context,
                    &format!("{clause_path}.type"),
                    &clause.value_type,
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
                value: normalize_selected_contract_type(&type_context, &path, return_type)?,
                path,
            });
        }
        if let Some(parameter_modes) = &set.parameter_modes {
            for (clause_index, clause) in parameter_modes.0.iter().enumerate() {
                let clause_path = format!("{record_path}.set.parameter_modes[{clause_index}]");
                let parameter_index = contract_parameter_index(
                    &clause.parameter,
                    header,
                    document_index,
                    &format!("{clause_path}.parameter"),
                )?;
                let mode = match &clause.mode {
                    contract::ModeRule::Fixed {
                        mode: contract::Mode::Borrow,
                    } => (ParameterMode::Borrow, false),
                    contract::ModeRule::Fixed {
                        mode: contract::Mode::Move,
                    } => (ParameterMode::Move, false),
                    contract::ModeRule::CallableUse { callable } => {
                        let callable = normalize_contract_type(
                            &type_context,
                            &format!("{clause_path}.mode.callable"),
                            callable,
                        )?;
                        if callable != header.parameters[parameter_index].ty {
                            return Err(contract_diagnostic(
                                CheckDiagnosticKind::ContractConflict,
                                "callable_use must refer to this parameter's actual callable type",
                                document_index,
                                format!("{clause_path}.mode.callable"),
                                Vec::new(),
                            ));
                        }
                        type_context
                            .normalizer
                            .shared_callable(
                                &callable,
                                &header.requirements,
                                CheckOrigin::Contract {
                                    document_index,
                                    json_path: format!("{clause_path}.mode"),
                                },
                            )
                            .map_err(|mut diagnostic| {
                                diagnostic.kind = CheckDiagnosticKind::Unsupported;
                                diagnostic
                            })?;
                        (ParameterMode::Borrow, true)
                    }
                    contract::ModeRule::Fixed {
                        mode: contract::Mode::Mut,
                    } => {
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
            let path = format!("{record_path}.set.effect_upper");
            update.effect_upper = Some(ContractValue {
                value: type_context.effect_row(effect_upper, &path)?,
                path,
            });
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

                if !matches!(
                    &clause.mode,
                    contract::ModeRule::Fixed {
                        mode: contract::Mode::Borrow | contract::Mode::Move
                    } | contract::ModeRule::CallableUse { .. }
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
        contract::Type::Formal { .. } => None,
        contract::Type::SelfReference { .. } => None,
        contract::Type::Associated {
            base, trait_ref, ..
        } => unsupported_contract_type_path(base, &format!("{path}.base"))
            .or_else(|| {
                trait_ref
                    .arguments
                    .iter()
                    .enumerate()
                    .find_map(|(index, ty)| {
                        unsupported_contract_type_path(
                            ty,
                            &format!("{path}.trait.arguments[{index}]"),
                        )
                    })
            })
            .or_else(|| {
                trait_ref
                    .associated_bindings
                    .iter()
                    .enumerate()
                    .find_map(|(index, binding)| {
                        unsupported_contract_type_path(
                            &binding.value_type,
                            &format!("{path}.trait.associated_bindings[{index}].type"),
                        )
                    })
            }),
        contract::Type::Tuple { elements } => {
            elements.0.iter().enumerate().find_map(|(index, element)| {
                unsupported_contract_type_path(element, &format!("{path}.elements[{index}]"))
            })
        }
        contract::Type::Nominal {
            declaration,
            arguments,
        } if matches!(
            declaration.kind,
            contract::DeclarationKind::TypeAlias
                | contract::DeclarationKind::Struct
                | contract::DeclarationKind::Enum
        ) =>
        {
            arguments.iter().enumerate().find_map(|(index, argument)| {
                unsupported_contract_type_path(argument, &format!("{path}.arguments[{index}]"))
            })
        }
        _ => Some(path.to_owned()),
    }
}

fn contract_parameter_index(
    parameter: &contract::ParameterRef,
    header: &FunctionHeader,
    document_index: usize,
    path: &str,
) -> Result<usize, CheckDiagnostic> {
    let receiver = header
        .parameters
        .first()
        .is_some_and(|parameter| parameter.binding.name == "self");
    let index = match parameter {
        contract::ParameterRef::Receiver {} if receiver => Some(0),
        contract::ParameterRef::Receiver {} => None,
        contract::ParameterRef::Position { index } => usize::try_from(index.0)
            .ok()
            .and_then(|index| index.checked_add(usize::from(receiver))),
    };
    index
        .filter(|index| *index < header.parameters.len())
        .ok_or_else(|| {
            contract_diagnostic(
                CheckDiagnosticKind::ContractBinding,
                "parameter selector does not name this callable's receiver or ordinary parameter",
                document_index,
                path,
                vec![CheckOrigin::Source(header.origin.clone())],
            )
        })
}
struct ContractTypeContext<'a> {
    project: &'a ResolvedProject,
    owner: LibraryId,
    target: &'a EntityId,
    formals: &'a BTreeMap<EntityId, TypeFormal>,
    effect_formals: &'a [EffectFormal],
    source_origin: &'a OriginRef,
    document_index: usize,
    normalizer: &'a SourceTypeNormalizer<'a>,
    headers: &'a BTreeMap<EntityId, FunctionHeader>,
}

fn normalize_contract_type(
    context: &ContractTypeContext<'_>,
    path: &str,
    ty: &contract::Type,
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
                context.document_index,
                path,
                Vec::new(),
            )),
        },
        contract::Type::Tuple { elements } => {
            let mut normalized = Vec::with_capacity(elements.0.len());
            for (index, element) in elements.0.iter().enumerate() {
                normalized.push(normalize_contract_type(
                    context,
                    &format!("{path}.elements[{index}]"),
                    element,
                )?);
            }
            Ok(CheckedType::Tuple(normalized))
        }
        contract::Type::Formal { formal } => context.formal(formal, path),
        contract::Type::SelfReference { owner } => context.self_type(owner, path),
        contract::Type::Associated {
            base,
            trait_ref,
            name,
        } => {
            let subject = normalize_contract_type(context, &format!("{path}.base"), base)?;
            let bound = context.trait_use(trait_ref, &format!("{path}.trait"))?;
            let member = context.project.entities[&bound.declaration]
                .members
                .get(&name.0)
                .into_iter()
                .flatten()
                .find(|member| member.kind == EntityKind::AssociatedType)
                .cloned()
                .ok_or_else(|| {
                    context.error(
                        CheckDiagnosticKind::ContractBinding,
                        path,
                        "associated type member does not exist",
                    )
                })?;
            Ok(CheckedType::Projection(Box::new(Projection {
                subject,
                bound,
                member,
            })))
        }
        contract::Type::Nominal {
            declaration,
            arguments,
        } => {
            let expected_kind = match declaration.kind {
                contract::DeclarationKind::TypeAlias => EntityKind::TypeAlias,
                contract::DeclarationKind::Struct => EntityKind::Struct,
                contract::DeclarationKind::Enum => EntityKind::Enum,
                _ => {
                    return Err(contract_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "contract nominal type kind is outside the current Checker subset",
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
            if target.kind != expected_kind {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::ContractBinding,
                    "nominal contract type does not resolve to its declared kind",
                    context.document_index,
                    path,
                    entity_origin(&target)
                        .map(CheckOrigin::Source)
                        .into_iter()
                        .collect(),
                ));
            }
            if expected_kind != EntityKind::TypeAlias {
                let definition = &context.normalizer.nominals[&target];
                if definition.formals.len() != arguments.len() {
                    return Err(contract_diagnostic(
                        CheckDiagnosticKind::ContractBinding,
                        format!(
                            "nominal type expects {} argument(s) but the contract supplied {}",
                            definition.formals.len(),
                            arguments.len()
                        ),
                        context.document_index,
                        path,
                        entity_origin(&target)
                            .map(CheckOrigin::Source)
                            .into_iter()
                            .collect(),
                    ));
                }
                let arguments = arguments
                    .iter()
                    .enumerate()
                    .map(|(index, argument)| {
                        normalize_contract_type(
                            context,
                            &format!("{path}.arguments[{index}]"),
                            argument,
                        )
                    })
                    .collect::<Result<_, _>>()?;
                return Ok(CheckedType::Nominal(Box::new(NominalType {
                    declaration: target,
                    arguments,
                })));
            }
            let Some(definition) = context.normalizer.aliases.get(&target) else {
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
                    context.document_index,
                    path,
                    vec![CheckOrigin::Source(definition.origin.clone())],
                ));
            }
            if definition.type_parameter_count != 0 {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "generic type aliases are outside the initial Checker subset",
                    context.document_index,
                    path,
                    vec![CheckOrigin::Source(definition.origin.clone())],
                ));
            }
            Ok(context
                .normalizer
                .normalized_aliases
                .get(&target)
                .expect("every supported alias is normalized during declaration checking")
                .clone())
        }
        _ => Err(contract_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "contract type is outside the initial Checker subset",
            context.document_index,
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
    selections
        .targets
        .entry(update.target.clone())
        .or_insert(CheckOrigin::Contract {
            document_index,
            json_path: update.target_path,
        });
    if let Some(path) = update.type_parameters {
        selections
            .type_parameters
            .entry(update.target.clone())
            .or_insert(CheckOrigin::Contract {
                document_index,
                json_path: path,
            });
    }

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
            && previous != &selected.value.0
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
            if matches!(source.origin, CheckOrigin::Source(_)) && source.value != selected.value.0 {
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
                value: selected.value.0,
                origin: origin.clone(),
            });
        }
        parameter.callable_use |= selected.value.1;
        selections
            .parameter_modes
            .entry(key)
            .or_insert((selected.value.0, origin));
    }

    if let Some(selected) = update.effect_upper {
        let origin = CheckOrigin::Contract {
            document_index,
            json_path: selected.path.clone(),
        };
        let mut value = EffectRow::default();
        value.union(&selected.value, &mut TypeInference::default(), &origin)?;
        if let Some((previous, previous_origin)) = selections.effect_upper.get(&update.target) {
            if previous != &value {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::ContractConflict,
                    "partial records select different effect upper bounds",
                    document_index,
                    selected.path,
                    vec![previous_origin.clone()],
                ));
            }
        } else if let Some(source) = &header.effect_upper {
            let mut source_row = EffectRow::default();
            source_row.union(source, &mut TypeInference::default(), &header.effect_origin)?;
            if source_row != value {
                return Err(contract_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "different explicit source and contract effect bounds require a defined difference policy",
                    document_index,
                    selected.path,
                    vec![header.effect_origin.clone()],
                ));
            }
        }
        header.effect_upper = Some(value.clone());
        header.effect_origin = origin.clone();
        selections
            .effect_upper
            .entry(update.target)
            .or_insert((value, origin));
    }
    Ok(())
}

fn validate_public_inputs(
    function_order: &[EntityId],
    headers: &BTreeMap<EntityId, FunctionHeader>,
    selections: &ContractSelections,
) -> Result<(), CheckDiagnostic> {
    for identity in function_order {
        let header = headers
            .get(identity)
            .expect("source-ordered function remains indexed");
        if !header.public_export {
            continue;
        }
        for (index, parameter) in header.parameters.iter().enumerate() {
            if !parameter.source_type_explicit
                && !selections
                    .parameter_types
                    .contains_key(&(identity.clone(), index))
            {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "every actually exported public input type must be explicit in source or its contract",
                    header.context.origin(parameter.span),
                    Vec::new(),
                ));
            }
            if parameter.mode.is_none() {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "every actually exported public input mode must be explicit in source or a supported contract",
                    header.context.origin(parameter.span),
                    Vec::new(),
                ));
            }
        }
    }
    Ok(())
}

fn apply_contract_type_constraints(
    group: &[EntityId],
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    selections: &ContractSelections,
    inference: &mut TypeInference,
) -> Result<(), CheckDiagnostic> {
    for identity in group {
        let header = headers
            .get_mut(identity)
            .expect("a binding-group member remains indexed");
        for (index, parameter) in header.parameters.iter_mut().enumerate() {
            let Some((selected, selected_origin)) =
                selections.parameter_types.get(&(identity.clone(), index))
            else {
                continue;
            };
            reject_contract_specialization(
                &parameter.ty,
                &parameter.type_origin,
                selected_origin,
                inference,
            )?;
            let inferred = inference.resolve(&parameter.ty);
            if !inferred_types_equal(&inferred, selected, inference) {
                return Err(contract_type_conflict(
                    "parameter",
                    &inferred,
                    selected,
                    selected_origin,
                    &parameter.type_origin,
                ));
            }
            if !parameter.source_type_explicit {
                parameter.type_origin = selected_origin.clone();
            }
        }
        if let Some((selected, selected_origin)) = selections.return_types.get(identity) {
            reject_contract_specialization(
                &header.return_type,
                &header.return_origin,
                selected_origin,
                inference,
            )?;
            let inferred = inference.resolve(&header.return_type);
            if !inferred_types_equal(&inferred, selected, inference) {
                return Err(contract_type_conflict(
                    "return",
                    &inferred,
                    selected,
                    selected_origin,
                    &header.return_origin,
                ));
            }
            if !header.source_return_explicit {
                header.return_origin = selected_origin.clone();
            }
        }
    }
    Ok(())
}

fn reject_contract_specialization(
    source: &CheckedType,
    source_origin: &CheckOrigin,
    selected_origin: &CheckOrigin,
    inference: &TypeInference,
) -> Result<(), CheckDiagnostic> {
    let mut unresolved = BTreeSet::new();
    inference.unresolved_variables(source, &mut unresolved);
    if !unresolved.is_empty() {
        return Err(CheckDiagnostic {
            kind: CheckDiagnosticKind::ContractConflict,
            message: "a contract type cannot replace an unresolved source-inferred generic relationship; declare the intended source relationship explicitly"
                .to_owned(),
            primary: Some(selected_origin.clone()),
            related: vec![source_origin.clone()],
        });
    }
    Ok(())
}

fn contract_type_conflict(
    position: &str,
    inferred: &CheckedType,
    selected: &CheckedType,
    selected_origin: &CheckOrigin,
    source_origin: &CheckOrigin,
) -> CheckDiagnostic {
    CheckDiagnostic {
        kind: CheckDiagnosticKind::ContractConflict,
        message: format!(
            "contract {position} type {} conflicts with source-inferred type {}",
            display_type(selected),
            display_type(inferred)
        ),
        primary: Some(selected_origin.clone()),
        related: vec![source_origin.clone()],
    }
}

fn inferred_types_equal(
    inferred: &CheckedType,
    selected: &CheckedType,
    inference: &TypeInference,
) -> bool {
    let inferred = inference.resolve(inferred);
    let selected = inference.resolve(selected);
    match (&inferred, &selected) {
        (CheckedType::Formal(left), CheckedType::Formal(right)) => {
            inference.formals_equivalent(left, right)
        }
        (CheckedType::Tuple(left), CheckedType::Tuple(right)) if left.len() == right.len() => left
            .iter()
            .zip(right)
            .all(|(left, right)| inferred_types_equal(left, right, inference)),
        (CheckedType::Nominal(left), CheckedType::Nominal(right))
            if left.declaration == right.declaration =>
        {
            left.arguments
                .iter()
                .zip(&right.arguments)
                .all(|(left, right)| inferred_types_equal(left, right, inference))
        }
        _ => inferred == selected,
    }
}

fn validate_contracted_inference_is_explicit(
    group: &[EntityId],
    headers: &BTreeMap<EntityId, FunctionHeader>,
    selections: &ContractSelections,
    inference: &TypeInference,
) -> Result<(), CheckDiagnostic> {
    for identity in group {
        let Some(contract_origin) = selections.targets.get(identity) else {
            continue;
        };
        let header = headers
            .get(identity)
            .expect("every contracted group member retains its source header");
        let mut unresolved = BTreeSet::new();
        let mut formals = BTreeSet::new();
        for parameter in &header.parameters {
            collect_inference_inputs(inference, &parameter.ty, &mut unresolved, &mut formals);
        }
        collect_inference_inputs(
            inference,
            &header.return_type,
            &mut unresolved,
            &mut formals,
        );
        if !unresolved.is_empty()
            || formals.iter().any(|formal| {
                !header
                    .declared_formals
                    .iter()
                    .chain(&header.outer_formals)
                    .any(|declared| inference.formals_equivalent(formal, declared))
            })
        {
            return Err(CheckDiagnostic {
                kind: CheckDiagnosticKind::ContractConflict,
                message: "a contracted function retains inferred generic formals that were not explicitly declared by both source and contract"
                    .to_owned(),
                primary: Some(
                    selections
                        .type_parameters
                        .get(identity)
                        .unwrap_or(contract_origin)
                        .clone(),
                ),
                related: vec![CheckOrigin::Source(header.origin.clone())],
            });
        }
    }
    Ok(())
}

#[derive(Clone, Copy)]
enum ValueContext {
    Borrow,
    BorrowResult,
    Consume,
    Discard,
    Return,
}

type ParameterKey = (EntityId, usize);

#[derive(Default)]
struct ModeConstraints {
    required_move: BTreeSet<ParameterKey>,
    implications: BTreeSet<(ParameterKey, ParameterKey)>,
}

fn infer_parameter_modes(
    function_order: &[EntityId],
    headers: &mut BTreeMap<EntityId, FunctionHeader>,
    bodies: &BTreeMap<EntityId, TypedBlock>,
    inference: &TypeInference,
) -> Result<(), CheckDiagnostic> {
    let binding_parameters = headers
        .iter()
        .flat_map(|(function, header)| {
            header
                .parameters
                .iter()
                .enumerate()
                .map(|(index, parameter)| (parameter.binding.clone(), (function.clone(), index)))
        })
        .collect::<BTreeMap<_, _>>();
    let mut constraints = ModeConstraints::default();
    for identity in function_order {
        collect_mode_constraints_block(
            bodies
                .get(identity)
                .expect("every checked function has one closed body"),
            ValueContext::Return,
            headers,
            &binding_parameters,
            &mut constraints,
            inference,
        );
    }

    let mut move_parameters = headers
        .iter()
        .flat_map(|(identity, header)| {
            header
                .parameters
                .iter()
                .enumerate()
                .filter(|(_, parameter)| {
                    parameter
                        .mode
                        .as_ref()
                        .is_some_and(|mode| mode.value == ParameterMode::Move)
                })
                .map(|(index, _)| (identity.clone(), index))
        })
        .chain(constraints.required_move.iter().cloned())
        .collect::<BTreeSet<_>>();
    loop {
        let mut changed = false;
        for (condition, consequence) in &constraints.implications {
            if move_parameters.contains(condition) {
                changed |= move_parameters.insert(consequence.clone());
            }
        }
        if !changed {
            break;
        }
    }

    for identity in function_order {
        let header = headers
            .get_mut(identity)
            .expect("source-ordered function remains indexed");
        for (index, parameter) in header.parameters.iter_mut().enumerate() {
            if parameter.mode.is_none() {
                let value = if move_parameters.contains(&(identity.clone(), index)) {
                    ParameterMode::Move
                } else {
                    ParameterMode::Borrow
                };
                parameter.mode = Some(SelectedMode {
                    value,
                    origin: CheckOrigin::Source(header.context.origin(parameter.span)),
                });
            }
        }
    }
    Ok(())
}

fn collect_mode_constraints_block(
    block: &TypedBlock,
    tail_context: ValueContext,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    binding_parameters: &BTreeMap<EntityId, ParameterKey>,
    constraints: &mut ModeConstraints,
    inference: &TypeInference,
) -> bool {
    for statement in &block.statements {
        let continues = match &statement.kind {
            TypedStatementKind::Let { value, .. } => collect_mode_constraints_expr(
                value,
                ValueContext::Consume,
                headers,
                binding_parameters,
                constraints,
                inference,
            ),
            TypedStatementKind::Return(Some(value)) => {
                collect_mode_constraints_expr(
                    value,
                    ValueContext::Return,
                    headers,
                    binding_parameters,
                    constraints,
                    inference,
                );
                false
            }
            TypedStatementKind::Expression(expression) => collect_mode_constraints_expr(
                expression,
                ValueContext::Discard,
                headers,
                binding_parameters,
                constraints,
                inference,
            ),
            TypedStatementKind::Return(None) => false,
        };
        if !continues {
            return false;
        }
    }
    if let Some(tail) = &block.tail {
        collect_mode_constraints_expr(
            tail,
            tail_context,
            headers,
            binding_parameters,
            constraints,
            inference,
        )
    } else {
        true
    }
}

fn collect_mode_constraints_expr(
    expression: &TypedExpr,
    context: ValueContext,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    binding_parameters: &BTreeMap<EntityId, ParameterKey>,
    constraints: &mut ModeConstraints,
    inference: &TypeInference,
) -> bool {
    match &expression.kind {
        TypedExprKind::FunctionValue(_) => {}
        TypedExprKind::Indirect(call) => {
            if !collect_mode_constraints_expr(
                &call.callable,
                ValueContext::Borrow,
                headers,
                binding_parameters,
                constraints,
                inference,
            ) {
                return false;
            }
            for (argument, mode) in call.arguments.iter().zip(&call.parameter_modes) {
                if !collect_mode_constraints_expr(
                    argument,
                    if *mode == ParameterMode::Move {
                        ValueContext::Consume
                    } else {
                        ValueContext::Borrow
                    },
                    headers,
                    binding_parameters,
                    constraints,
                    inference,
                ) {
                    return false;
                }
            }
        }
        TypedExprKind::Operation(operation) => {
            for (argument, mode) in operation.arguments.iter().zip(&operation.parameter_modes) {
                let context = if *mode == ParameterMode::Move {
                    ValueContext::Consume
                } else {
                    ValueContext::Borrow
                };
                if !collect_mode_constraints_expr(
                    argument,
                    context,
                    headers,
                    binding_parameters,
                    constraints,
                    inference,
                ) {
                    return false;
                }
            }
        }
        TypedExprKind::MethodDraft { .. } => {
            unreachable!("method selection closes before this phase")
        }
        TypedExprKind::Reference { binding, .. } => {
            if matches!(context, ValueContext::Consume | ValueContext::Return)
                && !is_copy_type(&inference.resolve(&expression.ty))
                && let Some(parameter) = binding_parameters.get(binding.as_ref())
            {
                constraints.required_move.insert(parameter.clone());
            }
        }
        TypedExprKind::Parenthesized(inner) => {
            return collect_mode_constraints_expr(
                inner,
                context,
                headers,
                binding_parameters,
                constraints,
                inference,
            );
        }
        TypedExprKind::Tuple(elements) => {
            for element in elements {
                if !collect_mode_constraints_expr(
                    element,
                    ValueContext::Consume,
                    headers,
                    binding_parameters,
                    constraints,
                    inference,
                ) {
                    return false;
                }
            }
        }
        TypedExprKind::Construct(construction) => {
            for field in &construction.fields {
                if !collect_mode_constraints_expr(
                    &field.value,
                    ValueContext::Consume,
                    headers,
                    binding_parameters,
                    constraints,
                    inference,
                ) {
                    return false;
                }
            }
        }
        TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
            return collect_mode_constraints_block(
                block,
                context,
                headers,
                binding_parameters,
                constraints,
                inference,
            );
        }
        TypedExprKind::If {
            condition,
            then_branch,
            else_branch,
        } => {
            if !collect_mode_constraints_expr(
                condition,
                ValueContext::Borrow,
                headers,
                binding_parameters,
                constraints,
                inference,
            ) {
                return false;
            }
            let then_continues = collect_mode_constraints_block(
                then_branch,
                if else_branch.is_some() {
                    context
                } else {
                    ValueContext::Discard
                },
                headers,
                binding_parameters,
                constraints,
                inference,
            );
            let else_continues = if let Some(else_branch) = else_branch {
                collect_mode_constraints_expr(
                    else_branch,
                    context,
                    headers,
                    binding_parameters,
                    constraints,
                    inference,
                )
            } else {
                true
            };
            if !then_continues && !else_continues {
                return false;
            }
        }
        TypedExprKind::Unary { operand, .. } => {
            if !collect_mode_constraints_expr(
                operand,
                ValueContext::Borrow,
                headers,
                binding_parameters,
                constraints,
                inference,
            ) {
                return false;
            }
        }
        TypedExprKind::Binary {
            operator,
            left,
            right,
            ..
        } => {
            if !collect_mode_constraints_expr(
                left,
                ValueContext::Borrow,
                headers,
                binding_parameters,
                constraints,
                inference,
            ) {
                return false;
            }
            let right_continues = collect_mode_constraints_expr(
                right,
                ValueContext::Borrow,
                headers,
                binding_parameters,
                constraints,
                inference,
            );
            if !right_continues
                && !matches!(operator, BinaryOperator::LogicAnd | BinaryOperator::LogicOr)
            {
                return false;
            }
        }
        TypedExprKind::Call {
            callee, arguments, ..
        } => {
            let callee_header = headers
                .get(callee.as_ref())
                .expect("every typed direct call retains a checked function target");
            for (index, (argument, parameter)) in
                arguments.iter().zip(&callee_header.parameters).enumerate()
            {
                let mode = parameter.mode.as_ref().map(|mode| mode.value);
                let context = match mode {
                    Some(ParameterMode::Move) => ValueContext::Consume,
                    Some(ParameterMode::Borrow) | None => ValueContext::Borrow,
                    Some(ParameterMode::MutBorrow | ParameterMode::Call) => unreachable!(
                        "unsupported parameter modes are rejected during header collection"
                    ),
                };
                if !collect_mode_constraints_expr(
                    argument,
                    context,
                    headers,
                    binding_parameters,
                    constraints,
                    inference,
                ) {
                    return false;
                }
                if mode.is_none() {
                    let mut consumed = BTreeSet::new();
                    collect_consumed_parameters(
                        argument,
                        binding_parameters,
                        &mut consumed,
                        inference,
                    );
                    for source in consumed {
                        constraints
                            .implications
                            .insert(((callee.as_ref().clone(), index), source));
                    }
                }
            }
        }
        TypedExprKind::TupleField { receiver, .. } | TypedExprKind::Field { receiver, .. } => {
            if !collect_mode_constraints_expr(
                receiver,
                ValueContext::Borrow,
                headers,
                binding_parameters,
                constraints,
                inference,
            ) {
                return false;
            }
        }
        TypedExprKind::Integer { .. }
        | TypedExprKind::Float(_)
        | TypedExprKind::Boolean(_)
        | TypedExprKind::Unit => {}
    }
    inference.resolve(&expression.ty) != CheckedType::Never
}

fn collect_consumed_parameters(
    expression: &TypedExpr,
    binding_parameters: &BTreeMap<EntityId, ParameterKey>,
    consumed: &mut BTreeSet<ParameterKey>,
    inference: &TypeInference,
) {
    if inference.resolve(&expression.ty) == CheckedType::Never {
        return;
    }
    match &expression.kind {
        TypedExprKind::Reference { binding, .. }
            if !is_copy_type(&inference.resolve(&expression.ty)) =>
        {
            if let Some(parameter) = binding_parameters.get(binding.as_ref()) {
                consumed.insert(parameter.clone());
            }
        }
        TypedExprKind::Parenthesized(inner) => {
            collect_consumed_parameters(inner, binding_parameters, consumed, inference);
        }
        TypedExprKind::Tuple(elements) => {
            for element in elements {
                collect_consumed_parameters(element, binding_parameters, consumed, inference);
            }
        }
        TypedExprKind::If {
            then_branch,
            else_branch: Some(else_branch),
            ..
        } => {
            if inference.resolve(&then_branch.ty) != CheckedType::Never
                && let Some(tail) = &then_branch.tail
            {
                collect_consumed_parameters(tail, binding_parameters, consumed, inference);
            }
            collect_consumed_parameters(else_branch, binding_parameters, consumed, inference);
        }
        TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
            if let Some(tail) = &block.tail {
                collect_consumed_parameters(tail, binding_parameters, consumed, inference);
            }
        }
        _ => {}
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OwnershipKind {
    Borrowed,
    Owned,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Availability {
    Live,
    Moved,
    MaybeMoved,
}

#[derive(Clone)]
struct BindingUsage {
    cleanup: Vec<CheckedType>,
    ownership: OwnershipKind,
    availability: Availability,
    origin: OriginRef,
}

#[derive(Clone, Default)]
struct UsageState {
    bindings: BTreeMap<EntityId, BindingUsage>,
    temporaries: Vec<PendingCleanup>,
    order: Vec<EntityId>,
}

#[derive(Clone)]
struct PendingCleanup {
    origin: OriginRef,
    value_type: CheckedType,
    types: Vec<CheckedType>,
    borrowed: bool,
    availability: Availability,
}

#[derive(Clone, Copy)]
enum CleanupCause {
    ScopeExit,
    FunctionExit,
    FailureExit,
    TemporaryEnd,
}

#[allow(
    dead_code,
    reason = "opaque cleanup carrier keeps each semantic exit location and cause"
)]
#[derive(Clone)]
struct CleanupPoint {
    origin: OriginRef,
    cause: CleanupCause,
    state: UsageState,
    bindings: Vec<EntityId>,
    temporaries: Vec<usize>,
}

impl CleanupPoint {
    fn effect(&self) -> EffectRow {
        let mut types = Vec::new();
        for binding in &self.bindings {
            let usage = &self.state.bindings[binding];
            if usage.ownership == OwnershipKind::Owned && usage.availability != Availability::Moved
            {
                types.extend(usage.cleanup.iter().cloned());
            }
        }
        for index in &self.temporaries {
            let temporary = &self.state.temporaries[*index];
            if temporary.availability != Availability::Moved {
                types.extend(temporary.types.iter().cloned());
            }
        }
        EffectRow(types.into_iter().map(EffectTerm::Destruction).collect())
    }

    fn close(mut self, closure: &BodyClosure<'_>) -> Self {
        for usage in self.state.bindings.values_mut() {
            usage.cleanup = usage
                .cleanup
                .iter()
                .map(|ty| closure.close_type(ty))
                .collect();
        }
        for temporary in &mut self.state.temporaries {
            temporary.value_type = closure.close_type(&temporary.value_type);
            temporary.types = temporary
                .types
                .iter()
                .map(|ty| closure.close_type(ty))
                .collect();
        }
        self
    }
}

struct UsageEnvironment<'a> {
    headers: &'a BTreeMap<EntityId, FunctionHeader>,
    function: &'a FunctionHeader,
    inference: &'a TypeInference,
    cleanups: Vec<CleanupPoint>,
    result_locals: BTreeSet<EntityId>,
}

impl UsageEnvironment<'_> {
    fn may_exit(&self, row: &EffectRow) -> bool {
        row.0.iter().any(|term| {
            if let EffectTerm::SelectedCall(ty) = term {
                let ty = self.inference.canonical(ty);
                if self.function.shapes.iter().any(|shape| {
                    self.inference.canonical(&shape.subject) == ty && !shape.shape.effect.may_exit()
                }) {
                    return false;
                }
            }
            EffectRow(vec![term.clone()]).may_exit()
        })
    }
    fn enter_call(
        &mut self,
        state: &mut UsageState,
        checkpoint: usize,
        may_exit: bool,
        span: Span,
    ) {
        state.take_temporaries(checkpoint);
        if may_exit {
            self.cleanup(
                state,
                state.order.iter().rev().cloned().collect(),
                (0..state.temporaries.len()).rev().collect(),
                CleanupCause::FailureExit,
                self.function.context.origin(span),
            );
        }
    }

    fn cleanup(
        &mut self,
        state: &UsageState,
        bindings: Vec<EntityId>,
        temporaries: Vec<usize>,
        cause: CleanupCause,
        origin: OriginRef,
    ) {
        if bindings.is_empty() && temporaries.is_empty() {
            return;
        }
        self.cleanups.push(CleanupPoint {
            origin,
            cause,
            state: state.clone(),
            bindings,
            temporaries,
        });
    }
}

impl UsageState {
    fn take_temporaries(&mut self, checkpoint: usize) -> Vec<CheckedType> {
        let mut cleanup = Vec::new();
        for temporary in self.temporaries.split_off(checkpoint) {
            if temporary.borrowed {
                self.temporaries.push(temporary);
            } else {
                cleanup.extend(temporary.types);
            }
        }
        cleanup
    }
}

fn validate_whole_value_use(
    function_order: &[EntityId],
    headers: &BTreeMap<EntityId, FunctionHeader>,
    bodies: &mut BTreeMap<EntityId, TypedBlock>,
    inference: &TypeInference,
) -> Result<BTreeMap<EntityId, Vec<CleanupPoint>>, CheckDiagnostic> {
    let mut all_cleanups = BTreeMap::new();
    for identity in function_order {
        let header = &headers[identity];
        let mut state = UsageState::default();
        let mut environment = UsageEnvironment {
            headers,
            function: header,
            inference,
            cleanups: Vec::new(),
            result_locals: BTreeSet::new(),
        };
        for parameter in &header.parameters {
            if is_copy_type(&inference.resolve(&parameter.ty)) {
                continue;
            }
            let mode = parameter
                .mode
                .as_ref()
                .expect("parameter modes precede ownership")
                .value;
            state.bindings.insert(
                parameter.binding.clone(),
                BindingUsage {
                    cleanup: if mode == ParameterMode::Move {
                        vec![inference.resolve(&parameter.ty)]
                    } else {
                        Vec::new()
                    },
                    ownership: if mode == ParameterMode::Move {
                        OwnershipKind::Owned
                    } else {
                        OwnershipKind::Borrowed
                    },
                    availability: Availability::Live,
                    origin: header.context.origin(parameter.span),
                },
            );
            state.order.push(parameter.binding.clone());
        }
        let state = validate_usage_block(
            bodies.get_mut(identity).expect("one body"),
            ValueContext::Return,
            Some(state),
            &mut environment,
        )?;
        if let Some(state) = state {
            record_normal_exit(&state, &mut environment, bodies[identity].span);
        }
        all_cleanups.insert(identity.clone(), environment.cleanups);
    }
    Ok(all_cleanups)
}
fn validate_usage_block(
    block: &mut TypedBlock,
    tail_context: ValueContext,
    state: Option<UsageState>,
    environment: &mut UsageEnvironment<'_>,
) -> Result<Option<UsageState>, CheckDiagnostic> {
    let headers = environment.headers;
    let function = environment.function;
    let inference = environment.inference;
    let mut locals = Vec::new();
    let mut continuation = state;
    for statement in &mut block.statements {
        let Some(state) = continuation.take() else {
            close_unreachable_statement(statement, headers, inference);
            continue;
        };
        let statement_checkpoint = state.temporaries.len();
        match &mut statement.kind {
            TypedStatementKind::Let { binding, ty, value } => {
                let temporary_checkpoint = state.temporaries.len();
                continuation =
                    validate_usage_expr(value, ValueContext::Consume, Some(state), environment)?;
                if let Some(next) = &mut continuation
                    && !is_copy_type(&inference.resolve(ty))
                {
                    let cleanup = next.take_temporaries(temporary_checkpoint);
                    let identity = binding.as_ref().clone();
                    locals.push(identity.clone());
                    next.bindings.insert(
                        identity.clone(),
                        BindingUsage {
                            cleanup,
                            ownership: OwnershipKind::Owned,
                            availability: Availability::Live,
                            origin: entity_origin(&identity)
                                .unwrap_or_else(|| function.context.origin(statement.span)),
                        },
                    );
                    next.order.push(identity);
                }
            }
            TypedStatementKind::Return(value) => {
                continuation = if let Some(value) = value {
                    validate_usage_expr(value, ValueContext::Return, Some(state), environment)?
                } else {
                    Some(state)
                };
                if let Some(exit) = &continuation {
                    record_normal_exit(exit, environment, statement.span);
                }
                continuation = None;
            }
            TypedStatementKind::Expression(expression) => {
                continuation = validate_usage_expr(
                    expression,
                    ValueContext::Discard,
                    Some(state),
                    environment,
                )?;
            }
        }
        if let Some(state) = &mut continuation {
            let temporaries = (statement_checkpoint..state.temporaries.len())
                .rev()
                .filter(|index| state.temporaries[*index].borrowed)
                .collect::<Vec<_>>();
            environment.cleanup(
                state,
                Vec::new(),
                temporaries.clone(),
                CleanupCause::TemporaryEnd,
                function.context.origin(statement.span),
            );
            for index in temporaries {
                state.temporaries.remove(index);
            }
        }
    }
    if let Some(state) = continuation.take() {
        let previous_locals = environment.result_locals.clone();
        let tail_context = if matches!(
            tail_context,
            ValueContext::Borrow | ValueContext::BorrowResult
        ) {
            environment.result_locals.extend(locals.iter().cloned());
            ValueContext::BorrowResult
        } else {
            tail_context
        };
        continuation = if let Some(tail) = &mut block.tail {
            validate_usage_expr(tail, tail_context, Some(state), environment)?
        } else {
            Some(state)
        };
        environment.result_locals = previous_locals;
    } else if let Some(tail) = &mut block.tail {
        close_unreachable_expr(tail, tail_context, headers, inference);
    }
    if let Some(state) = &mut continuation {
        record_scope_cleanup(state, &locals, environment, block.span);
        for local in locals {
            state.bindings.remove(&local);
            state.order.retain(|binding| binding != &local);
        }
    }
    Ok(continuation)
}

fn validate_usage_expr(
    expression: &mut TypedExpr,
    context: ValueContext,
    state: Option<UsageState>,
    environment: &mut UsageEnvironment<'_>,
) -> Result<Option<UsageState>, CheckDiagnostic> {
    let headers = environment.headers;
    let function = environment.function;
    let inference = environment.inference;
    let Some(mut state) = state else {
        close_unreachable_expr(expression, context, headers, inference);
        return Ok(None);
    };
    let expression_span = expression.span;
    let expression_type = inference.resolve(&expression.ty);
    let temporary_checkpoint = state.temporaries.len();
    match &mut expression.kind {
        TypedExprKind::FunctionValue(_) => {
            use_temporary(
                &mut state,
                Vec::new(),
                &expression_type,
                context,
                expression_span,
                environment,
            );
        }
        TypedExprKind::Indirect(call) => {
            let mut continuation = validate_usage_expr(
                &mut call.callable,
                ValueContext::Borrow,
                Some(state),
                environment,
            )?;
            for (argument, mode) in call.arguments.iter_mut().zip(&call.parameter_modes) {
                continuation = validate_usage_expr(
                    argument,
                    if *mode == ParameterMode::Move {
                        ValueContext::Consume
                    } else {
                        ValueContext::Borrow
                    },
                    continuation,
                    environment,
                )?;
            }
            let Some(next) = continuation else {
                return Ok(None);
            };
            state = next;
            environment.enter_call(
                &mut state,
                temporary_checkpoint,
                environment.may_exit(call.effect.as_ref().expect("callback row")),
                expression_span,
            );
            if expression_type == CheckedType::Never {
                return Ok(None);
            }
            let cleanup = if is_copy_type(&expression_type) {
                Vec::new()
            } else {
                vec![expression_type.clone()]
            };
            use_temporary(
                &mut state,
                cleanup,
                &expression_type,
                context,
                expression_span,
                environment,
            );
        }
        TypedExprKind::Operation(operation) => {
            let mut continuation = Some(state);
            for (argument, mode) in operation
                .arguments
                .iter_mut()
                .zip(&operation.parameter_modes)
            {
                let argument_context = if *mode == ParameterMode::Move {
                    ValueContext::Consume
                } else {
                    ValueContext::Borrow
                };
                continuation =
                    validate_usage_expr(argument, argument_context, continuation, environment)?;
            }
            let Some(next) = continuation else {
                return Ok(None);
            };
            state = next;
            environment.enter_call(
                &mut state,
                temporary_checkpoint,
                operation.effect.may_exit(),
                expression_span,
            );
            if expression_type == CheckedType::Never {
                return Ok(None);
            }
            let cleanup = if is_copy_type(&expression_type) {
                Vec::new()
            } else {
                vec![expression_type.clone()]
            };
            use_temporary(
                &mut state,
                cleanup,
                &expression_type,
                context,
                expression_span,
                environment,
            );
        }
        TypedExprKind::MethodDraft { .. } => {
            unreachable!("method selection closes before this phase")
        }
        TypedExprKind::Reference { binding, use_kind } => {
            if is_copy_type(&expression_type) {
                *use_kind = Some(ValueUseKind::Copy);
            } else {
                let usage = state.bindings.get_mut(binding.as_ref()).expect(
                    "every non-Copy typed reference names a tracked parameter or local owner",
                );
                match usage.availability {
                    Availability::Moved => {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "reusing a moved generic value requires later Copy evidence",
                            function.context.origin(expression_span),
                            vec![usage.origin.clone()],
                        ));
                    }
                    Availability::MaybeMoved => {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "using a maybe-moved generic value requires later Copy and control-flow ownership facts",
                            function.context.origin(expression_span),
                            vec![usage.origin.clone()],
                        ));
                    }
                    Availability::Live => {}
                }
                match context {
                    ValueContext::Borrow | ValueContext::BorrowResult => {
                        if matches!(context, ValueContext::BorrowResult)
                            && environment.result_locals.contains(binding.as_ref())
                            && usage.ownership == OwnershipKind::Owned
                        {
                            usage.availability = Availability::Moved;
                            state.temporaries.push(PendingCleanup {
                                origin: function.context.origin(expression_span),
                                value_type: expression_type.clone(),
                                types: usage.cleanup.clone(),
                                borrowed: true,
                                availability: Availability::Live,
                            });
                            *use_kind = Some(ValueUseKind::Move);
                        } else {
                            *use_kind = Some(ValueUseKind::Borrow);
                        }
                    }
                    ValueContext::Consume | ValueContext::Return
                        if usage.ownership == OwnershipKind::Owned =>
                    {
                        usage.availability = Availability::Moved;
                        *use_kind = Some(ValueUseKind::Move);
                        if matches!(context, ValueContext::Consume) {
                            state.temporaries.push(PendingCleanup {
                                origin: function.context.origin(expression_span),
                                types: usage.cleanup.clone(),
                                value_type: expression_type.clone(),
                                borrowed: false,
                                availability: Availability::Live,
                            });
                        }
                    }
                    ValueContext::Consume | ValueContext::Return => {
                        return Err(source_diagnostic(
                            CheckDiagnosticKind::Unsupported,
                            "a borrowed generic value cannot become an owned result without Copy evidence",
                            function.context.origin(expression_span),
                            vec![usage.origin.clone()],
                        ));
                    }
                    ValueContext::Discard => {
                        *use_kind = Some(ValueUseKind::Borrow);
                    }
                }
            }
        }
        TypedExprKind::Parenthesized(inner) => {
            let next = validate_usage_expr(inner, context, Some(state), environment)?;
            return Ok(next);
        }
        TypedExprKind::Tuple(elements) => {
            let mut continuation = Some(state);
            for element in elements.iter_mut() {
                continuation =
                    validate_usage_expr(element, ValueContext::Consume, continuation, environment)?;
            }
            let Some(next) = continuation else {
                return Ok(None);
            };
            state = next;
            let cleanup = state.take_temporaries(temporary_checkpoint);
            use_temporary(
                &mut state,
                cleanup,
                &expression_type,
                context,
                expression_span,
                environment,
            );
        }
        TypedExprKind::Construct(construction) => {
            let mut continuation = Some(state);
            for field in &mut construction.fields {
                continuation = validate_usage_expr(
                    &mut field.value,
                    ValueContext::Consume,
                    continuation,
                    environment,
                )?;
            }
            let Some(next) = continuation else {
                return Ok(None);
            };
            state = next;
            let cleanup = state.take_temporaries(temporary_checkpoint);
            use_temporary(
                &mut state,
                cleanup,
                &expression_type,
                context,
                expression_span,
                environment,
            );
        }
        TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
            let next = validate_usage_block(block, context, Some(state), environment)?;
            return Ok(next);
        }
        TypedExprKind::If {
            condition,
            then_branch,
            else_branch,
        } => {
            let after_condition =
                validate_usage_expr(condition, ValueContext::Borrow, Some(state), environment)?;
            let mut then_state = validate_usage_block(
                then_branch,
                if else_branch.is_some() {
                    context
                } else {
                    ValueContext::Discard
                },
                after_condition.clone(),
                environment,
            )?;
            let mut else_state = if let Some(else_branch) = else_branch {
                validate_usage_expr(else_branch, context, after_condition, environment)?
            } else {
                after_condition
            };
            // Each continuing branch contributes its actual result obligations.
            // Join them before publishing a single result temporary; no cleanup
            // proof is needed when the result is simply moved onward.
            let mut cleanup = Vec::new();
            for branch in [&mut then_state, &mut else_state].into_iter().flatten() {
                cleanup.extend(branch.take_temporaries(temporary_checkpoint));
            }
            let mut joined = merge_usage_states(then_state, else_state);
            if let Some(state) = &mut joined {
                use_temporary(
                    state,
                    cleanup,
                    &expression_type,
                    context,
                    expression_span,
                    environment,
                );
            }
            return Ok(joined);
        }
        TypedExprKind::Unary { operand, .. } => {
            let Some(next) =
                validate_usage_expr(operand, ValueContext::Borrow, Some(state), environment)?
            else {
                return Ok(None);
            };
            state = next;
        }
        TypedExprKind::Binary {
            operator,
            left,
            right,
            ..
        } => {
            let after_left =
                validate_usage_expr(left, ValueContext::Borrow, Some(state), environment)?;
            if matches!(operator, BinaryOperator::LogicAnd | BinaryOperator::LogicOr) {
                let right_state = validate_usage_expr(
                    right,
                    ValueContext::Borrow,
                    after_left.clone(),
                    environment,
                )?;
                return Ok(merge_usage_states(after_left, right_state));
            }
            let Some(next) =
                validate_usage_expr(right, ValueContext::Borrow, after_left, environment)?
            else {
                return Ok(None);
            };
            state = next;
        }
        TypedExprKind::Call {
            callee,
            arguments,
            parameter_modes,
            effect,
            ..
        } => {
            let header = headers
                .get(callee.as_ref())
                .expect("every typed call retains an exact checked callee");
            *parameter_modes = header
                .parameters
                .iter()
                .map(|parameter| {
                    parameter
                        .mode
                        .as_ref()
                        .expect("callee modes are finalized before usage validation")
                        .value
                })
                .collect();
            let mut continuation = Some(state);
            for (argument, parameter) in arguments.iter_mut().zip(&header.parameters) {
                let mode = parameter
                    .mode
                    .as_ref()
                    .expect("callee modes are finalized before usage validation")
                    .value;
                let argument_context = if mode == ParameterMode::Move {
                    ValueContext::Consume
                } else {
                    ValueContext::Borrow
                };
                continuation =
                    validate_usage_expr(argument, argument_context, continuation, environment)?;
            }
            let Some(next) = continuation else {
                return Ok(None);
            };
            state = next;
            environment.enter_call(
                &mut state,
                temporary_checkpoint,
                environment.may_exit(
                    effect
                        .as_ref()
                        .expect("call row is available before ownership constraints"),
                ),
                expression_span,
            );
            if expression_type == CheckedType::Never {
                return Ok(None);
            }
            let cleanup = if is_copy_type(&expression_type) {
                Vec::new()
            } else {
                vec![expression_type.clone()]
            };
            use_temporary(
                &mut state,
                cleanup,
                &expression_type,
                context,
                expression_span,
                environment,
            );
        }
        TypedExprKind::Field {
            receiver, use_kind, ..
        } => {
            let copy = is_copy_type(&expression_type);
            if !copy && matches!(context, ValueContext::Consume | ValueContext::Return) {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "moving a non-Copy field requires later partial-move facts; a borrowed field cannot become owned",
                    function.context.origin(expression_span),
                    vec![function.context.origin(receiver.span)],
                ));
            }
            *use_kind = Some(if copy {
                ValueUseKind::Copy
            } else {
                ValueUseKind::Borrow
            });
            let Some(next) = validate_usage_expr(
                receiver,
                if matches!(context, ValueContext::BorrowResult) {
                    ValueContext::BorrowResult
                } else {
                    ValueContext::Borrow
                },
                Some(state),
                environment,
            )?
            else {
                return Ok(None);
            };
            state = next;
        }
        TypedExprKind::TupleField { receiver, .. } => {
            if !is_copy_type(&inference.resolve(&receiver.ty)) {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "projecting a non-Copy generic tuple requires later partial-move and cleanup facts",
                    function.context.origin(expression_span),
                    vec![function.context.origin(receiver.span)],
                ));
            }
            let Some(next) =
                validate_usage_expr(receiver, ValueContext::Borrow, Some(state), environment)?
            else {
                return Ok(None);
            };
            state = next;
        }
        TypedExprKind::Integer { .. }
        | TypedExprKind::Float(_)
        | TypedExprKind::Boolean(_)
        | TypedExprKind::Unit => {}
    }
    if expression_type == CheckedType::Never {
        Ok(None)
    } else {
        Ok(Some(state))
    }
}

fn close_unreachable_statement(
    statement: &mut TypedStatement,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    inference: &TypeInference,
) {
    match &mut statement.kind {
        TypedStatementKind::Let { value, .. } => {
            close_unreachable_expr(value, ValueContext::Consume, headers, inference);
        }
        TypedStatementKind::Return(Some(value)) => {
            close_unreachable_expr(value, ValueContext::Return, headers, inference);
        }
        TypedStatementKind::Return(None) => {}
        TypedStatementKind::Expression(expression) => {
            close_unreachable_expr(expression, ValueContext::Discard, headers, inference);
        }
    }
}

fn close_unreachable_block(
    block: &mut TypedBlock,
    tail_context: ValueContext,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    inference: &TypeInference,
) {
    for statement in &mut block.statements {
        close_unreachable_statement(statement, headers, inference);
    }
    if let Some(tail) = &mut block.tail {
        close_unreachable_expr(tail, tail_context, headers, inference);
    }
}

fn close_unreachable_expr(
    expression: &mut TypedExpr,
    context: ValueContext,
    headers: &BTreeMap<EntityId, FunctionHeader>,
    inference: &TypeInference,
) {
    let expression_is_copy = is_copy_type(&inference.resolve(&expression.ty));
    match &mut expression.kind {
        TypedExprKind::FunctionValue(_) => {}
        TypedExprKind::Indirect(call) => {
            close_unreachable_expr(&mut call.callable, ValueContext::Borrow, headers, inference);
            for (argument, mode) in call.arguments.iter_mut().zip(&call.parameter_modes) {
                close_unreachable_expr(
                    argument,
                    if *mode == ParameterMode::Move {
                        ValueContext::Consume
                    } else {
                        ValueContext::Borrow
                    },
                    headers,
                    inference,
                );
            }
        }
        TypedExprKind::Operation(operation) => {
            for (argument, mode) in operation
                .arguments
                .iter_mut()
                .zip(&operation.parameter_modes)
            {
                close_unreachable_expr(
                    argument,
                    if *mode == ParameterMode::Move {
                        ValueContext::Consume
                    } else {
                        ValueContext::Borrow
                    },
                    headers,
                    inference,
                );
            }
        }
        TypedExprKind::MethodDraft { .. } => {
            unreachable!("method selection closes before this phase")
        }
        TypedExprKind::Reference { use_kind, .. } => {
            *use_kind = Some(if expression_is_copy {
                ValueUseKind::Copy
            } else if matches!(context, ValueContext::Consume | ValueContext::Return) {
                ValueUseKind::Move
            } else {
                ValueUseKind::Borrow
            });
        }
        TypedExprKind::Parenthesized(inner) => {
            close_unreachable_expr(inner, context, headers, inference);
        }
        TypedExprKind::Tuple(elements) => {
            for element in elements {
                close_unreachable_expr(element, ValueContext::Consume, headers, inference);
            }
        }
        TypedExprKind::Construct(construction) => {
            for field in &mut construction.fields {
                close_unreachable_expr(&mut field.value, ValueContext::Consume, headers, inference);
            }
        }
        TypedExprKind::Field {
            receiver, use_kind, ..
        } => {
            *use_kind = Some(if expression_is_copy {
                ValueUseKind::Copy
            } else {
                ValueUseKind::Borrow
            });
            close_unreachable_expr(receiver, ValueContext::Borrow, headers, inference);
        }
        TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
            close_unreachable_block(block, context, headers, inference);
        }
        TypedExprKind::If {
            condition,
            then_branch,
            else_branch,
        } => {
            close_unreachable_expr(condition, ValueContext::Borrow, headers, inference);
            close_unreachable_block(
                then_branch,
                if else_branch.is_some() {
                    context
                } else {
                    ValueContext::Discard
                },
                headers,
                inference,
            );
            if let Some(else_branch) = else_branch {
                close_unreachable_expr(else_branch, context, headers, inference);
            }
        }
        TypedExprKind::Unary { operand, .. } => {
            close_unreachable_expr(operand, ValueContext::Borrow, headers, inference);
        }
        TypedExprKind::Binary { left, right, .. } => {
            close_unreachable_expr(left, ValueContext::Borrow, headers, inference);
            close_unreachable_expr(right, ValueContext::Borrow, headers, inference);
        }
        TypedExprKind::Call {
            callee,
            arguments,
            parameter_modes,
            ..
        } => {
            let header = headers
                .get(callee.as_ref())
                .expect("every retained call has an exact checked callee");
            *parameter_modes = header
                .parameters
                .iter()
                .map(|parameter| {
                    parameter
                        .mode
                        .as_ref()
                        .expect("callee modes close before retained facts")
                        .value
                })
                .collect();
            for (argument, mode) in arguments.iter_mut().zip(parameter_modes.iter().copied()) {
                close_unreachable_expr(
                    argument,
                    if mode == ParameterMode::Move {
                        ValueContext::Consume
                    } else {
                        ValueContext::Borrow
                    },
                    headers,
                    inference,
                );
            }
        }
        TypedExprKind::TupleField { receiver, .. } => {
            close_unreachable_expr(receiver, ValueContext::Borrow, headers, inference);
        }
        TypedExprKind::Integer { .. }
        | TypedExprKind::Float(_)
        | TypedExprKind::Boolean(_)
        | TypedExprKind::Unit => {}
    }
}

fn use_temporary(
    state: &mut UsageState,
    cleanup: Vec<CheckedType>,
    value_type: &CheckedType,
    context: ValueContext,
    span: Span,
    environment: &mut UsageEnvironment<'_>,
) {
    if !is_copy_type(value_type) && !matches!(context, ValueContext::Return) {
        state.temporaries.push(PendingCleanup {
            origin: environment.function.context.origin(span),
            value_type: value_type.clone(),
            types: cleanup,
            borrowed: matches!(
                context,
                ValueContext::Borrow | ValueContext::BorrowResult | ValueContext::Discard
            ),
            availability: Availability::Live,
        });
    }
}

fn record_scope_cleanup(
    state: &UsageState,
    locals: &[EntityId],
    environment: &mut UsageEnvironment<'_>,
    span: Span,
) {
    environment.cleanup(
        state,
        locals.iter().rev().cloned().collect(),
        Vec::new(),
        CleanupCause::ScopeExit,
        environment.function.context.origin(span),
    );
}

fn record_normal_exit(state: &UsageState, environment: &mut UsageEnvironment<'_>, span: Span) {
    environment.cleanup(
        state,
        state.order.iter().rev().cloned().collect(),
        (0..state.temporaries.len()).rev().collect(),
        CleanupCause::FunctionExit,
        environment.function.context.origin(span),
    );
}
fn merge_usage_states(left: Option<UsageState>, right: Option<UsageState>) -> Option<UsageState> {
    match (left, right) {
        (None, None) => None,
        (Some(state), None) | (None, Some(state)) => Some(state),
        (Some(mut left), Some(right)) => {
            for temporary in &mut left.temporaries {
                if let Some(other) = right
                    .temporaries
                    .iter()
                    .find(|other| other.origin == temporary.origin)
                {
                    if other.availability != temporary.availability {
                        temporary.availability = Availability::MaybeMoved;
                    }
                } else {
                    temporary.availability = Availability::MaybeMoved;
                }
            }
            for mut temporary in right.temporaries {
                if !left
                    .temporaries
                    .iter()
                    .any(|other| other.origin == temporary.origin)
                {
                    temporary.availability = Availability::MaybeMoved;
                    left.temporaries.push(temporary);
                }
            }
            for (identity, right_usage) in right.bindings {
                let left_usage = left
                    .bindings
                    .get_mut(&identity)
                    .expect("branch states retain the same outer binding set");
                debug_assert_eq!(left_usage.ownership, right_usage.ownership);
                if left_usage.availability != right_usage.availability {
                    left_usage.availability = Availability::MaybeMoved;
                }
            }
            Some(left)
        }
    }
}

#[allow(dead_code)]
struct CheckedFunction {
    identity: EntityId,
    origin: OriginRef,
    parameters: Vec<CheckedParameter>,
    scheme: Vec<TypeFormal>,
    instantiation_formals: BTreeSet<TypeFormal>,
    effect_formals: Vec<EffectFormal>,
    shapes: Vec<ShapeRequirement>,
    stored_types: Vec<StoredType>,
    return_type: CheckedType,
    requirements: Vec<Requirement>,
    effect: EffectRow,
    cleanups: Vec<CleanupPoint>,
    body: TypedBlock,
}

#[allow(dead_code)]
struct CheckedParameter {
    binding: EntityId,
    ty: CheckedType,
    mode: ParameterMode,
    callable_use: bool,
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
    FunctionValue(Box<TypedFunctionValue>),
    Indirect(Box<TypedIndirectCall>),
    Reference {
        binding: Box<EntityId>,
        use_kind: Option<ValueUseKind>,
    },
    MethodDraft {
        receiver: Option<Box<TypedExpr>>,
        subject: CheckedType,
        member: ResolvedSelection,
        arguments: Vec<TypedExpr>,
    },
    Parenthesized(Box<TypedExpr>),
    Tuple(Vec<TypedExpr>),
    Construct(Box<TypedConstruction>),
    Block(Box<TypedBlock>),
    Unsafe(Box<TypedBlock>),
    Operation(Box<TypedOperation>),
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
        instantiation: CallInstantiation,
        evidence: Vec<Evidence>,
        return_type: CheckedType,
        effect: Option<EffectRow>,
    },
    TupleField {
        receiver: Box<TypedExpr>,
        index: usize,
    },
    Field {
        receiver: Box<TypedExpr>,
        selection: FieldSelection,
        use_kind: Option<ValueUseKind>,
    },
}

#[allow(dead_code)]
enum FieldSelection {
    Pending(usize),
    Exact(Box<EntityId>, OriginRef),
}

struct TypedConstruction {
    formation: Option<usize>,
    #[allow(
        dead_code,
        reason = "opaque typed construction retains its checked formation evidence"
    )]
    evidence: Vec<Evidence>,
    nominal: NominalType,
    constructor: EntityId,
    fields: Vec<TypedConstructField>,
}

struct TypedConstructField {
    declaration: EntityId,
    origin: OriginRef,
    value: TypedExpr,
}

#[allow(dead_code)]
enum CallInstantiation {
    Pending(BTreeMap<TypeFormal, CheckedType>),
    Published(CallMapping),
    // During inference, the call's exact callee references an unpublished
    // group binding. Group closure resolves that binding's forward receipt.
    RecursiveBinding {
        effects: Vec<(EffectFormal, EffectRow)>,
    },
    Provisional(CallMapping),
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct CallMapping {
    types: Vec<(TypeFormal, CheckedType)>,
    effects: Vec<(EffectFormal, EffectRow)>,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ValueUseKind {
    Borrow,
    Copy,
    Move,
}

#[allow(dead_code)]
struct ComparisonEvidence {
    trait_declaration: EntityId,
    method: EntityId,
    result_carriers: Option<(EntityId, EntityId)>,
    obligation: Option<usize>,
    mapping: CallMapping,
    selection: Vec<Evidence>,
}

enum TypeObligationKind {
    Compatible {
        expected: CheckedType,
    },
    Formation {
        evidence: Vec<Evidence>,
    },
    Numeric,
    Comparison {
        declaration: EntityId,
        evidence: Vec<Evidence>,
    },
    TupleProjection {
        index: usize,
        result: CheckedType,
    },
    FieldProjection {
        field: Box<ResolvedSelection>,
        result: CheckedType,
        selected: Option<Box<EntityId>>,
    },
}

struct TypeObligation {
    owner: EntityId,
    kind: TypeObligationKind,
    ty: CheckedType,
    primary: OriginRef,
    related: Vec<OriginRef>,
}

fn validate_type_obligations(
    obligations: &mut [TypeObligation],
    members: &BTreeSet<EntityId>,
    allow_pending: bool,
    inference: &mut TypeInference,
    normalizer: &SourceTypeNormalizer,
    headers: &BTreeMap<EntityId, FunctionHeader>,
) -> Result<(), CheckDiagnostic> {
    // All projections consume the same body constraints before numeric checks.
    if allow_pending {
        for obligation in obligations.iter() {
            let TypeObligationKind::Compatible { expected } = &obligation.kind else {
                continue;
            };
            if !members.contains(&obligation.owner) {
                continue;
            }
            let mut variables = BTreeSet::new();
            inference.unresolved_variables(expected, &mut variables);
            if !variables.is_empty() {
                continue;
            }
            let givens = headers[&obligation.owner]
                .requirements
                .iter()
                .map(|requirement| requirement.map_types(|ty| inference.canonical(ty)))
                .collect::<Vec<_>>();
            let mut solver = SelectionSolver::new(
                &normalizer.selection,
                &normalizer.project.core_roles,
                &givens,
                CheckOrigin::Source(obligation.primary.clone()),
            )?;
            let expected = solver.normalize(&inference.canonical(expected))?;
            let actual = solver.normalize(&inference.canonical(&obligation.ty))?;
            inference.satisfy(&actual, &expected).map_err(|failure| {
                source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    display_unification_failure(&failure),
                    obligation.primary.clone(),
                    obligation.related.clone(),
                )
            })?;
        }
    }
    let mut pending = obligations
        .iter()
        .enumerate()
        .filter_map(|(index, obligation)| {
            (members.contains(&obligation.owner)
                && matches!(
                    obligation.kind,
                    TypeObligationKind::TupleProjection { .. }
                        | TypeObligationKind::FieldProjection { .. }
                ))
            .then_some(index)
        })
        .collect::<Vec<_>>();
    while !pending.is_empty() {
        let previous_count = pending.len();
        let mut deferred = Vec::new();
        for index in pending {
            let obligation = &mut obligations[index];
            let receiver = inference.receiver_type(&obligation.ty);
            let (field_type, result) = match &mut obligation.kind {
                TypeObligationKind::TupleProjection { index, result } => (
                    tuple_field_type(&receiver, *index, &obligation.primary, &obligation.related)?,
                    result,
                ),
                TypeObligationKind::FieldProjection {
                    field,
                    result,
                    selected,
                } => {
                    let resolved = nominal_field_type(
                        &receiver,
                        field,
                        normalizer.project,
                        &normalizer.nominals,
                    )?;
                    let ty = resolved.map(|(identity, ty)| {
                        *selected = Some(Box::new(identity));
                        ty
                    });
                    (ty, result)
                }
                _ => unreachable!("only projections enter the pending equations"),
            };
            let Some(field_type) = field_type else {
                deferred.push(index);
                continue;
            };
            let givens = headers[&obligation.owner]
                .requirements
                .iter()
                .map(|requirement| requirement.map_types(|ty| inference.canonical(ty)))
                .collect::<Vec<_>>();
            let mut solver = SelectionSolver::new(
                &normalizer.selection,
                &normalizer.project.core_roles,
                &givens,
                CheckOrigin::Source(obligation.primary.clone()),
            )?;
            let field_type = solver.normalize(&inference.canonical(&field_type))?;
            inference
                .unify(&obligation.ty, &receiver)
                .map_err(|failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        display_unification_failure(&failure),
                        obligation.primary.clone(),
                        obligation.related.clone(),
                    )
                })?;
            let constraint = if matches!(inference.resolve(result), CheckedType::Infer(_)) {
                inference.unify(&field_type, result)
            } else {
                inference.satisfy(&field_type, result)
            };
            constraint.map_err(|failure| {
                source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    format!(
                        "projection result is incompatible: {}",
                        display_unification_failure(&failure)
                    ),
                    obligation.primary.clone(),
                    obligation.related.clone(),
                )
            })?;
        }
        if deferred.len() == previous_count {
            if allow_pending {
                return Ok(());
            }
            let obligation = &obligations[deferred[0]];
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "projection requires a known receiver structure after recursive-group inference",
                obligation.primary.clone(),
                obligation.related.clone(),
            ));
        }
        pending = deferred;
    }
    if allow_pending {
        return Ok(());
    }
    for obligation in obligations {
        if !members.contains(&obligation.owner) {
            continue;
        }
        let ty = inference.resolve(&obligation.ty);
        let result = match &mut obligation.kind {
            TypeObligationKind::Compatible { expected } => {
                let givens = headers[&obligation.owner]
                    .requirements
                    .iter()
                    .map(|requirement| requirement.map_types(|ty| inference.canonical(ty)))
                    .collect::<Vec<_>>();
                let mut solver = SelectionSolver::new(
                    &normalizer.selection,
                    &normalizer.project.core_roles,
                    &givens,
                    CheckOrigin::Source(obligation.primary.clone()),
                )?;
                let actual = solver.normalize(&inference.canonical(&ty))?;
                let expected = solver.normalize(&inference.canonical(expected))?;
                inference.satisfy(&actual, &expected).map_err(|failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        format!(
                            "construction field cannot satisfy its declared type: {}",
                            display_unification_failure(&failure)
                        ),
                        obligation.primary.clone(),
                        obligation.related.clone(),
                    )
                })
            }
            TypeObligationKind::Formation { evidence } => {
                let ty = inference.canonical(&ty);
                let givens = headers[&obligation.owner]
                    .requirements
                    .iter()
                    .map(|requirement| requirement.map_types(|ty| inference.canonical(ty)))
                    .collect::<Vec<_>>();
                normalizer.validate_formation(
                    std::slice::from_ref(&ty),
                    &givens,
                    CheckOrigin::Source(obligation.primary.clone()),
                )?;
                let CheckedType::Nominal(nominal) = &ty else {
                    unreachable!("construction keeps its nominal type")
                };
                let mapping = nominal.replacements(&normalizer.nominals);
                let mut solver = SelectionSolver::new(
                    &normalizer.selection,
                    &normalizer.project.core_roles,
                    &givens,
                    CheckOrigin::Source(obligation.primary.clone()),
                )?;
                for requirement in &normalizer.nominals[&nominal.declaration].requirements {
                    solver.prove(&requirement.instantiate(&mapping))?;
                }
                *evidence = solver.evidence;
                Ok(())
            }
            TypeObligationKind::Numeric => match ty {
                CheckedType::Int | CheckedType::Float | CheckedType::Never => Ok(()),
                CheckedType::Infer(_) | CheckedType::Formal(_) => Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "arithmetic on a generic value requires later numeric Trait selection",
                    obligation.primary.clone(),
                    obligation.related.clone(),
                )),
                other => Err(source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    format!("numeric operation does not accept {}", display_type(&other)),
                    obligation.primary.clone(),
                    obligation.related.clone(),
                )),
            },
            TypeObligationKind::Comparison {
                declaration,
                evidence,
            } => {
                let givens = headers[&obligation.owner]
                    .requirements
                    .iter()
                    .map(|requirement| requirement.map_types(|ty| inference.canonical(ty)))
                    .collect::<Vec<_>>();
                let mut solver = SelectionSolver::new(
                    &normalizer.selection,
                    &normalizer.project.core_roles,
                    &givens,
                    CheckOrigin::Source(obligation.primary.clone()),
                )?;
                solver.prove(&Requirement {
                    subject: inference.canonical(&ty),
                    bound: TraitUse {
                        declaration: declaration.clone(),
                        arguments: Vec::new(),
                        associated: BTreeMap::new(),
                    },
                    origin: CheckOrigin::Source(obligation.primary.clone()),
                })?;
                *evidence = solver.evidence;
                Ok(())
            }
            TypeObligationKind::TupleProjection { .. }
            | TypeObligationKind::FieldProjection { .. } => Ok(()),
        };
        result?;
    }
    Ok(())
}

fn nominal_field_type(
    receiver: &CheckedType,
    selection: &ResolvedSelection,
    project: &ResolvedProject,
    nominals: &BTreeMap<EntityId, NominalDefinition>,
) -> Result<Option<(EntityId, CheckedType)>, CheckDiagnostic> {
    let nominal = match receiver {
        CheckedType::Infer(_) => return Ok(None),
        CheckedType::Nominal(nominal) if nominal.declaration.kind == EntityKind::Struct => nominal,
        CheckedType::Formal(_) | CheckedType::Never | CheckedType::Nominal(_) => {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "field selection requires a known ordinary struct receiver",
                selection.origin.clone(),
                Vec::new(),
            ));
        }
        _ => {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "field selection requires a struct receiver",
                selection.origin.clone(),
                Vec::new(),
            ));
        }
    };
    let definition = &nominals[&nominal.declaration].constructors[&nominal.declaration];
    let Some(field) = definition
        .fields
        .iter()
        .find(|field| field.identity.name == selection.name)
    else {
        return Err(source_diagnostic(
            CheckDiagnosticKind::TypeMismatch,
            "struct has no such field",
            selection.origin.clone(),
            entity_origin(&nominal.declaration).into_iter().collect(),
        ));
    };
    if selection
        .declaration
        .as_ref()
        .is_some_and(|identity| identity != &field.identity)
    {
        return Err(source_diagnostic(
            CheckDiagnosticKind::TypeMismatch,
            "field belongs to a different nominal declaration",
            selection.origin.clone(),
            vec![field.origin.clone()],
        ));
    }
    let module = module_for_origin(project, &selection.origin)
        .expect("field occurrence belongs to a source module");
    check_field_access(project, &field.identity, &module, &selection.origin)?;
    Ok(Some((
        field.identity.clone(),
        instantiate_type(&field.ty, &nominal.replacements(nominals)),
    )))
}

fn tuple_field_type(
    receiver: &CheckedType,
    index: usize,
    primary: &OriginRef,
    related: &[OriginRef],
) -> Result<Option<CheckedType>, CheckDiagnostic> {
    match receiver {
        CheckedType::Tuple(elements) => elements.get(index).cloned().map(Some).ok_or_else(|| {
            source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                format!(
                    "tuple projection index {index} is outside a {}-element tuple",
                    elements.len()
                ),
                primary.clone(),
                related.to_vec(),
            )
        }),
        CheckedType::Never => Ok(Some(CheckedType::Never)),
        CheckedType::Infer(_) => Ok(None),
        CheckedType::Formal(_) => Err(source_diagnostic(
            CheckDiagnosticKind::Unsupported,
            "projecting a generic value requires a known tuple structure",
            primary.clone(),
            related.to_vec(),
        )),
        other => Err(source_diagnostic(
            CheckDiagnosticKind::TypeMismatch,
            format!(
                "tuple projection requires a tuple, found {}",
                display_type(other)
            ),
            primary.clone(),
            related.to_vec(),
        )),
    }
}

struct BodyChecker<'project, 'borrow> {
    project: &'project ResolvedProject,
    environment: BodyEnvironment<'borrow>,
    function: &'borrow FunctionHeader,
    normalizer: &'borrow mut SourceTypeNormalizer<'project>,
    inference: &'borrow mut TypeInference,
    obligations: &'borrow mut Vec<TypeObligation>,
    values: BTreeMap<EntityId, CheckedType>,
}

#[derive(Clone, Copy)]
struct BodyEnvironment<'a> {
    headers: &'a BTreeMap<EntityId, FunctionHeader>,
}

impl<'project, 'borrow> BodyChecker<'project, 'borrow> {
    fn new(
        project: &'project ResolvedProject,
        environment: BodyEnvironment<'borrow>,
        function: &'borrow FunctionHeader,
        normalizer: &'borrow mut SourceTypeNormalizer<'project>,
        inference: &'borrow mut TypeInference,
        obligations: &'borrow mut Vec<TypeObligation>,
    ) -> Self {
        let values = function
            .parameters
            .iter()
            .map(|parameter| (parameter.binding.clone(), parameter.ty.clone()))
            .collect();
        Self {
            project,
            environment,
            function,
            normalizer,
            inference,
            obligations,
            values,
        }
    }

    fn origin(&self, span: Span) -> OriginRef {
        self.function.context.origin(span)
    }

    fn is_never(&self, ty: &CheckedType) -> bool {
        self.inference.resolve(ty) == CheckedType::Never
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
                        .normalize_with_formals(annotation, &self.function.formal_by_identity)?;
                    self.inference
                        .satisfy(&value.ty, &annotated)
                        .map_err(|failure| {
                            source_diagnostic(
                                CheckDiagnosticKind::TypeMismatch,
                                format!(
                                    "let annotation cannot match its value: {}",
                                    display_unification_failure(&failure)
                                ),
                                self.origin(annotation.span),
                                vec![self.origin(value.span)],
                            )
                        })?;
                    annotated
                } else {
                    value.ty.clone()
                };
                self.values.insert(binding.identity.clone(), ty.clone());
                let continues = !self.is_never(&value.ty);
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
                if let Err(failure) = self.inference.satisfy(&actual, &self.function.return_type) {
                    let primary = value
                        .as_ref()
                        .map_or_else(|| origin.clone(), |value| self.origin(value.span));
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::ReturnMismatch,
                        format!(
                            "return cannot satisfy the function result: {}",
                            display_unification_failure(&failure)
                        ),
                        primary,
                        vec![origin_as_source(
                            &self.function.return_origin,
                            &self.function.origin,
                        )],
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
                let continues = !self.is_never(&expression.ty);
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
            ResolvedExprKind::NamedConstruct { target, entries } => {
                self.check_named_construction(origin, target, entries)
            }
            ResolvedExprKind::Field { receiver, field } => {
                let receiver = self.check_expr(receiver)?;
                let result = self.inference.fresh();
                let index = self.obligations.len();
                self.obligations.push(TypeObligation {
                    owner: self.function.identity.clone(),
                    kind: TypeObligationKind::FieldProjection {
                        field: Box::new(field.clone()),
                        result: result.clone(),
                        selected: None,
                    },
                    ty: receiver.ty.clone(),
                    primary: field.origin.clone(),
                    related: vec![self.origin(receiver.span)],
                });
                Ok(TypedExpr {
                    span: expression.span,
                    ty: result,
                    kind: TypedExprKind::Field {
                        receiver: Box::new(receiver),
                        selection: FieldSelection::Pending(index),
                        use_kind: None,
                    },
                })
            }
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
                    diverges |= self.is_never(&element.ty);
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
            ResolvedExprKind::MethodCall {
                receiver,
                method,
                arguments,
            } => {
                if let ResolvedExprKind::Path(ResolvedReference::Exact { target, .. }) =
                    &receiver.kind
                    && matches!(target.kind, EntityKind::Effect | EntityKind::LanguageEffect)
                {
                    return self.operation_draft(origin, target, method, arguments);
                }
                let receiver = self.check_expr(receiver)?;
                let subject = receiver.ty.clone();
                self.method_draft(origin, Some(receiver), subject, method.clone(), arguments)
            }
            ResolvedExprKind::Unsafe(block) => {
                let allowed = self
                    .normalizer
                    .module_effects
                    .get(&self.function.identity.module)
                    .is_some_and(|(row, _)| row.0.contains(&EffectTerm::Unsafe));
                if !allowed {
                    return Err(effect_diagnostic(
                        "unsafe discharge requires an explicit module unsafe permission",
                        CheckOrigin::Source(origin),
                    ));
                }
                let block = self.check_block(block)?;
                Ok(TypedExpr {
                    span: expression.span,
                    ty: block.ty.clone(),
                    kind: TypedExprKind::Unsafe(Box::new(block)),
                })
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
        &mut self,
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
        if target.kind == EntityKind::EnumConstructor {
            let (nominal, constructor, _) =
                self.construction_header(reference, &[EntityShape::ConstructorUnit], &origin)?;
            return Ok(self.finish_construction(origin, nominal, constructor, Vec::new()));
        }
        if target.kind == EntityKind::Function {
            return self.function_value_draft(target, origin);
        }
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
            kind: TypedExprKind::Reference {
                binding: Box::new(target.clone()),
                use_kind: None,
            },
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
        if let Err(failure) = self.inference.satisfy(&condition.ty, &CheckedType::Bool) {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                format!(
                    "if condition must be Bool: {}",
                    display_unification_failure(&failure)
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
            join_inferred_types(self.inference, &then_branch.ty, &else_branch.ty).map_err(
                |failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        format!(
                            "if branches have incompatible types: {}",
                            display_unification_failure(&failure)
                        ),
                        self.origin(else_branch.span),
                        vec![self.origin(then_branch.span)],
                    )
                },
            )?
        } else {
            CheckedType::Unit
        };
        let ty = if self.is_never(&condition.ty) {
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
        match operator.1 {
            UnaryOperator::Negate => match self.inference.resolve(&operand.ty) {
                CheckedType::Int | CheckedType::Float | CheckedType::Never => {}
                CheckedType::Infer(_) | CheckedType::Formal(_) => {
                    self.obligations.push(TypeObligation {
                        owner: self.function.identity.clone(),
                        kind: TypeObligationKind::Numeric,
                        ty: operand.ty.clone(),
                        primary: self.origin(operator.0),
                        related: vec![self.origin(operand.span)],
                    });
                }
                other => {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        format!(
                            "unary operator {:?} does not accept {}",
                            operator.1,
                            display_type(&other)
                        ),
                        self.origin(operator.0),
                        vec![self.origin(operand.span)],
                    ));
                }
            },
            UnaryOperator::Not => {
                self.inference
                    .satisfy(&operand.ty, &CheckedType::Bool)
                    .map_err(|failure| {
                        source_diagnostic(
                            CheckDiagnosticKind::TypeMismatch,
                            format!(
                                "logical negation requires Bool: {}",
                                display_unification_failure(&failure)
                            ),
                            self.origin(operator.0),
                            vec![self.origin(operand.span)],
                        )
                    })?;
            }
        }
        Ok(TypedExpr {
            span: origin.span,
            ty: self.inference.resolve(&operand.ty),
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
        let left_never = self.is_never(&left.ty);
        let right_never = self.is_never(&right.ty);
        let diverges = left_never || right_never;
        let (ty, comparison) = match operator.1 {
            BinaryOperator::Add
            | BinaryOperator::Subtract
            | BinaryOperator::Multiply
            | BinaryOperator::Divide
            | BinaryOperator::Remainder => {
                let operand_type = join_inferred_types(self.inference, &left.ty, &right.ty)
                    .map_err(|_| self.binary_type_diagnostic(operator.0, &left, &right))?;
                let operand_type = self.inference.resolve(&operand_type);
                match &operand_type {
                    CheckedType::Int | CheckedType::Float | CheckedType::Never => {}
                    CheckedType::Infer(_) | CheckedType::Formal(_) => {
                        self.obligations.push(TypeObligation {
                            owner: self.function.identity.clone(),
                            kind: TypeObligationKind::Numeric,
                            ty: operand_type.clone(),
                            primary: self.origin(operator.0),
                            related: vec![self.origin(left.span), self.origin(right.span)],
                        });
                    }
                    _ => return Err(self.binary_type_diagnostic(operator.0, &left, &right)),
                }
                (
                    if diverges {
                        CheckedType::Never
                    } else {
                        operand_type
                    },
                    None,
                )
            }
            BinaryOperator::LogicAnd | BinaryOperator::LogicOr => {
                self.inference
                    .satisfy(&left.ty, &CheckedType::Bool)
                    .and_then(|()| self.inference.satisfy(&right.ty, &CheckedType::Bool))
                    .map_err(|_| self.binary_type_diagnostic(operator.0, &left, &right))?;
                (
                    if left_never {
                        CheckedType::Never
                    } else {
                        CheckedType::Bool
                    },
                    None,
                )
            }
            BinaryOperator::Equal | BinaryOperator::NotEqual => {
                let operand_type = join_inferred_types(self.inference, &left.ty, &right.ty)
                    .map_err(|_| self.binary_type_diagnostic(operator.0, &left, &right))?;
                let operand_type = self.inference.resolve(&operand_type);
                let declaration = self.project.core_roles.partial_eq.declaration.clone();
                let obligation = self.obligations.len();
                self.obligations.push(TypeObligation {
                    owner: self.function.identity.clone(),
                    kind: TypeObligationKind::Comparison {
                        declaration: declaration.clone(),
                        evidence: Vec::new(),
                    },
                    ty: operand_type.clone(),
                    primary: self.origin(operator.0),
                    related: vec![self.origin(left.span), self.origin(right.span)],
                });
                let mapping = CallMapping {
                    types: vec![(
                        self.normalizer.selection.traits[&declaration]
                            .self_formal
                            .clone(),
                        operand_type,
                    )],
                    effects: Vec::new(),
                };
                let roles = &self.project.core_roles;
                (
                    if diverges {
                        CheckedType::Never
                    } else {
                        CheckedType::Bool
                    },
                    Some(Box::new(ComparisonEvidence {
                        obligation: Some(obligation),
                        mapping,
                        selection: Vec::new(),
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
                let operand_type = join_inferred_types(self.inference, &left.ty, &right.ty)
                    .map_err(|_| self.binary_type_diagnostic(operator.0, &left, &right))?;
                let operand_type = self.inference.resolve(&operand_type);
                let declaration = self.project.core_roles.partial_ord.declaration.clone();
                let obligation = self.obligations.len();
                self.obligations.push(TypeObligation {
                    owner: self.function.identity.clone(),
                    kind: TypeObligationKind::Comparison {
                        declaration: declaration.clone(),
                        evidence: Vec::new(),
                    },
                    ty: operand_type.clone(),
                    primary: self.origin(operator.0),
                    related: vec![self.origin(left.span), self.origin(right.span)],
                });
                let mapping = CallMapping {
                    types: vec![(
                        self.normalizer.selection.traits[&declaration]
                            .self_formal
                            .clone(),
                        operand_type,
                    )],
                    effects: Vec::new(),
                };
                let roles = &self.project.core_roles;
                (
                    if diverges {
                        CheckedType::Never
                    } else {
                        CheckedType::Bool
                    },
                    Some(Box::new(ComparisonEvidence {
                        obligation: Some(obligation),
                        mapping,
                        selection: Vec::new(),
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
        if let ResolvedExprKind::Path(ResolvedReference::Selection {
            occurrence,
            base,
            members,
            self_reference,
            ..
        }) = &callee.kind
        {
            let (member, prefixes) = members
                .split_last()
                .expect("type-relative call has a member");
            let base = self_reference
                .as_ref()
                .map_or_else(|| base.clone(), |reference| reference.identity.clone());
            let subject = if prefixes.is_empty() && self.normalizer.nominals.contains_key(&base) {
                CheckedType::Nominal(Box::new(NominalType {
                    declaration: base.clone(),
                    arguments: (0..self.normalizer.nominals[&base].formals.len())
                        .map(|_| self.inference.fresh())
                        .collect(),
                }))
            } else {
                let reference = if prefixes.is_empty() {
                    ResolvedReference::Exact {
                        occurrence: occurrence.clone(),
                        target: base,
                        self_reference: None,
                    }
                } else {
                    ResolvedReference::Selection {
                        occurrence: occurrence.clone(),
                        base,
                        namespace: Namespace::Type,
                        members: prefixes.to_vec(),
                        self_reference: None,
                    }
                };
                self.normalizer.normalize_with_formals(
                    &ResolvedType {
                        span: callee.span,
                        kind: ResolvedTypeKind::Named(Box::new(ResolvedNamedType {
                            span: callee.span,
                            reference,
                            arguments: Vec::new(),
                        })),
                    },
                    &self.function.formal_by_identity,
                )?
            };
            return self.method_draft(origin, None, subject, member.clone(), arguments);
        }
        if let ResolvedExprKind::Path(reference @ ResolvedReference::Exact { target, .. }) =
            &callee.kind
            && target.kind == EntityKind::EnumConstructor
        {
            let (nominal, constructor, fields) = self.construction_header(
                reference,
                &[EntityShape::ConstructorPositional],
                &origin,
            )?;
            if arguments.len() != fields.len() {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::CallMismatch,
                    "enum payload argument count does not match its variant",
                    origin,
                    entity_origin(&constructor).into_iter().collect(),
                ));
            }
            let mut typed = Vec::new();
            for (argument, field) in arguments.iter().zip(fields) {
                let ResolvedCallArgument::Expression(value) = argument else {
                    return Err(source_diagnostic(
                        CheckDiagnosticKind::Unsupported,
                        "constructor mode assertions are outside the current Checker subset",
                        origin,
                        Vec::new(),
                    ));
                };
                let value = self.check_expr(value)?;
                typed.push(self.check_construct_field(field, self.origin(value.span), value)?);
            }
            return Ok(self.finish_construction(origin, nominal, constructor, typed));
        }
        let Some(target) = direct_function_callee(callee) else {
            return self.indirect_draft(origin, callee, arguments);
        };
        let header = self.environment.headers.get(&target).ok_or_else(|| {
            source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "the direct callee is not a supported callable",
                self.origin(callee.span),
                entity_origin(&target).into_iter().collect(),
            )
        })?;
        if arguments.len() != header.parameters.len() {
            return Err(source_diagnostic(
                CheckDiagnosticKind::CallMismatch,
                "call argument count does not match the declaration",
                origin,
                vec![header.origin.clone()],
            ));
        }
        let mut typed_arguments = Vec::with_capacity(arguments.len());
        for argument in arguments {
            let ResolvedCallArgument::Expression(argument) = argument else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "call-site mut/move assertions remain unsupported",
                    origin,
                    Vec::new(),
                ));
            };
            typed_arguments.push(self.check_expr(argument)?);
        }
        let return_type = if self.inference.resolve(&header.return_type) == CheckedType::Never {
            CheckedType::Never
        } else {
            self.inference.fresh()
        };
        let ty = if typed_arguments
            .iter()
            .any(|argument| self.is_never(&argument.ty))
        {
            CheckedType::Never
        } else {
            return_type.clone()
        };
        Ok(TypedExpr {
            span: origin.span,
            ty,
            kind: TypedExprKind::Call {
                callee: Box::new(target),
                arguments: typed_arguments,
                parameter_modes: Vec::new(),
                instantiation: CallInstantiation::Pending(BTreeMap::new()),
                evidence: Vec::new(),
                return_type,
                effect: None,
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
        let receiver_type = self.inference.resolve(&receiver.ty);
        let related = vec![self.origin(receiver.span)];
        let ty = if let Some(ty) = tuple_field_type(&receiver_type, index, index_origin, &related)?
        {
            ty
        } else {
            let result = self.inference.fresh();
            self.obligations.push(TypeObligation {
                owner: self.function.identity.clone(),
                kind: TypeObligationKind::TupleProjection {
                    index,
                    result: result.clone(),
                },
                ty: receiver.ty.clone(),
                primary: index_origin.clone(),
                related,
            });
            result
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

impl BodyChecker<'_, '_> {
    fn construction_header(
        &mut self,
        reference: &ResolvedReference,
        shapes: &[EntityShape],
        origin: &OriginRef,
    ) -> Result<(NominalType, EntityId, Vec<NominalField>), CheckDiagnostic> {
        let ResolvedReference::Exact { target, .. } = reference else {
            return Err(source_diagnostic(
                CheckDiagnosticKind::Unsupported,
                "type-dependent construction is outside the current Checker subset",
                origin.clone(),
                Vec::new(),
            ));
        };
        let nominal = {
            let owner = if target.kind == EntityKind::EnumConstructor {
                self.project.entities[target]
                    .owner
                    .as_ref()
                    .expect("variant retains its nominal owner")
                    .clone()
            } else {
                target.clone()
            };
            let Some(definition) = self.normalizer.nominals.get(&owner) else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "construction target is outside the current Checker subset",
                    origin.clone(),
                    entity_origin(target).into_iter().collect(),
                ));
            };
            NominalType {
                declaration: owner,
                arguments: definition
                    .formals
                    .iter()
                    .map(|_| self.inference.fresh())
                    .collect(),
            }
        };
        let constructor = if target.kind == EntityKind::EnumConstructor {
            target.clone()
        } else {
            nominal.declaration.clone()
        };
        let definition = &self.normalizer.nominals[&nominal.declaration];
        let Some(fields) = definition
            .constructors
            .get(&constructor)
            .filter(|fields| shapes.contains(&fields.shape))
        else {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                "construction syntax does not match the nominal or variant payload shape",
                origin.clone(),
                entity_origin(&constructor).into_iter().collect(),
            ));
        };
        let replacements = nominal.replacements(&self.normalizer.nominals);
        let fields = fields
            .fields
            .iter()
            .map(|field| NominalField {
                ty: instantiate_type(&field.ty, &replacements),
                ..field.clone()
            })
            .collect();
        Ok((nominal, constructor, fields))
    }

    fn check_named_construction(
        &mut self,
        origin: OriginRef,
        target: &ResolvedReference,
        entries: &[ResolvedConstructEntry],
    ) -> Result<TypedExpr, CheckDiagnostic> {
        let (nominal, constructor, fields) = self.construction_header(
            target,
            &[EntityShape::Plain, EntityShape::ConstructorNamed],
            &origin,
        )?;
        let module = module_for_origin(self.project, &origin)
            .expect("construction belongs to a resolved module");
        let mut remaining = fields
            .iter()
            .map(|field| (field.identity.clone(), field.clone()))
            .collect::<BTreeMap<_, _>>();
        let mut typed = Vec::new();
        for entry in entries {
            let ResolvedConstructEntry::Field {
                member,
                value,
                shorthand,
            } = entry
            else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::Unsupported,
                    "struct update spread is outside the current Checker subset",
                    origin,
                    Vec::new(),
                ));
            };
            let identity = member.declaration.as_ref();
            let Some(field) = identity.and_then(|identity| remaining.remove(identity)) else {
                return Err(source_diagnostic(
                    CheckDiagnosticKind::TypeMismatch,
                    "duplicate, unknown, or foreign construction field",
                    member.origin.clone(),
                    entity_origin(&constructor).into_iter().collect(),
                ));
            };
            check_field_access(self.project, &field.identity, &module, &member.origin)?;
            let value = if let Some(value) = value {
                self.check_expr(value)?
            } else {
                self.check_value_reference(
                    shorthand
                        .as_deref()
                        .expect("field shorthand retains its reference"),
                    member.origin.clone(),
                )?
            };
            typed.push(self.check_construct_field(field, member.origin.clone(), value)?);
        }
        if !remaining.is_empty() {
            return Err(source_diagnostic(
                CheckDiagnosticKind::TypeMismatch,
                format!(
                    "construction is missing field(s): {}",
                    remaining
                        .keys()
                        .map(|identity| identity.name.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
                origin,
                remaining
                    .values()
                    .map(|field| field.origin.clone())
                    .collect(),
            ));
        }
        Ok(self.finish_construction(origin, nominal, constructor, typed))
    }

    fn check_construct_field(
        &mut self,
        field: NominalField,
        origin: OriginRef,
        value: TypedExpr,
    ) -> Result<TypedConstructField, CheckDiagnostic> {
        if has_projection(&field.ty) || has_projection(&value.ty) {
            self.obligations.push(TypeObligation {
                owner: self.function.identity.clone(),
                kind: TypeObligationKind::Compatible {
                    expected: field.ty.clone(),
                },
                ty: value.ty.clone(),
                primary: self.origin(value.span),
                related: vec![field.origin.clone()],
            });
        } else {
            self.inference
                .satisfy(&value.ty, &field.ty)
                .map_err(|failure| {
                    source_diagnostic(
                        CheckDiagnosticKind::TypeMismatch,
                        format!(
                            "construction field cannot satisfy its declared type: {}",
                            display_unification_failure(&failure)
                        ),
                        self.origin(value.span),
                        vec![field.origin],
                    )
                })?;
        }
        Ok(TypedConstructField {
            declaration: field.identity,
            origin,
            value,
        })
    }

    fn finish_construction(
        &mut self,
        origin: OriginRef,
        nominal: NominalType,
        constructor: EntityId,
        fields: Vec<TypedConstructField>,
    ) -> TypedExpr {
        let formation = self.obligations.len();
        self.obligations.push(TypeObligation {
            owner: self.function.identity.clone(),
            kind: TypeObligationKind::Formation {
                evidence: Vec::new(),
            },
            ty: CheckedType::Nominal(Box::new(nominal.clone())),
            primary: origin.clone(),
            related: Vec::new(),
        });
        let ty = if fields.iter().any(|field| self.is_never(&field.value.ty)) {
            CheckedType::Never
        } else {
            CheckedType::Nominal(Box::new(nominal.clone()))
        };
        TypedExpr {
            span: origin.span,
            ty,
            kind: TypedExprKind::Construct(Box::new(TypedConstruction {
                formation: Some(formation),
                evidence: Vec::new(),
                nominal,
                constructor,
                fields,
            })),
        }
    }
}

fn check_field_access(
    project: &ResolvedProject,
    field: &EntityId,
    module: &ModuleRef,
    origin: &OriginRef,
) -> Result<(), CheckDiagnostic> {
    if project.entities[field].public || module.is_descendant_of(&field.module) {
        return Ok(());
    }
    Err(source_diagnostic(
        CheckDiagnosticKind::TypeMismatch,
        "field is private to its declaring module",
        origin.clone(),
        entity_origin(field).into_iter().collect(),
    ))
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

fn join_inferred_types(
    inference: &mut TypeInference,
    left: &CheckedType,
    right: &CheckedType,
) -> Result<CheckedType, UnificationFailure> {
    let left = inference.resolve(left);
    let right = inference.resolve(right);
    if left == CheckedType::Never {
        return Ok(right);
    }
    if right == CheckedType::Never {
        return Ok(left);
    }
    if let (CheckedType::Tuple(left), CheckedType::Tuple(right)) = (&left, &right)
        && left.len() == right.len()
    {
        return left
            .iter()
            .zip(right)
            .map(|(left, right)| join_inferred_types(inference, left, right))
            .collect::<Result<Vec<_>, _>>()
            .map(CheckedType::Tuple);
    }
    inference.unify(&left, &right)?;
    Ok(inference.resolve(&left))
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

    fn assert_closed_type(ty: &CheckedType, scheme: &[TypeFormal]) {
        match ty {
            CheckedType::Infer(variable) => {
                panic!("published Checker result retained ?{}", variable.0)
            }
            CheckedType::Tuple(elements) => {
                for element in elements {
                    assert_closed_type(element, scheme);
                }
            }
            CheckedType::Nominal(nominal) => {
                for actual in &nominal.arguments {
                    assert_closed_type(actual, scheme);
                }
            }
            CheckedType::Projection(projection) => {
                for ty in projection.types() {
                    assert_closed_type(ty, scheme);
                }
            }
            CheckedType::Function(item) => {
                for ty in item.types() {
                    assert_closed_type(ty, scheme);
                }
            }
            CheckedType::Formal(formal) => assert!(
                scheme.contains(formal.as_ref()),
                "published type has free formal {}::{}",
                formal.owner.name,
                formal.name,
            ),
            _ => {}
        }
    }

    fn assert_closed_block(block: &TypedBlock, scheme: &[TypeFormal]) {
        assert_closed_type(&block.ty, scheme);
        for statement in &block.statements {
            match &statement.kind {
                TypedStatementKind::Let { ty, value, .. } => {
                    assert_closed_type(ty, scheme);
                    assert_closed_expr(value, scheme);
                }
                TypedStatementKind::Return(Some(value)) | TypedStatementKind::Expression(value) => {
                    assert_closed_expr(value, scheme)
                }
                TypedStatementKind::Return(None) => {}
            }
        }
        if let Some(tail) = &block.tail {
            assert_closed_expr(tail, scheme);
        }
    }

    fn assert_closed_expr(expression: &TypedExpr, scheme: &[TypeFormal]) {
        assert_closed_type(&expression.ty, scheme);
        match &expression.kind {
            TypedExprKind::FunctionValue(value) => {
                assert!(value.mapping.is_some());
            }
            TypedExprKind::Indirect(call) => {
                assert!(call.effect.is_some());
                assert_closed_expr(&call.callable, scheme);
                for argument in &call.arguments {
                    assert_closed_expr(argument, scheme);
                }
            }
            TypedExprKind::Operation(operation) => {
                for argument in &operation.arguments {
                    assert_closed_expr(argument, scheme);
                }
                for (_, actual) in &operation.mapping.types {
                    assert_closed_type(actual, scheme);
                }
            }
            TypedExprKind::MethodDraft { .. } => {
                unreachable!("method selection closes before this phase")
            }
            TypedExprKind::Construct(construction) => {
                for actual in &construction.nominal.arguments {
                    assert_closed_type(actual, scheme);
                }
                for field in &construction.fields {
                    assert_closed_expr(&field.value, scheme);
                }
            }
            TypedExprKind::Field {
                receiver,
                selection,
                use_kind,
            } => {
                assert_closed_expr(receiver, scheme);
                let FieldSelection::Exact(identity, origin) = selection else {
                    panic!("field must retain an exact closed selection")
                };
                assert_eq!(identity.kind, EntityKind::Field);
                assert_eq!(
                    origin.library,
                    scheme.first().map_or(origin.library, |formal| formal
                        .owner
                        .module
                        .source_library()
                        .unwrap())
                );
                assert!(use_kind.is_some());
            }
            TypedExprKind::Parenthesized(inner)
            | TypedExprKind::Unary { operand: inner, .. }
            | TypedExprKind::TupleField {
                receiver: inner, ..
            } => assert_closed_expr(inner, scheme),
            TypedExprKind::Tuple(elements) => {
                for element in elements {
                    assert_closed_expr(element, scheme);
                }
            }
            TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
                assert_closed_block(block, scheme)
            }
            TypedExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => {
                assert_closed_expr(condition, scheme);
                assert_closed_block(then_branch, scheme);
                if let Some(else_branch) = else_branch {
                    assert_closed_expr(else_branch, scheme);
                }
            }
            TypedExprKind::Binary { left, right, .. } => {
                assert_closed_expr(left, scheme);
                assert_closed_expr(right, scheme);
            }
            TypedExprKind::Call {
                arguments,
                parameter_modes,
                instantiation,
                ..
            } => {
                assert_eq!(parameter_modes.len(), arguments.len());
                for argument in arguments {
                    assert_closed_expr(argument, scheme);
                }
                match instantiation {
                    CallInstantiation::Published(mapping)
                    | CallInstantiation::Provisional(mapping) => {
                        for (_, actual) in &mapping.types {
                            assert_closed_type(actual, scheme);
                        }
                    }
                    CallInstantiation::RecursiveBinding { .. } | CallInstantiation::Pending(_) => {
                        panic!("published body retains an unfinished group binding")
                    }
                }
            }
            TypedExprKind::Integer { .. }
            | TypedExprKind::Float(_)
            | TypedExprKind::Boolean(_)
            | TypedExprKind::Unit => {}
            TypedExprKind::Reference { use_kind, .. } => {
                assert!(
                    use_kind.is_some(),
                    "every retained reference has an actual use kind"
                );
            }
        }
    }

    #[test]
    fn nominal_result_retains_owner_actual_constructor_field_and_closed_body_facts() {
        let checked = crate::check_project(
            &sources(
                r#"
struct Box<T> { value: T }
enum Choice<T> { Named { second: Int, first: T }, Empty }
fn observe<T>(value: &T) {}
fn field<T>(value: &Box<T>) { observe(value.value); }
fn wrap<T>(value: T) -> Box<T> { Box { value } }
fn relay<T>(value: Box<T>) -> Box<T> { if true { relay(value) } else { value } }
fn ordered<T>(value: T) -> Choice<T> { Choice::Named { first: value, second: 1 } }
fn concrete() -> Option<Int> { Option::Some(1) }
"#,
            ),
            &BTreeMap::new(),
            Vec::new(),
        )
        .expect("nominal facts close before publication");
        for (identity, definition) in &checked.nominals {
            for formal in &definition.formals {
                assert_eq!(&formal.owner, identity);
            }
            for constructor in definition.constructors.values() {
                for field in &constructor.fields {
                    assert_closed_type(&field.ty, &definition.formals);
                }
            }
        }
        for function in checked.functions.values() {
            for parameter in &function.parameters {
                assert_closed_type(&parameter.ty, &function.scheme);
            }
            assert_closed_type(&function.return_type, &function.scheme);
            assert_closed_block(&function.body, &function.scheme);
        }
        let ordered = checked
            .functions
            .values()
            .find(|function| function.identity.name == "ordered")
            .unwrap();
        let TypedExprKind::Construct(construction) = &ordered.body.tail.as_ref().unwrap().kind
        else {
            panic!("constructor is a distinct typed operation")
        };
        assert_eq!(
            construction
                .fields
                .iter()
                .map(|field| field.declaration.name.as_str())
                .collect::<Vec<_>>(),
            ["first", "second"]
        );
        assert!(
            construction.fields[0].origin.span.start < construction.fields[1].origin.span.start
        );
        assert_eq!(
            checked.prepared.0.entities[&construction.constructor]
                .owner
                .as_ref(),
            Some(&construction.nominal.declaration)
        );
        assert_eq!(
            construction.nominal.arguments,
            vec![CheckedType::Formal(Box::new(ordered.scheme[0].clone()))]
        );
        for field in &construction.fields {
            assert_eq!(
                checked.prepared.0.entities[&field.declaration]
                    .owner
                    .as_ref(),
                Some(&construction.constructor)
            );
        }
        let concrete = checked
            .functions
            .values()
            .find(|function| function.identity.name == "concrete")
            .unwrap();
        let TypedExprKind::Construct(construction) = &concrete.body.tail.as_ref().unwrap().kind
        else {
            panic!("Option construction is retained")
        };
        assert_eq!(
            construction.constructor,
            checked.prepared.0.core_roles.option.some
        );
        assert_eq!(
            construction.nominal.declaration,
            checked.prepared.0.core_roles.option.declaration
        );
        assert_eq!(construction.nominal.arguments, vec![CheckedType::Int]);
    }

    #[test]
    fn opaque_result_retains_real_typed_literal_callee_mode_and_origin_facts() {
        let source = "type Number = Int; type Standalone = Bool; \
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
        assert_eq!(checked.aliases.len(), 2);
        assert!(checked.aliases.values().any(|ty| ty == &CheckedType::Int));
        assert!(checked.aliases.values().any(|ty| ty == &CheckedType::Bool));

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
        assert!(callee.effect.0.is_empty());
        assert_eq!(callee.parameters[0].mode, ParameterMode::Move);
        assert_eq!(callee.parameters[0].ty, CheckedType::Int);

        let tail = caller.body.tail.as_deref().expect("caller tail");
        let TypedExprKind::Call {
            callee: exact_callee,
            arguments,
            parameter_modes,
            ..
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
    fn hm_result_retains_one_closed_scheme_mapping_and_provisional_recursive_call() {
        let checked = check_project(
            &sources(
                "fn identity(value) { value } \
                 fn repeat<T>(value: T, depth: Int) -> T { \
                     if depth == 0 { value } else { repeat(value, depth - 1) } \
                 } \
                 fn main() -> (Int, Bool) { (identity(1), identity(true)) }",
            ),
            &BTreeMap::new(),
            Vec::new(),
        )
        .expect("HM source checks");

        let identity = checked
            .functions
            .values()
            .find(|function| function.identity.name == "identity")
            .expect("identity function");
        assert_eq!(identity.scheme.len(), 1);
        assert_eq!(
            identity.parameters[0].ty,
            CheckedType::Formal(Box::new(identity.scheme[0].clone()))
        );
        assert_eq!(identity.return_type, identity.parameters[0].ty);
        assert_eq!(identity.parameters[0].mode, ParameterMode::Move);

        let main = checked
            .functions
            .values()
            .find(|function| function.identity.name == "main")
            .expect("main function");
        let TypedExprKind::Tuple(calls) = &main.body.tail.as_deref().expect("main tail").kind
        else {
            panic!("main returns the two calls")
        };
        for (call, expected) in calls.iter().zip([CheckedType::Int, CheckedType::Bool]) {
            let TypedExprKind::Call { instantiation, .. } = &call.kind else {
                panic!("tuple element is a direct call")
            };
            let CallInstantiation::Published(mapping) = instantiation else {
                panic!("group-external use instantiates the published scheme")
            };
            assert_eq!(mapping.types.len(), 1);
            assert_eq!(mapping.types[0].0, identity.scheme[0]);
            assert_eq!(mapping.types[0].1, expected);
        }

        let repeat = checked
            .functions
            .values()
            .find(|function| function.identity.name == "repeat")
            .expect("repeat function");
        let TypedExprKind::If {
            else_branch: Some(else_branch),
            ..
        } = &repeat.body.tail.as_deref().expect("repeat tail").kind
        else {
            panic!("repeat body is the recursive conditional")
        };
        let recursive = match &else_branch.kind {
            TypedExprKind::Call { instantiation, .. } => instantiation,
            TypedExprKind::Block(block) | TypedExprKind::Unsafe(block) => {
                let TypedExprKind::Call { instantiation, .. } =
                    &block.tail.as_deref().expect("recursive block tail").kind
                else {
                    panic!("repeat else block ends in its direct recursive call")
                };
                instantiation
            }
            _ => panic!("repeat else branch is its direct recursive call"),
        };
        let CallInstantiation::Provisional(mapping) = recursive else {
            panic!("a recursive call retains its shared group actuals");
        };
        assert_eq!(
            &mapping.types,
            &vec![(
                repeat.scheme[0].clone(),
                CheckedType::Formal(Box::new(repeat.scheme[0].clone()))
            )]
        );

        for function in checked.functions.values() {
            for parameter in &function.parameters {
                assert_closed_type(&parameter.ty, &function.scheme);
            }
            assert_closed_type(&function.return_type, &function.scheme);
            assert_closed_block(&function.body, &function.scheme);
        }
    }

    #[test]
    fn unreachable_retained_calls_still_have_closed_mode_and_use_facts() {
        let checked = check_project(
            &sources(
                "fn identity(value) { value } \
                 fn f(value: Int) -> Int { return value; identity(value); }",
            ),
            &BTreeMap::new(),
            Vec::new(),
        )
        .expect("unreachable source remains a closed typed body fact");
        let function = checked
            .functions
            .values()
            .find(|function| function.identity.name == "f")
            .expect("f function");
        let TypedStatementKind::Expression(call) = &function.body.statements[1].kind else {
            panic!("second retained statement is the unreachable call")
        };
        let TypedExprKind::Call {
            arguments,
            parameter_modes,
            ..
        } = &call.kind
        else {
            panic!("retained expression is a call")
        };
        let TypedExprKind::Reference { use_kind, .. } = &arguments[0].kind else {
            panic!("retained argument is the exact reference")
        };
        assert_eq!(parameter_modes, &[ParameterMode::Move]);
        assert_eq!(*use_kind, Some(ValueUseKind::Copy));
    }

    #[test]
    fn nested_divergence_retains_closed_use_and_call_facts() {
        for body in [
            "(stop(), id(x)); stop()",
            "id(stop()) + id(x)",
            "take(stop(), id(x))",
            "if stop() { id(x) } else { id(x) }",
        ] {
            let checked = check_project(
                &sources(&format!(
                    "fn stop() -> Never {{ stop() }} \
                     fn id(x: Int) -> Int {{ x }} \
                     fn take(x: Int, y: Int) -> Int {{ x + y }} \
                     fn f(x: Int) -> Never {{ {body} }}"
                )),
                &BTreeMap::new(),
                Vec::new(),
            )
            .expect("nested divergence still retains closed typed facts");
            for function in checked.functions.values() {
                assert_closed_block(&function.body, &function.scheme);
            }
        }
    }

    #[test]
    fn nested_unreachable_uses_do_not_infer_move_parameters() {
        for body in [
            "({ return y; }, x);",
            "take({ return y; }, x);",
            "return y; x;",
        ] {
            let checked = check_project(
                &sources(&format!(
                    "fn take<T>(n: Int, x: move T) -> T {{ x }} \
                     fn f<T>(x: T, y: move T) -> T {{ {body} }}"
                )),
                &BTreeMap::new(),
                Vec::new(),
            )
            .expect("unreachable ownership uses cannot change the calling convention");
            let function = checked
                .functions
                .values()
                .find(|function| function.identity.name == "f")
                .unwrap();
            assert_eq!(function.parameters[0].mode, ParameterMode::Borrow);
            assert_closed_block(&function.body, &function.scheme);
        }
    }

    #[test]
    fn body_only_call_actuals_do_not_expand_the_callable_scheme() {
        let source = "fn unused<T>() -> Int { 1 } pub fn caller() -> Int { unused() }";
        let document = crate::decode_contract(br#"{"format":"vorton.contract","format_version":1,"semantics_version":"0.1","owner":"app","records":[{"target":{"tag":"declaration","declaration":{"library":{"tag":"self"},"path":["caller"],"kind":"function"}},"type_parameters":[],"set":{"return_type":{"tag":"primitive","name":"Int"},"generic_requirements":[]}}]}"#).unwrap();
        for documents in [Vec::new(), vec![document]] {
            let checked = check_project(
                &sources(source),
                &BTreeMap::from([("app".to_owned(), APP)]),
                documents,
            )
            .expect("a vacuous callee formal cannot change the concrete caller signature");
            let caller = checked
                .functions
                .values()
                .find(|function| function.identity.name == "caller")
                .unwrap();
            assert!(caller.scheme.is_empty());
            let unused = checked
                .functions
                .values()
                .find(|function| function.identity.name == "unused")
                .unwrap();
            assert_eq!(unused.scheme.len(), 1);
            let TypedExprKind::Call {
                instantiation: CallInstantiation::Published(mapping),
                ..
            } = &caller.body.tail.as_ref().unwrap().kind
            else {
                panic!("caller retains the published direct call");
            };
            assert!(
                mapping.types.is_empty(),
                "no type relation consumes the vacuous formal"
            );
            assert_closed_block(&caller.body, &caller.scheme);
        }

        let diagnostic = check_project(
            &sources(
                "fn stop() -> Never { stop() } \
                 fn produce<T>() -> T { produce() } \
                 fn internal<T>() -> Int { let value: T = produce(); stop() } \
                 fn caller() -> Int { internal() }",
            ),
            &BTreeMap::new(),
            Vec::new(),
        )
        .expect_err("a formal consumed only by the callee body still needs a real call actual");
        assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
        assert!(diagnostic.message.contains("body type cannot be inferred"));
    }

    #[test]
    fn scc_body_formals_must_be_bound_by_the_published_callable() {
        let make = "fn make<T>() -> T { make() }";
        let a = "fn a<U>(x: move U) -> Unit { b(); a(x) }";
        for declaration in ["fn b()", "pub fn b()", "fn b<U>()"] {
            let b = format!("{declaration} -> Unit {{ a(make()) }}");
            for source in [format!("{make} {a} {b}"), format!("{make} {b} {a}")] {
                let diagnostic = check_project(&sources(&source), &BTreeMap::new(), Vec::new())
                    .expect_err("b cannot borrow a peer binder to close its own body actual");
                assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
                let Some(CheckOrigin::Source(origin)) = diagnostic.primary else {
                    panic!("an unbound body type has a real source origin");
                };
                assert!(source[origin.span.start..origin.span.end].contains("a(make())"));
            }
        }

        let a = "fn a<U>(x: move U) -> Unit { b(x) }";
        let b = "fn b<V>(x: move V) -> Unit { a(make()); b(x) }";
        for source in [format!("{make} {a} {b}"), format!("{make} {b} {a}")] {
            let checked = check_project(&sources(&source), &BTreeMap::new(), Vec::new())
                .expect("the shared SCC formal is bound by each member's own signature");
            for function in checked.functions.values() {
                assert_closed_block(&function.body, &function.scheme);
            }
        }
    }

    #[test]
    fn recursive_calls_require_the_actuals_consumed_by_callee_bodies() {
        let make = "fn make<T>() -> T { make() }";
        for (a, b) in [
            (
                "pub fn a() -> Never { b() }",
                "fn b<U>() -> Never { let y: U = make(); a() }",
            ),
            (
                "fn a<T>() -> Never { let x: T = make(); b() }",
                "fn b<U>() -> Never { let y: U = make(); a() }",
            ),
        ] {
            for source in [format!("{make} {a} {b}"), format!("{make} {b} {a}")] {
                let diagnostic = check_project(&sources(&source), &BTreeMap::new(), Vec::new())
                    .expect_err("recursive calls cannot omit a callee body's required type actual");
                assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
            }
        }
        for (a, b) in [
            (
                "fn a<T>(x: move T) -> Never { b() }",
                "fn b<U>() -> Never { let y: U = make(); a(y) }",
            ),
            (
                "fn a(x) { b(x) }",
                "fn b(y) { if false { y } else { a(y) } }",
            ),
        ] {
            for source in [format!("{make} {a} {b}"), format!("{make} {b} {a}")] {
                let checked = check_project(&sources(&source), &BTreeMap::new(), Vec::new())
                    .expect("the shared actual is determined through the other recursive edge");
                let a = checked
                    .functions
                    .values()
                    .find(|function| function.identity.name == "a")
                    .unwrap();
                let b = checked
                    .functions
                    .values()
                    .find(|function| function.identity.name == "b")
                    .unwrap();
                let TypedExprKind::Call {
                    instantiation: CallInstantiation::Provisional(mapping),
                    ..
                } = &a.body.tail.as_ref().unwrap().kind
                else {
                    panic!("a retains its actual recursive mapping to b");
                };
                assert_eq!(
                    &mapping.types,
                    &vec![(
                        b.scheme[0].clone(),
                        CheckedType::Formal(Box::new(a.scheme[0].clone()))
                    )]
                );
                for function in checked.functions.values() {
                    assert_closed_block(&function.body, &function.scheme);
                }
            }
        }

        let checked = check_project(
            &sources(
                "fn a<T>() -> Never { b() } fn b<U>() -> Never { a() } fn entry() -> Never { a() }",
            ),
            &BTreeMap::new(),
            Vec::new(),
        )
        .expect("vacuous recursive binders do not manufacture type demands");
        for function in checked.functions.values() {
            let TypedExprKind::Call { instantiation, .. } =
                &function.body.tail.as_ref().unwrap().kind
            else {
                panic!("direct call tail")
            };
            let (CallInstantiation::Published(mapping) | CallInstantiation::Provisional(mapping)) =
                instantiation
            else {
                panic!("all bindings are frozen")
            };
            assert!(mapping.types.is_empty());
            assert_closed_block(&function.body, &function.scheme);
        }

        let diagnostic = check_project(
            &sources(&format!("{make} fn stop() -> Never {{ stop() }} fn a<T>() -> Never {{ let x: T = make(); stop() }} fn b<U>() -> Never {{ let y: U = make(); a() }}")),
            &BTreeMap::new(), Vec::new(),
        ).expect_err("the group-external version has the same unclosed actual");
        assert_eq!(diagnostic.kind, CheckDiagnosticKind::Unsupported);
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
    #[test]
    fn generic_cleanup_retains_live_owners_and_untransferred_argument_temporaries() {
        let checked = check_project(
            &sources(
                r#"
trait Tick { fn tick(self: &Self) -> Int; }
effect Log { fn tick() -> Int; }
struct Runner {}
impl Tick for Runner { fn tick(self: &Self) -> Int { 1 } }
fn keep<T, R: Tick>(value: move T, runner: &R) -> T {
    runner.tick();
    value
}
fn pass<T>(value: move T, n: Int) -> T { value }
fn staged<T, R: Tick>(value: move T, runner: &R) -> T {
    pass(value, runner.tick())
}
fn consume<T>(value: move T) {}
fn handed<T, R: Tick>(value: move T, runner: &R) {
    consume(value);
    runner.tick();
}
fn handled_keep<T>(value: move T) -> T { Log.tick(); value }
fn handled_staged<T>(value: move T) -> T { pass(value, Log.tick()) }
fn raise_owned<T>(value: move T) -> Never { fail.raise(value) }
fn clean() with {} {}
fn known_pure<T>(value: move T) -> T { clean(); value }
fn concrete() -> Int { keep(1, Runner {}) }
"#,
            ),
            &BTreeMap::new(),
            Vec::new(),
        )
        .expect("generic ownership and effect facts close together");
        let function = |name: &str| {
            checked
                .functions
                .values()
                .find(|function| function.identity.name == name)
                .unwrap()
        };
        for name in [
            "keep",
            "staged",
            "handled_keep",
            "handled_staged",
            "consume",
        ] {
            let body = function(name);
            assert!(body.effect.0.iter().any(|term| matches!(term, EffectTerm::Destruction(CheckedType::Formal(formal)) if formal.as_ref() == &body.scheme[0])), "missing D(T) for {name}");
        }
        for name in ["staged", "handled_staged"] {
            let body = function(name);
            let failure = body
                .cleanups
                .iter()
                .find(|point| matches!(point.cause, CleanupCause::FailureExit))
                .expect("potential exit");
            assert_eq!(
                failure.temporaries.len(),
                1,
                "earlier Move argument remains owned by caller"
            );
            let temporary = &failure.state.temporaries[failure.temporaries[0]];
            assert!(!temporary.borrowed);
            assert_eq!(temporary.types.len(), 1);
            let value = failure
                .state
                .bindings
                .iter()
                .find(|(binding, _)| binding.name == "value")
                .unwrap()
                .1;
            assert!(value.availability == Availability::Moved);
        }
        let handed = function("handed");
        let failure = handed
            .cleanups
            .iter()
            .find(|point| matches!(point.cause, CleanupCause::FailureExit))
            .unwrap();
        assert!(
            failure.effect().0.is_empty(),
            "callee already owns the transferred parameter"
        );
        assert!(function("known_pure").effect.0.is_empty());
        assert!(function("concrete").effect.0.is_empty());
        assert!(
            !function("raise_owned")
                .effect
                .0
                .iter()
                .any(|term| matches!(term, EffectTerm::Destruction(_))),
            "failure payload is transferred, not cleaned by caller"
        );
    }
    #[test]
    fn trait_callback_formals_keep_independent_positions_and_impl_alpha_names() {
        let checked = check_project(&sources(r#"
trait Pipeline {
    fn run<F: Fn + fn() -> Unit, G: Fn + fn() -> Unit>(self: &Self, first: call F, second: call G) -> Unit;
}
struct Engine {}
impl Pipeline for Engine {
    fn run<A: Fn + fn() -> Unit with {X}, B: Fn + fn() -> Unit with {Y}, effect X, effect Y>(self: &Self, first: call A, second: call B) -> Unit { first(); }
}
trait Extra {
    fn go<F: Fn + fn() -> Unit, effect Unused>(self: &Self, callback: call F) -> Unit;
}
impl Extra for Engine {
    fn go<G: Fn + fn() -> Unit>(self: &Self, callback: call G) -> Unit { callback(); }
}
fn console_callback() -> Unit with {console} {}
fn file_callback() -> Unit with {fs} {}
fn independent() -> Unit with {console} { Engine {}.run(console_callback, file_callback) }
fn omitted_name() -> Unit with {console} { Engine {}.go(console_callback) }
"#), &BTreeMap::new(), Vec::new()).expect("trait positions control explicit and omitted impl effect names");
        let caller = |name: &str| {
            checked
                .functions
                .values()
                .find(|function| function.identity.name == name)
                .unwrap()
        };
        let TypedExprKind::Call {
            instantiation: CallInstantiation::Published(mapping),
            ..
        } = &caller("independent").body.tail.as_ref().unwrap().kind
        else {
            panic!("selected method")
        };
        assert_eq!(mapping.effects.len(), 2);
        assert_eq!(
            mapping.effects[0].1,
            EffectRow(vec![EffectTerm::System(SystemEffect::Console)])
        );
        assert_eq!(
            mapping.effects[1].1,
            EffectRow(vec![EffectTerm::System(SystemEffect::Fs)])
        );
        let TypedExprKind::Call {
            instantiation: CallInstantiation::Published(mapping),
            ..
        } = &caller("omitted_name").body.tail.as_ref().unwrap().kind
        else {
            panic!("selected method")
        };
        assert_eq!(mapping.effects.len(), 2);
        assert!(mapping.effects[0].1.0.is_empty());
        assert_eq!(
            mapping.effects[1].1,
            EffectRow(vec![EffectTerm::System(SystemEffect::Console)])
        );
    }
    #[test]
    fn borrowed_block_results_keep_their_local_owner_until_the_call_finishes() {
        let checked = check_project(
            &sources(
                r#"
effect Log { fn tick() -> Unit; }
struct Box<T> { value: T }
fn borrow<T>(value: &T) -> Unit { Log.tick(); }
fn block<T>(value: move T) { borrow({ let local = value; local }); }
fn field<T>(value: move Box<T>) { borrow({ let local = value; local.value }); }
"#,
            ),
            &BTreeMap::new(),
            Vec::new(),
        )
        .expect("the owning block result outlives the receiving shared call");
        for name in ["block", "field"] {
            let function = checked
                .functions
                .values()
                .find(|function| function.identity.name == name)
                .unwrap();
            let point = function
                .cleanups
                .iter()
                .find(|point| matches!(point.cause, CleanupCause::FailureExit))
                .unwrap();
            assert_eq!(point.temporaries.len(), 1);
            let temporary = &point.state.temporaries[point.temporaries[0]];
            assert!(temporary.borrowed);
            assert!(!temporary.types.is_empty());
            assert!(
                function
                    .cleanups
                    .iter()
                    .any(|point| matches!(point.cause, CleanupCause::TemporaryEnd)
                        && !point.effect().0.is_empty())
            );
            assert_closed_block(&function.body, &function.scheme);
            for ty in function.effect.types() {
                assert_closed_type(ty, &function.scheme);
            }
            for cleanup in &function.cleanups {
                for ty in cleanup.effect().types() {
                    assert_closed_type(ty, &function.scheme);
                }
            }
        }
    }

    #[test]
    fn named_generic_provider_effect_actual_waits_for_its_callback_consumer() {
        let checked = check_project(&sources(r#"
fn ignore<G: Fn + fn() -> Unit with {E}, effect E>(callback: call G) -> Unit with {} {}
fn invoke<G: Fn + fn() -> Unit with {console}, F: Fn + fn(call G) -> Unit with {}>(higher: call F, lower: call G) -> Unit with {} { higher(lower); }
fn noisy() -> Unit with {console} {}
fn run() with {} { invoke(ignore, noisy); }
"#), &BTreeMap::new(), Vec::new()).expect("the same function item mapping receives G and E from its consumer");
        let run = checked
            .functions
            .values()
            .find(|function| function.identity.name == "run")
            .unwrap();
        let TypedStatementKind::Expression(call) = &run.body.statements[0].kind else {
            panic!("invocation")
        };
        let TypedExprKind::Call { arguments, .. } = &call.kind else {
            panic!("direct consumer")
        };
        let TypedExprKind::FunctionValue(provider) = &arguments[0].kind else {
            panic!("named generic provider")
        };
        assert_eq!(
            provider.mapping.as_ref().unwrap().effects[0].1,
            EffectRow(vec![EffectTerm::System(SystemEffect::Console)])
        );
        assert_closed_block(&run.body, &run.scheme);
        let CheckedType::Function(item) = &arguments[0].ty else {
            panic!("function item type")
        };
        assert_eq!(
            item.mapping.effects,
            provider.mapping.as_ref().unwrap().effects
        );
    }
}
