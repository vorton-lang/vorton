//! Move checking: where an entity can be moved out of, and which places
//! may hold nothing when they are used.

use std::collections::BTreeSet;

use super::Error;
use crate::ast::Span;
use crate::dataflow::{self, Graph, Sets};
use crate::diagnostic::CheckDiagnosticKind;
use crate::mir::{Body, Local, Operand, Place, Projection, Rvalue, StatementKind, projection_type};
use crate::types::Types;

/// Reports each move out of a place that an entity cannot leave: through a
/// borrow, out of an element of a container, or out of a value with a
/// hand-written `drop`, which runs on the whole value.
pub(super) fn check_move_sources(body: &Body, types: &Types, errors: &mut Vec<Error>) {
    // The reference locals that point where a call's result points.
    let mut from_call = vec![false; body.locals.len()];
    for block in &body.blocks {
        for statement in &block.statements {
            if let StatementKind::Bind(reference, Rvalue::Call { .. }) = &statement.kind {
                from_call[*reference] = true;
            }
        }
    }
    for block in &body.blocks {
        for statement in &block.statements {
            let moved = match &statement.kind {
                StatementKind::Assign(_, value) | StatementKind::Bind(_, value) => value
                    .operands()
                    .into_iter()
                    .filter_map(|operand| match operand {
                        Operand::Move(place) => Some(place),
                        _ => None,
                    })
                    .collect(),
                StatementKind::Unpack(taken) => taken.iter().map(|(_, place)| place).collect(),
                StatementKind::Release(_)
                | StatementKind::Distinct { .. }
                | StatementKind::Keep(_) => Vec::new(),
            };
            for place in moved {
                if let Some(message) = immovable(body, types, &from_call, place) {
                    errors.push(Error {
                        kind: CheckDiagnosticKind::CannotMove,
                        span: statement.span,
                        message,
                    });
                }
            }
        }
    }
}

/// Why the entity at `place` cannot be moved out, if it cannot.
fn immovable(body: &Body, types: &Types, from_call: &[bool], place: &Place) -> Option<String> {
    let moved = types.name(body.place_type(types, place));
    let local = &body.locals[place.local];
    if local.reference.is_some() {
        return Some(if from_call[place.local] {
            format!("this call returns a borrow, so its `{moved}` cannot be moved; use `clone()`")
        } else if local.temporary {
            format!("this value is borrowed, so its `{moved}` cannot be moved; use `clone()`")
        } else {
            format!(
                "`{}` is borrowed, so its `{moved}` cannot be moved; use `clone()`",
                local.name
            )
        });
    }
    let mut ty = local.ty;
    for projection in &place.projections {
        match projection {
            Projection::Index(_) | Projection::ConstantIndex(_) | Projection::Position(_) => {
                return Some(format!(
                    "a `{moved}` cannot be moved out of an element; use `clone()`, or take it with `remove` or `replace`"
                ));
            }
            Projection::Field(_) | Projection::VariantField { .. } if types.has_drop(ty) => {
                return Some(format!(
                    "`{}` implements `Drop`, so no part of it can be moved out; borrow it, or use `replace`",
                    types.name(ty)
                ));
            }
            Projection::Field(_) | Projection::VariantField { .. } => {}
        }
        ty = projection_type(types, ty, projection).expect("each step of a place fits its type");
    }
    None
}

/// The places that may hold nothing: whole locals, and parts of the
/// temporaries that lowering moves out one at a time. A step looks only at
/// the locals it names.
#[derive(Clone, PartialEq, Default)]
struct Empty {
    whole: BTreeSet<Local>,
    /// Ordered by their local.
    parts: BTreeSet<Place>,
}

impl Empty {
    fn is_whole(&self, local: Local) -> bool {
        self.whole.contains(&local)
    }

    /// The empty parts of `local`.
    fn parts_of(&self, local: Local) -> impl Iterator<Item = &Place> {
        self.parts
            .range(Place::local(local)..Place::local(local + 1))
    }

    /// Records that `place` may hold nothing.
    fn insert(&mut self, place: Place) {
        if place.projections.is_empty() {
            self.whole.insert(place.local);
            self.fill_parts(&place);
        } else if !self.is_whole(place.local) {
            self.parts.insert(place);
        }
    }

    /// Records that `place` and everything inside it hold a value.
    fn fill(&mut self, place: &Place) {
        if place.projections.is_empty() {
            self.whole.remove(&place.local);
        }
        self.fill_parts(place);
    }

    fn fill_parts(&mut self, place: &Place) {
        let filled = self
            .parts_of(place.local)
            .filter(|part| is_prefix(place, part))
            .cloned()
            .collect::<Vec<_>>();
        for part in filled {
            self.parts.remove(&part);
        }
    }

    /// Whether some part of `place`, or a place that contains it, may hold
    /// nothing.
    fn overlaps(&self, place: &Place) -> bool {
        self.is_whole(place.local)
            || self
                .parts_of(place.local)
                .any(|part| is_prefix(part, place) || is_prefix(place, part))
    }

    /// Whether a place that strictly contains `place` may hold nothing.
    fn lacks_container(&self, place: &Place) -> bool {
        self.is_whole(place.local)
            || self.parts_of(place.local).any(|part| {
                is_prefix(part, place) && part.projections.len() < place.projections.len()
            })
    }

    fn join(&mut self, other: &Self) {
        self.whole.extend(other.whole.iter().copied());
        self.parts.extend(other.parts.iter().cloned());
    }

    /// Forgets the locals that are not in `live`.
    fn retain(&mut self, live: &BTreeSet<Local>) {
        self.whole.retain(|local| live.contains(local));
        self.parts.retain(|part| live.contains(&part.local));
    }
}

pub(super) fn check_moves(body: &Body, graph: &Graph, live: &Sets, errors: &mut Vec<Error>) {
    let mut entry = Empty::default();
    for local in (0..body.locals.len()).filter(|local| !body.parameters.contains(local)) {
        entry.insert(Place::local(local));
    }
    let starts = dataflow::forward(graph, entry, Empty::join, |block, state| {
        state.retain(&live.starts[block]);
        for statement in &body.blocks[block].statements {
            move_statement(body, &statement.kind, statement.span, state, None);
        }
        state.retain(&live.ends[block]);
    });
    for &block in &graph.order {
        let mut state = starts[block].clone().expect("a reachable block is reached");
        state.retain(&live.starts[block]);
        for statement in &body.blocks[block].statements {
            move_statement(
                body,
                &statement.kind,
                statement.span,
                &mut state,
                Some(errors),
            );
        }
        let terminator = &body.blocks[block].terminator;
        for place in terminator.kind.places(body) {
            check_filled(body, &state, &place, terminator.span, errors);
        }
    }
}

fn move_statement(
    body: &Body,
    statement: &StatementKind,
    span: Span,
    state: &mut Empty,
    mut errors: Option<&mut Vec<Error>>,
) {
    let (written, value) = match statement {
        StatementKind::Assign(destination, value) => (destination.clone(), value),
        StatementKind::Bind(reference, value) => (Place::local(*reference), value),
        StatementKind::Release(local) => {
            state.insert(Place::local(*local));
            return;
        }
        StatementKind::Unpack(taken) => {
            if let Some(errors) = errors {
                for (_, place) in taken {
                    for used in place.with_indices() {
                        check_filled(body, state, &used, span, errors);
                    }
                }
            }
            for (_, place) in taken {
                state.insert(moved_place(body, place));
            }
            for (local, _) in taken {
                state.fill(&Place::local(*local));
            }
            return;
        }
        StatementKind::Keep(reference) => {
            if let Some(errors) = errors {
                check_filled(body, state, &Place::local(*reference), span, errors);
            }
            return;
        }
        StatementKind::Distinct { pairs, .. } => {
            if let Some(errors) = errors {
                for (left, right) in pairs {
                    for used in left.places().iter().chain(&right.places()) {
                        check_filled(body, state, used, span, errors);
                    }
                }
            }
            return;
        }
    };
    if let Some(errors) = errors.as_deref_mut() {
        for place in value.places() {
            check_filled(body, state, &place, span, errors);
        }
    }
    for operand in value.operands() {
        if let Operand::Move(place) = operand {
            state.insert(moved_place(body, place));
        }
    }
    if let StatementKind::Assign(destination, _) = statement
        && !is_whole(body, destination)
        && let Some(errors) = errors
    {
        // Writing through a reference needs it to point somewhere,
        // and writing into a part needs the whole to be there.
        let missing = if body.locals[destination.local].reference.is_some() {
            state.is_whole(destination.local)
        } else {
            state.lacks_container(destination)
        };
        if missing {
            let local = &body.locals[destination.local];
            errors.push(Error {
                kind: CheckDiagnosticKind::UseAfterMove,
                span,
                message: format!(
                    "`{}` is assigned to after its value may have been moved",
                    local.name
                ),
            });
        }
    }
    state.fill(&written);
}

/// What a move out of `place` leaves empty: the whole variable, or for a
/// temporary of lowering just that part.
fn moved_place(body: &Body, place: &Place) -> Place {
    if body.locals[place.local].temporary {
        place.clone()
    } else {
        Place::local(place.local)
    }
}

/// Whether an assignment to `destination` fills a whole local of its own.
fn is_whole(body: &Body, destination: &Place) -> bool {
    destination.projections.is_empty() && body.locals[destination.local].reference.is_none()
}

fn check_filled(body: &Body, state: &Empty, place: &Place, span: Span, errors: &mut Vec<Error>) {
    if state.overlaps(place) {
        let local = &body.locals[place.local];
        let message = if local.temporary {
            "this value is used after it may have been moved".to_owned()
        } else {
            format!(
                "`{}` is used after its value may have been moved",
                local.name
            )
        };
        errors.push(Error {
            kind: CheckDiagnosticKind::UseAfterMove,
            span,
            message,
        });
    }
}

/// Whether `prefix` is `place` or a place that contains it.
fn is_prefix(prefix: &Place, place: &Place) -> bool {
    prefix.local == place.local
        && prefix.projections.len() <= place.projections.len()
        && prefix
            .projections
            .iter()
            .zip(&place.projections)
            .all(|(left, right)| left == right)
}
