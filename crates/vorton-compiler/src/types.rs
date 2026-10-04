//! The checker's type table.
//!
//! Every type is interned once and named by a [`Type`] index, so the checker
//! and code generation compare types by index and never rebuild them from
//! source spellings.

use std::collections::HashMap;

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

/// The hand-written comparison impls of a type: the function of each
/// method, which instantiation renumbers to its instance.
#[derive(Debug, Default, Clone)]
pub(crate) struct ComparisonImpls {
    pub(crate) eq: Option<usize>,
    /// `impl Eq`, which has no method.
    pub(crate) total_eq: bool,
    pub(crate) partial_cmp: Option<usize>,
    pub(crate) cmp: Option<usize>,
}

pub(crate) struct Types {
    kinds: Vec<TypeKind>,
    /// Whether each type mentions a type parameter.
    generic: Vec<bool>,
    lookup: HashMap<TypeKind, Type>,
    pub(crate) nominals: Vec<NominalInfo>,
    shapes: HashMap<Type, Vec<Variant>>,
    pub(crate) comparisons: HashMap<Type, ComparisonImpls>,
}

impl Types {
    pub(crate) fn new() -> Self {
        let mut types = Self {
            kinds: Vec::new(),
            generic: Vec::new(),
            lookup: HashMap::new(),
            nominals: Vec::new(),
            shapes: HashMap::new(),
            comparisons: HashMap::new(),
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
        match self.kind(ty) {
            TypeKind::Str
            | TypeKind::List(_)
            | TypeKind::Map(..)
            | TypeKind::Set(_)
            | TypeKind::Param { .. } => true,
            TypeKind::Tuple(_) | TypeKind::Nominal { .. } => self
                .components(ty)
                .into_iter()
                .any(|component| self.needs_release(component)),
            TypeKind::Int
            | TypeKind::Float
            | TypeKind::Bool
            | TypeKind::Unit
            | TypeKind::Never
            | TypeKind::Range => false,
        }
    }

    /// Whether `ty` is an entity: it has identity and is moved, never copied.
    pub(crate) fn is_entity(&self, ty: Type) -> bool {
        match self.kind(ty) {
            TypeKind::List(_) | TypeKind::Map(..) | TypeKind::Set(_) => true,
            TypeKind::Param { copy, .. } => !copy,
            TypeKind::Tuple(_) | TypeKind::Nominal { .. } => self
                .components(ty)
                .into_iter()
                .any(|component| self.is_entity(component)),
            TypeKind::Int
            | TypeKind::Float
            | TypeKind::Bool
            | TypeKind::Str
            | TypeKind::Unit
            | TypeKind::Never
            | TypeKind::Range => false,
        }
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
    pub(crate) fn compares(
        &self,
        ty: Type,
        comparison: Comparison,
        param: &dyn Fn(usize) -> bool,
    ) -> bool {
        self.compares_in(ty, comparison, param, &mut Vec::new())
    }

    /// `pending` holds the types whose answer is being worked out further up;
    /// meeting one again, through a list, assumes the answer is yes, which is
    /// the greatest fixed point the spec asks for recursive types.
    fn compares_in(
        &self,
        ty: Type,
        comparison: Comparison,
        param: &dyn Fn(usize) -> bool,
        pending: &mut Vec<Type>,
    ) -> bool {
        if let Some(written) = self.comparisons.get(&ty) {
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
                return own;
            }
        }
        let ordered = matches!(comparison, Comparison::PartialOrd | Comparison::Ord);
        let total = matches!(comparison, Comparison::Eq | Comparison::Ord);
        match self.kind(ty) {
            TypeKind::Int | TypeKind::Bool | TypeKind::Str | TypeKind::Unit => true,
            TypeKind::Float => !total,
            TypeKind::Param { index, .. } => param(*index),
            TypeKind::Never | TypeKind::Map(..) | TypeKind::Set(_) | TypeKind::Range => false,
            TypeKind::List(element) => {
                !ordered && self.compares_in(*element, comparison, param, pending)
            }
            TypeKind::Tuple(_) | TypeKind::Nominal { .. } => {
                if pending.contains(&ty) {
                    return true;
                }
                pending.push(ty);
                let result = self
                    .components(ty)
                    .into_iter()
                    .all(|component| self.compares_in(component, comparison, param, pending));
                pending.pop();
                result
            }
        }
    }

    /// Whether `ty` can be a map key: a value compared with `==` that has
    /// no `Float` in it and no hand-written `PartialEq`, so its structural
    /// hash agrees with its equality.
    pub(crate) fn is_key(&self, ty: Type) -> bool {
        if self
            .comparisons
            .get(&ty)
            .is_some_and(|written| written.eq.is_some())
        {
            return false;
        }
        match self.kind(ty) {
            TypeKind::Int | TypeKind::Bool | TypeKind::Str => true,
            // A `Unit` part adds nothing to a key, but `Unit` alone is no key.
            TypeKind::Tuple(_) | TypeKind::Nominal { .. } => self
                .components(ty)
                .into_iter()
                .all(|component| component == Type::UNIT || self.is_key(component)),
            TypeKind::Float
            | TypeKind::Unit
            | TypeKind::Never
            | TypeKind::List(_)
            | TypeKind::Map(..)
            | TypeKind::Set(_)
            | TypeKind::Range
            | TypeKind::Param { .. } => false,
        }
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
