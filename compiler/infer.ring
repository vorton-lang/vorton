use types::{Type, Effect, EffectRow, StructField, EnumVariant,
    INT, FLOAT, STR, BOOL, UNIT, NEVER, ANY, EMPTY_ROW,
    type_to_string, make_option_type, is_option_type, option_inner,
    type_to_builtin_name, effect_row, nominal_display_name}
use ast::{Program, Decl, Expr, Stmt, Param, MatchArm, StructFieldInit,
    EffectHandler, StringInterpPart, Pattern, BinOp, UnaryOp, TypeExpr,
    TypeParam, TypeBound, Span, UseDecl, DestructureBinding, span_zero,
    EffectOpDecl}
use hir::{HExpr, HStmt, HDecl, HParam, HMatchArm, HEffectHandler,
    HPatternBinding,
    HStructFieldInit, HNominalStructFieldInit, HFieldAccessKind,
    HStringInterpPart, HProgram, DerivedImpl,
    TraitDispatch, DictDispatchInfo, DictRef, TraitBound,
    MethodCallRef, make_intrinsic_method_call_ref,
    HStructField, HEnumVariant, HEffectOp, HTraitMethod,
    HForInDestructure, HLetDestructureBinding, ValueBindingKind,
    trait_bound_param_name,
    BUILTIN_RANGE, BUILTIN_LIST, BUILTIN_MAP, BUILTIN_SET, BUILTIN_OPTION,
    hexpr_type, hexpr_effects, hexpr_span, map_index_helper_identity}
use diagnostics::{DiagnosticContext, DiagnosticNote, CollectingSink, Severity, make_diag}
use codes::{E0201, E0203, E0206, E0301, E0303, E0304, E0305, E0306,
    E0307, E0308, E0309, E0402, E0411, E0503, E0601, E0705, W0001}
use union_find::{UnionFind}
use env::{TypeEnv, TypeScheme, StructDef, EnumDef, EffectDef,
    EffectOpDef, TraitDef, TraitMethodDef, ImplEntry,
    ImplMethodSchemeCore, TypeAliasDef,
    BuiltInKind, mono, apply_subst, apply_subst_row, apply_subst_map,
    build_scheme_var_map, impl_method_core_as_scheme,
    find_impl, lookup_variant}
use unify::{unify, empty_subst}
use infer_ctx::{InferCtx, InferResult, FnBoundsEntry, CompileError,
    PendingDictPurpose,
    type_error, type_error_with_notes, merge_effects, unify_at, unify_at_noted, update_fn_effects,
    resolve_type_expr, resolve_self_type, resolve_named_type,
    bind_pattern, resolve_dict_ref_for_type,
    resolve_or_defer_dicts_from_scheme,
    resolve_or_defer_dicts_from_impl_owner,
    register_callable_value_shadow,
    pending_dict_checkpoint, has_pending_dicts_since,
    remove_fail_effect,
    generalize, free_type_vars, resolve_relative_qualifier}
use exhaustive::{check_exhaustive}
use infer_helpers::{MethodLookupResult, StmtResult,
    is_value_type, cancel_local_mut_effects, resolve_var_id,
    check_assign_target_mutable, find_root_expr, get_assign_target_root_def_id, get_hexpr_root_type,
    infer_ident, infer_numeric_op, is_primitive_ord,
    resolve_trait_dispatch, resolve_eq_dispatch,
    is_bounded_direct_callable_ident, resolve_callee_metadata,
    check_expr_is_let_def, get_expr_def_id, is_mut_method_call, check_receiver_mutability,
    lookup_impl_method, lookup_trait_method,
    rewrite_bare_enum_bindings}
use ir_identity::{IntrinsicRef}

// ============================================================
// Block inference (from infer-stmt.ts)
// ============================================================

pub fn infer_block(mut ctx: InferCtx, body: Expr, initial_subst: UnionFind?) -> InferResult {
    match body {
        Expr::Block { stmts, tail, span } => {
            let mut subst = match initial_subst { some(s) => s, none => ctx.subst }
            let mut effects: EffectRow = EMPTY_ROW
            let mut hstmts: List<HStmt> = []

            for stmt in stmts {
                let sr = infer_stmt(ctx, stmt, subst)
                subst = sr.subst
                let me = merge_effects(ctx.sink, ctx.env, effects, sr.effects, subst, span)
                effects = me.0
                subst = me.1
                hstmts.push(sr.hstmt)
            }

            let mut tail_hexpr: HExpr? = none
            let mut block_type: Type = UNIT

            match tail {
                some(t) => {
                    let tr = infer_expr(ctx, t, subst)
                    subst = tr.subst
                    let me = merge_effects(ctx.sink, ctx.env, effects, tr.effects, subst, span)
                    effects = me.0
                    subst = me.1
                    tail_hexpr = some(tr.hexpr)
                    block_type = hexpr_type(tr.hexpr)
                },
                none => {}
            }

            let hblock = HExpr::Block {
                stmts: hstmts, tail: tail_hexpr,
                ty: block_type, effects: effects, span: span
            }
            InferResult { hexpr: hblock, subst: subst, effects: effects }
        },
        _ => panic("unreachable: infer_block called with non-block expression")
    }
}

// Nested source blocks own one lexical frame.  Restore it on both success and
// CompileError so a failed branch cannot poison a sibling or later declaration.
fn infer_scoped_block(
    mut ctx: InferCtx, body: Expr, initial_subst: UnionFind?
) -> InferResult {
    ctx.env.push_scope()
    let scoped_result = some(
        infer_block(ctx, body, initial_subst)
    ) catch { _ => none }
    ctx.env.pop_scope()
    match scoped_result {
        some(result) => result,
        none => fail.raise(CompileError {})
    }
}

// ============================================================
// Statement inference (from infer-stmt.ts)
// ============================================================

fn collect_bounded_callable_values_in_stmt(
    ctx: InferCtx, stmt: HStmt, mut found: List<HExpr>
) {
    match stmt {
        HStmt::Let { init, .. } =>
            collect_bounded_callable_values(ctx, init, found),
        HStmt::Var { init, .. } =>
            collect_bounded_callable_values(ctx, init, found),
        HStmt::Assign { target, value, .. } => {
            collect_bounded_callable_values(ctx, target, found)
            collect_bounded_callable_values(ctx, value, found)
        },
        HStmt::ExprStmt { expr, .. } =>
            collect_bounded_callable_values(ctx, expr, found),
        HStmt::Return { value, .. } => match value {
            some(v) => collect_bounded_callable_values(ctx, v, found),
            none => {}
        },
        HStmt::While { condition, body, .. } => {
            collect_bounded_callable_values(ctx, condition, found)
            collect_bounded_callable_values(ctx, body, found)
        },
        HStmt::ForIn { iterable, body, .. } => {
            collect_bounded_callable_values(ctx, iterable, found)
            collect_bounded_callable_values(ctx, body, found)
        },
        HStmt::LetDestructure { init, .. } =>
            collect_bounded_callable_values(ctx, init, found),
        HStmt::IfLet { expr, then_block, else_block, .. } => {
            collect_bounded_callable_values(ctx, expr, found)
            collect_bounded_callable_values(ctx, then_block, found)
            match else_block {
                some(block) =>
                    collect_bounded_callable_values(ctx, block, found),
                none => {}
            }
        },
        HStmt::Break { .. } => {},
        HStmt::Continue { .. } => {},
        HStmt::Drop { .. } => {}
    }
}

fn collect_bounded_callable_values(
    ctx: InferCtx, expr: HExpr, mut found: List<HExpr>
) {
    match expr {
        HExpr::Ident { .. } => {
            if is_bounded_direct_callable_ident(ctx, expr) {
                found.push(expr)
            }
        },
        HExpr::BinOp { left, right, .. } => {
            collect_bounded_callable_values(ctx, left, found)
            collect_bounded_callable_values(ctx, right, found)
        },
        HExpr::UnaryOp { operand, .. } =>
            collect_bounded_callable_values(ctx, operand, found),
        HExpr::Call { callee, args, .. } => {
            // A bare Ident callee is a direct invocation, not a function value.
            match callee {
                HExpr::Ident { .. } => {},
                _ => collect_bounded_callable_values(ctx, callee, found)
            }
            for arg in args {
                collect_bounded_callable_values(ctx, arg, found)
            }
        },
        HExpr::FieldAccess { receiver, .. } =>
            collect_bounded_callable_values(ctx, receiver, found),
        HExpr::StructLit { fields, spread, .. } => {
            for field in fields {
                collect_bounded_callable_values(ctx, field.value, found)
            }
            match spread {
                some(value) =>
                    collect_bounded_callable_values(ctx, value, found),
                none => {}
            }
        },
        HExpr::NamedVariantConstruct { fields, spread, .. } => {
            for field in fields {
                collect_bounded_callable_values(ctx, field.value, found)
            }
            match spread {
                some(value) =>
                    collect_bounded_callable_values(ctx, value, found),
                none => {}
            }
        },
        HExpr::MatchExpr { scrutinee, arms, .. } => {
            collect_bounded_callable_values(ctx, scrutinee, found)
            for arm in arms {
                match arm.guard {
                    some(guard) =>
                        collect_bounded_callable_values(ctx, guard, found),
                    none => {}
                }
                collect_bounded_callable_values(ctx, arm.body, found)
            }
        },
        HExpr::Block { stmts, tail, .. } => {
            for stmt in stmts {
                collect_bounded_callable_values_in_stmt(ctx, stmt, found)
            }
            match tail {
                some(value) =>
                    collect_bounded_callable_values(ctx, value, found),
                none => {}
            }
        },
        HExpr::IfExpr { condition, then_branch, else_branch, .. } => {
            collect_bounded_callable_values(ctx, condition, found)
            collect_bounded_callable_values(ctx, then_branch, found)
            match else_branch {
                some(value) =>
                    collect_bounded_callable_values(ctx, value, found),
                none => {}
            }
        },
        HExpr::StringInterp { parts, .. } => {
            for part in parts {
                match part {
                    HStringInterpPart::Expression(value) =>
                        collect_bounded_callable_values(ctx, value, found),
                    _ => {}
                }
            }
        },
        HExpr::TryCatch { body, arms, .. } => {
            collect_bounded_callable_values(ctx, body, found)
            for arm in arms {
                match arm.guard {
                    some(guard) =>
                        collect_bounded_callable_values(ctx, guard, found),
                    none => {}
                }
                collect_bounded_callable_values(ctx, arm.body, found)
            }
        },
        HExpr::HandleExpr { body, handlers, .. } => {
            collect_bounded_callable_values(ctx, body, found)
            for handler in handlers {
                collect_bounded_callable_values(ctx, handler.body, found)
            }
        },
        HExpr::Lambda { body, .. } =>
            collect_bounded_callable_values(ctx, body, found),
        HExpr::EffectOp { args, .. } => {
            for arg in args {
                collect_bounded_callable_values(ctx, arg, found)
            }
        },
        HExpr::RangeExpr { start, end, .. } => {
            collect_bounded_callable_values(ctx, start, found)
            collect_bounded_callable_values(ctx, end, found)
        },
        HExpr::ListLit { elements, .. } => {
            for element in elements {
                collect_bounded_callable_values(ctx, element, found)
            }
        },
        // Keep this separate from ListLit. LLVM OrPattern lowering does not
        // bind payload fields, so a shared arm leaks `elements` into codegen.
        HExpr::TupleLit { elements, .. } => {
            for element in elements {
                collect_bounded_callable_values(ctx, element, found)
            }
        },
        HExpr::IndexExpr { receiver, index, .. } => {
            collect_bounded_callable_values(ctx, receiver, found)
            collect_bounded_callable_values(ctx, index, found)
        },
        HExpr::Clone { inner, .. } =>
            collect_bounded_callable_values(ctx, inner, found),
        HExpr::ReturnExpr { value, .. } => match value {
            some(inner) =>
                collect_bounded_callable_values(ctx, inner, found),
            none => {}
        },
        HExpr::UnsafeBlock { body, .. } =>
            collect_bounded_callable_values(ctx, body, found),
        HExpr::IntLit { .. } => {},
        HExpr::FloatLit { .. } => {},
        HExpr::StrLit { .. } => {},
        HExpr::BoolLit { .. } => {},
        HExpr::DictConstruct { .. } => {}
    }
}

fn hexpr_contains_bounded_callable_value(ctx: InferCtx, expr: HExpr) -> Bool {
    let found: List<HExpr> = []
    collect_bounded_callable_values(ctx, expr, found)
    found.len() > 0
}

// Register each exact DefId/live-scheme callable value once for its owner.
// The shadow shares the canonical evidence/assoc resolver with calls but never
// attaches DictRefs; resolve_value_ident remains the final-zonk authority.
fn register_bounded_callable_value_shadows_inner(
    mut ctx: InferCtx, expr: HExpr, s: UnionFind
) {
    let found: List<HExpr> = []
    collect_bounded_callable_values(ctx, expr, found)
    for callable in found {
        match resolve_callee_metadata(ctx, callable) {
            some(metadata) => match metadata.kind {
                ValueBindingKind::DirectCallable |
                ValueBindingKind::ExternCallable => {
                    if metadata.live_scheme.bounds.len() > 0 {
                        register_callable_value_shadow(
                            ctx, metadata.live_scheme,
                            hexpr_type(callable), s,
                            hexpr_span(callable))
                    }
                },
                ValueBindingKind::ConstGetter |
                ValueBindingKind::LocalBorrow => {
                }
            },
            none => {}
        }
    }
}

pub fn register_bounded_callable_value_shadows(
    ctx: InferCtx, expr: HExpr, s: UnionFind
) {
    register_bounded_callable_value_shadows_inner(ctx, expr, s)
}

// B-163 C': non-Range for-in is lowered while inference still owns the
// authoritative trait registry, method schemes, dictionaries, and effects.
// These helpers deliberately validate a named protocol before invoking the
// ordinary method-call inference path; an inherent same-spelled method cannot
// manufacture Iterable/Iterator evidence.
fn require_for_protocol_impl(
    mut ctx: InferCtx, ty: Type, trait_name: Str,
    subst: UnionFind, span: Span
) -> ImplEntry {
    let concrete = apply_subst(subst, ty)
    match concrete {
        Type::TypeVar { .. } => {
            let trait_display = nominal_display_name(trait_name)
            let _ = type_error(ctx.sink, E0503,
                "for..in cannot lower abstract '${type_to_string(concrete)}: ${trait_display}' until associated iterator evidence is available",
                span, DiagnosticContext::TraitError { detail: "associated iterator dictionary evidence is unavailable" })
            fail.raise(CompileError {})
        },
        _ => {}
    }

    let type_name = match type_to_builtin_name(concrete) {
        some(name) => name,
        none => {
            let _ = type_error(ctx.sink, E0301,
                "for..in requires '${type_to_string(concrete)}' to implement '${nominal_display_name(trait_name)}'",
                span, DiagnosticContext::TraitError { detail: "iteration protocol requires a named implementation" })
            fail.raise(CompileError {})
        }
    }
    let impl_entry = match find_impl(ctx.env.trait_reg, type_name, trait_name) {
        some(entry) => entry,
        none => {
            let _ = type_error(ctx.sink, E0301,
                "for..in requires an iterable type (one that implements '${nominal_display_name(trait_name)}'), got ${type_to_string(concrete)}",
                span, DiagnosticContext::TraitError { detail: "same-spelled inherent methods do not satisfy the iteration protocol" })
            fail.raise(CompileError {})
        }
    }

    // Resolve the actual impl evidence now. This catches missing nested bounds
    // before lowering and never lets a later backend guess a dictionary.
    match resolve_dict_ref_for_type(
        ctx.env, ctx.current_fn_bounds, concrete, subst, trait_name
    ) {
        some(_) => impl_entry,
        none => {
            let _ = type_error(ctx.sink, E0503,
                "Cannot resolve '${nominal_display_name(trait_name)}' evidence for '${type_to_string(concrete)}'",
                span, DiagnosticContext::TraitError { detail: "iteration protocol dictionary evidence is unavailable" })
            fail.raise(CompileError {})
        }
    }
}

fn for_protocol_method_scheme(
    mut ctx: InferCtx, impl_entry: ImplEntry, method: Str, span: Span
) -> ImplMethodSchemeCore {
    match impl_entry.method_schemes.get(method) {
        some(scheme) => scheme,
        none => {
            let _ = type_error(ctx.sink, E0305,
                "Iteration protocol implementation '${nominal_display_name(impl_entry.target_type_name)}' has no exact method '${method}'",
                span, DiagnosticContext::TraitError {
                    detail: "protocol lowering does not fall back to default or flat method tables"
                })
            fail.raise(CompileError {})
        }
    }
}

struct MethodCallSelection {
    method_type: Type?,
    method_core: ImplMethodSchemeCore?,
    impl_owner: ImplEntry?,
    dict_dispatch: DictDispatchInfo?,
    intrinsic_ref: IntrinsicRef?
}

// Resolve an already-authoritative protocol impl into the same input consumed
// by ordinary method-call inference. No trait declaration reconstruction and
// no flat last-writer splice is permitted here: the exact ImplEntry scheme is
// the complete receiver/result/effect/bounds identity.
fn select_for_protocol_method(
    mut ctx: InferCtx, impl_entry: ImplEntry, method: Str, span: Span
) -> MethodCallSelection {
    let impl_core = for_protocol_method_scheme(ctx, impl_entry, method, span)
    let registered_method = ctx.env.instantiate_impl_method_core(
        impl_entry, impl_core)
    MethodCallSelection {
        method_type: some(registered_method),
        method_core: some(impl_core),
        impl_owner: some(impl_entry),
        dict_dispatch: none,
        intrinsic_ref: impl_entry.method_intrinsics.get(method)
    }
}

fn for_protocol_call_method_type(mut ctx: InferCtx, call: HExpr, span: Span) -> Type {
    match call {
        HExpr::Call { callee, .. } => match callee {
            HExpr::FieldAccess { ty, .. } => ty,
            _ => {
                let _ = type_error(ctx.sink, E0305,
                    "Internal iteration lowering expected a method call",
                    span, DiagnosticContext::OtherContext { detail: some("protocol call lost method provenance") })
                fail.raise(CompileError {})
            }
        },
        _ => {
            let _ = type_error(ctx.sink, E0305,
                "Internal iteration lowering expected a call expression",
                span, DiagnosticContext::OtherContext { detail: some("protocol call was not lowered as an ordinary call") })
            fail.raise(CompileError {})
        }
    }
}

// Instantiate an impl-associated type through the exact method scheme that
// ordinary call inference instantiated. build_scheme_var_map follows scheme
// variable identity through the receiver/return structure; there is no
// positional associated-type substitution here.
fn for_protocol_assoc_type(
    mut ctx: InferCtx, impl_entry: ImplEntry, method: Str,
    assoc_name: Str, call: HExpr, subst: UnionFind, span: Span
) -> Type {
    let raw_assoc = match impl_entry.assoc_types.get(assoc_name) {
        some(ty) => ty,
        none => {
            let _ = type_error(ctx.sink, E0301,
                "Iteration protocol implementation for '${nominal_display_name(impl_entry.target_type_name)}' is missing associated type '${assoc_name}'",
                span, DiagnosticContext::TraitError { detail: "protocol associated type is missing" })
            fail.raise(CompileError {})
        }
    }
    let scheme = impl_method_core_as_scheme(
        for_protocol_method_scheme(ctx, impl_entry, method, span))
    let instantiated_method = for_protocol_call_method_type(ctx, call, span)
    let var_map = build_scheme_var_map(scheme, instantiated_method)
    apply_subst(subst, apply_subst_map(var_map, raw_assoc))
}

pub fn infer_stmt(mut ctx: InferCtx, stmt: Stmt, subst: UnionFind) -> StmtResult {
    match stmt {
        Stmt::Let { name, name_span, type_annotation, init, span } => {
            let obligation_checkpoint = pending_dict_checkpoint(ctx)
            let init_r = infer_expr(ctx, init, subst)
            let mut s = init_r.subst
            let mut var_type = hexpr_type(init_r.hexpr)
            match type_annotation {
                some(ta) => {
                    let annotated = resolve_type_expr(ctx, ta)
                    let notes: List<DiagnosticNote> = [
                        DiagnosticNote { message: "expected '${type_to_string(annotated)}' because variable '${name}' is declared with this type", span: some(name_span) },
                        DiagnosticNote { message: "initializer has type '${type_to_string(apply_subst(s, var_type))}'", span: some(hexpr_span(init_r.hexpr)) }
                    ]
                    s = unify_at_noted(ctx.sink, ctx.env, var_type, annotated, s, span, notes)
                    var_type = apply_subst(s, annotated)
                },
                none => {}
            }
            let resolved = apply_subst(s, var_type)
            // A bounded direct callable hidden anywhere in a value position
            // must stay monomorphic until later uses determine its concrete
            // evidence. The DefId walk is shadow-safe and deliberately skips
            // only a bare direct-call callee.
            let init_has_bounds =
                hexpr_contains_bounded_callable_value(ctx, init_r.hexpr)
            // An initializer that created deferred evidence is a monomorphic
            // barrier.  Later statements must constrain the same variables;
            // generalizing here would detach the obligation from its value.
            let init_has_pending =
                has_pending_dicts_since(ctx, obligation_checkpoint)
            // Optimization: skip the expensive free_type_vars_in_env scan when the resolved
            // type is ground (no type variables). Most function-local let bindings have ground
            // types, so this avoids a full env scan on each one.
            let ftv = free_type_vars(resolved, empty_subst())
            let scheme = if ftv.len() == 0 || init_has_bounds || init_has_pending {
                mono(resolved)
            } else {
                generalize(ctx.env, resolved, s)
            }
            ctx.env.bind(name, scheme)
            let bound_scheme = ctx.env.lookup(name)
            let bound_def_id: Int? = match bound_scheme {
                some(bs) => {
                    match bs.def_id {
                        some(did) => {
                            ctx.env.record_def_span(did, name_span)
                            ctx.env.scope.let_defs.insert(did)
                            ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
                            some(did)
                        },
                        none => none
                    }
                },
                none => none
            }
            StmtResult {
                hstmt: HStmt::Let { name: name, name_span: name_span, def_id: bound_def_id, ty: resolved, init: init_r.hexpr, span: span },
                subst: s,
                effects: init_r.effects
            }
        },
        Stmt::Var { name, name_span, type_annotation, init, span } => {
            let init_r = infer_expr(ctx, init, subst)
            let mut s = init_r.subst
            let mut var_type = hexpr_type(init_r.hexpr)
            match type_annotation {
                some(ta) => {
                    let annotated = resolve_type_expr(ctx, ta)
                    let notes: List<DiagnosticNote> = [
                        DiagnosticNote { message: "expected '${type_to_string(annotated)}' because variable '${name}' is declared with this type", span: some(name_span) },
                        DiagnosticNote { message: "initializer has type '${type_to_string(apply_subst(s, var_type))}'", span: some(hexpr_span(init_r.hexpr)) }
                    ]
                    s = unify_at_noted(ctx.sink, ctx.env, var_type, annotated, s, span, notes)
                    var_type = apply_subst(s, annotated)
                },
                none => {}
            }
            ctx.env.bind_mono(name, apply_subst(s, var_type))
            let var_scheme = ctx.env.lookup(name)
            match var_scheme {
                some(vs) => {
                    match vs.def_id {
                        some(did) => {
                            ctx.env.record_def_span(did, name_span)
                            ctx.env.scope.mutable_vars.insert(did)
                            ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
                        },
                        none => {}
                    }
                    StmtResult {
                        hstmt: HStmt::Var { name: name, name_span: name_span, def_id: vs.def_id, ty: apply_subst(s, var_type), init: init_r.hexpr, span: span },
                        subst: s,
                        effects: init_r.effects
                    }
                },
                none => panic("unreachable: var_stmt lookup failed after bind")
            }
        },
        Stmt::Assign { target, value, span } => {
            check_assign_target_mutable(ctx, target)
            let target_r = infer_expr(ctx, target, subst)
            let value_r = infer_expr(ctx, value, target_r.subst)
            let assign_notes: List<DiagnosticNote> = [
                DiagnosticNote { message: "target has type '${type_to_string(apply_subst(value_r.subst, hexpr_type(target_r.hexpr)))}'", span: some(hexpr_span(target_r.hexpr)) },
                DiagnosticNote { message: "assigned value has type '${type_to_string(apply_subst(value_r.subst, hexpr_type(value_r.hexpr)))}'", span: some(hexpr_span(value_r.hexpr)) }
            ]
            let mut s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(target_r.hexpr), hexpr_type(value_r.hexpr), value_r.subst, span, assign_notes)
            let me = merge_effects(ctx.sink, ctx.env, target_r.effects, value_r.effects, s, span)
            s = me.1
            let mut effects = me.0
            // B-056: Inject mut<T> effect when assigning to a captured outer mutable variable
            match get_assign_target_root_def_id(ctx, target) {
                some(did) => {
                    if ctx.env.scope.mutable_vars.contains(did) {
                        match ctx.var_lambda_depth.get(did) {
                            some(def_depth) => {
                                if ctx.lambda_depth > def_depth {
                                    let var_type = apply_subst(s, get_hexpr_root_type(target_r.hexpr))
                                    let mut_eff = Effect::MutEffect { state_type: var_type }
                                    let me2 = merge_effects(ctx.sink, ctx.env, effects, effect_row([mut_eff]), s, span)
                                    effects = me2.0
                                    s = me2.1
                                }
                            },
                            none => {}
                        }
                    }
                },
                none => {}
            }
            StmtResult {
                hstmt: HStmt::Assign { target: target_r.hexpr, value: value_r.hexpr, span: span },
                subst: s,
                effects: effects
            }
        },
        Stmt::ExprStmt { expr, span, .. } => {
            let r = infer_expr(ctx, expr, subst)
            StmtResult {
                hstmt: HStmt::ExprStmt { expr: r.hexpr, span: span },
                subst: r.subst,
                effects: r.effects
            }
        },
        Stmt::Return { value, span } => match value {
            some(v) => {
                let r = infer_expr(ctx, v, subst)
                let mut s = r.subst
                match ctx.current_fn_return_type {
                    some(ret_type) => {
                        let return_notes: List<DiagnosticNote> = [
                            DiagnosticNote { message: "function return type is '${type_to_string(apply_subst(s, ret_type))}'", span: none },
                            DiagnosticNote { message: "return value has type '${type_to_string(apply_subst(s, hexpr_type(r.hexpr)))}'", span: some(hexpr_span(r.hexpr)) }
                        ]
                        s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(r.hexpr), ret_type, s, span, return_notes)
                    },
                    none => {}
                }
                StmtResult {
                    hstmt: HStmt::Return { value: some(r.hexpr), span: span },
                    subst: s,
                    effects: r.effects
                }
            },
            none => {
                let mut s = subst
                match ctx.current_fn_return_type {
                    some(ret_type) => {
                        s = unify_at(ctx.sink, ctx.env, UNIT, ret_type, s, span)
                    },
                    none => {}
                }
                StmtResult {
                    hstmt: HStmt::Return { value: none, span: span },
                    subst: s,
                    effects: EMPTY_ROW
                }
            }
        },
        Stmt::While { condition, body, span } => {
            let cond_r = infer_expr(ctx, condition, subst)
            let mut s = unify_at(ctx.sink, ctx.env, hexpr_type(cond_r.hexpr), BOOL, cond_r.subst, span)
            ctx.env.push_scope()
            ctx.loop_depth = ctx.loop_depth + 1
            let body_result = some(infer_block(ctx, body, some(s))) catch { _ => none }
            ctx.loop_depth = ctx.loop_depth - 1
            ctx.env.pop_scope()
            match body_result {
                some(body_r) => {
                    s = body_r.subst
                    let me = merge_effects(ctx.sink, ctx.env, cond_r.effects, body_r.effects, s, span)
                    StmtResult {
                        hstmt: HStmt::While { condition: cond_r.hexpr, body: body_r.hexpr, span: span },
                        subst: me.1,
                        effects: me.0
                    }
                },
                none => fail.raise(CompileError {})
            }
        },
        Stmt::ForIn { binding, binding_span, destructure, iterable, body, span } => {
            let iter_r = infer_expr(ctx, iterable, subst)
            let mut s = iter_r.subst
            let iter_type = apply_subst(s, hexpr_type(iter_r.hexpr))
            let mut element_type: Type = ctx.env.fresh_var()
            // Check for Range (builtin, keep special path)
            let is_range = match iter_type {
                Type::EnumType { name, .. } => name == BUILTIN_RANGE,
                _ => false
            }
            if !is_range {
                return lower_protocol_for_in(
                    ctx, binding, binding_span, destructure,
                    iter_r, body, span
                )
            }
            match iter_type {
                Type::EnumType { type_params, .. } => {
                    element_type = match type_params.first() { some(t) => t, none => INT }
                },
                _ => {}
            }

            ctx.env.push_scope()
            let mut hdestructure: List<HForInDestructure>? = none
            match destructure {
                some(destr) => {
                    match element_type {
                        Type::TupleType { elements: type_elems } => {
                            if destr.names.len() != type_elems.len() {
                                let _ = type_error(ctx.sink, E0301,
                                    "Destructure binding expects ${destr.names.len().to_str()} elements, but iterable element type is ${type_to_string(element_type)}",
                                    span, DiagnosticContext::OtherContext { detail: some("tuple arity mismatch") })
                            }
                        },
                        _ => {
                            let _ = type_error(ctx.sink, E0301,
                                "Destructure binding expects tuple elements, but iterable element type is ${type_to_string(element_type)}",
                                span, DiagnosticContext::OtherContext { detail: some("tuple arity mismatch") })
                        }
                    }
                    let mut hd: List<HForInDestructure> = []
                    let mut di = 0
                    while di < destr.names.len() {
                        match destr.names.get(di) {
                            some(dname) => {
                                let elem_t = match element_type {
                                    Type::TupleType { elements: type_elems } => match type_elems.get(di) {
                                        some(et) => et,
                                        none => ctx.env.fresh_var()
                                    },
                                    _ => ctx.env.fresh_var()
                                }
                                ctx.env.bind_mono(dname, elem_t)
                                let dscheme = ctx.env.lookup(dname)
                                match dscheme {
                                    some(ds) => {
                                        match (ds.def_id, destr.spans.get(di)) {
                                            (some(did), some(dspan)) => {
                                                ctx.env.record_def_span(did, dspan)
                                                ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
                                            },
                                            _ => {}
                                        }
                                        hd.push(HForInDestructure { name: dname, def_id: ds.def_id })
                                    },
                                    none => { hd.push(HForInDestructure { name: dname, def_id: none }) }
                                }
                            },
                            none => {}
                        }
                        di = di + 1
                    }
                    hdestructure = some(hd)
                },
                none => {
                    ctx.env.bind_mono(binding, element_type)
                }
            }
            let binding_scheme = ctx.env.lookup(binding)
            match binding_scheme {
                some(bs) => match bs.def_id {
                    some(did) => {
                        ctx.env.record_def_span(did, binding_span)
                        ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
                    },
                    none => {}
                },
                none => {}
            }
            ctx.loop_depth = ctx.loop_depth + 1
            let body_result = some(infer_block(ctx, body, some(s))) catch { _ => none }
            ctx.loop_depth = ctx.loop_depth - 1
            ctx.env.pop_scope()
            match body_result {
                some(body_r) => {
                    s = body_r.subst
                    let me = merge_effects(ctx.sink, ctx.env, iter_r.effects, body_r.effects, s, span)
                    StmtResult {
                        hstmt: HStmt::ForIn {
                            binding: binding, binding_span: binding_span,
                            def_id: match binding_scheme { some(bs) => bs.def_id, none => none },
                            destructure: hdestructure,
                            iterable: iter_r.hexpr, body: body_r.hexpr,
                            iterable_type_name: none,
                            iter_type_name: none,
                            span: span
                        },
                        subst: me.1,
                        effects: me.0
                    }
                },
                none => fail.raise(CompileError {})
            }
        },
        Stmt::Break { span } => {
            if ctx.loop_depth == 0 {
                let _ = type_error(ctx.sink, E0206, "'break' can only be used inside a loop", span,
                    DiagnosticContext::OtherContext { detail: some("break outside loop") })
            }
            StmtResult { hstmt: HStmt::Break { span: span }, subst: subst, effects: EMPTY_ROW }
        },
        Stmt::Continue { span } => {
            if ctx.loop_depth == 0 {
                let _ = type_error(ctx.sink, E0206, "'continue' can only be used inside a loop", span,
                    DiagnosticContext::OtherContext { detail: some("continue outside loop") })
            }
            StmtResult { hstmt: HStmt::Continue { span: span }, subst: subst, effects: EMPTY_ROW }
        },
        Stmt::LetDestructure { pattern, init, span } => {
            let init_r = infer_expr(ctx, init, subst)
            let mut s = init_r.subst
            let init_type = apply_subst(s, hexpr_type(init_r.hexpr))
            match init_type {
                Type::TupleType { .. } => {},
                _ => { let _ = type_error(ctx.sink, E0301,
                    "let destructuring requires tuple type, got ${type_to_string(init_type)}",
                    span, DiagnosticContext::OtherContext { detail: some("not a tuple") }) }
            }
            let tuple_elements: List<Type> = match init_type {
                Type::TupleType { elements } => elements,
                _ => []
            }
            match pattern {
                Pattern::TuplePattern { elements: pat_elements, .. } => {
                    if pat_elements.len() != tuple_elements.len() {
                        let _ = type_error(ctx.sink, E0301,
                            "Tuple has ${tuple_elements.len().to_str()} elements but pattern has ${pat_elements.len().to_str()}",
                            span, DiagnosticContext::OtherContext { detail: some("tuple arity mismatch") })
                    }
                    let mut bindings: List<HLetDestructureBinding> = []
                    let mut bi = 0
                    while bi < pat_elements.len() {
                        match pat_elements.get(bi) {
                            some(p) => {
                                let elem_type = match tuple_elements.get(bi) { some(et) => et, none => UNIT }
                                match p {
                                    Pattern::Binding { name, span: pspan } => {
                                        ctx.env.bind_mono(name, elem_type)
                                        let bscheme = ctx.env.lookup(name)
                                        match bscheme {
                                            some(bs) => {
                                                match bs.def_id {
                                                    some(did) => {
                                                        ctx.env.record_def_span(did, pspan)
                                                        ctx.env.scope.let_defs.insert(did)
                                                    },
                                                    none => {}
                                                }
                                                bindings.push(HLetDestructureBinding { name: name, def_id: bs.def_id, ty: elem_type })
                                            },
                                            none => {
                                                bindings.push(HLetDestructureBinding { name: name, def_id: none, ty: elem_type })
                                            }
                                        }
                                    },
                                    Pattern::Wildcard { .. } => {
                                        bindings.push(HLetDestructureBinding { name: "_", def_id: none, ty: elem_type })
                                    },
                                    _ => {
                                        let _ = type_error(ctx.sink, E0301,
                                            "Only binding and wildcard patterns are supported in let destructuring",
                                            span, DiagnosticContext::OtherContext { detail: some("unsupported pattern kind") })
                                    }
                                }
                            },
                            none => {}
                        }
                        bi = bi + 1
                    }
                    StmtResult {
                        hstmt: HStmt::LetDestructure { pattern: pattern, bindings: bindings, init: init_r.hexpr, span: span },
                        subst: s,
                        effects: init_r.effects
                    }
                },
                _ => {
                    let _ = type_error(ctx.sink, E0301,
                        "let destructuring requires tuple pattern",
                        span, DiagnosticContext::OtherContext { detail: some("not a tuple pattern") })
                    StmtResult {
                        hstmt: HStmt::ExprStmt { expr: HExpr::IntLit { value: 0, ty: UNIT, effects: EMPTY_ROW, span: span }, span: span },
                        subst: s,
                        effects: init_r.effects
                    }
                }
            }
        },
        Stmt::IfLet { pattern, expr, then_block, else_block, span } => {
            let expr_r = infer_expr(ctx, expr, subst)
            infer_if_let_from_result(
                ctx, pattern, expr_r, then_block, else_block, span)
        }
    }
}

fn infer_if_let_from_result(
    mut ctx: InferCtx, pattern: Pattern, expr_r: InferResult,
    then_block: Expr, else_block: Expr?, span: Span
) -> StmtResult {
    let mut s = expr_r.subst
    let expr_type = apply_subst(s, hexpr_type(expr_r.hexpr))
    let iflet_pattern = rewrite_bare_enum_bindings(ctx.env, pattern)

    let mut pattern_bindings: List<HPatternBinding> = []
    ctx.env.push_scope()
    let then_result = some({
        s = bind_pattern(ctx, iflet_pattern, expr_type, s)
        pattern_bindings = exact_pattern_bindings(
            ctx.env, iflet_pattern)
        infer_block(ctx, then_block, some(s))
    }) catch { _ => none }
    ctx.env.pop_scope()

    match then_result {
        some(then_r) => {
            s = then_r.subst
            let mut combined = merge_effects(
                ctx.sink, ctx.env, expr_r.effects, then_r.effects,
                s, span)
            let mut combined_effects = combined.0
            s = combined.1

            let mut else_hblock: HExpr? = none
            match else_block {
                some(eb) => {
                    ctx.env.push_scope()
                    let else_result = some(
                        infer_block(ctx, eb, some(s))) catch { _ => none }
                    ctx.env.pop_scope()
                    match else_result {
                        some(else_r) => {
                            s = else_r.subst
                            else_hblock = some(else_r.hexpr)
                            let me2 = merge_effects(
                                ctx.sink, ctx.env, combined_effects,
                                else_r.effects, s, span)
                            combined_effects = me2.0
                            s = me2.1
                        },
                        none => fail.raise(CompileError {})
                    }
                },
                none => {}
            }

            StmtResult {
                hstmt: HStmt::IfLet {
                    pattern: iflet_pattern, bindings: pattern_bindings,
                    expr: expr_r.hexpr,
                    then_block: then_r.hexpr,
                    else_block: else_hblock, span: span
                },
                subst: s,
                effects: combined_effects
            }
        },
        none => fail.raise(CompileError {})
    }
}

fn lower_protocol_for_in(
    mut ctx: InferCtx, binding: Str, binding_span: Span,
    destructure: DestructureBinding?, iterable_result: InferResult,
    body: Expr, span: Span
) -> StmtResult {
    let mut s = iterable_result.subst
    let collection_type = apply_subst(s, hexpr_type(iterable_result.hexpr))

    // The generated locals live in one ordinary lexical block. Catch only to
    // guarantee that the synthetic scope is popped before propagating a
    // declaration-level CompileError.
    ctx.env.push_scope()
    let lowered_result: StmtResult? = some({
        let iterable_impl = require_for_protocol_impl(
            ctx, collection_type, "Iterable", s, span)

        let iterable_selection = select_for_protocol_method(
            ctx, iterable_impl, "iter", span)
        let iter_call_result = infer_method_call_from_receiver(
            ctx, none, iterable_result, "iter", [], span,
            some(iterable_selection))
        s = iter_call_result.subst

        let associated_iter_type = for_protocol_assoc_type(
            ctx, iterable_impl, "iter", "Iter",
            iter_call_result.hexpr, s, span)
        let associated_item_type = for_protocol_assoc_type(
            ctx, iterable_impl, "iter", "Item",
            iter_call_result.hexpr, s, span)
        let iter_notes: List<DiagnosticNote> = [
            DiagnosticNote {
                message: "Iterable::Iter is '${type_to_string(associated_iter_type)}'",
                span: some(span)
            },
            DiagnosticNote {
                message: "iter() returns '${type_to_string(apply_subst(s, hexpr_type(iter_call_result.hexpr)))}'",
                span: some(span)
            }
        ]
        s = unify_at_noted(
            ctx.sink, ctx.env,
            hexpr_type(iter_call_result.hexpr), associated_iter_type,
            s, span, iter_notes)
        let iterator_type = apply_subst(s, hexpr_type(iter_call_result.hexpr))
        let iterator_impl = require_for_protocol_impl(
            ctx, iterator_type, "Iterator", s, span)

        let iterator_name = "__ring_for_iterator_${ctx.env.ids.next_def_id.to_str()}"
        ctx.env.bind_mono(iterator_name, iterator_type)
        let iterator_scheme = match ctx.env.lookup(iterator_name) {
            some(scheme) => scheme,
            none => panic("unreachable: lowered for iterator binding missing")
        }
        match iterator_scheme.def_id {
            some(did) => {
                ctx.env.record_def_span(did, span)
                ctx.env.scope.mutable_vars.insert(did)
                ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
            },
            none => {}
        }
        let iterator_stmt = HStmt::Var {
            name: iterator_name, name_span: span,
            def_id: iterator_scheme.def_id, ty: iterator_type,
            init: iter_call_result.hexpr, span: span
        }

        let mut payload_pattern = Pattern::Binding {
            name: binding, span: binding_span
        }
        let mut then_block = body
        match destructure {
            some(destr) => {
                let payload_name = "__ring_for_payload_${ctx.env.ids.next_def_id.to_str()}"
                payload_pattern = Pattern::Binding { name: payload_name, span: binding_span }

                let mut tuple_patterns: List<Pattern> = []
                let mut di = 0
                while di < destr.names.len() {
                    match (destr.names.get(di), destr.spans.get(di)) {
                        (some(name), some(name_span)) => {
                            tuple_patterns.push(Pattern::Binding {
                                name: name, span: name_span
                            })
                        },
                        (some(name), none) => {
                            tuple_patterns.push(Pattern::Binding {
                                name: name, span: binding_span
                            })
                        },
                        _ => {}
                    }
                    di = di + 1
                }
                let destructure_stmt = Stmt::LetDestructure {
                    pattern: Pattern::TuplePattern {
                        elements: tuple_patterns, span: span
                    },
                    init: Expr::Ident {
                        name: payload_name, qualifier: none, span: span
                    },
                    span: span
                }
                then_block = match then_block {
                    Expr::Block { stmts, tail, span: body_span } => {
                        let mut lowered_stmts: List<Stmt> = [destructure_stmt]
                        for original_stmt in stmts {
                            lowered_stmts.push(original_stmt)
                        }
                        Expr::Block {
                            stmts: lowered_stmts, tail: tail, span: body_span
                        }
                    },
                    _ => panic("unreachable: for-in body is not a block")
                }
            },
            none => {}
        }

        let some_pattern = Pattern::Constructor {
            name: "some", qualifier: some(BUILTIN_OPTION),
            fields: [payload_pattern], span: span
        }
        let exhausted_block = Expr::Block {
            stmts: [Stmt::Break { span: span }],
            tail: none, span: span
        }
        ctx.env.push_scope()
        ctx.loop_depth = ctx.loop_depth + 1
        let while_candidate: StmtResult? = some({
            let iterator_expr = Expr::Ident {
                name: iterator_name, qualifier: none, span: span
            }
            let next_receiver = infer_expr(ctx, iterator_expr, s)
            let next_selection = select_for_protocol_method(
                ctx, iterator_impl, "next", span)
            let next_call_result = infer_method_call_from_receiver(
                ctx, some(iterator_expr), next_receiver,
                "next", [], span, some(next_selection))
            s = next_call_result.subst

            let iterator_item_type = for_protocol_assoc_type(
                ctx, iterator_impl, "next", "Item",
                next_call_result.hexpr, s, span)
            let next_expected = make_option_type(iterator_item_type)
            let next_notes: List<DiagnosticNote> = [
                DiagnosticNote {
                    message: "Iterator::Item is '${type_to_string(iterator_item_type)}'",
                    span: some(span)
                },
                DiagnosticNote {
                    message: "next() returns '${type_to_string(apply_subst(s, hexpr_type(next_call_result.hexpr)))}'",
                    span: some(span)
                }
            ]
            s = unify_at_noted(
                ctx.sink, ctx.env, hexpr_type(next_call_result.hexpr),
                next_expected, s, span, next_notes)

            let item_notes: List<DiagnosticNote> = [
                DiagnosticNote {
                    message: "Iterable::Item is '${type_to_string(apply_subst(s, associated_item_type))}'",
                    span: some(span)
                },
                DiagnosticNote {
                    message: "Iterator::Item is '${type_to_string(apply_subst(s, iterator_item_type))}'",
                    span: some(span)
                }
            ]
            s = unify_at_noted(
                ctx.sink, ctx.env,
                associated_item_type, iterator_item_type,
                s, span, item_notes)

            let checked_next = InferResult {
                hexpr: next_call_result.hexpr,
                subst: s, effects: next_call_result.effects
            }
            let branch_result = infer_if_let_from_result(
                ctx, some_pattern, checked_next, then_block,
                some(exhausted_block), span)
            s = branch_result.subst
            let loop_body = HExpr::Block {
                stmts: [branch_result.hstmt], tail: none,
                ty: UNIT, effects: branch_result.effects, span: span
            }
            StmtResult {
                hstmt: HStmt::While {
                    condition: HExpr::BoolLit {
                        value: true, ty: BOOL,
                        effects: EMPTY_ROW, span: span
                    },
                    body: loop_body, span: span
                },
                subst: s, effects: branch_result.effects
            }
        }) catch { _ => none }
        ctx.loop_depth = ctx.loop_depth - 1
        ctx.env.pop_scope()
        let while_result = match while_candidate {
            some(result) => result,
            none => fail.raise(CompileError {})
        }
        s = while_result.subst

        let mut block_effects = iter_call_result.effects
        let combined = merge_effects(
            ctx.sink, ctx.env, block_effects,
            while_result.effects, s, span)
        block_effects = combined.0
        s = combined.1

        let lowered_block = HExpr::Block {
            stmts: [iterator_stmt, while_result.hstmt],
            tail: none, ty: UNIT, effects: block_effects, span: span
        }
        StmtResult {
            hstmt: HStmt::ExprStmt { expr: lowered_block, span: span },
            subst: s, effects: block_effects
        }
    }) catch { _ => none }
    ctx.env.pop_scope()
    match lowered_result {
        some(result) => result,
        none => fail.raise(CompileError {})
    }
}

// ============================================================
// Expression inference dispatch (from infer.ts)
// ============================================================

pub fn infer_expr(mut ctx: InferCtx, expr: Expr, subst: UnionFind) -> InferResult {
    match expr {
        Expr::IntLit { value, span } =>
            InferResult {
                hexpr: HExpr::IntLit { value: value, ty: INT, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            },
        Expr::FloatLit { value, span } =>
            InferResult {
                hexpr: HExpr::FloatLit { value: value, ty: FLOAT, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            },
        Expr::StrLit { value, span } =>
            InferResult {
                hexpr: HExpr::StrLit { value: value, ty: STR, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            },
        Expr::BoolLit { value, span } =>
            InferResult {
                hexpr: HExpr::BoolLit { value: value, ty: BOOL, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            },
        Expr::Ident { name, qualifier, span } =>
            infer_ident(ctx, name, span, subst, qualifier),
        Expr::BinOp { op, left, right, span } =>
            infer_bin_op(ctx, op, left, right, span, subst),
        Expr::UnaryOp { op, operand, span } =>
            infer_unary_op(ctx, op, operand, span, subst),
        Expr::Call { callee, args, span, .. } =>
            infer_call(ctx, callee, args, span, subst),
        Expr::MethodCall { receiver, method, args, span, .. } =>
            infer_method_call(ctx, receiver, method, args, span, subst),
        Expr::FieldAccess { receiver, field, span } =>
            infer_field_access(ctx, receiver, field, span, subst),
        Expr::StructLit { name, qualifier, fields, spread, span, .. } =>
            infer_struct_lit(ctx, name, fields, spread, span, subst, qualifier),
        Expr::MatchExpr { scrutinee, arms, span } =>
            infer_match(ctx, scrutinee, arms, span, subst),
        Expr::Block { .. } =>
            infer_scoped_block(ctx, expr, some(subst)),
        Expr::IfExpr { condition, then_branch, else_branch, span } =>
            infer_if(ctx, condition, then_branch, else_branch, span, subst),
        Expr::StringInterp { parts, span } =>
            infer_string_interp(ctx, parts, span, subst),
        Expr::CatchExpr { expr: catch_expr, arms, span } =>
            infer_catch(ctx, catch_expr, arms, span, subst),
        Expr::HandleExpr { body, handlers, span } =>
            infer_handle(ctx, body, handlers, span, subst),
        Expr::Lambda { params, body, span, .. } =>
            infer_lambda(ctx, params, body, span, subst, none),
        Expr::ListLit { elements, span } =>
            infer_list_literal(ctx, elements, span, subst),
        Expr::TupleLit { elements, span } => {
            // () — unit literal: 0-element tuple is Unit
            if elements.len() == 0 {
                return InferResult {
                    hexpr: HExpr::TupleLit { elements: [], ty: UNIT, effects: EMPTY_ROW, span: span },
                    subst: subst, effects: EMPTY_ROW
                }
            }
            let mut s = subst
            let mut helements: List<HExpr> = []
            let mut combined_effects: EffectRow = EMPTY_ROW
            for el in elements {
                let r = infer_expr(ctx, el, s)
                s = r.subst
                helements.push(r.hexpr)
                let me = merge_effects(ctx.sink, ctx.env, combined_effects, r.effects, s, span)
                combined_effects = me.0
                s = me.1
            }
            let mut elem_types: List<Type> = []
            for he in helements { elem_types.push(apply_subst(s, hexpr_type(he))) }
            let tuple_type = Type::TupleType { elements: elem_types }
            InferResult {
                hexpr: HExpr::TupleLit { elements: helements, ty: tuple_type, effects: combined_effects, span: span },
                subst: s, effects: combined_effects
            }
        },
        Expr::Range { start, end, inclusive, span } => {
            let start_r = infer_expr(ctx, start, subst)
            let mut s = unify_at(ctx.sink, ctx.env, hexpr_type(start_r.hexpr), INT, start_r.subst, span)
            let end_r = infer_expr(ctx, end, s)
            s = unify_at(ctx.sink, ctx.env, hexpr_type(end_r.hexpr), INT, end_r.subst, span)
            let me = merge_effects(ctx.sink, ctx.env, start_r.effects, end_r.effects, s, span)
            let mut range_effects = me.0
            s = me.1
            let range_type = Type::EnumType { name: BUILTIN_RANGE, type_params: [INT] }
            InferResult {
                hexpr: HExpr::RangeExpr {
                    start: start_r.hexpr, end: end_r.hexpr, inclusive: inclusive,
                    ty: range_type, effects: range_effects, span: span
                },
                subst: s, effects: range_effects
            }
        },
        Expr::IndexExpr { receiver, index, span } =>
            infer_index_expr(ctx, receiver, index, span, subst),
        Expr::ReturnExpr { value, span } => match value {
            some(v) => {
                let r = infer_expr(ctx, v, subst)
                let mut s = r.subst
                match ctx.current_fn_return_type {
                    some(ret_type) => {
                        let return_notes: List<DiagnosticNote> = [
                            DiagnosticNote { message: "function return type is '${type_to_string(apply_subst(s, ret_type))}'", span: none },
                            DiagnosticNote { message: "return value has type '${type_to_string(apply_subst(s, hexpr_type(r.hexpr)))}'", span: some(hexpr_span(r.hexpr)) }
                        ]
                        s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(r.hexpr), ret_type, s, span, return_notes)
                    },
                    none => {}
                }
                InferResult {
                    hexpr: HExpr::ReturnExpr { value: some(r.hexpr), ty: NEVER, effects: r.effects, span: span },
                    subst: s, effects: r.effects
                }
            },
            none => {
                let mut s = subst
                match ctx.current_fn_return_type {
                    some(ret_type) => {
                        s = unify_at(ctx.sink, ctx.env, UNIT, ret_type, s, span)
                    },
                    none => {}
                }
                InferResult {
                    hexpr: HExpr::ReturnExpr { value: none, ty: NEVER, effects: EMPTY_ROW, span: span },
                    subst: s, effects: EMPTY_ROW
                }
            }
        },
        // B-125: unsafe block — discharge UnsafeEffect from body
        Expr::UnsafeBlock { body, span } => {
            // Check that the current module allows unsafe blocks
            if !ctx.mod_unsafe_allowed {
                let _ = type_error(ctx.sink, E0411,
                    "unsafe block requires `mod ... requires {unsafe}` declaration",
                    span,
                    DiagnosticContext::OtherContext { detail: some("unsafe block without requires") })
            }
            // Infer body (which is a Block expr from parse_block_expr)
            let body_r = infer_scoped_block(ctx, body, some(subst))
            // Discharge: filter out UnsafeEffect from the body's effect row
            let mut filtered: List<Effect> = []
            for e in body_r.effects.effects {
                match e {
                    Effect::UnsafeEffect => {},
                    _ => filtered.push(e)
                }
            }
            let discharged_effects = EffectRow { effects: filtered, tail: body_r.effects.tail }
            InferResult {
                hexpr: HExpr::UnsafeBlock {
                    body: body_r.hexpr,
                    ty: hexpr_type(body_r.hexpr),
                    effects: discharged_effects,
                    span: span
                },
                subst: body_r.subst, effects: discharged_effects
            }
        }
    }
}

// ============================================================
// infer_index_expr: list[i] / map[key] / str[i]
// ============================================================

fn infer_index_expr(mut ctx: InferCtx, receiver: Expr, index: Expr, span: Span, subst: UnionFind) -> InferResult {
    let recv_r = infer_expr(ctx, receiver, subst)
    let mut s = recv_r.subst
    let mut combined_effects = recv_r.effects

    let idx_r = infer_expr(ctx, index, s)
    s = idx_r.subst
    let me = merge_effects(ctx.sink, ctx.env, combined_effects, idx_r.effects, s, span)
    combined_effects = me.0
    s = me.1

    let recv_type = apply_subst(s, hexpr_type(recv_r.hexpr))
    let idx_type = apply_subst(s, hexpr_type(idx_r.hexpr))

    let mut result_ty: Type = Type::ErrorType
    let mut map_key_type: Type? = none

    match recv_type {
        Type::StructType { name, type_params, .. } => {
            if name == BUILTIN_LIST {
                // list[i]: index must be Int, result is element type T
                s = unify_at(ctx.sink, ctx.env, idx_type, INT, s, span)
                result_ty = if type_params.len() > 0 { type_params.get(0).unwrap() } else { Type::ErrorType }
            } else if name == BUILTIN_MAP {
                // map[key]: index must be key type K, result is value type V
                if type_params.len() >= 2 {
                    let key_type = type_params.get(0).unwrap()
                    s = unify_at(ctx.sink, ctx.env, idx_type, key_type, s, span)
                    map_key_type = some(apply_subst(s, key_type))
                    result_ty = type_params.get(1).unwrap()
                } else {
                    result_ty = Type::ErrorType
                }
            } else {
                let _ = type_error(ctx.sink, E0306,
                    "Type '${type_to_string(recv_type)}' does not support indexing",
                    span, DiagnosticContext::OtherContext { detail: some("only List, Map, and Str support subscript operator []") })
                result_ty = Type::ErrorType
            }
        },
        Type::StrType => {
            // str[i]: index must be Int, result is Str
            s = unify_at(ctx.sink, ctx.env, idx_type, INT, s, span)
            result_ty = STR
        },
        Type::ErrorType => {
            result_ty = Type::ErrorType
        },
        _ => {
            let _ = type_error(ctx.sink, E0306,
                "Type '${type_to_string(recv_type)}' does not support indexing",
                span, DiagnosticContext::OtherContext { detail: some("only List, Map, and Str support subscript operator []") })
            result_ty = Type::ErrorType
        }
    }

    match map_key_type {
        some(key_type) => {
            // B-152 P3 closure: Map subscript is the bounded pure-Ring
            // map_get_panic call, not a backend/runtime projection.  Lowering
            // here preserves the Hash+Eq dictionaries.  The binding comes from
            // load_prelude's canonical TypeScheme/DefId, never from a lexical
            // name lookup that a local/parameter could shadow.
            let callee_name = map_index_helper_identity()
            let callee_scheme = match ctx.env.lookup(callee_name) {
                some(scheme) => scheme,
                none => panic("unreachable: canonical prelude map_get_panic is missing")
            }
            let callee_ty = ctx.env.instantiate(callee_scheme)
            let callee = HExpr::Ident {
                name: callee_name, resolved_name: none,
                def_id: callee_scheme.def_id, dict_closure_dicts: none,
                ty: callee_ty, effects: EMPTY_ROW, span: span
            }
            let effect_tail = ctx.env.fresh_var_id()
            let expected_fn = Type::FnType {
                params: [apply_subst(s, recv_type), key_type],
                return_type: apply_subst(s, result_ty),
                effects: EffectRow { effects: [], tail: some(effect_tail) }
            }
            s = unify_at(ctx.sink, ctx.env, hexpr_type(callee), expected_fn, s, span)

            match apply_subst(s, hexpr_type(callee)) {
                Type::FnType { effects: fn_effects, .. } => {
                    let me2 = merge_effects(ctx.sink, ctx.env, combined_effects, fn_effects, s, span)
                    combined_effects = me2.0
                    s = me2.1
                },
                _ => {}
            }

            let resolved_dicts: List<DictRef> = []
            resolve_or_defer_dicts_from_scheme(
                ctx, callee_scheme, hexpr_type(callee), s, span,
                PendingDictPurpose::DirectCallPublish {
                    output_slot: resolved_dicts
                })

            let final_result_ty = apply_subst(s, result_ty)
            InferResult {
                hexpr: HExpr::Call {
                    callee: callee,
                    args: [recv_r.hexpr, idx_r.hexpr],
                    type_args: [],
                    resolved_dicts: resolved_dicts,
                    dict_dispatch: none, method_ref: none,
                    ty: final_result_ty,
                    effects: combined_effects,
                    span: span
                },
                subst: s, effects: combined_effects
            }
        },
        none => InferResult {
            hexpr: HExpr::IndexExpr {
                receiver: recv_r.hexpr, index: idx_r.hexpr,
                ty: result_ty, effects: combined_effects, span: span
            },
            subst: s, effects: combined_effects
        }
    }
}

// ============================================================
// infer_bin_op (from infer-expr.ts)
// ============================================================

fn infer_bin_op(mut ctx: InferCtx, op: BinOp, left: Expr, right: Expr, span: Span, subst: UnionFind) -> InferResult {
    let lr = infer_expr(ctx, left, subst)
    let rr = infer_expr(ctx, right, lr.subst)
    let mut s = rr.subst
    let mut result_type: Type = UNIT
    let mut eq_dispatch: TraitDispatch? = none
    let mut ord_dispatch: TraitDispatch? = none

    match op {
        BinOp::Add => { result_type = infer_numeric_op(ctx, lr.hexpr, rr.hexpr, s, span, "+"); s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span) },
        BinOp::Sub => { result_type = infer_numeric_op(ctx, lr.hexpr, rr.hexpr, s, span, "-"); s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span) },
        BinOp::Mul => { result_type = infer_numeric_op(ctx, lr.hexpr, rr.hexpr, s, span, "*"); s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span) },
        BinOp::Div => { result_type = infer_numeric_op(ctx, lr.hexpr, rr.hexpr, s, span, "/"); s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span) },
        BinOp::Mod => { result_type = infer_numeric_op(ctx, lr.hexpr, rr.hexpr, s, span, "%"); s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span) },
        BinOp::Eq | BinOp::Neq => {
            s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span)
            result_type = BOOL
            let resolved = apply_subst(s, hexpr_type(lr.hexpr))
            let op_sym = match op { BinOp::Eq => "==", _ => "!=" }
            eq_dispatch = some(resolve_eq_dispatch(ctx, resolved, s, span, op_sym))
        },
        BinOp::Lt | BinOp::Lte | BinOp::Gt | BinOp::Gte => {
            s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), hexpr_type(rr.hexpr), s, span)
            result_type = BOOL
            let resolved = apply_subst(s, hexpr_type(lr.hexpr))
            let op_sym = match op { BinOp::Lt => "<", BinOp::Lte => "<=", BinOp::Gt => ">", _ => ">=" }
            ord_dispatch = some(resolve_trait_dispatch(ctx, resolved, "Ord", E0308, s, span, op_sym, is_primitive_ord(resolved)))
        },
        BinOp::And => {
            s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), BOOL, s, span)
            s = unify_at(ctx.sink, ctx.env, hexpr_type(rr.hexpr), BOOL, s, span)
            result_type = BOOL
        },
        BinOp::Or => {
            s = unify_at(ctx.sink, ctx.env, hexpr_type(lr.hexpr), BOOL, s, span)
            s = unify_at(ctx.sink, ctx.env, hexpr_type(rr.hexpr), BOOL, s, span)
            result_type = BOOL
        }
    }

    let me = merge_effects(ctx.sink, ctx.env, lr.effects, rr.effects, s, span)
    let mut effects = me.0
    s = me.1
    InferResult {
        hexpr: HExpr::BinOp { op: op, left: lr.hexpr, right: rr.hexpr, eq_dispatch: eq_dispatch, ord_dispatch: ord_dispatch, ty: result_type, effects: effects, span: span },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_unary_op
// ============================================================

fn infer_unary_op(mut ctx: InferCtx, op: UnaryOp, operand: Expr, span: Span, subst: UnionFind) -> InferResult {
    let r = infer_expr(ctx, operand, subst)
    let mut s = r.subst
    let mut result_type: Type = UNIT
    match op {
        UnaryOp::Neg => {
            let resolved = apply_subst(s, hexpr_type(r.hexpr))
            match resolved {
                Type::TypeVar { .. } => { s = unify_at(ctx.sink, ctx.env, resolved, INT, s, span); result_type = INT },
                Type::IntType => { result_type = INT },
                Type::FloatType => { result_type = FLOAT },
                _ => { let _ = type_error(ctx.sink, E0303,
                    "Unary - requires numeric type, got ${type_to_string(resolved)}",
                    span, DiagnosticContext::TypeMismatch { expected: "Int or Float", actual: type_to_string(resolved), expression: none }) }
            }
        },
        UnaryOp::Not => {
            s = unify_at(ctx.sink, ctx.env, hexpr_type(r.hexpr), BOOL, s, span)
            result_type = BOOL
        }
    }
    InferResult {
        hexpr: HExpr::UnaryOp { op: op, operand: r.hexpr, ty: result_type, effects: r.effects, span: span },
        subst: s, effects: r.effects
    }
}

// ============================================================
// infer_call
// ============================================================

fn infer_call(mut ctx: InferCtx, callee: Expr, args: List<Expr>, span: Span, subst: UnionFind) -> InferResult {
    let callee_r = infer_expr(ctx, callee, subst)
    let callee_metadata = resolve_callee_metadata(ctx, callee_r.hexpr)
    let mut s = callee_r.subst
    let mut effects = callee_r.effects

    // Resolve callee type for lambda bidirectional inference
    let resolved_callee = apply_subst(s, hexpr_type(callee_r.hexpr))
    let callee_fn_type: Type? = match resolved_callee {
        Type::FnType { .. } => some(resolved_callee),
        _ => none
    }

    let mut hargs: List<HExpr> = []
    let mut arg_types: List<Type> = []
    let mut ai = 0
    for arg in args {
        let mut ar: InferResult = match arg {
            Expr::Lambda { params: lparams, body: lbody, span: lspan, .. } => {
                match callee_fn_type {
                    some(cft) => match cft {
                        Type::FnType { params: cft_params, .. } => {
                            if ai < cft_params.len() {
                                match cft_params.get(ai) {
                                    some(expected_raw) => {
                                        let expected = apply_subst(s, expected_raw)
                                        match expected {
                                            Type::FnType { params: exp_params, .. } => {
                                                infer_lambda(ctx, lparams, lbody, lspan, s, some(exp_params))
                                            },
                                            _ => infer_expr(ctx, arg, s)
                                        }
                                    },
                                    none => infer_expr(ctx, arg, s)
                                }
                            } else { infer_expr(ctx, arg, s) }
                        },
                        _ => infer_expr(ctx, arg, s)
                    },
                    none => infer_expr(ctx, arg, s)
                }
            },
            _ => infer_expr(ctx, arg, s)
        }
        s = ar.subst
        let me = merge_effects(ctx.sink, ctx.env, effects, ar.effects, s, span)
        effects = me.0
        s = me.1
        hargs.push(ar.hexpr)
        arg_types.push(hexpr_type(ar.hexpr))
        ai = ai + 1
    }

    let ret_var = ctx.env.fresh_var()
    let effect_tail = ctx.env.fresh_var_id()
    let expected_fn = Type::FnType {
        params: arg_types,
        return_type: ret_var,
        effects: EffectRow { effects: [], tail: some(effect_tail) }
    }

    let callee_name_for_note: Str = match callee { Expr::Ident { name: cn, .. } => cn, _ => "<expression>" }
    let call_notes: List<DiagnosticNote> = [
        DiagnosticNote { message: "calling '${callee_name_for_note}' with ${arg_types.len().to_str()} argument(s)", span: some(span) }
    ]
    s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(callee_r.hexpr), expected_fn, s, span, call_notes)
    let resolved_callee_type = apply_subst(s, hexpr_type(callee_r.hexpr))

    match resolved_callee_type {
        Type::FnType { params: callee_params, effects: fn_effects, .. } => {
            let me = merge_effects(ctx.sink, ctx.env, effects, fn_effects, s, span)
            effects = me.0
            s = me.1
            // Cancel mut<T> effects for arguments that are local variables
            effects = cancel_local_mut_effects(ctx, effects, callee_params, fn_effects, hargs, 0, s)
        },
        _ => {}
    }

    let resolved_dicts: List<DictRef> = []
    match callee_metadata {
        some(metadata) => match metadata.kind {
            ValueBindingKind::DirectCallable => {
                if metadata.live_scheme.bounds.len() > 0 {
                    resolve_or_defer_dicts_from_scheme(
                        ctx, metadata.live_scheme,
                        hexpr_type(callee_r.hexpr), s, span,
                        PendingDictPurpose::DirectCallPublish {
                            output_slot: resolved_dicts
                        })
                }
            },
            ValueBindingKind::ExternCallable => {
                if metadata.live_scheme.bounds.len() > 0 {
                    // Extern ABI never receives Ring dictionaries. Resolution
                    // remains mandatory for static bound validation.
                    resolve_or_defer_dicts_from_scheme(
                        ctx, metadata.live_scheme,
                        hexpr_type(callee_r.hexpr), s, span,
                        PendingDictPurpose::ExternCallValidate)
                }
            },
            ValueBindingKind::ConstGetter | ValueBindingKind::LocalBorrow => {}
        },
        none => {}
    }

    // B-100 Fix 3: compute result_type AFTER dict resolution so that
    // associated type vars unified during check_assoc_constraints are
    // reflected in the result.
    let result_type = apply_subst(s, ret_var)

    // Call-site pre-boxing consumes only exact DirectCallable metadata.
    match callee_metadata {
        some(metadata) => match metadata.mut_flags {
            some(mut_flags) => {
                let mut mi = 0
                while mi < mut_flags.len() && mi < args.len() {
                    match (mut_flags.get(mi), hargs.get(mi)) {
                        (some(is_mut), some(harg)) => {
                            if is_mut {
                                match harg {
                                    HExpr::Ident { def_id: some(arg_did), .. } => {
                                        if ctx.env.scope.mutable_vars.contains(arg_did) {
                                            match resolved_callee_type {
                                                Type::FnType { params: fn_params, .. } => {
                                                    match fn_params.get(mi) {
                                                        some(pt) => {
                                                            let resolved_pt = apply_subst(s, pt)
                                                            if is_value_type(resolved_pt) {
                                                                ctx.boxed_vars.insert(arg_did)
                                                            }
                                                        },
                                                        none => {}
                                                    }
                                                },
                                                _ => {}
                                            }
                                        }
                                    },
                                    _ => {}
                                }
                            }
                        },
                        _ => {}
                    }
                    mi = mi + 1
                }
            },
            none => {}
        },
        none => {}
    }

    InferResult {
        hexpr: HExpr::Call {
            callee: callee_r.hexpr, args: hargs, type_args: [],
            resolved_dicts: resolved_dicts, dict_dispatch: none,
            method_ref: none,
            ty: result_type, effects: effects, span: span
        },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_method_call
// ============================================================

fn infer_method_call(mut ctx: InferCtx, receiver: Expr, method: Str, args: List<Expr>, span: Span, subst: UnionFind) -> InferResult {
    // Check if receiver is an effect module
    match receiver {
        Expr::Ident { name: recv_name, qualifier, .. } => {
            let full_effect_name = match qualifier {
                some(q) => "${q}::${recv_name}",
                none => recv_name
            }
            match ctx.env.types.effects.get(full_effect_name) {
                some(_) => { return infer_effect_op(ctx, full_effect_name, method, args, span, subst) },
                none => {}
            }
        },
        _ => {}
    }

    let recv_r = infer_expr(ctx, receiver, subst)
    infer_method_call_from_receiver(
        ctx, some(receiver), recv_r, method, args, span, none)
}

// Shared method-call inference after receiver evaluation. Protocol lowering
// supplies an authoritative selection; ordinary source calls leave it absent
// and use the existing name resolver below. In both cases argument inference,
// unification, effects, dictionaries, and HIR construction remain identical.
fn infer_method_call_from_receiver(
    mut ctx: InferCtx, receiver_source: Expr?, recv_r: InferResult,
    method: Str, args: List<Expr>, span: Span,
    selection: MethodCallSelection?
) -> InferResult {
    let mut s = recv_r.subst
    let mut effects = recv_r.effects
    let recv_type = apply_subst(s, hexpr_type(recv_r.hexpr))

    // Check receiver mutability for mut self methods
    match receiver_source {
        some(receiver) =>
            check_receiver_mutability(ctx, receiver, recv_type, method, span),
        none => {}
    }

    // Inject mut<T> effect when calling mut method on a mut function parameter
    if is_mut_method_call(ctx, recv_type, method) {
        match receiver_source {
            some(receiver) => match get_expr_def_id(ctx, receiver) {
                some(did) => {
                    if ctx.env.scope.mut_param_defs.contains(did) {
                        let mut_eff = Effect::MutEffect { state_type: recv_type }
                        let me = merge_effects(ctx.sink, ctx.env, effects, effect_row([mut_eff]), s, span)
                        effects = me.0
                        s = me.1
                    }
                },
                none => {}
            },
            none => {}
        }
    }

    let mut method_type: Type? = none
    let mut method_core: ImplMethodSchemeCore? = none
    let mut impl_owner: ImplEntry? = none
    let mut dict_dispatch: DictDispatchInfo? = none
    let mut intrinsic_ref: IntrinsicRef? = none

    match selection {
        some(selected) => {
            method_type = selected.method_type
            method_core = selected.method_core
            impl_owner = selected.impl_owner
            dict_dispatch = selected.dict_dispatch
            intrinsic_ref = selected.intrinsic_ref
        },
        none => {}
    }

    // Look up method in impl for struct/enum
    if method_type.is_none() {
        match recv_type {
            Type::StructType { name, .. } => {
                let r = lookup_impl_method(ctx, name, method)
                method_type = r.method_type
                method_core = r.method_core
                impl_owner = r.impl_owner
                intrinsic_ref = r.intrinsic_ref
            },
            Type::EnumType { name, .. } => {
                let r = lookup_impl_method(ctx, name, method)
                method_type = r.method_type
                method_core = r.method_core
                impl_owner = r.impl_owner
                intrinsic_ref = r.intrinsic_ref
            },
            _ => {}
        }
    }

    // Method lookup for primitive types
    if method_type.is_none() {
        match type_to_builtin_name(recv_type) {
            some(prim_name) => {
                let r = lookup_impl_method(ctx, prim_name, method)
                method_type = r.method_type
                method_core = r.method_core
                impl_owner = r.impl_owner
                intrinsic_ref = r.intrinsic_ref
            },
            none => {}
        }
    }

    // Check trait impls
    if method_type.is_none() {
        match type_to_builtin_name(recv_type) {
            some(type_name) => {
                let r = lookup_trait_method(ctx, type_name, method, span)
                method_type = r.method_type
                method_core = r.method_core
                impl_owner = r.impl_owner
                intrinsic_ref = r.intrinsic_ref
            },
            none => {}
        }
    }

    // Check fn bounds for type variable receivers
    let recv_raw_type = hexpr_type(recv_r.hexpr)
    let recv_var_id = match recv_raw_type {
        Type::TypeVar { id, .. } => some(resolve_var_id(id, s)),
        _ => none
    }
    if method_type.is_none() {
        match recv_var_id {
            some(rvid) => {
                for fb in ctx.current_fn_bounds {
                    if resolve_var_id(fb.type_param_var_id, s) == rvid {
                        match ctx.env.trait_reg.traits.get(fb.trait_name) {
                            some(trait_def) => {
                                let tm = trait_def.methods.find(fn(m) { m.name == method })
                                match tm {
                                    some(found_method) => {
                                        method_type = some(ctx.env.instantiate(TypeScheme { ty: found_method.ty, type_vars: trait_def.type_param_vars, bounds: [], def_id: none }))
                                        dict_dispatch = some(DictDispatchInfo {
                                            dict_ref: DictRef::Simple(trait_bound_param_name(
                                                fb.type_param_name, fb.trait_name)),
                                            method: method
                                        })
                                    },
                                    none => {}
                                }
                            },
                            none => {}
                        }
                    }
                }
            },
            none => {}
        }
    }

    // Early receiver-method unification for bidirectional type checking
    match method_type {
        some(mt) => match mt {
            Type::FnType { params: mt_params, .. } => {
                if mt_params.len() > 0 {
                    match mt_params.first() {
                        some(first_param) => {
                            let recv_notes: List<DiagnosticNote> = [
                                DiagnosticNote { message: "method '${method}' expects receiver of type '${type_to_string(apply_subst(s, first_param))}'", span: some(span) },
                                DiagnosticNote { message: "receiver has type '${type_to_string(apply_subst(s, hexpr_type(recv_r.hexpr)))}'", span: some(hexpr_span(recv_r.hexpr)) }
                            ]
                            s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(recv_r.hexpr), first_param, s, span, recv_notes)
                        },
                        none => {}
                    }
                }
            },
            _ => {}
        },
        none => {}
    }

    // Infer arguments with lambda type propagation
    let mut hargs: List<HExpr> = []
    let mut ai = 0
    for arg in args {
        let mut ar: InferResult = match arg {
            Expr::Lambda { params: lparams, body: lbody, span: lspan, .. } => {
                match method_type {
                    some(mt) => match mt {
                        Type::FnType { params: mt_params, .. } => {
                            if ai + 1 < mt_params.len() {
                                match mt_params.get(ai + 1) {
                                    some(expected_raw) => {
                                        let expected = apply_subst(s, expected_raw)
                                        match expected {
                                            Type::FnType { params: exp_params, .. } => {
                                                infer_lambda(ctx, lparams, lbody, lspan, s, some(exp_params))
                                            },
                                            _ => infer_expr(ctx, arg, s)
                                        }
                                    },
                                    none => infer_expr(ctx, arg, s)
                                }
                            } else { infer_expr(ctx, arg, s) }
                        },
                        _ => infer_expr(ctx, arg, s)
                    },
                    none => infer_expr(ctx, arg, s)
                }
            },
            _ => infer_expr(ctx, arg, s)
        }
        s = ar.subst
        let me = merge_effects(ctx.sink, ctx.env, effects, ar.effects, s, span)
        effects = me.0
        s = me.1
        hargs.push(ar.hexpr)
        ai = ai + 1
    }

    let mut result_type: Type = ctx.env.fresh_var()
    match method_type {
        some(mt) => match mt {
            Type::FnType { params: mt_params, return_type: mt_ret, effects: mt_effects, .. } => {
                let mut i = 0
                for harg in hargs {
                    if i + 1 < mt_params.len() {
                        match mt_params.get(i + 1) {
                            some(expected_param) => {
                                let arg_num = (i + 1).to_str()
                                let marg_notes: List<DiagnosticNote> = [
                                    DiagnosticNote { message: "argument ${arg_num} of method '${method}' expects type '${type_to_string(apply_subst(s, expected_param))}'", span: some(span) },
                                    DiagnosticNote { message: "argument has type '${type_to_string(apply_subst(s, hexpr_type(harg)))}'", span: some(hexpr_span(harg)) }
                                ]
                                s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(harg), expected_param, s, span, marg_notes)
                            },
                            none => {}
                        }
                    }
                    i = i + 1
                }
                // Check for excess arguments (mt_params[0] is self)
                let expected_args = mt_params.len() - 1
                if hargs.len() > expected_args {
                    let _ = type_error(ctx.sink, E0301,
                        "Method '${method}' expects ${expected_args.to_str()} argument(s), got ${hargs.len().to_str()}",
                        span, DiagnosticContext::TypeMismatch { expected: "${expected_args.to_str()} args", actual: "${hargs.len().to_str()} args", expression: none })
                }
                // Check for too few arguments (mt_params[0] is self)
                if hargs.len() < expected_args {
                    let _ = type_error(ctx.sink, E0301,
                        "Method '${method}' expects ${expected_args.to_str()} argument(s), got ${hargs.len().to_str()}",
                        span, DiagnosticContext::TypeMismatch { expected: "${expected_args.to_str()} args", actual: "${hargs.len().to_str()} args", expression: none })
                }
                result_type = apply_subst(s, mt_ret)
                let me = merge_effects(ctx.sink, ctx.env, effects, mt_effects, s, span)
                effects = me.0
                s = me.1
                // Cancel mut<T> effects for method arguments that are local variables
                // param_offset=1 because mt_params[0] is self
                effects = cancel_local_mut_effects(ctx, effects, mt_params, mt_effects, hargs, 1, s)
            },
            _ => {
                match recv_type {
                    Type::TypeVar { .. } => {},
                    _ => { let _ = type_error(ctx.sink, E0305,
                        "Type '${type_to_string(recv_type)}' has no method '${method}'",
                        span, DiagnosticContext::OtherContext { detail: some("no method '${method}' on type '${type_to_string(recv_type)}'") }) }
                }
            }
        },
        none => {
            match recv_type {
                Type::TypeVar { .. } => {},
                _ => { let _ = type_error(ctx.sink, E0305,
                    "Type '${type_to_string(recv_type)}' has no method '${method}'",
                    span, DiagnosticContext::OtherContext { detail: some("no method '${method}' on type '${type_to_string(recv_type)}'") }) }
            }
        }
    }

    let resolved_dicts: List<DictRef> = []
    match (impl_owner, method_core, method_type) {
        (some(owner), some(core), some(mt)) => {
            resolve_or_defer_dicts_from_impl_owner(
                ctx, owner, core, mt, s, span,
                PendingDictPurpose::DirectCallPublish {
                    output_slot: resolved_dicts
                })
        },
        _ => {}
    }

    // B-100 Fix 3: recompute result_type after dict resolution so
    // associated type unifications are visible.
    result_type = apply_subst(s, result_type)

    let callee_type = match method_type { some(mt) => mt, none => ctx.env.fresh_var() }
    let exact_method_ref: MethodCallRef? = match intrinsic_ref {
        some(intrinsic) => some(make_intrinsic_method_call_ref(
            intrinsic, callee_type)),
        none => none
    }
    InferResult {
        hexpr: HExpr::Call {
            callee: HExpr::FieldAccess {
                receiver: recv_r.hexpr, field: method,
                access_kind: HFieldAccessKind::Method,
                ty: callee_type, effects: EMPTY_ROW, span: span },
            args: hargs, type_args: [], resolved_dicts: resolved_dicts,
            dict_dispatch: dict_dispatch, method_ref: exact_method_ref,
            ty: result_type, effects: effects, span: span
        },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_effect_op
// ============================================================

fn infer_effect_op(mut ctx: InferCtx, effect_name: Str, op_name: Str, args: List<Expr>, span: Span, subst: UnionFind) -> InferResult {
    let effect_def_opt = ctx.env.types.effects.get(effect_name)
    match effect_def_opt {
        none => {
            let effect_display = nominal_display_name(effect_name)
            let _ = type_error(ctx.sink, E0402,
                "Unknown effect: ${effect_display}",
                span, DiagnosticContext::OtherContext { detail: some("effect '${effect_display}' not found") })
            return InferResult {
                hexpr: HExpr::EffectOp { effect_name: effect_name, op_name: op_name, args: [], ty: Type::ErrorType, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            }
        },
        _ => {}
    }
    let effect_def = match effect_def_opt { some(ed) => ed, none => panic("unreachable: effect_def_opt after none early return") }
    // Use canonical name from EffectDef so mod-internal unqualified references
    // (e.g. "Greeter") resolve to the declaration name (e.g. "fx::Greeter")
    let canonical_effect_name = effect_def.name
    let op_opt = effect_def.ops.find(fn(o) { o.name == op_name })
    match op_opt {
        none => {
            let effect_display = nominal_display_name(canonical_effect_name)
            let _ = type_error(ctx.sink, E0402,
                "Effect ${effect_display} has no operation ${op_name}",
                span, DiagnosticContext::OtherContext { detail: some("no operation '${op_name}' on effect '${effect_display}'") })
            return InferResult {
                hexpr: HExpr::EffectOp { effect_name: canonical_effect_name, op_name: op_name, args: [], ty: Type::ErrorType, effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            }
        },
        _ => {}
    }
    let op = match op_opt { some(o) => o, none => panic("unreachable: op_opt after none early return") }

    // Instantiate effect type params with fresh variables
    let mut inst_map: Map<Int, Type> = map_new()
    let mut inst_type_args: List<Type> = []
    let mut tpi = 0
    for tpv in effect_def.type_param_vars {
        let fresh = ctx.env.fresh_var()
        inst_map.insert(tpv, fresh)
        inst_type_args.push(fresh)
        tpi = tpi + 1
    }

    // Apply instantiation to op param types and return type
    let mut inst_params: List<Type> = []
    for pt in op.params {
        inst_params.push(apply_subst_map(inst_map, pt))
    }
    let inst_ret = apply_subst_map(inst_map, op.return_type)

    if args.len() != inst_params.len() {
        let effect_display = nominal_display_name(effect_name)
        let _ = type_error(ctx.sink, E0301,
            "Effect operation '${effect_display}.${op_name}' expects ${inst_params.len().to_str()} argument(s), got ${args.len().to_str()}",
            span, DiagnosticContext::TypeMismatch { expected: "${inst_params.len().to_str()} args", actual: "${args.len().to_str()} args", expression: none })
    }

    let mut s = subst
    let mut effects: EffectRow = EMPTY_ROW
    let mut hargs: List<HExpr> = []

    let mut i = 0
    for arg in args {
        let ar = infer_expr(ctx, arg, s)
        s = ar.subst
        let me = merge_effects(ctx.sink, ctx.env, effects, ar.effects, s, span)
        effects = me.0
        s = me.1
        hargs.push(ar.hexpr)
        match inst_params.get(i) {
            some(param_type) => { s = unify_at(ctx.sink, ctx.env, hexpr_type(ar.hexpr), param_type, s, span) },
            none => {}
        }
        i = i + 1
    }

    let mut eff: Effect = Effect::CustomEffect { name: canonical_effect_name, type_args: inst_type_args }
    match effect_def.built_in_kind {
        some(bik) => match bik {
            BuiltInKind::BkIo => { eff = Effect::IoEffect },
            BuiltInKind::BkFail => {
                let error_type = if hargs.len() > 0 { apply_subst(s, hexpr_type(match hargs.first() { some(h) => h, none => panic("unreachable: hargs.first() after len > 0 check") })) } else { UNIT }
                eff = Effect::FailEffect { error_type: error_type }
            },
            BuiltInKind::BkMut => { eff = Effect::MutEffect { state_type: ctx.env.fresh_var() } }
        },
        none => {}
    }

    let me = merge_effects(ctx.sink, ctx.env, effects, effect_row([eff]), s, span)
    effects = me.0
    s = me.1

    InferResult {
        hexpr: HExpr::EffectOp { effect_name: canonical_effect_name, op_name: op_name, args: hargs, ty: inst_ret, effects: effects, span: span },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_field_access
// ============================================================

fn infer_field_access(mut ctx: InferCtx, receiver: Expr, field: Str, span: Span, subst: UnionFind) -> InferResult {
    let recv_r = infer_expr(ctx, receiver, subst)
    let s = recv_r.subst
    let recv_type = apply_subst(s, hexpr_type(recv_r.hexpr))

    let mut field_type: Type = ctx.env.fresh_var()
    let mut access_kind = HFieldAccessKind::ErrorRecovery
    match recv_type {
        Type::StructType { name, type_params, .. } => {
            match ctx.env.types.structs.get(name) {
                some(struct_def) => {
                    let f = struct_def.fields.find(fn(f_) { f_.name == field })
                    match f {
                        some(found_field) => {
                            access_kind = HFieldAccessKind::NominalField {
                                owner_ref: struct_def.owner_ref,
                                field_ref: found_field.field_ref,
                                field_index: found_field.field_index
                            }
                            let mut inst_map: Map<Int, Type> = map_new()
                            let mut fi = 0
                            while fi < struct_def.type_param_vars.len() && fi < type_params.len() {
                                match (struct_def.type_param_vars.get(fi), type_params.get(fi)) {
                                    (some(var_id), some(tp)) => inst_map.insert(var_id, tp),
                                    _ => {}
                                }
                                fi = fi + 1
                            }
                            field_type = apply_subst_map(inst_map, found_field.ty)
                        },
                        none => { let _ = type_error(ctx.sink, E0304,
                            "Struct ${name} has no field ${field}",
                            span, DiagnosticContext::MissingField { field: field, ty: name, available: none }) }
                    }
                },
                none => { let _ = type_error(ctx.sink, E0203,
                    "Unknown struct: ${name}",
                    span, DiagnosticContext::OtherContext { detail: some("unknown struct '${name}'") }) }
            }
        },
        Type::RecordType { fields: rec_fields, tail, .. } => {
            access_kind = HFieldAccessKind::RecordField
            let f = rec_fields.find(fn(f_) { f_.name == field })
            match f {
                some(found_field) => { field_type = found_field.ty },
                none => match tail {
                    some(_) => {},
                    none => { let _ = type_error(ctx.sink, E0304,
                        "Record type has no field '${field}'",
                        span, DiagnosticContext::MissingField { field: field, ty: "record", available: none }) }
                }
            }
        },
        Type::TupleType { elements } => {
            access_kind = HFieldAccessKind::TupleField
            match parse_int(field) {
                none => { let _ = type_error(ctx.sink, E0304,
                    "Cannot access named field '${field}' on tuple type; use .0, .1, etc.",
                    span, DiagnosticContext::MissingField { field: field, ty: "tuple", available: none }) },
                some(i) => {
                    if i < 0 || i >= elements.len() {
                        let _ = type_error(ctx.sink, E0304,
                            "Tuple index ${field} out of bounds; tuple has ${elements.len().to_str()} elements",
                            span, DiagnosticContext::MissingField { field: field, ty: "tuple", available: none })
                        field_type = Type::ErrorType
                    } else {
                        match elements.get(i) {
                            some(t) => { field_type = t },
                            none => { field_type = Type::ErrorType }
                        }
                    }
                }
            }
        },
        Type::TypeVar { .. } => {},
        _ => { let _ = type_error(ctx.sink, E0304,
            "Cannot access field '${field}' on type ${type_to_string(recv_type)}",
            span, DiagnosticContext::MissingField { field: field, ty: type_to_string(recv_type), available: none }) }
    }

    InferResult {
        hexpr: HExpr::FieldAccess {
            receiver: recv_r.hexpr, field: field,
            access_kind: access_kind, ty: field_type,
            effects: recv_r.effects, span: span },
        subst: s, effects: recv_r.effects
    }
}

// ============================================================
// infer_struct_lit
// ============================================================

fn infer_struct_lit(mut ctx: InferCtx, name: Str, fields: List<StructFieldInit>, spread: Expr?, span: Span, subst: UnionFind, qualifier: Str?) -> InferResult {
    // Resolve relative paths (self::/super::)
    let mut resolved_qualifier = qualifier
    match qualifier {
        some(q) => {
            if q == "self" || q.starts_with("super") {
                match resolve_relative_qualifier(q, ctx.mod_path_stack) {
                    some(prefix) => {
                        if prefix == "" {
                            resolved_qualifier = none
                        } else {
                            resolved_qualifier = some(prefix)
                        }
                    },
                    none => {
                        let _ = type_error(ctx.sink, E0705,
                            "Cannot use '${q}' — relative path exceeds module nesting depth",
                            span, DiagnosticContext::OtherContext { detail: some("relative path out of scope") })
                        return InferResult {
                            hexpr: HExpr::IntLit {
                                value: 0, ty: Type::ErrorType,
                                effects: EMPTY_ROW, span: span },
                            subst: subst, effects: EMPTY_ROW
                        }
                    }
                }
            }
        },
        none => {}
    }

    // Try module-qualified struct lookup: qualifier::name
    match resolved_qualifier {
        some(q) => {
            let qualified_name = "${q}::${name}"
            let mod_struct = ctx.env.types.structs.get(qualified_name)
            match mod_struct {
                some(_) => {
                    return infer_struct_lit(ctx, qualified_name, fields, spread, span, subst, none)
                },
                none => {
                    // Fallback: try prepending current mod path for relative references
                    if ctx.mod_path_stack.len() > 0 {
                        let mod_prefix = ctx.mod_path_stack.join("::")
                        let full_qualified = "${mod_prefix}::${qualified_name}"
                        let full_struct = ctx.env.types.structs.get(full_qualified)
                        match full_struct {
                            some(_) => {
                                return infer_struct_lit(ctx, full_qualified, fields, spread, span, subst, none)
                            },
                            none => {}
                        }
                    }
                }
            }
        },
        none => {}
    }

    // Check for named enum variant
    let mut variant_enum: Str? = none
    match resolved_qualifier {
        some(q) => {
            match ctx.env.types.enums.get(q) {
                some(enum_def) => {
                    if enum_def.variant_index.contains_key(name) { variant_enum = some(enum_def.name) }
                },
                none => {
                    // Fallback: try prepending current mod path
                    if ctx.mod_path_stack.len() > 0 {
                        let mod_prefix = ctx.mod_path_stack.join("::")
                        let full_q = "${mod_prefix}::${q}"
                        match ctx.env.types.enums.get(full_q) {
                            some(enum_def) => {
                                if enum_def.variant_index.contains_key(name) { variant_enum = some(enum_def.name) }
                            },
                            none => {}
                        }
                    }
                }
            }
        },
        none => { variant_enum = ctx.env.types.variant_to_enum.get(name) }
    }
    if variant_enum.is_none() && resolved_qualifier.is_some() {
        match resolved_qualifier {
            some(q) => {
                let qualifier_display = nominal_display_name(q)
                let _ = type_error(ctx.sink, E0201, "'${qualifier_display}' has no variant '${name}'", span,
                    DiagnosticContext::UndefinedVariable { name: name, scope_locals: none })
            },
            none => {}
        }
    }
    match variant_enum {
        some(ve) => match ctx.env.types.enums.get(ve) {
            some(enum_def) => {
                let variant = lookup_variant(enum_def, name)
                match variant {
                    some(v) => match v.field_names {
                        some(_) => { return infer_named_variant_construct(ctx, ve, name, v, enum_def, fields, spread, span, subst) },
                        none => {}
                    },
                    none => {}
                }
            },
            none => {}
        },
        none => {}
    }

    let struct_def_opt = ctx.env.types.structs.get(name)
    match struct_def_opt {
        none => {
            let _ = type_error(ctx.sink, E0203, "Unknown struct: ${name}", span,
                DiagnosticContext::OtherContext { detail: some("unknown struct '${name}'") })
            return InferResult {
                hexpr: HExpr::IntLit {
                    value: 0, ty: Type::ErrorType,
                    effects: EMPTY_ROW, span: span },
                subst: subst, effects: EMPTY_ROW
            }
        },
        _ => {}
    }
    let struct_def = match struct_def_opt { some(sd) => sd, none => panic("unreachable: struct_def_opt after none early return") }

    let mut inst_map: Map<Int, Type> = map_new()
    let mut type_param_types: List<Type> = []
    let mut tpi = 0
    while tpi < struct_def.type_param_vars.len() {
        match struct_def.type_param_vars.get(tpi) {
            some(var_id) => {
                let tv = ctx.env.fresh_var()
                inst_map.insert(var_id, tv)
                type_param_types.push(tv)
            },
            none => {}
        }
        tpi = tpi + 1
    }

    let mut s = subst
    let mut effects: EffectRow = EMPTY_ROW
    let mut hfields: List<HNominalStructFieldInit> = []

    let mut hspread: HExpr? = none
    match spread {
        some(sp) => {
            let sr = infer_expr(ctx, sp, s)
            s = sr.subst
            let me = merge_effects(ctx.sink, ctx.env, effects, sr.effects, s, span)
            effects = me.0
            s = me.1
            let spread_type = Type::StructType { name: struct_def.name, type_params: type_param_types }
            s = unify_at(ctx.sink, ctx.env, hexpr_type(sr.hexpr), spread_type, s, span)
            hspread = some(sr.hexpr)
        },
        none => {}
    }

    for field in fields {
        let fr = infer_expr(ctx, field.value, s)
        s = fr.subst
        let me = merge_effects(ctx.sink, ctx.env, effects, fr.effects, s, span)
        effects = me.0
        s = me.1
        let def_field = struct_def.fields.find(fn(f) { f.name == field.name })
        match def_field {
            some(df) => {
                let ft = apply_subst_map(inst_map, df.ty)
                let field_notes: List<DiagnosticNote> = [
                    DiagnosticNote { message: "field '${field.name}' of struct '${name}' expects type '${type_to_string(ft)}'", span: some(field.span) },
                    DiagnosticNote { message: "provided value has type '${type_to_string(apply_subst(s, hexpr_type(fr.hexpr)))}'", span: some(hexpr_span(fr.hexpr)) }
                ]
                s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(fr.hexpr), ft, s, span, field_notes)
                hfields.push(HNominalStructFieldInit {
                    name: field.name,
                    field_ref: df.field_ref,
                    field_index: df.field_index,
                    value: fr.hexpr
                })
            },
            none => { let _ = type_error(ctx.sink, E0203,
                "Struct '${name}' has no field '${field.name}'",
                field.span, DiagnosticContext::MissingField { field: field.name, ty: name, available: none }) }
        }
    }

    if spread.is_none() {
        let mut provided: Set<Str> = set_new()
        for f in fields { provided.insert(f.name) }
        for df in struct_def.fields {
            if !provided.contains(df.name) {
                let _ = type_error(ctx.sink, E0203,
                    "Missing field '${df.name}' in struct literal '${name}'",
                    span, DiagnosticContext::MissingField { field: df.name, ty: name, available: none })
            }
        }
    }

    let struct_type = Type::StructType {
        name: struct_def.name, type_params: type_param_types
    }

    InferResult {
        hexpr: HExpr::StructLit {
            name: struct_def.name, owner_ref: struct_def.owner_ref,
            type_args: [], fields: hfields, spread: hspread,
            ty: struct_type, effects: effects, span: span },
        subst: s, effects: effects
    }
}

fn infer_named_variant_construct(mut ctx: InferCtx, enum_name: Str, variant_name: Str, variant: EnumVariant, enum_def: EnumDef, fields: List<StructFieldInit>, spread: Expr?, span: Span, subst: UnionFind) -> InferResult {
    let field_names = match variant.field_names { some(fn_) => fn_, none => [] }

    let mut inst_map: Map<Int, Type> = map_new()
    let mut type_param_types: List<Type> = []
    let mut tpi = 0
    while tpi < enum_def.type_param_vars.len() {
        match enum_def.type_param_vars.get(tpi) {
            some(var_id) => {
                let tv = ctx.env.fresh_var()
                inst_map.insert(var_id, tv)
                type_param_types.push(tv)
            },
            none => {}
        }
        tpi = tpi + 1
    }

    let mut s = subst
    let mut effects: EffectRow = EMPTY_ROW
    let mut hfields: List<HStructFieldInit> = []

    let mut hspread: HExpr? = none
    match spread {
        some(sp) => {
            let sr = infer_expr(ctx, sp, s)
            s = sr.subst
            let me = merge_effects(ctx.sink, ctx.env, effects, sr.effects, s, span)
            effects = me.0
            s = me.1
            let spread_enum_type = Type::EnumType { name: enum_name, type_params: type_param_types }
            s = unify_at(ctx.sink, ctx.env, hexpr_type(sr.hexpr), spread_enum_type, s, span)
            hspread = some(sr.hexpr)
        },
        none => {}
    }

    for field in fields {
        let fr = infer_expr(ctx, field.value, s)
        s = fr.subst
        let me = merge_effects(ctx.sink, ctx.env, effects, fr.effects, s, span)
        effects = me.0
        s = me.1
        let field_idx = field_names.index_of(field.name)
        match field_idx {
            some(idx) => match variant.fields.get(idx) {
                some(ftype) => {
                    let ft = apply_subst_map(inst_map, ftype)
                    s = unify_at(ctx.sink, ctx.env, hexpr_type(fr.hexpr), ft, s, span)
                },
                none => {}
            },
            none => { let _ = type_error(ctx.sink, E0203,
                "Variant '${variant_name}' has no field '${field.name}'",
                field.span, DiagnosticContext::MissingField { field: field.name, ty: variant_name, available: none }) }
        }
        hfields.push(HStructFieldInit { name: field.name, value: fr.hexpr })
    }

    if spread.is_none() {
        let mut provided: Set<Str> = set_new()
        for f in fields { provided.insert(f.name) }
        for fn_name in field_names {
            if !provided.contains(fn_name) {
                let _ = type_error(ctx.sink, E0203,
                    "Missing field '${fn_name}' in variant '${variant_name}'",
                    span, DiagnosticContext::MissingField { field: fn_name, ty: variant_name, available: none })
            }
        }
    }

    let enum_type = Type::EnumType { name: enum_name, type_params: type_param_types }

    InferResult {
        hexpr: HExpr::NamedVariantConstruct {
            enum_name: enum_name, variant_name: variant_name,
            fields: hfields, spread: hspread, ty: enum_type, effects: effects, span: span
        },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_match
// ============================================================

fn collect_exact_pattern_bindings(
    env: TypeEnv, pattern: Pattern, mut seen: Set<Str>,
    mut out: List<HPatternBinding>
) {
    match pattern {
        Pattern::Wildcard { .. } | Pattern::Literal { .. } => {},
        Pattern::Binding { name, .. } => {
            if name != "_" && !seen.contains(name) {
                seen.insert(name)
                let scheme = match env.lookup(name) {
                    some(value) => value,
                    none => panic(
                        "unreachable: inferred pattern binding is absent from its lexical scope")
                }
                let def_id = match scheme.def_id {
                    some(id) => id,
                    none => panic(
                        "unreachable: inferred pattern binding has no exact DefId")
                }
                out.push(HPatternBinding {
                    name: name, def_id: def_id, ty: scheme.ty
                })
            }
        },
        Pattern::Constructor { fields, .. } => {
            for field in fields {
                collect_exact_pattern_bindings(env, field, seen, out)
            }
        },
        Pattern::NamedConstructor { fields, .. } => {
            for field in fields {
                collect_exact_pattern_bindings(
                    env, field.pattern, seen, out)
            }
        },
        Pattern::TuplePattern { elements, .. } => {
            for element in elements {
                collect_exact_pattern_bindings(env, element, seen, out)
            }
        },
        Pattern::OrPattern { patterns, .. } => {
            for alternative in patterns {
                collect_exact_pattern_bindings(env, alternative, seen, out)
            }
        }
    }
}

fn exact_pattern_bindings(
    env: TypeEnv, pattern: Pattern
) -> List<HPatternBinding> {
    let mut result: List<HPatternBinding> = []
    let mut seen: Set<Str> = set_new()
    collect_exact_pattern_bindings(env, pattern, seen, result)
    result
}

fn infer_match(mut ctx: InferCtx, scrutinee: Expr, arms: List<MatchArm>, span: Span, subst: UnionFind) -> InferResult {
    let scrut_r = infer_expr(ctx, scrutinee, subst)
    let mut s = scrut_r.subst
    let mut effects = scrut_r.effects
    let result_type = ctx.env.fresh_var()
    let mut harms: List<HMatchArm> = []
    // #180: track whether a non-Never arm has contributed to result_type.
    // When true, subsequent Never arms skip unification to avoid poisoning
    // the result type variable (which may chain to a polymorphic type param T).
    let mut has_non_never_arm = false

    for arm in arms {
        ctx.env.push_scope()
        let arm_result = some({
            let match_pattern = rewrite_bare_enum_bindings(ctx.env, arm.pattern)
            s = bind_pattern(ctx, match_pattern, hexpr_type(scrut_r.hexpr), s)
            let pattern_bindings = exact_pattern_bindings(
                ctx.env, match_pattern)

            let mut guard_hexpr: HExpr? = none
            match arm.guard {
                some(g) => {
                    let gr = infer_expr(ctx, g, s)
                    s = gr.subst
                    s = unify_at(ctx.sink, ctx.env, hexpr_type(gr.hexpr), BOOL, s, arm.span)
                    let me = merge_effects(ctx.sink, ctx.env, effects, gr.effects, s, arm.span)
                    effects = me.0
                    s = me.1
                    guard_hexpr = some(gr.hexpr)
                },
                none => {}
            }

            let body_r = infer_expr(ctx, arm.body, s)
            s = body_r.subst
            let me = merge_effects(ctx.sink, ctx.env, effects, body_r.effects, s, arm.span)
            effects = me.0
            s = me.1
            // #180: skip arm-vs-result unification when the arm body is Never
            // AND a non-Never arm has already been unified.  Never is the bottom
            // type — compatible with any result type, but unifying it with a
            // result_type that chains to a polymorphic type param T would bind
            // T = Never, causing all callers to see the function as diverging.
            // When no non-Never arm has run yet (all arms so far are Never), we
            // allow the binding so all-diverging matches correctly have type Never.
            let arm_body_resolved = apply_subst(s, hexpr_type(body_r.hexpr))
            let arm_is_never = match arm_body_resolved { Type::NeverType => true, _ => false }
            if arm_is_never && has_non_never_arm {
                // A non-Never arm already determined the result type;
                // skip to avoid poisoning the type chain.
            } else {
                let match_notes: List<DiagnosticNote> = [
                    DiagnosticNote { message: "match arms must all have the same type", span: some(arm.span) },
                    DiagnosticNote { message: "this arm has type '${type_to_string(apply_subst(s, hexpr_type(body_r.hexpr)))}'", span: some(hexpr_span(body_r.hexpr)) }
                ]
                s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(body_r.hexpr), result_type, s, arm.span, match_notes)
                if !arm_is_never {
                    has_non_never_arm = true
                }
            }

            harms.push(HMatchArm { pattern: match_pattern,
                bindings: pattern_bindings, guard: guard_hexpr,
                body: body_r.hexpr, span: arm.span })
            true
        }) catch { _ => none }
        ctx.env.pop_scope()
        match arm_result {
            none => fail.raise(CompileError {}),
            _ => {}
        }
    }

    let scrut_type_resolved = apply_subst(s, hexpr_type(scrut_r.hexpr))
    let missing = check_exhaustive(ctx.env, harms, scrut_type_resolved, s)
    match missing {
        some(m) => {
            let msg = if m == "_" {
                "Non-exhaustive match: non-finite type '${type_to_string(scrut_type_resolved)}' requires a wildcard '_' or binding pattern"
            } else {
                "Non-exhaustive match on type ${type_to_string(scrut_type_resolved)}: missing pattern for ${m}"
            }
            let _ = type_error(ctx.sink, E0601,
                msg,
                span, DiagnosticContext::PatternError { detail: "missing: ${m}" })
        },
        none => {}
    }

    let final_type = apply_subst(s, result_type)
    InferResult {
        hexpr: HExpr::MatchExpr { scrutinee: scrut_r.hexpr, arms: harms, ty: final_type, effects: effects, span: span },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_if
// ============================================================

fn infer_if(mut ctx: InferCtx, condition: Expr, then_branch: Expr, else_branch: Expr?, span: Span, subst: UnionFind) -> InferResult {
    let cond_r = infer_expr(ctx, condition, subst)
    let mut s = cond_r.subst
    s = unify_at(ctx.sink, ctx.env, hexpr_type(cond_r.hexpr), BOOL, s, span)
    let mut effects = cond_r.effects

    let then_r = infer_scoped_block(ctx, then_branch, some(s))
    s = then_r.subst
    let me = merge_effects(ctx.sink, ctx.env, effects, then_r.effects, s, span)
    effects = me.0
    s = me.1

    let mut else_hexpr: HExpr? = none
    let mut result_type: Type = UNIT

    match else_branch {
        some(eb) => match eb {
            Expr::Block { .. } => {
                let else_r = infer_scoped_block(ctx, eb, some(s))
                s = else_r.subst
                let me2 = merge_effects(ctx.sink, ctx.env, effects, else_r.effects, s, span)
                effects = me2.0
                s = me2.1
                let if_notes: List<DiagnosticNote> = [
                    DiagnosticNote { message: "then branch has type '${type_to_string(apply_subst(s, hexpr_type(then_r.hexpr)))}'", span: some(hexpr_span(then_r.hexpr)) },
                    DiagnosticNote { message: "else branch has type '${type_to_string(apply_subst(s, hexpr_type(else_r.hexpr)))}'", span: some(hexpr_span(else_r.hexpr)) }
                ]
                s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(then_r.hexpr), hexpr_type(else_r.hexpr), s, span, if_notes)
                result_type = apply_subst(s, hexpr_type(then_r.hexpr))
                else_hexpr = some(else_r.hexpr)
            },
            Expr::IfExpr { condition: ec, then_branch: etb, else_branch: eeb, span: espan } => {
                let else_if_r = infer_if(ctx, ec, etb, eeb, espan, s)
                s = else_if_r.subst
                let me2 = merge_effects(ctx.sink, ctx.env, effects, else_if_r.effects, s, span)
                effects = me2.0
                s = me2.1
                let elif_notes: List<DiagnosticNote> = [
                    DiagnosticNote { message: "then branch has type '${type_to_string(apply_subst(s, hexpr_type(then_r.hexpr)))}'", span: some(hexpr_span(then_r.hexpr)) },
                    DiagnosticNote { message: "else branch has type '${type_to_string(apply_subst(s, hexpr_type(else_if_r.hexpr)))}'", span: some(hexpr_span(else_if_r.hexpr)) }
                ]
                s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(then_r.hexpr), hexpr_type(else_if_r.hexpr), s, span, elif_notes)
                result_type = apply_subst(s, hexpr_type(then_r.hexpr))
                else_hexpr = some(HExpr::Block {
                    stmts: [], tail: some(else_if_r.hexpr),
                    ty: hexpr_type(else_if_r.hexpr), effects: else_if_r.effects, span: espan
                })
            },
            _ => { panic("unreachable: unexpected else branch form in infer_if") }
        },
        none => {}
    }

    InferResult {
        hexpr: HExpr::IfExpr {
            condition: cond_r.hexpr, then_branch: then_r.hexpr, else_branch: else_hexpr,
            ty: result_type, effects: effects, span: span
        },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_string_interp
// ============================================================

fn is_interpolatable_type(t: Type) -> Bool {
    match t {
        Type::IntType => true,
        Type::FloatType => true,
        Type::StrType => true,
        Type::BoolType => true,
        // TypeVar means the type is not yet resolved — allow it (may resolve later)
        Type::TypeVar { .. } => true,
        // ErrorType — already has an error, don't cascade
        Type::ErrorType => true,
        _ => false,
    }
}

fn infer_string_interp(mut ctx: InferCtx, parts: List<StringInterpPart>, span: Span, subst: UnionFind) -> InferResult {
    let mut s = subst
    let mut effects: EffectRow = EMPTY_ROW
    let mut hparts: List<HStringInterpPart> = []

    for part in parts {
        match part {
            StringInterpPart::LitPart(str_val) => hparts.push(HStringInterpPart::Literal(str_val)),
            StringInterpPart::ExprPart(expr) => {
                let r = infer_expr(ctx, expr, s)
                s = r.subst
                let me = merge_effects(ctx.sink, ctx.env, effects, r.effects, s, span)
                effects = me.0
                s = me.1
                // #184: check that interpolated expression type is Str/Int/Float/Bool
                let resolved = apply_subst(s, hexpr_type(r.hexpr))
                if is_interpolatable_type(resolved) == false {
                    let _ = type_error(ctx.sink, E0309,
                        "string interpolation requires Str, Int, Float, or Bool, got ${type_to_string(resolved)}",
                        hexpr_span(r.hexpr),
                        DiagnosticContext::TypeMismatch {
                            expected: "Str | Int | Float | Bool",
                            actual: type_to_string(resolved),
                            expression: none
                        })
                }
                hparts.push(HStringInterpPart::Expression(r.hexpr))
            }
        }
    }

    InferResult {
        hexpr: HExpr::StringInterp { parts: hparts, ty: STR, effects: effects, span: span },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_catch
// ============================================================

fn infer_catch(mut ctx: InferCtx, expr: Expr, arms: List<MatchArm>, span: Span, subst: UnionFind) -> InferResult {
    let expr_r = infer_expr(ctx, expr, subst)
    let mut s = expr_r.subst
    let mut effects = expr_r.effects

    // Extract error type from the body's fail effects, unifying if multiple
    let mut error_type: Type = ctx.env.fresh_var()
    let mut found_fail = false
    for eff in effects.effects {
        match eff {
            Effect::FailEffect { error_type: et } => {
                if found_fail {
                    s = unify_at(ctx.sink, ctx.env, error_type, et, s, span)
                } else {
                    error_type = et
                    found_fail = true
                }
            },
            _ => {}
        }
    }

    // Warn only when the body's effect row is closed (no open tail) and has no fail effect.
    // An open tail means the body may have fail effects from polymorphic call sites.
    let resolved_row = apply_subst_row(s, effects)
    let has_open_tail = match resolved_row.tail {
        some(_) => true,
        none => false
    }
    if found_fail == false && has_open_tail == false {
        let warn = make_diag(W0001, Severity::SevWarning,
            "catch on expression with no fail effect; handler will never execute",
            span,
            DiagnosticContext::OtherContext { detail: some("body has no fail effect") })
        ctx.sink.report(warn)
    }

    let result_type = ctx.env.fresh_var()
    s = unify_at(ctx.sink, ctx.env, hexpr_type(expr_r.hexpr), result_type, s, span)
    let mut harms: List<HMatchArm> = []

    for arm in arms {
        ctx.env.push_scope()
        let arm_result = some({
            let catch_pattern = rewrite_bare_enum_bindings(ctx.env, arm.pattern)
            s = bind_pattern(ctx, catch_pattern, error_type, s)
            let pattern_bindings = exact_pattern_bindings(
                ctx.env, catch_pattern)

            let mut guard_hexpr: HExpr? = none
            match arm.guard {
                some(g) => {
                    let gr = infer_expr(ctx, g, s)
                    s = gr.subst
                    s = unify_at(ctx.sink, ctx.env, hexpr_type(gr.hexpr), BOOL, s, arm.span)
                    let me = merge_effects(ctx.sink, ctx.env, effects, gr.effects, s, arm.span)
                    effects = me.0
                    s = me.1
                    guard_hexpr = some(gr.hexpr)
                },
                none => {}
            }

            let body_r = infer_expr(ctx, arm.body, s)
            s = body_r.subst
            let me = merge_effects(ctx.sink, ctx.env, effects, body_r.effects, s, arm.span)
            effects = me.0
            s = me.1
            s = unify_at(ctx.sink, ctx.env, hexpr_type(body_r.hexpr), result_type, s, arm.span)

            harms.push(HMatchArm { pattern: catch_pattern,
                bindings: pattern_bindings, guard: guard_hexpr,
                body: body_r.hexpr, span: arm.span })
            true
        }) catch { _ => none }
        ctx.env.pop_scope()
        match arm_result {
            none => fail.raise(CompileError {}),
            _ => {}
        }
    }

    // Check exhaustiveness of catch arms against the error type
    let error_type_resolved = apply_subst(s, error_type)
    let missing = check_exhaustive(ctx.env, harms, error_type_resolved, s)
    match missing {
        some(m) => {
            let msg = if m == "_" {
                "Non-exhaustive catch: non-finite error type '${type_to_string(error_type_resolved)}' requires a wildcard '_' or binding pattern"
            } else {
                "Non-exhaustive catch on error type ${type_to_string(error_type_resolved)}: missing pattern for ${m}"
            }
            let _ = type_error(ctx.sink, E0601,
                msg,
                span, DiagnosticContext::PatternError { detail: "missing: ${m}" })
        },
        none => {}
    }

    // catch always fully consumes the fail effect
    effects = remove_fail_effect(effects)

    let final_type = apply_subst(s, result_type)
    InferResult {
        hexpr: HExpr::TryCatch { body: expr_r.hexpr, arms: harms, ty: final_type, effects: effects, span: span },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_handle
// ============================================================

fn infer_handle(mut ctx: InferCtx, body: Expr, handlers: List<EffectHandler>, span: Span, subst: UnionFind) -> InferResult {
    let body_r = infer_expr(ctx, body, subst)
    let mut s = body_r.subst
    let mut effects = body_r.effects
    // #251: an abort arm is an alternate exit from the handled body, so its
    // value participates in the handle result. Keep the concrete body type as
    // the initial join candidate so a Never abort arm cannot bind an otherwise
    // unconstrained body TypeVar to Never (the #180 bottom-poisoning class).
    let mut result_type = hexpr_type(body_r.hexpr)

    // #251: populated lazily only for an abort handler so ordinary
    // tail-resumptive handles retain their existing (#258) checker behavior.
    let mut body_fail_error_type: Type? = none
    let mut body_fail_types_extracted = false

    let mut hhandlers: List<HEffectHandler> = []
    let mut handled_effects: Set<Str> = set_new()
    // Tail-resumptive arm closures capture the OUTER evidence for
    // their handled effect, while abort arms run after the current handler has
    // been deactivated. Both kinds of arm effects therefore escape unchanged
    // and must be merged only AFTER the handled body row has had this handle's
    // effects removed. Keep the rows separate so #251's abort-result contract
    // remains visibly isolated from the tail-resumptive result contract below.
    let mut tail_arm_effect_rows: List<EffectRow> = []
    let mut abort_arm_effect_rows: List<EffectRow> = []
    // One runtime evidence value backs every operation arm for a canonical
    // effect in this handle. Share its type arguments even when the body is
    // pure or contains only an unknown open tail.
    let mut handler_inst_type_args_by_effect: Map<Str, List<Type>> = map_new()

    for handler in handlers {
        ctx.env.push_scope()
        // Tail-resumptive arms are lowered to closures; #251 abort arms execute
        // inline after the current handler is inactive. Infer both at one deeper
        // lambda depth so mutable outer captures use the same shared cell in
        // either lowering. Save/restore the exact enclosing depth, and keep all
        // fallible arm setup inside the bracket, so nested handlers and failed
        // inference cannot leak scope state.
        let enclosing_lambda_depth = ctx.lambda_depth
        ctx.lambda_depth = enclosing_lambda_depth + 1
        let handler_result = some({
            let effect_def = ctx.env.types.effects.get(handler.effect_name)
            let canonical_effect_name = match effect_def {
                some(ed) => ed.name,
                none => handler.effect_name
            }
            let is_abort_handler = canonical_effect_name == "fail" && handler.op_name == "raise"

            // fail.raise receives the error payload raised by the handled body.
            // Extract concrete fail label(s) exactly as infer_catch does and
            // unify duplicates. Apply the current substitution first because
            // an earlier HOF call may already have expanded the body's row tail.
            if is_abort_handler && !body_fail_types_extracted {
                let resolved_body_effects = apply_subst_row(s, effects)
                for eff in resolved_body_effects.effects {
                    match eff {
                        Effect::FailEffect { error_type: et } => {
                            match body_fail_error_type {
                                some(existing) => {
                                    s = unify_at(ctx.sink, ctx.env, existing, et, s, span)
                                },
                                none => {
                                    body_fail_error_type = some(et)
                                }
                            }
                        },
                        _ => {}
                    }
                }
                body_fail_types_extracted = true
            }

            // Instantiate effect type params once per canonical effect for this
            // handle. Every operation arm rebuilds its declaration-variable map
            // from the shared instance.
            let mut handler_inst_map: Map<Int, Type> = map_new()
            let mut handler_inst_type_args: List<Type> = []
            match effect_def {
                some(ed) => {
                    match handler_inst_type_args_by_effect.get(canonical_effect_name) {
                        some(shared_type_args) => {
                            handler_inst_type_args = shared_type_args
                        },
                        none => {
                            for _tpv in ed.type_param_vars {
                                handler_inst_type_args.push(ctx.env.fresh_var())
                            }
                            handler_inst_type_args_by_effect.insert(
                                canonical_effect_name, handler_inst_type_args
                            )
                        }
                    }
                    let mut shared_type_arg_index = 0
                    for tpv in ed.type_param_vars {
                        match handler_inst_type_args.get(shared_type_arg_index) {
                            some(shared_type_arg) => {
                                handler_inst_map.insert(tpv, shared_type_arg)
                            },
                            none => {}
                        }
                        shared_type_arg_index = shared_type_arg_index + 1
                    }
                },
                none => {}
            }

            // The operation signature used by the arm must be the instance
            // performed by the handled body, not an unrelated fresh instance.
            // Body-row merging already unifies repeated labels of the same
            // canonical custom effect; connect every matching concrete label
            // to this arm's instantiation before binding its params/result.
            match effect_def {
                some(ed) => {
                    let resolved_body_effects_for_handler = apply_subst_row(s, effects)
                    for body_effect in resolved_body_effects_for_handler.effects {
                        match body_effect {
                            Effect::CustomEffect { name, type_args } => {
                                if name == canonical_effect_name {
                                    let mut type_arg_index = 0
                                    for handler_type_arg in handler_inst_type_args {
                                        match type_args.get(type_arg_index) {
                                            some(body_type_arg) => {
                                                s = unify_at(
                                                    ctx.sink, ctx.env,
                                                    handler_type_arg, body_type_arg,
                                                    s, handler.span
                                                )
                                            },
                                            none => {}
                                        }
                                        type_arg_index = type_arg_index + 1
                                    }
                                }
                            },
                            _ => {}
                        }
                    }
                },
                none => {}
            }

            let mut op_def: EffectOpDef? = none
            match effect_def {
                some(ed) => { op_def = ed.ops.find(fn(o) { o.name == handler.op_name }) },
                none => {}
            }

            // The instantiated fail.raise parameter is the single payload
            // contract shared by the handled body's concrete fail<E> row, the
            // source annotation (if any), and the arm-local binding.
            let mut abort_payload_type: Type? = none
            if is_abort_handler {
                match op_def {
                    some(od) => {
                        match od.params.first() {
                            some(odt) => {
                                let payload_type = apply_subst_map(handler_inst_map, odt)
                                match body_fail_error_type {
                                    some(body_error_type) => {
                                        s = unify_at(ctx.sink, ctx.env, payload_type, body_error_type, s, handler.span)
                                    },
                                    none => {}
                                }
                                abort_payload_type = some(payload_type)
                            },
                            none => {}
                        }
                    },
                    none => {}
                }

                // An abort handler proves that every open contribution to the
                // body row contains the same fail<payload> contract. Split any
                // open tail into that handled fail label plus a fresh residual,
                // even when the body also has an explicit fail label: otherwise
                // a callback tail could later instantiate to fail<Other>.
                //
                // Effect rows currently have no lacks/optional-label constraint,
                // so this is intentionally an exact (and conservative) callback
                // effect requirement. The residual remains polymorphic and is
                // propagated after fail is filtered from this handle.
                let resolved_body_effects = apply_subst_row(s, effects)
                match (abort_payload_type, resolved_body_effects.tail) {
                    (some(payload_type), some(body_tail)) => {
                        let residual_tail = ctx.env.fresh_var_id()
                        let required_tail = Type::EffectRowType {
                            effects: [Effect::FailEffect { error_type: payload_type }],
                            tail: some(residual_tail)
                        }
                        s = unify_at(
                            ctx.sink, ctx.env,
                            Type::TypeVar { id: body_tail, name: none },
                            required_tail, s, handler.span
                        )
                        body_fail_error_type = some(payload_type)
                    },
                    _ => {}
                }
            }

            let mut hparams: List<HParam> = []
            let mut hi = 0
            for p in handler.params {
                let mut pt = match p.type_annotation {
                    some(ta) => resolve_type_expr(ctx, ta),
                    none => match op_def {
                        some(od) => match od.params.get(hi) {
                            some(odt) => apply_subst_map(handler_inst_map, odt),
                            none => ctx.env.fresh_var()
                        },
                        none => ctx.env.fresh_var()
                    }
                }
                if is_abort_handler && hi == 0 {
                    match abort_payload_type {
                        some(payload_type) => {
                            let mut payload_notes: List<DiagnosticNote> = [
                                DiagnosticNote {
                                    message: "abort handler payload type must match handled fail error type",
                                    span: some(handler.span)
                                },
                                DiagnosticNote {
                                    message: "handler payload parameter has type '${type_to_string(apply_subst(s, pt))}'",
                                    span: some(p.span)
                                }
                            ]
                            match body_fail_error_type {
                                some(body_error_type) => {
                                    payload_notes.push(DiagnosticNote {
                                        message: "handled body raises '${type_to_string(apply_subst(s, body_error_type))}'",
                                        span: some(hexpr_span(body_r.hexpr))
                                    })
                                },
                                none => {}
                            }
                            s = unify_at_noted(ctx.sink, ctx.env, pt, payload_type, s, p.span, payload_notes)
                            pt = apply_subst(s, payload_type)
                        },
                        none => {}
                    }
                }
                ctx.env.bind_mono(p.name, pt)
                let param_scheme = match ctx.env.lookup(p.name) {
                    some(value) => value,
                    none => panic(
                        "unreachable: handler parameter is missing")
                }
                let param_def_id = match param_scheme.def_id {
                    some(id) => id,
                    none => panic(
                        "unreachable: handler parameter has no exact DefId")
                }
                ctx.env.record_def_span(param_def_id, p.span)
                hparams.push(HParam { name: p.name, ty: pt,
                    def_id: some(param_def_id), is_mutable: false })
                hi = hi + 1
            }

            let mut resume_binding: HPatternBinding? = none
            match handler.resume_name {
                some(rn) => {
                    let resume_param = match op_def {
                        some(od) => apply_subst_map(handler_inst_map, od.return_type),
                        none => ctx.env.fresh_var()
                    }
                    let resume_ret = ctx.env.fresh_var()
                    let resume_type = Type::FnType {
                        params: [resume_param], return_type: resume_ret,
                        effects: EMPTY_ROW
                    }
                    ctx.env.bind_mono(rn, resume_type)
                    let resume_scheme = match ctx.env.lookup(rn) {
                        some(value) => value,
                        none => panic(
                            "unreachable: handler resume binding is missing")
                    }
                    let resume_def_id = match resume_scheme.def_id {
                        some(id) => id,
                        none => panic(
                            "unreachable: handler resume binding has no exact DefId")
                    }
                    ctx.env.record_def_span(resume_def_id, handler.span)
                    resume_binding = some(HPatternBinding {
                        name: rn, def_id: resume_def_id, ty: resume_type
                    })
                },
                none => {}
            }

            let hbr = infer_expr(ctx, handler.body, s)
            s = hbr.subst
            if is_abort_handler {
                abort_arm_effect_rows.push(hbr.effects)

                // #251/#180: Never is bottom, but unify binds TypeVars before
                // applying the Never shortcut. Join explicitly so an abort arm
                // that re-raises does not poison a polymorphic normal result,
                // while a Never body can still recover to the arm's value type.
                let resolved_result = apply_subst(s, result_type)
                let resolved_arm = apply_subst(s, hexpr_type(hbr.hexpr))
                let result_is_never = match resolved_result { Type::NeverType => true, _ => false }
                let arm_is_never = match resolved_arm { Type::NeverType => true, _ => false }
                if result_is_never && !arm_is_never {
                    result_type = hexpr_type(hbr.hexpr)
                } else {
                    if !result_is_never && !arm_is_never {
                        let handle_notes: List<DiagnosticNote> = [
                            DiagnosticNote { message: "abort handler arm and handled body must produce the same type", span: some(handler.span) },
                            DiagnosticNote { message: "handled body has type '${type_to_string(resolved_result)}'", span: some(hexpr_span(body_r.hexpr)) },
                            DiagnosticNote { message: "abort arm has type '${type_to_string(resolved_arm)}'", span: some(hexpr_span(hbr.hexpr)) }
                        ]
                        s = unify_at_noted(ctx.sink, ctx.env, hexpr_type(hbr.hexpr), result_type, s, handler.span, handle_notes)
                    }
                }
            } else {
                tail_arm_effect_rows.push(hbr.effects)

                // A tail-resumptive arm is the implementation of this effect
                // operation: its body value is returned directly as the resume
                // value. Resolve bottom before ordinary unification so a Never
                // arm cannot bind a still-fresh shared operation type variable.
                // Either concrete-vs-Never direction remains valid.
                match op_def {
                    some(od) => {
                        let op_return_type = apply_subst_map(handler_inst_map, od.return_type)
                        let resolved_op_return = apply_subst(s, op_return_type)
                        let resolved_arm = apply_subst(s, hexpr_type(hbr.hexpr))
                        let op_return_is_never = match resolved_op_return {
                            Type::NeverType => true,
                            _ => false
                        }
                        let arm_is_never = match resolved_arm {
                            Type::NeverType => true,
                            _ => false
                        }
                        // #265: a Unit-returning operation's resume value
                        // carries no information. The arm result is discarded
                        // exactly like a statement-position value, so it
                        // imposes no contract on the arm's type.
                        let op_return_is_unit = match resolved_op_return {
                            Type::UnitType => true,
                            _ => false
                        }
                        let effect_display = nominal_display_name(canonical_effect_name)
                        let tail_arm_notes: List<DiagnosticNote> = [
                            DiagnosticNote {
                                message: "tail-resumptive handler arm result must match effect operation return type",
                                span: some(handler.span)
                            },
                            DiagnosticNote {
                                message: "effect operation '${effect_display}.${handler.op_name}' returns '${type_to_string(resolved_op_return)}'",
                                span: some(handler.span)
                            },
                            DiagnosticNote {
                                message: "handler arm has type '${type_to_string(resolved_arm)}'",
                                span: some(hexpr_span(hbr.hexpr))
                            }
                        ]
                        if !op_return_is_never && !arm_is_never && !op_return_is_unit {
                            s = unify_at_noted(
                                ctx.sink, ctx.env,
                                hexpr_type(hbr.hexpr), op_return_type,
                                s, handler.span, tail_arm_notes
                            )
                        }
                    },
                    none => {}
                }
            }
            hhandlers.push(HEffectHandler {
                effect_name: canonical_effect_name, op_name: handler.op_name,
                params: hparams, resume_binding: resume_binding,
                body: hbr.hexpr
            })
            handled_effects.insert(canonical_effect_name)
            true
        }) catch { _ => none }
        ctx.lambda_depth = enclosing_lambda_depth
        ctx.env.pop_scope()

        match handler_result {
            some(_) => {},
            none => fail.raise(CompileError {})
        }
    }

    let resolved_effects = apply_subst_row(s, effects)
    let mut filtered_effects: List<Effect> = []
    for e in resolved_effects.effects {
        let should_keep = match e {
            Effect::IoEffect => !handled_effects.contains("io"),
            Effect::CustomEffect { name, .. } => !handled_effects.contains(name),
            Effect::FailEffect { .. } => !handled_effects.contains("fail"),
            Effect::MutEffect { .. } => !handled_effects.contains("mut"),
            // UnsafeEffect cannot be handled — only discharged by unsafe {}
            Effect::UnsafeEffect => true
        }
        if should_keep { filtered_effects.push(e) }
    }
    effects = EffectRow { effects: filtered_effects, tail: resolved_effects.tail }

    // #258: merge explicit tail-arm rows only after filtering the handled
    // body's row. In particular, do not re-filter a same-effect re-perform:
    // explicit arms capture outer evidence, so that operation propagates.
    for arm_effects in tail_arm_effect_rows {
        let me = merge_effects(ctx.sink, ctx.env, effects, arm_effects, s, span)
        effects = me.0
        s = me.1
    }

    // #251: the abort arm executes outside the current handler. Merge its row
    // verbatim after filtering the body row so io/custom effects and a re-raised
    // fail escape to the enclosing signature/handler instead of being swallowed.
    for arm_effects in abort_arm_effect_rows {
        let me = merge_effects(ctx.sink, ctx.env, effects, arm_effects, s, span)
        effects = me.0
        s = me.1
    }
    effects = apply_subst_row(s, effects)

    InferResult {
        hexpr: HExpr::HandleExpr {
            body: body_r.hexpr, handlers: hhandlers,
            ty: apply_subst(s, result_type), effects: effects, span: span
        },
        subst: s, effects: effects
    }
}

// ============================================================
// infer_lambda
// ============================================================

fn infer_lambda(mut ctx: InferCtx, params: List<Param>, body: Expr, span: Span, subst: UnionFind, expected_param_types: List<Type>?) -> InferResult {
    ctx.env.push_scope()
    ctx.lambda_depth = ctx.lambda_depth + 1
    let mut s = subst
    let mut hparams: List<HParam> = []
    let mut param_types: List<Type> = []

    let mut pi = 0
    for p in params {
        let pt = match p.type_annotation {
            some(ta) => resolve_type_expr(ctx, ta),
            none => ctx.env.fresh_var()
        }
        match expected_param_types {
            some(epts) => {
                if p.type_annotation.is_none() {
                    match epts.get(pi) {
                        some(expected_t) => { s = unify_at(ctx.sink, ctx.env, pt, expected_t, s, span) },
                        none => {}
                    }
                }
            },
            none => {}
        }
        ctx.env.bind_mono(p.name, pt)
        let lam_scheme = ctx.env.lookup(p.name)
        match lam_scheme {
            some(ls) => {
                match ls.def_id {
                    some(did) => {
                        ctx.env.record_def_span(did, p.span)
                        ctx.var_lambda_depth.insert(did, ctx.lambda_depth)
                        if p.is_mutable {
                            ctx.env.scope.mutable_vars.insert(did)
                            ctx.env.scope.mut_param_defs.insert(did)
                        } else {
                            ctx.env.scope.let_defs.insert(did)
                        }
                    },
                    none => {}
                }
                hparams.push(HParam { name: p.name, ty: pt, def_id: ls.def_id, is_mutable: p.is_mutable })
            },
            none => {
                hparams.push(HParam { name: p.name, ty: pt, def_id: none, is_mutable: p.is_mutable })
            }
        }
        param_types.push(pt)
        pi = pi + 1
    }

    let body_result = some(infer_expr(ctx, body, s)) catch { _ => none }
    ctx.lambda_depth = ctx.lambda_depth - 1
    ctx.env.pop_scope()

    match body_result {
        some(body_r) => {
            s = body_r.subst
            let mut applied_params: List<Type> = []
            for pt in param_types { applied_params.push(apply_subst(s, pt)) }
            let applied_ret = apply_subst(s, hexpr_type(body_r.hexpr))

            let fn_type = Type::FnType { params: applied_params, return_type: applied_ret, effects: body_r.effects }

            let mut final_hparams: List<HParam> = []
            for hp in hparams {
                final_hparams.push(HParam { name: hp.name, ty: apply_subst(s, hp.ty), def_id: hp.def_id, is_mutable: hp.is_mutable })
            }

            InferResult {
                hexpr: HExpr::Lambda {
                    params: final_hparams, return_type: applied_ret,
                    body: body_r.hexpr, ty: fn_type, effects: EMPTY_ROW, span: span
                },
                subst: s, effects: EMPTY_ROW
            }
        },
        none => fail.raise(CompileError {})
    }
}

// ============================================================
// infer_list_literal
// ============================================================

fn infer_list_literal(mut ctx: InferCtx, elements: List<Expr>, span: Span, subst: UnionFind) -> InferResult {
    if elements.len() == 0 {
        let elem_type = ctx.env.fresh_var()
        let list_type = Type::StructType { name: BUILTIN_LIST, type_params: [elem_type] }
        return InferResult {
            hexpr: HExpr::ListLit { elements: [], ty: list_type, effects: EMPTY_ROW, span: span },
            subst: subst, effects: EMPTY_ROW
        }
    }
    let mut s = subst
    let mut helements: List<HExpr> = []
    let mut elem_type: Type = ctx.env.fresh_var()
    let mut combined_effects: EffectRow = EMPTY_ROW
    for el in elements {
        let r = infer_expr(ctx, el, s)
        s = r.subst
        s = unify_at(ctx.sink, ctx.env, apply_subst(s, hexpr_type(r.hexpr)), apply_subst(s, elem_type), s, span)
        elem_type = apply_subst(s, elem_type)
        helements.push(r.hexpr)
        let me = merge_effects(ctx.sink, ctx.env, combined_effects, r.effects, s, span)
        combined_effects = me.0
        s = me.1
    }
    let list_type = Type::StructType { name: BUILTIN_LIST, type_params: [apply_subst(s, elem_type)] }
    InferResult {
        hexpr: HExpr::ListLit { elements: helements, ty: list_type, effects: combined_effects, span: span },
        subst: s, effects: combined_effects
    }
}
