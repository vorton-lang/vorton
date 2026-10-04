//! C code for the body of one function, from its IR.
//!
//! Every basic block becomes a labelled run of C statements that ends in a
//! jump, a return, or a call that does not return, so the C code takes the
//! IR's edges and runs its steps in the IR's order. Every local of the IR
//! is a C variable declared at the top of the function; a reference local
//! is a pointer.
//!
//! A local that is not a reference owns what it holds: nothing, which is a
//! zeroed value that releasing ignores, or a value of its own. Copying a
//! counted value retains it, moving a value zeroes its place, and `Release`
//! releases a local and zeroes it, so a local in a loop starts every
//! iteration empty. An argument that is not borrowed is passed as an owned
//! value, which the callee releases like its other locals.
//!
//! A `TailCall` terminator, which [`crate::tail`] puts where the function
//! calls itself in tail position, jumps back to the start: the arguments
//! become the new parameters once the locals are released, so the stack
//! does not grow.

use std::fmt::Write as _;

use super::{
    GENERIC, Literals, c_type, clone_code, compare_code, count_line, equal_code, field_code,
    function_name, int_literal, item_type, local_name, map_key, map_value, option_variants,
    prototype, zero, zero_value,
};
use crate::ast::{BinaryOperator, UnaryOperator};
use crate::mir::{
    BlockId, Body, Constant, Local, Operand, Place, Program, Projection, RANGE_FIELDS, Rvalue,
    StatementKind, TerminatorKind,
};
use crate::typed::{Builtin, Callee, Intrinsic, StrMethod};
use crate::types::{Operation, Type, TypeKind, Types};

/// The C definition of the function at `index`.
pub(super) fn function(program: &Program, index: usize, literals: &mut Literals) -> String {
    let types = &program.types;
    let function = &program.functions[index];
    let body = &function.body;
    let mut emitter = Emitter {
        program,
        types,
        body,
        literals,
        declarations: String::new(),
        code: String::new(),
        temporaries: 0,
    };
    for (local, declaration) in body.locals.iter().enumerate() {
        if body.parameters.contains(&local) || !types.has_storage(declaration.ty) {
            continue;
        }
        let name = emitter.variable(local);
        let (ty, initial) = if declaration.reference.is_some() {
            (format!("{} *", c_type(types, declaration.ty)), "NULL")
        } else {
            (c_type(types, declaration.ty), zero(types, declaration.ty))
        };
        writeln!(emitter.declarations, "    {ty} {name} = {initial};").unwrap();
    }
    let order = body.reverse_postorder();
    for (position, &block) in order.iter().enumerate() {
        emitter.block(block, order.get(position + 1).copied());
    }
    format!(
        "{} {{\n{}{}}}\n\n",
        prototype(types, index, function),
        emitter.declarations,
        emitter.code
    )
}

struct Emitter<'a> {
    program: &'a Program,
    types: &'a Types,
    body: &'a Body,
    literals: &'a mut Literals,
    /// The C variables, declared at the top of the function.
    declarations: String,
    code: String,
    temporaries: usize,
}

impl<'a> Emitter<'a> {
    fn line(&mut self, text: &str) {
        self.code.push_str("    ");
        self.code.push_str(text);
        self.code.push('\n');
    }

    /// The C variable of a local.
    fn variable(&self, local: Local) -> String {
        let name = &self.body.locals[local].name;
        if name.is_empty() {
            format!("t{local}")
        } else {
            local_name(local, name)
        }
    }

    fn fresh(&mut self) -> String {
        let name = format!("c{}", self.temporaries);
        self.temporaries += 1;
        name
    }

    /// A new C variable of type `ty`, which has storage.
    fn temporary(&mut self, ty: Type) -> String {
        let name = self.fresh();
        writeln!(
            self.declarations,
            "    {} {name} = {};",
            c_type(self.types, ty),
            zero(self.types, ty)
        )
        .unwrap();
        name
    }

    /// A new C variable that points at a `ty`.
    fn pointer_temporary(&mut self, ty: Type) -> String {
        let name = self.fresh();
        writeln!(
            self.declarations,
            "    {} *{name} = NULL;",
            c_type(self.types, ty)
        )
        .unwrap();
        name
    }

    /// A new C variable of the storage of map keys or values of type `ty`,
    /// whose address the map functions take.
    fn entry_temporary(&mut self, ty: Type) -> String {
        let name = self.fresh();
        let initial = if self.types.has_storage(ty) {
            zero(self.types, ty)
        } else {
            "0"
        };
        writeln!(
            self.declarations,
            "    {} {name} = {initial};",
            item_type(self.types, ty)
        )
        .unwrap();
        name
    }

    // Blocks.

    /// Emits `block`; `next` is the block emitted after it, which the block
    /// can fall through to.
    fn block(&mut self, block: BlockId, next: Option<BlockId>) {
        let body = self.body;
        writeln!(self.code, "bb{block}:;").unwrap();
        let data = &body.blocks[block];
        for statement in &data.statements {
            match &statement.kind {
                StatementKind::Assign(destination, value) => self.assign(destination, value),
                StatementKind::Bind(reference, value) => self.bind(*reference, value),
                StatementKind::Unpack(taken) => {
                    for (local, place) in taken {
                        if let Some(value) = self.owned(&Operand::Move(place.clone())) {
                            let name = self.variable(*local);
                            self.line(&format!("{name} = {value};"));
                        }
                    }
                }
                StatementKind::Release(local) => self.release(*local),
                StatementKind::Distinct { pairs, message } => self.distinct(pairs, message),
                StatementKind::Keep(_) => {}
            }
        }
        match &data.terminator.kind {
            TerminatorKind::Goto(target) => {
                if next != Some(*target) {
                    self.line(&format!("goto bb{target};"));
                }
            }
            TerminatorKind::Branch {
                condition,
                then,
                otherwise,
            } => {
                let condition = self.read(condition).expect("a condition is a `Bool`");
                if next == Some(*then) {
                    self.line(&format!("if (!{condition}) goto bb{otherwise};"));
                } else {
                    self.line(&format!("if ({condition}) goto bb{then};"));
                    if next != Some(*otherwise) {
                        self.line(&format!("goto bb{otherwise};"));
                    }
                }
            }
            TerminatorKind::Return => {
                if self.types.has_storage(body.locals[body.result].ty) {
                    let result = self.variable(body.result);
                    self.line(&format!("return {result};"));
                } else {
                    self.line("return;");
                }
            }
            TerminatorKind::Unreachable => self.line("vt_unreachable();"),
            TerminatorKind::TailCall {
                arguments,
                releases,
            } => self.jump_to_start(arguments, releases),
        }
    }

    /// Panics with `message` if every pair of operands is equal.
    fn distinct(&mut self, pairs: &[(Operand, Operand)], message: &str) {
        let mut tests = Vec::new();
        for (left, right) in pairs {
            let ty = self.operand_type(left);
            let (left, right) = (self.read(left), self.read(right));
            let pair = left.as_deref().zip(right.as_deref());
            tests.push(comparison(self.types, BinaryOperator::Equal, ty, pair));
        }
        let message = self.literals.add(message);
        self.line(&format!(
            "if ({}) {{ vt_panic_str({message}); }}",
            tests.join(" && ")
        ));
    }

    // Tail calls of the function itself.

    /// Makes `arguments` the new parameters after releasing `releases`, and
    /// jumps to the start of the function.
    fn jump_to_start(&mut self, arguments: &[Operand], releases: &[Local]) {
        let body = self.body;
        let mut values = Vec::new();
        for (argument, &parameter) in arguments.iter().zip(&body.parameters) {
            if let Some(value) = self.owned(argument) {
                let ty = body.locals[parameter].ty;
                let temporary = if body.locals[parameter].reference.is_some() {
                    self.pointer_temporary(ty)
                } else {
                    self.temporary(ty)
                };
                self.line(&format!("{temporary} = {value};"));
                values.push((self.variable(parameter), temporary));
            }
        }
        for &local in releases {
            self.release(local);
        }
        for (parameter, value) in values {
            self.line(&format!("{parameter} = {value};"));
        }
        self.line("goto bb0;");
    }

    // Statements.

    fn release(&mut self, local: Local) {
        let declaration = &self.body.locals[local];
        let ty = declaration.ty;
        if declaration.reference.is_none() && self.types.needs_release(ty) {
            let name = self.variable(local);
            self.line(&count_line(ty, "release", &name));
            self.line(&format!("{name} = {};", zero_value(self.types, ty)));
        }
    }

    /// Makes the reference local `reference` point at the place `value`
    /// names.
    fn bind(&mut self, reference: Local, value: &'a Rvalue) {
        let ty = self.body.locals[reference].ty;
        let pointer = match value {
            Rvalue::Ref(_, place) => self.place(place).map(|code| format!("&{code}")),
            Rvalue::Call {
                callee, arguments, ..
            } => {
                let call = self.call(*callee, arguments);
                if self.types.has_storage(ty) {
                    Some(call)
                } else {
                    self.line(&format!("{call};"));
                    None
                }
            }
            _ => unreachable!("only borrows and calls make references point"),
        };
        if let Some(pointer) = pointer {
            let name = self.variable(reference);
            self.line(&format!("{name} = {pointer};"));
        }
    }

    /// Evaluates `value`, then checks that the destination exists, releases
    /// what it held, and stores the value.
    fn assign(&mut self, destination: &Place, value: &'a Rvalue) {
        let body = self.body;
        let ty = body.place_type(self.types, destination);
        if let Some((key, map)) = body.map_entry(self.types, destination) {
            self.insert(&map, key, value, ty);
            return;
        }
        let value = self.rvalue(value, ty);
        let owning = self.types.needs_release(ty);
        let checked = destination.projections.iter().any(|projection| {
            matches!(
                projection,
                Projection::Index(_) | Projection::ConstantIndex(_)
            )
        });
        // A value that the release or the checks could change is kept first.
        let value = match value {
            Some(value) if owning || checked => {
                let temporary = self.temporary(ty);
                self.line(&format!("{temporary} = {value};"));
                Some(temporary)
            }
            value => value,
        };
        let target = self.place(destination);
        if let (Some(target), Some(value)) = (target, value) {
            if owning {
                self.line(&count_line(ty, "release", &target));
            }
            self.line(&format!("{target} = {value};"));
        }
    }

    /// Stores `value` as the value of the key `key` in the map at `map`,
    /// which takes a copy of the key if it is absent; a present key keeps
    /// its stored copy and its old value is released.
    fn insert(&mut self, map: &Place, key: Projection, value: &'a Rvalue, ty: Type) {
        let types = self.types;
        let map_ty = self.body.place_type(types, map);
        let TypeKind::Map(key_ty, _) = *types.kind(map_ty) else {
            unreachable!("the place is a map")
        };
        let value = self.rvalue(value, ty);
        let new_value = self.entry_temporary(ty);
        if let Some(value) = value {
            self.line(&format!("{new_value} = {value};"));
        }
        let map = self.place(map).expect("a map has storage");
        let new_key = self.entry_temporary(key_ty);
        let key = match key {
            // A key without storage is the one value of its type.
            _ if !types.has_storage(key_ty) => "0".to_owned(),
            Projection::Index(local) => clone_code(types, key_ty, &self.variable(local)),
            Projection::ConstantIndex(value) => int_literal(value),
            _ => unreachable!("a key is an index"),
        };
        self.line(&format!("{new_key} = {key};"));
        let old = self.entry_temporary(ty);
        let release = [(&new_key, key_ty), (&old, ty)]
            .into_iter()
            .filter(|(_, ty)| types.needs_release(*ty))
            .map(|(code, ty)| count_line(ty, "release", code))
            .collect::<Vec<_>>()
            .join(" ");
        self.line(&format!(
            "if (vt_map_insert(&{map}.m, vt_maptype_T{}(), &{new_key}, &{new_value}, &{old})) {{ {release} }}",
            map_ty.index()
        ));
    }

    // Places and operands.

    /// The C lvalue of `place`, after the checks that its elements exist;
    /// `None` if its type has no storage.
    fn place(&mut self, place: &Place) -> Option<String> {
        let types = self.types;
        let declaration = &self.body.locals[place.local];
        let mut ty = declaration.ty;
        if !types.has_storage(ty) {
            return None;
        }
        let name = self.variable(place.local);
        let mut code = if declaration.reference.is_some() {
            format!("(*{name})")
        } else {
            name
        };
        for projection in &place.projections {
            (ty, code) = match *projection {
                Projection::Field(index) => match types.kind(ty) {
                    TypeKind::Range => (
                        RANGE_FIELDS[index],
                        format!("{code}.{}", ["start", "end", "inclusive"][index]),
                    ),
                    _ => (
                        types.components(ty)[index],
                        field_code(types, ty, 0, index, &code),
                    ),
                },
                Projection::VariantField { variant, field } => (
                    types.variants(ty)[variant].fields[field].ty,
                    field_code(types, ty, variant, field, &code),
                ),
                Projection::Index(local) => {
                    let index = self.variable(local);
                    // A key without storage is the one value of its type.
                    let key = match types.kind(ty) {
                        TypeKind::Map(key, _) if !types.has_storage(*key) => {
                            "&(char){0}".to_owned()
                        }
                        _ => format!("&{index}"),
                    };
                    self.element(&code, ty, &index, &key)
                }
                Projection::ConstantIndex(value) => {
                    let index = int_literal(value);
                    let key = format!("&(int64_t){{{index}}}");
                    self.element(&code, ty, &index, &key)
                }
                Projection::Position(local) => {
                    let position = self.variable(local);
                    let container = format!("&{code}");
                    match types.kind(ty) {
                        TypeKind::List(element) => (*element, format!("{code}.items[{position}]")),
                        TypeKind::Map(_, value) => {
                            (*value, map_value(types, *value, &container, &position))
                        }
                        TypeKind::Set(element) => {
                            (*element, map_key(types, *element, &container, &position))
                        }
                        _ => unreachable!("only containers have positions"),
                    }
                }
            };
        }
        types.has_storage(ty).then_some(code)
    }

    /// The element at `index` of the list `code` of type `ty`, or the value
    /// of the key that `key` points at in the map, after checking that it
    /// exists.
    fn element(&mut self, code: &str, ty: Type, index: &str, key: &str) -> (Type, String) {
        let types = self.types;
        match types.kind(ty) {
            TypeKind::List(element) => {
                self.line(&format!("vt_check_index({index}, {code}.len);"));
                (*element, format!("{code}.items[{index}]"))
            }
            TypeKind::Map(_, value) => {
                let value = *value;
                let at = format!("vt_map_at(&{code}.m, vt_maptype_T{}(), {key})", ty.index());
                if !types.has_storage(value) {
                    self.line(&format!("(void){at};"));
                    return (value, String::new());
                }
                let item = item_type(types, value);
                let pointer = self.fresh();
                writeln!(self.declarations, "    {item} *{pointer} = NULL;").unwrap();
                self.line(&format!("{pointer} = ({item} *){at};"));
                (value, format!("(*{pointer})"))
            }
            _ => unreachable!("only lists and maps are indexed"),
        }
    }

    fn operand_type(&self, operand: &Operand) -> Type {
        self.body.operand_type(self.types, operand)
    }

    /// `operand` as an owned value: a copy of a counted value is retained,
    /// and a moved value is taken and its place zeroed. `None` if its type
    /// has no storage.
    fn owned(&mut self, operand: &Operand) -> Option<String> {
        match operand {
            Operand::Constant(constant) => self.constant(constant),
            Operand::Borrowed(reference) => self.pointer(*reference),
            Operand::Inspect(_) => unreachable!("a step that stores a value is given a copy"),
            Operand::Copy(place) => {
                let ty = self.body.place_type(self.types, place);
                let code = self.place(place)?;
                Some(if self.types.needs_release(ty) {
                    assert!(
                        !self.types.is_entity(ty),
                        "entities are moved, never copied"
                    );
                    debug_assert!(
                        self.types.glue_functions(ty, Operation::Clone).is_empty(),
                        "copying a value runs no code the program wrote"
                    );
                    clone_code(self.types, ty, &code)
                } else {
                    code
                })
            }
            Operand::Move(place) => {
                let ty = self.body.place_type(self.types, place);
                let code = self.place(place)?;
                if !self.types.needs_release(ty) {
                    return Some(code);
                }
                let value = self.temporary(ty);
                self.line(&format!("{value} = {code};"));
                self.line(&format!("{code} = {};", zero_value(self.types, ty)));
                Some(value)
            }
        }
    }

    /// `operand` read where it is, for a step that only looks at it. A
    /// temporary that the step takes is released with its scope.
    fn read(&mut self, operand: &Operand) -> Option<String> {
        match operand {
            Operand::Constant(constant) => self.constant(constant),
            Operand::Copy(place) | Operand::Inspect(place) | Operand::Move(place) => {
                self.place(place)
            }
            Operand::Borrowed(reference) => self.pointer(*reference),
        }
    }

    fn constant(&mut self, constant: &Constant) -> Option<String> {
        Some(match constant {
            Constant::Int(value) => int_literal(*value),
            Constant::Float(value) => format!("{value:e}"),
            Constant::Bool(value) => value.to_string(),
            Constant::Str(value) => self.literals.add(value),
            Constant::Unit => return None,
        })
    }

    /// The pointer a reference local holds, if what it points at has
    /// storage.
    fn pointer(&self, reference: Local) -> Option<String> {
        self.types
            .has_storage(self.body.locals[reference].ty)
            .then(|| self.variable(reference))
    }

    /// The place a borrowed argument points at.
    fn borrowed_place(&self, operand: &Operand) -> Option<String> {
        let Operand::Borrowed(reference) = operand else {
            unreachable!("the argument is borrowed")
        };
        self.pointer(*reference)
            .map(|pointer| format!("(*{pointer})"))
    }

    // Values.

    /// The statements that compute `value`, of type `ty`, and a C expression
    /// for it, owned by whoever stores it; `None` if `ty` has no storage.
    fn rvalue(&mut self, value: &'a Rvalue, ty: Type) -> Option<String> {
        let types = self.types;
        match value {
            Rvalue::Use(operand) => self.owned(operand),
            Rvalue::Ref(..) => unreachable!("borrows are stored in reference locals"),
            Rvalue::Unary(operator, operand) => {
                let operand = self.read(operand)?;
                Some(match (operator, ty) {
                    (UnaryOperator::Negate, Type::INT) => format!("vt_int_neg({operand})"),
                    (UnaryOperator::Negate, _) => format!("(-{operand})"),
                    (UnaryOperator::Not, _) => format!("(!{operand})"),
                })
            }
            Rvalue::Binary(operator, left, right) => Some(self.binary(*operator, left, right)),
            Rvalue::Tuple(operands) => self.aggregate(ty, 0, operands.iter().enumerate()),
            Rvalue::Construct { variant, fields } => self.aggregate(
                ty,
                *variant,
                fields.iter().map(|(index, operand)| (*index, operand)),
            ),
            Rvalue::List(operands) => {
                let values = operands
                    .iter()
                    .map(|operand| self.owned(operand))
                    .collect::<Vec<_>>();
                let list = self.temporary(ty);
                self.line(&format!("{list} = {};", zero_value(types, ty)));
                for value in values {
                    let value = value.map_or_else(String::new, |value| format!(", {value}"));
                    self.line(&format!("vt_push_T{}(&{list}{value});", ty.index()));
                }
                Some(list)
            }
            Rvalue::EmptyMap => Some(zero_value(types, ty)),
            Rvalue::Range {
                start,
                end,
                inclusive,
            } => {
                let start = self.read(start)?;
                let end = self.read(end)?;
                Some(format!("(vt_range){{{start}, {end}, {inclusive}}}"))
            }
            Rvalue::Interpolate(parts) => Some(self.interpolate(parts)),
            Rvalue::Discriminant(place) => {
                self.place(place).map(|code| format!("(int64_t){code}.tag"))
            }
            Rvalue::Len(place) => {
                let container = self.body.place_type(types, place);
                let code = self.place(place)?;
                Some(match types.kind(container) {
                    TypeKind::List(_) => format!("{code}.len"),
                    _ => format!("{code}.m.used"),
                })
            }
            Rvalue::Occupied {
                container,
                position,
            } => {
                let code = self.place(container)?;
                Some(format!("{code}.m.live[{}]", self.variable(*position)))
            }
            Rvalue::Call {
                callee,
                arguments,
                borrow,
                ..
            } => {
                let call = self.call(*callee, arguments);
                if !types.has_storage(ty) {
                    self.line(&format!("{call};"));
                    return None;
                }
                assert!(
                    borrow.is_none(),
                    "a call that returns a borrow is only in a `Bind`"
                );
                Some(call)
            }
            Rvalue::Builtin {
                builtin,
                receiver,
                arguments,
            } => self.builtin(*builtin, receiver, arguments, ty),
            Rvalue::Glue {
                operation,
                operator,
                ty: operand_ty,
                operands,
            } => self.glue(*operation, *operator, *operand_ty, operands),
            Rvalue::Intrinsic {
                intrinsic,
                arguments,
            } => self.intrinsic(*intrinsic, arguments, ty),
            Rvalue::Take {
                container,
                position,
            } => self.take(*container, *position, ty),
        }
    }

    /// An operation that the helpers of `ty` carry out, which follow
    /// [`Types::glue`].
    fn glue(
        &mut self,
        operation: Operation,
        operator: Option<BinaryOperator>,
        ty: Type,
        operands: &[Operand],
    ) -> Option<String> {
        let types = self.types;
        let values = operands
            .iter()
            .map(|operand| self.read(operand))
            .collect::<Vec<_>>();
        match operation {
            Operation::Equal | Operation::Order => {
                let operator = operator.expect("a comparison operator");
                let pair = values[0].as_deref().zip(values[1].as_deref());
                Some(comparison(types, operator, ty, pair))
            }
            Operation::Clone => values[0].as_ref().map(|code| clone_code(types, ty, code)),
            Operation::Contains => {
                let list = values[0].as_ref().expect("a list has storage");
                // Every element of a `List<Unit>` equals the argument.
                Some(match &values[1] {
                    None => format!("({list}.len > 0)"),
                    Some(value) => format!("vt_contains_T{}({list}, {value})", ty.index()),
                })
            }
        }
    }

    /// An operation on values that the compiler carries out directly:
    /// comparisons of values without parts, and arithmetic.
    fn binary(&mut self, operator: BinaryOperator, left: &Operand, right: &Operand) -> String {
        use BinaryOperator as Op;
        let operand_ty = self.operand_type(left);
        debug_assert!(
            !matches!(
                self.types.kind(operand_ty),
                TypeKind::Tuple(_) | TypeKind::Nominal { .. } | TypeKind::List(_)
            ),
            "values with parts are compared by `Glue`"
        );
        let (left, right) = (self.read(left), self.read(right));
        if matches!(
            operator,
            Op::Equal | Op::NotEqual | Op::Less | Op::Greater | Op::LessEqual | Op::GreaterEqual
        ) {
            let pair = left.as_deref().zip(right.as_deref());
            return comparison(self.types, operator, operand_ty, pair);
        }
        let (Some(a), Some(b)) = (left, right) else {
            unreachable!("arithmetic and logic have operands with storage")
        };
        match (operator, operand_ty) {
            (Op::Add, Type::INT) => format!("vt_int_add({a}, {b})"),
            (Op::Subtract, Type::INT) => format!("vt_int_sub({a}, {b})"),
            (Op::Multiply, Type::INT) => format!("vt_int_mul({a}, {b})"),
            (Op::Divide, Type::INT) => format!("vt_int_div({a}, {b})"),
            (Op::Remainder, Type::INT) => format!("vt_int_rem({a}, {b})"),
            (Op::Add, _) => format!("({a} + {b})"),
            (Op::Subtract, _) => format!("({a} - {b})"),
            (Op::Multiply, _) => format!("({a} * {b})"),
            (Op::Divide, _) => format!("({a} / {b})"),
            (Op::Remainder, _) => format!("fmod({a}, {b})"),
            (Op::LogicAnd, _) => format!("({a} && {b})"),
            (Op::LogicOr, _) => format!("({a} || {b})"),
            (
                Op::Equal
                | Op::NotEqual
                | Op::Less
                | Op::Greater
                | Op::LessEqual
                | Op::GreaterEqual,
                _,
            ) => unreachable!("comparisons are handled above"),
            (Op::RangeExclusive | Op::RangeInclusive, _) => {
                unreachable!("ranges are built by `Range`")
            }
        }
    }

    /// A tuple, struct or enum value of type `ty` with the given fields,
    /// by declaration index.
    fn aggregate(
        &mut self,
        ty: Type,
        variant: usize,
        fields: impl Iterator<Item = (usize, &'a Operand)>,
    ) -> Option<String> {
        let values = fields
            .map(|(index, operand)| (index, self.owned(operand)))
            .collect::<Vec<_>>();
        if !self.types.has_storage(ty) {
            return None;
        }
        let result = self.temporary(ty);
        if self.types.is_enum(ty) {
            self.line(&format!("{result}.tag = {variant};"));
        }
        // A value with a hand-written `Drop` is live until it is moved away.
        if self.types.has_drop(ty) {
            self.line(&format!("{result}.vt_live = true;"));
        }
        for (index, value) in values {
            if let Some(value) = value {
                let field = field_code(self.types, ty, variant, index, &result);
                self.line(&format!("{field} = {value};"));
            }
        }
        Some(result)
    }

    fn interpolate(&mut self, parts: &[Operand]) -> String {
        let mut texts = Vec::new();
        for part in parts {
            let ty = self.operand_type(part);
            let value = self.read(part).expect("interpolated values have storage");
            texts.push(self.stringify(&value, ty));
        }
        let list = texts
            .iter()
            .map(|(text, _)| text.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        let result = self.temporary(Type::STR);
        self.line(&format!(
            "{result} = vt_str_join({}, (vt_str *[]){{{list}}});",
            texts.len().max(1)
        ));
        for (text, owned) in &texts {
            if *owned {
                self.line(&format!("vt_str_release({text});"));
            }
        }
        result
    }

    /// A `Str` for the printable `value` of type `ty`, and whether it is a
    /// new string to release.
    fn stringify(&mut self, value: &str, ty: Type) -> (String, bool) {
        let convert = match ty {
            Type::STR => return (value.to_owned(), false),
            Type::BOOL => return (format!("vt_bool_to_str({value})"), false),
            Type::INT => "vt_int_to_str",
            Type::FLOAT => "vt_float_to_str",
            _ => unreachable!("the checker admits only printable values"),
        };
        let text = self.temporary(Type::STR);
        self.line(&format!("{text} = {convert}({value});"));
        (text, true)
    }

    fn call(&mut self, callee: Callee, arguments: &[Operand]) -> String {
        let Callee::Function(function) = callee else {
            unreachable!("{GENERIC}")
        };
        let mut values = Vec::new();
        for argument in arguments {
            values.extend(self.owned(argument));
        }
        format!(
            "{}({})",
            function_name(function, &self.program.functions[function]),
            values.join(", ")
        )
    }

    /// Takes the element at `position` out of a list or set that a loop
    /// took, zeroing its slot, or a map's entry as a `(key, value)` tuple.
    fn take(&mut self, container: Local, position: Local, ty: Type) -> Option<String> {
        let types = self.types;
        let code = self.variable(container);
        let position = self.variable(position);
        let source = format!("&{code}");
        match types.kind(self.body.locals[container].ty) {
            TypeKind::List(element) => {
                self.take_slot(format!("{code}.items[{position}]"), *element)
            }
            TypeKind::Set(element) => {
                self.take_slot(map_key(types, *element, &source, &position), *element)
            }
            TypeKind::Map(key, value) => {
                let entry = self.temporary(ty);
                let parts = [
                    (*key, map_key(types, *key, &source, &position)),
                    (*value, map_value(types, *value, &source, &position)),
                ];
                for (index, (part_ty, part)) in parts.into_iter().enumerate() {
                    if types.has_storage(part_ty) {
                        let field = field_code(types, ty, 0, index, &entry);
                        self.line(&format!("{field} = {part};"));
                        if types.needs_release(part_ty) {
                            self.line(&format!("{part} = {};", zero_value(types, part_ty)));
                        }
                    }
                }
                Some(entry)
            }
            _ => unreachable!("loops take lists, maps and sets"),
        }
    }

    fn take_slot(&mut self, slot: String, ty: Type) -> Option<String> {
        if !self.types.has_storage(ty) {
            return None;
        }
        let value = self.temporary(ty);
        self.line(&format!("{value} = {slot};"));
        if self.types.needs_release(ty) {
            self.line(&format!("{slot} = {};", zero_value(self.types, ty)));
        }
        Some(value)
    }

    fn intrinsic(
        &mut self,
        intrinsic: Intrinsic,
        arguments: &[Operand],
        ty: Type,
    ) -> Option<String> {
        match intrinsic {
            Intrinsic::Print => {
                let value_ty = self.operand_type(&arguments[0]);
                let value = self
                    .read(&arguments[0])
                    .expect("printable values have storage");
                let (text, owned) = self.stringify(&value, value_ty);
                self.line(&format!("vt_print({text});"));
                if owned {
                    self.line(&format!("vt_str_release({text});"));
                }
                None
            }
            Intrinsic::Assert => {
                let condition = self.read(&arguments[0]).expect("a condition is a `Bool`");
                let message = self.read(&arguments[1]).expect("a message is a `Str`");
                self.line(&format!("if (!{condition}) vt_panic_assert({message});"));
                None
            }
            Intrinsic::Panic => {
                let message = self.read(&arguments[0]).expect("a message is a `Str`");
                self.line(&format!("vt_panic_str({message});"));
                None
            }
            // The old value moves out to the caller.
            Intrinsic::Replace => {
                let target = self.borrowed_place(&arguments[0]);
                let value = self.owned(&arguments[1]);
                let (Some(target), Some(value)) = (target, value) else {
                    return None;
                };
                let old = self.temporary(ty);
                self.line(&format!("{old} = {target};"));
                self.line(&format!("{target} = {value};"));
                Some(old)
            }
            Intrinsic::Swap => {
                let first = self.borrowed_place(&arguments[0]);
                let second = self.borrowed_place(&arguments[1]);
                if let (Some(first), Some(second)) = (first, second) {
                    let temporary = self.temporary(self.operand_type(&arguments[0]));
                    self.line(&format!(
                        "{temporary} = {first}; {first} = {second}; {second} = {temporary};"
                    ));
                }
                None
            }
        }
    }

    // Built-in methods.

    fn builtin(
        &mut self,
        builtin: Builtin,
        receiver: &Place,
        arguments: &[Operand],
        ty: Type,
    ) -> Option<String> {
        let types = self.types;
        let receiver_ty = self.body.place_type(types, receiver);
        let code = self
            .place(receiver)
            .expect("containers and strings have storage");
        match (types.kind(receiver_ty), builtin) {
            (TypeKind::Str, Builtin::Str(method)) => {
                Some(self.str_builtin(method, &code, arguments, ty))
            }
            (TypeKind::List(element), _) => {
                self.list_builtin(builtin, &code, receiver_ty, *element, arguments, ty)
            }
            (TypeKind::Map(key, value), _) => {
                self.map_builtin(builtin, &code, receiver_ty, (*key, *value), arguments, ty)
            }
            (TypeKind::Set(element), _) => {
                self.set_builtin(builtin, &code, receiver_ty, *element, arguments)
            }
            _ => unreachable!("built-in methods belong to containers and strings"),
        }
    }

    fn list_builtin(
        &mut self,
        builtin: Builtin,
        code: &str,
        list: Type,
        element: Type,
        arguments: &[Operand],
        ty: Type,
    ) -> Option<String> {
        let types = self.types;
        let n = list.index();
        let with =
            |value: Option<String>| value.map_or_else(String::new, |value| format!(", {value}"));
        match builtin {
            Builtin::Push => {
                let value = with(self.owned(&arguments[0]));
                self.line(&format!("vt_push_T{n}(&{code}{value});"));
                None
            }
            Builtin::Insert => {
                let index = self.read(&arguments[0]).expect("an index is an `Int`");
                let value = with(self.owned(&arguments[1]));
                self.line(&format!("vt_insert_T{n}(&{code}, {index}{value});"));
                None
            }
            Builtin::Clear => {
                self.line(&format!("vt_clear_T{n}(&{code});"));
                None
            }
            Builtin::Len => Some(format!("{code}.len")),
            Builtin::IsEmpty => Some(format!("({code}.len == 0)")),
            Builtin::Remove => {
                let index = self.read(&arguments[0]).expect("an index is an `Int`");
                if types.has_storage(element) {
                    Some(format!("vt_remove_T{n}(&{code}, {index})"))
                } else {
                    self.line(&format!(
                        "vt_check_index({index}, {code}.len); {code}.len -= 1;"
                    ));
                    None
                }
            }
            Builtin::Pop => {
                let (some, none) = option_variants(types, ty);
                let result = self.temporary(ty);
                self.line(&format!("if ({code}.len == 0) {{"));
                self.line(&format!("    {result}.tag = {none};"));
                self.line("} else {");
                self.line(&format!("    {code}.len -= 1;"));
                self.line(&format!("    {result}.tag = {some};"));
                if types.has_storage(element) {
                    self.line(&format!(
                        "    {} = {code}.items[{code}.len];",
                        field_code(types, ty, some, 0, &result)
                    ));
                }
                self.line("}");
                Some(result)
            }
            Builtin::Get => {
                let index = self.read(&arguments[0]).expect("an index is an `Int`");
                let field = clone_code(types, element, &format!("{code}.items[{index}]"));
                let test = format!("{index} >= 0 && {index} < {code}.len");
                Some(self.option(ty, element, &test, &[], &field))
            }
            _ => unreachable!("not a list method"),
        }
    }

    fn map_builtin(
        &mut self,
        builtin: Builtin,
        code: &str,
        map: Type,
        (key, value): (Type, Type),
        arguments: &[Operand],
        ty: Type,
    ) -> Option<String> {
        let types = self.types;
        let n = map.index();
        let map_type = format!("vt_maptype_T{n}()");
        let release = |ty: Type, code: &str| {
            if types.needs_release(ty) {
                vec![count_line(ty, "release", code)]
            } else {
                Vec::new()
            }
        };
        match builtin {
            Builtin::Len => Some(format!("{code}.m.len")),
            Builtin::IsEmpty => Some(format!("({code}.m.len == 0)")),
            Builtin::Clear => {
                self.line(&format!("vt_clear_T{n}(&{code});"));
                None
            }
            Builtin::ContainsKey => {
                let key = self.key(&arguments[0], key);
                Some(format!("(vt_map_find(&{code}.m, {map_type}, &{key}) >= 0)"))
            }
            Builtin::Get => {
                let key = self.key(&arguments[0], key);
                let entry = self.temporary(Type::INT);
                self.line(&format!(
                    "{entry} = vt_map_find(&{code}.m, {map_type}, &{key});"
                ));
                let stored = map_value(types, value, &format!("&{code}"), &entry);
                let field = clone_code(types, value, &stored);
                Some(self.option(ty, value, &format!("{entry} >= 0"), &[], &field))
            }
            // A present key keeps its stored copy, and the old value moves
            // out to the caller.
            Builtin::Insert => {
                let new_key = self.entry(&arguments[0], key);
                let new_value = self.entry(&arguments[1], value);
                let old = self.entry_temporary(value);
                let test = format!(
                    "vt_map_insert(&{code}.m, {map_type}, &{new_key}, &{new_value}, &{old})"
                );
                Some(self.option(ty, value, &test, &release(key, &new_key), &old))
            }
            Builtin::Remove => {
                let key_code = self.key(&arguments[0], key);
                let old_key = self.entry_temporary(key);
                let old = self.entry_temporary(value);
                let test = format!(
                    "vt_map_remove(&{code}.m, {map_type}, &{key_code}, &{old_key}, &{old})"
                );
                Some(self.option(ty, value, &test, &release(key, &old_key), &old))
            }
            Builtin::Keys => {
                let result = self.temporary(ty);
                self.line(&format!("{result} = {};", zero_value(types, ty)));
                let entry = self.temporary(Type::INT);
                let stored = map_key(types, key, &format!("&{code}"), &entry);
                self.line(&format!(
                    "for ({entry} = 0; {entry} < {code}.m.used; {entry} += 1) {{"
                ));
                self.line(&format!(
                    "    if ({code}.m.live[{entry}]) vt_push_T{}(&{result}, {});",
                    ty.index(),
                    clone_code(types, key, &stored)
                ));
                self.line("}");
                Some(result)
            }
            _ => unreachable!("not a map method"),
        }
    }

    /// A built-in method of a set, a map whose values are `Unit`. `insert`
    /// moves its element into the set; the other methods only read it.
    fn set_builtin(
        &mut self,
        builtin: Builtin,
        code: &str,
        set: Type,
        element: Type,
        arguments: &[Operand],
    ) -> Option<String> {
        let types = self.types;
        let set_type = format!("vt_maptype_T{}()", set.index());
        match builtin {
            Builtin::Len => Some(format!("{code}.m.len")),
            Builtin::IsEmpty => Some(format!("({code}.m.len == 0)")),
            Builtin::Clear => {
                self.line(&format!("vt_clear_T{}(&{code});", set.index()));
                None
            }
            Builtin::Contains => {
                let key = self.key(&arguments[0], element);
                Some(format!("(vt_map_find(&{code}.m, {set_type}, &{key}) >= 0)"))
            }
            // A present element keeps its stored copy.
            Builtin::Insert => {
                let key = self.entry(&arguments[0], element);
                let unit = self.entry_temporary(Type::UNIT);
                let old = self.entry_temporary(Type::UNIT);
                let added = self.temporary(Type::BOOL);
                self.line(&format!(
                    "{added} = !vt_map_insert(&{code}.m, {set_type}, &{key}, &{unit}, &{old});"
                ));
                if types.needs_release(element) {
                    let release = count_line(element, "release", &key);
                    self.line(&format!("if (!{added}) {release}"));
                }
                Some(added)
            }
            Builtin::Remove => {
                let key = self.key(&arguments[0], element);
                let old_key = self.entry_temporary(element);
                let old = self.entry_temporary(Type::UNIT);
                let removed = self.temporary(Type::BOOL);
                self.line(&format!(
                    "{removed} = vt_map_remove(&{code}.m, {set_type}, &{key}, &{old_key}, &{old});"
                ));
                if types.needs_release(element) {
                    let release = count_line(element, "release", &old_key);
                    self.line(&format!("if ({removed}) {release}"));
                }
                Some(removed)
            }
            _ => unreachable!("not a set method"),
        }
    }

    /// An owned map key or value in a temporary of the map's entry storage.
    fn entry(&mut self, operand: &Operand, ty: Type) -> String {
        let temporary = self.entry_temporary(ty);
        if let Some(value) = self.owned(operand) {
            self.line(&format!("{temporary} = {value};"));
        }
        temporary
    }

    /// A key to look up, read into a temporary of the map's entry storage.
    fn key(&mut self, operand: &Operand, ty: Type) -> String {
        let temporary = self.entry_temporary(ty);
        if let Some(value) = self.read(operand) {
            self.line(&format!("{temporary} = {value};"));
        }
        temporary
    }

    /// An `Option` of type `ty` in a new temporary: `Some` of `field`, of
    /// type `value`, after the lines `then` when `test` holds, and `None`
    /// otherwise.
    fn option(
        &mut self,
        ty: Type,
        value: Type,
        test: &str,
        then: &[String],
        field: &str,
    ) -> String {
        let (some, none) = option_variants(self.types, ty);
        let result = self.temporary(ty);
        self.line(&format!("if ({test}) {{"));
        for line in then {
            self.line(&format!("    {line}"));
        }
        self.line(&format!("    {result}.tag = {some};"));
        if self.types.has_storage(value) {
            let target = field_code(self.types, ty, some, 0, &result);
            self.line(&format!("    {target} = {field};"));
        }
        self.line(&format!("}} else {{ {result}.tag = {none}; }}"));
        result
    }

    /// A method of the string `code`, returning a `ty`.
    fn str_builtin(
        &mut self,
        method: StrMethod,
        code: &str,
        arguments: &[Operand],
        ty: Type,
    ) -> String {
        use StrMethod as M;
        let arguments = arguments
            .iter()
            .map(|argument| self.read(argument).expect("`Str` arguments have storage"))
            .collect::<Vec<_>>();
        match method {
            M::Len => format!("{code}->len"),
            M::IsEmpty => format!("({code}->len == 0)"),
            M::Contains => format!("(vt_str_find_from({code}, {}, 0) >= 0)", arguments[0]),
            M::StartsWith => format!("vt_str_starts_with({code}, {})", arguments[0]),
            M::EndsWith => format!("vt_str_ends_with({code}, {})", arguments[0]),
            M::Find => {
                let at = self.temporary(Type::INT);
                self.line(&format!(
                    "{at} = vt_str_find_from({code}, {}, 0);",
                    arguments[0]
                ));
                self.option(ty, Type::INT, &format!("{at} >= 0"), &[], &at)
            }
            M::ParseInt => {
                let parsed = self.temporary(Type::BOOL);
                let value = self.temporary(Type::INT);
                self.line(&format!("{parsed} = vt_str_parse_int({code}, &{value});"));
                self.option(ty, Type::INT, &parsed, &[], &value)
            }
            M::Slice => format!("vt_str_slice({code}, {}, {})", arguments[0], arguments[1]),
            M::Trim => format!("vt_str_trim({code})"),
            M::Replace => format!("vt_str_replace({code}, {}, {})", arguments[0], arguments[1]),
            M::Repeat => format!("vt_str_repeat({code}, {})", arguments[0]),
            M::ToUpper => format!("vt_str_case({code}, true)"),
            M::ToLower => format!("vt_str_case({code}, false)"),
            M::Split | M::Chars => {
                // The runtime returns the parts in a C array; the list takes
                // the strings and the array is freed.
                let parts = self.fresh();
                writeln!(self.declarations, "    vt_str **{parts} = NULL;").unwrap();
                let count = self.temporary(Type::INT);
                let index = self.temporary(Type::INT);
                let call = if method == M::Split {
                    format!("vt_str_split({code}, {}, &{parts})", arguments[0])
                } else {
                    format!("vt_str_chars({code}, &{parts})")
                };
                self.line(&format!("{count} = {call};"));
                let list = self.temporary(ty);
                self.line(&format!("{list} = {};", zero_value(self.types, ty)));
                self.line(&format!(
                    "for ({index} = 0; {index} < {count}; {index} += 1) vt_push_T{}(&{list}, {parts}[{index}]);",
                    ty.index()
                ));
                self.line(&format!("vt_items_free({parts});"));
                list
            }
        }
    }
}

/// `operator` applied to the values `a` and `b` of type `ty`, given as
/// `pair`. A type without storage has one value, so `pair` is `None` and the
/// two are equal.
fn comparison(
    types: &Types,
    operator: BinaryOperator,
    ty: Type,
    pair: Option<(&str, &str)>,
) -> String {
    use BinaryOperator as Op;
    let Some((a, b)) = pair else {
        return matches!(operator, Op::Equal | Op::LessEqual | Op::GreaterEqual).to_string();
    };
    let symbol = match operator {
        Op::Equal => return equal_code(types, ty, a, b),
        Op::NotEqual => return format!("(!{})", equal_code(types, ty, a, b)),
        Op::Less => "<",
        Op::Greater => ">",
        Op::LessEqual => "<=",
        Op::GreaterEqual => ">=",
        _ => unreachable!("not a comparison"),
    };
    match types.kind(ty) {
        TypeKind::Int | TypeKind::Float | TypeKind::Bool => format!("({a} {symbol} {b})"),
        TypeKind::Str => format!("(vt_str_compare({a}, {b}) {symbol} 0)"),
        _ => {
            // -1, 0 or 1, or 2 for values that are not ordered.
            let compare = compare_code(types, ty, a, b);
            match operator {
                Op::Less => format!("({compare} == -1)"),
                Op::Greater => format!("({compare} == 1)"),
                // -1 or 0.
                Op::LessEqual => format!("((unsigned)({compare} + 1) <= 1u)"),
                // 0 or 1.
                _ => format!("((unsigned)({compare}) <= 1u)"),
            }
        }
    }
}
