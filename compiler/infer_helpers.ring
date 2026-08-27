use types::{Type, Effect, EffectRow,
    INT, FLOAT, STR, BOOL, UNIT, NEVER, ANY, EMPTY_ROW,
    type_to_string, nominal_display_name, types_equal,
    type_to_builtin_name}
use ast::{Expr, Pattern, Span, NamedPatternField}
use hir::{HExpr, HStmt, TraitDispatch, DictRef, ValueBindingKind,
    HCallableTypeActual, HCallableEffectInstantiation,
    HCallableValueInstantiation,
    MethodCallRef,
    HOperatorPlan, h_operator_method, h_operator_tuple,
    make_intrinsic_method_call_ref, make_concrete_method_call_ref,
    make_bound_method_call_ref,
    trait_dict_name, trait_bound_param_name,
    hexpr_type, compare_by_first}
use hir_exact::{
    dict_ref_is_simple_physical, dict_ref_is_static_physical,
    dict_ref_simple_name, dict_ref_static_name,
    dict_ref_wrapped_name, dict_ref_wrapped_physical_inner
}
use diagnostics::{DiagnosticContext, DiagnosticNote}
use codes::{E0201, E0205, E0208, E0303, E0307, E0308, E0504, E0705}
use union_find::{UnionFind, uf_find, uf_lookup}
use env::{TypeEnv, TypeScheme, ImplEntry, ImplMethodSchemeCore,
    apply_subst, build_scheme_var_map, scheme_value_type_vars,
    ordered_effect_tail_vars,
    has_impl, lookup_variant, find_impl_by_provider}
use infer_ctx::{InferCtx, InferResult, FnBoundsEntry,
    fn_bound_dict_ref,
    type_error, unify_at, resolve_relative_qualifier,
    resolve_dict_ref_for_type, resolve_dicts_from_scheme, variant_ctor_origin,
    value_binding_kind, value_symbol_ref, current_identity_file_key,
    current_executable_owner, current_dictionary_evidence_owner}
use ir_identity::{IntrinsicRef, ImplMethodRef,
    impl_method_ref_owner, impl_owner_ref_trait, impl_owner_ref_provider,
    make_named_callee_ref, make_local_callee_ref, make_source_slot_ref,
    slot_domain_lexical}

fn make_inferred_ident(
    ctx: InferCtx, name: Str, resolved_name: Str?, scheme: TypeScheme?,
    ty: Type, span: Span
) -> HExpr {
    let def_id = match scheme { some(value) => value.def_id, none => none }
    let kind = value_binding_kind(ctx, def_id)
    let is_constructor = resolved_name.is_some()
    let source_slot = match (def_id, kind) {
        (some(id), ValueBindingKind::LocalBorrow) => if is_constructor {
            none
        } else { some(
            make_source_slot_ref(
                current_identity_file_key(ctx), slot_domain_lexical(), id)) },
        _ => none
    }
    let is_callable = match ty { Type::FnType { .. } => true, _ => false }
    let callee_identity = match def_id {
        some(id) => if is_constructor ||
                match kind {
                    ValueBindingKind::DirectCallable |
                    ValueBindingKind::ExternCallable |
                    ValueBindingKind::ConstGetter => true,
                    ValueBindingKind::LocalBorrow => false
                } {
            some(make_named_callee_ref(value_symbol_ref(ctx, id)))
        } else if is_callable {
            match source_slot {
                some(slot) => some(make_local_callee_ref(slot)),
                none => panic("Ident identity: callable local has no SlotRef")
            }
        } else { none },
        none => none
    }
    HExpr::Ident { name: name, resolved_name: resolved_name,
        def_id: def_id, source_slot: source_slot,
        callee_identity: callee_identity, dict_closure_dicts: none,
        callable_instantiation: none,
        ty: ty, effects: EMPTY_ROW, span: span }
}


pub struct MethodLookupResult {
    method_type: Type?,
    method_core: ImplMethodSchemeCore?,
    impl_owner: ImplEntry?,
    impl_method_ref: ImplMethodRef?,
    intrinsic_ref: IntrinsicRef?
}


pub struct StmtResult {
    hstmt: HStmt,
    subst: UnionFind,
    effects: EffectRow
}

pub struct LiveSchemeBinding {
    binding_key: Str,
    live_scheme: TypeScheme
}

pub struct CalleeMetadata {
    def_id: Int,
    binding_key: Str,
    ultimate_origin: Str,
    kind: ValueBindingKind,
    live_scheme: TypeScheme,
    mut_flags: List<Bool>?
}


// ============================================================
// Value type check (for auto-boxing)
// ============================================================

pub fn is_value_type(t: Type) -> Bool {
    match t {
        Type::IntType => true,
        Type::FloatType => true,
        Type::BoolType => true,
        Type::StrType => true,
        _ => false
    }
}

// ============================================================
// Local mut effect cancellation
// ============================================================

// When calling a function that has mut<T> effects, if the argument
// corresponding to the mut parameter is a local variable (not a
// mut function parameter), the mutation is not observable outside
// the current function, so the mut<T> effect should be cancelled.
//
// callee_params: the callee's FnType parameter types
// callee_effects: the callee's FnType effect row
// hargs: inferred argument HExprs (same length as callee_params for regular calls;
//        for method calls, hargs[i] corresponds to callee_params[param_offset + i])
// param_offset: 0 for regular calls, 1 for method calls (skip self)
pub fn cancel_local_mut_effects(
    ctx: InferCtx,
    effects: EffectRow,
    callee_params: List<Type>,
    callee_effects: EffectRow,
    hargs: List<HExpr>,
    param_offset: Int,
    s: UnionFind
) -> EffectRow {
    let mut cancel_types: List<Type> = []
    for eff in callee_effects.effects {
        match eff {
            Effect::MutEffect { state_type } => {
                let resolved_st = apply_subst(s, state_type)
                let mut pi = param_offset
                let mut ai = 0
                while ai < hargs.len() {
                    match callee_params.get(pi) {
                        some(pt) => {
                            let resolved_pt = apply_subst(s, pt)
                            if types_equal(resolved_pt, resolved_st) {
                                match hargs.get(ai) {
                                    some(harg) => match harg {
                                        HExpr::Ident { def_id: some(did), .. } => {
                                            if !ctx.env.scope.mut_param_defs.contains(did) {
                                                cancel_types.push(resolved_st)
                                            }
                                        },
                                        _ => {}
                                    },
                                    none => {}
                                }
                            }
                        },
                        none => {}
                    }
                    pi = pi + 1
                    ai = ai + 1
                }
            },
            _ => {}
        }
    }

    if cancel_types.len() == 0 {
        return effects
    }

    let mut filtered: List<Effect> = []
    for e in effects.effects {
        let mut keep = true
        match e {
            Effect::MutEffect { state_type } => {
                let resolved_st = apply_subst(s, state_type)
                for ct in cancel_types {
                    if types_equal(ct, resolved_st) {
                        keep = false
                    }
                }
            },
            _ => {}
        }
        if keep {
            filtered.push(e)
        }
    }
    EffectRow { effects: filtered, tail: effects.tail }
}

// ============================================================
// Resolve substitution var chain
// ============================================================

pub fn resolve_var_id(id: Int, sub: UnionFind) -> Int {
    match uf_lookup(sub, id) {
        some(resolved) => match resolved {
            Type::TypeVar { id: new_id, .. } => resolve_var_id(new_id, sub),
            _ => id
        },
        none => uf_find(sub, id)
    }
}

// ============================================================
// Assignment target mutability check
// ============================================================

pub fn check_assign_target_mutable(ctx: InferCtx, target: Expr) {
    match target {
        Expr::Ident { name, span, .. } => {
            let scheme = ctx.env.lookup(name)
            match scheme {
                some(s) => match s.def_id {
                    some(did) => {
                        if !ctx.env.scope.mutable_vars.contains(did) {
                            let _ = type_error(ctx.sink, E0205,
                                "Cannot assign to immutable variable '${name}' (declared with 'let'). Use 'let mut' for mutable bindings.",
                                span, DiagnosticContext::OtherContext { detail: some("'${name}' is declared with 'let'") })
                        }
                    },
                    none => {}
                },
                none => {}
            }
        },
        Expr::FieldAccess { receiver, span, .. } => {
            let root = find_root_expr(receiver)
            match root {
                Expr::Ident { name, span: rspan, .. } => {
                    let scheme = ctx.env.lookup(name)
                    match scheme {
                        some(s) => match s.def_id {
                            some(did) => {
                                if !ctx.env.scope.mutable_vars.contains(did) {
                                    let _ = type_error(ctx.sink, E0205,
                                        "Cannot assign to field of immutable variable '${name}'. Use 'let mut' for mutable bindings.",
                                        span, DiagnosticContext::OtherContext { detail: some("'${name}' is not mutable") })
                                }
                            },
                            none => {}
                        },
                        none => {}
                    }
                },
                _ => {
                    let _ = type_error(ctx.sink, E0205,
                        "Cannot assign to field of a temporary value. Store the value in a 'let mut' variable first.",
                        span, DiagnosticContext::OtherContext { detail: some("assignment to temporary value") })
                }
            }
        },
        _ => {}
    }
}

pub fn find_root_expr(e: Expr) -> Expr {
    match e {
        Expr::FieldAccess { receiver, .. } => find_root_expr(receiver),
        _ => e
    }
}

// B-056: Get def_id of root variable in an assignment target (AST level).
pub fn get_assign_target_root_def_id(ctx: InferCtx, target: Expr) -> Int? {
    let root = find_root_expr(target)
    match root {
        Expr::Ident { name, .. } => {
            match ctx.env.lookup(name) {
                some(s) => s.def_id,
                none => none
            }
        },
        _ => none
    }
}

// B-056: Get type of root HExpr in an assignment target (HIR level).
pub fn get_hexpr_root_type(target: HExpr) -> Type {
    match target {
        HExpr::FieldAccess { receiver, .. } => get_hexpr_root_type(receiver),
        _ => hexpr_type(target)
    }
}

// ============================================================
// infer_ident (from infer-expr.ts)
// ============================================================

// Origin metadata is keyed by the lexical binding's DefId, so same-spelled
// locals cannot inherit an imported or module-level binding's origin.
fn exact_value_origin(ctx: InferCtx, spelling: Str, scheme: TypeScheme) -> Str {
    match scheme.def_id {
        some(def_id) => match ctx.use_aliases.get(def_id) {
            some(origin) => origin,
            none => spelling
        },
        none => spelling
    }
}

pub fn infer_ident(mut ctx: InferCtx, name: Str, span: Span, subst: UnionFind, qualifier: Str?) -> InferResult {
    // Resolve relative paths (self::/super::) to actual qualified names
    let mut resolved_qualifier = qualifier
    match qualifier {
        some(q) => {
            if q == "self" || q.starts_with("super") {
                match resolve_relative_qualifier(q, ctx.mod_path_stack) {
                    some(prefix) => {
                        if prefix == "" {
                            // super from top-level mod — name is at root scope
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
                            hexpr: make_inferred_ident(
                                ctx, name, none, none, Type::ErrorType, span),
                            subst: subst, effects: EMPTY_ROW
                        }
                    }
                }
            }
        },
        none => {}
    }

    // Try module-qualified lookup first: qualifier::name
    match resolved_qualifier {
        some(q) => {
            let qualified_name = "${q}::${name}"
            let mod_scheme = ctx.env.lookup(qualified_name)
            match mod_scheme {
                some(ms) => {
                    let t = ctx.env.instantiate(ms)
                    let actual_name = exact_value_origin(ctx, qualified_name, ms)
                    return InferResult {
                        hexpr: make_inferred_ident(
                            ctx, actual_name, variant_ctor_origin(ctx, ms),
                            some(ms), t, span),
                        subst: subst, effects: EMPTY_ROW
                    }
                },
                none => {
                    // Fallback: try prepending current mod path for relative references
                    // e.g., inside mod outer, "inner::f" should resolve to "outer::inner::f"
                    if ctx.mod_path_stack.len() > 0 {
                        let mod_prefix = ctx.mod_path_stack.join("::")
                        let full_qualified = "${mod_prefix}::${qualified_name}"
                        let full_scheme = ctx.env.lookup(full_qualified)
                        match full_scheme {
                            some(fs) => {
                                let t = ctx.env.instantiate(fs)
                                let actual_name = exact_value_origin(ctx, full_qualified, fs)
                                return InferResult {
                                    hexpr: make_inferred_ident(
                                        ctx, actual_name,
                                        variant_ctor_origin(ctx, fs),
                                        some(fs), t, span),
                                    subst: subst, effects: EMPTY_ROW
                                }
                            },
                            none => {}
                        }
                    }
                }
            }
        },
        none => {}
    }

    let scheme = ctx.env.lookup(name)
    match scheme {
        none => {
            match resolved_qualifier {
                some(q) => {
                    let qualifier_display = nominal_display_name(q)
                    let _ = type_error(ctx.sink, E0201, "'${qualifier_display}' has no member '${name}'", span,
                        DiagnosticContext::UndefinedVariable { name: name, scope_locals: none })
                    return InferResult {
                        hexpr: make_inferred_ident(
                            ctx, name, none, none, Type::ErrorType, span),
                        subst: subst, effects: EMPTY_ROW
                    }
                },
                none => {}
            }
            let _ = type_error(ctx.sink, E0201, "Undefined variable: ${name}", span,
                DiagnosticContext::UndefinedVariable { name: name, scope_locals: none })
            InferResult {
                hexpr: make_inferred_ident(
                    ctx, name, none, none, Type::ErrorType, span),
                subst: subst, effects: EMPTY_ROW
            }
        },
        some(s) => {
            let t = ctx.env.instantiate(s)
            // Auto-boxing: mark mutable vars captured by closures
            match s.def_id {
                some(did) => {
                    if ctx.env.scope.mutable_vars.contains(did) {
                        match ctx.var_lambda_depth.get(did) {
                            some(def_depth) => {
                                if ctx.lambda_depth > def_depth {
                                    ctx.boxed_vars.insert(did)
                                }
                            },
                            none => {}
                        }
                    }
                },
                none => {}
            }
            // Check if this name was imported via use alias (e.g. use super::value)
            // If so, use the qualified name in HIR for correct codegen
            let actual_name = exact_value_origin(ctx, name, s)
            match resolved_qualifier {
                some(q) => {
                    match ctx.env.types.enums.get(q) {
                        some(enum_def) => {
                            if !enum_def.variant_index.contains_key(name) {
                                let qualifier_display = nominal_display_name(q)
                                let _ = type_error(ctx.sink, E0201, "'${qualifier_display}' has no variant '${name}'", span,
                                    DiagnosticContext::UndefinedVariable { name: name, scope_locals: none })
                            }
                        },
                        none => {
                            let qualifier_display = nominal_display_name(q)
                            let _ = type_error(ctx.sink, E0201, "'${qualifier_display}' has no variant '${name}'", span,
                                DiagnosticContext::UndefinedVariable { name: name, scope_locals: none })
                        }
                    }
                },
                none => {}
            }
            InferResult {
                hexpr: make_inferred_ident(
                    ctx, actual_name, variant_ctor_origin(ctx, s),
                    some(s), t, span),
                subst: subst, effects: EMPTY_ROW
            }
        }
    }
}

// ============================================================
// infer_numeric_op
// ============================================================

pub fn infer_numeric_op(ctx: InferCtx, left: HExpr, right: HExpr, s: UnionFind, span: Span, op_str: Str) -> Type {
    let resolved = apply_subst(s, hexpr_type(left))
    match resolved {
        Type::TypeVar { id: tv_id, .. } => {
            // Check if this TypeVar is a rigid type parameter (from fn<T> etc.)
            // Rigid type params should not silently unify to Int — report E0303.
            // Fresh inference variables (e.g. from fold callback) can unify to Int.
            let mut rigid_ids: Set<Int> = set_new()
            let mut sorted_tp_scope = ctx.type_param_scope.entries()
            sorted_tp_scope.sort_by(compare_by_first)
            for entry in sorted_tp_scope {
                let tp_type = entry.1
                match tp_type {
                    Type::TypeVar { id: tp_id, .. } => {
                        rigid_ids.insert(resolve_var_id(tp_id, s))
                    },
                    _ => {}
                }
            }
            let is_rigid = rigid_ids.contains(resolve_var_id(tv_id, s))
            if is_rigid {
                type_error(ctx.sink, E0303,
                    "Operator ${op_str} requires numeric types (Int or Float), got unresolved type",
                    span, DiagnosticContext::TypeMismatch { expected: "Int or Float", actual: "unresolved type", expression: none })
            } else {
                let _ = unify_at(ctx.sink, ctx.env, resolved, INT, s, span)
                INT
            }
        },
        Type::IntType => INT,
        Type::FloatType => FLOAT,
        _ => type_error(ctx.sink, E0303,
            "Operator ${op_str} requires numeric types, got ${type_to_string(resolved)}",
            span, DiagnosticContext::TypeMismatch { expected: "Int or Float", actual: type_to_string(resolved), expression: none })
    }
}

pub fn is_primitive_eq(t: Type) -> Bool {
    match t {
        Type::IntType => true,
        Type::FloatType => true,
        Type::StrType => true,
        Type::BoolType => true,
        Type::UnitType => true,
        Type::NeverType => true,
        Type::AnyType => true,
        _ => false
    }
}

pub fn is_primitive_ord(t: Type) -> Bool {
    match t {
        Type::IntType => true,
        Type::FloatType => true,
        Type::StrType => true,
        Type::BoolType => true,
        _ => false
    }
}

// Resolve tuple Eq structurally while delegating every non-tuple leaf to the
// normal trait resolver.  This is the single source of truth for the plan
// consumed by dict lowering, closure-capture census, and both native backends.
pub fn resolve_eq_dispatch(ctx: InferCtx, resolved: Type, subst: UnionFind,
                           span: Span, op: Str) -> TraitDispatch {
    match resolved {
        Type::TupleType { elements } => {
            let mut element_types: List<Type> = []
            let mut element_dispatches: List<TraitDispatch> = []
            for element in elements {
                let element_type = apply_subst(subst, element)
                element_types.push(element_type)
                element_dispatches.push(resolve_eq_dispatch(
                    ctx, element_type, subst, span, op))
            }
            TraitDispatch::Tuple {
                element_types: element_types,
                elements: element_dispatches
            }
        },
        _ => resolve_trait_dispatch(
            ctx, resolved, "Eq", E0307, subst, span, op,
            is_primitive_eq(resolved)),
    }
}

fn dispatch_from_dict_ref(dict_ref: DictRef) -> TraitDispatch {
    if dict_ref_is_static_physical(dict_ref) {
        TraitDispatch::Direct {
            dict: dict_ref_static_name(dict_ref), extra_dicts: []
        }
    } else if dict_ref_is_simple_physical(dict_ref) {
        TraitDispatch::Dict { param: dict_ref_simple_name(dict_ref) }
    } else {
        TraitDispatch::Direct {
            dict: dict_ref_wrapped_name(dict_ref),
            extra_dicts: dict_ref_wrapped_physical_inner(dict_ref)
        }
    }
}

fn bound_type_var_matches(
    subst: UnionFind, bound_var_id: Int, resolved_id: Int
) -> Bool {
    if bound_var_id == resolved_id ||
       uf_find(subst, bound_var_id) == resolved_id {
        return true
    }
    match apply_subst(
            subst, Type::TypeVar { id: bound_var_id, name: none }) {
        Type::TypeVar { id, .. } => id == resolved_id,
        _ => false
    }
}

pub fn resolve_trait_dispatch(ctx: InferCtx, resolved: Type, trait_name: Str, error_code: Str, subst: UnionFind, span: Span, op: Str, is_builtin: Bool) -> TraitDispatch {
    if is_builtin { return TraitDispatch::Builtin }
    let trait_display = nominal_display_name(trait_name)

    match resolved {
        Type::TypeVar { id, .. } => {
            let bound = ctx.current_fn_bounds.find(fn(fb) {
                fb.trait_name == trait_name &&
                    bound_type_var_matches(
                        subst, fb.type_param_var_id, id)
            })
            match bound {
                some(b) => { return TraitDispatch::Dict { param: trait_bound_param_name(b.type_param_name, trait_name) } },
                none => {}
            }
            match ctx.env.scope.var_bounds.get(id) {
                some(var_bounds) => {
                    if var_bounds.contains(trait_name) { return TraitDispatch::Builtin }
                },
                none => {}
            }
            let _ = type_error(ctx.sink, error_code,
                "Type does not implement ${trait_display}, cannot use '${op}'",
                span, DiagnosticContext::TraitError { detail: "type does not implement ${trait_display}" })
            TraitDispatch::Builtin
        },
        Type::StructType { .. } => {
            match resolve_dict_ref_for_type(
                current_dictionary_evidence_owner(ctx),
                ctx.env, ctx.current_fn_bounds, resolved, subst, trait_name
            ) {
                some(dict_ref) => {
                    return dispatch_from_dict_ref(dict_ref)
                },
                none => {}
            }
            let _ = type_error(ctx.sink, error_code,
                "Type '${type_to_string(resolved)}' does not implement ${trait_display}, cannot use '${op}'",
                span, DiagnosticContext::TraitError { detail: "type '${type_to_string(resolved)}' does not implement ${trait_display}" })
            TraitDispatch::Builtin
        },
        Type::EnumType { .. } => {
            match resolve_dict_ref_for_type(
                current_dictionary_evidence_owner(ctx),
                ctx.env, ctx.current_fn_bounds, resolved, subst, trait_name
            ) {
                some(dict_ref) => {
                    return dispatch_from_dict_ref(dict_ref)
                },
                none => {}
            }
            let _ = type_error(ctx.sink, error_code,
                "Type '${type_to_string(resolved)}' does not implement ${trait_display}, cannot use '${op}'",
                span, DiagnosticContext::TraitError { detail: "type '${type_to_string(resolved)}' does not implement ${trait_display}" })
            TraitDispatch::Builtin
        },
        _ => {
            let _ = type_error(ctx.sink, error_code,
                "Type '${type_to_string(resolved)}' does not implement ${trait_display}, cannot use '${op}'",
                span, DiagnosticContext::TraitError { detail: "type '${type_to_string(resolved)}' does not implement ${trait_display}" })
            TraitDispatch::Builtin
        }
    }
}

// ============================================================
// Final value-position lowering for callable identifiers
// ============================================================

fn live_scheme_by_def_id(ctx: InferCtx, wanted: Int) -> LiveSchemeBinding? {
    let mut scope_idx = ctx.env.scope.scopes.len() - 1
    while scope_idx >= 0 {
        match ctx.env.scope.scopes.get(scope_idx) {
            some(scope) => {
                let entries = scope.variables.entries()
                for entry in entries {
                    let (binding_key, candidate) = entry
                    match candidate.def_id {
                        some(candidate_id) => {
                            if candidate_id == wanted {
                                return some(LiveSchemeBinding {
                                    binding_key: binding_key,
                                    live_scheme: candidate
                                })
                            }
                        },
                        none => {}
                    }
                }
            },
            none => {}
        }
        scope_idx = scope_idx - 1
    }
    none
}

pub fn resolve_callee_metadata(ctx: InferCtx, callee: HExpr) -> CalleeMetadata? {
    match callee {
        HExpr::Ident { def_id: some(def_id), .. } => {
            let kind = value_binding_kind(ctx, some(def_id))
            match live_scheme_by_def_id(ctx, def_id) {
                some(binding) => {
                    let ultimate_origin = match ctx.use_aliases.get(def_id) {
                        some(origin) => origin,
                        none => binding.binding_key
                    }

                    let mut mut_flags: List<Bool>? = none
                    match kind {
                        ValueBindingKind::DirectCallable => {
                            mut_flags = match ctx.fn_mut_params.get(ultimate_origin) {
                                some(flags) => some(flags),
                                none => match ctx.fn_mut_params.get(binding.binding_key) {
                                    some(flags) => some(flags),
                                    none => none
                                }
                            }
                        },
                        _ => {}
                    }

                    some(CalleeMetadata {
                        def_id: def_id,
                        binding_key: binding.binding_key,
                        ultimate_origin: ultimate_origin,
                        kind: kind,
                        live_scheme: binding.live_scheme,
                        mut_flags: mut_flags
                    })
                },
                none => match kind {
                    ValueBindingKind::LocalBorrow => none,
                    ValueBindingKind::DirectCallable |
                    ValueBindingKind::ExternCallable |
                    ValueBindingKind::ConstGetter =>
                        panic("internal error: declaration value DefId has no live scheme")
                }
            }
        },
        _ => none
    }
}

pub fn is_bounded_direct_callable_ident(ctx: InferCtx, expr: HExpr) -> Bool {
    match resolve_callee_metadata(ctx, expr) {
        some(metadata) => {
            match metadata.kind {
                ValueBindingKind::DirectCallable | ValueBindingKind::ExternCallable => {
                    metadata.live_scheme.bounds.len() > 0
                },
                _ => false
            }
        },
        _ => false
    }
}

fn declared_callable_type_vars(scheme: TypeScheme) -> List<Int> {
    let effect_tails = ordered_effect_tail_vars(scheme.ty)
    scheme.type_vars.filter(fn(id) { !effect_tails.contains(id) })
}

pub fn exact_callable_type_args(
    ctx: InferCtx, metadata: CalleeMetadata,
    instantiated_type: Type, subst: UnionFind
) -> List<HCallableTypeActual> {
    let scheme = metadata.live_scheme
    let declared = declared_callable_type_vars(scheme)
    let exact_type = apply_subst(subst, instantiated_type)
    let mapping = build_scheme_var_map(scheme, exact_type)
    let mut result: List<HCallableTypeActual> = []
    for formal in scheme_value_type_vars(scheme) {
        let mut ordinal: Int? = none
        let mut index = 0
        while index < declared.len() {
            if declared.get(index).unwrap() == formal { ordinal = some(index) }
            index = index + 1
        }
        result.push(HCallableTypeActual {
            owner: value_symbol_ref(ctx, metadata.def_id),
            source_type_var_id: formal,
            ordinal: match ordinal {
                some(value) => value,
                none => panic(
                    "callable value: used type formal is not declared")
            },
            arity: declared.len(),
            actual: match mapping.get(formal) {
            some(actual) => apply_subst(subst, actual),
            none => panic(
                "callable value: declared generic has no exact instantiation")
            }
        })
    }
    result
}

fn exact_callable_value_instantiation(
    ctx: InferCtx, metadata: CalleeMetadata,
    instantiated_type: Type, subst: UnionFind
) -> HCallableValueInstantiation? {
    let scheme = metadata.live_scheme
    if scheme.type_vars.len() == 0 { return none }
    if ordered_effect_tail_vars(scheme.ty).len() != 0 {
        panic("callable value: open effect provenance is absent")
    }
    some(HCallableValueInstantiation {
        type_args: exact_callable_type_args(
            ctx, metadata, instantiated_type, subst),
        effects: some(HCallableEffectInstantiation { substitutions: [] })
    })
}

pub fn resolve_value_ident(ctx: InferCtx, harg: HExpr, s: UnionFind) -> HExpr {
    let metadata = resolve_callee_metadata(ctx, harg)
    match harg {
        HExpr::Ident { name, resolved_name, def_id, source_slot,
                       callee_identity, dict_closure_dicts,
                       callable_instantiation, ty, effects, span } => {
            let kind = match metadata {
                some(m) => m.kind,
                none => ValueBindingKind::LocalBorrow
            }

            // A const identifier denotes a call to its zero-argument getter.
            // This remains explicit even when the stored value itself is a
            // function, so an outer source call uses the closure ABI.
            match kind {
                ValueBindingKind::ConstGetter => {
                    let getter_ty = Type::FnType {
                        params: [], return_type: ty, effects: EMPTY_ROW
                    }
                    let getter = HExpr::Ident {
                        name: name, resolved_name: none, def_id: def_id,
                        source_slot: source_slot,
                        callee_identity: callee_identity,
                        // This synthetic direct getter Call is returned from
                        // zonk and will not pass through zonk_direct_callee.
                        dict_closure_dicts: some([]),
                        callable_instantiation: callable_instantiation,
                        ty: getter_ty,
                        effects: EMPTY_ROW, span: span
                    }
                    return HExpr::Call {
                        callee: getter, args: [], type_args: [],
                        effect_instantiation: none,
                        resolved_dicts: [],
                        handled_evidence: [],
                        callee_ref: match def_id {
                            some(id) => some(make_named_callee_ref(
                                value_symbol_ref(ctx, id))),
                            none => panic(
                                "const getter: exact DefId is missing")
                        },
                        method_ref: none,
                        system_host: none,
                        ty: ty, effects: effects, span: span
                    }
                },
                _ => {}
            }

            // Already resolved by an earlier value-position walk.
            match dict_closure_dicts {
                some(_) => { return harg },
                none => {},
            }

            match ty {
                Type::FnType { .. } => {},
                _ => { return harg }
            }

            match kind {
                ValueBindingKind::DirectCallable => {
                    match metadata {
                        some(m) => {
                            let as_ = m.live_scheme
                            let exact_instantiation =
                                exact_callable_value_instantiation(ctx, m, ty, s)
                            if as_.bounds.len() == 0 {
                                HExpr::Ident {
                                    name: name, resolved_name: resolved_name,
                                    def_id: def_id, source_slot: source_slot,
                                    callee_identity: callee_identity,
                                    dict_closure_dicts: some([]),
                                    callable_instantiation: exact_instantiation,
                                    ty: ty, effects: effects, span: span
                                }
                            } else {
                                let dicts = resolve_dicts_from_scheme(
                                    current_dictionary_evidence_owner(ctx),
                                    ctx.sink, ctx.env, ctx.current_fn_bounds,
                                    as_, ty, s, span
                                )
                                // Never attach partial evidence.  resolve_dicts_from_scheme
                                // has already emitted one E0503 for every missing bound.
                                if dicts.len() == as_.bounds.len() {
                                    HExpr::Ident { name: name, resolved_name: resolved_name,
                                        def_id: def_id, source_slot: source_slot,
                                        callee_identity: callee_identity,
                                        dict_closure_dicts: some(dicts),
                                        callable_instantiation: exact_instantiation,
                                        ty: ty,
                                        effects: effects, span: span }
                                } else { harg }
                            }
                        },
                        none => harg
                    }
                },
                ValueBindingKind::ExternCallable => {
                    match metadata {
                        some(m) => {
                            let as_ = m.live_scheme
                            let exact_instantiation =
                                exact_callable_value_instantiation(ctx, m, ty, s)
                            let valid = if as_.bounds.len() > 0 {
                                let validated = resolve_dicts_from_scheme(
                                    current_dictionary_evidence_owner(ctx),
                                    ctx.sink, ctx.env, ctx.current_fn_bounds,
                                    as_, ty, s, span
                                )
                                validated.len() == as_.bounds.len()
                            } else {
                                true
                            }
                            if valid {
                                HExpr::Ident {
                                    name: name, resolved_name: resolved_name,
                                    def_id: def_id, source_slot: source_slot,
                                    callee_identity: callee_identity,
                                    dict_closure_dicts: some([]),
                                    callable_instantiation: exact_instantiation,
                                    ty: ty, effects: effects, span: span
                                }
                            } else {
                                harg
                            }
                        },
                        none => harg
                    }
                },
                ValueBindingKind::ConstGetter => harg,
                ValueBindingKind::LocalBorrow => {
                    // Positional variant constructors have their own exact
                    // DefId provenance and also need a zero-dict direct-ABI
                    // wrapper when used as values.
                    match resolved_name {
                        some(_) => HExpr::Ident {
                            name: name, resolved_name: resolved_name,
                            def_id: def_id, source_slot: source_slot,
                            callee_identity: callee_identity,
                            dict_closure_dicts: some([]),
                            callable_instantiation: callable_instantiation,
                            ty: ty, effects: effects, span: span
                        },
                        none => harg
                    }
                }
            }
        },
        _ => harg
    }
}

// ============================================================
// Mutability check for method calls
// ============================================================

pub fn check_expr_is_let_def(ctx: InferCtx, expr: Expr) -> Bool {
    match expr {
        Expr::Ident { name, .. } => {
            match ctx.env.lookup(name) {
                some(s) => match s.def_id {
                    some(did) => ctx.env.scope.let_defs.contains(did),
                    none => false
                },
                none => false
            }
        },
        Expr::FieldAccess { receiver: inner, .. } => check_expr_is_let_def(ctx, inner),
        _ => false
    }
}

pub fn get_expr_def_id(ctx: InferCtx, expr: Expr) -> Int? {
    match expr {
        Expr::Ident { name, .. } => {
            match ctx.env.lookup(name) {
                some(s) => s.def_id,
                none => none
            }
        },
        // Do not recurse through FieldAccess: only direct ident receivers
        // qualify for mut<T> injection (e.g. list.push, not ctx.field.push)
        _ => none
    }
}

pub fn is_mut_method_call(ctx: InferCtx, recv_type: Type, method: Str) -> Bool {
    let mut type_name: Str? = none
    match recv_type {
        Type::StructType { name, .. } => { type_name = some(name) },
        Type::EnumType { name, .. } => { type_name = some(name) },
        _ => {
            match type_to_builtin_name(recv_type) {
                some(n) => { type_name = some(n) },
                none => {}
            }
        }
    }
    match type_name {
        some(tname) => {
            match ctx.env.trait_reg.mut_methods.get(tname) {
                some(mut_set) => mut_set.contains(method),
                none => false
            }
        },
        none => false
    }
}

pub fn check_receiver_mutability(mut ctx: InferCtx, receiver: Expr, recv_type: Type, method: Str, span: Span) {
    let mut type_name: Str? = none
    match recv_type {
        Type::StructType { name, .. } => { type_name = some(name) },
        Type::EnumType { name, .. } => { type_name = some(name) },
        _ => {
            match type_to_builtin_name(recv_type) {
                some(n) => { type_name = some(n) },
                none => {}
            }
        }
    }

    match type_name {
        some(tname) => {
            match ctx.env.trait_reg.mut_methods.get(tname) {
                some(mut_set) => {
                    if mut_set.contains(method) {
                        let is_let_def = check_expr_is_let_def(ctx, receiver)
                        if is_let_def {
                            let _ = type_error(ctx.sink, E0208,
                                "Cannot call mutating method '${method}' on immutable binding. Use 'let mut' to make it mutable.",
                                span, DiagnosticContext::OtherContext { detail: some("'${method}' requires a mutable receiver") })
                        }
                    }
                },
                none => {}
            }
        },
        none => {}
    }
}

// ============================================================
// Method lookup helpers
// ============================================================

pub fn lookup_impl_method(mut ctx: InferCtx, type_name: Str, method: Str) -> MethodLookupResult {
    match ctx.env.trait_reg.method_index.get(type_name) {
        some(index) => match index.get(method) {
            some(method_ref) => {
                let owner_ref = impl_method_ref_owner(method_ref)
                match find_impl_by_provider(
                ctx.env.trait_reg, type_name,
                impl_owner_ref_trait(owner_ref),
                impl_owner_ref_provider(owner_ref)
            ) {
                some(owner) => match owner.method_schemes.get(method) {
                    some(core) => MethodLookupResult {
                        method_type: some(
                            ctx.env.instantiate_impl_method_core(owner, core)),
                        method_core: some(core),
                        impl_owner: some(owner),
                        impl_method_ref: some(method_ref),
                        intrinsic_ref: owner.method_intrinsics.get(method)
                    },
                    none => panic("method lookup: owner lost method core")
                },
                none => panic("method lookup: method index lost owner")
                }
            },
            none => MethodLookupResult {
                method_type: none, method_core: none, impl_owner: none,
                impl_method_ref: none,
                intrinsic_ref: none
            }
        },
        none => MethodLookupResult {
            method_type: none, method_core: none, impl_owner: none,
            impl_method_ref: none,
            intrinsic_ref: none
        }
    }
}

pub fn exact_operator_plan(
    ctx: InferCtx, resolved: Type, trait_name: Str,
    method_name: Str, subst: UnionFind, span: Span
) -> HOperatorPlan? {
    let exact_type = apply_subst(subst, resolved)
    match exact_type {
        Type::TupleType { elements } => {
            let mut plans: List<HOperatorPlan> = []
            for element in elements {
                match exact_operator_plan(
                        ctx, element, trait_name, method_name, subst, span) {
                    some(plan) => plans.push(plan),
                    none => return none
                }
            }
            some(h_operator_tuple(plans))
        },
        Type::TypeVar { id, .. } => {
            let bound = match ctx.current_fn_bounds.find(fn(item) {
                item.trait_name == trait_name &&
                    bound_type_var_matches(
                        subst, item.type_param_var_id, id)
            }) {
                some(value) => value,
                none => return none
            }
            let trait_def = match ctx.env.trait_reg.traits.get(trait_name) {
                some(value) => value,
                none => return none
            }
            let method = match trait_def.methods.find(fn(item) {
                item.name == method_name
            }) {
                some(value) => value,
                none => return none
            }
            some(h_operator_method(make_bound_method_call_ref(
                method.method_ref,
                fn_bound_dict_ref(
                    current_dictionary_evidence_owner(ctx), bound),
                method.ty, false)))
        },
        _ => {
            let type_name = match type_to_builtin_name(exact_type) {
                some(value) => value,
                none => match exact_type {
                    Type::StructType { name, .. } => name,
                    Type::EnumType { name, .. } => name,
                    _ => return none
                }
            }
            let lookup = lookup_impl_method(ctx, type_name, method_name)
            let signature = match lookup.method_type {
                some(value) => value,
                none => return none
            }
            match lookup.intrinsic_ref {
                some(intrinsic) => some(h_operator_method(
                    make_intrinsic_method_call_ref(intrinsic, signature))),
                none => match lookup.impl_method_ref {
                    some(method) => some(h_operator_method(
                        make_concrete_method_call_ref(
                            method, signature, false))),
                    none => none
                }
            }
        }
    }
}

pub fn exact_nominal_method_call(
    ctx: InferCtx, type_name: Str, method_name: Str
) -> MethodCallRef {
    let lookup = lookup_impl_method(ctx, type_name, method_name)
    let signature = match lookup.method_type {
        some(value) => value,
        none => panic("method plan: exact signature is absent")
    }
    match lookup.intrinsic_ref {
        some(intrinsic) => make_intrinsic_method_call_ref(
            intrinsic, signature),
        none => match lookup.impl_method_ref {
            some(method) => make_concrete_method_call_ref(
                method, signature, false),
            none => panic("method plan: exact impl method is absent")
        }
    }
}

pub fn lookup_trait_method(mut ctx: InferCtx, type_name: Str, method: Str, span: Span) -> MethodLookupResult {
    let mut found: MethodLookupResult = MethodLookupResult {
        method_type: none, method_core: none, impl_owner: none,
        impl_method_ref: none,
        intrinsic_ref: none
    }
    let mut found_trait_name: Str? = none
    match ctx.env.trait_reg.trait_impls.get(type_name) {
        some(type_impls) => {
            for impl_entry in type_impls {
                match impl_entry.trait_name {
                    some(entry_trait_name) => match ctx.env.trait_reg.traits.get(entry_trait_name) {
                        some(trait_def) => {
                        let tm = trait_def.methods.find(fn(m) { m.name == method })
                        match tm {
                            some(found_method) => {
                                match found_trait_name {
                                    some(prev_trait) => {
                                        let type_display = nominal_display_name(type_name)
                                        let prev_display = nominal_display_name(prev_trait)
                                        let trait_display = nominal_display_name(entry_trait_name)
                                        let _ = type_error(ctx.sink, E0504,
                                            "Ambiguous method '${method}' on '${type_display}': found in trait '${prev_display}' and '${trait_display}'",
                                            span, DiagnosticContext::OtherContext { detail: some("disambiguate by calling TraitName::${method}") })
                                        return found
                                    },
                                    none => {
                                        match impl_entry.method_schemes.get(method) {
                                            some(core) => {
                                                found = MethodLookupResult {
                                                    method_type: some(
                                                        ctx.env.instantiate_impl_method_core(
                                                            impl_entry, core)),
                                                    method_core: some(core),
                                                    impl_owner: some(impl_entry),
                                                    impl_method_ref:
                                                        impl_entry.method_refs.get(method),
                                                    intrinsic_ref:
                                                        impl_entry.method_intrinsics.get(method)
                                                }
                                            },
                                            none => panic(
                                                "trait method lookup: owner lost exact core")
                                        }
                                        found_trait_name = some(entry_trait_name)
                                    }
                                }
                            },
                            none => {}
                        }
                        },
                        none => {}
                    },
                    none => {}
                }
            }
        },
        none => {}
    }
    found
}

// ============================================================
// rewrite_bare_enum_bindings
// ============================================================

pub fn rewrite_bare_enum_bindings(env: TypeEnv, pattern: Pattern) -> Pattern {
    match pattern {
        Pattern::Binding { name, span } => {
            match env.types.variant_to_enum.get(name) {
                some(ve) => match env.types.enums.get(ve) {
                    some(edef) => {
                        let v = lookup_variant(edef, name)
                        match v {
                            some(found_v) => {
                                if found_v.fields.len() == 0 {
                                    let empty_pats: List<Pattern> = []
                                    Pattern::Constructor { name: name, qualifier: some(edef.name), fields: empty_pats, span: span }
                                } else {
                                    pattern
                                }
                            },
                            none => pattern,
                        }
                    },
                    none => pattern,
                },
                none => pattern,
            }
        },
        Pattern::TuplePattern { elements, span } => {
            let mut new_elems: List<Pattern> = []
            for elem in elements {
                new_elems.push(rewrite_bare_enum_bindings(env, elem))
            }
            Pattern::TuplePattern { elements: new_elems, span: span }
        },
        Pattern::Constructor { name, qualifier, fields, span } => {
            let mut new_fields: List<Pattern> = []
            for f in fields {
                new_fields.push(rewrite_bare_enum_bindings(env, f))
            }
            let canonical_qualifier = match qualifier {
                some(q) => match env.types.enums.get(q) {
                    some(edef) => some(edef.name), none => qualifier
                },
                none => env.types.variant_to_enum.get(name)
            }
            Pattern::Constructor { name: name, qualifier: canonical_qualifier, fields: new_fields, span: span }
        },
        Pattern::NamedConstructor { name, qualifier, fields, rest, span } => {
            let mut new_fields: List<NamedPatternField> = []
            for f in fields {
                new_fields.push(NamedPatternField { name: f.name, pattern: rewrite_bare_enum_bindings(env, f.pattern), span: f.span })
            }
            let canonical_enum = match qualifier {
                some(q) => match env.types.enums.get(q) {
                    some(edef) => some(edef.name), none => none
                },
                none => env.types.variant_to_enum.get(name)
            }
            match canonical_enum {
                some(ename) => Pattern::NamedConstructor { name: name, qualifier: some(ename), fields: new_fields, rest: rest, span: span },
                none => {
                    let struct_lookup = match qualifier {
                        some(q) => "${q}::${name}", none => name
                    }
                    match env.types.structs.get(struct_lookup) {
                        some(sdef) => Pattern::NamedConstructor { name: sdef.name, qualifier: none, fields: new_fields, rest: rest, span: span },
                        none => Pattern::NamedConstructor { name: name, qualifier: qualifier, fields: new_fields, rest: rest, span: span }
                    }
                }
            }
        },
        Pattern::OrPattern { patterns, span } => {
            let mut new_pats: List<Pattern> = []
            for p in patterns {
                new_pats.push(rewrite_bare_enum_bindings(env, p))
            }
            Pattern::OrPattern { patterns: new_pats, span: span }
        },
        _ => pattern,
    }
}
