//! Borrow checking: which loans each reference carries, and which accesses
//! conflict with the loans in force.

use std::collections::{BTreeMap, BTreeSet};

use super::Error;
use super::values::{Copies, Overlap, Values, learn, overlap};
use crate::ast::Span;
use crate::dataflow::{self, Graph, Sets};
use crate::diagnostic::CheckDiagnosticKind;
use crate::mir::{
    BasicBlock, BlockId, Body, Check, Local, Operand, Place, RefKind, Rvalue, StatementKind,
    TerminatorKind,
};
use crate::types::Types;

pub(super) struct Loan {
    pub(super) place: Place,
    pub(super) kind: RefKind,
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

/// Every loan of a body, by the statement that makes it.
struct Loans {
    list: Vec<Loan>,
    /// The loan that each `Bind` of a `Ref` makes, by block and statement.
    at: BTreeMap<(BlockId, usize), usize>,
    /// A `&mut` argument is reserved until its call runs. A borrow that the
    /// call returns carries it from then on as an active `&mut` loan: the
    /// twin of each reserved loan.
    active: Vec<Option<usize>>,
}

impl Loans {
    fn collect(body: &Body) -> Self {
        let mut list = Vec::new();
        let mut at = BTreeMap::new();
        for (block, data) in body.blocks.iter().enumerate() {
            for (index, statement) in data.statements.iter().enumerate() {
                if let StatementKind::Bind(reference, Rvalue::Ref(kind, place)) = &statement.kind {
                    at.insert((block, index), list.len());
                    list.push(Loan {
                        place: place.clone(),
                        kind: *kind,
                        reference: *reference,
                    });
                }
            }
        }
        let mut active = vec![None; list.len()];
        for (index, twin) in active.iter_mut().enumerate() {
            if list[index].kind == RefKind::MutableArgument {
                *twin = Some(list.len());
                list.push(Loan {
                    place: list[index].place.clone(),
                    kind: RefKind::Mutable,
                    reference: list[index].reference,
                });
            }
        }
        Self { list, at, active }
    }

    fn made_at(&self, block: BlockId, index: usize) -> Option<usize> {
        self.at.get(&(block, index)).copied()
    }
}

pub(super) fn check_borrows(
    body: &Body,
    types: &Types,
    graph: &Graph,
    live: &Sets,
    errors: &mut Vec<Error>,
    checks: &mut Vec<Check>,
) {
    let mut borrows = Borrows {
        body,
        types,
        live,
        loans: Loans::collect(body),
        values: Values::new(body),
    };
    let starts = dataflow::forward(graph, Flow::default(), Flow::join, |block, state| {
        borrows.transfer(block, state);
    });
    for &block in &graph.order {
        let start = starts[block].clone().expect("a reachable block is reached");
        borrows.check_block(block, start, errors, checks);
    }
}

struct Borrows<'a> {
    body: &'a Body,
    types: &'a Types,
    live: &'a Sets,
    loans: Loans,
    /// The expressions the temporaries are known to hold, numbered.
    values: Values,
}

impl Borrows<'_> {
    /// What the references carry, and what the temporaries hold, after
    /// `block`, keeping only the references live at its edges.
    fn transfer(&mut self, block: BlockId, state: &mut Flow) {
        let live = self.live;
        state
            .carried
            .retain(|reference, _| live.starts[block].contains(reference));
        for (index, statement) in self.body.blocks[block].statements.iter().enumerate() {
            state.step(
                self.body,
                &self.loans,
                &mut self.values,
                (block, index),
                &statement.kind,
            );
        }
        state
            .carried
            .retain(|reference, _| live.ends[block].contains(reference));
    }

    /// Checks each access of `block` against the loans in force, starting
    /// from `state`, and a borrow that the block returns.
    fn check_block(
        &mut self,
        block: BlockId,
        mut state: Flow,
        errors: &mut Vec<Error>,
        checks: &mut Vec<Check>,
    ) {
        let body = self.body;
        let live = self.live;
        state
            .carried
            .retain(|reference, _| live.starts[block].contains(reference));
        let dying = dying(body, live, block);
        let mut in_force = InForce::new(&self.loans.list, &state.carried);
        for (index, statement) in body.blocks[block].statements.iter().enumerate() {
            let own = self.loans.made_at(block, index);
            let made = accesses(
                body,
                self.types,
                &self.loans.list,
                &state.carried,
                &statement.kind,
                own,
            );
            match in_force.check(&made, &state.copies, &self.values) {
                Ok(found) => {
                    let mut needed = Vec::new();
                    for (pairs, message) in found {
                        let check = Check {
                            block,
                            index,
                            pairs,
                            message,
                        };
                        if !needed.contains(&check) {
                            needed.push(check);
                        }
                    }
                    checks.extend(needed);
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
                in_force.forget(state.carried.get(&reference));
            }
            state.step(
                body,
                &self.loans,
                &mut self.values,
                (block, index),
                &statement.kind,
            );
            if let Some(reference) = changed {
                in_force.add(state.carried.get(&reference));
            }
            for reference in &dying[index] {
                in_force.forget(state.carried.remove(reference).as_ref());
            }
        }
        if let TerminatorKind::Return = body.blocks[block].terminator.kind
            && body.locals[body.result].reference.is_some()
        {
            check_returned(
                body,
                &self.loans.list,
                &carried_by(&state.carried, body.result),
                &body.blocks[block],
                errors,
            );
        }
    }
}

/// The references that each statement of `block` is the last to use, or
/// that it makes point somewhere no later step looks: they are dead after
/// it.
fn dying(body: &Body, live: &Sets, block: BlockId) -> Vec<Vec<Local>> {
    let is_reference = |local: &Local| body.locals[*local].reference.is_some();
    let data = &body.blocks[block];
    let mut dying = vec![Vec::new(); data.statements.len()];
    let mut references = live.ends[block].clone();
    references.extend(
        data.terminator
            .kind
            .places(body)
            .into_iter()
            .map(|place| place.local),
    );
    references.retain(is_reference);
    for (index, statement) in data.statements.iter().enumerate().rev() {
        let effects = statement.kind.effects(body);
        let uses = effects
            .reads
            .into_iter()
            .chain(effects.changes)
            .collect::<Vec<_>>();
        dying[index] = uses
            .iter()
            .chain(&effects.replaces)
            .copied()
            .filter(|local| is_reference(local) && !references.contains(local))
            .collect();
        for replaced in &effects.replaces {
            references.remove(replaced);
        }
        references.extend(uses.into_iter().filter(is_reference));
    }
    dying
}
/// The loans that each reference local may carry, for the references that
/// carry any, so a step looks only at the references it names.
pub(super) type Carried = BTreeMap<Local, BTreeSet<usize>>;

/// The state of the forward analysis of borrows at a point: the loans the
/// references carry, and what the index locals are known to hold.
#[derive(Clone, PartialEq, Default)]
struct Flow {
    carried: Carried,
    copies: Copies,
}

impl Flow {
    /// Updates the state after the statement at `at`.
    fn step(
        &mut self,
        body: &Body,
        loans: &Loans,
        values: &mut Values,
        (block, index): (BlockId, usize),
        statement: &StatementKind,
    ) {
        learn(
            body,
            &loans.list,
            statement,
            &self.carried,
            &mut self.copies,
            values,
        );
        let own = loans.made_at(block, index);
        carry(body, statement, own, &loans.active, &mut self.carried);
    }

    /// The loans either side may carry; the copies both sides know.
    fn join(&mut self, other: &Self) {
        for (reference, theirs) in &other.carried {
            self.carried
                .entry(*reference)
                .or_default()
                .extend(theirs.iter().copied());
        }
        self.copies.join(&other.copies);
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
    block: &BasicBlock,
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
