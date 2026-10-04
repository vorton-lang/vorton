//! What index temporaries are known to hold, and whether two places are the
//! same: the one judgement of overlap.

use std::collections::{BTreeMap, BTreeSet};

use super::loans::{Carried, Loan};
use crate::mir::{
    Body, Constant, Local, Operand, Place, Projection, RefKind, Rvalue, StatementKind,
};

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
pub(super) struct Values {
    /// The temporaries whose value may tell whether two places are the same
    /// element: those that index a place, and those such a temporary is
    /// computed from. Only what these hold is worth knowing.
    wanted: BTreeSet<Local>,
    numbers: BTreeMap<Fact, usize>,
    facts: Vec<Fact>,
    reads: Vec<BTreeSet<Local>>,
}

impl Values {
    pub(super) fn new(body: &Body) -> Self {
        let mut wanted = BTreeSet::new();
        // The temporaries each temporary is computed from.
        let mut sources: BTreeMap<Local, Vec<Local>> = BTreeMap::new();
        let mut places = Vec::new();
        for data in &body.blocks {
            for statement in &data.statements {
                match &statement.kind {
                    StatementKind::Assign(destination, value) => {
                        places.push(destination.clone());
                        places.extend(value.places());
                        if destination.projections.is_empty() {
                            let read =
                                value
                                    .operands()
                                    .into_iter()
                                    .filter_map(|operand| match operand {
                                        Operand::Copy(place) if place.projections.is_empty() => {
                                            Some(place.local)
                                        }
                                        _ => None,
                                    });
                            sources.entry(destination.local).or_default().extend(read);
                        }
                    }
                    StatementKind::Bind(_, value) => places.extend(value.places()),
                    StatementKind::Unpack(taken) => {
                        places.extend(taken.iter().map(|(_, place)| place.clone()));
                    }
                    StatementKind::Release(_)
                    | StatementKind::Keep(_)
                    | StatementKind::Distinct { .. } => {}
                }
            }
            places.extend(data.terminator.kind.places(body));
        }
        for place in &places {
            for projection in &place.projections {
                if let Projection::Index(local) | Projection::Position(local) = projection {
                    wanted.insert(*local);
                }
            }
        }
        let mut pending = wanted.iter().copied().collect::<Vec<_>>();
        while let Some(local) = pending.pop() {
            for &source in sources.get(&local).into_iter().flatten() {
                if wanted.insert(source) {
                    pending.push(source);
                }
            }
        }
        Self {
            wanted,
            numbers: BTreeMap::new(),
            facts: Vec::new(),
            reads: Vec::new(),
        }
    }

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
pub(super) struct Copies {
    known: BTreeMap<Local, usize>,
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
        self.forget(temporary, values);
        for &read in &values.reads[number] {
            self.readers.entry(read).or_default().insert(temporary);
        }
        self.known.insert(temporary, number);
    }

    fn forget(&mut self, temporary: Local, values: &Values) {
        let Some(number) = self.known.remove(&temporary) else {
            return;
        };
        for read in &values.reads[number] {
            if let Some(readers) = self.readers.get_mut(read) {
                readers.remove(&temporary);
                if readers.is_empty() {
                    self.readers.remove(read);
                }
            }
        }
    }

    /// Forgets what each temporary in `changed` holds, and every expression
    /// that reads a local in `changed`.
    fn change(&mut self, changed: &BTreeSet<Local>, values: &Values) {
        for &local in changed {
            self.forget(local, values);
            for reader in self.readers.remove(&local).into_iter().flatten() {
                self.forget(reader, values);
            }
        }
    }

    /// Keeps what `other` knows too.
    pub(super) fn join(&mut self, other: &Self) {
        self.known
            .retain(|temporary, number| other.known.get(temporary) == Some(number));
        let known = &self.known;
        self.readers.retain(|_, readers| {
            readers.retain(|reader| known.contains_key(reader));
            !readers.is_empty()
        });
    }
}
/// Updates what the temporaries are known to hold after `statement`. It
/// forgets every expression that reads a local the statement may change:
/// one it writes, takes or ends, and one it may change through a reference
/// that carries a `&mut` loan of it, by writing through the reference or by
/// passing it to a call. Then it learns what the statement stores in a
/// temporary, if that is an expression of known values.
pub(super) fn learn(
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
        && values.wanted.contains(&destination.local)
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
pub(super) enum Overlap {
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
pub(super) fn overlap(left: &Place, right: &Place, copies: &Copies, values: &Values) -> Overlap {
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
