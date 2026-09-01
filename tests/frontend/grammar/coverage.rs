use std::collections::BTreeSet;

use vorton::ast::*;
use vorton::source::{SourceFile, SourceId, Span};

#[derive(Default)]
pub(crate) struct AstCoverage {
    pub(crate) variants: BTreeSet<&'static str>,
    pub(crate) nodes: BTreeSet<&'static str>,
    pub(crate) field_shapes: BTreeSet<&'static str>,
    source: Option<SourceId>,
    source_len: u32,
}

impl AstCoverage {
    pub(crate) fn visit_program(&mut self, program: &Program) {
        self.source = Some(program.source);
        self.source_len = program.span.end;
        self.node("Program", program.span);
        for use_decl in &program.uses {
            self.visit_use_decl(use_decl);
        }
        for declaration in &program.declarations {
            self.visit_decl(declaration);
        }
    }

    fn visit_use_decl(&mut self, use_decl: &UseDecl) {
        self.node("UseDecl", use_decl.span);
        self.visit_visibility(&use_decl.visibility);
        self.visit_path(&use_decl.path);
        self.visit_use_kind(&use_decl.kind);
    }

    fn visit_use_kind(&mut self, kind: &UseKind) {
        match kind {
            UseKind::Bare => self.mark("UseKind::Bare"),
            UseKind::PathAlias(alias) => {
                self.mark("UseKind::PathAlias");
                self.visit_name(alias);
            }
            UseKind::NamedItems(items) => {
                self.mark("UseKind::NamedItems");
                for item in items {
                    self.node("UseItem", item.span);
                    self.shape(if item.alias.is_some() {
                        "UseItem.alias.some"
                    } else {
                        "UseItem.alias.none"
                    });
                    if let Some(alias) = &item.alias {
                        self.visit_name(alias);
                    }
                    self.visit_name(&item.name);
                }
            }
        }
    }

    fn visit_decl(&mut self, declaration: &Decl) {
        self.span(declaration.span());
        match declaration {
            Decl::Function(value) => {
                self.mark("Decl::Function");
                self.visit_function(value);
            }
            Decl::Struct(value) => {
                self.mark("Decl::Struct");
                self.node("StructDecl", value.span);
                self.visit_visibility(&value.visibility);
                self.visit_name(&value.name);
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                for field in &value.fields {
                    self.node("StructField", field.span);
                    self.visit_visibility(&field.visibility);
                    self.visit_name(&field.name);
                    self.visit_type(&field.ty);
                }
            }
            Decl::Enum(value) => {
                self.mark("Decl::Enum");
                self.node("EnumDecl", value.span);
                self.visit_visibility(&value.visibility);
                self.visit_name(&value.name);
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                for variant in &value.variants {
                    self.node("EnumVariant", variant.span);
                    self.visit_name(&variant.name);
                    self.visit_variant_fields(&variant.fields);
                }
            }
            Decl::Trait(value) => {
                self.mark("Decl::Trait");
                self.node("TraitDecl", value.span);
                self.visit_visibility(&value.visibility);
                self.visit_name(&value.name);
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                for bound in &value.supertraits {
                    self.visit_type_bound(bound);
                }
                for member in &value.members {
                    self.visit_trait_member(member);
                }
            }
            Decl::Impl(value) => {
                self.mark("Decl::Impl");
                self.node("ImplDecl", value.span);
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                self.visit_impl_kind(&value.kind);
                for member in &value.members {
                    self.visit_impl_member(member);
                }
            }
            Decl::Effect(value) => {
                self.mark("Decl::Effect");
                self.node("EffectDecl", value.span);
                self.visit_visibility(&value.visibility);
                self.visit_name(&value.name);
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                for operation in &value.operations {
                    self.node("EffectOperation", operation.span);
                    self.visit_name(&operation.name);
                    for parameter in &operation.params {
                        self.visit_param(parameter);
                    }
                    self.visit_type(&operation.return_type);
                }
            }
            Decl::EffectAlias(value) => {
                self.mark("Decl::EffectAlias");
                self.node("EffectAliasDecl", value.span);
                self.visit_visibility(&value.visibility);
                self.visit_name(&value.name);
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                self.visit_effect_set(&value.effects);
            }
            Decl::ExternFunction(value) => {
                self.mark("Decl::ExternFunction");
                self.node("ExternFunctionDecl", value.span);
                self.visit_visibility(&value.visibility);
                self.visit_name(&value.name);
                self.shape(if value.return_type.is_some() {
                    "ExternFunctionDecl.return.some"
                } else {
                    "ExternFunctionDecl.return.none"
                });
                self.shape(if value.effects.is_some() {
                    "ExternFunctionDecl.effects.some"
                } else {
                    "ExternFunctionDecl.effects.none"
                });
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                for parameter in &value.params {
                    self.visit_param(parameter);
                }
                if let Some(return_type) = &value.return_type {
                    self.visit_type(return_type);
                }
                if let Some(effects) = &value.effects {
                    self.visit_effect_set(effects);
                }
            }
            Decl::ExternType(value) => {
                self.mark("Decl::ExternType");
                self.node("ExternTypeDecl", value.span);
                self.visit_visibility(&value.visibility);
                self.visit_name(&value.name);
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
            }
            Decl::TypeAlias(value) => {
                self.mark("Decl::TypeAlias");
                self.node("TypeAliasDecl", value.span);
                self.visit_visibility(&value.visibility);
                self.visit_name(&value.name);
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                self.visit_type(&value.ty);
            }
            Decl::Test(value) => {
                self.mark("Decl::Test");
                self.node("TestDecl", value.span);
                self.visit_visibility(&value.visibility);
                self.span(value.description_span);
                self.visit_expr(&value.body);
            }
            Decl::Const(value) => {
                self.mark("Decl::Const");
                self.node("ConstDecl", value.span);
                self.visit_visibility(&value.visibility);
                self.visit_name(&value.name);
                self.shape(if value.type_annotation.is_some() {
                    "ConstDecl.annotation.some"
                } else {
                    "ConstDecl.annotation.none"
                });
                if let Some(annotation) = &value.type_annotation {
                    self.visit_type(annotation);
                }
                self.visit_expr(&value.value);
            }
            Decl::Module(value) => {
                self.mark("Decl::Module");
                self.node("ModuleDecl", value.span);
                self.visit_visibility(&value.visibility);
                self.visit_name(&value.name);
                self.shape(if value.requires.is_some() {
                    "ModuleDecl.requires.some"
                } else {
                    "ModuleDecl.requires.none"
                });
                if let Some(requires) = &value.requires {
                    self.visit_effect_set(requires);
                }
                for use_decl in &value.uses {
                    self.visit_use_decl(use_decl);
                }
                for declaration in &value.declarations {
                    self.visit_decl(declaration);
                }
            }
        }
    }

    fn visit_function(&mut self, function: &FunctionDecl) {
        self.node("FunctionDecl", function.span);
        self.visit_visibility(&function.visibility);
        self.visit_name(&function.name);
        self.shape(if function.return_type.is_some() {
            "FunctionDecl.return.some"
        } else {
            "FunctionDecl.return.none"
        });
        self.shape(if function.effects.is_some() {
            "FunctionDecl.effects.some"
        } else {
            "FunctionDecl.effects.none"
        });
        for parameter in &function.type_params {
            self.visit_type_param(parameter);
        }
        for parameter in &function.params {
            self.visit_param(parameter);
        }
        if let Some(return_type) = &function.return_type {
            self.visit_type(return_type);
        }
        if let Some(effects) = &function.effects {
            self.visit_effect_set(effects);
        }
        self.visit_expr(&function.body);
    }

    fn visit_variant_fields(&mut self, fields: &VariantFields) {
        match fields {
            VariantFields::Unit => self.mark("VariantFields::Unit"),
            VariantFields::Positional(types) => {
                self.mark("VariantFields::Positional");
                for ty in types {
                    self.visit_type(ty);
                }
            }
            VariantFields::Named(fields) => {
                self.mark("VariantFields::Named");
                for field in fields {
                    self.node("NamedTypeField", field.span);
                    self.visit_name(&field.name);
                    self.visit_type(&field.ty);
                }
            }
        }
    }

    fn visit_trait_member(&mut self, member: &TraitMember) {
        match member {
            TraitMember::Method(value) => {
                self.mark("TraitMember::Method");
                self.node("FunctionSignature", value.span);
                self.visit_name(&value.name);
                self.shape(if value.return_type.is_some() {
                    "FunctionSignature.return.some"
                } else {
                    "FunctionSignature.return.none"
                });
                self.shape(if value.effects.is_some() {
                    "FunctionSignature.effects.some"
                } else {
                    "FunctionSignature.effects.none"
                });
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                for parameter in &value.params {
                    self.visit_param(parameter);
                }
                if let Some(return_type) = &value.return_type {
                    self.visit_type(return_type);
                }
                if let Some(effects) = &value.effects {
                    self.visit_effect_set(effects);
                }
            }
            TraitMember::AssociatedType(value) => {
                self.mark("TraitMember::AssociatedType");
                self.visit_associated_type(value);
            }
        }
    }

    fn visit_associated_type(&mut self, associated: &AssociatedTypeDecl) {
        self.node("AssociatedTypeDecl", associated.span);
        self.visit_visibility(&associated.visibility);
        self.visit_name(&associated.name);
        self.shape(if associated.value.is_some() {
            "AssociatedTypeDecl.value.some"
        } else {
            "AssociatedTypeDecl.value.none"
        });
        for bound in &associated.bounds {
            self.visit_type_bound(bound);
        }
        if let Some(value) = &associated.value {
            self.visit_type(value);
        }
    }

    fn visit_impl_kind(&mut self, kind: &ImplKind) {
        match kind {
            ImplKind::Inherent { target } => {
                self.mark("ImplKind::Inherent");
                self.visit_type(target);
            }
            ImplKind::Trait { trait_path, target } => {
                self.mark("ImplKind::Trait");
                self.visit_type(trait_path);
                self.visit_type(target);
            }
        }
    }

    fn visit_impl_member(&mut self, member: &ImplMember) {
        match member {
            ImplMember::Method(value) => {
                self.mark("ImplMember::Method");
                self.visit_function(value);
            }
            ImplMember::AssociatedType(value) => {
                self.mark("ImplMember::AssociatedType");
                self.visit_associated_type(value);
            }
        }
    }

    fn visit_type_param(&mut self, parameter: &TypeParam) {
        self.node("TypeParam", parameter.span);
        self.visit_name(&parameter.name);
        for bound in &parameter.bounds {
            self.visit_type_bound(bound);
        }
    }

    fn visit_type_bound(&mut self, bound: &TypeBound) {
        self.node("TypeBound", bound.span);
        self.visit_path(&bound.path);
        for argument in &bound.type_args {
            self.visit_type(argument);
        }
        for constraint in &bound.associated {
            self.node("AssociatedConstraint", constraint.span);
            self.visit_name(&constraint.name);
            self.visit_type(&constraint.ty);
        }
    }

    fn visit_param(&mut self, parameter: &Param) {
        self.node("Param", parameter.span);
        self.visit_name(&parameter.name);
        self.shape(if parameter.mutable {
            "Param.mutable.true"
        } else {
            "Param.mutable.false"
        });
        self.shape(if parameter.type_annotation.is_some() {
            "Param.annotation.some"
        } else {
            "Param.annotation.none"
        });
        if let Some(annotation) = &parameter.type_annotation {
            self.visit_type(annotation);
        }
    }

    fn visit_type(&mut self, ty: &TypeExpr) {
        self.span(ty.span());
        match ty {
            TypeExpr::Named {
                path, type_args, ..
            } => {
                self.mark("TypeExpr::Named");
                self.visit_path(path);
                for argument in type_args {
                    self.visit_type(argument);
                }
            }
            TypeExpr::Function {
                params,
                return_type,
                effects,
                ..
            } => {
                self.mark("TypeExpr::Function");
                for parameter in params {
                    self.visit_type(parameter);
                }
                self.visit_type(return_type);
                if let Some(effects) = effects {
                    self.visit_effect_set(effects);
                }
            }
            TypeExpr::Tuple { elements, .. } => {
                self.mark("TypeExpr::Tuple");
                for element in elements {
                    self.visit_type(element);
                }
            }
            TypeExpr::Parenthesized { inner, .. } => {
                self.mark("TypeExpr::Parenthesized");
                self.visit_type(inner);
            }
            TypeExpr::Record { fields, .. } => {
                self.mark("TypeExpr::Record");
                if let TypeExpr::Record { rest, .. } = ty {
                    self.shape(if rest.is_some() {
                        "TypeExpr.Record.rest.some"
                    } else {
                        "TypeExpr.Record.rest.none"
                    });
                    if let Some(rest) = rest {
                        self.visit_name(rest);
                    }
                }
                for field in fields {
                    self.node("NamedTypeField", field.span);
                    self.visit_name(&field.name);
                    self.visit_type(&field.ty);
                }
            }
        }
    }

    fn visit_effect_set(&mut self, set: &EffectSet) {
        self.node("EffectSet", set.span);
        self.shape(if set.effects.is_empty() {
            "EffectSet.empty"
        } else {
            "EffectSet.nonempty"
        });
        for effect in &set.effects {
            self.node("EffectExpr", effect.span);
            self.visit_effect_name(&effect.name);
            for argument in &effect.type_args {
                self.visit_type(argument);
            }
        }
    }

    fn visit_effect_name(&mut self, name: &EffectName) {
        match name {
            EffectName::Path(path) => {
                self.mark("EffectName::Path");
                self.visit_path(path);
            }
            EffectName::Mutation(name) => {
                self.mark("EffectName::Mutation");
                self.visit_name(name);
            }
            EffectName::Unsafe(name) => {
                self.mark("EffectName::Unsafe");
                self.visit_name(name);
            }
        }
    }

    fn visit_stmt(&mut self, statement: &Stmt) {
        self.span(statement.span());
        match statement {
            Stmt::Let {
                mutable,
                pattern,
                type_annotation,
                value,
                ..
            } => {
                self.mark("Stmt::Let");
                self.shape(if *mutable {
                    "Stmt.Let.mutable.true"
                } else {
                    "Stmt.Let.mutable.false"
                });
                self.shape(if type_annotation.is_some() {
                    "Stmt.Let.annotation.some"
                } else {
                    "Stmt.Let.annotation.none"
                });
                self.visit_pattern(pattern);
                if let Some(annotation) = type_annotation {
                    self.visit_type(annotation);
                }
                self.visit_expr(value);
            }
            Stmt::IfLet {
                pattern,
                value,
                then_block,
                else_block,
                ..
            } => {
                self.mark("Stmt::IfLet");
                self.shape(if else_block.is_some() {
                    "Stmt.IfLet.else.some"
                } else {
                    "Stmt.IfLet.else.none"
                });
                self.visit_pattern(pattern);
                self.visit_expr(value);
                self.visit_expr(then_block);
                if let Some(else_block) = else_block {
                    self.visit_expr(else_block);
                }
            }
            Stmt::Return { value, .. } => {
                self.mark("Stmt::Return");
                self.shape(if value.is_some() {
                    "Stmt.Return.value.some"
                } else {
                    "Stmt.Return.value.none"
                });
                if let Some(value) = value {
                    self.visit_expr(value);
                }
            }
            Stmt::While {
                condition, body, ..
            } => {
                self.mark("Stmt::While");
                self.visit_expr(condition);
                self.visit_expr(body);
            }
            Stmt::Loop { body, .. } => {
                self.mark("Stmt::Loop");
                self.visit_expr(body);
            }
            Stmt::For {
                binding,
                iterable,
                body,
                ..
            } => {
                self.mark("Stmt::For");
                self.visit_for_binding(binding);
                self.visit_expr(iterable);
                self.visit_expr(body);
            }
            Stmt::Break { .. } => self.mark("Stmt::Break"),
            Stmt::Continue { .. } => self.mark("Stmt::Continue"),
            Stmt::Assign {
                target, op, value, ..
            } => {
                self.mark("Stmt::Assign");
                self.visit_expr(target);
                self.visit_assign_op(*op);
                self.visit_expr(value);
            }
            Stmt::Expression { expression, .. } => {
                self.mark("Stmt::Expression");
                if let Stmt::Expression { has_semicolon, .. } = statement {
                    self.shape(if *has_semicolon {
                        "Stmt.Expression.semicolon.true"
                    } else {
                        "Stmt.Expression.semicolon.false"
                    });
                }
                self.visit_expr(expression);
            }
        }
    }

    fn visit_for_binding(&mut self, binding: &ForBinding) {
        match binding {
            ForBinding::Name(name) => {
                self.mark("ForBinding::Name");
                self.visit_name(name);
            }
            ForBinding::Tuple(names, _) => {
                self.mark("ForBinding::Tuple");
                if let ForBinding::Tuple(_, span) = binding {
                    self.span(*span);
                }
                for name in names {
                    self.visit_name(name);
                }
            }
        }
    }

    fn visit_assign_op(&mut self, op: AssignOp) {
        match op {
            AssignOp::Assign => self.mark("AssignOp::Assign"),
            AssignOp::AddAssign => self.mark("AssignOp::AddAssign"),
            AssignOp::SubtractAssign => self.mark("AssignOp::SubtractAssign"),
            AssignOp::MultiplyAssign => self.mark("AssignOp::MultiplyAssign"),
            AssignOp::DivideAssign => self.mark("AssignOp::DivideAssign"),
            AssignOp::RemainderAssign => self.mark("AssignOp::RemainderAssign"),
        }
    }

    pub(crate) fn visit_expr(&mut self, expression: &Expr) {
        self.span(expression.span());
        match expression {
            Expr::Integer { .. } => self.mark("Expr::Integer"),
            Expr::Float { .. } => self.mark("Expr::Float"),
            Expr::String { .. } => self.mark("Expr::String"),
            Expr::RawString { .. } => self.mark("Expr::RawString"),
            Expr::InterpolatedString { parts, .. } => {
                self.mark("Expr::InterpolatedString");
                for part in parts {
                    self.visit_string_part(part);
                }
            }
            Expr::Boolean { .. } => self.mark("Expr::Boolean"),
            Expr::Path { path, .. } => {
                self.mark("Expr::Path");
                self.visit_path(path);
            }
            Expr::Unary { op, operand, .. } => {
                self.mark("Expr::Unary");
                self.visit_unary_op(*op);
                self.visit_expr(operand);
            }
            Expr::Binary {
                op, left, right, ..
            } => {
                self.mark("Expr::Binary");
                self.visit_binary_op(*op);
                self.visit_expr(left);
                self.visit_expr(right);
            }
            Expr::Range {
                start,
                end,
                inclusive,
                ..
            } => {
                self.mark("Expr::Range");
                self.shape(if *inclusive {
                    "Expr.Range.inclusive.true"
                } else {
                    "Expr.Range.inclusive.false"
                });
                self.visit_expr(start);
                self.visit_expr(end);
            }
            Expr::Call { callee, args, .. } => {
                self.mark("Expr::Call");
                self.visit_expr(callee);
                for argument in args {
                    self.visit_expr(argument);
                }
            }
            Expr::MethodCall {
                receiver,
                method,
                args,
                ..
            } => {
                self.mark("Expr::MethodCall");
                self.visit_expr(receiver);
                self.visit_name(method);
                for argument in args {
                    self.visit_expr(argument);
                }
            }
            Expr::FieldAccess {
                receiver, field, ..
            } => {
                self.mark("Expr::FieldAccess");
                self.visit_expr(receiver);
                self.visit_name(field);
            }
            Expr::TupleFieldAccess { receiver, .. } => {
                self.mark("Expr::TupleFieldAccess");
                self.visit_expr(receiver);
            }
            Expr::Index {
                receiver, index, ..
            } => {
                self.mark("Expr::Index");
                self.visit_expr(receiver);
                self.visit_expr(index);
            }
            Expr::NamedLiteral {
                path,
                spread,
                fields,
                ..
            } => {
                self.mark("Expr::NamedLiteral");
                self.visit_path(path);
                self.shape(if spread.is_some() {
                    "Expr.NamedLiteral.spread.some"
                } else {
                    "Expr.NamedLiteral.spread.none"
                });
                if let Some(spread) = spread {
                    self.visit_expr(spread);
                }
                for field in fields {
                    self.node("FieldInit", field.span);
                    self.visit_name(&field.name);
                    self.shape(if field.shorthand {
                        "FieldInit.shorthand.true"
                    } else {
                        "FieldInit.shorthand.false"
                    });
                    self.visit_expr(&field.value);
                }
            }
            Expr::List { elements, .. } => {
                self.mark("Expr::List");
                self.shape(if elements.is_empty() {
                    "Expr.List.empty"
                } else {
                    "Expr.List.nonempty"
                });
                for element in elements {
                    self.visit_expr(element);
                }
            }
            Expr::Tuple { elements, .. } => {
                self.mark("Expr::Tuple");
                for element in elements {
                    self.visit_expr(element);
                }
            }
            Expr::Unit { .. } => self.mark("Expr::Unit"),
            Expr::Parenthesized { inner, .. } => {
                self.mark("Expr::Parenthesized");
                self.visit_expr(inner);
            }
            Expr::Block {
                statements, tail, ..
            } => {
                self.mark("Expr::Block");
                self.shape(if tail.is_some() {
                    "Expr.Block.tail.some"
                } else {
                    "Expr.Block.tail.none"
                });
                for statement in statements {
                    self.visit_stmt(statement);
                }
                if let Some(tail) = tail {
                    self.visit_expr(tail);
                }
            }
            Expr::If {
                condition,
                then_branch,
                else_branch,
                ..
            } => {
                self.mark("Expr::If");
                self.shape(if else_branch.is_some() {
                    "Expr.If.else.some"
                } else {
                    "Expr.If.else.none"
                });
                self.visit_expr(condition);
                self.visit_expr(then_branch);
                if let Some(else_branch) = else_branch {
                    self.visit_expr(else_branch);
                }
            }
            Expr::Match {
                scrutinee, arms, ..
            } => {
                self.mark("Expr::Match");
                self.visit_expr(scrutinee);
                for arm in arms {
                    self.visit_match_arm(arm);
                }
            }
            Expr::Handle { body, handlers, .. } => {
                self.mark("Expr::Handle");
                self.visit_expr(body);
                for handler in handlers {
                    self.node("EffectHandler", handler.span);
                    self.visit_path(&handler.effect);
                    self.visit_name(&handler.operation);
                    for parameter in &handler.params {
                        self.visit_param(parameter);
                    }
                    self.visit_expr(&handler.body);
                }
            }
            Expr::Lambda {
                params,
                return_type,
                body,
                ..
            } => {
                self.mark("Expr::Lambda");
                self.shape(if return_type.is_some() {
                    "Expr.Lambda.return.some"
                } else {
                    "Expr.Lambda.return.none"
                });
                for parameter in params {
                    self.visit_param(parameter);
                }
                if let Some(return_type) = return_type {
                    self.visit_type(return_type);
                }
                self.visit_expr(body);
            }
            Expr::Catch {
                expression, arms, ..
            } => {
                self.mark("Expr::Catch");
                self.visit_expr(expression);
                for arm in arms {
                    self.visit_match_arm(arm);
                }
            }
            Expr::Unsafe { body, .. } => {
                self.mark("Expr::Unsafe");
                self.visit_expr(body);
            }
            Expr::Return { value, .. } => {
                self.mark("Expr::Return");
                self.shape(if value.is_some() {
                    "Expr.Return.value.some"
                } else {
                    "Expr.Return.value.none"
                });
                if let Some(value) = value {
                    self.visit_expr(value);
                }
            }
        }
    }

    fn visit_string_part(&mut self, part: &StringPart) {
        match part {
            StringPart::Text { span, .. } => {
                self.mark("StringPart::Text");
                self.span(*span);
            }
            StringPart::Expression(expression) => {
                self.mark("StringPart::Expression");
                self.visit_expr(expression);
            }
        }
    }

    fn visit_unary_op(&mut self, op: UnaryOp) {
        match op {
            UnaryOp::Negate => self.mark("UnaryOp::Negate"),
            UnaryOp::Not => self.mark("UnaryOp::Not"),
        }
    }

    fn visit_binary_op(&mut self, op: BinaryOp) {
        match op {
            BinaryOp::Add => self.mark("BinaryOp::Add"),
            BinaryOp::Subtract => self.mark("BinaryOp::Subtract"),
            BinaryOp::Multiply => self.mark("BinaryOp::Multiply"),
            BinaryOp::Divide => self.mark("BinaryOp::Divide"),
            BinaryOp::Remainder => self.mark("BinaryOp::Remainder"),
            BinaryOp::Equal => self.mark("BinaryOp::Equal"),
            BinaryOp::NotEqual => self.mark("BinaryOp::NotEqual"),
            BinaryOp::Less => self.mark("BinaryOp::Less"),
            BinaryOp::LessEqual => self.mark("BinaryOp::LessEqual"),
            BinaryOp::Greater => self.mark("BinaryOp::Greater"),
            BinaryOp::GreaterEqual => self.mark("BinaryOp::GreaterEqual"),
            BinaryOp::And => self.mark("BinaryOp::And"),
            BinaryOp::Or => self.mark("BinaryOp::Or"),
        }
    }

    fn visit_match_arm(&mut self, arm: &MatchArm) {
        self.node("MatchArm", arm.span);
        self.shape(if arm.guard.is_some() {
            "MatchArm.guard.some"
        } else {
            "MatchArm.guard.none"
        });
        self.visit_pattern(&arm.pattern);
        if let Some(guard) = &arm.guard {
            self.visit_expr(guard);
        }
        self.visit_expr(&arm.body);
    }

    fn visit_pattern(&mut self, pattern: &Pattern) {
        self.span(pattern.span());
        match pattern {
            Pattern::Wildcard { .. } => self.mark("Pattern::Wildcard"),
            Pattern::Name { name, .. } => {
                self.mark("Pattern::Name");
                self.visit_name(name);
            }
            Pattern::Literal { literal, .. } => {
                self.mark("Pattern::Literal");
                self.visit_pattern_literal(literal);
            }
            Pattern::Constructor { path, fields, .. } => {
                self.mark("Pattern::Constructor");
                self.visit_path(path);
                for field in fields {
                    self.visit_pattern(field);
                }
            }
            Pattern::NamedConstructor {
                path, fields, rest, ..
            } => {
                self.mark("Pattern::NamedConstructor");
                self.visit_path(path);
                self.shape(if rest.is_some() {
                    "Pattern.NamedConstructor.rest.some"
                } else {
                    "Pattern.NamedConstructor.rest.none"
                });
                if let Some(rest) = rest {
                    self.span(*rest);
                }
                for field in fields {
                    self.node("NamedPatternField", field.span);
                    self.visit_name(&field.name);
                    self.shape(if field.shorthand {
                        "NamedPatternField.shorthand.true"
                    } else {
                        "NamedPatternField.shorthand.false"
                    });
                    self.visit_pattern(&field.pattern);
                }
            }
            Pattern::Tuple { elements, .. } => {
                self.mark("Pattern::Tuple");
                for element in elements {
                    self.visit_pattern(element);
                }
            }
            Pattern::Or { alternatives, .. } => {
                self.mark("Pattern::Or");
                for alternative in alternatives {
                    self.visit_pattern(alternative);
                }
            }
        }
    }

    fn visit_pattern_literal(&mut self, literal: &PatternLiteral) {
        match literal {
            PatternLiteral::Integer(_) => self.mark("PatternLiteral::Integer"),
            PatternLiteral::Float(_) => self.mark("PatternLiteral::Float"),
            PatternLiteral::String(_) => self.mark("PatternLiteral::String"),
            PatternLiteral::Boolean(_) => self.mark("PatternLiteral::Boolean"),
        }
    }

    fn visit_path(&mut self, path: &Path) {
        self.node("Path", path.span);
        self.shape(if path.segments.len() == 1 {
            "Path.segments.single"
        } else {
            "Path.segments.multi"
        });
        for segment in &path.segments {
            self.visit_name(segment);
        }
    }

    fn visit_name(&mut self, name: &Name) {
        self.node("Name", name.span);
    }

    fn visit_visibility(&mut self, visibility: &Visibility) {
        self.nodes.insert("Visibility");
        self.shape(if visibility.public {
            "Visibility.public.true"
        } else {
            "Visibility.public.false"
        });
        self.shape(if visibility.span.is_some() {
            "Visibility.span.some"
        } else {
            "Visibility.span.none"
        });
        if let Some(span) = visibility.span {
            self.span(span);
        }
    }

    fn node(&mut self, tag: &'static str, span: Span) {
        self.nodes.insert(tag);
        self.span(span);
    }

    fn shape(&mut self, tag: &'static str) {
        self.field_shapes.insert(tag);
    }

    fn span(&self, span: Span) {
        assert_eq!(Some(span.source), self.source);
        assert!(span.start <= span.end, "reversed span {span:?}");
        assert!(span.end <= self.source_len, "out-of-bounds span {span:?}");
    }

    fn mark(&mut self, tag: &'static str) {
        self.variants.insert(tag);
    }
}

pub(crate) const EXPECTED_AST_VARIANTS: &[&str] = &[
    "AssignOp::AddAssign",
    "AssignOp::Assign",
    "AssignOp::DivideAssign",
    "AssignOp::MultiplyAssign",
    "AssignOp::RemainderAssign",
    "AssignOp::SubtractAssign",
    "BinaryOp::Add",
    "BinaryOp::And",
    "BinaryOp::Divide",
    "BinaryOp::Equal",
    "BinaryOp::Greater",
    "BinaryOp::GreaterEqual",
    "BinaryOp::Less",
    "BinaryOp::LessEqual",
    "BinaryOp::Multiply",
    "BinaryOp::NotEqual",
    "BinaryOp::Or",
    "BinaryOp::Remainder",
    "BinaryOp::Subtract",
    "Decl::Const",
    "Decl::Effect",
    "Decl::EffectAlias",
    "Decl::Enum",
    "Decl::ExternFunction",
    "Decl::ExternType",
    "Decl::Function",
    "Decl::Impl",
    "Decl::Module",
    "Decl::Struct",
    "Decl::Test",
    "Decl::Trait",
    "Decl::TypeAlias",
    "EffectName::Mutation",
    "EffectName::Path",
    "EffectName::Unsafe",
    "Expr::Binary",
    "Expr::Block",
    "Expr::Boolean",
    "Expr::Call",
    "Expr::Catch",
    "Expr::FieldAccess",
    "Expr::Float",
    "Expr::Handle",
    "Expr::If",
    "Expr::Index",
    "Expr::Integer",
    "Expr::InterpolatedString",
    "Expr::Lambda",
    "Expr::List",
    "Expr::Match",
    "Expr::MethodCall",
    "Expr::NamedLiteral",
    "Expr::Parenthesized",
    "Expr::Path",
    "Expr::Range",
    "Expr::RawString",
    "Expr::Return",
    "Expr::String",
    "Expr::Tuple",
    "Expr::TupleFieldAccess",
    "Expr::Unary",
    "Expr::Unit",
    "Expr::Unsafe",
    "ForBinding::Name",
    "ForBinding::Tuple",
    "ImplKind::Inherent",
    "ImplKind::Trait",
    "ImplMember::AssociatedType",
    "ImplMember::Method",
    "Pattern::Constructor",
    "Pattern::Literal",
    "Pattern::Name",
    "Pattern::NamedConstructor",
    "Pattern::Or",
    "Pattern::Tuple",
    "Pattern::Wildcard",
    "PatternLiteral::Boolean",
    "PatternLiteral::Float",
    "PatternLiteral::Integer",
    "PatternLiteral::String",
    "Stmt::Assign",
    "Stmt::Break",
    "Stmt::Continue",
    "Stmt::Expression",
    "Stmt::For",
    "Stmt::IfLet",
    "Stmt::Let",
    "Stmt::Loop",
    "Stmt::Return",
    "Stmt::While",
    "StringPart::Expression",
    "StringPart::Text",
    "TraitMember::AssociatedType",
    "TraitMember::Method",
    "TypeExpr::Function",
    "TypeExpr::Named",
    "TypeExpr::Parenthesized",
    "TypeExpr::Record",
    "TypeExpr::Tuple",
    "UnaryOp::Negate",
    "UnaryOp::Not",
    "UseKind::Bare",
    "UseKind::NamedItems",
    "UseKind::PathAlias",
    "VariantFields::Named",
    "VariantFields::Positional",
    "VariantFields::Unit",
];

const EXPECTED_PUBLIC_NODES: &[&str] = &[
    "AssociatedConstraint",
    "AssociatedTypeDecl",
    "ConstDecl",
    "EffectAliasDecl",
    "EffectDecl",
    "EffectExpr",
    "EffectHandler",
    "EffectOperation",
    "EffectSet",
    "EnumDecl",
    "EnumVariant",
    "ExternFunctionDecl",
    "ExternTypeDecl",
    "FieldInit",
    "FunctionDecl",
    "FunctionSignature",
    "ImplDecl",
    "MatchArm",
    "ModuleDecl",
    "Name",
    "NamedPatternField",
    "NamedTypeField",
    "Param",
    "Path",
    "Program",
    "StructDecl",
    "StructField",
    "TestDecl",
    "TraitDecl",
    "TypeAliasDecl",
    "TypeBound",
    "TypeParam",
    "UseDecl",
    "UseItem",
    "Visibility",
];

// The spec-first candidate still compiles against the pre-implementation
// carrier, so the visitor records its only legal value. The implementation
// candidate will remove the field without changing this semantic tag.
const EXPECTED_FIELD_SHAPES: &[&str] = &[
    "AssociatedTypeDecl.value.none",
    "AssociatedTypeDecl.value.some",
    "ConstDecl.annotation.none",
    "ConstDecl.annotation.some",
    "EffectSet.empty",
    "EffectSet.nonempty",
    "Expr.Block.tail.none",
    "Expr.Block.tail.some",
    "Expr.If.else.none",
    "Expr.If.else.some",
    "Expr.Lambda.return.none",
    "Expr.Lambda.return.some",
    "Expr.List.empty",
    "Expr.List.nonempty",
    "Expr.NamedLiteral.spread.none",
    "Expr.NamedLiteral.spread.some",
    "Expr.Range.inclusive.false",
    "Expr.Range.inclusive.true",
    "Expr.Return.value.none",
    "Expr.Return.value.some",
    "ExternFunctionDecl.effects.none",
    "ExternFunctionDecl.effects.some",
    "ExternFunctionDecl.return.none",
    "ExternFunctionDecl.return.some",
    "FieldInit.shorthand.false",
    "FieldInit.shorthand.true",
    "FunctionDecl.effects.none",
    "FunctionDecl.effects.some",
    "FunctionDecl.return.none",
    "FunctionDecl.return.some",
    "FunctionSignature.effects.none",
    "FunctionSignature.effects.some",
    "FunctionSignature.return.none",
    "FunctionSignature.return.some",
    "MatchArm.guard.none",
    "MatchArm.guard.some",
    "ModuleDecl.requires.none",
    "ModuleDecl.requires.some",
    "NamedPatternField.shorthand.false",
    "NamedPatternField.shorthand.true",
    "Param.annotation.none",
    "Param.annotation.some",
    "Param.mutable.false",
    "Param.mutable.true",
    "Path.segments.multi",
    "Path.segments.single",
    "Pattern.NamedConstructor.rest.none",
    "Pattern.NamedConstructor.rest.some",
    "Stmt.Expression.semicolon.true",
    "Stmt.IfLet.else.none",
    "Stmt.IfLet.else.some",
    "Stmt.Let.annotation.none",
    "Stmt.Let.annotation.some",
    "Stmt.Let.mutable.false",
    "Stmt.Let.mutable.true",
    "Stmt.Return.value.none",
    "Stmt.Return.value.some",
    "TypeExpr.Record.rest.none",
    "TypeExpr.Record.rest.some",
    "UseItem.alias.none",
    "UseItem.alias.some",
    "Visibility.public.false",
    "Visibility.public.true",
    "Visibility.span.none",
    "Visibility.span.some",
];

const COVERAGE_SUPPLEMENT: &str = r#"
const INFERRED = 1
extern fn host_without_annotations()
mod plain {}
trait Bare {
    type Item
    fn bare(self)
}
type ClosedRecord = {field: Int}
fn constrained<T: Bound<Item = Int>>() {}

fn shapes(base: Shape, item: Shape, untyped, typed: Int) with {} {
    let empty = []
    let literal = Shape {x, y: 1}
    let updated = Shape {..base, x: 1}
    let conditional = if true {}
    if let value = item {}
    let lambda = fn(value) {value}
    let exclusive = 1..2
    let no_rest = match item {Shape {x, y: value} => value}
    let with_rest = match item {Shape {x, ..} if true => x}
    call();
}

fn operators(flag: Bool, item: Item, items: Items) with {mut<Int>, unsafe} {
    let sub = 3 - 2
    let mul = 3 * 2
    let div = 3 / 2
    let rem = 3 % 2
    let ne = 3 != 2
    let le = 3 <= 2
    let ge = 3 >= 2
    let and = flag && true
    let or = flag || false
    let exclusive = 1..2
    let qualified = module::value
    let arm_value = match item { _ => return 1 }
    let arm_bare = match item { _ => return }
    let literals = match item {
        3.5 => 0,
        "text" => 1,
        true => 2,
        false => 3,
        _ => 4,
    }
    for element in items {}
    sub + mul + div + rem + arm_value + arm_bare + literals
}

fn bare_return() {
    return
}
"#;

fn parse_valid(text: &str, id: u32) -> Program {
    let source = SourceFile::new(SourceId(id), format!("coverage-{id}.vorton"), text)
        .expect("valid source fixture");
    let output = vorton::parse_source(source);
    match output.syntax {
        Ok(program) => program,
        Err(diagnostics) => panic!("coverage fixture must parse: {diagnostics:#?}"),
    }
}

#[test]
fn all_ast_enum_variants_are_visited_exhaustively_and_exactly() {
    let mut coverage = AstCoverage::default();
    coverage.visit_program(&parse_valid(
        include_str!("../fixtures/full_surface.vorton"),
        1,
    ));
    coverage.visit_program(&parse_valid(COVERAGE_SUPPLEMENT, 2));

    let expected: BTreeSet<_> = EXPECTED_AST_VARIANTS.iter().copied().collect();
    let expected_nodes: BTreeSet<_> = EXPECTED_PUBLIC_NODES.iter().copied().collect();
    let expected_fields: BTreeSet<_> = EXPECTED_FIELD_SHAPES.iter().copied().collect();
    assert_eq!(EXPECTED_AST_VARIANTS.len(), 107);
    assert_eq!(EXPECTED_PUBLIC_NODES.len(), 35);
    assert_eq!(coverage.variants, expected);
    assert_eq!(coverage.nodes, expected_nodes);
    assert_eq!(coverage.field_shapes, expected_fields);
}
