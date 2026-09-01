use std::collections::BTreeSet;

use vorton::ast::*;
use vorton::source::{SourceFile, SourceId};

#[derive(Default)]
pub(crate) struct AstCoverage {
    pub(crate) variants: BTreeSet<&'static str>,
}

impl AstCoverage {
    pub(crate) fn visit_program(&mut self, program: &Program) {
        for use_decl in &program.uses {
            self.visit_use_decl(use_decl);
        }
        for declaration in &program.declarations {
            self.visit_decl(declaration);
        }
    }

    fn visit_use_decl(&mut self, use_decl: &UseDecl) {
        self.visit_path(&use_decl.path);
        self.visit_use_kind(&use_decl.kind);
    }

    fn visit_use_kind(&mut self, kind: &UseKind) {
        match kind {
            UseKind::Bare => self.mark("UseKind::Bare"),
            UseKind::PathAlias(_) => self.mark("UseKind::PathAlias"),
            UseKind::NamedItems(items) => {
                self.mark("UseKind::NamedItems");
                for item in items {
                    if let Some(alias) = &item.alias {
                        self.visit_name(alias);
                    }
                    self.visit_name(&item.name);
                }
            }
        }
    }

    fn visit_decl(&mut self, declaration: &Decl) {
        match declaration {
            Decl::Function(value) => {
                self.mark("Decl::Function");
                self.visit_function(value);
            }
            Decl::Struct(value) => {
                self.mark("Decl::Struct");
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                for field in &value.fields {
                    self.visit_type(&field.ty);
                }
            }
            Decl::Enum(value) => {
                self.mark("Decl::Enum");
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                for variant in &value.variants {
                    self.visit_variant_fields(&variant.fields);
                }
            }
            Decl::Trait(value) => {
                self.mark("Decl::Trait");
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
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                for operation in &value.operations {
                    for parameter in &operation.params {
                        self.visit_param(parameter);
                    }
                    self.visit_type(&operation.return_type);
                }
            }
            Decl::EffectAlias(value) => {
                self.mark("Decl::EffectAlias");
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                self.visit_effect_set(&value.effects);
            }
            Decl::ExternFunction(value) => {
                self.mark("Decl::ExternFunction");
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
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
            }
            Decl::TypeAlias(value) => {
                self.mark("Decl::TypeAlias");
                for parameter in &value.type_params {
                    self.visit_type_param(parameter);
                }
                self.visit_type(&value.ty);
            }
            Decl::Test(value) => {
                self.mark("Decl::Test");
                self.visit_expr(&value.body);
            }
            Decl::Const(value) => {
                self.mark("Decl::Const");
                if let Some(annotation) = &value.type_annotation {
                    self.visit_type(annotation);
                }
                self.visit_expr(&value.value);
            }
            Decl::Module(value) => {
                self.mark("Decl::Module");
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
                    self.visit_type(&field.ty);
                }
            }
        }
    }

    fn visit_trait_member(&mut self, member: &TraitMember) {
        match member {
            TraitMember::Method(value) => {
                self.mark("TraitMember::Method");
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
        for bound in &parameter.bounds {
            self.visit_type_bound(bound);
        }
    }

    fn visit_type_bound(&mut self, bound: &TypeBound) {
        self.visit_path(&bound.path);
        for argument in &bound.type_args {
            self.visit_type(argument);
        }
        for constraint in &bound.associated {
            self.visit_type(&constraint.ty);
        }
    }

    fn visit_param(&mut self, parameter: &Param) {
        if let Some(annotation) = &parameter.type_annotation {
            self.visit_type(annotation);
        }
    }

    fn visit_type(&mut self, ty: &TypeExpr) {
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
                for field in fields {
                    self.visit_type(&field.ty);
                }
            }
        }
    }

    fn visit_effect_set(&mut self, set: &EffectSet) {
        for effect in &set.effects {
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
        match statement {
            Stmt::Let {
                pattern,
                type_annotation,
                value,
                ..
            } => {
                self.mark("Stmt::Let");
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
                self.visit_pattern(pattern);
                self.visit_expr(value);
                self.visit_expr(then_block);
                if let Some(else_block) = else_block {
                    self.visit_expr(else_block);
                }
            }
            Stmt::Return { value, .. } => {
                self.mark("Stmt::Return");
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
            Expr::Range { start, end, .. } => {
                self.mark("Expr::Range");
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
            Expr::MethodCall { receiver, args, .. } => {
                self.mark("Expr::MethodCall");
                self.visit_expr(receiver);
                for argument in args {
                    self.visit_expr(argument);
                }
            }
            Expr::FieldAccess { receiver, .. } => {
                self.mark("Expr::FieldAccess");
                self.visit_expr(receiver);
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
                if let Some(spread) = spread {
                    self.visit_expr(spread);
                }
                for field in fields {
                    self.visit_expr(&field.value);
                }
            }
            Expr::List { elements, .. } => {
                self.mark("Expr::List");
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
                    self.visit_path(&handler.effect);
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
                if let Some(value) = value {
                    self.visit_expr(value);
                }
            }
        }
    }

    fn visit_string_part(&mut self, part: &StringPart) {
        match part {
            StringPart::Text { .. } => self.mark("StringPart::Text"),
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
        self.visit_pattern(&arm.pattern);
        if let Some(guard) = &arm.guard {
            self.visit_expr(guard);
        }
        self.visit_expr(&arm.body);
    }

    fn visit_pattern(&mut self, pattern: &Pattern) {
        match pattern {
            Pattern::Wildcard { .. } => self.mark("Pattern::Wildcard"),
            Pattern::Name { .. } => self.mark("Pattern::Name"),
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
                path,
                fields,
                rest: _,
                ..
            } => {
                self.mark("Pattern::NamedConstructor");
                self.visit_path(path);
                for field in fields {
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
        for segment in &path.segments {
            self.visit_name(segment);
        }
    }

    fn visit_name(&mut self, _name: &Name) {}

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

const COVERAGE_SUPPLEMENT: &str = r#"
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
    assert_eq!(EXPECTED_AST_VARIANTS.len(), 107);
    assert_eq!(coverage.variants, expected);
}
