//! Instantiation of generic functions, on the IR.
//!
//! The checker checks a generic function once, with its type parameters as
//! [`TypeKind::Param`], and it is lowered and checked for moves and borrows
//! once in that form. Code generation needs concrete types, so this pass
//! copies the IR of each generic function for every list of type arguments
//! that calls reach from the non-generic functions, and replaces the
//! parameters throughout the copy. The recursion check in the checker
//! guarantees that finitely many copies are reached.
//!
//! A generic function treats a parameter without a `Copy` bound as an
//! entity, so it moves values of that type. Where the argument is a value
//! type, moving it takes the value and leaves its place to be released as
//! usual; move checking on the generic IR has made sure the place is not
//! used again.
//!
//! A trait method called on a type parameter becomes a call of the method
//! of the impl for the type argument. The checker has made sure that the
//! impl exists; `Display` of a built-in type has none and becomes string
//! interpolation of the value.
//!
//! [`TypeKind::Param`]: crate::types::TypeKind::Param

use std::collections::BTreeMap;

use crate::checker::CheckDiagnostic;
use crate::mir::{Body, Instance, Operand, Place, Program, Rvalue, StatementKind};
use crate::typed::{Callee, Impls};
use crate::types::{InstantiationError, Type, Types};

/// A checked function before instantiation: its name and its IR.
pub(crate) struct Template {
    pub(crate) name: String,
    pub(crate) body: Body,
    pub(crate) generic: bool,
}

/// Returns the program that code generation emits: every non-generic
/// function, in order, then the instances of generic ones as calls reach
/// them. `error` reports a struct or enum that cannot be instantiated.
pub(crate) fn instantiate(
    mut types: Types,
    templates: &[Template],
    main: usize,
    impls: &Impls,
    display: usize,
    error: &dyn Fn(&Types, InstantiationError) -> CheckDiagnostic,
) -> Result<Program, CheckDiagnostic> {
    let mut instances = Instances::default();
    for (index, template) in templates.iter().enumerate() {
        if !template.generic {
            instances.get(index, Vec::new());
        }
    }
    let mut functions = Vec::new();
    while let Some((index, arguments)) = instances.list.get(functions.len()).cloned() {
        let template = &templates[index];
        let mut body = template.body.clone();
        Instantiation {
            types: &mut types,
            arguments: &arguments,
            instances: &mut instances,
            impls,
            display,
        }
        .body(&mut body)
        .map_err(|failure| error(&types, failure))?;
        functions.push(Instance {
            name: template.name.clone(),
            template: index,
            body,
        });
    }
    // Hand-written impls of core traits are methods of non-generic types.
    for written in types.written.values_mut() {
        for function in written.functions() {
            *function = instances.index[&(*function, Vec::new())];
        }
    }
    let main = instances.index[&(main, Vec::new())];
    Ok(Program {
        types,
        functions,
        main,
    })
}

/// The instances made so far: a template and its type arguments.
#[derive(Default)]
struct Instances {
    list: Vec<(usize, Vec<Type>)>,
    index: BTreeMap<(usize, Vec<Type>), usize>,
}

impl Instances {
    fn get(&mut self, template: usize, arguments: Vec<Type>) -> usize {
        let key = (template, arguments);
        if let Some(&index) = self.index.get(&key) {
            return index;
        }
        let index = self.list.len();
        self.list.push(key.clone());
        self.index.insert(key, index);
        index
    }
}

struct Instantiation<'a> {
    types: &'a mut Types,
    arguments: &'a [Type],
    instances: &'a mut Instances,
    impls: &'a Impls,
    display: usize,
}

impl Instantiation<'_> {
    fn ty(&mut self, ty: Type) -> Result<Type, InstantiationError> {
        self.types.substitute(ty, self.arguments)
    }

    fn body(&mut self, body: &mut Body) -> Result<(), InstantiationError> {
        for local in &mut body.locals {
            local.ty = self.ty(local.ty)?;
        }
        for block in &mut body.blocks {
            for statement in &mut block.statements {
                match &mut statement.kind {
                    StatementKind::Assign(_, value) | StatementKind::Bind(_, value) => {
                        self.rvalue(value)?;
                    }
                    StatementKind::Release(_)
                    | StatementKind::Unpack(_)
                    | StatementKind::Distinct { .. }
                    | StatementKind::Keep(_) => {}
                }
            }
        }
        Ok(())
    }

    fn rvalue(&mut self, value: &mut Rvalue) -> Result<(), InstantiationError> {
        match value {
            Rvalue::Call {
                callee,
                type_arguments,
                arguments,
                ..
            } => {
                let type_arguments = std::mem::take(type_arguments)
                    .into_iter()
                    .map(|argument| self.ty(argument))
                    .collect::<Result<Vec<_>, _>>()?;
                let function = match *callee {
                    Callee::Function(function) => Some(function),
                    Callee::Trait {
                        trait_index,
                        method,
                        self_type,
                    } => {
                        let self_type = self.ty(self_type)?;
                        let function = self
                            .impls
                            .get(&(trait_index, self_type))
                            .map(|methods| methods[method]);
                        assert!(
                            function.is_some() || trait_index == self.display,
                            "the checker found an impl for every bound"
                        );
                        function
                    }
                };
                match function {
                    Some(function) => {
                        *callee = Callee::Function(self.instances.get(function, type_arguments));
                    }
                    // `Display::to_str` of a built-in type, whose receiver
                    // is borrowed: the text of the value it points at.
                    None => {
                        let [Operand::Borrowed(receiver)] = arguments.as_slice() else {
                            unreachable!("`to_str` borrows its receiver")
                        };
                        *value = Rvalue::Interpolate(vec![Operand::Copy(Place::local(*receiver))]);
                    }
                }
            }
            Rvalue::Glue { ty, .. } => *ty = self.ty(*ty)?,
            // The types of the other steps are those of their places.
            Rvalue::Use(_)
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
            | Rvalue::Builtin { .. }
            | Rvalue::Intrinsic { .. }
            | Rvalue::Take { .. } => {}
        }
        Ok(())
    }
}
