//! Move and borrow checking on the IR.
//!
//! Both checks follow the edges of the control-flow graph, so every
//! construct that branches, loops or skips code is covered alike.
//!
//! - **Moves.** An entity can be moved out of a local or a part of one
//!   reached through fields, but not through a borrow, out of an element of
//!   a container, or out of a value with a hand-written `drop`; every move
//!   in the IR is checked against this. A forward analysis finds the places
//!   that may hold nothing at each point: not yet assigned, moved away, or
//!   released. Using one is an error. Moving a part of a variable counts as
//!   moving all of it, as the spec says, so the parts that one construct
//!   takes are taken in one `Unpack`; the temporaries of lowering are
//!   tracked part by part.
//! - **Borrows.** Each `Ref` makes a loan of a place. A reference local
//!   carries the loans it was made from: its own, those of the reference it
//!   reborrows, and for the result of a call that returns a borrow, those of
//!   the call's borrowed arguments. A loan is live where some reference that
//!   carries it may still be used, as in Rust's non-lexical lifetimes. An
//!   access that overlaps the place of a live loan and conflicts with its
//!   kind is an error.
//!
//! A place names one local, so a loan of `xs` and an access through a
//! reference `r` to `xs` never overlap as places. The access through `r`
//! uses `r`, which keeps `r`'s loans live, and it is the direct accesses to
//! `xs` while they are live that conflict.
//!
//! What a local holds, and which loans a reference carries, matter only
//! where a later step may depend on them. Both forward analyses keep, at the
//! edges between blocks, only the locals that are live there, so the work
//! follows the locals in use at each point rather than all the locals of
//! the function. What an index temporary is known to hold is kept while a
//! loan of a place indexed by it may be compared; a change of a local looks
//! only at the temporaries whose expression reads it.

mod loans;
mod moves;
mod values;

use crate::ast::Span;
use crate::dataflow::{self, Graph};
use crate::diagnostic::{CheckDiagnostic, CheckDiagnosticKind};
use crate::mir::{Body, Check};
use crate::project::OriginRef;
use crate::types::Types;

/// Checks the moves and borrows of `body`, and returns the run-time checks
/// it needs where only the values of indices tell whether two places are
/// the same.
pub(crate) fn check(
    body: &Body,
    types: &Types,
    at: &dyn Fn(Span) -> OriginRef,
) -> Result<Vec<Check>, CheckDiagnostic> {
    let graph = Graph::new(body);
    let live = dataflow::liveness(body, &graph);
    let mut errors = Vec::new();
    let mut checks = Vec::new();
    moves::check_move_sources(body, types, &mut errors);
    moves::check_moves(body, &graph, &live, &mut errors);
    loans::check_borrows(body, types, &graph, &live, &mut errors, &mut checks);
    match errors.into_iter().min_by_key(|error| error.span.start) {
        Some(error) => Err(CheckDiagnostic {
            kind: error.kind,
            primary: Some(at(error.span)),
            message: error.message,
        }),
        None => Ok(checks),
    }
}

struct Error {
    kind: CheckDiagnosticKind,
    span: Span,
    message: String,
}
