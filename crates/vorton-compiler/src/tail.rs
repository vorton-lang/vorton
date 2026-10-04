//! Tail calls of a function to itself, which the spec guarantees do not grow
//! the stack.
//!
//! The pass runs after instantiation, because whether a call is a tail call
//! depends on types: a local that may still hold a value with a hand-written
//! `drop` makes it none. Each call that is a tail call by the spec's
//! definition becomes a [`TerminatorKind::TailCall`], which code generation
//! emits as a jump to the start of the function.

use std::collections::BTreeSet;

use crate::mir::{
    BlockId, Body, Constant, Local, Operand, Place, Program, Rvalue, StatementKind, Terminator,
    TerminatorKind,
};
use crate::typed::Callee;
use crate::types::{Type, Types};

pub(crate) fn mark(program: &mut Program) {
    let types = &program.types;
    for (index, instance) in program.functions.iter_mut().enumerate() {
        let found = TailCalls::new(types, index, &instance.body).find();
        let body = &mut instance.body;
        for (block, statement, arguments, releases) in found {
            let data = &mut body.blocks[block];
            let span = data.statements[statement].span;
            data.statements.truncate(statement);
            data.terminator = Terminator {
                kind: TerminatorKind::TailCall {
                    arguments,
                    releases,
                },
                span,
            };
        }
    }
}

/// A tail call found in a block: the block, the statement of the call, its
/// arguments, and the locals to release before the jump.
type Found = (BlockId, usize, Vec<Operand>, Vec<Local>);

struct TailCalls<'a> {
    types: &'a Types,
    /// The function's own index, which a call of itself names.
    index: usize,
    body: &'a Body,
    /// What each reference local is made to point at: borrows and calls.
    definitions: Vec<Vec<&'a Rvalue>>,
    /// The owning locals that may hold something at the start of each
    /// block.
    filled: Vec<BTreeSet<Local>>,
}

impl<'a> TailCalls<'a> {
    fn new(types: &'a Types, index: usize, body: &'a Body) -> Self {
        let mut definitions = vec![Vec::new(); body.locals.len()];
        for block in &body.blocks {
            for statement in &block.statements {
                if let StatementKind::Bind(reference, value) = &statement.kind {
                    definitions[*reference].push(value);
                }
            }
        }
        Self {
            types,
            index,
            body,
            definitions,
            filled: body.maybe_filled(types),
        }
    }

    fn find(&self) -> Vec<Found> {
        let mut found = Vec::new();
        for block in self.body.reverse_postorder() {
            for statement in 0..self.body.blocks[block].statements.len() {
                if let Some((arguments, releases)) = self.tail_call(block, statement) {
                    found.push((block, statement, arguments.to_vec(), releases));
                    break;
                }
            }
        }
        found
    }

    /// If statement `index` of `block` is a tail call of the function
    /// itself, as the spec defines it, its arguments and the locals to
    /// release before the jump: those the path to the return releases, or
    /// every local when the call does not return.
    fn tail_call(&self, block: BlockId, index: usize) -> Option<(&'a [Operand], Vec<Local>)> {
        let body = self.body;
        let data = &body.blocks[block];
        let (destination, value) = match &data.statements[index].kind {
            StatementKind::Assign(destination, value) => (destination.clone(), value),
            StatementKind::Bind(reference, value) => (Place::local(*reference), value),
            StatementKind::Release(_) => return None,
        };
        let Rvalue::Call {
            callee: Callee::Function(callee),
            arguments,
            ..
        } = value
        else {
            return None;
        };
        if *callee != self.index {
            return None;
        }
        // In tail position: the function returns what the call returns,
        // with nothing to do after it but release its locals.
        let ty = body.place_type(self.types, &destination);
        let releases = if ty == Type::NEVER {
            if index + 1 != data.statements.len()
                || !matches!(data.terminator.kind, TerminatorKind::Unreachable)
            {
                return None;
            }
            (0..body.locals.len()).rev().collect()
        } else {
            let result = destination == Place::local(body.result);
            let unit = ty == Type::UNIT && body.locals[body.result].ty == Type::UNIT;
            if !result && !unit {
                return None;
            }
            self.releases_to_return(block, index)?
        };
        // A borrowed local or temporary must live until the call returns.
        let outside = arguments.iter().all(|argument| match argument {
            Operand::Borrowed(reference) => self.points_outside(*reference, &mut BTreeSet::new()),
            _ => true,
        });
        // A value whose `drop` runs after the call returns makes it no tail
        // call; releasing anything else early is not observable.
        let mut filled = self.filled[block].clone();
        for statement in &data.statements[..=index] {
            body.fill(self.types, &statement.kind, &mut filled);
        }
        filled.remove(&destination.local);
        let drops = filled
            .iter()
            .any(|&local| self.types.runs_drop(body.locals[local].ty));
        (outside && !drops).then_some((arguments.as_slice(), releases))
    }

    /// The locals released after statement `index` of `block` until the
    /// function returns, if the path there does nothing else.
    fn releases_to_return(&self, block: BlockId, index: usize) -> Option<Vec<Local>> {
        let body = self.body;
        let mut releases = Vec::new();
        let mut current = block;
        let mut statements = &body.blocks[block].statements[index + 1..];
        let mut seen = BTreeSet::from([block]);
        loop {
            for statement in statements {
                match &statement.kind {
                    StatementKind::Release(local) => releases.push(*local),
                    StatementKind::Assign(
                        place,
                        Rvalue::Use(Operand::Constant(Constant::Unit)),
                    ) if body.place_type(self.types, place) == Type::UNIT => {}
                    StatementKind::Assign(..) | StatementKind::Bind(..) => return None,
                }
            }
            match body.blocks[current].terminator.kind {
                TerminatorKind::Return => return Some(releases),
                TerminatorKind::Goto(next) if seen.insert(next) => {
                    current = next;
                    statements = &body.blocks[next].statements;
                }
                TerminatorKind::Goto(_)
                | TerminatorKind::Branch { .. }
                | TerminatorKind::Unreachable
                | TerminatorKind::TailCall { .. } => return None,
            }
        }
    }

    /// Whether the reference local `reference` points only behind the
    /// parameters passed by borrow, at places the caller owns.
    fn points_outside(&self, reference: Local, seen: &mut BTreeSet<Local>) -> bool {
        let body = self.body;
        if body.parameters.contains(&reference) || !seen.insert(reference) {
            return true;
        }
        self.definitions[reference].iter().all(|value| match value {
            Rvalue::Ref(_, place) => {
                body.locals[place.local].reference.is_some()
                    && self.points_outside(place.local, seen)
            }
            Rvalue::Call { arguments, .. } => arguments.iter().all(|argument| match argument {
                Operand::Borrowed(reference) => self.points_outside(*reference, seen),
                _ => true,
            }),
            _ => false,
        })
    }
}
