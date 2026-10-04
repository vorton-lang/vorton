//! The checker's type table.
//!
//! Every type is interned once and named by a [`Type`] index, so the checker
//! and code generation compare types by index and never rebuild them from
//! source spellings.

use std::collections::{HashMap, HashSet};

/// An interned type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct Type(u32);

impl Type {
    pub(crate) const INT: Self = Self(0);
    pub(crate) const FLOAT: Self = Self(1);
    pub(crate) const BOOL: Self = Self(2);
    pub(crate) const STR: Self = Self(3);
    pub(crate) const UNIT: Self = Self(4);
    pub(crate) const NEVER: Self = Self(5);

    pub(crate) fn index(self) -> usize {
        self.0 as usize
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum TypeKind {
    Int,
    Float,
    Bool,
    Str,
    Unit,
    Never,
    Tuple(Vec<Type>),
    /// A growable list that owns its elements; an entity.
    List(Type),
    /// A map from keys to values in insertion order; an entity.
    Map(Type, Type),
    /// A set of keys in insertion order; an entity.
    Set(Type),
    /// `Range<Int>`, the value of `start..end` or `start..=end`.
    Range,
    /// A struct or enum declaration, by its index in [`Types::nominals`],
    /// applied to type arguments.
    Nominal {
        declaration: usize,
        arguments: Vec<Type>,
    },
    /// The type parameter at `index` of the generic function being checked.
    /// A `Copy` bound makes it a value; without one it is an entity. Code
    /// generation sees only the types that replace it.
    Param {
        index: usize,
        name: String,
        copy: bool,
    },
}

/// What [`Types::search`] does with one type.
enum Search {
    Found,
    /// Nothing here, and nothing to look at inside.
    Leaf,
    /// Look at these types next.
    Into(Vec<Type>),
}

pub(crate) struct NominalInfo {
    pub(crate) name: String,
    pub(crate) is_enum: bool,
}

/// One way to build a nominal value. A struct has exactly one variant.
pub(crate) struct Variant {
    pub(crate) name: String,
    pub(crate) fields: Vec<Field>,
}

pub(crate) struct Field {
    pub(crate) name: String,
    pub(crate) ty: Type,
}

/// The comparison traits, which the compiler implements field by field for
/// a type without a hand-written impl.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Comparison {
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
}

/// The hand-written impls of core traits that change how the compiler
/// treats a type: the function of each method, which instantiation
/// renumbers to its instance.
#[derive(Debug, Default, Clone)]
pub(crate) struct WrittenImpls {
    pub(crate) eq: Option<usize>,
    /// `impl Eq`, which has no method.
    pub(crate) total_eq: bool,
    pub(crate) partial_cmp: Option<usize>,
    pub(crate) cmp: Option<usize>,
    pub(crate) clone: Option<usize>,
    pub(crate) drop: Option<usize>,
}

impl WrittenImpls {
    /// The functions of the written methods, to renumber them.
    pub(crate) fn functions(&mut self) -> impl Iterator<Item = &mut usize> {
        [
            &mut self.eq,
            &mut self.partial_cmp,
            &mut self.cmp,
            &mut self.clone,
            &mut self.drop,
        ]
        .into_iter()
        .flatten()
    }
}

pub(crate) struct Types {
    kinds: Vec<TypeKind>,
    /// Whether each type mentions a type parameter.
    generic: Vec<bool>,
    lookup: HashMap<TypeKind, Type>,
    pub(crate) nominals: Vec<NominalInfo>,
    shapes: HashMap<Type, Vec<Variant>>,
    /// The hand-written impls of core traits, by type.
    pub(crate) written: HashMap<Type, WrittenImpls>,
}

impl Types {
    pub(crate) fn new() -> Self {
        let mut types = Self {
            kinds: Vec::new(),
            generic: Vec::new(),
            lookup: HashMap::new(),
            nominals: Vec::new(),
            shapes: HashMap::new(),
            written: HashMap::new(),
        };
        for kind in [
            TypeKind::Int,
            TypeKind::Float,
            TypeKind::Bool,
            TypeKind::Str,
            TypeKind::Unit,
            TypeKind::Never,
        ] {
            types.intern(kind);
        }
        types
    }

    /// Returns the type for `kind` and whether it was interned just now.
    pub(crate) fn intern_new(&mut self, kind: TypeKind) -> (Type, bool) {
        if let Some(&ty) = self.lookup.get(&kind) {
            return (ty, false);
        }
        let ty = Type(u32::try_from(self.kinds.len()).expect("fewer than 2^32 types"));
        let generic = match &kind {
            TypeKind::Param { .. } => true,
            TypeKind::Tuple(parts)
            | TypeKind::Nominal {
                arguments: parts, ..
            } => parts.iter().any(|part| self.is_generic(*part)),
            TypeKind::List(element) | TypeKind::Set(element) => self.is_generic(*element),
            TypeKind::Map(key, value) => self.is_generic(*key) || self.is_generic(*value),
            TypeKind::Int
            | TypeKind::Float
            | TypeKind::Bool
            | TypeKind::Str
            | TypeKind::Unit
            | TypeKind::Never
            | TypeKind::Range => false,
        };
        self.kinds.push(kind.clone());
        self.generic.push(generic);
        self.lookup.insert(kind, ty);
        (ty, true)
    }

    /// Whether `ty` mentions a type parameter, so only its instances reach
    /// code generation.
    pub(crate) fn is_generic(&self, ty: Type) -> bool {
        self.generic[ty.index()]
    }

    /// Whether `ty` mentions the type parameter at `index`.
    pub(crate) fn mentions_param(&self, ty: Type, index: usize) -> bool {
        if !self.is_generic(ty) {
            return false;
        }
        match self.kind(ty) {
            TypeKind::Param { index: param, .. } => *param == index,
            TypeKind::Tuple(parts)
            | TypeKind::Nominal {
                arguments: parts, ..
            } => parts.iter().any(|part| self.mentions_param(*part, index)),
            TypeKind::List(element) | TypeKind::Set(element) => {
                self.mentions_param(*element, index)
            }
            TypeKind::Map(key, value) => {
                self.mentions_param(*key, index) || self.mentions_param(*value, index)
            }
            _ => false,
        }
    }

    pub(crate) fn intern(&mut self, kind: TypeKind) -> Type {
        self.intern_new(kind).0
    }

    pub(crate) fn kind(&self, ty: Type) -> &TypeKind {
        &self.kinds[ty.index()]
    }

    pub(crate) fn len(&self) -> usize {
        self.kinds.len()
    }

    /// Every interned type, in interning order.
    pub(crate) fn all(&self) -> impl Iterator<Item = Type> + use<> {
        (0..u32::try_from(self.kinds.len()).expect("fewer than 2^32 types")).map(Type)
    }

    pub(crate) fn set_variants(&mut self, ty: Type, variants: Vec<Variant>) {
        self.shapes.insert(ty, variants);
    }

    /// The variants of a nominal type; empty for other types.
    pub(crate) fn variants(&self, ty: Type) -> &[Variant] {
        self.shapes.get(&ty).map_or(&[], Vec::as_slice)
    }

    pub(crate) fn is_enum(&self, ty: Type) -> bool {
        matches!(self.kind(ty), TypeKind::Nominal { declaration, .. } if self.nominals[*declaration].is_enum)
    }

    pub(crate) fn is_struct(&self, ty: Type) -> bool {
        matches!(self.kind(ty), TypeKind::Nominal { declaration, .. } if !self.nominals[*declaration].is_enum)
    }

    /// The fields of a struct type.
    pub(crate) fn struct_fields(&self, ty: Type) -> &[Field] {
        if self.is_struct(ty) {
            self.variants(ty)
                .first()
                .map_or(&[], |variant| &variant.fields)
        } else {
            &[]
        }
    }

    pub(crate) fn name(&self, ty: Type) -> String {
        match self.kind(ty) {
            TypeKind::Int => "Int".to_owned(),
            TypeKind::Float => "Float".to_owned(),
            TypeKind::Bool => "Bool".to_owned(),
            TypeKind::Str => "Str".to_owned(),
            TypeKind::Unit => "Unit".to_owned(),
            TypeKind::Never => "Never".to_owned(),
            TypeKind::Tuple(elements) => format!("({})", self.names(elements)),
            TypeKind::List(element) => format!("List<{}>", self.name(*element)),
            TypeKind::Map(key, value) => format!("Map<{}, {}>", self.name(*key), self.name(*value)),
            TypeKind::Range => "Range<Int>".to_owned(),
            TypeKind::Set(element) => format!("Set<{}>", self.name(*element)),
            TypeKind::Nominal {
                declaration,
                arguments,
            } => {
                let name = &self.nominals[*declaration].name;
                if arguments.is_empty() {
                    name.clone()
                } else {
                    format!("{name}<{}>", self.names(arguments))
                }
            }
            TypeKind::Param { name, .. } => name.clone(),
        }
    }

    fn names(&self, types: &[Type]) -> String {
        types
            .iter()
            .map(|ty| self.name(*ty))
            .collect::<Vec<_>>()
            .join(", ")
    }

    /// Whether values of `ty` occupy storage. `Unit` and `Never` do not.
    pub(crate) fn has_storage(&self, ty: Type) -> bool {
        !matches!(self.kind(ty), TypeKind::Unit | TypeKind::Never)
    }

    /// Whether an owned value of `ty` must be released: it holds a counted
    /// `Str` or owns heap storage.
    pub(crate) fn needs_release(&self, ty: Type) -> bool {
        self.search(ty, |ty| {
            if self.has_drop(ty) {
                return Search::Found;
            }
            match self.kind(ty) {
                TypeKind::Str
                | TypeKind::List(_)
                | TypeKind::Map(..)
                | TypeKind::Set(_)
                | TypeKind::Param { .. } => Search::Found,
                TypeKind::Tuple(_) | TypeKind::Nominal { .. } => Search::Into(self.components(ty)),
                TypeKind::Int
                | TypeKind::Float
                | TypeKind::Bool
                | TypeKind::Unit
                | TypeKind::Never
                | TypeKind::Range => Search::Leaf,
            }
        })
    }

    /// Whether releasing a value of `ty` can run a hand-written `drop`: the
    /// type or a type stored in it, by value or in a container, has one.
    pub(crate) fn runs_drop(&self, ty: Type) -> bool {
        self.search(ty, |ty| {
            if self.has_drop(ty) {
                return Search::Found;
            }
            Search::Into(match self.kind(ty) {
                TypeKind::List(element) | TypeKind::Set(element) => vec![*element],
                TypeKind::Map(key, value) => vec![*key, *value],
                _ => self.components(ty),
            })
        })
    }

    /// Whether `ty` has a hand-written `Drop`.
    pub(crate) fn has_drop(&self, ty: Type) -> bool {
        self.written
            .get(&ty)
            .is_some_and(|written| written.drop.is_some())
    }

    /// Whether `ty` is an entity: it has identity and is moved, never copied.
    pub(crate) fn is_entity(&self, ty: Type) -> bool {
        self.search(ty, |ty| {
            if self.has_drop(ty) {
                return Search::Found;
            }
            match self.kind(ty) {
                TypeKind::List(_) | TypeKind::Map(..) | TypeKind::Set(_) => Search::Found,
                TypeKind::Param { copy: false, .. } => Search::Found,
                TypeKind::Tuple(_) | TypeKind::Nominal { .. } => Search::Into(self.components(ty)),
                TypeKind::Param { copy: true, .. }
                | TypeKind::Int
                | TypeKind::Float
                | TypeKind::Bool
                | TypeKind::Str
                | TypeKind::Unit
                | TypeKind::Never
                | TypeKind::Range => Search::Leaf,
            }
        })
    }

    /// Whether `==` applies to a type without type parameters.
    pub(crate) fn has_equality(&self, ty: Type) -> bool {
        self.compares(ty, Comparison::PartialEq, &|_| false)
    }

    /// Whether `<`, `>`, `<=` and `>=` apply to a type without type
    /// parameters.
    pub(crate) fn has_order(&self, ty: Type) -> bool {
        self.compares(ty, Comparison::PartialOrd, &|_| false)
    }

    /// Whether `ty` implements `comparison`: by a hand-written impl, or by
    /// the compiler when all its parts do. The compiler's impl of a trait is
    /// absent when the type has a hand-written impl that the trait must
    /// agree with: `PartialEq` for all four, and `PartialOrd` for `Ord`.
    /// `param` tells whether the type parameter at an index has the trait.
    ///
    /// A recursive type compares when nothing along its parts rules it out,
    /// the greatest fixed point the spec asks for: the answer is yes unless
    /// some type reachable through parts that the compiler compares fails on
    /// its own.
    pub(crate) fn compares(
        &self,
        ty: Type,
        comparison: Comparison,
        param: &dyn Fn(usize) -> bool,
    ) -> bool {
        let ordered = matches!(comparison, Comparison::PartialOrd | Comparison::Ord);
        let total = matches!(comparison, Comparison::Eq | Comparison::Ord);
        let fails = |fails: bool| if fails { Search::Found } else { Search::Leaf };
        !self.search(ty, |ty| {
            if let Some(written) = self.written.get(&ty) {
                let (own, overriding) = match comparison {
                    Comparison::PartialEq => (written.eq.is_some(), false),
                    Comparison::Eq => (written.total_eq, written.eq.is_some()),
                    Comparison::PartialOrd => (written.partial_cmp.is_some(), written.eq.is_some()),
                    Comparison::Ord => (
                        written.cmp.is_some(),
                        written.eq.is_some() || written.partial_cmp.is_some(),
                    ),
                };
                if own || overriding {
                    return fails(!own);
                }
            }
            match self.kind(ty) {
                TypeKind::Int | TypeKind::Bool | TypeKind::Str | TypeKind::Unit => Search::Leaf,
                TypeKind::Float => fails(total),
                TypeKind::Param { index, .. } => fails(!param(*index)),
                TypeKind::Never | TypeKind::Map(..) | TypeKind::Set(_) | TypeKind::Range => {
                    Search::Found
                }
                TypeKind::List(_) if ordered => Search::Found,
                TypeKind::List(element) => Search::Into(vec![*element]),
                TypeKind::Tuple(_) | TypeKind::Nominal { .. } => Search::Into(self.components(ty)),
            }
        })
    }

    /// Whether `ty` can be a map key: a value compared with `==` that has
    /// no `Float` in it and no hand-written `PartialEq`, so its structural
    /// hash agrees with its equality. A `Unit` part adds nothing to a key,
    /// but `Unit` alone is no key.
    pub(crate) fn is_key(&self, ty: Type) -> bool {
        ty != Type::UNIT
            && !self.search(ty, |ty| {
                let written = self.written.get(&ty);
                if written.is_some_and(|written| written.eq.is_some() || written.drop.is_some()) {
                    return Search::Found;
                }
                match self.kind(ty) {
                    TypeKind::Int | TypeKind::Bool | TypeKind::Str | TypeKind::Unit => Search::Leaf,
                    TypeKind::Tuple(_) | TypeKind::Nominal { .. } => {
                        Search::Into(self.components(ty))
                    }
                    TypeKind::Float
                    | TypeKind::Never
                    | TypeKind::List(_)
                    | TypeKind::Map(..)
                    | TypeKind::Set(_)
                    | TypeKind::Range
                    | TypeKind::Param { .. } => Search::Found,
                }
            })
    }

    /// Whether `step` finds something among the types it reaches from `ty`.
    /// Each type is looked at once, so the time is in proportion to the
    /// number of types, however often they are shared or recur.
    fn search(&self, ty: Type, mut step: impl FnMut(Type) -> Search) -> bool {
        let mut seen = HashSet::new();
        let mut pending = vec![ty];
        while let Some(ty) = pending.pop() {
            if !seen.insert(ty) {
                continue;
            }
            match step(ty) {
                Search::Found => return true,
                Search::Leaf => {}
                Search::Into(next) => pending.extend(next),
            }
        }
        false
    }

    /// The types stored inside `ty` by value: tuple elements, or the fields
    /// of every variant. Container contents live on the heap and are not
    /// included.
    pub(crate) fn components(&self, ty: Type) -> Vec<Type> {
        match self.kind(ty) {
            TypeKind::Tuple(elements) => elements.clone(),
            TypeKind::Nominal { .. } => self
                .variants(ty)
                .iter()
                .flat_map(|variant| variant.fields.iter().map(|field| field.ty))
                .collect(),
            _ => Vec::new(),
        }
    }
}
