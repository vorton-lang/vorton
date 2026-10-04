//! Changes that are never read.
//!
//! The spec makes it an error to change a `let mut` variable of a value
//! type and never read it afterwards: such a change usually changes a copy
//! where the original was meant, as in `let mut p = world.player.pos` and
//! then `p.x += 1.0`. A backward analysis finds, for the changed variables,
//! where a later step may read them before a new value replaces them or
//! they end.

use std::collections::BTreeSet;

use crate::ast::Span;
use crate::borrowck::{operand_places, rvalue_places};
use crate::checker::{CheckDiagnostic, CheckDiagnosticKind};
use crate::lower::Change;
use crate::mir::{Body, Local, Operand, Place, StatementKind, TerminatorKind};
use crate::project::OriginRef;

pub(crate) fn check(
    body: &Body,
    changes: &[Change],
    at: &dyn Fn(Span) -> OriginRef,
) -> Result<(), CheckDiagnostic> {
    if changes.is_empty() {
        return Ok(());
    }
    let tracked = changes
        .iter()
        .map(|change| change.local)
        .collect::<BTreeSet<_>>();
    let read_later = reads_after_blocks(body, &tracked);
    for change in changes {
        let data = &body.blocks[change.block];
        let mut read = None;
        for statement in &data.statements[change.statement + 1..] {
            let (reads, ends) = effect(&statement.kind);
            if reads.contains(&change.local) {
                read = Some(true);
                break;
            }
            if ends.contains(&change.local) {
                read = Some(false);
                break;
            }
        }
        let read = read.unwrap_or_else(|| {
            terminator_reads(body, &data.terminator.kind).contains(&change.local)
                || read_later[change.block].contains(&change.local)
        });
        if !read {
            let name = &body.locals[change.local].name;
            return Err(CheckDiagnostic {
                kind: CheckDiagnosticKind::UnreadChange,
                primary: Some(at(change.span)),
                message: format!(
                    "this changes `{name}`, which is never read afterwards; if the change is meant for the place `{name}` was copied from, borrow that place with `&mut`"
                ),
            });
        }
    }
    Ok(())
}

/// The locals a statement reads, and those it gives a new value whole or
/// ends. Writing into a part of a local does neither.
fn effect(statement: &StatementKind) -> (Vec<Local>, Vec<Local>) {
    let locals = |places: Vec<Place>| places.into_iter().map(|place| place.local).collect();
    match statement {
        StatementKind::Assign(destination, value) => {
            let mut reads: Vec<Local> = locals(rvalue_places(value));
            reads.extend(
                operand_places(&Operand::Move(destination.clone()))
                    .into_iter()
                    .skip(1)
                    .map(|place| place.local),
            );
            let ends = if destination.projections.is_empty() {
                vec![destination.local]
            } else {
                Vec::new()
            };
            (reads, ends)
        }
        StatementKind::Bind(reference, value) => (locals(rvalue_places(value)), vec![*reference]),
        StatementKind::Unpack(taken) => (
            taken.iter().map(|(_, place)| place.local).collect(),
            taken.iter().map(|(local, _)| *local).collect(),
        ),
        StatementKind::Release(local) => (Vec::new(), vec![*local]),
        StatementKind::Distinct { pairs, .. } => (
            pairs
                .iter()
                .flat_map(|(left, right)| [left, right])
                .flat_map(operand_places)
                .map(|place| place.local)
                .collect(),
            Vec::new(),
        ),
        StatementKind::Keep(reference) => (vec![*reference], Vec::new()),
    }
}

fn terminator_reads(body: &Body, terminator: &TerminatorKind) -> Vec<Local> {
    let places = match terminator {
        TerminatorKind::Branch { condition, .. } => operand_places(condition),
        TerminatorKind::Return => vec![Place::local(body.result)],
        TerminatorKind::TailCall { arguments, .. } => {
            arguments.iter().flat_map(operand_places).collect()
        }
        TerminatorKind::Goto(_) | TerminatorKind::Unreachable => Vec::new(),
    };
    places.into_iter().map(|place| place.local).collect()
}

/// For each block, the tracked locals that a step after it may read before
/// they get a new value or end.
fn reads_after_blocks(body: &Body, tracked: &BTreeSet<Local>) -> Vec<BTreeSet<Local>> {
    let count = body.blocks.len();
    let mut starts = vec![BTreeSet::new(); count];
    let mut ends = vec![BTreeSet::new(); count];
    let order = body.reverse_postorder();
    let mut changed = true;
    while changed {
        changed = false;
        for &block in order.iter().rev() {
            let mut live = BTreeSet::new();
            for successor in body.successors(block) {
                live.extend(starts[successor].iter().copied());
            }
            ends[block] = live.clone();
            let data = &body.blocks[block];
            live.extend(
                terminator_reads(body, &data.terminator.kind)
                    .into_iter()
                    .filter(|local| tracked.contains(local)),
            );
            for statement in data.statements.iter().rev() {
                let (reads, gone) = effect(&statement.kind);
                for local in gone {
                    live.remove(&local);
                }
                live.extend(reads.into_iter().filter(|local| tracked.contains(local)));
            }
            if live != starts[block] {
                starts[block] = live;
                changed = true;
            }
        }
    }
    ends
}
