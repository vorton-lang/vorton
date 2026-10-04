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
use crate::dataflow::{self, Graph, Sets, Summary};
use crate::diagnostic::{CheckDiagnostic, CheckDiagnosticKind};
use crate::lower::Change;
use crate::mir::{Body, Local};
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
    let read_later = reads_after(body, &tracked);
    for change in changes {
        let data = &body.blocks[change.block];
        let mut read = None;
        for statement in &data.statements[change.statement + 1..] {
            let effects = statement.kind.effects(body);
            if effects.reads.contains(&change.local) {
                read = Some(true);
                break;
            }
            if effects.replaces.contains(&change.local) {
                read = Some(false);
                break;
            }
        }
        let read = read.unwrap_or_else(|| {
            data.terminator
                .kind
                .places(body)
                .iter()
                .any(|place| place.local == change.local)
                || read_later.ends[change.block].contains(&change.local)
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

/// For each block, the tracked locals that a step may read before they get
/// a new value or end. Writing into a part of a local does not read it.
fn reads_after(body: &Body, tracked: &BTreeSet<Local>) -> Sets {
    let tracked_only = |locals: Vec<Local>| {
        locals
            .into_iter()
            .filter(|local| tracked.contains(local))
            .collect::<Vec<_>>()
    };
    let summaries = body
        .blocks
        .iter()
        .map(|data| {
            let mut summary = Summary::default();
            let reads = data.terminator.kind.places(body);
            summary.step_before(
                tracked_only(reads.into_iter().map(|place| place.local).collect()),
                [],
            );
            for statement in data.statements.iter().rev() {
                let effects = statement.kind.effects(body);
                summary.step_before(tracked_only(effects.reads), effects.replaces);
            }
            summary
        })
        .collect::<Vec<_>>();
    dataflow::backward(&Graph::new(body), &summaries)
}
