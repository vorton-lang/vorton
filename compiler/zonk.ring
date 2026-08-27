use types::{Type, Effect, EffectRow, StructField, RecordField,
    type_to_string}
use ast::{Pattern, Span}
use hir::{HExpr, HStmt, HParam, HMatchArm, HEffectHandler,
    HStructFieldInit, HNominalStructFieldInit,
    HStringInterpPart, HForInDestructure, HLambdaCapture,
    HLetDestructureBinding, HPatternBinding, ValueBindingKind, TraitDispatch,
    HPatternPlan, HPatternFieldPlan,
    make_h_pattern_field_plan, h_pattern_field_projection,
    h_pattern_field_pattern, h_pattern_wildcard, h_pattern_binding,
    h_pattern_literal, h_pattern_tuple, h_pattern_struct,
    h_pattern_variant, h_pattern_or, h_pattern_kind,
    h_pattern_plan_binding, h_pattern_plan_children,
    h_pattern_plan_fields, h_pattern_plan_struct_owner,
    h_pattern_plan_variant,
    HExactCallPlan, make_h_exact_call_plan,
    h_exact_call_callee, h_exact_call_signature, h_exact_call_method,
    h_exact_call_evidence, h_exact_call_handled_evidence,
    HListLiteralPlan, make_h_list_literal_plan,
    h_list_literal_builder, h_list_literal_owner,
    h_list_literal_constructor, h_list_literal_allocator,
    h_list_literal_push,
    HForInPlan, make_h_range_for_in_plan,
    h_for_in_binding_binder, h_range_for_in_owner,
    h_range_for_in_start, h_range_for_in_end,
    h_range_for_in_inclusive, h_range_for_in_order,
    h_range_for_in_equality,
    h_range_for_in_range_binder, h_range_for_in_counter_binder,
    h_range_for_in_finished_binder,
    HOperatorPlan, h_operator_is_tuple, h_operator_elements,
    h_operator_method_ref, h_operator_method, h_operator_tuple,
    MethodCallRef, make_intrinsic_method_call_ref,
    make_concrete_method_call_ref, make_bound_method_call_ref,
    method_call_ref_is_intrinsic, method_call_ref_is_concrete,
    method_call_ref_intrinsic, method_call_ref_impl, method_call_ref_bound,
    method_call_ref_bound_evidence,
    method_call_ref_signature, method_call_ref_receiver_mutable,
    hexpr_type, hexpr_effects, hexpr_span}
use union_find::{UnionFind}
use env::{apply_subst, apply_subst_row}
use infer_ctx::{InferCtx, value_binding_kind, has_variant_ctor_origin_def_id}
use infer_helpers::{resolve_value_ident}

pub struct ZonkCtx {
    pub subst: UnionFind,
    pub names: Map<Int, Str>,
    pub canonical_type_var_ids: Map<Int, Int>,
    // Present for checker-owned zonks.  Keeping it optional preserves zonk's
    // pure type-substitution use sites while allowing fully-unified function
    // VALUE identifiers to resolve their complete DictRef evidence once.
    pub dict_resolver: InferCtx?
}

pub fn zonk_type(ctx: ZonkCtx, t: Type) -> Type {
    let resolved = apply_subst(ctx.subst, t)
    label_vars(ctx.names, ctx.canonical_type_var_ids, resolved)
}

fn zonk_method_call_ref(
    ctx: ZonkCtx, value: MethodCallRef?
) -> MethodCallRef? {
    match value {
        some(exact) => {
            let signature = zonk_type(ctx, method_call_ref_signature(exact))
            if method_call_ref_is_intrinsic(exact) {
                some(make_intrinsic_method_call_ref(
                    method_call_ref_intrinsic(exact), signature))
            } else if method_call_ref_is_concrete(exact) {
                some(make_concrete_method_call_ref(
                    method_call_ref_impl(exact), signature,
                    method_call_ref_receiver_mutable(exact)))
            } else {
                some(make_bound_method_call_ref(
                    method_call_ref_bound(exact),
                    method_call_ref_bound_evidence(exact), signature,
                    method_call_ref_receiver_mutable(exact)))
            }
        },
        none => none
    }
}

fn zonk_operator_plan(ctx: ZonkCtx, value: HOperatorPlan?) -> HOperatorPlan? {
    match value {
        some(plan) => if h_operator_is_tuple(plan) {
            some(h_operator_tuple(h_operator_elements(plan).map(fn(item) {
                match zonk_operator_plan(ctx, some(item)) {
                    some(lowered) => lowered,
                    none => panic("zonk: operator element disappeared")
                }
            })))
        } else {
            let method = match zonk_method_call_ref(
                    ctx, some(h_operator_method_ref(plan))) {
                some(value) => value,
                none => panic("zonk: operator method disappeared")
            }
            some(h_operator_method(method))
        },
        none => none
    }
}

fn zonk_exact_call_plan(
    ctx: ZonkCtx, value: HExactCallPlan
) -> HExactCallPlan {
    make_h_exact_call_plan(
        h_exact_call_callee(value),
        zonk_type(ctx, h_exact_call_signature(value)),
        zonk_method_call_ref(ctx, h_exact_call_method(value)),
        h_exact_call_evidence(value),
        h_exact_call_handled_evidence(value))
}

fn zonk_list_literal_plan(
    ctx: ZonkCtx, value: HListLiteralPlan
) -> HListLiteralPlan {
    make_h_list_literal_plan(
        h_list_literal_builder(value), h_list_literal_owner(value),
        h_list_literal_constructor(value),
        zonk_exact_call_plan(ctx, h_list_literal_allocator(value)),
        zonk_exact_call_plan(ctx, h_list_literal_push(value)))
}

fn zonk_for_in_plan(ctx: ZonkCtx, value: HForInPlan) -> HForInPlan {
    let order = match zonk_operator_plan(
            ctx, some(h_range_for_in_order(value))) {
        some(plan) => plan,
        none => panic("zonk: Range ordering plan disappeared")
    }
    let equality = match zonk_operator_plan(
            ctx, some(h_range_for_in_equality(value))) {
        some(plan) => plan,
        none => panic("zonk: Range equality plan disappeared")
    }
    make_h_range_for_in_plan(
        h_range_for_in_owner(value), h_range_for_in_start(value),
        h_range_for_in_end(value), h_range_for_in_inclusive(value),
        order, equality,
        h_range_for_in_range_binder(value),
        h_range_for_in_counter_binder(value),
        h_range_for_in_finished_binder(value),
        h_for_in_binding_binder(value))
}

fn zonk_pattern_field_plan(
    ctx: ZonkCtx, value: HPatternFieldPlan
) -> HPatternFieldPlan {
    make_h_pattern_field_plan(
        h_pattern_field_projection(value),
        zonk_pattern_plan(ctx, h_pattern_field_pattern(value)))
}

fn zonk_pattern_plan(ctx: ZonkCtx, value: HPatternPlan) -> HPatternPlan {
    let kind = h_pattern_kind(value)
    if kind == 0 { return h_pattern_wildcard() }
    if kind == 1 {
        let binding = h_pattern_plan_binding(value)
        return h_pattern_binding(HPatternBinding {
            name: binding.name, def_id: binding.def_id,
            slot: binding.slot, ty: zonk_type(ctx, binding.ty)
        })
    }
    if kind == 2 { return h_pattern_literal() }
    if kind == 3 {
        return h_pattern_tuple(h_pattern_plan_children(value).map(fn(child) {
            zonk_pattern_plan(ctx, child)
        }))
    }
    if kind == 4 {
        return h_pattern_struct(
            h_pattern_plan_struct_owner(value),
            h_pattern_plan_fields(value).map(fn(field) {
                zonk_pattern_field_plan(ctx, field)
            }))
    }
    if kind == 5 {
        return h_pattern_variant(
            h_pattern_plan_variant(value),
            h_pattern_plan_fields(value).map(fn(field) {
                zonk_pattern_field_plan(ctx, field)
            }))
    }
    if kind == 6 {
        return h_pattern_or(h_pattern_plan_children(value).map(fn(child) {
            zonk_pattern_plan(ctx, child)
        }))
    }
    panic("zonk: unknown exact PatternPlan kind")
}

fn label_effect(
    names: Map<Int, Str>, canonical_ids: Map<Int, Int>, e: Effect
) -> Effect {
    match e {
        Effect::FailEffect { error_type } =>
            Effect::FailEffect {
                error_type: label_vars(names, canonical_ids, error_type) },
        Effect::MutEffect { state_type } =>
            Effect::MutEffect {
                state_type: label_vars(names, canonical_ids, state_type) },
        Effect::CustomEffect { reference, name, type_args } =>
            Effect::CustomEffect { reference: reference, name: name,
                type_args: type_args.map(fn(a) {
                    label_vars(names, canonical_ids, a) }) },
        Effect::SystemEffect { .. } => e,
        Effect::UnsafeEffect => e,
    }
}

fn canonical_type_var_id(
    canonical_ids: Map<Int, Int>, resolved_id: Int
) -> Int {
    canonical_ids.get(resolved_id).unwrap_or(resolved_id)
}

fn label_effect_row(
    names: Map<Int, Str>, canonical_ids: Map<Int, Int>, row: EffectRow
) -> EffectRow {
    EffectRow {
        effects: row.effects.map(fn(e) {
            label_effect(names, canonical_ids, e) }),
        tail: row.tail.map(fn(id) {
            canonical_type_var_id(canonical_ids, id) })
    }
}

fn label_vars(
    names: Map<Int, Str>, canonical_ids: Map<Int, Int>, t: Type
) -> Type {
    match t {
        Type::TypeVar { id, name } => {
            let labeled_name = match names.get(id) {
                some(n) => some(n), none => name
            }
            Type::TypeVar {
                id: canonical_type_var_id(canonical_ids, id),
                name: labeled_name
            }
        },
        Type::FnType { params, return_type, effects } =>
            Type::FnType {
                params: params.map(fn(p) {
                    label_vars(names, canonical_ids, p) }),
                return_type: label_vars(names, canonical_ids, return_type),
                effects: label_effect_row(names, canonical_ids, effects)
            },
        Type::StructType { name, type_params } =>
            Type::StructType {
                name: name,
                type_params: type_params.map(fn(p) {
                    label_vars(names, canonical_ids, p) })
            },
        Type::EnumType { name, type_params } =>
            Type::EnumType {
                name: name,
                type_params: type_params.map(fn(p) {
                    label_vars(names, canonical_ids, p) })
            },
        Type::GenericType { base, args } =>
            Type::GenericType {
                base: label_vars(names, canonical_ids, base),
                args: args.map(fn(a) {
                    label_vars(names, canonical_ids, a) })
            },
        Type::RecordType { fields, tail, tail_name } => {
            let new_tail_name = match tail {
                some(t_id) => match names.get(t_id) {
                    some(n) => some(n),
                    none => tail_name,
                },
                none => tail_name,
            }
            Type::RecordType {
                fields: fields.map(fn(f) { RecordField {
                    name: f.name,
                    ty: label_vars(names, canonical_ids, f.ty) } }),
                tail: tail.map(fn(id) {
                    canonical_type_var_id(canonical_ids, id) }),
                tail_name: new_tail_name
            }
        },
        Type::EffectRowType { effects, tail } =>
            Type::EffectRowType {
                effects: effects.map(fn(e) {
                    label_effect(names, canonical_ids, e) }),
                tail: tail.map(fn(id) {
                    canonical_type_var_id(canonical_ids, id) })
            },
        Type::TupleType { elements } =>
            Type::TupleType { elements: elements.map(fn(e) {
                label_vars(names, canonical_ids, e) }) },
        Type::PtrType { pointee } =>
            Type::PtrType {
                pointee: label_vars(names, canonical_ids, pointee) },
        Type::IntType => t,
        Type::FloatType => t,
        Type::StrType => t,
        Type::BoolType => t,
        Type::UnitType => t,
        Type::NeverType => t,
        Type::AnyType => t,
        Type::ErrorType => t,
    }
}

pub fn zonk_row(ctx: ZonkCtx, r: EffectRow) -> EffectRow {
    label_effect_row(
        ctx.names, ctx.canonical_type_var_ids,
        apply_subst_row(ctx.subst, r))
}

pub fn zonk_param(ctx: ZonkCtx, p: HParam) -> HParam {
    HParam { name: p.name, ty: zonk_type(ctx, p.ty), def_id: p.def_id, is_mutable: p.is_mutable }
}

fn zonk_dispatch(ctx: ZonkCtx, dispatch: TraitDispatch?) -> TraitDispatch? {
    match dispatch {
        some(TraitDispatch::Tuple { element_types, elements }) => {
            let mut zonked_types: List<Type> = []
            let mut zonked_elements: List<TraitDispatch> = []
            for element_type in element_types {
                zonked_types.push(zonk_type(ctx, element_type))
            }
            for element in elements {
                match zonk_dispatch(ctx, some(element)) {
                    some(zonked) => zonked_elements.push(zonked),
                    none => panic("zonk: tuple dispatch element disappeared"),
                }
            }
            some(TraitDispatch::Tuple {
                element_types: zonked_types,
                elements: zonked_elements
            })
        },
        _ => dispatch,
    }
}

pub fn zonk_block(ctx: ZonkCtx, block: HExpr) -> HExpr {
    match block {
        HExpr::Block { stmts, tail, ty, effects, span } => {
            let z_stmts = stmts.map(fn(s) { zonk_stmt(ctx, s) })
            let z_tail = match tail {
                some(t) => some(zonk_expr(ctx, t)),
                none => none,
            }
            HExpr::Block {
                stmts: z_stmts,
                tail: z_tail,
                ty: zonk_type(ctx, ty),
                effects: zonk_row(ctx, effects),
                span: span
            }
        },
        _ => zonk_expr(ctx, block),
    }
}

fn zonk_stmt(ctx: ZonkCtx, stmt: HStmt) -> HStmt {
    match stmt {
        HStmt::Let { name, name_span, def_id, ty, init, span } =>
            HStmt::Let { name: name, name_span: name_span, def_id: def_id, ty: zonk_type(ctx, ty), init: zonk_expr(ctx, init), span: span },
        HStmt::Var { name, name_span, def_id, ty, init, span } =>
            HStmt::Var { name: name, name_span: name_span, def_id: def_id, ty: zonk_type(ctx, ty), init: zonk_expr(ctx, init), span: span },
        HStmt::Assign { target, value, span } =>
            HStmt::Assign { target: zonk_expr(ctx, target), value: zonk_expr(ctx, value), span: span },
        HStmt::ExprStmt { expr, span } =>
            HStmt::ExprStmt { expr: zonk_expr(ctx, expr), span: span },
        HStmt::Return { value, span } => {
            let z_val = match value {
                some(v) => some(zonk_expr(ctx, v)),
                none => none,
            }
            HStmt::Return { value: z_val, span: span }
        },
        HStmt::While { condition, body, span } =>
            HStmt::While { condition: zonk_expr(ctx, condition), body: zonk_block(ctx, body), span: span },
        HStmt::ForIn { binding, binding_span, def_id, destructure, plan,
                       iterable, body, iterable_type_name, iter_type_name, span } =>
            HStmt::ForIn { binding: binding, binding_span: binding_span,
                def_id: def_id, destructure: destructure,
                plan: plan.map(fn(value) { zonk_for_in_plan(ctx, value) }),
                iterable: zonk_expr(ctx, iterable), body: zonk_block(ctx, body),
                iterable_type_name: iterable_type_name,
                iter_type_name: iter_type_name, span: span },
        HStmt::Break { span } => stmt,
        HStmt::Continue { span } => stmt,
        HStmt::LetDestructure { pattern, pattern_plan, bindings, init, span } => {
            let z_bindings = bindings.map(fn(b) {
                HLetDestructureBinding { name: b.name, def_id: b.def_id,
                    slot: b.slot, projection: b.projection,
                    ty: zonk_type(ctx, b.ty) }
            })
            HStmt::LetDestructure { pattern: pattern,
                pattern_plan: pattern_plan.map(fn(plan) {
                    zonk_pattern_plan(ctx, plan)
                }), bindings: z_bindings,
                init: zonk_expr(ctx, init), span: span }
        },
        HStmt::IfLet { pattern, pattern_plan, bindings, expr,
                       then_block, else_block, span } => {
            let z_else = match else_block {
                some(eb) => some(zonk_block(ctx, eb)),
                none => none,
            }
            HStmt::IfLet { pattern: pattern,
                pattern_plan: pattern_plan.map(fn(plan) {
                    zonk_pattern_plan(ctx, plan)
                }),
                bindings: bindings.map(fn(b) { HPatternBinding {
                    name: b.name, def_id: b.def_id,
                    slot: b.slot,
                    ty: zonk_type(ctx, b.ty) } }),
                expr: zonk_expr(ctx, expr),
                then_block: zonk_block(ctx, then_block),
                else_block: z_else, span: span }
        },
        HStmt::Drop {
            name, def_id, slot, place_target, site, reason, ty, span
        } =>
            HStmt::Drop { name: name, def_id: def_id, slot: slot,
                place_target: place_target.map(fn(value) {
                    zonk_expr(ctx, value)
                }), site: site, reason: reason,
                ty: zonk_type(ctx, ty), span: span }
    }
}

pub fn zonk_expr(ctx: ZonkCtx, expr: HExpr) -> HExpr {
    let z_ty = zonk_type(ctx, hexpr_type(expr))
    let z_eff = zonk_row(ctx, hexpr_effects(expr))
    let z_span = hexpr_span(expr)

    match expr {
        HExpr::IntLit { value, .. } =>
            HExpr::IntLit { value: value, ty: z_ty, effects: z_eff, span: z_span },
        HExpr::FloatLit { value, .. } =>
            HExpr::FloatLit { value: value, ty: z_ty, effects: z_eff, span: z_span },
        HExpr::StrLit { value, .. } =>
            HExpr::StrLit { value: value, ty: z_ty, effects: z_eff, span: z_span },
        HExpr::BoolLit { value, .. } =>
            HExpr::BoolLit { value: value, ty: z_ty, effects: z_eff, span: z_span },
        HExpr::Ident { name, resolved_name, def_id, source_slot,
                       callee_identity, dict_closure_dicts,
                       callable_instantiation, .. } => {
            let ident = HExpr::Ident {
                name: name, resolved_name: resolved_name, def_id: def_id,
                source_slot: source_slot, callee_identity: callee_identity,
                dict_closure_dicts: dict_closure_dicts,
                callable_instantiation: callable_instantiation,
                ty: z_ty, effects: z_eff, span: z_span
            }
            match ctx.dict_resolver {
                some(resolver) => resolve_value_ident(
                    resolver, ident, ctx.subst),
                none => ident,
            }
        },
        // B-104 D4: synthesised by dict_lower AFTER checking/zonking — never
        // seen here; ty is already concrete (TupleType{[]}).  Pass through.
        HExpr::DictConstruct { base_dict, plan, inner, .. } =>
            HExpr::DictConstruct { base_dict: base_dict, plan: plan,
                inner: inner, ty: z_ty, effects: z_eff, span: z_span },
        HExpr::BinOp { op, left, right, eq_dispatch, ord_dispatch,
                       eq_plan, ord_plan, .. } =>
            HExpr::BinOp { op: op, left: zonk_expr(ctx, left),
                right: zonk_expr(ctx, right),
                eq_dispatch: zonk_dispatch(ctx, eq_dispatch),
                ord_dispatch: zonk_dispatch(ctx, ord_dispatch),
                eq_plan: zonk_operator_plan(ctx, eq_plan),
                ord_plan: zonk_operator_plan(ctx, ord_plan),
                ty: z_ty, effects: z_eff, span: z_span },
        HExpr::UnaryOp { op, operand, .. } =>
            HExpr::UnaryOp { op: op, operand: zonk_expr(ctx, operand), ty: z_ty, effects: z_eff, span: z_span },
        HExpr::Call { callee, args, type_args, resolved_dicts, handled_evidence, callee_ref,
                      method_ref, system_host, .. } =>
            HExpr::Call {
                // A syntactic Ident callee uses the direct ABI and gets its
                // evidence from Call.resolved_dicts.  Every other recursive
                // position is a value position and must form a real closure.
                callee: zonk_direct_callee(ctx, callee),
                args: args.map(fn(a) { zonk_expr(ctx, a) }),
                type_args: type_args.map(fn(t) { zonk_type(ctx, t) }),
                resolved_dicts: resolved_dicts,
                handled_evidence: handled_evidence,
                callee_ref: callee_ref,
                method_ref: zonk_method_call_ref(ctx, method_ref),
                system_host: system_host,
                ty: z_ty, effects: z_eff, span: z_span
            },
        HExpr::FieldAccess { receiver, field, access_kind, projection, .. } =>
            HExpr::FieldAccess { receiver: zonk_expr(ctx, receiver),
                field: field, access_kind: access_kind, projection: projection,
                ty: z_ty, effects: z_eff, span: z_span },
        HExpr::StructLit { name, owner_ref, type_args, fields, spread,
                           constructor, .. } => {
            let z_spread = match spread {
                some(s) => some(zonk_expr(ctx, s)),
                none => none,
            }
            HExpr::StructLit {
                name: name,
                owner_ref: owner_ref,
                type_args: type_args.map(fn(t) { zonk_type(ctx, t) }),
                fields: fields.map(fn(f) { HNominalStructFieldInit {
                    name: f.name, field_ref: f.field_ref,
                    field_index: f.field_index,
                    value: zonk_expr(ctx, f.value) } }),
                spread: z_spread,
                constructor: constructor,
                ty: z_ty, effects: z_eff, span: z_span
            }
        },
        HExpr::NamedVariantConstruct { enum_name, variant_name, variant_ref,
                                       fields, spread, constructor, .. } => {
            let z_spread = match spread {
                some(s) => some(zonk_expr(ctx, s)),
                none => none,
            }
            HExpr::NamedVariantConstruct {
                enum_name: enum_name, variant_name: variant_name,
                variant_ref: variant_ref,
                fields: fields.map(fn(f) { HStructFieldInit { name: f.name, field_ref: f.field_ref, value: zonk_expr(ctx, f.value) } }),
                spread: z_spread,
                constructor: constructor,
                ty: z_ty, effects: z_eff, span: z_span
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } =>
            HExpr::MatchExpr {
                scrutinee: zonk_expr(ctx, scrutinee),
                arms: arms.map(fn(a) {
                    let z_guard = match a.guard {
                        some(g) => some(zonk_expr(ctx, g)),
                        none => none,
                    }
                    HMatchArm { pattern: a.pattern,
                        pattern_plan: a.pattern_plan.map(fn(plan) {
                            zonk_pattern_plan(ctx, plan)
                        }),
                        bindings: a.bindings.map(fn(b) { HPatternBinding {
                            name: b.name, def_id: b.def_id,
                            slot: b.slot,
                            ty: zonk_type(ctx, b.ty) } }),
                        guard: z_guard, body: zonk_expr(ctx, a.body),
                        span: a.span }
                }),
                ty: z_ty, effects: z_eff, span: z_span
            },
        HExpr::Block { stmts, tail, .. } => {
            let z_tail = match tail {
                some(t) => some(zonk_expr(ctx, t)),
                none => none,
            }
            HExpr::Block {
                stmts: stmts.map(fn(s) { zonk_stmt(ctx, s) }),
                tail: z_tail,
                ty: z_ty, effects: z_eff, span: z_span
            }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            let z_else = match else_branch {
                some(eb) => some(zonk_expr(ctx, eb)),
                none => none,
            }
            HExpr::IfExpr {
                condition: zonk_expr(ctx, condition),
                then_branch: zonk_block(ctx, then_branch),
                else_branch: z_else,
                ty: z_ty, effects: z_eff, span: z_span
            }
        },
        HExpr::StringInterp { parts, plan, .. } =>
            HExpr::StringInterp {
                parts: parts.map(fn(p) {
                    match p {
                        HStringInterpPart::Literal(s) => p,
                        HStringInterpPart::Expression(e) => HStringInterpPart::Expression(zonk_expr(ctx, e)),
                    }
                }),
                plan: plan,
                ty: z_ty, effects: z_eff, span: z_span
            },
        HExpr::TryCatch { body, arms, .. } =>
            HExpr::TryCatch {
                body: zonk_expr(ctx, body),
                arms: arms.map(fn(a) {
                    HMatchArm {
                        pattern: a.pattern,
                        pattern_plan: a.pattern_plan.map(fn(plan) {
                            zonk_pattern_plan(ctx, plan)
                        }),
                        bindings: a.bindings.map(fn(b) { HPatternBinding {
                            name: b.name, def_id: b.def_id,
                            slot: b.slot,
                            ty: zonk_type(ctx, b.ty) } }),
                        guard: match a.guard {
                            some(g) => some(zonk_expr(ctx, g)),
                            none => none
                        },
                        body: zonk_expr(ctx, a.body),
                        span: a.span
                    }
                }),
                ty: z_ty, effects: z_eff, span: z_span
            },
        HExpr::HandleExpr { body, handlers, installed_evidence, .. } =>
            HExpr::HandleExpr {
                body: zonk_expr(ctx, body),
                handlers: handlers.map(fn(h) {
                    HEffectHandler {
                        effect_name: h.effect_name,
                        handled_ref: h.handled_ref,
                        operation_ref: h.operation_ref,
                        fail_ref: h.fail_ref,
                        executable_ref: h.executable_ref, op_name: h.op_name,
                        captures: h.captures.map(fn(capture) { HLambdaCapture {
                            source: capture.source, target: capture.target,
                            value: capture.value.map(fn(value) {
                                zonk_expr(ctx, value) }),
                            resource_site: capture.resource_site } }),
                        handled_evidence_bindings:
                            h.handled_evidence_bindings,
                        evidence_captures: h.evidence_captures,
                        params: h.params.map(fn(p) { zonk_param(ctx, p) }),
                        resume_binding: match h.resume_binding {
                            some(binding) => some(HPatternBinding {
                                name: binding.name,
                                def_id: binding.def_id,
                                slot: binding.slot,
                                ty: zonk_type(ctx, binding.ty)
                            }),
                            none => none
                        },
                        body: zonk_expr(ctx, h.body)
                    }
                }),
                installed_evidence: installed_evidence,
                ty: z_ty, effects: z_eff, span: z_span
            },
        HExpr::Lambda { executable_ref, params, captures, handled_evidence_bindings, evidence_captures, return_type, body, .. } =>
            HExpr::Lambda {
                executable_ref: executable_ref,
                params: params.map(fn(p) { zonk_param(ctx, p) }),
                captures: captures.map(fn(capture) { HLambdaCapture {
                    source: capture.source, target: capture.target,
                    value: capture.value.map(fn(value) {
                        zonk_expr(ctx, value) }),
                    resource_site: capture.resource_site } }),
                handled_evidence_bindings: handled_evidence_bindings,
                evidence_captures: evidence_captures,
                return_type: zonk_type(ctx, return_type),
                body: zonk_expr(ctx, body),
                ty: z_ty, effects: z_eff, span: z_span
            },
        HExpr::EffectOp { effect_name, op_name, operation_ref, fail_ref, handled_evidence,
                          args, .. } =>
            HExpr::EffectOp { effect_name: effect_name, op_name: op_name,
                operation_ref: operation_ref, fail_ref: fail_ref,
                handled_evidence: handled_evidence,
                args: args.map(fn(a) { zonk_expr(ctx, a) }),
                ty: z_ty, effects: z_eff, span: z_span },
        HExpr::ListLit { elements, plan, .. } =>
            HExpr::ListLit { elements: elements.map(fn(e) { zonk_expr(ctx, e) }),
                plan: plan.map(fn(value) {
                    zonk_list_literal_plan(ctx, value) }),
                ty: z_ty, effects: z_eff, span: z_span },
        HExpr::TupleLit { elements, constructor, .. } =>
            HExpr::TupleLit { elements: elements.map(fn(e) { zonk_expr(ctx, e) }),
                constructor: constructor, ty: z_ty, effects: z_eff, span: z_span },
        HExpr::IndexExpr { receiver, index, call_plan, projection, .. } =>
            HExpr::IndexExpr { receiver: zonk_expr(ctx, receiver),
                index: zonk_expr(ctx, index), call_plan: call_plan,
                projection: projection, ty: z_ty, effects: z_eff, span: z_span },
        // B-098: Clone is inserted by the Perceus pass (post-zonk), so it never
        // reaches zonk in practice; the arm exists only for match exhaustiveness.
        HExpr::Clone { inner, .. } =>
            HExpr::Clone { inner: zonk_expr(ctx, inner), ty: z_ty, effects: z_eff, span: z_span },
        HExpr::Take { source, source_slot, saved_slot, site, .. } =>
            HExpr::Take { source: zonk_expr(ctx, source),
                source_slot: source_slot, saved_slot: saved_slot, site: site,
                ty: z_ty, effects: z_eff, span: z_span },
        // B-113: return in expression position (match arm)
        HExpr::ReturnExpr { value, .. } => match value {
            some(v) => HExpr::ReturnExpr { value: some(zonk_expr(ctx, v)), ty: z_ty, effects: z_eff, span: z_span },
            none => HExpr::ReturnExpr { value: none, ty: z_ty, effects: z_eff, span: z_span },
        },
        // B-125: unsafe block — zonk the body
        HExpr::UnsafeBlock { body, .. } =>
            HExpr::UnsafeBlock { body: zonk_expr(ctx, body), ty: z_ty, effects: z_eff, span: z_span },
    }
}

fn mark_zonk_direct_callee(ident: HExpr) -> HExpr {
    match ident {
        HExpr::Ident { .. } => HExpr::Ident {
            ..ident, dict_closure_dicts: some([])
        },
        _ => panic("zonk: direct callee marker requires Ident")
    }
}

fn clear_zonk_local_callee_marker(ident: HExpr) -> HExpr {
    match ident {
        HExpr::Ident { .. } => HExpr::Ident {
            ..ident, dict_closure_dicts: none
        },
        _ => panic("zonk: local callee marker requires Ident")
    }
}

fn zonk_direct_callee(ctx: ZonkCtx, callee: HExpr) -> HExpr {
    match callee {
        HExpr::Ident { name, resolved_name, def_id, source_slot,
                       callee_identity, dict_closure_dicts,
                       callable_instantiation, .. } => {
            let z_ty = zonk_type(ctx, hexpr_type(callee))
            let z_eff = zonk_row(ctx, hexpr_effects(callee))
            let z_span = hexpr_span(callee)
            let ident = HExpr::Ident {
                name: name, resolved_name: resolved_name, def_id: def_id,
                source_slot: source_slot, callee_identity: callee_identity,
                dict_closure_dicts: dict_closure_dicts,
                callable_instantiation: callable_instantiation,
                ty: z_ty, effects: z_eff, span: z_span
            }
            match ctx.dict_resolver {
                some(resolver) => {
                    match value_binding_kind(resolver, def_id) {
                        ValueBindingKind::ConstGetter =>
                            resolve_value_ident(resolver, ident, ctx.subst),
                        ValueBindingKind::DirectCallable =>
                            mark_zonk_direct_callee(ident),
                        ValueBindingKind::ExternCallable =>
                            mark_zonk_direct_callee(ident),
                        ValueBindingKind::LocalBorrow => match def_id {
                            some(id) => {
                                if has_variant_ctor_origin_def_id(resolver, id) {
                                    mark_zonk_direct_callee(ident)
                                } else {
                                    clear_zonk_local_callee_marker(ident)
                                }
                            },
                            none => clear_zonk_local_callee_marker(ident)
                        }
                    }
                },
                none => ident
            }
        },
        _ => zonk_expr(ctx, callee),
    }
}

