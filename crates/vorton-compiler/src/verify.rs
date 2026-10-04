//! A check that a body keeps the invariants of the IR that later passes
//! rely on.
//!
//! Lowering and instantiation must produce bodies that keep them, so a body
//! that breaks one is a compiler bug. It is reported the same way in every
//! build, so a release build never emits code for an IR that a debug build
//! would have rejected.

use crate::mir::{Body, Operand, Place, Rvalue, StatementKind, TerminatorKind, projection_type};
use crate::types::{Type, TypeKind, Types};

/// Panics if `body` breaks an invariant of the IR; `stage` names the pass
/// that produced it.
pub(crate) fn verify(body: &Body, types: &Types, name: &str, stage: &str) {
    if let Err(problem) = check(body, types).and_then(|()| released(body, types)) {
        panic!("internal error: the IR of `{name}` after {stage} is invalid: {problem}");
    }
}

fn check(body: &Body, types: &Types) -> Result<(), String> {
    let local = |local: usize| {
        if local < body.locals.len() {
            Ok(&body.locals[local])
        } else {
            Err(format!("local {local} does not exist"))
        }
    };
    for (block, data) in body.blocks.iter().enumerate() {
        for (index, statement) in data.statements.iter().enumerate() {
            let at = |problem: String| format!("block {block}, statement {index}: {problem}");
            match &statement.kind {
                StatementKind::Assign(destination, value) => {
                    place_type(body, types, destination).map_err(at)?;
                    if value.is_borrow() {
                        return Err(at("a borrow is stored instead of bound".to_owned()));
                    }
                    rvalue(body, types, value).map_err(at)?;
                }
                StatementKind::Bind(reference, value) => {
                    if local(*reference).map_err(at)?.reference.is_none() {
                        return Err(at("binds a local that is not a reference".to_owned()));
                    }
                    if !value.is_borrow() {
                        return Err(at("binds something other than a borrow".to_owned()));
                    }
                    rvalue(body, types, value).map_err(at)?;
                }
                StatementKind::Unpack(taken) => {
                    for (target, place) in taken {
                        let declaration = local(*target).map_err(at)?;
                        if declaration.reference.is_some() {
                            return Err(at("unpacks into a reference".to_owned()));
                        }
                        if place_type(body, types, place).map_err(at)? != declaration.ty {
                            return Err(at("unpacks a part of another type".to_owned()));
                        }
                    }
                }
                StatementKind::Release(released) => {
                    local(*released).map_err(at)?;
                }
                StatementKind::Distinct { pairs, .. } => {
                    for (left, right) in pairs {
                        for operand in [left, right] {
                            if types.is_entity(operand_type(body, types, operand).map_err(at)?) {
                                return Err(at("compares entities as indices".to_owned()));
                            }
                        }
                    }
                }
                StatementKind::Keep(reference) => {
                    if local(*reference).map_err(at)?.reference.is_none() {
                        return Err(at("keeps a local that is not a reference".to_owned()));
                    }
                }
            }
        }
        let at = |problem: String| format!("block {block}, terminator: {problem}");
        let target = |next: usize| {
            if next < body.blocks.len() {
                Ok(())
            } else {
                Err(at(format!("block {next} does not exist")))
            }
        };
        match &data.terminator.kind {
            TerminatorKind::Goto(next) => target(*next)?,
            TerminatorKind::Branch {
                condition,
                then,
                otherwise,
            } => {
                if operand_type(body, types, condition).map_err(at)? != Type::BOOL {
                    return Err(at("branches on a value that is not a `Bool`".to_owned()));
                }
                target(*then)?;
                target(*otherwise)?;
            }
            TerminatorKind::TailCall { arguments, .. } => {
                for argument in arguments {
                    operand(body, types, argument, true).map_err(at)?;
                }
            }
            TerminatorKind::Return | TerminatorKind::Unreachable => {}
        }
    }
    Ok(())
}

/// Checks that every path to a return releases each local that holds
/// something to release, so no branch of lowering forgets a scope.
fn released(body: &Body, types: &Types) -> Result<(), String> {
    let starts = body.maybe_filled(types);
    for block in body.reverse_postorder() {
        if !matches!(body.blocks[block].terminator.kind, TerminatorKind::Return) {
            continue;
        }
        let mut filled = starts[block].clone();
        for statement in &body.blocks[block].statements {
            body.fill(types, &statement.kind, &mut filled);
        }
        filled.remove(&body.result);
        if !filled.is_empty() {
            return Err(format!(
                "block {block} returns without releasing locals {filled:?}"
            ));
        }
    }
    Ok(())
}

fn rvalue(body: &Body, types: &Types, value: &Rvalue) -> Result<(), String> {
    // Only `Glue` looks at an entity where it is; every other step that
    // reads an operand takes a value or moves an entity.
    let looks = matches!(value, Rvalue::Glue { .. });
    for operand_ in value.operands() {
        operand(body, types, operand_, !looks)?;
    }
    match value {
        Rvalue::Binary(_, left, _) => {
            let ty = operand_type(body, types, left)?;
            if matches!(
                types.kind(ty),
                TypeKind::Tuple(_)
                    | TypeKind::Nominal { .. }
                    | TypeKind::List(_)
                    | TypeKind::Map(..)
                    | TypeKind::Set(_)
                    | TypeKind::Param { .. }
            ) {
                return Err(format!(
                    "`{}` is compared by a plain operator instead of `Glue`",
                    types.name(ty)
                ));
            }
        }
        Rvalue::Ref(_, place) | Rvalue::Discriminant(place) | Rvalue::Len(place) => {
            place_type(body, types, place)?;
        }
        Rvalue::Builtin { receiver, .. } => {
            place_type(body, types, receiver)?;
        }
        Rvalue::Occupied { container, .. } => {
            place_type(body, types, container)?;
        }
        Rvalue::Use(_)
        | Rvalue::Unary(..)
        | Rvalue::Tuple(_)
        | Rvalue::Construct { .. }
        | Rvalue::List(_)
        | Rvalue::EmptyMap
        | Rvalue::Range { .. }
        | Rvalue::Interpolate(_)
        | Rvalue::Call { .. }
        | Rvalue::Glue { .. }
        | Rvalue::Intrinsic { .. }
        | Rvalue::Take { .. } => {}
    }
    Ok(())
}

/// Checks an operand; `stores` says whether the step keeps what it reads,
/// so an entity it inspects in place would be copied.
fn operand(body: &Body, types: &Types, operand: &Operand, stores: bool) -> Result<(), String> {
    match operand {
        Operand::Copy(place) => {
            let ty = place_type(body, types, place)?;
            if types.is_entity(ty) {
                return Err(format!("copies an entity of type `{}`", types.name(ty)));
            }
        }
        Operand::Inspect(place) => {
            place_type(body, types, place)?;
            if stores {
                return Err("keeps an entity it only inspects".to_owned());
            }
        }
        Operand::Move(place) => {
            place_type(body, types, place)?;
        }
        Operand::Borrowed(reference) => {
            if body
                .locals
                .get(*reference)
                .is_none_or(|local| local.reference.is_none())
            {
                return Err("passes on a local that is not a reference".to_owned());
            }
        }
        Operand::Constant(_) => {}
    }
    Ok(())
}

/// The type `operand` gives, once its place is known to fit.
fn operand_type(body: &Body, types: &Types, operand: &Operand) -> Result<Type, String> {
    if let Operand::Copy(place) | Operand::Inspect(place) | Operand::Move(place) = operand {
        place_type(body, types, place)?;
    }
    Ok(body.operand_type(types, operand))
}

/// The type at `place`, if each step of it fits the type it is taken in.
fn place_type(body: &Body, types: &Types, place: &Place) -> Result<Type, String> {
    let Some(local) = body.locals.get(place.local) else {
        return Err(format!("local {} does not exist", place.local));
    };
    place
        .projections
        .iter()
        .try_fold(local.ty, |ty, projection| {
            projection_type(types, ty, projection)
                .ok_or_else(|| format!("a step of a place does not fit `{}`", types.name(ty)))
        })
}
