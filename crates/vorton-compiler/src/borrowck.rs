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

use std::collections::{BTreeMap, BTreeSet};

use crate::ast::Span;
use crate::diagnostic::{CheckDiagnostic, CheckDiagnosticKind};
use crate::mir::{
    BlockId, Body, Check, Constant, Local, Operand, Place, Projection, RefKind, Rvalue,
    StatementKind, TerminatorKind, projection_type,
};
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
    let live = liveness(body, &graph);
    let mut errors = Vec::new();
    let mut checks = Vec::new();
    check_move_sources(body, types, &mut errors);
    check_moves(body, &graph, &live, &mut errors);
    check_borrows(body, types, &graph, &live, &mut errors, &mut checks);
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
        StatementKind::Keep(reference) => {
            if let Some(errors) = errors {
                check_filled(body, state, &Place::local(*reference), span, errors);
            }
            return;
        }
        StatementKind::Distinct { pairs, .. } => {
            if let Some(errors) = errors {
                for (left, right) in pairs {
                    for used in operand_places(left).iter().chain(&operand_places(right)) {
                        check_filled(body, state, used, span, errors);
                    }
                }
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
    checks: &mut Vec<Check>,
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
    // The loans each reference local may carry, and what the temporaries are
    // known to hold.
    let mut values = Values::default();
    let starts = forward(
        graph,
        Flow {
            reached: true,
            ..Flow::default()
        },
        &Flow::default(),
        Flow::join,
        |block, state| {
            if !state.reached {
                return;
            }
            state
                .carried
                .retain(|reference, _| live.starts[block].contains(reference));
            for (index, statement) in body.blocks[block].statements.iter().enumerate() {
                let own = loan_at.get(&(block, index)).copied();
                learn(
                    body,
                    &loans,
                    &statement.kind,
                    &state.carried,
                    &mut state.copies,
                    &mut values,
                );
                carry(body, &statement.kind, own, &active, &mut state.carried);
            }
            state
                .carried
                .retain(|reference, _| live.ends[block].contains(reference));
        },
    );
    let is_reference = |local: &Local| body.locals[*local].reference.is_some();
    for &block in &graph.order {
        let Flow {
            mut carried,
            mut copies,
            ..
        } = starts[block].clone();
        carried.retain(|reference, _| live.starts[block].contains(reference));
        // The references that each statement is the last to use, or that it
        // makes point somewhere no later step looks: they are dead after it.
        let statements = &body.blocks[block].statements;
        let mut dying = vec![Vec::new(); statements.len()];
        let mut references = live.ends[block].clone();
        terminator_uses(body, &body.blocks[block].terminator.kind, &mut references);
        references.retain(is_reference);
        for (index, statement) in statements.iter().enumerate().rev() {
            let (uses, defines) = local_uses(body, &statement.kind);
            dying[index] = uses
                .iter()
                .chain(&defines)
                .copied()
                .filter(|local| is_reference(local) && !references.contains(local))
                .collect();
            for defined in defines {
                references.remove(&defined);
            }
            references.extend(uses.into_iter().filter(is_reference));
        }
        let mut in_force = InForce::new(&loans, &carried);
        for (index, statement) in statements.iter().enumerate() {
            let own = loan_at.get(&(block, index)).copied();
            let made = accesses(body, types, &loans, &carried, &statement.kind, own);
            match in_force.check(&made, &copies, &values) {
                Ok(found) => {
                    for (pairs, message) in found {
                        let check = Check {
                            block,
                            index,
                            pairs,
                            message,
                        };
                        if !checks.contains(&check) {
                            checks.push(check);
                        }
                    }
                }
                Err(access) => {
                    errors.push(conflict_error(
                        body,
                        &access.place,
                        access.kind,
                        statement.span,
                    ));
                }
            }
            learn(
                body,
                &loans,
                &statement.kind,
                &carried,
                &mut copies,
                &mut values,
            );
            // Only `Bind` and `Release` change what a reference carries.
            let changed = match &statement.kind {
                StatementKind::Bind(reference, _) | StatementKind::Release(reference) => {
                    Some(*reference)
                }
                StatementKind::Assign(..)
                | StatementKind::Unpack(_)
                | StatementKind::Distinct { .. }
                | StatementKind::Keep(_) => None,
            };
            if let Some(reference) = changed {
                in_force.forget(carried.get(&reference));
            }
            carry(body, &statement.kind, own, &active, &mut carried);
            if let Some(reference) = changed {
                in_force.add(carried.get(&reference));
            }
            for reference in &dying[index] {
                in_force.forget(carried.remove(reference).as_ref());
            }
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

/// The state of the forward analysis of borrows at a point: the loans the
/// references carry, and what the index locals are known to hold. A block
/// that no edge has reached yet constrains nothing.
#[derive(Clone, PartialEq, Default)]
struct Flow {
    reached: bool,
    carried: Carried,
    copies: Copies,
}

impl Flow {
    /// The loans either side may carry; the copies both sides know.
    fn join(&mut self, other: &Self) {
        if !other.reached {
            return;
        }
        if !self.reached {
            *self = other.clone();
            return;
        }
        for (reference, theirs) in &other.carried {
            self.carried
                .entry(*reference)
                .or_default()
                .extend(theirs.iter().copied());
        }
        self.copies.join(&other.copies);
    }
}

/// An expression that a temporary is known to hold: over value places that
/// have not changed since, constants, and operators. Operands are the
/// numbers of other expressions in [`Values`], so equal expressions have one
/// number, and two indices that hold the same number are equal: places
/// written alike name the same element.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
enum Fact {
    Copy(Place),
    Constant(Key),
    Unary(u8, usize),
    Binary(u8, usize, usize),
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
enum Key {
    Int(i64),
    Bool(bool),
    Str(String),
}

/// The expressions known in a function, numbered once each, with the
/// locals each one reads.
#[derive(Default)]
struct Values {
    numbers: BTreeMap<Fact, usize>,
    facts: Vec<Fact>,
    reads: Vec<BTreeSet<Local>>,
}

impl Values {
    fn number(&mut self, fact: Fact) -> usize {
        if let Some(&number) = self.numbers.get(&fact) {
            return number;
        }
        let reads = match &fact {
            Fact::Copy(place) => BTreeSet::from([place.local]),
            Fact::Constant(_) => BTreeSet::new(),
            Fact::Unary(_, operand) => self.reads[*operand].clone(),
            Fact::Binary(_, left, right) => self.reads[*left]
                .union(&self.reads[*right])
                .copied()
                .collect(),
        };
        let number = self.facts.len();
        self.facts.push(fact.clone());
        self.reads.push(reads);
        self.numbers.insert(fact, number);
        number
    }

    /// The number of what `operand` is known to be: a temporary's
    /// expression, a copy of a value place of a variable, or a constant.
    fn operand(&mut self, body: &Body, operand: &Operand, copies: &Copies) -> Option<usize> {
        let fact = match operand {
            Operand::Copy(place) if body.locals[place.local].temporary => {
                return if place.projections.is_empty() {
                    copies.get(&place.local).copied()
                } else {
                    None
                };
            }
            Operand::Copy(place)
                if body.locals[place.local].reference.is_none()
                    && place
                        .projections
                        .iter()
                        .all(|projection| matches!(projection, Projection::Field(_))) =>
            {
                Fact::Copy(place.clone())
            }
            Operand::Constant(Constant::Int(value)) => Fact::Constant(Key::Int(*value)),
            Operand::Constant(Constant::Bool(value)) => Fact::Constant(Key::Bool(*value)),
            Operand::Constant(Constant::Str(value)) => Fact::Constant(Key::Str(value.clone())),
            _ => return None,
        };
        Some(self.number(fact))
    }
}

/// The number of the expression each temporary is known to hold, and the
/// temporaries whose expression reads each local, so a change of a local
/// forgets only what depends on it.
#[derive(Clone, Default)]
struct Copies {
    known: BTreeMap<Local, usize>,
    /// May also name temporaries that hold another expression by now; those
    /// are skipped.
    readers: BTreeMap<Local, BTreeSet<Local>>,
}

impl PartialEq for Copies {
    fn eq(&self, other: &Self) -> bool {
        self.known == other.known
    }
}

impl Copies {
    fn get(&self, temporary: &Local) -> Option<&usize> {
        self.known.get(temporary)
    }

    fn insert(&mut self, temporary: Local, number: usize, values: &Values) {
        for &read in &values.reads[number] {
            self.readers.entry(read).or_default().insert(temporary);
        }
        self.known.insert(temporary, number);
    }

    /// Forgets what each temporary in `changed` holds, and every expression
    /// that reads a local in `changed`.
    fn change(&mut self, changed: &BTreeSet<Local>, values: &Values) {
        for local in changed {
            self.known.remove(local);
            for reader in self.readers.remove(local).into_iter().flatten() {
                if self
                    .known
                    .get(&reader)
                    .is_some_and(|&number| values.reads[number].contains(local))
                {
                    self.known.remove(&reader);
                }
            }
        }
    }

    /// Keeps what `other` knows too.
    fn join(&mut self, other: &Self) {
        self.known
            .retain(|temporary, number| other.known.get(temporary) == Some(number));
    }
}

/// Updates what the temporaries are known to hold after `statement`. It
/// forgets every expression that reads a local the statement may change:
/// one it writes, takes or ends, and one it may change through a reference
/// that carries a `&mut` loan of it, by writing through the reference or by
/// passing it to a call. Then it learns what the statement stores in a
/// temporary, if that is an expression of known values.
fn learn(
    body: &Body,
    loans: &[Loan],
    statement: &StatementKind,
    carried: &Carried,
    copies: &mut Copies,
    values: &mut Values,
) {
    let mut changed = BTreeSet::new();
    let through = |reference: Local, changed: &mut BTreeSet<Local>| {
        for &loan in carried.get(&reference).into_iter().flatten() {
            if loans[loan].kind != RefKind::Shared {
                changed.insert(loans[loan].place.local);
            }
        }
    };
    let value = match statement {
        StatementKind::Assign(destination, value) => {
            if body.locals[destination.local].reference.is_some() {
                through(destination.local, &mut changed);
            } else {
                changed.insert(destination.local);
            }
            Some(value)
        }
        StatementKind::Bind(reference, value) => {
            changed.insert(*reference);
            Some(value)
        }
        StatementKind::Unpack(taken) => {
            for (local, place) in taken {
                changed.insert(*local);
                changed.insert(place.local);
            }
            None
        }
        StatementKind::Release(local) => {
            changed.insert(*local);
            None
        }
        StatementKind::Distinct { .. } | StatementKind::Keep(_) => None,
    };
    if let Some(value) = value {
        for operand in value.operands() {
            match operand {
                Operand::Move(place) => {
                    changed.insert(place.local);
                }
                Operand::Borrowed(reference) => through(*reference, &mut changed),
                Operand::Copy(_) | Operand::Inspect(_) | Operand::Constant(_) => {}
            }
        }
        if let Rvalue::Builtin { receiver, .. } = value
            && body.locals[receiver.local].reference.is_some()
        {
            through(receiver.local, &mut changed);
        }
    }
    copies.change(&changed, values);
    if let StatementKind::Assign(destination, value) = statement
        && destination.projections.is_empty()
        && body.locals[destination.local].temporary
        && body.locals[destination.local].reference.is_none()
    {
        let number = match value {
            Rvalue::Use(value) => values.operand(body, value, copies),
            Rvalue::Unary(operator, value) => values
                .operand(body, value, copies)
                .map(|value| values.number(Fact::Unary(*operator as u8, value))),
            Rvalue::Binary(operator, left, right) => {
                let left = values.operand(body, left, copies);
                let right = values.operand(body, right, copies);
                left.zip(right)
                    .map(|(left, right)| values.number(Fact::Binary(*operator as u8, left, right)))
            }
            _ => None,
        };
        if let Some(number) = number {
            copies.insert(destination.local, number, values);
        }
    }
}
/// How two places relate.
enum Overlap {
    /// They never reach the same storage.
    Disjoint,
    /// One contains the other, whatever their indices hold.
    Certain,
    /// They are the same element if each pair of indices or keys is equal,
    /// which only their values at run time tell.
    IfEqual(Vec<(Operand, Operand)>),
}

/// What an index projection is known to be.
#[derive(PartialEq)]
enum IndexValue {
    Constant(Key),
    Known(usize),
    Local(Local),
}

fn index_value(projection: &Projection, copies: &Copies, values: &Values) -> IndexValue {
    match projection {
        Projection::ConstantIndex(value) => IndexValue::Constant(Key::Int(*value)),
        Projection::Index(local) | Projection::Position(local) => match copies.get(local) {
            Some(&number) => match &values.facts[number] {
                Fact::Constant(key) => IndexValue::Constant(key.clone()),
                _ => IndexValue::Known(number),
            },
            None => IndexValue::Local(*local),
        },
        Projection::Field(_) | Projection::VariantField { .. } => {
            unreachable!("not an index")
        }
    }
}
fn index_operand(projection: &Projection) -> Operand {
    match projection {
        Projection::ConstantIndex(value) => Operand::Constant(Constant::Int(*value)),
        Projection::Index(local) | Projection::Position(local) => {
            Operand::Copy(Place::local(*local))
        }
        Projection::Field(_) | Projection::VariantField { .. } => {
            unreachable!("not an index")
        }
    }
}

/// How the places `left` and `right` relate, given what the index locals
/// are known to hold. This is the one judgement of overlap: a step that
/// reaches a place a live loan has lent is an error when they certainly
/// overlap, and is preceded by a run-time check when only the values of
/// their indices tell.
fn overlap(left: &Place, right: &Place, copies: &Copies, values: &Values) -> Overlap {
    if left.local != right.local {
        return Overlap::Disjoint;
    }
    let is_index = |projection: &Projection| {
        matches!(
            projection,
            Projection::Index(_) | Projection::ConstantIndex(_) | Projection::Position(_)
        )
    };
    let mut pairs = Vec::new();
    for (step, other) in left.projections.iter().zip(&right.projections) {
        match (step, other) {
            (Projection::Field(a), Projection::Field(b)) if a != b => return Overlap::Disjoint,
            (
                Projection::VariantField { variant, field },
                Projection::VariantField {
                    variant: other_variant,
                    field: other_field,
                },
            ) if variant != other_variant || field != other_field => return Overlap::Disjoint,
            _ if is_index(step) && is_index(other) => {
                let (a, b) = (
                    index_value(step, copies, values),
                    index_value(other, copies, values),
                );
                if a == b {
                    continue;
                }
                if let (IndexValue::Constant(_), IndexValue::Constant(_)) = (&a, &b) {
                    return Overlap::Disjoint;
                }
                // A position and a key do not compare; take them as the same.
                if matches!(step, Projection::Position(_))
                    == matches!(other, Projection::Position(_))
                {
                    pairs.push((index_operand(step), index_operand(other)));
                }
            }
            _ => {}
        }
    }
    if pairs.is_empty() {
        Overlap::Certain
    } else {
        Overlap::IfEqual(pairs)
    }
}

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
        StatementKind::Assign(..)
        | StatementKind::Unpack(_)
        | StatementKind::Distinct { .. }
        | StatementKind::Keep(_) => {}
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
        StatementKind::Keep(reference) => (vec![*reference], Vec::new()),
        StatementKind::Distinct { pairs, .. } => (
            pairs
                .iter()
                .flat_map(|(left, right)| {
                    locals(operand_places(left)).chain(locals(operand_places(right)))
                })
                .collect(),
            Vec::new(),
        ),
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

/// The loans in force while a block is checked: those that some reference
/// carries that the statement being checked uses or a later step uses.
/// They are kept by the local of their place, so an access looks only at
/// the loans of the local it touches; `&mut` loans apart, as only they
/// conflict with borrowing with `&`.
struct InForce<'a> {
    loans: &'a [Loan],
    /// How many references carry each loan in force.
    carriers: BTreeMap<usize, usize>,
    mutable: BTreeMap<Local, BTreeSet<usize>>,
    other: BTreeMap<Local, BTreeSet<usize>>,
}

impl<'a> InForce<'a> {
    fn new(loans: &'a [Loan], carried: &Carried) -> Self {
        let mut in_force = Self {
            loans,
            carriers: BTreeMap::new(),
            mutable: BTreeMap::new(),
            other: BTreeMap::new(),
        };
        for carried in carried.values() {
            in_force.add(Some(carried));
        }
        in_force
    }

    fn by_kind(&mut self, loan: usize) -> &mut BTreeSet<usize> {
        let loan = &self.loans[loan];
        let index = match loan.kind {
            RefKind::Mutable => &mut self.mutable,
            RefKind::Shared | RefKind::MutableArgument => &mut self.other,
        };
        index.entry(loan.place.local).or_default()
    }

    /// Adds the loans a reference carries.
    fn add(&mut self, carried: Option<&BTreeSet<usize>>) {
        for &loan in carried.into_iter().flatten() {
            let count = self.carriers.entry(loan).or_default();
            *count += 1;
            if *count == 1 {
                self.by_kind(loan).insert(loan);
            }
        }
    }

    /// Removes the loans a reference carried.
    fn forget(&mut self, carried: Option<&BTreeSet<usize>>) {
        for &loan in carried.into_iter().flatten() {
            let count = self.carriers.get_mut(&loan).expect("the loan is in force");
            *count -= 1;
            if *count == 0 {
                self.carriers.remove(&loan);
                self.by_kind(loan).remove(&loan);
            }
        }
    }

    /// Checks the accesses a statement makes against the loans in force
    /// whose kinds conflict with them, other than `exempt` ones. Returns the
    /// first access that certainly overlaps such a loan, or else the
    /// run-time checks the statement needs: for each loan that only the
    /// values of indices tell apart, the pairs of indices that must not all
    /// be equal, and the message to panic with.
    #[allow(clippy::type_complexity)]
    fn check<'m>(
        &self,
        made: &'m [Made],
        copies: &Copies,
        values: &Values,
    ) -> Result<Vec<(Vec<(Operand, Operand)>, &'static str)>, &'m Made> {
        let mut found = Vec::new();
        for access in made {
            let local = access.place.local;
            let other = match access.kind {
                Access::ReadValue => continue,
                Access::Share | Access::Reserve => None,
                Access::Borrow | Access::Write | Access::Move | Access::Release => {
                    self.other.get(&local)
                }
            };
            let message = match access.kind {
                Access::Write => "a borrowed element is changed",
                _ => "the same element is borrowed twice",
            };
            let candidates = self.mutable.get(&local).into_iter().flatten();
            for &loan in candidates.chain(other.into_iter().flatten()) {
                let lent = &self.loans[loan];
                if access.exempt.contains(&loan) || !kinds_conflict(lent.kind, access.kind) {
                    continue;
                }
                match overlap(&lent.place, &access.place, copies, values) {
                    Overlap::Disjoint => {}
                    Overlap::Certain => return Err(access),
                    Overlap::IfEqual(pairs) => found.push((pairs, message)),
                }
            }
        }
        Ok(found)
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
        // Reads indices, which are values.
        StatementKind::Distinct { .. } | StatementKind::Keep(_) => return made,
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
    for &reference in &activated {
        for loan_index in own_loans(loans, carried, reference) {
            let loan = &loans[loan_index];
            if loan.kind != RefKind::MutableArgument {
                continue;
            }
            // Not counting the loans it is made through.
            made.push(Made {
                place: loan.place.clone(),
                kind: Access::Borrow,
                exempt: carried_by(carried, reference),
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

/// Whether an access of kind `access` conflicts with a loan of kind `loan`
/// of a place it overlaps.
fn kinds_conflict(loan: RefKind, access: Access) -> bool {
    match (loan, access) {
        (_, Access::ReadValue) => false,
        (RefKind::Mutable, _) => true,
        (RefKind::Shared | RefKind::MutableArgument, access) => matches!(
            access,
            Access::Borrow | Access::Write | Access::Move | Access::Release
        ),
    }
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
                    StatementKind::Release(_)
                    | StatementKind::Unpack(_)
                    | StatementKind::Distinct { .. }
                    | StatementKind::Keep(_) => false,
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
pub(crate) fn rvalue_places(value: &Rvalue) -> Vec<Place> {
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

pub(crate) fn operand_places(operand: &Operand) -> Vec<Place> {
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
