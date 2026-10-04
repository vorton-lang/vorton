//! Instantiation of generic functions.
//!
//! The checker checks a generic function once, with its type parameters as
//! [`TypeKind::Param`]. Code generation needs concrete types, so this pass
//! copies each generic function for every list of type arguments that calls
//! reach from the non-generic functions, and replaces the parameters
//! throughout the copy. The recursion check in the checker guarantees that
//! finitely many copies are reached.
//!
//! A generic function treats a parameter without a `Copy` bound as an
//! entity, so it moves values of that type. Where the argument is a value
//! type, the copy reads the place instead: the checker has made sure the
//! moved place is not used again, and reading leaves the place to be
//! released as usual.
//!
//! A trait method called on a type parameter becomes a call of the method
//! of the impl for the type argument. The checker has made sure that the
//! impl exists; `Display` of a built-in type has none and becomes string
//! interpolation of the value.

use std::collections::BTreeMap;

use crate::checker::{
    Block, BorrowTarget, Callee, CheckDiagnostic, Expr, ExprKind, ForSource, Function, Impls,
    Place, Projection, Receiver, Statement,
};
use crate::types::{Type, TypeKind, Types};

/// `ty` with every type parameter replaced by the argument at its index.
/// `instantiate` builds a struct or enum declaration at type arguments.
pub(crate) fn substitute<F>(
    types: &mut Types,
    instantiate: &mut F,
    ty: Type,
    arguments: &[Type],
) -> Result<Type, CheckDiagnostic>
where
    F: FnMut(&mut Types, usize, Vec<Type>) -> Result<Type, CheckDiagnostic>,
{
    if !types.is_generic(ty) {
        return Ok(ty);
    }
    let mut all = |types: &mut Types, parts: Vec<Type>| {
        parts
            .into_iter()
            .map(|part| substitute(types, instantiate, part, arguments))
            .collect::<Result<Vec<_>, _>>()
    };
    let kind = match types.kind(ty).clone() {
        TypeKind::Param { index, .. } => return Ok(arguments[index]),
        TypeKind::Nominal {
            declaration,
            arguments: parts,
        } => {
            let parts = all(types, parts)?;
            return instantiate(types, declaration, parts);
        }
        TypeKind::Tuple(parts) => TypeKind::Tuple(all(types, parts)?),
        TypeKind::List(element) => TypeKind::List(all(types, vec![element])?[0]),
        TypeKind::Set(element) => TypeKind::Set(all(types, vec![element])?[0]),
        TypeKind::Map(key, value) => {
            let parts = all(types, vec![key, value])?;
            TypeKind::Map(parts[0], parts[1])
        }
        TypeKind::Int
        | TypeKind::Float
        | TypeKind::Bool
        | TypeKind::Str
        | TypeKind::Unit
        | TypeKind::Never
        | TypeKind::Range => unreachable!("only types with parameters are substituted"),
    };
    Ok(types.intern(kind))
}

/// Returns the functions that code generation emits, and the index of
/// `main` among them: every non-generic function of `templates`, in order,
/// then the instances of generic ones as calls reach them.
pub(crate) fn instantiate_functions<F>(
    types: &mut Types,
    instantiate: &mut F,
    templates: Vec<Function>,
    generic: &[bool],
    main: usize,
    impls: &Impls,
    display: usize,
) -> Result<(Vec<Function>, usize), CheckDiagnostic>
where
    F: FnMut(&mut Types, usize, Vec<Type>) -> Result<Type, CheckDiagnostic>,
{
    let mut instances = Instances::default();
    for (template, is_generic) in generic.iter().enumerate() {
        if !is_generic {
            instances.get(template, Vec::new());
        }
    }
    let mut functions = Vec::new();
    while let Some((template, arguments)) = instances.list.get(functions.len()).cloned() {
        let mut function = templates[template].clone();
        Instantiation {
            types: &mut *types,
            instantiate: &mut *instantiate,
            arguments: &arguments,
            instances: &mut instances,
            impls,
            display,
        }
        .function(&mut function)?;
        functions.push(function);
    }
    // Hand-written comparisons are methods of non-generic types.
    for written in types.comparisons.values_mut() {
        for function in [&mut written.eq, &mut written.partial_cmp, &mut written.cmp]
            .into_iter()
            .flatten()
        {
            *function = instances.index[&(*function, Vec::new())];
        }
    }
    let main = instances.index[&(main, Vec::new())];
    Ok((functions, main))
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

struct Instantiation<'a, F> {
    types: &'a mut Types,
    instantiate: &'a mut F,
    arguments: &'a [Type],
    instances: &'a mut Instances,
    impls: &'a Impls,
    /// The core `Display`, which built-in types implement without an impl.
    display: usize,
}

impl<F> Instantiation<'_, F>
where
    F: FnMut(&mut Types, usize, Vec<Type>) -> Result<Type, CheckDiagnostic>,
{
    fn ty(&mut self, ty: &mut Type) -> Result<(), CheckDiagnostic> {
        *ty = substitute(self.types, self.instantiate, *ty, self.arguments)?;
        Ok(())
    }

    fn function(&mut self, function: &mut Function) -> Result<(), CheckDiagnostic> {
        for local in &mut function.locals {
            self.ty(&mut local.ty)?;
        }
        self.ty(&mut function.result)?;
        let locals = function
            .locals
            .iter()
            .map(|local| local.ty)
            .collect::<Vec<_>>();
        self.block(&mut function.body, &locals)
    }

    fn block(&mut self, block: &mut Block, locals: &[Type]) -> Result<(), CheckDiagnostic> {
        for statement in &mut block.statements {
            self.statement(statement, locals)?;
        }
        if let Some(tail) = &mut block.tail {
            self.expr(tail, locals)?;
        }
        self.ty(&mut block.ty)
    }

    fn statement(
        &mut self,
        statement: &mut Statement,
        locals: &[Type],
    ) -> Result<(), CheckDiagnostic> {
        match statement {
            Statement::Let { value, .. }
            | Statement::LetPattern { value, .. }
            | Statement::Expr(value)
            | Statement::Return(Some(value)) => self.expr(value, locals),
            Statement::Assign { place, value, .. } => {
                self.place(place, locals)?;
                self.expr(value, locals)
            }
            Statement::Return(None) | Statement::Break | Statement::Continue => Ok(()),
            Statement::While { condition, body } => {
                self.expr(condition, locals)?;
                self.block(body, locals)
            }
            Statement::Loop(body) => self.block(body, locals),
            Statement::For { source, body, .. } => {
                match source {
                    ForSource::Range { start, end, .. } => {
                        self.expr(start, locals)?;
                        self.expr(end, locals)?;
                    }
                    ForSource::RangeValue(value) => self.expr(value, locals)?,
                    ForSource::Taken { container, element } => {
                        self.expr(container, locals)?;
                        self.ty(element)?;
                    }
                    ForSource::Borrowed(place) => self.place(place, locals)?,
                }
                self.block(body, locals)
            }
        }
    }

    fn place(&mut self, place: &mut Place, locals: &[Type]) -> Result<(), CheckDiagnostic> {
        if let Some(call) = &mut place.call {
            self.expr(call, locals)?;
        }
        for projection in &mut place.projections {
            if let Projection::Index(index) = projection {
                self.expr(index, locals)?;
            }
        }
        Ok(())
    }

    fn exprs(&mut self, expressions: &mut [Expr], locals: &[Type]) -> Result<(), CheckDiagnostic> {
        for expression in expressions {
            self.expr(expression, locals)?;
        }
        Ok(())
    }

    fn expr(&mut self, expression: &mut Expr, locals: &[Type]) -> Result<(), CheckDiagnostic> {
        self.ty(&mut expression.ty)?;
        match &mut expression.kind {
            ExprKind::Int(_)
            | ExprKind::Float(_)
            | ExprKind::Bool(_)
            | ExprKind::Str(_)
            | ExprKind::Unit
            | ExprKind::Local(_)
            | ExprKind::EmptyMap => {}
            ExprKind::Call {
                callee,
                type_arguments,
                arguments,
                ..
            } => {
                for argument in type_arguments.iter_mut() {
                    self.ty(argument)?;
                }
                self.exprs(arguments, locals)?;
                let function = match *callee {
                    Callee::Function(function) => Some(function),
                    Callee::Trait {
                        trait_index,
                        method,
                        mut self_type,
                    } => {
                        self.ty(&mut self_type)?;
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
                        *callee = Callee::Function(
                            self.instances.get(function, std::mem::take(type_arguments)),
                        );
                    }
                    // `Display::to_str` of a built-in type.
                    None => {
                        let [receiver] = std::mem::take(arguments)
                            .try_into()
                            .unwrap_or_else(|_| unreachable!("`to_str` takes `&self`"));
                        let ExprKind::Borrow(target) = receiver.kind else {
                            unreachable!("`to_str` borrows its receiver")
                        };
                        let value = match *target {
                            BorrowTarget::Place(place) => self.read(place, locals),
                            BorrowTarget::Value(value) => value,
                        };
                        expression.kind = ExprKind::Interpolate(vec![value]);
                    }
                }
            }
            ExprKind::Intrinsic { arguments, .. }
            | ExprKind::Interpolate(arguments)
            | ExprKind::Tuple(arguments)
            | ExprKind::List(arguments) => self.exprs(arguments, locals)?,
            ExprKind::Unary { operand, .. } => self.expr(operand, locals)?,
            ExprKind::Binary { left, right, .. }
            | ExprKind::Range {
                start: left,
                end: right,
                ..
            }
            | ExprKind::Index {
                base: left,
                index: right,
            } => {
                self.expr(left, locals)?;
                self.expr(right, locals)?;
            }
            ExprKind::If {
                condition,
                then_branch,
                else_branch,
            } => {
                self.expr(condition, locals)?;
                self.block(then_branch, locals)?;
                if let Some(else_branch) = else_branch {
                    self.expr(else_branch, locals)?;
                }
            }
            ExprKind::Block(block) => self.block(block, locals)?,
            ExprKind::Construct { base, fields, .. } => {
                if let Some(base) = base {
                    self.expr(base, locals)?;
                }
                for (_, field) in fields {
                    self.expr(field, locals)?;
                }
            }
            ExprKind::Field { base, .. } => self.expr(base, locals)?,
            ExprKind::Match { scrutinee, arms } => {
                self.expr(scrutinee, locals)?;
                for arm in arms {
                    if let Some(guard) = &mut arm.guard {
                        self.expr(guard, locals)?;
                    }
                    self.expr(&mut arm.body, locals)?;
                }
            }
            ExprKind::Move(place) => {
                self.place(place, locals)?;
                if !self.types.is_entity(expression.ty) {
                    let ExprKind::Move(place) =
                        std::mem::replace(&mut expression.kind, ExprKind::Unit)
                    else {
                        unreachable!("matched above")
                    };
                    *expression = self.read(place, locals);
                }
            }
            ExprKind::Builtin {
                receiver,
                arguments,
                ..
            } => {
                match receiver.as_mut() {
                    Receiver::Place(place) => self.place(place, locals)?,
                    Receiver::Value(value) => self.expr(value, locals)?,
                }
                self.exprs(arguments, locals)?;
            }
            ExprKind::Borrow(target) => match target.as_mut() {
                BorrowTarget::Place(place) => self.place(place, locals)?,
                BorrowTarget::Value(value) => self.expr(value, locals)?,
            },
        }
        Ok(())
    }

    /// An expression that reads `place`.
    fn read(&self, place: Place, locals: &[Type]) -> Expr {
        let mut value = match place.call {
            Some(call) => *call,
            None => Expr {
                ty: locals[place.local],
                kind: ExprKind::Local(place.local),
            },
        };
        for projection in place.projections {
            let base = Box::new(value);
            value = match projection {
                Projection::Field(index) => Expr {
                    ty: self.types.components(base.ty)[index],
                    kind: ExprKind::Field { base, index },
                },
                Projection::Index(index) => Expr {
                    ty: match self.types.kind(base.ty) {
                        TypeKind::List(element) | TypeKind::Map(_, element) => *element,
                        _ => unreachable!("only lists and maps are indexed"),
                    },
                    kind: ExprKind::Index { base, index },
                },
            };
        }
        value
    }
}
