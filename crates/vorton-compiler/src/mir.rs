//! The mid-level IR.
//!
//! Each function is a control-flow graph of basic blocks. A block runs its
//! statements in order and ends in one terminator that says where control
//! goes. Every step names the places it reads and writes, every temporary
//! is a local, and every borrow is an explicit `Bind` of a reference local. Branches of `if`, `match`, `&&`, `||`, guards and loops are edges,
//! so an analysis that follows the edges covers every construct alike.
//!
//! Every step that can run code the program wrote is a `Call` of a function
//! or a `Glue` operation; the only exception is the `drop` of a value that
//! a step releases, which the spec keeps free of effects and capabilities.
//!
//! The IR is not in SSA form: locals are storage that statements write and
//! borrows point into, which is what move and borrow checking are about.
//! Code generation follows the same blocks, so the order the checks see is
//! the order the program runs in.

use std::collections::BTreeSet;

use crate::ast::{BinaryOperator, BorrowKind, Span, UnaryOperator};
use crate::typed::{Builtin, Callee, Intrinsic};
use crate::types::{Operation, Type, TypeKind, Types};

/// A program ready for code generation: every function is an instance
/// whose types are concrete.
pub(crate) struct Program {
    pub(crate) types: Types,
    pub(crate) functions: Vec<Instance>,
    pub(crate) main: usize,
}

/// A function with concrete types: a non-generic function, or a generic one
/// at one list of type arguments.
pub(crate) struct Instance {
    /// The name of the function it instantiates.
    pub(crate) name: String,
    /// That function, by its index among the checked functions.
    pub(crate) template: usize,
    pub(crate) body: Body,
}

pub(crate) type Local = usize;
pub(crate) type BlockId = usize;

#[derive(Clone)]
pub(crate) struct Body {
    /// The function's own locals first, with the indices the checker gave
    /// them, then the temporaries of lowering.
    pub(crate) locals: Vec<LocalDecl>,
    pub(crate) parameters: Vec<Local>,
    /// The local that holds the result when the function returns: a
    /// reference local for a borrowed result.
    pub(crate) result: Local,
    /// Block 0 is the entry.
    pub(crate) blocks: Vec<BasicBlock>,
}

#[derive(Clone)]
pub(crate) struct LocalDecl {
    pub(crate) name: String,
    pub(crate) ty: Type,
    /// A reference local holds a pointer to a place of type `ty`. A place
    /// rooted at it names that place.
    pub(crate) reference: Option<BorrowKind>,
    pub(crate) temporary: bool,
}

#[derive(Clone)]
pub(crate) struct BasicBlock {
    pub(crate) statements: Vec<Statement>,
    pub(crate) terminator: Terminator,
}

#[derive(Clone)]
pub(crate) struct Statement {
    pub(crate) kind: StatementKind,
    pub(crate) span: Span,
}

#[derive(Clone)]
pub(crate) enum StatementKind {
    /// Evaluates the right side and stores it in the place, releasing what
    /// an owning place held before. A place rooted at a reference local is
    /// the place it points at, so this writes through it. Storing the value
    /// of a key in a map adds the key if it is absent.
    Assign(Place, Rvalue),
    /// Makes the reference local point at the place the right side names:
    /// a `Ref` of a place, or a call that returns a borrow.
    Bind(Local, Rvalue),
    /// Moves the entity at each place into its local, as one step: the
    /// parts that one pattern binds, or that one `..base` takes. Moving a
    /// part of a variable counts as moving all of it, so the parts that one
    /// construct takes together are taken in one step.
    Unpack(Vec<(Local, Place)>),
    /// The local's scope ends: what it owns is released, and it holds
    /// nothing afterwards.
    Release(Local),
    /// Uses the reference local and does nothing else: the borrow it carries
    /// lasts at least until here. A `match` keeps its subject borrowed this
    /// way until it has chosen an arm, so a guard cannot change the subject.
    Keep(Local),
    /// Panics with `message` if every pair of operands is equal: the indices
    /// and keys of a borrowed place and of a place that a step is about to
    /// reach, where only their values tell whether the two are the same.
    /// Borrow checking puts it before that step. It is a cost the program
    /// pays at run time, and the only one of its kind.
    Distinct {
        pairs: Vec<(Operand, Operand)>,
        message: &'static str,
    },
}

#[derive(Clone)]
pub(crate) struct Terminator {
    pub(crate) kind: TerminatorKind,
    pub(crate) span: Span,
}

#[derive(Clone)]
pub(crate) enum TerminatorKind {
    Goto(BlockId),
    Branch {
        condition: Operand,
        then: BlockId,
        otherwise: BlockId,
    },
    /// Returns the result local.
    Return,
    /// Control never gets here: after a call that returns `Never`, or the
    /// end of a `match` that covers every value.
    Unreachable,
    /// A tail call of the function itself, as [`crate::tail`] finds them:
    /// takes the arguments as owned values, releases `releases`, and starts
    /// the function over with the arguments as its parameters.
    TailCall {
        arguments: Vec<Operand>,
        releases: Vec<Local>,
    },
}

/// A local and a path of parts inside it. A reference local stands for the
/// place it points at.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Place {
    pub(crate) local: Local,
    pub(crate) projections: Vec<Projection>,
}

impl Place {
    pub(crate) fn local(local: Local) -> Self {
        Self {
            local,
            projections: Vec::new(),
        }
    }

    pub(crate) fn project(&self, projection: Projection) -> Self {
        let mut place = self.clone();
        place.projections.push(projection);
        place
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Projection {
    /// A tuple element or struct field.
    Field(usize),
    /// A field of an enum value that holds the variant.
    VariantField { variant: usize, field: usize },
    /// A list element or map value at the index or key that the local
    /// holds.
    Index(Local),
    /// A list element, or the value of a map's `Int` key, at a constant
    /// index.
    ConstantIndex(i64),
    /// The element of a list, or the value of a map or the element of a set,
    /// at a position that the local holds. A map or set keeps its entries in
    /// insertion order, and the positions of removed entries stay until it
    /// grows; [`Rvalue::Occupied`] tells them apart.
    Position(Local),
}

#[derive(Clone, PartialEq)]
pub(crate) enum Operand {
    /// Copies the value at the place.
    Copy(Place),
    /// Looks at the entity at the place where it is, for a step that only
    /// reads it, such as a comparison or a search.
    Inspect(Place),
    /// Takes the entity out of the place, which holds nothing afterwards.
    Move(Place),
    /// The pointer that a reference local holds, passed on to a borrowed
    /// parameter.
    Borrowed(Local),
    Constant(Constant),
}

#[derive(Clone, PartialEq)]
pub(crate) enum Constant {
    Int(i64),
    Float(f64),
    Bool(bool),
    Str(String),
    Unit,
}

/// How a `Ref` borrows its place.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RefKind {
    Shared,
    Mutable,
    /// A `&mut` argument or receiver of a call, which is reserved while the
    /// later arguments are evaluated and takes effect when the call runs.
    MutableArgument,
}

#[derive(Clone)]
pub(crate) enum Rvalue {
    Use(Operand),
    /// A borrow of the place, which only a `Bind` holds.
    Ref(RefKind, Place),
    Unary(UnaryOperator, Operand),
    Binary(BinaryOperator, Operand, Operand),
    Tuple(Vec<Operand>),
    /// A struct (variant 0) or enum variant value of the assigned place's
    /// type, from its fields by declaration index.
    Construct {
        variant: usize,
        fields: Vec<(usize, Operand)>,
    },
    List(Vec<Operand>),
    /// `Map::new()` or `Set::new()`.
    EmptyMap,
    Range {
        start: Operand,
        end: Operand,
        inclusive: bool,
    },
    Interpolate(Vec<Operand>),
    /// The variant an enum value holds.
    Discriminant(Place),
    /// The number of positions of a container: a list's elements, or the
    /// entries of a map or set, removed ones included.
    Len(Place),
    /// Whether the position that a local holds is an entry of a map or set
    /// that has not been removed.
    Occupied {
        container: Place,
        position: Local,
    },
    /// A call. One that returns a borrow is only in a `Bind`, which makes
    /// the reference local point where the result points.
    Call {
        callee: Callee,
        /// The type arguments of a generic callee; instantiation makes the
        /// callee an instance and leaves this empty.
        type_arguments: Vec<Type>,
        arguments: Vec<Operand>,
        borrow: Option<BorrowKind>,
    },
    /// A comparison, clone or search that the compiler carries out for
    /// values of `ty`, by hand-written impls or through the parts of the
    /// values, as [`Types::glue`] describes. `operator` is the comparison
    /// operator of `Equal` and `Order`.
    Glue {
        operation: Operation,
        operator: Option<BinaryOperator>,
        ty: Type,
        operands: Vec<Operand>,
    },
    /// A built-in method. A receiver that the method changes is a reference
    /// local; one it reads only values of is the place itself. It runs no
    /// code the program wrote, other than the `drop` of what it releases.
    Builtin {
        builtin: Builtin,
        receiver: Place,
        arguments: Vec<Operand>,
    },
    Intrinsic {
        intrinsic: Intrinsic,
        arguments: Vec<Operand>,
    },
    /// Takes the element at a position out of a list or set that a loop
    /// took, or a map's entry as a `(key, value)` tuple.
    Take {
        container: Local,
        position: Local,
    },
}

impl Rvalue {
    /// Whether the rvalue is a borrow: a [`Rvalue::Ref`], or a call that
    /// returns one. Only a [`StatementKind::Bind`] holds a borrow.
    pub(crate) fn is_borrow(&self) -> bool {
        matches!(
            self,
            Self::Ref(..)
                | Self::Call {
                    borrow: Some(_),
                    ..
                }
        )
    }

    /// The operands the rvalue reads or takes.
    pub(crate) fn operands(&self) -> Vec<&Operand> {
        match self {
            Self::Use(operand) | Self::Unary(_, operand) => vec![operand],
            Self::Binary(_, left, right) => vec![left, right],
            Self::Tuple(operands)
            | Self::List(operands)
            | Self::Interpolate(operands)
            | Self::Call {
                arguments: operands,
                ..
            }
            | Self::Intrinsic {
                arguments: operands,
                ..
            }
            | Self::Builtin {
                arguments: operands,
                ..
            }
            | Self::Glue { operands, .. } => operands.iter().collect(),
            Self::Construct { fields, .. } => fields.iter().map(|(_, operand)| operand).collect(),
            Self::Range { start, end, .. } => vec![start, end],
            Self::Ref(..)
            | Self::EmptyMap
            | Self::Discriminant(_)
            | Self::Len(_)
            | Self::Occupied { .. }
            | Self::Take { .. } => Vec::new(),
        }
    }
}

/// A run-time check that borrow checking asks for before statement `index`
/// of `block`, as a [`StatementKind::Distinct`].
#[derive(PartialEq)]
pub(crate) struct Check {
    pub(crate) block: BlockId,
    pub(crate) index: usize,
    pub(crate) pairs: Vec<(Operand, Operand)>,
    pub(crate) message: &'static str,
}

impl Body {
    /// Puts each check before the statement it is for.
    pub(crate) fn insert_checks(&mut self, mut checks: Vec<Check>) {
        // From the last, so the positions of the others stay.
        checks.sort_by_key(|check| std::cmp::Reverse((check.block, check.index)));
        for check in checks {
            let statements = &mut self.blocks[check.block].statements;
            let span = statements[check.index].span;
            statements.insert(
                check.index,
                Statement {
                    kind: StatementKind::Distinct {
                        pairs: check.pairs,
                        message: check.message,
                    },
                    span,
                },
            );
        }
    }

    pub(crate) fn new_block(&mut self) -> BlockId {
        self.blocks.push(BasicBlock {
            statements: Vec::new(),
            terminator: Terminator {
                kind: TerminatorKind::Unreachable,
                span: Span::new(0, 0),
            },
        });
        self.blocks.len() - 1
    }

    /// The blocks that control can go to after `block`.
    pub(crate) fn successors(&self, block: BlockId) -> Vec<BlockId> {
        match &self.blocks[block].terminator.kind {
            TerminatorKind::Goto(target) => vec![*target],
            TerminatorKind::Branch {
                then, otherwise, ..
            } => vec![*then, *otherwise],
            // A tail call starts the function over, as a new run of it.
            TerminatorKind::Return
            | TerminatorKind::Unreachable
            | TerminatorKind::TailCall { .. } => Vec::new(),
        }
    }

    /// The reachable blocks in reverse postorder.
    pub(crate) fn reverse_postorder(&self) -> Vec<BlockId> {
        let mut visited = vec![false; self.blocks.len()];
        let mut postorder = Vec::new();
        // An explicit stack, so deep nesting cannot overflow.
        let mut stack = vec![(0, 0)];
        visited[0] = true;
        while let Some((block, next)) = stack.pop() {
            if let Some(&successor) = self.successors(block).get(next) {
                stack.push((block, next + 1));
                if !visited[successor] {
                    visited[successor] = true;
                    stack.push((successor, 0));
                }
            } else {
                postorder.push(block);
            }
        }
        postorder.reverse();
        postorder
    }

    /// Whether `local` owns what it holds, which must be released.
    pub(crate) fn owns(&self, types: &Types, local: Local) -> bool {
        self.locals[local].reference.is_none() && types.needs_release(self.locals[local].ty)
    }

    /// The owning locals that may hold something at the start of each
    /// reachable block.
    pub(crate) fn maybe_filled(&self, types: &Types) -> Vec<BTreeSet<Local>> {
        let mut starts: Vec<Option<BTreeSet<Local>>> = vec![None; self.blocks.len()];
        starts[0] = Some(
            self.parameters
                .iter()
                .copied()
                .filter(|&local| self.owns(types, local))
                .collect(),
        );
        let mut work = vec![0];
        while let Some(block) = work.pop() {
            let mut filled = starts[block].clone().unwrap_or_default();
            for statement in &self.blocks[block].statements {
                self.fill(types, &statement.kind, &mut filled);
            }
            for successor in self.successors(block) {
                let changed = match &mut starts[successor] {
                    Some(start) => {
                        let before = start.len();
                        start.extend(filled.iter().copied());
                        start.len() != before
                    }
                    start @ None => {
                        *start = Some(filled.clone());
                        true
                    }
                };
                if changed {
                    work.push(successor);
                }
            }
        }
        starts.into_iter().map(Option::unwrap_or_default).collect()
    }

    /// Updates the owning locals that may hold something after `statement`:
    /// a move out of a whole local empties it, `Release` empties it, and an
    /// assignment to an owning local fills it.
    pub(crate) fn fill(
        &self,
        types: &Types,
        statement: &StatementKind,
        filled: &mut BTreeSet<Local>,
    ) {
        let (destination, value) = match statement {
            StatementKind::Assign(destination, value) => (Some(destination), value),
            StatementKind::Bind(_, value) => (None, value),
            StatementKind::Release(local) => {
                filled.remove(local);
                return;
            }
            StatementKind::Distinct { .. } | StatementKind::Keep(_) => return,
            // Only parts are taken, so the variables may still hold the rest.
            StatementKind::Unpack(moves) => {
                for (local, _) in moves {
                    if self.owns(types, *local) {
                        filled.insert(*local);
                    }
                }
                return;
            }
        };
        for operand in value.operands() {
            if let Operand::Move(place) = operand
                && place.projections.is_empty()
            {
                filled.remove(&place.local);
            }
        }
        if let Some(destination) = destination
            && self.owns(types, destination.local)
        {
            filled.insert(destination.local);
        }
    }

    /// If `place` is the value of a key in a map, the key's projection and
    /// the map's place. Storing there may add the key, which changes the
    /// map.
    pub(crate) fn map_entry(&self, types: &Types, place: &Place) -> Option<(Projection, Place)> {
        let (last, prefix) = place.projections.split_last()?;
        if !matches!(last, Projection::Index(_) | Projection::ConstantIndex(_)) {
            return None;
        }
        let map = Place {
            local: place.local,
            projections: prefix.to_vec(),
        };
        matches!(types.kind(self.place_type(types, &map)), TypeKind::Map(..))
            .then_some((*last, map))
    }

    /// The type of the value at `place`.
    pub(crate) fn place_type(&self, types: &Types, place: &Place) -> Type {
        place
            .projections
            .iter()
            .fold(self.locals[place.local].ty, |ty, projection| {
                projection_type(types, ty, projection).expect("each step of a place fits its type")
            })
    }

    /// The type of the value `operand` gives.
    pub(crate) fn operand_type(&self, types: &Types, operand: &Operand) -> Type {
        match operand {
            Operand::Copy(place) | Operand::Inspect(place) | Operand::Move(place) => {
                self.place_type(types, place)
            }
            Operand::Borrowed(reference) => self.locals[*reference].ty,
            Operand::Constant(constant) => constant.ty(),
        }
    }
}

impl Constant {
    pub(crate) fn ty(&self) -> Type {
        match self {
            Self::Int(_) => Type::INT,
            Self::Float(_) => Type::FLOAT,
            Self::Bool(_) => Type::BOOL,
            Self::Str(_) => Type::STR,
            Self::Unit => Type::UNIT,
        }
    }
}

/// The types of the fields of a `Range`: its start, its end, and whether it
/// includes the end.
pub(crate) const RANGE_FIELDS: [Type; 3] = [Type::INT, Type::INT, Type::BOOL];

/// The type of the part that `projection` reaches in a value of type `ty`,
/// or `None` if a value of that type has no such part.
pub(crate) fn projection_type(types: &Types, ty: Type, projection: &Projection) -> Option<Type> {
    match (projection, types.kind(ty)) {
        (Projection::Field(index), TypeKind::Range) => RANGE_FIELDS.get(*index).copied(),
        (Projection::Field(index), TypeKind::Tuple(_) | TypeKind::Nominal { .. })
            if !types.is_enum(ty) =>
        {
            types.components(ty).get(*index).copied()
        }
        (Projection::VariantField { variant, field }, TypeKind::Nominal { .. })
            if types.is_enum(ty) =>
        {
            let fields = &types.variants(ty).get(*variant)?.fields;
            fields.get(*field).map(|field| field.ty)
        }
        (
            Projection::Index(_) | Projection::ConstantIndex(_),
            TypeKind::List(element) | TypeKind::Map(_, element),
        )
        | (
            Projection::Position(_),
            TypeKind::List(element) | TypeKind::Map(_, element) | TypeKind::Set(element),
        ) => Some(*element),
        _ => None,
    }
}

/// The type of the elements of a list or set, or of the values of a map.
pub(crate) fn element_type(types: &Types, container: Type) -> Type {
    match types.kind(container) {
        TypeKind::List(element) | TypeKind::Set(element) | TypeKind::Map(_, element) => *element,
        _ => unreachable!("only containers have elements"),
    }
}
