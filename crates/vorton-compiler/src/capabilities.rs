//! What the capabilities of functions allow, checked on the instantiated
//! IR, where every call and every hand-written impl that an operation runs
//! is known.
//!
//! In 0.1 the only rule is the spec's Drop boundary: a hand-written `drop`
//! cannot use the console.

use crate::ast::Span;
use crate::checker::{CheckDiagnostic, CheckDiagnosticKind, at};
use crate::mir::{Body, Program, Rvalue, StatementKind};
use crate::project::OriginRef;
use crate::typed::{Callee, Intrinsic};
use crate::types::Types;

/// Rejects a hand-written `drop` that can reach `print`: in 0.1 a `Drop`
/// cannot use the console. It runs after instantiation, when every call,
/// and every hand-written comparison or `clone` that an operation runs, is
/// known.
pub(crate) fn check_drops(program: &Program, origins: &[OriginRef]) -> Result<(), CheckDiagnostic> {
    let types = &program.types;
    let bodies = program
        .functions
        .iter()
        .map(|instance| &instance.body)
        .collect::<Vec<_>>();
    // What each function does that can reach the console, in order: a
    // `print` (`None`), or a call of another function.
    let uses = bodies
        .iter()
        .map(|body| console_uses(body, types))
        .collect::<Vec<_>>();
    let mut console = uses
        .iter()
        .map(|uses| uses.iter().any(|(_, callee)| callee.is_none()))
        .collect::<Vec<_>>();
    let mut changed = true;
    while changed {
        changed = false;
        for (function, uses) in uses.iter().enumerate() {
            if !console[function]
                && uses
                    .iter()
                    .any(|(_, callee)| callee.is_some_and(|callee| console[callee]))
            {
                console[function] = true;
                changed = true;
            }
        }
    }
    let mut drops = types
        .written
        .iter()
        .filter_map(|(ty, written)| written.drop.map(|drop| (drop, *ty)))
        .collect::<Vec<_>>();
    drops.sort_unstable();
    for (drop, ty) in drops {
        let Some(&(span, callee)) = uses[drop]
            .iter()
            .find(|(_, callee)| callee.is_none_or(|callee| console[callee]))
        else {
            continue;
        };
        let what = if callee.is_none() {
            "prints"
        } else {
            "can print"
        };
        return Err(CheckDiagnostic {
            kind: CheckDiagnosticKind::ConsoleInDrop,
            primary: Some(at(&origins[program.functions[drop].template], span)),
            message: format!(
                "this {what}, but the `drop` of `{}` cannot use the console in 0.1",
                types.name(ty)
            ),
        });
    }
    Ok(())
}

/// The steps of `body` that print, and the functions it calls, with their
/// spans: named calls, and the hand-written impls that a `Glue` operation
/// runs. Every IR step is listed, so a new kind of step must say what it
/// calls.
fn console_uses(body: &Body, types: &Types) -> Vec<(Span, Option<usize>)> {
    let mut uses = Vec::new();
    for block in &body.blocks {
        for statement in &block.statements {
            let span = statement.span;
            let value = match &statement.kind {
                StatementKind::Assign(_, value) | StatementKind::Bind(_, value) => value,
                // A release may run a `drop`, which is checked on its own.
                StatementKind::Release(_) => continue,
                StatementKind::Unpack(_) => continue,
            };
            match value {
                Rvalue::Intrinsic {
                    intrinsic: Intrinsic::Print,
                    ..
                } => uses.push((span, None)),
                Rvalue::Call {
                    callee: Callee::Function(callee),
                    ..
                } => uses.push((span, Some(*callee))),
                Rvalue::Call {
                    callee: Callee::Trait { .. },
                    ..
                } => unreachable!("instantiation resolves trait methods"),
                Rvalue::Glue { operation, ty, .. } => {
                    for callee in types.glue_functions(*ty, *operation) {
                        uses.push((span, Some(callee)));
                    }
                }
                // These run no code the program wrote, other than the `drop`
                // of what they release.
                Rvalue::Intrinsic { .. }
                | Rvalue::Builtin { .. }
                | Rvalue::Use(_)
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
                | Rvalue::Take { .. } => {}
            }
        }
    }
    uses
}
