//! The control-flow graph of a body, and the fixed-point engines that the
//! analyses of the IR run on it.
//!
//! A forward analysis carries a state from the entry along the edges and
//! joins the states that meet at a block; a backward analysis of locals
//! carries the set of locals that a later step may depend on. Both visit
//! only the blocks that some path from the entry reaches, and revisit a
//! block only when what flows into it has changed.

use std::collections::BTreeSet;

use crate::mir::{BlockId, Body, Local};
use crate::types::Types;

/// The reachable blocks in reverse postorder, and the edges between them.
pub(crate) struct Graph {
    pub(crate) order: Vec<BlockId>,
    pub(crate) predecessors: Vec<Vec<BlockId>>,
    pub(crate) successors: Vec<Vec<BlockId>>,
    /// The position of each reachable block in `order`.
    position: Vec<Option<usize>>,
}

impl Graph {
    pub(crate) fn new(body: &Body) -> Self {
        let count = body.blocks.len();
        let successors = (0..count)
            .map(|block| body.successors(block))
            .collect::<Vec<_>>();
        let order = body.reverse_postorder();
        let mut position = vec![None; count];
        for (index, &block) in order.iter().enumerate() {
            position[block] = Some(index);
        }
        let mut predecessors = vec![Vec::new(); count];
        for &block in &order {
            for &successor in &successors[block] {
                predecessors[successor].push(block);
            }
        }
        Self {
            order,
            predecessors,
            successors,
            position,
        }
    }

    fn position(&self, block: BlockId) -> usize {
        self.position[block].expect("only reachable blocks are visited")
    }
}

/// Runs a forward analysis to its fixed point and returns the state at the
/// start of each block, or `None` for a block that no path reaches. The
/// entry starts in `entry`; any other block starts in the join of the
/// states at the end of its predecessors.
pub(crate) fn forward<S: Clone + PartialEq>(
    graph: &Graph,
    entry: S,
    join: impl Fn(&mut S, &S),
    mut transfer: impl FnMut(BlockId, &mut S),
) -> Vec<Option<S>> {
    let count = graph.successors.len();
    let mut starts: Vec<Option<S>> = vec![None; count];
    let mut ends: Vec<Option<S>> = vec![None; count];
    let first = graph.order[0];
    let mut pending = BTreeSet::from([0]);
    while let Some(index) = pending.pop_first() {
        let block = graph.order[index];
        let mut start = (block == first).then(|| entry.clone());
        for &predecessor in &graph.predecessors[block] {
            if let Some(end) = &ends[predecessor] {
                match &mut start {
                    Some(start) => join(start, end),
                    None => start = Some(end.clone()),
                }
            }
        }
        let mut state = start.clone().expect("a visited block is reached");
        starts[block] = start;
        transfer(block, &mut state);
        if ends[block].as_ref() != Some(&state) {
            ends[block] = Some(state);
            pending.extend(
                graph.successors[block]
                    .iter()
                    .map(|&successor| graph.position(successor)),
            );
        }
    }
    starts
}

/// What a block does to a backward analysis of locals: before the block,
/// the set holds `uses` and what it held after the block, less `kills`.
#[derive(Default)]
pub(crate) struct Summary {
    uses: BTreeSet<Local>,
    kills: BTreeSet<Local>,
}

impl Summary {
    /// Adds a step before the steps summed up so far: it makes `uses` live
    /// and `kills` dead.
    pub(crate) fn step_before(
        &mut self,
        uses: impl IntoIterator<Item = Local>,
        kills: impl IntoIterator<Item = Local>,
    ) {
        for local in kills {
            self.uses.remove(&local);
            self.kills.insert(local);
        }
        self.uses.extend(uses);
    }
}

/// The sets of locals at the start and at the end of each block.
pub(crate) struct Sets {
    pub(crate) starts: Vec<BTreeSet<Local>>,
    pub(crate) ends: Vec<BTreeSet<Local>>,
}

/// Runs a backward analysis of locals to its fixed point, given what each
/// reachable block does.
pub(crate) fn backward(graph: &Graph, summaries: &[Summary]) -> Sets {
    let count = graph.successors.len();
    let mut starts = vec![BTreeSet::new(); count];
    let mut ends = vec![BTreeSet::new(); count];
    let mut visited = vec![false; count];
    // From the last block in reverse postorder, so most blocks see their
    // successors first.
    let mut pending = (0..graph.order.len()).collect::<BTreeSet<_>>();
    while let Some(index) = pending.pop_last() {
        let block = graph.order[index];
        let mut live = BTreeSet::new();
        for &successor in &graph.successors[block] {
            live.extend(starts[successor].iter().copied());
        }
        ends[block].clone_from(&live);
        let summary = &summaries[block];
        live.retain(|local| !summary.kills.contains(local));
        live.extend(summary.uses.iter().copied());
        if !visited[block] || live != starts[block] {
            visited[block] = true;
            starts[block] = live;
            pending.extend(
                graph.predecessors[block]
                    .iter()
                    .map(|&predecessor| graph.position(predecessor)),
            );
        }
    }
    Sets { starts, ends }
}

/// The locals live at the start and at the end of each block: those whose
/// content a later step may depend on before something replaces it.
pub(crate) fn liveness(body: &Body, graph: &Graph) -> Sets {
    let summaries = body
        .blocks
        .iter()
        .map(|data| {
            let mut summary = Summary::default();
            summary.step_before(
                data.terminator
                    .kind
                    .places(body)
                    .into_iter()
                    .map(|place| place.local),
                [],
            );
            for statement in data.statements.iter().rev() {
                let effects = statement.kind.effects(body);
                summary.step_before(
                    effects.reads.into_iter().chain(effects.changes),
                    effects.replaces,
                );
            }
            summary
        })
        .collect::<Vec<_>>();
    backward(graph, &summaries)
}

/// The owning locals that may hold something at the start of each reachable
/// block, as [`Body::fill`] tracks them.
pub(crate) fn maybe_filled(body: &Body, types: &Types) -> Vec<BTreeSet<Local>> {
    let graph = Graph::new(body);
    let entry = body
        .parameters
        .iter()
        .copied()
        .filter(|&local| body.owns(types, local))
        .collect::<BTreeSet<_>>();
    forward(
        &graph,
        entry,
        |state, other| state.extend(other.iter().copied()),
        |block, filled| {
            for statement in &body.blocks[block].statements {
                body.fill(types, &statement.kind, filled);
            }
        },
    )
    .into_iter()
    .map(Option::unwrap_or_default)
    .collect()
}
