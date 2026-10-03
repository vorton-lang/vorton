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
    /// A struct or enum declaration, by its index in [`Types::nominals`],
    /// applied to type arguments.
    Nominal {
        declaration: usize,
        arguments: Vec<Type>,
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

pub(crate) struct Types {
    kinds: Vec<TypeKind>,
    lookup: HashMap<TypeKind, Type>,
    pub(crate) nominals: Vec<NominalInfo>,
    shapes: HashMap<Type, Vec<Variant>>,
}

impl Types {
    pub(crate) fn new() -> Self {
        let mut types = Self {
            kinds: Vec::new(),
            lookup: HashMap::new(),
            nominals: Vec::new(),
            shapes: HashMap::new(),
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
        self.kinds.push(kind.clone());
        self.lookup.insert(kind, ty);
        (ty, true)
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
            TypeKind::Str | TypeKind::List(_) | TypeKind::Map(..) => true,
            TypeKind::Tuple(_) | TypeKind::Nominal { .. } => self
                .components(ty)
                .into_iter()
                .any(|component| self.needs_release(component)),
            TypeKind::Int | TypeKind::Float | TypeKind::Bool | TypeKind::Unit | TypeKind::Never => {
                false
            }
        }
    }

    /// Whether `ty` is an entity: it has identity and is moved, never copied.
    pub(crate) fn is_entity(&self, ty: Type) -> bool {
        match self.kind(ty) {
            TypeKind::List(_) | TypeKind::Map(..) => true,
            TypeKind::Tuple(_) | TypeKind::Nominal { .. } => self
                .components(ty)
                .into_iter()
                .any(|component| self.is_entity(component)),
            TypeKind::Int
            | TypeKind::Float
            | TypeKind::Bool
            | TypeKind::Str
            | TypeKind::Unit
            | TypeKind::Never => false,
        }
    }

    /// Whether `ty` can be a map key: a value compared with `==` that has
    /// no `Float` in it.
    pub(crate) fn is_key(&self, ty: Type) -> bool {
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
            | TypeKind::Map(..) => false,
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
