//! The mid-level IR.
//!
//! Each function is a control-flow graph of basic blocks. A block runs its
//! statements in order and ends in one terminator that says where control
//! goes. Every step names the places it reads and writes, every temporary
//! is a local, and every borrow is an explicit `Ref` stored in a reference
//! local. Branches of `if`, `match`, `&&`, `||`, guards and loops are edges,
//! so an analysis that follows the edges covers every construct alike.
//!
//! The IR is not in SSA form: locals are storage that statements write and
//! borrows point into, which is what move and borrow checking are about.
//! Code generation follows the same blocks, so the order the checks see is
//! the order the program runs in.

use crate::ast::{BinaryOperator, BorrowKind, Span, UnaryOperator};
use crate::checker::{Builtin, Callee, Intrinsic};
use crate::types::{Type, TypeKind, Types};

pub(crate) type Local = usize;
pub(crate) type BlockId = usize;

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

pub(crate) struct LocalDecl {
    pub(crate) name: String,
    pub(crate) ty: Type,
    /// A reference local holds a pointer to a place of type `ty`. A place
    /// rooted at it names that place.
    pub(crate) reference: Option<BorrowKind>,
    pub(crate) temporary: bool,
}

pub(crate) struct BasicBlock {
    pub(crate) statements: Vec<Statement>,
    pub(crate) terminator: Terminator,
}

pub(crate) struct Statement {
    pub(crate) kind: StatementKind,
    pub(crate) span: Span,
}

pub(crate) enum StatementKind {
    /// Evaluates the right side and stores it in the place, releasing what
    /// an owning place held before. Storing the value of a key in a map
    /// adds the key if it is absent.
    Assign(Place, Rvalue),
    /// The local's scope ends: what it owns is released, and it holds
    /// nothing afterwards.
    Release(Local),
}

pub(crate) struct Terminator {
    pub(crate) kind: TerminatorKind,
    pub(crate) span: Span,
}

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

#[derive(Clone)]
pub(crate) enum Operand {
    /// Reads the place: copies a value, and reads an entity where it is.
    Copy(Place),
    /// Takes the entity out of the place, which holds nothing afterwards.
    Move(Place),
    /// The pointer that a reference local holds, passed on to a borrowed
    /// parameter.
    Borrowed(Local),
    Constant(Constant),
}

#[derive(Clone)]
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

pub(crate) enum Rvalue {
    Use(Operand),
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
    /// A call. One that returns a borrow is stored in a reference local,
    /// which then points where the result points.
    Call {
        callee: Callee,
        arguments: Vec<Operand>,
        borrow: Option<BorrowKind>,
    },
    /// A built-in method. A receiver that the method changes, or an entity
    /// it clones, is a reference local; one it reads only values of is the
    /// place itself.
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

impl Body {
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
            TerminatorKind::Return | TerminatorKind::Unreachable => Vec::new(),
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

    /// Whether assigning `value` to `destination` makes a reference local
    /// point somewhere, rather than write where it points.
    pub(crate) fn defines_pointer(&self, destination: &Place, value: &Rvalue) -> bool {
        destination.projections.is_empty()
            && self.locals[destination.local].reference.is_some()
            && matches!(
                value,
                Rvalue::Ref(..)
                    | Rvalue::Call {
                        borrow: Some(_),
                        ..
                    }
            )
    }

    /// The type of the value at `place`.
    pub(crate) fn place_type(&self, types: &Types, place: &Place) -> Type {
        let mut ty = self.locals[place.local].ty;
        for projection in &place.projections {
            ty = match projection {
                Projection::Field(index) => match types.kind(ty) {
                    TypeKind::Range => [Type::INT, Type::INT, Type::BOOL][*index],
                    _ => types.components(ty)[*index],
                },
                Projection::VariantField { variant, field } => {
                    types.variants(ty)[*variant].fields[*field].ty
                }
                Projection::Index(_) | Projection::ConstantIndex(_) | Projection::Position(_) => {
                    element_type(types, ty)
                }
            };
        }
        ty
    }
}

/// The type of the elements of a list or set, or of the values of a map.
pub(crate) fn element_type(types: &Types, container: Type) -> Type {
    match types.kind(container) {
        TypeKind::List(element) | TypeKind::Set(element) | TypeKind::Map(_, element) => *element,
        _ => unreachable!("only containers have elements"),
    }
}
