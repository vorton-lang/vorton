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
    /// A struct declaration, by its index in [`Types::structs`].
    Struct(usize),
}

pub(crate) struct StructInfo {
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
    pub(crate) structs: Vec<StructInfo>,
}

impl Types {
    pub(crate) fn new() -> Self {
        let mut types = Self {
            kinds: Vec::new(),
            lookup: HashMap::new(),
            structs: Vec::new(),
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

    pub(crate) fn intern(&mut self, kind: TypeKind) -> Type {
        if let Some(&ty) = self.lookup.get(&kind) {
            return ty;
        }
        let ty = Type(u32::try_from(self.kinds.len()).expect("fewer than 2^32 types"));
        self.kinds.push(kind.clone());
        self.lookup.insert(kind, ty);
        ty
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

    pub(crate) fn name(&self, ty: Type) -> String {
        match self.kind(ty) {
            TypeKind::Int => "Int".to_owned(),
            TypeKind::Float => "Float".to_owned(),
            TypeKind::Bool => "Bool".to_owned(),
            TypeKind::Str => "Str".to_owned(),
            TypeKind::Unit => "Unit".to_owned(),
            TypeKind::Never => "Never".to_owned(),
            TypeKind::Tuple(elements) => format!(
                "({})",
                elements
                    .iter()
                    .map(|element| self.name(*element))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            TypeKind::Struct(index) => self.structs[*index].name.clone(),
        }
    }

    /// Whether values of `ty` occupy storage. `Unit` and `Never` do not.
    pub(crate) fn has_storage(&self, ty: Type) -> bool {
        !matches!(self.kind(ty), TypeKind::Unit | TypeKind::Never)
    }

    /// Whether copying `ty` must retain reference counts inside it.
    pub(crate) fn is_counted(&self, ty: Type) -> bool {
        match self.kind(ty) {
            TypeKind::Str => true,
            TypeKind::Tuple(elements) => elements.iter().any(|element| self.is_counted(*element)),
            TypeKind::Struct(index) => self.structs[*index]
                .fields
                .iter()
                .any(|field| self.is_counted(field.ty)),
            TypeKind::Int | TypeKind::Float | TypeKind::Bool | TypeKind::Unit | TypeKind::Never => {
                false
            }
        }
    }

    /// The types stored inside `ty`, in declaration order, without `Unit`.
    pub(crate) fn components(&self, ty: Type) -> Vec<Type> {
        match self.kind(ty) {
            TypeKind::Tuple(elements) => elements.clone(),
            TypeKind::Struct(index) => self.structs[*index]
                .fields
                .iter()
                .map(|field| field.ty)
                .collect(),
            _ => Vec::new(),
        }
    }
}
