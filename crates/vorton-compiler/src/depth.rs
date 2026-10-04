//! The spec's limit on how deeply source nests.
//!
//! Every pass of the compiler recurses as deep as the source nests, so the
//! limit is what lets each pass finish on the compiler's fixed stack. Each
//! expression, block, statement, pattern and type is one level deeper than
//! the one that contains it; a chain `1 + 2 + 3` nests too, because the
//! first sum is part of the second. The walk stops at the first node past
//! the limit, so it never recurses deeper than the limit itself.

use crate::ast::{
    Block, ConstructEntryKind, Declaration, DeclarationKind, Expr, ExprKind, FunctionSignature,
    ImplMemberKind, InterpolationPart, LetBinding, NamedTypeKind, Parameter, Pattern,
    PatternFields, PatternKind, PlaceProjection, Program, Span, StatementKind, TraitMemberKind,
    TypeArgument, TypeExpr, TypeKind, VariantFields,
};

/// The deepest nesting the spec allows.
pub(crate) const MAX_NESTING: usize = 10_000;

/// Returns the span of the first node nested deeper than [`MAX_NESTING`].
pub(crate) fn too_deep(program: &Program) -> Option<Span> {
    program
        .items
        .iter()
        .find_map(|item| declaration(item, 1).err())
}

type Walk = Result<(), Span>;

fn at(depth: usize, span: Span) -> Walk {
    if depth > MAX_NESTING {
        Err(span)
    } else {
        Ok(())
    }
}

fn declaration(item: &Declaration, depth: usize) -> Walk {
    at(depth, item.span)?;
    let next = depth + 1;
    match &item.kind {
        DeclarationKind::Function(declared) => {
            signature(&declared.item.signature, next)?;
            block(&declared.item.body, next)
        }
        DeclarationKind::Struct(declared) => declared
            .item
            .fields
            .iter()
            .try_for_each(|field| ty(&field.ty, next)),
        DeclarationKind::Enum(declared) => {
            declared
                .item
                .variants
                .iter()
                .try_for_each(|variant| match &variant.fields {
                    VariantFields::Unit => Ok(()),
                    VariantFields::Positional(types) => {
                        types.iter().try_for_each(|field| ty(field, next))
                    }
                    VariantFields::Named(fields) => {
                        fields.iter().try_for_each(|field| ty(&field.ty, next))
                    }
                })
        }
        DeclarationKind::InherentImpl(implementation) => implementation
            .members
            .iter()
            .try_for_each(|member| impl_member(&member.kind, next)),
        DeclarationKind::TraitImpl(implementation) => implementation
            .members
            .iter()
            .try_for_each(|member| impl_member(&member.kind, next)),
        DeclarationKind::Trait(declared) => {
            declared
                .item
                .members
                .iter()
                .try_for_each(|member| match &member.kind {
                    TraitMemberKind::Method(method) => signature(method, next),
                    TraitMemberKind::AssociatedType(associated) => associated
                        .default
                        .iter()
                        .try_for_each(|value| ty(value, next)),
                })
        }
        DeclarationKind::Effect(declared) => {
            declared.item.operations.iter().try_for_each(|operation| {
                parameters(&operation.parameters, next)?;
                ty(&operation.return_type, next)
            })
        }
        DeclarationKind::EffectAlias(_) | DeclarationKind::Extern(_) => Ok(()),
        DeclarationKind::TypeAlias(declared) => ty(&declared.item.value, next),
        DeclarationKind::Const(declared) => {
            declared
                .item
                .annotation
                .iter()
                .try_for_each(|annotation| ty(annotation, next))?;
            expression(&declared.item.value, next)
        }
        DeclarationKind::Module(declared) => declared
            .item
            .items
            .iter()
            .try_for_each(|item| declaration(item, next)),
    }
}

fn impl_member(member: &ImplMemberKind, depth: usize) -> Walk {
    match member {
        ImplMemberKind::Function(function) => {
            signature(&function.signature, depth)?;
            block(&function.body, depth)
        }
        ImplMemberKind::AssociatedType(associated) => ty(&associated.value, depth),
    }
}

fn signature(signature: &FunctionSignature, depth: usize) -> Walk {
    parameters(&signature.parameters, depth)?;
    signature
        .return_type
        .iter()
        .try_for_each(|result| ty(result, depth))
}

fn parameters(parameters: &[Parameter], depth: usize) -> Walk {
    parameters
        .iter()
        .filter_map(|parameter| parameter.ty.as_ref())
        .try_for_each(|parameter| ty(parameter, depth))
}

fn ty(ty: &TypeExpr, depth: usize) -> Walk {
    at(depth, ty.span)?;
    let next = depth + 1;
    match &ty.kind {
        TypeKind::Named(named) => named_type(named, next),
        TypeKind::Grouped(inner) => self::ty(inner, next),
        TypeKind::Tuple(elements) => elements
            .iter()
            .try_for_each(|element| self::ty(element, next)),
        TypeKind::Function(function) => {
            function
                .parameters
                .iter()
                .try_for_each(|parameter| self::ty(&parameter.ty, next))?;
            function
                .return_type
                .iter()
                .try_for_each(|result| self::ty(result, next))
        }
    }
}

fn named_type(named: &NamedTypeKind, depth: usize) -> Walk {
    named
        .arguments
        .iter()
        .try_for_each(|argument| match argument {
            TypeArgument::Type(argument)
            | TypeArgument::AssociatedType {
                value: argument, ..
            } => ty(argument, depth),
        })
}

fn block(block: &Block, depth: usize) -> Walk {
    at(depth, block.span)?;
    let next = depth + 1;
    for statement in &block.statements {
        at(next, statement.span)?;
        let inner = next + 1;
        match &statement.kind {
            StatementKind::Let { binding, value } => {
                match binding {
                    LetBinding::Name { annotation, .. } => {
                        annotation
                            .iter()
                            .try_for_each(|annotation| ty(annotation, inner))?;
                    }
                    LetBinding::Tuple(binding) => pattern(binding, inner)?,
                }
                expression(value, inner)?;
            }
            StatementKind::Return(value) => {
                value
                    .iter()
                    .try_for_each(|value| expression(value, inner))?;
            }
            StatementKind::Break | StatementKind::Continue => {}
            StatementKind::Assignment { target, value, .. } => {
                for projection in &target.projections {
                    if let PlaceProjection::Index(index) = projection {
                        expression(index, inner)?;
                    }
                }
                expression(value, inner)?;
            }
            StatementKind::Expression(value) => expression(value, inner)?,
            StatementKind::IfLet {
                pattern: binding,
                value,
                then_branch,
                else_branch,
            } => {
                pattern(binding, inner)?;
                expression(value, inner)?;
                self::block(then_branch, inner)?;
                else_branch
                    .iter()
                    .try_for_each(|branch| self::block(branch, inner))?;
            }
            StatementKind::While { condition, body } => {
                expression(condition, inner)?;
                self::block(body, inner)?;
            }
            StatementKind::For { iterable, body, .. } => {
                expression(iterable, inner)?;
                self::block(body, inner)?;
            }
            StatementKind::Loop(body) => self::block(body, inner)?,
        }
    }
    block
        .tail
        .iter()
        .try_for_each(|tail| expression(tail, next))
}

fn expression(expression: &Expr, depth: usize) -> Walk {
    at(depth, expression.span)?;
    let next = depth + 1;
    let all = |expressions: &[Expr]| {
        expressions
            .iter()
            .try_for_each(|expression| self::expression(expression, next))
    };
    match &expression.kind {
        ExprKind::Integer(_)
        | ExprKind::Float(_)
        | ExprKind::String(_)
        | ExprKind::RawString { .. }
        | ExprKind::Boolean(_)
        | ExprKind::Path(_)
        | ExprKind::Unit => Ok(()),
        ExprKind::InterpolatedString(parts) => parts.iter().try_for_each(|part| match part {
            InterpolationPart::String(_) => Ok(()),
            InterpolationPart::Expression(part) => self::expression(part, next),
        }),
        ExprKind::NamedConstruct { entries, .. } => {
            entries.iter().try_for_each(|entry| match &entry.kind {
                ConstructEntryKind::Spread(value) => self::expression(value, next),
                ConstructEntryKind::Field { value, .. } => value
                    .iter()
                    .try_for_each(|value| self::expression(value, next)),
            })
        }
        ExprKind::List(elements) | ExprKind::Tuple(elements) => all(elements),
        ExprKind::Parenthesized(inner)
        | ExprKind::Unary { operand: inner, .. }
        | ExprKind::Borrow { operand: inner, .. }
        | ExprKind::TupleField {
            receiver: inner, ..
        }
        | ExprKind::Field {
            receiver: inner, ..
        } => self::expression(inner, next),
        ExprKind::Block(inner) | ExprKind::Unsafe(inner) => block(inner, next),
        ExprKind::If {
            condition,
            then_branch,
            else_branch,
        } => {
            self::expression(condition, next)?;
            block(then_branch, next)?;
            else_branch
                .iter()
                .try_for_each(|branch| self::expression(branch, next))
        }
        ExprKind::Match {
            scrutinee: subject,
            arms,
        }
        | ExprKind::Catch {
            expression: subject,
            arms,
        } => {
            self::expression(subject, next)?;
            arms.iter().try_for_each(|arm| {
                arm.pattern
                    .alternatives
                    .iter()
                    .try_for_each(|alternative| pattern(alternative, next))?;
                arm.guard
                    .iter()
                    .try_for_each(|guard| self::expression(guard, next))?;
                self::expression(&arm.body, next)
            })
        }
        ExprKind::Handle { body, handlers } => {
            block(body, next)?;
            handlers.iter().try_for_each(|handler| {
                parameters(&handler.parameters, next)?;
                self::expression(&handler.body, next)
            })
        }
        ExprKind::Closure(closure) => {
            parameters(&closure.parameters, next)?;
            closure
                .return_type
                .iter()
                .try_for_each(|result| ty(result, next))?;
            block(&closure.body, next)
        }
        ExprKind::Binary { left, right, .. }
        | ExprKind::Index {
            receiver: left,
            index: right,
        } => {
            self::expression(left, next)?;
            self::expression(right, next)
        }
        ExprKind::Call { callee, arguments } => {
            self::expression(callee, next)?;
            all(arguments)
        }
        ExprKind::MethodCall {
            receiver,
            arguments,
            ..
        } => {
            self::expression(receiver, next)?;
            all(arguments)
        }
    }
}

fn pattern(pattern: &Pattern, depth: usize) -> Walk {
    at(depth, pattern.span)?;
    let next = depth + 1;
    match &pattern.kind {
        PatternKind::Wildcard
        | PatternKind::Integer(_)
        | PatternKind::Float(_)
        | PatternKind::String(_)
        | PatternKind::Boolean(_) => Ok(()),
        PatternKind::Path { fields, .. } => match fields {
            None => Ok(()),
            Some(PatternFields::Positional(patterns)) => patterns
                .iter()
                .try_for_each(|pattern| self::pattern(pattern, next)),
            Some(PatternFields::Named { fields, .. }) => fields
                .iter()
                .filter_map(|field| field.pattern.as_ref())
                .try_for_each(|pattern| self::pattern(pattern, next)),
        },
        PatternKind::Tuple(elements) => elements
            .iter()
            .try_for_each(|element| self::pattern(element, next)),
    }
}
