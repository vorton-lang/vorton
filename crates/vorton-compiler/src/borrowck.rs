//! Move and borrow checking on the IR.
//!
//! Both checks follow the edges of the control-flow graph, so every
//! construct that branches, loops or skips code is covered alike.
//!
//! - **Moves.** A forward analysis finds the places that may hold nothing at
//!   each point: not yet assigned, moved away, or released. Using one is an
//!   error. Moving a part of a variable counts as moving all of it, as the
//!   spec says; the temporaries of lowering are tracked part by part.
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

use std::collections::BTreeSet;

use crate::ast::Span;
use crate::checker::{CheckDiagnostic, CheckDiagnosticKind};
use crate::mir::{
    BlockId, Body, Operand, Place, Projection, RefKind, Rvalue, StatementKind, TerminatorKind,
};
use crate::project::OriginRef;

pub(crate) fn check(body: &Body, at: &dyn Fn(Span) -> OriginRef) -> Result<(), CheckDiagnostic> {
    let graph = Graph::new(body);
    let mut errors = Vec::new();
    check_moves(body, &graph, &mut errors);
    check_borrows(body, &graph, &mut errors);
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

// Moves.

/// The places that may hold nothing.
type Empty = BTreeSet<Place>;

fn check_moves(body: &Body, graph: &Graph, errors: &mut Vec<Error>) {
    let entry = (0..body.locals.len())
        .filter(|local| !body.parameters.contains(local))
        .map(Place::local)
        .collect::<Empty>();
    let starts = forward(
        graph,
        entry,
        &Empty::new(),
        |state, other| state.extend(other.iter().cloned()),
        |block, state| {
            for statement in &body.blocks[block].statements {
                move_statement(body, &statement.kind, statement.span, state, None);
            }
        },
    );
    for &block in &graph.order {
        let mut state = starts[block].clone();
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
    match statement {
        StatementKind::Assign(destination, value) => {
            if let Some(errors) = errors.as_deref_mut() {
                for place in rvalue_places(value) {
                    check_filled(body, state, &place, span, errors);
                }
            }
            for operand in rvalue_operands(value) {
                if let Operand::Move(place) = operand {
                    state.insert(moved_place(body, place));
                }
            }
            if !body.defines_pointer(destination, value)
                && !is_whole(body, destination)
                && let Some(errors) = errors
            {
                // Writing through a reference needs it to point somewhere,
                // and writing into a part needs the whole to be there.
                let reference = body.locals[destination.local].reference.is_some();
                let missing = state.iter().any(|empty| {
                    if reference {
                        *empty == Place::local(destination.local)
                    } else {
                        is_prefix(empty, destination)
                            && empty.projections.len() < destination.projections.len()
                    }
                });
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
            fill(state, destination);
        }
        StatementKind::Release(local) => {
            state.retain(|place| place.local != *local);
            state.insert(Place::local(*local));
        }
    }
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

/// Records that `place` and everything inside it hold a value.
fn fill(state: &mut Empty, place: &Place) {
    state.retain(|empty| !is_prefix(place, empty));
}

fn check_filled(body: &Body, state: &Empty, place: &Place, span: Span, errors: &mut Vec<Error>) {
    if state.iter().any(|empty| {
        empty.local == place.local && (is_prefix(empty, place) || is_prefix(place, empty))
    }) {
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

fn check_borrows(body: &Body, graph: &Graph, errors: &mut Vec<Error>) {
    // Every loan, by the statement that makes it.
    let mut loans = Vec::new();
    let mut loan_at = std::collections::BTreeMap::new();
    for (block, data) in body.blocks.iter().enumerate() {
        for (index, statement) in data.statements.iter().enumerate() {
            if let StatementKind::Assign(destination, value @ Rvalue::Ref(kind, place)) =
                &statement.kind
                && body.defines_pointer(destination, value)
            {
                loan_at.insert((block, index), loans.len());
                loans.push(Loan {
                    place: place.clone(),
                    kind: *kind,
                    reference: destination.local,
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
    let count = body.locals.len();
    // The loans each reference local may carry.
    let carried_starts = forward(
        graph,
        vec![BTreeSet::new(); count],
        &vec![BTreeSet::new(); count],
        |state: &mut Vec<BTreeSet<usize>>, other| {
            for (mine, theirs) in state.iter_mut().zip(other) {
                mine.extend(theirs.iter().copied());
            }
        },
        |block, state| {
            for (index, statement) in body.blocks[block].statements.iter().enumerate() {
                let own = loan_at.get(&(block, index)).copied();
                carry(body, &statement.kind, own, &active, state);
            }
        },
    );
    let live_ends = liveness(body, graph);
    for &block in &graph.order {
        let mut carried = carried_starts[block].clone();
        // The references live after each statement, from the block's end
        // backwards.
        let statements = &body.blocks[block].statements;
        let mut live_after = vec![BTreeSet::new(); statements.len()];
        let mut live = live_ends[block].clone();
        terminator_uses(body, &body.blocks[block].terminator.kind, &mut live);
        for (index, statement) in statements.iter().enumerate().rev() {
            live_after[index] = live.clone();
            let (uses, defines) = reference_uses(body, &statement.kind);
            if let Some(defined) = defines {
                live.remove(&defined);
            }
            live.extend(uses);
        }
        for (index, statement) in statements.iter().enumerate() {
            let own = loan_at.get(&(block, index)).copied();
            check_statement(
                body,
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
                &carried[body.result],
                &body.blocks[block],
                errors,
            );
        }
    }
}

/// Updates the loans the reference locals carry after `statement`.
fn carry(
    body: &Body,
    statement: &StatementKind,
    own: Option<usize>,
    active: &[Option<usize>],
    carried: &mut [BTreeSet<usize>],
) {
    match statement {
        StatementKind::Assign(destination, value) if body.defines_pointer(destination, value) => {
            let mut loans = BTreeSet::new();
            match value {
                Rvalue::Ref(_, place) => {
                    loans.extend(own);
                    if body.locals[place.local].reference.is_some() {
                        loans.extend(carried[place.local].iter().copied());
                    }
                }
                Rvalue::Call { arguments, .. } => {
                    for argument in arguments {
                        if let Operand::Borrowed(reference) = argument {
                            loans.extend(
                                carried[*reference].iter().map(|&loan| {
                                    active.get(loan).copied().flatten().unwrap_or(loan)
                                }),
                            );
                        }
                    }
                }
                _ => unreachable!("only borrows and calls define pointers"),
            }
            carried[destination.local] = loans;
        }
        StatementKind::Release(local) => carried[*local].clear(),
        StatementKind::Assign(..) => {}
    }
}

/// The reference locals live at the end of each block.
fn liveness(body: &Body, graph: &Graph) -> Vec<BTreeSet<usize>> {
    let count = body.blocks.len();
    let mut ends = vec![BTreeSet::new(); count];
    let mut starts = vec![BTreeSet::<usize>::new(); count];
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
                let (uses, defines) = reference_uses(body, &statement.kind);
                if let Some(defined) = defines {
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
    ends
}

fn terminator_uses(body: &Body, terminator: &TerminatorKind, live: &mut BTreeSet<usize>) {
    match terminator {
        TerminatorKind::Branch { condition, .. } => {
            for place in operand_places(condition) {
                if body.locals[place.local].reference.is_some() {
                    live.insert(place.local);
                }
            }
        }
        // A returned borrow lives on in the caller.
        TerminatorKind::Return if body.locals[body.result].reference.is_some() => {
            live.insert(body.result);
        }
        _ => {}
    }
}

/// The reference locals a statement uses, and the one it makes point
/// somewhere or ends.
fn reference_uses(body: &Body, statement: &StatementKind) -> (Vec<usize>, Option<usize>) {
    let is_reference = |local: usize| body.locals[local].reference.is_some();
    match statement {
        StatementKind::Assign(destination, value) => {
            let mut uses = rvalue_places(value)
                .into_iter()
                .map(|place| place.local)
                .chain(
                    rvalue_operands(value)
                        .iter()
                        .filter_map(|operand| match operand {
                            Operand::Borrowed(local) => Some(*local),
                            _ => None,
                        }),
                )
                .filter(|&local| is_reference(local))
                .collect::<Vec<_>>();
            if body.defines_pointer(destination, value) {
                (uses, Some(destination.local))
            } else {
                if is_reference(destination.local) {
                    uses.push(destination.local);
                }
                (uses, None)
            }
        }
        StatementKind::Release(local) if is_reference(*local) => (Vec::new(), Some(*local)),
        StatementKind::Release(_) => (Vec::new(), None),
    }
}

#[allow(clippy::too_many_arguments)]
fn check_statement(
    body: &Body,
    loans: &[Loan],
    carried: &[BTreeSet<usize>],
    live_after: &BTreeSet<usize>,
    own: Option<usize>,
    statement: &StatementKind,
    span: Span,
    errors: &mut Vec<Error>,
) {
    let (uses, _) = reference_uses(body, statement);
    // The loans that hold while the statement runs: those of the references
    // used later and of those it uses itself.
    let mut live = BTreeSet::new();
    for reference in live_after.iter().chain(&uses) {
        live.extend(carried[*reference].iter().copied());
    }
    let accesses = accesses(body, loans, carried, statement, own);
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
    loans: &[Loan],
    carried: &[BTreeSet<usize>],
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
    match statement {
        StatementKind::Release(local) => {
            if body.locals[*local].reference.is_none() {
                access(&Place::local(*local), Access::Release);
            }
        }
        StatementKind::Assign(destination, value) => {
            match value {
                Rvalue::Ref(kind, place) => access(
                    place,
                    match kind {
                        RefKind::Shared => Access::Share,
                        RefKind::MutableArgument => Access::Reserve,
                        RefKind::Mutable => Access::Borrow,
                    },
                ),
                Rvalue::Discriminant(_) | Rvalue::Len(_) | Rvalue::Occupied { .. } => {}
                _ => {
                    for operand in rvalue_operands(value) {
                        match operand {
                            Operand::Copy(place) => access(place, Access::ReadValue),
                            Operand::Move(place) => access(place, Access::Move),
                            Operand::Borrowed(_) | Operand::Constant(_) => {}
                        }
                    }
                }
            }
            if !body.defines_pointer(destination, value) {
                access(destination, Access::Write);
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
                _ => Vec::new(),
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
                    let mut exempt = carried[reference].clone();
                    exempt.extend(
                        siblings.iter().copied().filter(|&sibling| {
                            differs_in_indices(&loans[sibling].place, &loan.place)
                        }),
                    );
                    made.push(Made {
                        place: loan.place.clone(),
                        kind: Access::Borrow,
                        exempt,
                    });
                }
            }
        }
    }
    made
}

/// The loans made for `reference` itself.
fn own_loans(loans: &[Loan], carried: &[BTreeSet<usize>], reference: usize) -> Vec<usize> {
    carried[reference]
        .iter()
        .copied()
        .filter(|&loan| loans[loan].reference == reference)
        .collect()
}

/// Whether two places of one local have the same shape and differ only in
/// list indices that are not both constants.
fn differs_in_indices(left: &Place, right: &Place) -> bool {
    left.local == right.local
        && left.projections.len() == right.projections.len()
        && left
            .projections
            .iter()
            .zip(&right.projections)
            .any(|(left, right)| left != right)
        && left
            .projections
            .iter()
            .zip(&right.projections)
            .all(|(left, right)| {
                left == right || (is_index(left) && is_index(right) && !both_constant(left, right))
            })
}

fn is_index(projection: &Projection) -> bool {
    matches!(
        projection,
        Projection::Index(_) | Projection::ConstantIndex(_) | Projection::Position(_)
    )
}

fn both_constant(left: &Projection, right: &Projection) -> bool {
    matches!(
        (left, right),
        (Projection::ConstantIndex(_), Projection::ConstantIndex(_))
    )
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
                .find(|statement| {
                    matches!(&statement.kind, StatementKind::Assign(destination, _) if destination.local == body.result)
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

fn rvalue_operands(value: &Rvalue) -> Vec<&Operand> {
    match value {
        Rvalue::Use(operand) | Rvalue::Unary(_, operand) => vec![operand],
        Rvalue::Binary(_, left, right) => vec![left, right],
        Rvalue::Tuple(operands)
        | Rvalue::List(operands)
        | Rvalue::Interpolate(operands)
        | Rvalue::Call {
            arguments: operands,
            ..
        }
        | Rvalue::Intrinsic {
            arguments: operands,
            ..
        }
        | Rvalue::Builtin {
            arguments: operands,
            ..
        } => operands.iter().collect(),
        Rvalue::Construct { fields, .. } => fields.iter().map(|(_, operand)| operand).collect(),
        Rvalue::Range { start, end, .. } => vec![start, end],
        Rvalue::Ref(..)
        | Rvalue::EmptyMap
        | Rvalue::Discriminant(_)
        | Rvalue::Len(_)
        | Rvalue::Occupied { .. }
        | Rvalue::Take { .. } => Vec::new(),
    }
}

/// Every place an rvalue reads, takes or borrows, and the locals it reads
/// through: index locals and borrowed references.
fn rvalue_places(value: &Rvalue) -> Vec<Place> {
    let mut places = Vec::new();
    for operand in rvalue_operands(value) {
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
        _ => {}
    }
    places
}

fn operand_places(operand: &Operand) -> Vec<Place> {
    match operand {
        Operand::Copy(place) | Operand::Move(place) => {
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
