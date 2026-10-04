//! Lowering of checked functions to the IR in [`crate::mir`].
//!
//! Lowering fixes the order of evaluation. Operands are evaluated from left
//! to right into temporaries, so a later operand cannot change what an
//! earlier one read. A borrowed argument or receiver becomes a reference
//! temporary before the later arguments are evaluated. An assignment
//! evaluates the indices of its target, then its value, and writes last.
//!
//! Every temporary belongs to the statement that makes it and is released
//! when the statement ends; the locals of a block are released when the
//! block ends, and `break`, `continue` and `return` release the scopes they
//! leave.

use crate::ast::{AssignmentOperator, BinaryOperator, BorrowKind, Span};
use crate::mir::{
    BlockId, Body, Constant, Local, LocalDecl, Operand, Place, Projection, RefKind, Rvalue,
    Statement, StatementKind, Terminator, TerminatorKind, element_type,
};
use crate::typed::{
    Arm, Block, BorrowTarget, Builtin, Expr, ExprKind, ForSource, Function, Intrinsic, Pattern,
    Projection as TypedProjection, Receiver, Statement as TypedStatement,
};
use crate::types::{Operation, Type, TypeKind, Types};

pub(crate) fn lower(function: &Function, types: &Types) -> Body {
    let mut locals = function
        .locals
        .iter()
        .map(|local| LocalDecl {
            name: local.name.clone(),
            ty: local.ty,
            reference: local.borrow,
            temporary: false,
        })
        .collect::<Vec<_>>();
    let result = locals.len();
    locals.push(LocalDecl {
        name: "result".to_owned(),
        ty: function.result,
        reference: function.result_borrow,
        temporary: true,
    });
    let mut builder = Builder {
        types,
        body: Body {
            locals,
            parameters: function.parameters.clone(),
            result,
            blocks: Vec::new(),
        },
        current: 0,
        scopes: Vec::new(),
        loops: Vec::new(),
        index_copies: None,
    };
    builder.current = builder.body.new_block();
    builder.scopes.push(Scope {
        locals: function.parameters.clone(),
        block: true,
    });
    let span = function_span(&function.body);
    if builder.block_into(Some(Place::local(result)), &function.body) {
        if function.result == Type::UNIT {
            builder.unit_result(span);
        }
        builder.return_(span);
    }
    #[cfg(debug_assertions)]
    assert_released(&builder.body, types, &function.name);
    builder.body
}

/// Checks that every path to a return releases each local that holds
/// something to release, so no branch of lowering forgets a scope.
#[cfg(debug_assertions)]
fn assert_released(body: &Body, types: &Types, name: &str) {
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
        assert!(
            filled.is_empty(),
            "`{name}` returns without releasing locals {filled:?}"
        );
    }
}

/// A span for the synthetic steps of a function: its last expression, or
/// nothing.
fn function_span(body: &Block) -> Span {
    body.tail
        .as_ref()
        .map_or_else(|| Span::new(0, 0), |tail| tail.span)
}

struct Scope {
    /// The locals the scope owns, in the order they were declared.
    locals: Vec<Local>,
    /// A block's scope, which owns its `let` locals; a statement's scope
    /// owns only its temporaries.
    block: bool,
}

struct LoopTargets {
    /// Where `continue` goes.
    next: BlockId,
    /// Where `break` goes.
    exit: BlockId,
    /// The number of scopes open outside the loop body.
    depth: usize,
}

struct Builder<'a> {
    types: &'a Types,
    body: Body,
    current: BlockId,
    scopes: Vec<Scope>,
    loops: Vec<LoopTargets>,
    /// While the arguments of a call are lowered, the temporaries that hold
    /// variables used as indices in them.
    index_copies: Option<Vec<IndexCopy>>,
}

/// A temporary that holds the value of a variable used as an index, made
/// at a point in a block.
struct IndexCopy {
    variable: Local,
    temporary: Local,
    block: BlockId,
    /// The statements of `block` before this point.
    after: usize,
}

impl Builder<'_> {
    fn push(&mut self, kind: StatementKind, span: Span) {
        self.body.blocks[self.current]
            .statements
            .push(Statement { kind, span });
    }

    /// Stores `value` in `place`. A borrow, or a call that returns one, into
    /// a whole reference local makes it point there; anything else into a
    /// place rooted at a reference local writes where it points.
    fn assign(&mut self, place: Place, value: Rvalue, span: Span) {
        let points = place.projections.is_empty()
            && self.body.locals[place.local].reference.is_some()
            && matches!(
                value,
                Rvalue::Ref(..)
                    | Rvalue::Call {
                        borrow: Some(_),
                        ..
                    }
            );
        let kind = if points {
            StatementKind::Bind(place.local, value)
        } else {
            debug_assert!(
                !matches!(value, Rvalue::Ref(..)),
                "only a `Bind` holds a borrow"
            );
            StatementKind::Assign(place, value)
        };
        self.push(kind, span);
    }

    /// Ends the current block with `kind`; code after it goes to a new block
    /// that nothing reaches.
    fn terminate(&mut self, kind: TerminatorKind, span: Span) {
        self.body.blocks[self.current].terminator = Terminator { kind, span };
        self.current = self.body.new_block();
    }

    fn goto(&mut self, target: BlockId, span: Span) {
        self.terminate(TerminatorKind::Goto(target), span);
    }

    /// Continues in `block`, which the current block goes to.
    fn enter(&mut self, block: BlockId, span: Span) {
        self.goto(block, span);
        self.current = block;
    }

    fn new_local(&mut self, ty: Type, reference: Option<BorrowKind>) -> Local {
        self.body.locals.push(LocalDecl {
            name: String::new(),
            ty,
            reference,
            temporary: true,
        });
        self.body.locals.len() - 1
    }

    /// A temporary owned by the innermost scope.
    fn temporary(&mut self, ty: Type) -> Local {
        let local = self.new_local(ty, None);
        self.scopes
            .last_mut()
            .expect("a scope is open")
            .locals
            .push(local);
        local
    }

    /// A reference temporary, which owns nothing.
    fn reference(&mut self, ty: Type, kind: BorrowKind) -> Local {
        let local = self.new_local(ty, Some(kind));
        self.scopes
            .last_mut()
            .expect("a scope is open")
            .locals
            .push(local);
        local
    }

    /// Makes the innermost block scope own a `let` local.
    fn declare(&mut self, local: Local) {
        self.scopes
            .iter_mut()
            .rev()
            .find(|scope| scope.block)
            .expect("a block scope is open")
            .locals
            .push(local);
    }

    fn open(&mut self, block: bool) {
        self.scopes.push(Scope {
            locals: Vec::new(),
            block,
        });
    }

    /// Releases the locals of the scopes from `depth` on, innermost and
    /// latest first, without closing them.
    fn release_from(&mut self, depth: usize, span: Span) {
        let locals = self.scopes[depth..]
            .iter()
            .flat_map(|scope| scope.locals.iter().copied())
            .rev()
            .collect::<Vec<_>>();
        for local in locals {
            self.push(StatementKind::Release(local), span);
        }
    }

    fn close(&mut self, span: Span) {
        let depth = self.scopes.len() - 1;
        self.release_from(depth, span);
        self.scopes.pop();
    }

    fn unit_result(&mut self, span: Span) {
        let result = Place::local(self.body.result);
        self.assign(result, Rvalue::Use(Operand::Constant(Constant::Unit)), span);
    }

    fn return_(&mut self, span: Span) {
        self.release_from(0, span);
        self.terminate(TerminatorKind::Return, span);
    }

    fn unreachable(&mut self, span: Span) {
        self.terminate(TerminatorKind::Unreachable, span);
    }

    // Blocks and statements.

    /// Lowers `block`, storing its value in `destination`. Returns whether
    /// control continues after it.
    fn block_into(&mut self, destination: Option<Place>, block: &Block) -> bool {
        self.open(true);
        for statement in &block.statements {
            self.open(false);
            let continues = self.statement(statement);
            if !continues {
                self.scopes.pop();
                self.scopes.pop();
                return false;
            }
            let span = statement_span(statement);
            self.close(span);
        }
        let continues = match &block.tail {
            Some(tail) if block.ty == Type::UNIT => {
                self.open(false);
                let continues = self.expr_into(None, tail);
                if continues {
                    self.close(tail.span);
                } else {
                    self.scopes.pop();
                }
                continues
            }
            Some(tail) => self.expr_into(destination, tail),
            None => block.ty != Type::NEVER,
        };
        if !continues || block.ty == Type::NEVER {
            self.scopes.pop();
            if continues {
                self.unreachable(Span::new(0, 0));
            }
            return false;
        }
        let span = block
            .tail
            .as_ref()
            .map_or(Span::new(0, 0), |tail| tail.span);
        self.close(span);
        true
    }

    /// Returns whether control continues after the statement.
    fn statement(&mut self, statement: &TypedStatement) -> bool {
        match statement {
            TypedStatement::Let { local, value } => {
                self.declare(*local);
                self.expr_into(Some(Place::local(*local)), value)
            }
            TypedStatement::LetPattern { pattern, value } => {
                let Some((base, ty)) = self.subject(value) else {
                    return false;
                };
                for local in pattern.bindings() {
                    self.declare(local);
                }
                self.bind(pattern, &base, ty, value.span);
                true
            }
            TypedStatement::Assign {
                place,
                operator,
                value,
            } => {
                let Some(target) = self.typed_place(place) else {
                    return false;
                };
                let Some(value_operand) = self.operand(value) else {
                    return false;
                };
                let span = place.span;
                match operator {
                    AssignmentOperator::Assign => {
                        self.assign(target, Rvalue::Use(value_operand), span);
                    }
                    operator => {
                        let ty = value.ty;
                        let result = self.temporary(ty);
                        self.assign(
                            Place::local(result),
                            Rvalue::Binary(
                                compound_operator(*operator),
                                Operand::Copy(target.clone()),
                                value_operand,
                            ),
                            span,
                        );
                        self.assign(
                            target,
                            Rvalue::Use(Operand::Copy(Place::local(result))),
                            span,
                        );
                    }
                }
                true
            }
            TypedStatement::Expr(expression) => self.expr_into(None, expression),
            TypedStatement::Return(value) => {
                let result = Place::local(self.body.result);
                let span = value.as_ref().map_or(Span::new(0, 0), |value| value.span);
                match value {
                    Some(value) if value.ty != Type::UNIT => {
                        if !self.expr_into(Some(result), value) {
                            return false;
                        }
                    }
                    Some(value) => {
                        if !self.expr_into(None, value) {
                            return false;
                        }
                        self.unit_result(span);
                    }
                    None => self.unit_result(span),
                }
                self.return_(span);
                false
            }
            TypedStatement::Break | TypedStatement::Continue => {
                let targets = self.loops.last().expect("inside a loop");
                let (depth, target) = match statement {
                    TypedStatement::Break => (targets.depth, targets.exit),
                    _ => (targets.depth, targets.next),
                };
                self.release_from(depth, Span::new(0, 0));
                self.goto(target, Span::new(0, 0));
                false
            }
            TypedStatement::While { condition, body } => {
                let head = self.body.new_block();
                let exit = self.body.new_block();
                self.enter(head, condition.span);
                let Some(condition) = self.operand(condition) else {
                    return false;
                };
                let start = self.body.new_block();
                self.terminate(
                    TerminatorKind::Branch {
                        condition,
                        then: start,
                        otherwise: exit,
                    },
                    Span::new(0, 0),
                );
                self.current = start;
                self.loop_body(body, head, exit);
                self.current = exit;
                true
            }
            TypedStatement::Loop(body) => {
                let head = self.body.new_block();
                let exit = self.body.new_block();
                self.enter(head, Span::new(0, 0));
                self.loop_body(body, head, exit);
                // Without a `break`, nothing reaches the exit.
                self.current = exit;
                true
            }
            TypedStatement::For {
                binding,
                source,
                body,
            } => self.for_loop(binding, source, body),
        }
    }

    /// Lowers a loop body that goes back to `next`, or ends at `exit`.
    fn loop_body(&mut self, body: &Block, next: BlockId, exit: BlockId) {
        self.loops.push(LoopTargets {
            next,
            exit,
            depth: self.scopes.len(),
        });
        if self.block_into(None, body) {
            self.goto(next, Span::new(0, 0));
        }
        self.loops.pop();
    }

    fn for_loop(&mut self, binding: &Pattern, source: &ForSource, body: &Block) -> bool {
        let int = Type::INT;
        let position = self.temporary(int);
        let exit = self.body.new_block();
        let head = self.body.new_block();
        let latch = self.body.new_block();
        let start = self.body.new_block();
        // The test at the head, the step at the latch, and how the body
        // gets its element.
        enum Element {
            Counter,
            Take(Local),
            Borrow(Local),
        }
        let (element, element_ty, span) = match source {
            ForSource::Range {
                start: first,
                end,
                inclusive,
            } => {
                let Some(first) = self.operand(first) else {
                    return false;
                };
                let Some(end) = self.operand(end) else {
                    return false;
                };
                self.assign(Place::local(position), Rvalue::Use(first), Span::new(0, 0));
                let end = self.settle(end, int, Span::new(0, 0));
                self.counter_loop(position, end, *inclusive, head, latch, start, exit);
                (Element::Counter, int, Span::new(0, 0))
            }
            ForSource::RangeValue(range) => {
                let span = range.span;
                let Some(range) = self.operand(range) else {
                    return false;
                };
                let range_ty = self.range_type(&range);
                let range = self.settle(range, range_ty, span);
                let Operand::Copy(range) = range else {
                    unreachable!("a settled range is a temporary")
                };
                self.assign(
                    Place::local(position),
                    Rvalue::Use(Operand::Copy(range.project(Projection::Field(0)))),
                    span,
                );
                let end = Operand::Copy(range.project(Projection::Field(1)));
                let inclusive = range.project(Projection::Field(2));
                self.range_value_loop(position, end, inclusive, head, latch, start, exit, span);
                (Element::Counter, int, span)
            }
            ForSource::Taken { container, element } => {
                let span = container.span;
                let container_ty = container.ty;
                let taken = self.temporary(container_ty);
                if !self.expr_into(Some(Place::local(taken)), container) {
                    return false;
                }
                self.index_loop(
                    position,
                    Place::local(taken),
                    head,
                    latch,
                    start,
                    exit,
                    span,
                );
                (Element::Take(taken), *element, span)
            }
            ForSource::Borrowed(place) => {
                let span = place.span;
                let kind = for_borrow_kind(binding, self);
                let Some(target) = self.typed_place(place) else {
                    return false;
                };
                let container_ty = self.place_type(&target);
                let element_ty = element_type(self.types, container_ty);
                let reference = self.reference(container_ty, kind);
                self.assign(
                    Place::local(reference),
                    Rvalue::Ref(ref_kind(kind), target),
                    span,
                );
                self.index_loop(
                    position,
                    Place::local(reference),
                    head,
                    latch,
                    start,
                    exit,
                    span,
                );
                (Element::Borrow(reference), element_ty, span)
            }
        };
        // The body: its binding, then the body block, then the latch.
        self.current = start;
        self.loops.push(LoopTargets {
            next: latch,
            exit,
            depth: self.scopes.len(),
        });
        self.open(true);
        match element {
            Element::Counter => {
                let Pattern::Binding(local) = binding else {
                    unreachable!("a counting loop binds one name")
                };
                self.declare(*local);
                self.assign(
                    Place::local(*local),
                    Rvalue::Use(Operand::Copy(Place::local(position))),
                    span,
                );
            }
            Element::Take(taken) => {
                let item = self.temporary(element_ty);
                self.assign(
                    Place::local(item),
                    Rvalue::Take {
                        container: taken,
                        position,
                    },
                    span,
                );
                for local in binding.bindings() {
                    self.declare(local);
                }
                self.bind(binding, &Place::local(item), element_ty, span);
            }
            Element::Borrow(reference) => {
                let item = Place::local(reference).project(Projection::Position(position));
                for local in binding.bindings() {
                    self.declare(local);
                }
                self.bind(binding, &item, element_ty, span);
            }
        }
        let continues = self.block_into(None, body);
        if continues {
            self.close(span);
            self.goto(latch, span);
        } else {
            self.scopes.pop();
        }
        self.loops.pop();
        self.current = exit;
        true
    }

    /// The head of a loop over `position` from its current value to `end`.
    #[allow(clippy::too_many_arguments)]
    fn counter_loop(
        &mut self,
        position: Local,
        end: Operand,
        inclusive: bool,
        head: BlockId,
        latch: BlockId,
        start: BlockId,
        exit: BlockId,
    ) {
        let span = Span::new(0, 0);
        self.enter(head, span);
        let test = self.temporary(Type::BOOL);
        let operator = if inclusive {
            BinaryOperator::LessEqual
        } else {
            BinaryOperator::Less
        };
        self.assign(
            Place::local(test),
            Rvalue::Binary(operator, Operand::Copy(Place::local(position)), end.clone()),
            span,
        );
        self.terminate(
            TerminatorKind::Branch {
                condition: Operand::Copy(Place::local(test)),
                then: start,
                otherwise: exit,
            },
            span,
        );
        // An inclusive range stops at its end, which may be the largest
        // `Int`, without stepping past it.
        self.current = latch;
        if inclusive {
            let last = self.temporary(Type::BOOL);
            let step = self.body.new_block();
            self.assign(
                Place::local(last),
                Rvalue::Binary(
                    BinaryOperator::Equal,
                    Operand::Copy(Place::local(position)),
                    end,
                ),
                span,
            );
            self.terminate(
                TerminatorKind::Branch {
                    condition: Operand::Copy(Place::local(last)),
                    then: exit,
                    otherwise: step,
                },
                span,
            );
            self.current = step;
        }
        self.step(position, head);
    }

    /// The head of a loop over a `Range<Int>` value, whose `inclusive`
    /// flag is read at run time.
    #[allow(clippy::too_many_arguments)]
    fn range_value_loop(
        &mut self,
        position: Local,
        end: Operand,
        inclusive: Place,
        head: BlockId,
        latch: BlockId,
        start: BlockId,
        exit: BlockId,
        span: Span,
    ) {
        let inclusive_head = self.body.new_block();
        let exclusive_head = self.body.new_block();
        self.enter(head, span);
        self.terminate(
            TerminatorKind::Branch {
                condition: Operand::Copy(inclusive.clone()),
                then: inclusive_head,
                otherwise: exclusive_head,
            },
            span,
        );
        for (block, operator) in [
            (inclusive_head, BinaryOperator::LessEqual),
            (exclusive_head, BinaryOperator::Less),
        ] {
            self.current = block;
            let test = self.temporary(Type::BOOL);
            self.assign(
                Place::local(test),
                Rvalue::Binary(operator, Operand::Copy(Place::local(position)), end.clone()),
                span,
            );
            self.terminate(
                TerminatorKind::Branch {
                    condition: Operand::Copy(Place::local(test)),
                    then: start,
                    otherwise: exit,
                },
                span,
            );
        }
        self.current = latch;
        let last = self.temporary(Type::BOOL);
        let step = self.body.new_block();
        self.assign(
            Place::local(last),
            Rvalue::Binary(
                BinaryOperator::Equal,
                Operand::Copy(Place::local(position)),
                end,
            ),
            span,
        );
        let at_end = self.temporary(Type::BOOL);
        self.assign(
            Place::local(at_end),
            Rvalue::Binary(
                BinaryOperator::LogicAnd,
                Operand::Copy(inclusive),
                Operand::Copy(Place::local(last)),
            ),
            span,
        );
        self.terminate(
            TerminatorKind::Branch {
                condition: Operand::Copy(Place::local(at_end)),
                then: exit,
                otherwise: step,
            },
            span,
        );
        self.current = step;
        self.step(position, head);
    }

    /// The head of a loop over the positions of the container at `place`,
    /// whose length is read at every test. The positions of removed entries
    /// of a map or set are skipped.
    #[allow(clippy::too_many_arguments)]
    fn index_loop(
        &mut self,
        position: Local,
        container: Place,
        head: BlockId,
        latch: BlockId,
        start: BlockId,
        exit: BlockId,
        span: Span,
    ) {
        let gaps = matches!(
            self.types.kind(self.place_type(&container)),
            TypeKind::Map(..) | TypeKind::Set(_)
        );
        let entry = if gaps { self.body.new_block() } else { start };
        self.assign(
            Place::local(position),
            Rvalue::Use(Operand::Constant(Constant::Int(0))),
            span,
        );
        self.enter(head, span);
        let length = self.temporary(Type::INT);
        self.assign(Place::local(length), Rvalue::Len(container.clone()), span);
        let test = self.temporary(Type::BOOL);
        self.assign(
            Place::local(test),
            Rvalue::Binary(
                BinaryOperator::Less,
                Operand::Copy(Place::local(position)),
                Operand::Copy(Place::local(length)),
            ),
            span,
        );
        self.terminate(
            TerminatorKind::Branch {
                condition: Operand::Copy(Place::local(test)),
                then: entry,
                otherwise: exit,
            },
            span,
        );
        if gaps {
            self.current = entry;
            let occupied = self.temporary(Type::BOOL);
            self.assign(
                Place::local(occupied),
                Rvalue::Occupied {
                    container,
                    position,
                },
                span,
            );
            self.terminate(
                TerminatorKind::Branch {
                    condition: Operand::Copy(Place::local(occupied)),
                    then: start,
                    otherwise: latch,
                },
                span,
            );
        }
        self.current = latch;
        self.step(position, head);
    }

    fn step(&mut self, position: Local, head: BlockId) {
        let span = Span::new(0, 0);
        self.assign(
            Place::local(position),
            Rvalue::Binary(
                BinaryOperator::Add,
                Operand::Copy(Place::local(position)),
                Operand::Constant(Constant::Int(1)),
            ),
            span,
        );
        self.goto(head, span);
    }

    fn range_type(&self, operand: &Operand) -> Type {
        match operand {
            Operand::Copy(place) | Operand::Move(place) => self.place_type(place),
            _ => unreachable!("a range value is a place"),
        }
    }

    // Expressions.

    /// Lowers `expression` and stores its value in `destination`, or drops
    /// it. Returns whether control continues after it.
    fn expr_into(&mut self, destination: Option<Place>, expression: &Expr) -> bool {
        let span = expression.span;
        let ty = expression.ty;
        let value = match &expression.kind {
            ExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => {
                return self.if_into(
                    destination,
                    condition,
                    then_branch,
                    else_branch.as_deref(),
                    ty,
                );
            }
            ExprKind::Block(block) => return self.block_into(destination, block),
            ExprKind::Match { scrutinee, arms } => {
                return self.match_into(destination, scrutinee, arms, ty, span);
            }
            ExprKind::Binary {
                operator: operator @ (BinaryOperator::LogicAnd | BinaryOperator::LogicOr),
                left,
                right,
            } => return self.logic_into(destination, *operator, left, right, span),
            _ => self.rvalue(expression),
        };
        let Some(value) = value else {
            return false;
        };
        if ty == Type::NEVER {
            // A call that returns `Never`: the call runs, and control stops.
            let sink = self.new_local(Type::NEVER, None);
            self.assign(Place::local(sink), value, span);
            self.unreachable(span);
            return false;
        }
        match destination {
            Some(destination) => self.assign(destination, value, span),
            None => {
                let sink = self.temporary(ty);
                self.assign(Place::local(sink), value, span);
            }
        }
        true
    }

    /// The value of `expression` as one IR step, after the steps that
    /// evaluate its parts.
    fn rvalue(&mut self, expression: &Expr) -> Option<Rvalue> {
        let span = expression.span;
        let ty = expression.ty;
        Some(match &expression.kind {
            ExprKind::Int(value) => Rvalue::Use(Operand::Constant(Constant::Int(*value))),
            ExprKind::Float(value) => Rvalue::Use(Operand::Constant(Constant::Float(*value))),
            ExprKind::Bool(value) => Rvalue::Use(Operand::Constant(Constant::Bool(*value))),
            ExprKind::Str(value) => Rvalue::Use(Operand::Constant(Constant::Str(value.clone()))),
            ExprKind::Unit => Rvalue::Use(Operand::Constant(Constant::Unit)),
            ExprKind::Local(_) | ExprKind::Field { .. } | ExprKind::Index { .. } => {
                // The checker moves or borrows entities wherever they are
                // used as values, so this reads a value.
                debug_assert!(!self.types.is_entity(ty), "an entity read as a value");
                Rvalue::Use(Operand::Copy(self.place(expression)?))
            }
            ExprKind::Move(place) => Rvalue::Use(Operand::Move(self.typed_place(place)?)),
            ExprKind::Call {
                callee,
                type_arguments,
                arguments,
                borrow,
            } => {
                let arguments = self.arguments(arguments, span)?;
                Rvalue::Call {
                    callee: *callee,
                    type_arguments: type_arguments.clone(),
                    arguments,
                    borrow: *borrow,
                }
            }
            ExprKind::Intrinsic {
                intrinsic,
                arguments,
            } => {
                let arguments = self.arguments(arguments, span)?;
                Rvalue::Intrinsic {
                    intrinsic: *intrinsic,
                    arguments,
                }
            }
            ExprKind::Unary { operator, operand } => {
                Rvalue::Unary(*operator, self.operand(operand)?)
            }
            ExprKind::Binary {
                operator,
                left,
                right,
            } => {
                let compares = !matches!(
                    operator,
                    BinaryOperator::Add
                        | BinaryOperator::Subtract
                        | BinaryOperator::Multiply
                        | BinaryOperator::Divide
                        | BinaryOperator::Remainder
                        | BinaryOperator::RangeExclusive
                        | BinaryOperator::RangeInclusive
                );
                let ty = left.ty;
                let (left, right) = if compares && self.types.is_entity(ty) {
                    // Comparisons borrow entity operands.
                    let left = self.borrowed_operand(left)?;
                    (left, self.borrowed_operand(right)?)
                } else {
                    let left = self.operand(left)?;
                    (left, self.operand(right)?)
                };
                // Comparing values that have parts may run hand-written impls.
                if compares
                    && matches!(
                        self.types.kind(ty),
                        TypeKind::Tuple(_)
                            | TypeKind::Nominal { .. }
                            | TypeKind::List(_)
                            | TypeKind::Param { .. }
                    )
                {
                    let operation = match operator {
                        BinaryOperator::Equal | BinaryOperator::NotEqual => Operation::Equal,
                        _ => Operation::Order,
                    };
                    return Some(Rvalue::Glue {
                        operation,
                        operator: Some(*operator),
                        ty,
                        operands: vec![left, right],
                    });
                }
                Rvalue::Binary(*operator, left, right)
            }
            ExprKind::Interpolate(parts) => Rvalue::Interpolate(self.operands(parts)?),
            ExprKind::Tuple(elements) => Rvalue::Tuple(self.operands(elements)?),
            ExprKind::List(elements) => Rvalue::List(self.operands(elements)?),
            ExprKind::Construct {
                variant,
                base,
                fields,
            } => match base {
                None => {
                    let values = self.operands_of(fields.iter().map(|(_, value)| value))?;
                    Rvalue::Construct {
                        variant: *variant,
                        fields: fields.iter().map(|(index, _)| *index).zip(values).collect(),
                    }
                }
                Some(base) => {
                    // The base, then each given field in its place.
                    let result = self.temporary(ty);
                    if !self.expr_into(Some(Place::local(result)), base) {
                        return None;
                    }
                    for (index, value) in fields {
                        let field_place = Place::local(result).project(Projection::Field(*index));
                        if !self.expr_into(Some(field_place), value) {
                            return None;
                        }
                    }
                    Rvalue::Use(Operand::Move(Place::local(result)))
                }
            },
            ExprKind::EmptyMap => Rvalue::EmptyMap,
            ExprKind::Range {
                start,
                end,
                inclusive,
            } => {
                let start = self.operand(start)?;
                Rvalue::Range {
                    start,
                    end: self.operand(end)?,
                    inclusive: *inclusive,
                }
            }
            ExprKind::Builtin {
                builtin,
                receiver,
                arguments,
            } => self.builtin(*builtin, receiver, arguments, span)?,
            ExprKind::Borrow(kind, target) => {
                let place = match target.as_ref() {
                    BorrowTarget::Place(place) => self.typed_place(place)?,
                    BorrowTarget::Value(value) => {
                        let temporary = self.temporary(value.ty);
                        if !self.expr_into(Some(Place::local(temporary)), value) {
                            return None;
                        }
                        Place::local(temporary)
                    }
                };
                Rvalue::Ref(ref_kind(*kind), place)
            }
            ExprKind::If { .. } | ExprKind::Block(_) | ExprKind::Match { .. } => {
                let result = self.temporary(ty);
                if !self.expr_into(Some(Place::local(result)), expression) {
                    return None;
                }
                Rvalue::Use(self.take(Place::local(result), ty))
            }
        })
    }

    /// Lowers `expression` to an operand that later steps cannot change.
    fn operand(&mut self, expression: &Expr) -> Option<Operand> {
        let ty = expression.ty;
        match &expression.kind {
            ExprKind::Int(value) => Some(Operand::Constant(Constant::Int(*value))),
            ExprKind::Float(value) => Some(Operand::Constant(Constant::Float(*value))),
            ExprKind::Bool(value) => Some(Operand::Constant(Constant::Bool(*value))),
            ExprKind::Str(value) => Some(Operand::Constant(Constant::Str(value.clone()))),
            ExprKind::Unit => Some(Operand::Constant(Constant::Unit)),
            _ => {
                let temporary = self.temporary(ty);
                if !self.expr_into(Some(Place::local(temporary)), expression) {
                    return None;
                }
                Some(self.take(Place::local(temporary), ty))
            }
        }
    }

    /// An operand that reads or takes a temporary.
    fn take(&self, place: Place, ty: Type) -> Operand {
        if self.types.is_entity(ty) {
            Operand::Move(place)
        } else {
            Operand::Copy(place)
        }
    }

    /// `operand` as a temporary, unless it is a constant.
    fn settle(&mut self, operand: Operand, ty: Type, span: Span) -> Operand {
        match operand {
            Operand::Constant(_) | Operand::Borrowed(_) => operand,
            Operand::Copy(place) | Operand::Move(place)
                if self.body.locals[place.local].temporary && place.projections.is_empty() =>
            {
                Operand::Copy(place)
            }
            operand => {
                let temporary = self.temporary(ty);
                self.assign(Place::local(temporary), Rvalue::Use(operand), span);
                self.take(Place::local(temporary), ty)
            }
        }
    }

    fn operands(&mut self, expressions: &[Expr]) -> Option<Vec<Operand>> {
        self.operands_of(expressions.iter())
    }

    fn operands_of<'e>(
        &mut self,
        expressions: impl Iterator<Item = &'e Expr>,
    ) -> Option<Vec<Operand>> {
        expressions
            .map(|expression| self.operand(expression))
            .collect()
    }

    /// An operand that reads an entity where it is: a place is borrowed for
    /// as long as the operand is needed, and any other value is kept in a
    /// temporary.
    fn borrowed_operand(&mut self, expression: &Expr) -> Option<Operand> {
        if is_place(expression) {
            let span = expression.span;
            let place = self.place(expression)?;
            let reference = self.reference(expression.ty, BorrowKind::Shared);
            self.assign(
                Place::local(reference),
                Rvalue::Ref(RefKind::Shared, place),
                span,
            );
            Some(Operand::Inspect(Place::local(reference)))
        } else {
            let temporary = self.temporary(expression.ty);
            if !self.expr_into(Some(Place::local(temporary)), expression) {
                return None;
            }
            Some(Operand::Inspect(Place::local(temporary)))
        }
    }

    /// The arguments of a call: a borrowed one is a reference temporary
    /// made before the later arguments are evaluated. Then, for each two
    /// borrowed places at least one of which is borrowed with `&mut` and
    /// which differ only in indices, the program panics if they are the
    /// same element.
    fn arguments(&mut self, arguments: &[Expr], span: Span) -> Option<Vec<Operand>> {
        let outer = self.index_copies.replace(Vec::new());
        let operands = self.arguments_in(arguments, span);
        self.index_copies = outer;
        operands
    }

    fn arguments_in(&mut self, arguments: &[Expr], span: Span) -> Option<Vec<Operand>> {
        let mut operands = Vec::new();
        let mut places = Vec::new();
        for argument in arguments {
            let mut borrowed = None;
            operands.push(match &argument.kind {
                ExprKind::Borrow(kind, target) => {
                    let place = match target.as_ref() {
                        BorrowTarget::Place(place) => {
                            let place = self.typed_place(place)?;
                            borrowed = Some((place.clone(), *kind == BorrowKind::Mutable));
                            place
                        }
                        BorrowTarget::Value(value) => {
                            let temporary = self.temporary(value.ty);
                            if !self.expr_into(Some(Place::local(temporary)), value) {
                                return None;
                            }
                            Place::local(temporary)
                        }
                    };
                    let reference = self.reference(argument.ty, *kind);
                    let ref_kind = match kind {
                        BorrowKind::Shared => RefKind::Shared,
                        BorrowKind::Mutable => RefKind::MutableArgument,
                    };
                    self.assign(
                        Place::local(reference),
                        Rvalue::Ref(ref_kind, place),
                        argument.span,
                    );
                    Operand::Borrowed(reference)
                }
                _ => self.operand(argument)?,
            });
            places.push(borrowed);
        }
        let places = places.into_iter().flatten().collect::<Vec<_>>();
        for (position, (first, first_mutable)) in places.iter().enumerate() {
            for (second, second_mutable) in &places[position + 1..] {
                if (*first_mutable || *second_mutable) && first.differs_only_in_indices(second) {
                    self.disjoint(first, second, span);
                }
            }
        }
        Some(operands)
    }

    /// Panics if the places `first` and `second`, which differ only in
    /// indices, are the same element: if every index of one equals the
    /// index at the same step of the other.
    fn disjoint(&mut self, first: &Place, second: &Place, span: Span) {
        let mut pairs = Vec::new();
        for (left, right) in first.projections.iter().zip(&second.projections) {
            pairs.push(match (left, right) {
                (Projection::ConstantIndex(left), Projection::ConstantIndex(right)) => {
                    if left != right {
                        return;
                    }
                    continue;
                }
                (Projection::Index(left), Projection::Index(right)) => (
                    Operand::Copy(Place::local(*left)),
                    Operand::Copy(Place::local(*right)),
                ),
                (Projection::Index(index), Projection::ConstantIndex(constant))
                | (Projection::ConstantIndex(constant), Projection::Index(index)) => (
                    Operand::Copy(Place::local(*index)),
                    Operand::Constant(Constant::Int(*constant)),
                ),
                _ => continue,
            });
        }
        let distinct = self.body.new_block();
        for (left, right) in pairs {
            let same = self.temporary(Type::BOOL);
            self.assign(
                Place::local(same),
                Rvalue::Binary(BinaryOperator::Equal, left, right),
                span,
            );
            let next = self.body.new_block();
            self.terminate(
                TerminatorKind::Branch {
                    condition: Operand::Copy(Place::local(same)),
                    then: next,
                    otherwise: distinct,
                },
                span,
            );
            self.current = next;
        }
        let sink = self.new_local(Type::NEVER, None);
        self.assign(
            Place::local(sink),
            Rvalue::Intrinsic {
                intrinsic: Intrinsic::Panic,
                arguments: vec![Operand::Constant(Constant::Str(
                    "the same element is borrowed twice".to_owned(),
                ))],
            },
            span,
        );
        self.unreachable(span);
        self.current = distinct;
    }

    fn builtin(
        &mut self,
        builtin: Builtin,
        receiver: &Receiver,
        arguments: &[Expr],
        span: Span,
    ) -> Option<Rvalue> {
        let place = match receiver {
            Receiver::Place(place) => self.typed_place(place)?,
            Receiver::Value(value) => self.place(value)?,
        };
        let receiver_ty = self.place_type(&place);
        // A method that changes its receiver borrows it with `&mut`, and
        // `clone` of an entity reads it whole with `&`, before the arguments
        // are evaluated. The others read only values of a container, its
        // length, keys or value elements, which never conflicts, and a
        // `Str` receiver is a value read now.
        let kind = match builtin {
            Builtin::Push | Builtin::Pop | Builtin::Insert | Builtin::Remove | Builtin::Clear => {
                Some((RefKind::MutableArgument, BorrowKind::Mutable))
            }
            Builtin::Clone if self.types.is_entity(receiver_ty) => {
                Some((RefKind::Shared, BorrowKind::Shared))
            }
            _ => None,
        };
        let receiver = match kind {
            Some((ref_kind, borrow)) => {
                let reference = self.reference(receiver_ty, borrow);
                self.assign(Place::local(reference), Rvalue::Ref(ref_kind, place), span);
                Place::local(reference)
            }
            None if self.types.is_entity(receiver_ty) => place,
            None => {
                let operand = self.settle(Operand::Copy(place), receiver_ty, span);
                let (Operand::Copy(place) | Operand::Move(place)) = operand else {
                    unreachable!("a settled receiver is a temporary")
                };
                place
            }
        };
        let mut arguments = self.operands(arguments)?;
        // Cloning, and searching a list, clone or compare the parts of
        // values, which may run hand-written impls.
        let operation = match (builtin, self.types.kind(receiver_ty)) {
            (Builtin::Clone, _) => Some(Operation::Clone),
            (Builtin::Contains, TypeKind::List(_)) => Some(Operation::Contains),
            _ => None,
        };
        if let Some(operation) = operation {
            // An entity is looked at where it is; a value is read.
            let receiver = if self.types.is_entity(receiver_ty) {
                Operand::Inspect(receiver)
            } else {
                Operand::Copy(receiver)
            };
            arguments.insert(0, receiver);
            return Some(Rvalue::Glue {
                operation,
                operator: None,
                ty: receiver_ty,
                operands: arguments,
            });
        }
        Some(Rvalue::Builtin {
            builtin,
            receiver,
            arguments,
        })
    }

    /// Lowers a place expression: a local, fields and indices of it, or a
    /// part of a value kept in a temporary.
    fn place(&mut self, expression: &Expr) -> Option<Place> {
        match &expression.kind {
            ExprKind::Local(local) => Some(Place::local(*local)),
            ExprKind::Field { base, index } => {
                let base = self.place(base)?;
                Some(base.project(Projection::Field(*index)))
            }
            ExprKind::Index { base, index } => {
                let base = self.place(base)?;
                let index = self.index(index)?;
                Some(base.project(index))
            }
            ExprKind::Call {
                borrow: Some(_), ..
            } => {
                let reference = self.reference(expression.ty, BorrowKind::Shared);
                if !self.expr_into(Some(Place::local(reference)), expression) {
                    return None;
                }
                Some(Place::local(reference))
            }
            _ => {
                let temporary = self.temporary(expression.ty);
                if !self.expr_into(Some(Place::local(temporary)), expression) {
                    return None;
                }
                Some(Place::local(temporary))
            }
        }
    }

    /// Lowers a place of the checked program.
    fn typed_place(&mut self, place: &crate::typed::Place) -> Option<Place> {
        if let Some(call) = &place.call {
            // The call's result points at the place; the checker's local for
            // it is a reference.
            if !self.expr_into(Some(Place::local(place.local)), call) {
                return None;
            }
        }
        let mut lowered = Place::local(place.local);
        for projection in &place.projections {
            lowered = match projection {
                TypedProjection::Field(index) => lowered.project(Projection::Field(*index)),
                TypedProjection::Index(index) => {
                    let index = self.index(index)?;
                    lowered.project(index)
                }
            };
        }
        Some(lowered)
    }

    /// An index projection: a constant, or a temporary that holds the index
    /// or key as it was when the place was evaluated.
    fn index(&mut self, index: &Expr) -> Option<Projection> {
        if let ExprKind::Int(value) = index.kind {
            return Some(Projection::ConstantIndex(value));
        }
        if let ExprKind::Local(variable) = index.kind
            && let Some(temporary) = self.same_index(variable)
        {
            return Some(Projection::Index(temporary));
        }
        let temporary = self.temporary(index.ty);
        if !self.expr_into(Some(Place::local(temporary)), index) {
            return None;
        }
        if let ExprKind::Local(variable) = index.kind
            && let Some(copies) = &mut self.index_copies
        {
            copies.push(IndexCopy {
                variable,
                temporary,
                block: self.current,
                after: self.body.blocks[self.current].statements.len(),
            });
        }
        Some(Projection::Index(temporary))
    }

    /// In the arguments of the call being lowered, a temporary that already
    /// holds the value of the variable `variable`, which nothing has changed
    /// since. Two places indexed by the same variable then name the same
    /// element, which borrow checking sees.
    fn same_index(&self, variable: Local) -> Option<Local> {
        let copy = self
            .index_copies
            .as_ref()?
            .iter()
            .rev()
            .find(|copy| copy.variable == variable)?;
        if copy.block != self.current {
            return None;
        }
        let statements = &self.body.blocks[self.current].statements[copy.after..];
        statements
            .iter()
            .all(|statement| !changes(&statement.kind, variable))
            .then_some(copy.temporary)
    }

    /// The type of the value at `place`.
    fn place_type(&self, place: &Place) -> Type {
        self.body.place_type(self.types, place)
    }

    fn if_into(
        &mut self,
        destination: Option<Place>,
        condition: &Expr,
        then_branch: &Block,
        else_branch: Option<&Expr>,
        ty: Type,
    ) -> bool {
        let span = condition.span;
        let Some(condition) = self.operand(condition) else {
            return false;
        };
        let then = self.body.new_block();
        let otherwise = self.body.new_block();
        let join = self.body.new_block();
        self.terminate(
            TerminatorKind::Branch {
                condition,
                then,
                otherwise,
            },
            span,
        );
        let destination = destination.filter(|_| ty != Type::UNIT);
        self.current = then;
        let mut reaches = false;
        if self.block_into(destination.clone(), then_branch) {
            self.goto(join, span);
            reaches = true;
        }
        self.current = otherwise;
        let continues = match else_branch {
            Some(branch) => {
                self.open(false);
                let continues = self.expr_into(destination, branch);
                if continues {
                    self.close(span);
                } else {
                    self.scopes.pop();
                }
                continues
            }
            None => true,
        };
        if continues {
            self.goto(join, span);
            reaches = true;
        }
        self.current = join;
        if !reaches {
            self.unreachable(span);
        }
        reaches
    }

    /// `left && right` or `left || right`: the right operand runs only when
    /// the left one does not decide the result.
    fn logic_into(
        &mut self,
        destination: Option<Place>,
        operator: BinaryOperator,
        left: &Expr,
        right: &Expr,
        span: Span,
    ) -> bool {
        let result = self.temporary(Type::BOOL);
        let Some(left) = self.operand(left) else {
            return false;
        };
        self.assign(Place::local(result), Rvalue::Use(left), span);
        let evaluate = self.body.new_block();
        let join = self.body.new_block();
        let (then, otherwise) = match operator {
            BinaryOperator::LogicAnd => (evaluate, join),
            _ => (join, evaluate),
        };
        self.terminate(
            TerminatorKind::Branch {
                condition: Operand::Copy(Place::local(result)),
                then,
                otherwise,
            },
            span,
        );
        self.current = evaluate;
        self.open(false);
        if self.expr_into(Some(Place::local(result)), right) {
            self.close(span);
            self.goto(join, span);
        } else {
            self.scopes.pop();
        }
        self.current = join;
        if let Some(destination) = destination {
            self.assign(
                destination,
                Rvalue::Use(Operand::Copy(Place::local(result))),
                span,
            );
        }
        true
    }

    // Matching.

    /// Evaluates the subject of a `match` or destructuring. Returns the
    /// place the patterns read and its type: a borrowed place through a
    /// reference, a place the match only reads where it is, and any other
    /// value in a temporary that bindings may take parts of.
    fn subject(&mut self, subject: &Expr) -> Option<(Place, Type)> {
        let span = subject.span;
        match &subject.kind {
            ExprKind::Borrow(kind, target) => {
                let place = match target.as_ref() {
                    BorrowTarget::Place(place) => self.typed_place(place)?,
                    BorrowTarget::Value(value) => {
                        let temporary = self.temporary(value.ty);
                        if !self.expr_into(Some(Place::local(temporary)), value) {
                            return None;
                        }
                        Place::local(temporary)
                    }
                };
                let reference = self.reference(subject.ty, *kind);
                self.assign(
                    Place::local(reference),
                    Rvalue::Ref(ref_kind(*kind), place),
                    span,
                );
                Some((Place::local(reference), subject.ty))
            }
            _ if is_place(subject) => Some((self.place(subject)?, subject.ty)),
            _ => {
                let temporary = self.temporary(subject.ty);
                if !self.expr_into(Some(Place::local(temporary)), subject) {
                    return None;
                }
                Some((Place::local(temporary), subject.ty))
            }
        }
    }

    fn match_into(
        &mut self,
        destination: Option<Place>,
        scrutinee: &Expr,
        arms: &[Arm],
        ty: Type,
        span: Span,
    ) -> bool {
        let Some((base, subject_ty)) = self.subject(scrutinee) else {
            return false;
        };
        let destination = destination.filter(|_| ty != Type::UNIT);
        let join = self.body.new_block();
        let mut reaches = false;
        for arm in arms {
            let next_arm = self.body.new_block();
            let matched = self.body.new_block();
            self.open(true);
            for local in arm.pattern.bindings() {
                self.declare(local);
            }
            // The first alternative that matches binds; its guard decides
            // whether this arm runs or the next arm is tried.
            let alternatives = match &arm.pattern {
                Pattern::Or(alternatives) => alternatives.clone(),
                pattern => vec![pattern.clone()],
            };
            let count = alternatives.len();
            for (position, alternative) in alternatives.iter().enumerate() {
                let fail = if position + 1 < count {
                    self.body.new_block()
                } else {
                    next_arm
                };
                self.test(alternative, &base, subject_ty, fail, span);
                self.bind(alternative, &base, subject_ty, span);
                if let Some(guard) = &arm.guard {
                    let Some(condition) = self.operand(guard) else {
                        self.current = fail;
                        continue;
                    };
                    let accepted = self.body.new_block();
                    let rejected = self.body.new_block();
                    self.terminate(
                        TerminatorKind::Branch {
                            condition,
                            then: accepted,
                            otherwise: rejected,
                        },
                        guard.span,
                    );
                    // A rejected arm gives back what its bindings took, so
                    // the next arms see the subject whole, and releases the
                    // rest of its bindings and the guard's temporaries.
                    self.current = rejected;
                    self.unbind(alternative, &base, subject_ty, guard.span);
                    let depth = self.scopes.len() - 1;
                    self.release_from(depth, guard.span);
                    self.goto(next_arm, guard.span);
                    self.current = accepted;
                }
                self.goto(matched, span);
                self.current = fail;
            }
            self.current = matched;
            let continues = self.expr_into(destination.clone(), &arm.body);
            if continues {
                self.close(arm.body.span);
                self.goto(join, span);
                reaches = true;
            } else {
                self.scopes.pop();
            }
            self.current = next_arm;
        }
        // The arms cover every value.
        self.unreachable(span);
        self.current = join;
        if !reaches {
            self.unreachable(span);
        }
        reaches
    }

    /// Branches to `fail` unless the value at `place` matches `pattern`,
    /// which has no alternatives.
    fn test(&mut self, pattern: &Pattern, place: &Place, ty: Type, fail: BlockId, span: Span) {
        let constant = match pattern {
            Pattern::Wildcard | Pattern::Binding(_) => return,
            Pattern::Int(value) => Constant::Int(*value),
            Pattern::Float(value) => Constant::Float(*value),
            Pattern::Bool(value) => Constant::Bool(*value),
            Pattern::Str(value) => Constant::Str(value.clone()),
            Pattern::Tuple(elements) => {
                let element_types = self.types.components(ty);
                for (index, (element, element_ty)) in elements.iter().zip(element_types).enumerate()
                {
                    let element_place = place.project(Projection::Field(index));
                    self.test(element, &element_place, element_ty, fail, span);
                }
                return;
            }
            Pattern::Variant { variant, fields } => {
                let tag = self.temporary(Type::INT);
                self.assign(Place::local(tag), Rvalue::Discriminant(place.clone()), span);
                self.branch_unless_equal(
                    Operand::Copy(Place::local(tag)),
                    Constant::Int(i64::try_from(*variant).expect("few variants")),
                    fail,
                    span,
                );
                for (field, field_pattern) in fields {
                    let field_ty = self.types.variants(ty)[*variant].fields[*field].ty;
                    let field_place = place.project(Projection::VariantField {
                        variant: *variant,
                        field: *field,
                    });
                    self.test(field_pattern, &field_place, field_ty, fail, span);
                }
                return;
            }
            Pattern::Or(_) => unreachable!("alternatives are expanded before testing"),
        };
        self.branch_unless_equal(Operand::Copy(place.clone()), constant, fail, span);
    }

    fn branch_unless_equal(
        &mut self,
        value: Operand,
        constant: Constant,
        fail: BlockId,
        span: Span,
    ) {
        let test = self.temporary(Type::BOOL);
        self.assign(
            Place::local(test),
            Rvalue::Binary(BinaryOperator::Equal, value, Operand::Constant(constant)),
            span,
        );
        let next = self.body.new_block();
        self.terminate(
            TerminatorKind::Branch {
                condition: Operand::Copy(Place::local(test)),
                then: next,
                otherwise: fail,
            },
            span,
        );
        self.current = next;
    }

    /// Gives the binding locals of `pattern` the parts of the value at
    /// `place`: a pointer for a borrowed binding, the part itself for an
    /// owned entity, and a copy otherwise.
    fn bind(&mut self, pattern: &Pattern, place: &Place, ty: Type, span: Span) {
        match pattern {
            Pattern::Binding(local) => {
                let value = match self.body.locals[*local].reference {
                    Some(kind) => Rvalue::Ref(ref_kind(kind), place.clone()),
                    None if self.types.is_entity(ty) => Rvalue::Use(Operand::Move(place.clone())),
                    None => Rvalue::Use(Operand::Copy(place.clone())),
                };
                self.assign(Place::local(*local), value, span);
            }
            Pattern::Tuple(elements) => {
                let element_types = self.types.components(ty);
                for (index, (element, element_ty)) in elements.iter().zip(element_types).enumerate()
                {
                    self.bind(
                        element,
                        &place.project(Projection::Field(index)),
                        element_ty,
                        span,
                    );
                }
            }
            Pattern::Variant { variant, fields } => {
                for (field, field_pattern) in fields {
                    let field_ty = self.types.variants(ty)[*variant].fields[*field].ty;
                    let field_place = place.project(Projection::VariantField {
                        variant: *variant,
                        field: *field,
                    });
                    self.bind(field_pattern, &field_place, field_ty, span);
                }
            }
            Pattern::Or(alternatives) => {
                // Destructuring and loop bindings have no alternatives that
                // bind; a match expands them before binding.
                if let Some(first) = alternatives.first() {
                    self.bind(first, place, ty, span);
                }
            }
            Pattern::Wildcard
            | Pattern::Int(_)
            | Pattern::Float(_)
            | Pattern::Bool(_)
            | Pattern::Str(_) => {}
        }
    }

    /// Moves the owned entity bindings of `pattern` back into the parts of
    /// the value at `place` they were taken from.
    fn unbind(&mut self, pattern: &Pattern, place: &Place, ty: Type, span: Span) {
        match pattern {
            Pattern::Binding(local)
                if self.body.locals[*local].reference.is_none() && self.types.is_entity(ty) =>
            {
                self.assign(
                    place.clone(),
                    Rvalue::Use(Operand::Move(Place::local(*local))),
                    span,
                );
            }
            Pattern::Tuple(elements) => {
                let element_types = self.types.components(ty);
                for (index, (element, element_ty)) in elements.iter().zip(element_types).enumerate()
                {
                    let element_place = place.project(Projection::Field(index));
                    self.unbind(element, &element_place, element_ty, span);
                }
            }
            Pattern::Variant { variant, fields } => {
                for (field, field_pattern) in fields {
                    let field_ty = self.types.variants(ty)[*variant].fields[*field].ty;
                    let field_place = place.project(Projection::VariantField {
                        variant: *variant,
                        field: *field,
                    });
                    self.unbind(field_pattern, &field_place, field_ty, span);
                }
            }
            _ => {}
        }
    }
}

/// Whether `statement` may change the value of the variable `variable`:
/// it writes or moves it, borrows it with `&mut`, or ends it.
fn changes(statement: &StatementKind, variable: Local) -> bool {
    let moves = |value: &Rvalue| {
        value
            .operands()
            .iter()
            .any(|operand| matches!(operand, Operand::Move(place) if place.local == variable))
    };
    match statement {
        StatementKind::Assign(destination, value) => destination.local == variable || moves(value),
        StatementKind::Bind(_, Rvalue::Ref(kind, place)) => {
            place.local == variable && *kind != RefKind::Shared
        }
        StatementKind::Bind(_, value) => moves(value),
        StatementKind::Release(local) => *local == variable,
    }
}

/// Whether `expression` names a place: a local and fields and indices of
/// it, or the result of a call that returns a borrow.
fn is_place(expression: &Expr) -> bool {
    match &expression.kind {
        ExprKind::Local(_)
        | ExprKind::Call {
            borrow: Some(_), ..
        } => true,
        ExprKind::Field { base, .. } | ExprKind::Index { base, .. } => is_place(base),
        _ => false,
    }
}

fn ref_kind(kind: BorrowKind) -> RefKind {
    match kind {
        BorrowKind::Shared => RefKind::Shared,
        BorrowKind::Mutable => RefKind::Mutable,
    }
}

/// How a `for` loop borrows its container: as its bindings borrow the
/// elements.
fn for_borrow_kind(binding: &Pattern, builder: &Builder) -> BorrowKind {
    binding
        .bindings()
        .into_iter()
        .find_map(|local| builder.body.locals[local].reference)
        .unwrap_or(BorrowKind::Shared)
}

fn compound_operator(operator: AssignmentOperator) -> BinaryOperator {
    match operator {
        AssignmentOperator::AddAssign => BinaryOperator::Add,
        AssignmentOperator::SubtractAssign => BinaryOperator::Subtract,
        AssignmentOperator::MultiplyAssign => BinaryOperator::Multiply,
        AssignmentOperator::DivideAssign => BinaryOperator::Divide,
        AssignmentOperator::RemainderAssign => BinaryOperator::Remainder,
        AssignmentOperator::Assign => unreachable!("plain assignment has no operator"),
    }
}

fn statement_span(statement: &TypedStatement) -> Span {
    match statement {
        TypedStatement::Let { value, .. }
        | TypedStatement::LetPattern { value, .. }
        | TypedStatement::Expr(value)
        | TypedStatement::Return(Some(value)) => value.span,
        TypedStatement::Assign { place, .. } => place.span,
        TypedStatement::While { condition, .. } => condition.span,
        _ => Span::new(0, 0),
    }
}
