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
//! the function.

use std::collections::{BTreeMap, BTreeSet};

use crate::ast::Span;
use crate::checker::{CheckDiagnostic, CheckDiagnosticKind};
use crate::mir::{
    BlockId, Body, Local, Operand, Place, Projection, RefKind, Rvalue, StatementKind,
    TerminatorKind, projection_type,
};
use crate::project::OriginRef;
use crate::types::Types;

pub(crate) fn check(
    body: &Body,
    types: &Types,
    at: &dyn Fn(Span) -> OriginRef,
) -> Result<(), CheckDiagnostic> {
    let graph = Graph::new(body);
    let live = liveness(body, &graph);
    let mut errors = Vec::new();
    check_move_sources(body, types, &mut errors);
    check_moves(body, &graph, &live, &mut errors);
    check_borrows(body, types, &graph, &live, &mut errors);
    match errors.into_iter().min_by_key(|error| error.span.start) {
        Some(error) => Err(CheckDiagnostic {
            kind: error.kind,
            primary: Some(at(error.span)),
            message: error.message,
        }),
        None => Ok(()),
    }
}

struct Error {
    kind: CheckDiagnosticKind,
    span: Span,
    message: String,
}

/// The reachable blocks in reverse postorder, and the edges between them.
struct Graph {
    order: Vec<BlockId>,
    predecessors: Vec<Vec<BlockId>>,
    successors: Vec<Vec<BlockId>>,
}

impl Graph {
    fn new(body: &Body) -> Self {
        let count = body.blocks.len();
        let successors = (0..count)
            .map(|block| body.successors(block))
            .collect::<Vec<_>>();
        let order = body.reverse_postorder();
        let mut predecessors = vec![Vec::new(); count];
        for &block in order.iter().rev() {
            for &successor in &successors[block] {
                predecessors[successor].push(block);
            }
        }
        Self {
            order,
            predecessors,
            successors,
        }
    }
}

/// Runs a forward analysis to its fixed point and returns the state at the
/// start of each block.
fn forward<S: Clone + PartialEq>(
    graph: &Graph,
    entry: S,
    bottom: &S,
    join: impl Fn(&mut S, &S),
    mut transfer: impl FnMut(BlockId, &mut S),
) -> Vec<S> {
    let count = graph.predecessors.len();
    let mut starts = vec![bottom.clone(); count];
    let mut ends = vec![bottom.clone(); count];
    starts[graph.order[0]] = entry.clone();
    let mut changed = true;
    while changed {
        changed = false;
        for &block in &graph.order {
            let mut state = if block == graph.order[0] {
                entry.clone()
            } else {
                bottom.clone()
            };
            for &predecessor in &graph.predecessors[block] {
                join(&mut state, &ends[predecessor]);
            }
            starts[block] = state.clone();
            transfer(block, &mut state);
            if state != ends[block] {
                ends[block] = state;
                changed = true;
            }
        }
    }
    starts
}

// Where entities can be moved out of.

/// Reports each move out of a place that an entity cannot leave: through a
/// borrow, out of an element of a container, or out of a value with a
/// hand-written `drop`, which runs on the whole value.
fn check_move_sources(body: &Body, types: &Types, errors: &mut Vec<Error>) {
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
                StatementKind::Release(_) => Vec::new(),
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
        ty = projection_type(types, ty, projection);
    }
    None
}

// Moves.

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

fn check_moves(body: &Body, graph: &Graph, live: &Liveness, errors: &mut Vec<Error>) {
    let mut entry = Empty::default();
    for local in (0..body.locals.len()).filter(|local| !body.parameters.contains(local)) {
        entry.insert(Place::local(local));
    }
    let starts = forward(
        graph,
        entry,
        &Empty::default(),
        Empty::join,
        |block, state| {
            state.retain(&live.starts[block]);
            for statement in &body.blocks[block].statements {
                move_statement(body, &statement.kind, statement.span, state, None);
            }
            state.retain(&live.ends[block]);
        },
    );
    for &block in &graph.order {
        let mut state = starts[block].clone();
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
        let used = match &terminator.kind {
            TerminatorKind::Branch { condition, .. } => operand_places(condition),
            TerminatorKind::Return => vec![Place::local(body.result)],
            TerminatorKind::TailCall { arguments, .. } => {
                arguments.iter().flat_map(operand_places).collect()
            }
            TerminatorKind::Goto(_) | TerminatorKind::Unreachable => Vec::new(),
        };
        for place in used {
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
                    for used in operand_places(&Operand::Move(place.clone())) {
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
    };
    if let Some(errors) = errors.as_deref_mut() {
        for place in rvalue_places(value) {
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

// Borrows.

struct Loan {
    place: Place,
    kind: RefKind,
    /// The reference local the loan was made for.
    reference: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Access {
    /// Reads a value, which is a copy and never conflicts: a value-typed
    /// place, an enum's variant, or a container's length, keys and value
    /// elements.
    ReadValue,
    /// Borrows with `&`.
    Share,
    /// Reserves a `&mut` argument, which conflicts like `&` until the call
    /// runs.
    Reserve,
    /// Borrows with `&mut`, or a `&mut` argument takes effect.
    Borrow,
    Write,
    Move,
    /// The place's local ends.
    Release,
}

fn check_borrows(
    body: &Body,
    types: &Types,
    graph: &Graph,
    live: &Liveness,
    errors: &mut Vec<Error>,
) {
    // Every loan, by the statement that makes it.
    let mut loans = Vec::new();
    let mut loan_at = BTreeMap::new();
    for (block, data) in body.blocks.iter().enumerate() {
        for (index, statement) in data.statements.iter().enumerate() {
            if let StatementKind::Bind(reference, Rvalue::Ref(kind, place)) = &statement.kind {
                loan_at.insert((block, index), loans.len());
                loans.push(Loan {
                    place: place.clone(),
                    kind: *kind,
                    reference: *reference,
                });
            }
        }
    }
    // A `&mut` argument is reserved until its call runs. A borrow that the
    // call returns carries it from then on as an active `&mut` loan, a twin
    // of the reserved one.
    let mut active = vec![None; loans.len()];
    for (index, slot) in active.iter_mut().enumerate() {
        if loans[index].kind == RefKind::MutableArgument {
            *slot = Some(loans.len());
            loans.push(Loan {
                place: loans[index].place.clone(),
                kind: RefKind::Mutable,
                reference: loans[index].reference,
            });
        }
    }
    // The loans each reference local may carry.
    let carried_starts = forward(
        graph,
        Carried::new(),
        &Carried::new(),
        |state: &mut Carried, other| {
            for (reference, theirs) in other {
                state
                    .entry(*reference)
                    .or_default()
                    .extend(theirs.iter().copied());
            }
        },
        |block, state| {
            state.retain(|reference, _| live.starts[block].contains(reference));
            for (index, statement) in body.blocks[block].statements.iter().enumerate() {
                let own = loan_at.get(&(block, index)).copied();
                carry(body, &statement.kind, own, &active, state);
            }
            state.retain(|reference, _| live.ends[block].contains(reference));
        },
    );
    let is_reference = |local: &Local| body.locals[*local].reference.is_some();
    for &block in &graph.order {
        let mut carried = carried_starts[block].clone();
        carried.retain(|reference, _| live.starts[block].contains(reference));
        // The references live after each statement, from the block's end
        // backwards.
        let statements = &body.blocks[block].statements;
        let mut live_after = vec![BTreeSet::new(); statements.len()];
        let mut references = live.ends[block].clone();
        terminator_uses(body, &body.blocks[block].terminator.kind, &mut references);
        references.retain(is_reference);
        for (index, statement) in statements.iter().enumerate().rev() {
            live_after[index] = references.clone();
            let (uses, defines) = local_uses(body, &statement.kind);
            for defined in defines {
                references.remove(&defined);
            }
            references.extend(uses.into_iter().filter(is_reference));
        }
        for (index, statement) in statements.iter().enumerate() {
            let own = loan_at.get(&(block, index)).copied();
            check_statement(
                body,
                types,
                &loans,
                &carried,
                &live_after[index],
                own,
                &statement.kind,
                statement.span,
                errors,
            );
            carry(body, &statement.kind, own, &active, &mut carried);
        }
        if let TerminatorKind::Return = body.blocks[block].terminator.kind
            && body.locals[body.result].reference.is_some()
        {
            check_returned(
                body,
                &loans,
                &carried_by(&carried, body.result),
                &body.blocks[block],
                errors,
            );
        }
    }
}

/// The loans that each reference local may carry, for the references that
/// carry any, so a step looks only at the references it names.
type Carried = BTreeMap<Local, BTreeSet<usize>>;

/// The loans that `reference` may carry.
fn carried_by(carried: &Carried, reference: Local) -> BTreeSet<usize> {
    carried.get(&reference).cloned().unwrap_or_default()
}

/// Updates the loans the reference locals carry after `statement`.
fn carry(
    body: &Body,
    statement: &StatementKind,
    own: Option<usize>,
    active: &[Option<usize>],
    carried: &mut Carried,
) {
    match statement {
        StatementKind::Bind(reference, value) => {
            let mut loans = BTreeSet::new();
            match value {
                Rvalue::Ref(_, place) => {
                    loans.extend(own);
                    if body.locals[place.local].reference.is_some() {
                        loans.extend(carried_by(carried, place.local));
                    }
                }
                Rvalue::Call { arguments, .. } => {
                    for argument in arguments {
                        if let Operand::Borrowed(reference) = argument {
                            loans.extend(
                                carried_by(carried, *reference).into_iter().map(|loan| {
                                    active.get(loan).copied().flatten().unwrap_or(loan)
                                }),
                            );
                        }
                    }
                }
                _ => unreachable!("only borrows and calls make references point"),
            }
            if loans.is_empty() {
                carried.remove(reference);
            } else {
                carried.insert(*reference, loans);
            }
        }
        StatementKind::Release(local) => {
            carried.remove(local);
        }
        StatementKind::Assign(..) | StatementKind::Unpack(_) => {}
    }
}

// Liveness.

/// The locals live at the start and at the end of each block: those whose
/// content a later step may depend on before something replaces it.
struct Liveness {
    starts: Vec<BTreeSet<Local>>,
    ends: Vec<BTreeSet<Local>>,
}

fn liveness(body: &Body, graph: &Graph) -> Liveness {
    let count = body.blocks.len();
    let mut starts = vec![BTreeSet::new(); count];
    let mut ends = vec![BTreeSet::new(); count];
    let mut changed = true;
    while changed {
        changed = false;
        for &block in graph.order.iter().rev() {
            let mut live = BTreeSet::new();
            for &successor in &graph.successors[block] {
                live.extend(starts[successor].iter().copied());
            }
            ends[block] = live.clone();
            terminator_uses(body, &body.blocks[block].terminator.kind, &mut live);
            for statement in body.blocks[block].statements.iter().rev() {
                let (uses, defines) = local_uses(body, &statement.kind);
                for defined in defines {
                    live.remove(&defined);
                }
                live.extend(uses);
            }
            if live != starts[block] {
                starts[block] = live;
                changed = true;
            }
        }
    }
    Liveness { starts, ends }
}

/// Adds the locals a terminator uses to `live`. A borrow that the function
/// returns lives on in the caller.
fn terminator_uses(body: &Body, terminator: &TerminatorKind, live: &mut BTreeSet<Local>) {
    let used = match terminator {
        TerminatorKind::Branch { condition, .. } => operand_places(condition),
        TerminatorKind::Return => vec![Place::local(body.result)],
        TerminatorKind::TailCall { arguments, .. } => {
            arguments.iter().flat_map(operand_places).collect()
        }
        TerminatorKind::Goto(_) | TerminatorKind::Unreachable => Vec::new(),
    };
    live.extend(used.into_iter().map(|place| place.local));
}

/// The locals whose content `statement` depends on: those whose places it
/// reads, takes or borrows, writes into a part of, or writes through; and
/// those it gives new content regardless of what they held: filled whole,
/// made to point somewhere, or released.
fn local_uses(body: &Body, statement: &StatementKind) -> (Vec<Local>, Vec<Local>) {
    let locals = |places: Vec<Place>| places.into_iter().map(|place| place.local);
    match statement {
        StatementKind::Release(local) => (Vec::new(), vec![*local]),
        StatementKind::Unpack(taken) => (
            taken
                .iter()
                .flat_map(|(_, place)| locals(operand_places(&Operand::Move(place.clone()))))
                .collect(),
            taken.iter().map(|(local, _)| *local).collect(),
        ),
        StatementKind::Bind(reference, value) => {
            (locals(rvalue_places(value)).collect(), vec![*reference])
        }
        StatementKind::Assign(destination, value) => {
            let mut uses = locals(rvalue_places(value)).collect::<Vec<_>>();
            if is_whole(body, destination) {
                (uses, vec![destination.local])
            } else {
                uses.extend(locals(operand_places(&Operand::Move(destination.clone()))));
                (uses, Vec::new())
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn check_statement(
    body: &Body,
    types: &Types,
    loans: &[Loan],
    carried: &Carried,
    live_after: &BTreeSet<usize>,
    own: Option<usize>,
    statement: &StatementKind,
    span: Span,
    errors: &mut Vec<Error>,
) {
    let (uses, _) = local_uses(body, statement);
    // The loans that hold while the statement runs: those of the references
    // used later and of those it uses itself.
    let mut live = BTreeSet::new();
    for reference in live_after.iter().chain(&uses) {
        live.extend(carried_by(carried, *reference));
    }
    let accesses = accesses(body, types, loans, carried, statement, own);
    for access in accesses {
        for &loan_index in &live {
            if access.exempt.contains(&loan_index) {
                continue;
            }
            let loan = &loans[loan_index];
            if conflicts(loan, &access.place, access.kind) {
                errors.push(conflict_error(body, &access.place, access.kind, span));
                return;
            }
        }
    }
}

/// One access a statement makes, and the loans that do not count against
/// it: those it is made through.
struct Made {
    place: Place,
    kind: Access,
    exempt: BTreeSet<usize>,
}

fn accesses(
    body: &Body,
    types: &Types,
    loans: &[Loan],
    carried: &Carried,
    statement: &StatementKind,
    own: Option<usize>,
) -> Vec<Made> {
    let mut made = Vec::new();
    let mut access = |place: &Place, kind: Access| {
        made.push(Made {
            place: place.clone(),
            kind,
            exempt: own.into_iter().collect(),
        });
    };
    let (destination, value) = match statement {
        StatementKind::Release(local) => {
            if body.locals[*local].reference.is_none() {
                access(&Place::local(*local), Access::Release);
            }
            return made;
        }
        StatementKind::Unpack(taken) => {
            for (local, place) in taken {
                access(place, Access::Move);
                access(&Place::local(*local), Access::Write);
            }
            return made;
        }
        StatementKind::Assign(destination, value) => (Some(destination), value),
        StatementKind::Bind(_, value) => (None, value),
    };
    match value {
        Rvalue::Ref(kind, place) => access(
            place,
            match kind {
                RefKind::Shared => Access::Share,
                RefKind::MutableArgument => Access::Reserve,
                RefKind::Mutable => Access::Borrow,
            },
        ),
        // Reading an enum's variant, a length or an occupied slot reads a
        // value, which never conflicts.
        Rvalue::Discriminant(_) | Rvalue::Len(_) | Rvalue::Occupied { .. } => {}
        Rvalue::Use(_)
        | Rvalue::Unary(..)
        | Rvalue::Binary(..)
        | Rvalue::Tuple(_)
        | Rvalue::Construct { .. }
        | Rvalue::List(_)
        | Rvalue::EmptyMap
        | Rvalue::Range { .. }
        | Rvalue::Interpolate(_)
        | Rvalue::Call { .. }
        | Rvalue::Glue { .. }
        | Rvalue::Builtin { .. }
        | Rvalue::Intrinsic { .. }
        | Rvalue::Take { .. } => {
            for operand in value.operands() {
                match operand {
                    Operand::Copy(place) | Operand::Inspect(place) => {
                        access(place, Access::ReadValue);
                    }
                    Operand::Move(place) => access(place, Access::Move),
                    Operand::Borrowed(_) | Operand::Constant(_) => {}
                }
            }
        }
    }
    if let Some(destination) = destination {
        // Storing the value of a key may add the key, which changes
        // the map as a whole.
        match body.map_entry(types, destination) {
            Some((_, map)) => access(&map, Access::Write),
            None => access(destination, Access::Write),
        }
    }
    // A `&mut` argument or receiver takes effect when the call runs.
    let activated = match value {
        Rvalue::Call { arguments, .. } | Rvalue::Intrinsic { arguments, .. } => arguments
            .iter()
            .filter_map(|operand| match operand {
                Operand::Borrowed(reference) => Some(*reference),
                _ => None,
            })
            .collect::<Vec<_>>(),
        Rvalue::Builtin { receiver, .. } => vec![receiver.local],
        Rvalue::Use(_)
        | Rvalue::Ref(..)
        | Rvalue::Unary(..)
        | Rvalue::Binary(..)
        | Rvalue::Tuple(_)
        | Rvalue::Construct { .. }
        | Rvalue::List(_)
        | Rvalue::EmptyMap
        | Rvalue::Range { .. }
        | Rvalue::Interpolate(_)
        | Rvalue::Discriminant(_)
        | Rvalue::Len(_)
        | Rvalue::Occupied { .. }
        | Rvalue::Glue { .. }
        | Rvalue::Take { .. } => Vec::new(),
    };
    let siblings = activated
        .iter()
        .flat_map(|&reference| own_loans(loans, carried, reference))
        .collect::<Vec<_>>();
    for &reference in &activated {
        for loan_index in own_loans(loans, carried, reference) {
            let loan = &loans[loan_index];
            if loan.kind != RefKind::MutableArgument {
                continue;
            }
            // The loans it is made through, and those of the other
            // borrowed arguments that differ from it only in list
            // indices, which are compared at run time.
            let mut exempt = carried_by(carried, reference);
            exempt.extend(
                siblings
                    .iter()
                    .copied()
                    .filter(|&sibling| loans[sibling].place.differs_only_in_indices(&loan.place)),
            );
            made.push(Made {
                place: loan.place.clone(),
                kind: Access::Borrow,
                exempt,
            });
        }
    }
    made
}

/// The loans made for `reference` itself.
fn own_loans(loans: &[Loan], carried: &Carried, reference: usize) -> Vec<usize> {
    carried_by(carried, reference)
        .into_iter()
        .filter(|&loan| loans[loan].reference == reference)
        .collect()
}

/// Whether an access of `kind` to `place` conflicts with `loan`.
fn conflicts(loan: &Loan, place: &Place, kind: Access) -> bool {
    if kind == Access::ReadValue {
        return false;
    }
    if !overlap(&loan.place, place) {
        return false;
    }
    match loan.kind {
        RefKind::Shared | RefKind::MutableArgument => matches!(
            kind,
            Access::Borrow | Access::Write | Access::Move | Access::Release
        ),
        RefKind::Mutable => true,
    }
}

/// Whether two places may overlap: they are of one local, and along their
/// common path no step tells them apart.
fn overlap(left: &Place, right: &Place) -> bool {
    if left.local != right.local {
        return false;
    }
    for (left, right) in left.projections.iter().zip(&right.projections) {
        let disjoint = match (left, right) {
            (Projection::Field(a), Projection::Field(b)) => a != b,
            (
                Projection::VariantField { variant, field },
                Projection::VariantField {
                    variant: other_variant,
                    field: other_field,
                },
            ) => variant != other_variant || field != other_field,
            (Projection::ConstantIndex(a), Projection::ConstantIndex(b)) => a != b,
            _ => false,
        };
        if disjoint {
            return false;
        }
    }
    true
}

fn conflict_error(body: &Body, place: &Place, kind: Access, span: Span) -> Error {
    let local = &body.locals[place.local];
    let name = if local.temporary {
        "this value".to_owned()
    } else {
        format!("`{}`", local.name)
    };
    if kind == Access::Release {
        return Error {
            kind: CheckDiagnosticKind::BorrowOutlives,
            span,
            message: format!("{name} ends while it is still borrowed"),
        };
    }
    let what = match kind {
        Access::Write => "change",
        Access::Move => "be moved",
        Access::Borrow | Access::Reserve => "be borrowed with `&mut`",
        Access::ReadValue | Access::Share | Access::Release => "be borrowed",
    };
    Error {
        kind: CheckDiagnosticKind::BorrowConflict,
        span,
        message: format!("{name} cannot {what} while it is borrowed"),
    }
}

/// A returned borrow must reach only places of the parameters passed by
/// borrow: every loan it carries is of a place behind a reference.
fn check_returned(
    body: &Body,
    loans: &[Loan],
    carried: &BTreeSet<usize>,
    block: &crate::mir::BasicBlock,
    errors: &mut Vec<Error>,
) {
    for &loan in carried {
        let root = loans[loan].place.local;
        if body.locals[root].reference.is_none() {
            let local = &body.locals[root];
            let message = if local.temporary {
                "a returned borrow cannot name a temporary, which ends when the function returns"
                    .to_owned()
            } else {
                format!(
                    "a returned borrow must come from a parameter passed by borrow; `{}` ends when the function returns",
                    local.name
                )
            };
            let span = block
                .statements
                .iter()
                .rev()
                .find(|statement| match &statement.kind {
                    StatementKind::Assign(destination, _) => destination.local == body.result,
                    StatementKind::Bind(reference, _) => *reference == body.result,
                    StatementKind::Release(_) | StatementKind::Unpack(_) => false,
                })
                .map_or(block.terminator.span, |statement| statement.span);
            errors.push(Error {
                kind: CheckDiagnosticKind::BorrowOutlives,
                span,
                message,
            });
            return;
        }
    }
}

// Places in IR steps.

/// Every place an rvalue reads, takes or borrows, and the locals it reads
/// through: index locals and borrowed references.
fn rvalue_places(value: &Rvalue) -> Vec<Place> {
    let mut places = Vec::new();
    for operand in value.operands() {
        places.extend(operand_places(operand));
    }
    match value {
        Rvalue::Ref(_, place) | Rvalue::Discriminant(place) | Rvalue::Len(place) => {
            places.push(place.clone());
            places.extend(index_locals(place));
        }
        Rvalue::Builtin { receiver, .. } => {
            places.push(receiver.clone());
            places.extend(index_locals(receiver));
        }
        Rvalue::Occupied {
            container,
            position,
        } => {
            places.push(container.clone());
            places.extend(index_locals(container));
            places.push(Place::local(*position));
        }
        Rvalue::Take {
            container,
            position,
        } => {
            places.push(Place::local(*container));
            places.push(Place::local(*position));
        }
        // These read only their operands.
        Rvalue::Use(_)
        | Rvalue::Unary(..)
        | Rvalue::Binary(..)
        | Rvalue::Tuple(_)
        | Rvalue::Construct { .. }
        | Rvalue::List(_)
        | Rvalue::EmptyMap
        | Rvalue::Range { .. }
        | Rvalue::Interpolate(_)
        | Rvalue::Call { .. }
        | Rvalue::Glue { .. }
        | Rvalue::Intrinsic { .. } => {}
    }
    places
}

fn operand_places(operand: &Operand) -> Vec<Place> {
    match operand {
        Operand::Copy(place) | Operand::Inspect(place) | Operand::Move(place) => {
            let mut places = vec![place.clone()];
            places.extend(index_locals(place));
            places
        }
        Operand::Borrowed(local) => vec![Place::local(*local)],
        Operand::Constant(_) => Vec::new(),
    }
}

fn index_locals(place: &Place) -> Vec<Place> {
    place
        .projections
        .iter()
        .filter_map(|projection| match projection {
            Projection::Index(local) | Projection::Position(local) => Some(Place::local(*local)),
            _ => None,
        })
        .collect()
}
