use std::collections::BTreeMap;

use crate::project::{
    EntityId, EntityKind, EntitySite, ModuleRef, OriginRef, ProjectDiagnostic,
    ProjectDiagnosticKind, ResolvedDeclaration, ResolvedDeclarationKind, ResolvedEffectSet,
    ResolvedNamedType, ResolvedProject, ResolvedReference, SupertraitTargetKind,
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
